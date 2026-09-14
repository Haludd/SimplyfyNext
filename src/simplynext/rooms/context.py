"""Immutable stage context. Batched semantic compaction remains milestone 3."""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field, model_validator

from simplynext.contracts.translated_sign_utterance import Sequence, StrictValue


class ConversationTurn(StrictValue):
    server_sequence: Sequence
    speaker: Literal["signer", "hearing"]
    source: Literal["sign", "text", "speech"]
    text: str = Field(min_length=1, max_length=2000)


class ConversationContext(StrictValue):
    room_id: UUID
    context_version: Sequence
    summary: str = Field(default="", max_length=3200)
    recent_turns: Annotated[tuple[ConversationTurn, ...], Field(max_length=10)] = ()
    participant_aliases: Annotated[
        tuple[Annotated[str, Field(min_length=1, max_length=40)], ...], Field(max_length=2)
    ] = ()

    @model_validator(mode="after")
    def bounded_context(self) -> "ConversationContext":
        if len(self.model_dump_json().encode("utf-8")) > 96_000:
            raise ValueError("context budget exceeded")
        return self

    def critic_view(self) -> dict[str, object]:
        # The critic gets only the last two accepted turns, never a full transcript,
        # persistent memory, provider messages or assembler reasoning.
        return {
            "context_version": self.context_version,
            "recent_turns": [t.model_dump(mode="json") for t in self.recent_turns[-2:]],
        }
