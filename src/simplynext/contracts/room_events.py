"""Frozen room events: processing/accepted/repair are disjoint wire shapes."""

from typing import Annotated, Literal, TypeAlias
from uuid import UUID

from pydantic import Field, TypeAdapter, model_validator

from simplynext.contracts.room_inputs import Alias, RoomCode, Text
from simplynext.contracts.translated_sign_utterance import Score, Sequence, StrictValue, WordIndex

RepairAction = Literal[
    "ask_repeat",
    "offer_alternatives",
    "request_fingerspelling",
    "ask_type",
    "escalate_human_interpreter",
]
Reason = Literal[
    "policy_unconfigured",
    "unsupported_vocabulary",
    "low_score",
    "ambiguous_words",
    "unresolved_content",
    "unsupported_detail",
    "invalid_alignment",
    "unnatural_sentence",
    "context_conflict",
    "invalid_output",
    "provider_failure",
    "timeout",
    "cancelled",
    "capacity",
    "revision_exhausted",
]


class AcceptedOutcome(StrictValue):
    status: Literal["accepted"] = "accepted"
    text: Annotated[str, Field(min_length=1, max_length=500)]
    tts_text: Annotated[str, Field(min_length=1, max_length=500)] | None = None
    confidence: Score
    confidence_kind: Literal["normalized_model_score"] = "normalized_model_score"
    model_version: str = Field(min_length=1, max_length=128)
    policy_version: str = Field(min_length=1, max_length=80)

    @model_validator(mode="after")
    def identical_tts(self) -> "AcceptedOutcome":
        if self.tts_text is not None and self.tts_text != self.text:
            raise ValueError("TTS must be the approved sentence")
        return self


class RepairOutcome(StrictValue):
    status: Literal["repair"] = "repair"
    action: RepairAction
    prompt: str = Field(min_length=1, max_length=240)
    reason_code: Reason
    target_indices: Annotated[tuple[WordIndex, ...], Field(max_length=64)] = ()


TerminalOutcome: TypeAlias = Annotated[
    AcceptedOutcome | RepairOutcome, Field(discriminator="status")
]


class MessageBase(StrictValue):
    message_id: UUID
    sender_id: UUID
    client_sequence: Sequence
    server_sequence: Sequence
    context_version: Sequence
    source: Literal["sign", "text", "speech"]


class ProcessingMessage(MessageBase):
    source: Literal["sign"] = "sign"
    status: Literal["processing"] = "processing"


class AcceptedMessage(MessageBase):
    status: Literal["accepted"] = "accepted"
    text: Text
    translation: AcceptedOutcome | None = None


class RepairMessage(MessageBase):
    source: Literal["sign"] = "sign"
    status: Literal["repair"] = "repair"
    repair: RepairOutcome


RoomMessage: TypeAlias = Annotated[
    ProcessingMessage | AcceptedMessage | RepairMessage,
    Field(discriminator="status"),
]


class UtteranceAck(StrictValue):
    event_schema_version: Literal["1.0"] = "1.0"
    type: Literal["utterance_ack"] = "utterance_ack"
    message_id: UUID
    client_sequence: Sequence
    server_sequence: Sequence
    disposition: Literal["accepted", "cached"]


class RoomCredentials(StrictValue):
    event_schema_version: Literal["1.0"] = "1.0"
    utterance_schema_version: Literal["1.0"] = "1.0"
    code: RoomCode
    participant_id: UUID
    role: Literal["signer", "hearing"]
    token: str
    join_path: str  # Public invitation; never contains a capability.


class ParticipantView(StrictValue):
    participant_id: UUID
    role: Literal["signer", "hearing"]
    alias: Alias
    online: bool


class EventBase(StrictValue):
    event_schema_version: Literal["1.0"] = "1.0"
    room_version: Sequence


class RoomSnapshot(EventBase):
    type: Literal["snapshot"] = "snapshot"
    code: RoomCode
    state: Literal["waiting", "active"]
    context_version: Sequence
    participants: Annotated[tuple[ParticipantView, ...], Field(min_length=1, max_length=2)]
    messages: Annotated[tuple[RoomMessage, ...], Field(max_length=300)]


class MessageUpsert(EventBase):
    type: Literal["message_upsert"] = "message_upsert"
    message: RoomMessage


class PresenceEvent(EventBase):
    type: Literal["presence"] = "presence"
    participant: ParticipantView


class ActivityEvent(EventBase):
    type: Literal["activity"] = "activity"
    participant_id: UUID
    state: Literal["idle", "typing", "listening", "signing"]


class RoomEnded(EventBase):
    type: Literal["room_ended"] = "room_ended"


class RoomError(EventBase):
    type: Literal["error"] = "error"
    code: Literal["resync_required", "invalid_control", "rate_limited"]


class Pong(EventBase):
    type: Literal["pong"] = "pong"


RoomEvent: TypeAlias = Annotated[
    RoomSnapshot | MessageUpsert | PresenceEvent | ActivityEvent | RoomEnded | RoomError | Pong,
    Field(discriminator="type"),
]
ROOM_EVENT_ADAPTER: TypeAdapter[RoomEvent] = TypeAdapter(RoomEvent)
