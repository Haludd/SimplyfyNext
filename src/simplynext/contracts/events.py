"""Server-to-client WebSocket event contracts."""

from __future__ import annotations

from enum import StrEnum
from typing import Annotated, Literal, TypeAlias
from uuid import UUID

from pydantic import ConfigDict, Field, model_validator

from .common import Confidence, ContractModel, Identifier
from .gloss_lattice import (
    MAX_GLOSS_CANDIDATES,
    MAX_GLOSS_LATTICE_SLOTS,
    GlossCandidate,
    GlossProvenance,
    GlossSlot,
)

LATTICE_EVENT_SCHEMA_VERSION: Literal["1.0"] = "1.0"
MAX_SAFE_EVENT_INTEGER = 9_007_199_254_740_991
EventSequence = Annotated[int, Field(ge=0, le=MAX_SAFE_EVENT_INTEGER)]
EventTimestampMs = Annotated[int, Field(ge=0, le=MAX_SAFE_EVENT_INTEGER)]


class ActivityState(StrEnum):
    IDLE = "idle"
    PROCESSING = "processing"


class ErrorCode(StrEnum):
    INVALID_MESSAGE = "invalid_message"
    UNAUTHORIZED = "unauthorized"
    SESSION_NOT_FOUND = "session_not_found"
    SESSION_EXPIRED = "session_expired"
    INVALID_SESSION_STATE = "invalid_session_state"
    NON_MONOTONIC_SEQUENCE = "non_monotonic_sequence"
    RATE_LIMITED = "rate_limited"
    INTERNAL_ERROR = "internal_error"


class _LatticeEventModel(ContractModel):
    """Strict base for the separately versioned lattice response protocol."""

    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
        str_strip_whitespace=False,
        validate_default=True,
    )


class LatticeAckDisposition(StrEnum):
    """Whether a submission was newly accepted or served from replay state."""

    ACCEPTED = "accepted"
    CACHED = "cached"


class LatticeRepairAction(StrEnum):
    """Graph-native, non-guessing repair actions exposed by lattice events."""

    ASK_REPEAT = "ask_repeat"
    REQUEST_FINGERSPELLING = "request_fingerspelling"
    OFFER_TOP_K = "offer_top_k"
    ESCALATE_HUMAN_INTERPRETER = "escalate_human_interpreter"


class _LatticeEventEnvelope(_LatticeEventModel):
    """Correlation fields carried by every server-to-client lattice event."""

    event_schema_version: Literal["1.0"] = LATTICE_EVENT_SCHEMA_VERSION
    session_id: UUID


class LatticeAckEvent(_LatticeEventEnvelope):
    """Acknowledgement after a lattice is atomically accepted or replayed."""

    type: Literal["lattice_ack"] = "lattice_ack"
    lattice_seq: EventSequence
    utterance_id: Identifier
    disposition: LatticeAckDisposition
    server_ms: EventTimestampMs


class LatticeActivityEvent(_LatticeEventEnvelope):
    """Server processing state for the lattice channel."""

    type: Literal["activity"] = "activity"
    state: ActivityState
    lattice_seq: EventSequence | None = None
    utterance_id: Identifier | None = None
    server_ms: EventTimestampMs

    @model_validator(mode="after")
    def validate_correlation(self) -> LatticeActivityEvent:
        correlated = (self.lattice_seq is not None, self.utterance_id is not None)
        if correlated[0] is not correlated[1]:
            raise ValueError("lattice_seq and utterance_id must be supplied together")
        if self.state is ActivityState.PROCESSING and not correlated[0]:
            raise ValueError("processing activity requires lattice correlation")
        return self


class LatticePongEvent(_LatticeEventEnvelope):
    """Response to one lattice-channel ping control message."""

    type: Literal["pong"] = "pong"
    control_seq: EventSequence
    server_ms: EventTimestampMs


class LatticeErrorEvent(_LatticeEventEnvelope):
    """Machine-readable lattice-channel failure without an invented result."""

    type: Literal["error"] = "error"
    code: ErrorCode
    message: str = Field(min_length=1, max_length=500)
    retryable: bool = False
    lattice_seq: EventSequence | None = None
    utterance_id: Identifier | None = None

    @model_validator(mode="after")
    def validate_correlation(self) -> LatticeErrorEvent:
        if (self.lattice_seq is None) is not (self.utterance_id is None):
            raise ValueError("lattice_seq and utterance_id must be supplied together")
        return self


class LatticeEvidenceTrace(_LatticeEventModel):
    """One complete, slot-scoped classifier decision returned for audit and UI."""

    slot_index: int = Field(ge=0, lt=MAX_GLOSS_LATTICE_SLOTS)
    slot_id: Identifier
    start_ms: EventTimestampMs
    end_ms: EventTimestampMs
    resolved_gloss_id: Identifier | None
    confidence: Confidence | None
    provenance: GlossProvenance
    candidates: Annotated[
        tuple[GlossCandidate, ...],
        Field(max_length=MAX_GLOSS_CANDIDATES),
    ]

    @model_validator(mode="after")
    def validate_evidence(self) -> LatticeEvidenceTrace:
        slot = GlossSlot(
            slot_index=self.slot_index,
            slot_id=self.slot_id,
            start_ms=self.start_ms,
            end_ms=self.end_ms,
            candidates=self.candidates,
            resolved_gloss_id=self.resolved_gloss_id,
            provenance=self.provenance,
        )
        resolved_candidate = next(
            (
                candidate
                for candidate in slot.candidates
                if candidate.gloss_id == slot.resolved_gloss_id
            ),
            None,
        )
        if slot.provenance is GlossProvenance.UNRESOLVED:
            if self.confidence is not None:
                raise ValueError("unresolved evidence cannot contain confidence")
        elif resolved_candidate is None:
            if self.confidence is not None:
                raise ValueError("out-of-vocabulary evidence cannot contain classifier confidence")
        elif self.confidence != resolved_candidate.confidence:
            raise ValueError("evidence confidence must match the resolved candidate")
        return self


class LatticeChoice(_LatticeEventModel):
    """One retained, slot-scoped option that the signer may select."""

    slot_id: Identifier
    rank: int = Field(ge=1, le=MAX_GLOSS_CANDIDATES)
    gloss_id: Identifier
    confidence: Confidence


class _LatticeTerminalEvent(_LatticeEventEnvelope):
    """Fields shared by the two mutually exclusive lattice outcomes."""

    lattice_seq: EventSequence
    utterance_id: Identifier
    evidence_trace: Annotated[
        tuple[LatticeEvidenceTrace, ...],
        Field(min_length=1, max_length=MAX_GLOSS_LATTICE_SLOTS),
    ]
    classifier_version: Identifier
    agent_source: Identifier | None = None
    agent_model_version: Identifier | None = None
    latency_ms: dict[Identifier, EventTimestampMs] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_trace(self) -> _LatticeTerminalEvent:
        expected_indices = tuple(range(len(self.evidence_trace)))
        actual_indices = tuple(item.slot_index for item in self.evidence_trace)
        if actual_indices != expected_indices:
            raise ValueError("evidence_trace slot_index values must be contiguous and ordered")
        slot_ids = tuple(item.slot_id for item in self.evidence_trace)
        if len(slot_ids) != len(set(slot_ids)):
            raise ValueError("evidence_trace slot_id values must be unique")
        return self


class LatticeResultEvent(_LatticeTerminalEvent):
    """Confident display/TTS text with the exact structured evidence that supports it."""

    type: Literal["lattice_result"] = "lattice_result"
    status: Literal["confident"] = "confident"
    caption: str = Field(min_length=1, max_length=500)
    tts_text: str | None = Field(default=None, min_length=1, max_length=500)
    confidence: Confidence
    gloss_id_trace: Annotated[
        tuple[Identifier, ...],
        Field(min_length=1, max_length=MAX_GLOSS_LATTICE_SLOTS),
    ]

    @model_validator(mode="after")
    def validate_confident_result(self) -> LatticeResultEvent:
        if any(item.provenance is GlossProvenance.UNRESOLVED for item in self.evidence_trace):
            raise ValueError("a confident result cannot contain unresolved evidence")
        resolved_trace = tuple(
            item.resolved_gloss_id
            for item in self.evidence_trace
            if item.resolved_gloss_id is not None
        )
        if self.gloss_id_trace != resolved_trace:
            raise ValueError("gloss_id_trace must exactly match the resolved evidence trace")
        return self


class LatticeRepairRequiredEvent(_LatticeTerminalEvent):
    """Fail-closed repair instruction carrying no caption or TTS text."""

    type: Literal["lattice_repair_required"] = "lattice_repair_required"
    status: Literal["uncertain"] = "uncertain"
    repair_id: Identifier
    action: LatticeRepairAction
    message: str = Field(min_length=1, max_length=500)
    confidence: Confidence
    target_slot_ids: tuple[Identifier, ...] = ()
    choices: tuple[LatticeChoice, ...] = ()
    reason_codes: tuple[Identifier, ...] = ()

    @model_validator(mode="after")
    def validate_repair(self) -> LatticeRepairRequiredEvent:
        trace_by_slot_id = {item.slot_id: item for item in self.evidence_trace}
        if len(self.target_slot_ids) != len(set(self.target_slot_ids)):
            raise ValueError("target_slot_ids must be unique")
        if any(slot_id not in trace_by_slot_id for slot_id in self.target_slot_ids):
            raise ValueError("target_slot_ids must identify evidence_trace slots")

        if self.action is LatticeRepairAction.OFFER_TOP_K:
            if len(self.target_slot_ids) != 1 or not self.choices:
                raise ValueError("offer_top_k requires one target slot and at least one choice")
            target_slot_id = self.target_slot_ids[0]
            retained = {
                (candidate.rank, candidate.gloss_id, candidate.confidence)
                for candidate in trace_by_slot_id[target_slot_id].candidates
            }
            offered = tuple(
                (choice.rank, choice.gloss_id, choice.confidence) for choice in self.choices
            )
            if any(choice.slot_id != target_slot_id for choice in self.choices):
                raise ValueError("offer_top_k choices must belong to the target slot")
            if any(choice not in retained for choice in offered):
                raise ValueError("offer_top_k choices must exactly match retained candidates")
            if len(offered) != len(set(offered)):
                raise ValueError("offer_top_k choices must be unique")
        elif self.choices:
            raise ValueError("only offer_top_k may contain choices")
        return self


LatticeOutboundEvent: TypeAlias = Annotated[
    LatticeAckEvent
    | LatticeActivityEvent
    | LatticePongEvent
    | LatticeErrorEvent
    | LatticeResultEvent
    | LatticeRepairRequiredEvent,
    Field(discriminator="type"),
]
LatticeTerminalEvent: TypeAlias = LatticeResultEvent | LatticeRepairRequiredEvent
