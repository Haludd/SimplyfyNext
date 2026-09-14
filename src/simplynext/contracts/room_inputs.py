"""Room v1 negotiation and browser-safe controls."""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field, StringConstraints, field_validator

from simplynext.contracts.translated_sign_utterance import Sequence, StrictValue

RoomCode = Annotated[str, StringConstraints(pattern=r"^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$")]
Alias = Annotated[str, StringConstraints(min_length=1, max_length=40)]
Text = Annotated[str, StringConstraints(min_length=1, max_length=2000)]


class CreateRoom(StrictValue):
    schema_version: Literal["1.0"]
    event_schema_version: Literal["1.0"]
    alias: Alias


class JoinRoom(CreateRoom):
    code: RoomCode


class TextMessage(StrictValue):
    schema_version: Literal["1.0"]
    message_id: UUID
    client_sequence: Sequence
    source: Literal["text", "speech"]
    text: Text

    @field_validator("text")
    @classmethod
    def nonblank(cls, value: str) -> str:
        if not value.strip() or any(ord(c) < 32 and c not in "\n\t" for c in value):
            raise ValueError("text must be printable and nonempty")
        return value


class Authenticate(StrictValue):
    type: Literal["authenticate"]
    event_schema_version: Literal["1.0"]
    token: str = Field(min_length=32, max_length=128)


class Activity(StrictValue):
    type: Literal["activity"]
    state: Literal["idle", "typing", "listening", "signing"]


class EndRoom(StrictValue):
    type: Literal["end"]


class Ping(StrictValue):
    type: Literal["ping"]


SocketInput = Annotated[Activity | EndRoom | Ping, Field(discriminator="type")]
