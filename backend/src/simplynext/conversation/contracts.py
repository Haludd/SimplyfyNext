"""Version 1 conversation and words-only translation contracts."""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class Value(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, allow_inf_nan=False)


class ParticipantInput(Value):
    name: str = Field(min_length=1, max_length=40)
    mode: Literal["sign", "speech"] = "sign"


class JoinInput(ParticipantInput):
    code: str = Field(pattern=r"^[A-Z2-9]{6}$")


class Word(Value):
    word: str = Field(min_length=1, max_length=80)
    confidence: float = Field(strict=True, ge=0, le=1)


class WordsInput(Value):
    message_id: UUID
    words: list[Word] = Field(min_length=1, max_length=64)


class TextInput(Value):
    message_id: UUID
    text: str = Field(min_length=1, max_length=2000)
    source: Literal["text", "speech"] = "text"


class TranslationResult(Value):
    status: Literal["accepted", "repair"]
    text: str | None = Field(default=None, min_length=1, max_length=2000)
    prompt: str | None = Field(default=None, min_length=1, max_length=500)

    @model_validator(mode="after")
    def validate_outcome(self) -> "TranslationResult":
        if self.status == "accepted" and (self.text is None or self.prompt is not None):
            raise ValueError("accepted results require text only")
        if self.status == "repair" and (self.prompt is None or self.text is not None):
            raise ValueError("repair results require prompt only")
        return self


class Authenticate(Value):
    type: Literal["authenticate"]
    token: str = Field(min_length=32, max_length=128)


class Activity(Value):
    type: Literal["activity"]
    state: Literal["idle", "typing", "listening", "signing"]


class Ping(Value):
    type: Literal["ping"]


SocketInput = Annotated[Activity | Ping, Field(discriminator="type")]
