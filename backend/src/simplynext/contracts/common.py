"""Shared types for versioned API contracts."""

from __future__ import annotations

from enum import StrEnum
from typing import Annotated, Final

from pydantic import BaseModel, ConfigDict, Field, StringConstraints


class ContractModel(BaseModel):
    """Base for wire models: reject unknown fields and remain immutable."""

    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        str_strip_whitespace=True,
        validate_default=True,
    )


class SignLanguage(StrEnum):
    """Sign-language modes supported by the first-draft protocol."""

    SGSL = "sgsl"
    ASL = "asl"


MAX_IDENTIFIER_CHARACTERS: Final[int] = 128

Confidence = Annotated[float, Field(ge=0.0, le=1.0, allow_inf_nan=False)]
Identifier = Annotated[
    str,
    StringConstraints(
        min_length=1,
        max_length=MAX_IDENTIFIER_CHARACTERS,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:-]*$",
    ),
]
