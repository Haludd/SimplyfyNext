"""Frozen ASL-to-English lexical ingress with strict semantic validation."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Annotated, Any, Literal, Self, TypeVar
from uuid import UUID

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)

MAX_UTTERANCE_BYTES = 16_384
MAX_SEQUENCE = 9_007_199_254_740_991


class StrictValue(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
        allow_inf_nan=False,
        str_strip_whitespace=False,
        validate_default=True,
    )


Word = Annotated[
    str,
    StringConstraints(
        min_length=1,
        max_length=80,
        pattern=r"^[A-Z0-9]+(?:['-][A-Z0-9]+)*$",
    ),
]
TokenId = Annotated[
    str,
    StringConstraints(
        min_length=1,
        max_length=80,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$",
    ),
]
Score = Annotated[float, Field(ge=0, le=1, allow_inf_nan=False)]


def json_integer(value: object) -> object:
    # JSON Schema integer is a mathematical value, so 0 and 0.0 have identical
    # semantics. Keep strings/booleans forbidden while canonicalizing integral
    # JSON numbers, including ranks and indices, for exact-retry digests.
    if type(value) is float and value.is_integer():
        return int(value)
    return value


Sequence = Annotated[int, Field(ge=0, le=MAX_SEQUENCE), BeforeValidator(json_integer)]
WordIndex = Annotated[int, Field(ge=0, le=63), BeforeValidator(json_integer)]


class WordProducer(StrictValue):
    recognizer_id: Literal[
        "signchat_asl_signs_onnx",
        "personal_landmark_templates",
        "signbridge_local_recognizers",
    ]
    recognizer_version: Literal[
        "signchat_asl_signs_onnx",
        "personal_landmark_templates_v1",
        "signbridge_local_recognizers_v1",
    ]
    translator_id: Literal["asl_label_to_english"]
    translator_version: Literal["1.0.0"]
    vocabulary_version: Literal[
        "popsign_250_en_v1",
        "personal_signs_local_v1",
        "popsign_250_plus_personal_v1",
    ]
    confidence_kind: Literal["normalized_model_score"]

    @model_validator(mode="after")
    def supported_profile(self) -> Self:
        profile = (self.recognizer_id, self.recognizer_version, self.vocabulary_version)
        if profile not in {
            ("signchat_asl_signs_onnx", "signchat_asl_signs_onnx", "popsign_250_en_v1"),
            (
                "personal_landmark_templates",
                "personal_landmark_templates_v1",
                "personal_signs_local_v1",
            ),
            (
                "signbridge_local_recognizers",
                "signbridge_local_recognizers_v1",
                "popsign_250_plus_personal_v1",
            ),
        }:
            raise ValueError("unsupported producer profile")
        return self

    @property
    def includes_personal_vocabulary(self) -> bool:
        return self.recognizer_id in {
            "personal_landmark_templates",
            "signbridge_local_recognizers",
        }


class WordAlternative(StrictValue):
    rank: Annotated[int, Field(ge=2, le=5), BeforeValidator(json_integer)]
    word: Word
    confidence: Score


class WordToken(StrictValue):
    index: WordIndex
    token_id: TokenId
    word: Word
    confidence: Score
    alternatives: Annotated[tuple[WordAlternative, ...], Field(max_length=4)]

    @model_validator(mode="after")
    def ordered_alternatives(self) -> Self:
        if [a.rank for a in self.alternatives] != list(range(2, len(self.alternatives) + 2)):
            raise ValueError("alternative ranks must be contiguous from two")
        words = [self.word, *(a.word for a in self.alternatives)]
        if len(set(words)) != len(words):
            raise ValueError("primary and alternative words must be unique")
        scores = [self.confidence, *(a.confidence for a in self.alternatives)]
        if scores != sorted(scores, reverse=True):
            raise ValueError("scores must be non-increasing")
        return self


class TranslatedSignUtteranceV1(StrictValue):
    type: Literal["translated_sign_utterance"]
    schema_version: Literal["1.0"]
    message_id: UUID
    client_sequence: Sequence
    source_language: Literal["asl"]
    target_language: Literal["en"]
    is_final: Literal[True]
    completion_reason: Literal["user_commit"]
    producer: WordProducer
    words: Annotated[tuple[WordToken, ...], Field(min_length=1, max_length=64)]

    @field_validator("message_id", mode="before")
    @classmethod
    def uuid_format(cls, value: object) -> object:
        # UUID JSON Schema format uses the hyphenated RFC representation, not UUID's
        # more permissive URN/braced/hex-only Python parsing forms.
        if (
            isinstance(value, str)
            and re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value) is None
        ):
            raise ValueError("message_id must use UUID format")
        return value

    @field_validator("is_final", mode="before")
    @classmethod
    def real_boolean(cls, value: object) -> object:
        if value is not True:
            raise ValueError("is_final must be the JSON boolean true")
        return value

    @model_validator(mode="after")
    def ordered_words(self) -> Self:
        if [word.index for word in self.words] != list(range(len(self.words))):
            raise ValueError("word indices must be contiguous from zero")
        if len({word.token_id for word in self.words}) != len(self.words):
            raise ValueError("token IDs must be unique")
        return self


T = TypeVar("T", bound=BaseModel)


def strict_json(raw: str | bytes, *, max_bytes: int = MAX_UTTERANCE_BYTES) -> Any:
    """Reject invalid UTF-8, duplicate keys and nonfinite JSON before model parsing."""
    encoded = raw.encode("utf-8") if isinstance(raw, str) else raw
    if len(encoded) > max_bytes:
        raise ValueError("payload_too_large")

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    def nonfinite(value: str) -> None:
        raise ValueError("nonfinite JSON number")

    return json.loads(encoded.decode("utf-8"), object_pairs_hook=pairs, parse_constant=nonfinite)


def parse_value(model: type[T], raw: str | bytes, *, max_bytes: int = MAX_UTTERANCE_BYTES) -> T:
    value = strict_json(raw, max_bytes=max_bytes)
    # JSON-mode preserves strict arrays/UUIDs while rejecting coercible wire numbers.
    return model.model_validate_json(json.dumps(value, allow_nan=False))


def canonical_digest(value: BaseModel) -> str:
    encoded = json.dumps(
        value.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()
