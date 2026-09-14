"""Distinct bounded assembler and critic schemas for translated words."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from simplynext.contracts.room_events import Reason
from simplynext.contracts.translated_sign_utterance import StrictValue, WordIndex


class AlignmentSpan(StrictValue):
    text: str = Field(min_length=1, max_length=80)
    input_indices: Annotated[tuple[WordIndex, ...], Field(max_length=64)]
    transformation: Literal["lexical", "inflection", "article", "auxiliary"]

    @model_validator(mode="after")
    def one_span(self) -> "AlignmentSpan":
        if any(c.isspace() for c in self.text):
            raise ValueError("each span must be one output token")
        if len(set(self.input_indices)) != len(self.input_indices):
            raise ValueError("duplicate input index")
        return self


class WordDraft(StrictValue):
    schema_version: Literal["1.0"] = "1.0"
    candidate_text: str = Field(min_length=1, max_length=500)
    tts_text: Annotated[str, Field(min_length=1, max_length=500)] | None = None
    alignment: Annotated[tuple[AlignmentSpan, ...], Field(min_length=1, max_length=128)]
    unresolved_indices: Annotated[tuple[WordIndex, ...], Field(max_length=64)] = ()

    @model_validator(mode="after")
    def exact_rendering(self) -> "WordDraft":
        if self.candidate_text != " ".join(span.text for span in self.alignment):
            raise ValueError("alignment must render the exact candidate")
        if self.tts_text is not None and self.tts_text != self.candidate_text:
            raise ValueError("TTS cannot differ from candidate")
        if len(set(self.unresolved_indices)) != len(self.unresolved_indices):
            raise ValueError("duplicate unresolved index")
        return self


class WordVerdict(StrictValue):
    schema_version: Literal["1.0"] = "1.0"
    supported: bool
    reason_code: Literal["supported"] | Reason
    target_indices: Annotated[tuple[WordIndex, ...], Field(max_length=64)]
    revision_instruction: (
        Literal[
            "remove_unsupported_detail",
            "fix_alignment",
            "improve_grammar",
            "abstain",
        ]
        | None
    ) = None

    @model_validator(mode="after")
    def consistent_verdict(self) -> "WordVerdict":
        if self.supported:
            if self.reason_code != "supported" or self.target_indices or self.revision_instruction:
                raise ValueError("supported verdict cannot contain criticism")
        elif self.reason_code == "supported":
            raise ValueError("unsupported verdict needs a reason")
        if len(set(self.target_indices)) != len(self.target_indices):
            raise ValueError("duplicate target index")
        return self
