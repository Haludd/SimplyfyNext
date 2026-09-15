"""Lexical grounding and one independent bounded provider request per assembly."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from importlib.resources import files
from typing import Any, Protocol, TypeVar

from pydantic import BaseModel

from simplynext.agent.words.state import WordDraft, WordVerdict
from simplynext.contracts.room_events import Reason
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1, parse_value
from simplynext.rooms.context import ConversationContext


class WordOutputFailure(ValueError):
    def __init__(self, reason: Reason) -> None:
        super().__init__(reason)
        self.reason = reason


class ConverseClient(Protocol):
    def converse(self, **kwargs: Any) -> Mapping[str, Any]: ...


class WordAssembler(Protocol):
    def assemble(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        previous: WordDraft | None,
        verdict: WordVerdict | None,
    ) -> WordDraft: ...


_INFLECTIONS = {
    "WANT": {"wants"},
    "NEED": {"needs"},
    "LIKE": {"likes"},
    "HELP": {"helps"},
    "GO": {"goes"},
    "CLEAN": {"cleans"},
    "BE": {"am", "is", "are"},
}


def validate_grounding(draft: WordDraft, utterance: TranslatedSignUtteranceV1) -> None:
    """Mechanical release gate independent of model approval.

    Deliberately conservative: novel lexical paraphrases need a reviewed extension.
    A model cannot launder an invented name/number/person/negation through an index.
    """
    if draft.unresolved_indices:
        raise WordOutputFailure("unresolved_content")
    current = {word.index: word.word for word in utterance.words}
    covered: set[int] = set()
    if not draft.candidate_text.endswith((".", "?", "!")):
        raise WordOutputFailure("unnatural_sentence")
    question_evidence = {"WHO", "WHAT", "WHERE", "WHEN", "WHY", "HOW", "QUESTION"}
    if "?" in draft.candidate_text and not question_evidence.intersection(current.values()):
        raise WordOutputFailure("unsupported_detail")
    for position, span in enumerate(draft.alignment):
        # ASCII lexical spans, with punctuation only at token boundaries; no prompt
        # markers, XML roles, markdown, emoji, controls, URLs, or hidden sentences.
        if re.fullmatch(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*[,.?!]?", span.text) is None:
            raise WordOutputFailure("invalid_alignment")
        if position != len(draft.alignment) - 1 and span.text.endswith((".", "?", "!")):
            raise WordOutputFailure("invalid_alignment")
        if any(index not in current for index in span.input_indices):
            raise WordOutputFailure("invalid_alignment")
        token = span.text.rstrip(",.?!").lower()
        if span.transformation in {"article", "auxiliary"}:
            allowed = (
                {"a", "an", "the"} if span.transformation == "article" else {"am", "is", "are"}
            )
            if token not in allowed or span.input_indices:
                raise WordOutputFailure("unsupported_detail")
        else:
            if not span.input_indices:
                raise WordOutputFailure("invalid_alignment")
            for index in span.input_indices:
                source = current[index]
                allowed = (
                    {source.lower()}
                    if span.transformation == "lexical"
                    else (_INFLECTIONS.get(source, set()))
                )
                if token not in allowed:
                    raise WordOutputFailure("unsupported_detail")
                if index in covered:
                    raise WordOutputFailure("invalid_alignment")
                covered.add(index)
    if covered != set(current):
        raise WordOutputFailure("invalid_alignment")


M = TypeVar("M", bound=BaseModel)


class WordProvider:
    def __init__(self, client: ConverseClient, model_id: str) -> None:
        self.client = client
        self.model_id = model_id
        self.prompts = {
            role: files("simplynext.agent.prompts").joinpath(f"word_{role}_v1.txt").read_text()
            for role in ("assembler", "critic")
        }
        self.system_prompts = {
            role: self.prompts[role] + "\nOutput schema:\n" + json.dumps(model.model_json_schema())
            for role, model in (("assembler", WordDraft), ("critic", WordVerdict))
        }

    def request(self, role: str, payload: dict[str, Any], schema: type[M], request_id: str) -> M:
        prompt = self.system_prompts[role]
        response = self.client.converse(
            modelId=self.model_id,
            system=[{"text": prompt}],
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"text": json.dumps(payload, ensure_ascii=True, separators=(",", ":"))}
                    ],
                }
            ],
            inferenceConfig={"maxTokens": 2200 if role == "assembler" else 300, "temperature": 0.0},
            requestMetadata={
                "simplynext_role": f"word_{role}",
                "simplynext_utterance_id": request_id,
            },
        )
        if response.get("stopReason") != "end_turn":
            raise WordOutputFailure("invalid_output")
        output = response.get("output")
        message = output.get("message") if isinstance(output, Mapping) else None
        content = message.get("content") if isinstance(message, Mapping) else None
        if not isinstance(content, list) or len(content) != 1:
            raise WordOutputFailure("invalid_output")
        block = content[0]
        if (
            not isinstance(block, Mapping)
            or set(block) != {"text"}
            or not isinstance(block["text"], str)
        ):
            raise WordOutputFailure("invalid_output")
        return parse_value(schema, block["text"], max_bytes=24_576 if role == "assembler" else 2048)


class ProviderWordAssembler:
    def __init__(self, provider: WordProvider) -> None:
        self.provider = provider

    def assemble(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        previous: WordDraft | None,
        verdict: WordVerdict | None,
    ) -> WordDraft:
        payload: dict[str, Any] = {
            "reference_context": context.assembler_view(),
            "current_evidence": {
                "producer": utterance.producer.model_dump(mode="json"),
                "words": [word.model_dump(mode="json") for word in utterance.words],
            },
        }
        if previous is not None and verdict is not None:
            payload["previous_draft"] = previous.model_dump(mode="json")
            payload["criticism"] = verdict.model_dump(mode="json")
        return self.provider.request("assembler", payload, WordDraft, str(utterance.message_id))


class TemplateWordAssembler:
    def __init__(self, templates: Mapping[tuple[str, ...], WordDraft]) -> None:
        self.templates = dict(templates)

    def assemble(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        previous: WordDraft | None,
        verdict: WordVerdict | None,
    ) -> WordDraft:
        draft = self.templates.get(tuple(word.word for word in utterance.words))
        if draft is None:
            raise WordOutputFailure("unresolved_content")
        return draft
