"""Producer-specific word admission policy and in-process agent composition."""

from pathlib import Path
from typing import Annotated, Literal

from pydantic import Field, model_validator

from simplynext.agent.words.assembler import (
    ConverseClient,
    ProviderWordAssembler,
    TemplateWordAssembler,
    WordProvider,
)
from simplynext.agent.words.critic import ProviderWordCritic, TemplateWordCritic
from simplynext.agent.words.graph import WordGraph
from simplynext.agent.words.repair import repair
from simplynext.agent.words.state import WordDraft
from simplynext.config import Settings
from simplynext.contracts.room_events import RepairOutcome, TerminalOutcome
from simplynext.contracts.translated_sign_utterance import (
    Score,
    StrictValue,
    TranslatedSignUtteranceV1,
    Word,
    WordProducer,
    parse_value,
)
from simplynext.rooms.context import ConversationContext


class WordPolicy(StrictValue):
    schema_version: Literal["1.0"]
    producer: WordProducer
    evaluation_id: str = Field(min_length=1, max_length=80)
    purpose: Literal["synthetic_evaluation", "producer_evaluated"]
    vocabulary: Annotated[tuple[Word, ...], Field(min_length=1, max_length=512)]
    min_score: Score
    min_margin: Score

    @model_validator(mode="after")
    def unique_vocabulary(self) -> "WordPolicy":
        if len(set(self.vocabulary)) != len(self.vocabulary):
            raise ValueError("duplicate vocabulary word")
        return self

    def check(self, utterance: TranslatedSignUtteranceV1) -> RepairOutcome | None:
        if utterance.producer != self.producer:
            return repair("policy_unconfigured")
        for word in utterance.words:
            if any(
                w not in self.vocabulary for w in (word.word, *(a.word for a in word.alternatives))
            ):
                return repair("unsupported_vocabulary", (word.index,))
            if word.confidence <= 0 or word.confidence < self.min_score:
                return repair("low_score", (word.index,))
            if word.alternatives and (
                word.confidence <= word.alternatives[0].confidence
                or word.confidence - word.alternatives[0].confidence < self.min_margin
            ):
                return repair("ambiguous_words", (word.index,))
        return None


class TemplateEntry(StrictValue):
    words: Annotated[tuple[Word, ...], Field(min_length=1, max_length=64)]
    draft: WordDraft


class WordTemplates(StrictValue):
    schema_version: Literal["1.0"]
    templates: Annotated[tuple[TemplateEntry, ...], Field(max_length=1000)]

    @model_validator(mode="after")
    def unique_templates(self) -> "WordTemplates":
        if len({entry.words for entry in self.templates}) != len(self.templates):
            raise ValueError("duplicate word template")
        return self


class WordTranslationEngine:
    def __init__(self, graph: WordGraph, policy: WordPolicy | None) -> None:
        self.graph = graph
        self.policy = policy

    async def process(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
    ) -> TerminalOutcome:
        if self.policy is None:
            return repair("policy_unconfigured")
        decision = self.policy.check(utterance)
        if decision is not None:
            return decision
        return await self.graph.run(utterance, context, policy_version=self.policy.evaluation_id)


def build_word_translation_engine(
    settings: Settings,
    client: ConverseClient | None = None,
) -> WordTranslationEngine:
    policy = (
        None
        if settings.word_policy_path is None
        else parse_value(
            WordPolicy,
            settings.word_policy_path.read_bytes(),
            max_bytes=65_536,
        )
    )
    if (
        settings.environment == "production"
        and policy is not None
        and (policy.purpose != "producer_evaluated")
    ):
        raise ValueError("production requires producer-evaluated word policy")
    if settings.bedrock_enabled or settings.anthropic_enabled:
        if client is None:
            raise ValueError("hosted word translation requires the shared cost-guarded client")
        model_id = (
            settings.anthropic_model_id if settings.anthropic_enabled else settings.bedrock_model_id
        )
        provider = WordProvider(client, model_id)
        graph = WordGraph(
            ProviderWordAssembler(provider),
            ProviderWordCritic(provider),
            model_version=model_id,
            max_revisions=settings.agent_max_revisions,
            max_concurrent_calls=settings.max_concurrent_agent_runs,
        )
    else:
        templates = load_word_templates(settings.word_templates_path)
        graph = WordGraph(
            TemplateWordAssembler(templates),
            TemplateWordCritic({key: draft.candidate_text for key, draft in templates.items()}),
            model_version="word_templates_v1",
            max_revisions=settings.agent_max_revisions,
            max_concurrent_calls=settings.max_concurrent_agent_runs,
        )
    return WordTranslationEngine(graph, policy)


def load_word_templates(path: Path | None) -> dict[tuple[str, ...], WordDraft]:
    if path is None:
        return {}
    document = parse_value(WordTemplates, path.read_bytes(), max_bytes=2_000_000)
    return {entry.words: entry.draft for entry in document.templates}
