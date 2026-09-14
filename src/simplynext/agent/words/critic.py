"""Independent critic with a smaller context projection and no rewriting interface."""

from collections.abc import Mapping
from typing import Protocol

from simplynext.agent.words.assembler import WordProvider, validate_grounding
from simplynext.agent.words.state import WordDraft, WordVerdict
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1
from simplynext.rooms.context import ConversationContext


class WordCritic(Protocol):
    def assess(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        draft: WordDraft,
    ) -> WordVerdict: ...


class ProviderWordCritic:
    def __init__(self, provider: WordProvider) -> None:
        self.provider = provider

    def assess(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        draft: WordDraft,
    ) -> WordVerdict:
        return self.provider.request(
            "critic",
            {
                "reference_context": context.critic_view(),
                "current_evidence": {
                    "producer": utterance.producer.model_dump(mode="json"),
                    "words": [word.model_dump(mode="json") for word in utterance.words],
                },
                "draft": draft.model_dump(mode="json"),
            },
            WordVerdict,
            str(utterance.message_id),
        )


class TemplateWordCritic:
    """Deterministic release gate accepts only separately reviewed exact sentences."""

    def __init__(self, approved: Mapping[tuple[str, ...], str]) -> None:
        self.approved = dict(approved)

    def assess(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        draft: WordDraft,
    ) -> WordVerdict:
        validate_grounding(draft, utterance)
        supported = (
            self.approved.get(tuple(w.word for w in utterance.words)) == draft.candidate_text
        )
        # Exact templates can attest grammar/grounding but cannot judge relationships
        # with prior speech. Contextual acceptance requires the independent provider critic.
        has_history = bool(context.summary or context.recent_turns or context.overflow_turns)
        supported = supported and not has_history
        return WordVerdict(
            supported=supported,
            standalone_coherent=True,
            history_relation="uncertain" if has_history else "no_relevant_history",
            reference_sequences=(),
            reason_code="supported" if supported else "context_conflict",
            target_indices=(),
        )
