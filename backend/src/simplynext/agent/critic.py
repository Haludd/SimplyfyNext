"""Token-level evidence critic for stage ⑦."""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Any, Final, Literal, Protocol, cast

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    JsonValue,
    StringConstraints,
    ValidationError,
    model_validator,
)

from simplynext.agent.assembler import (
    AssemblerDraft,
    DraftEvidence,
    SupportedTextPart,
    validate_draft_for_lattice,
)
from simplynext.agent.graph import AgentGraphState, AllowedToolExecutor, CriticVerdict
from simplynext.contracts.common import Identifier
from simplynext.contracts.gloss_lattice import GlossLattice
from simplynext.observability.metrics import MetricsRegistry

CRITIC_ASSESSMENT_SCHEMA_VERSION: Final = "1.0"
DEFAULT_CRITIC_PROMPT_PATH: Final = Path(__file__).with_name("prompts") / "critic_v1.txt"
MAX_CRITIC_TOKENS: Final = 512
MAX_CRITIC_RESPONSE_CHARACTERS: Final = 32_768

CriticTokenText = Annotated[str, StringConstraints(min_length=1, max_length=160)]
CriticReason = Annotated[str, StringConstraints(min_length=1, max_length=240)]

_REQUIRED_CRITIC_PROMPT_FRAGMENTS: Final = (
    "One question: is every candidate token supported",
    "Do not revise, translate, improve, or complete",
    "Every whitespace-delimited candidate token",
    "Overall supported must be true if and only if every token assessment is supported.",
    "Return exactly one JSON object",
)

logger = logging.getLogger(__name__)


class CriticOutputError(ValueError):
    """Raised internally when the critic response is not a valid assessment."""


class CriticGroundingError(CriticOutputError):
    """Raised internally when an assessment escapes the draft's evidence envelope."""


class CriticTokenKind(StrEnum):
    """Kind of exact candidate token presented to the critic."""

    SPOKEN_TEXT = "spoken_text"
    GAP_MARKER = "gap_marker"


class _CriticValue(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
        str_strip_whitespace=False,
        validate_default=True,
    )


class CriticTokenAssessment(_CriticValue):
    """The critic's evidence decision for one exact candidate surface token."""

    token_index: int = Field(strict=True, ge=0, lt=MAX_CRITIC_TOKENS)
    token: CriticTokenText
    supported: bool
    evidence: Annotated[tuple[DraftEvidence, ...], Field(max_length=64)] = ()
    reason: CriticReason

    @model_validator(mode="after")
    def validate_token_and_evidence(self) -> CriticTokenAssessment:
        if self.token != self.token.strip() or any(character.isspace() for character in self.token):
            raise ValueError("critic token must be one exact whitespace-delimited token")
        if self.reason != self.reason.strip():
            raise ValueError("critic token reason must not have surrounding whitespace")
        evidence_keys = [(item.slot_id, item.gloss_id) for item in self.evidence]
        if len(evidence_keys) != len(set(evidence_keys)):
            raise ValueError("critic token evidence cannot contain duplicates")
        return self


class CriticAssessment(_CriticValue):
    """Strict token-by-token response produced by the separate critic agent."""

    schema_version: Literal["1.0"]
    utterance_id: Identifier
    supported: bool
    token_assessments: Annotated[
        tuple[CriticTokenAssessment, ...],
        Field(min_length=1, max_length=MAX_CRITIC_TOKENS),
    ]

    @model_validator(mode="after")
    def validate_complete_and_consistent_verdict(self) -> CriticAssessment:
        indices = [item.token_index for item in self.token_assessments]
        if indices != list(range(len(indices))):
            raise ValueError("critic token indices must be contiguous and ordered from zero")
        if self.supported is not all(item.supported for item in self.token_assessments):
            raise ValueError("critic verdict must equal the conjunction of all token assessments")
        return self


class LatticeCriticClient(Protocol):
    """Minimal Bedrock Converse-compatible client used only by the critic node."""

    def converse(self, **kwargs: Any) -> Mapping[str, Any]:
        """Submit one critic request and return the provider response."""

        ...


@dataclass(frozen=True, slots=True)
class LatticeCriticConfig:
    """Configuration for one bounded, single-purpose critic call."""

    model_id: str
    max_tokens: int = 1_200
    temperature: float = 0.0
    max_candidate_tokens: int = 256
    max_response_characters: int = MAX_CRITIC_RESPONSE_CHARACTERS
    prompt_path: Path = DEFAULT_CRITIC_PROMPT_PATH

    def __post_init__(self) -> None:
        if not self.model_id or self.model_id != self.model_id.strip():
            raise ValueError("model_id must be non-empty without surrounding whitespace")
        if type(self.max_tokens) is not int or self.max_tokens <= 0:
            raise ValueError("max_tokens must be a positive integer")
        if type(self.temperature) not in (int, float) or not 0 <= self.temperature <= 1:
            raise ValueError("temperature must be between 0 and 1")
        if (
            type(self.max_candidate_tokens) is not int
            or not 1 <= self.max_candidate_tokens <= MAX_CRITIC_TOKENS
        ):
            raise ValueError(
                f"max_candidate_tokens must be an integer from 1 to {MAX_CRITIC_TOKENS}"
            )
        if type(self.max_response_characters) is not int or self.max_response_characters <= 0:
            raise ValueError("max_response_characters must be a positive integer")
        if not isinstance(self.prompt_path, Path):
            raise TypeError("prompt_path must be a pathlib.Path")


@dataclass(frozen=True, slots=True)
class _ExpectedToken:
    token_index: int
    token: str
    kind: CriticTokenKind
    evidence: tuple[DraftEvidence, ...]
    gap_slot_id: str | None = None


class BedrockLatticeCriticNode:
    """Separate stage ⑦ agent that can only assess candidate grounding."""

    def __init__(
        self,
        *,
        client: LatticeCriticClient,
        config: LatticeCriticConfig,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._client = client
        self._config = config
        self._metrics = metrics
        self._system_prompt = _load_critic_prompt(config.prompt_path)

    @property
    def prompt_path(self) -> Path:
        """Expose the critic's independent versioned prompt path."""

        return self._config.prompt_path

    def __call__(
        self,
        state: AgentGraphState,
        tools: AllowedToolExecutor,
    ) -> CriticVerdict:
        """Adapt the critic to the T5.2 graph callback contract."""

        del tools
        raw_draft = state.get("draft")
        if raw_draft is None:
            return self._reject("critic_input_missing")
        try:
            draft = AssemblerDraft.model_validate_json(
                json.dumps(raw_draft, allow_nan=False, ensure_ascii=True, separators=(",", ":"))
            )
        except (TypeError, ValueError, ValidationError):
            return self._reject("critic_input_invalid")
        return self.review(draft=draft, lattice=state["lattice"])

    def review(self, *, draft: AssemblerDraft, lattice: GlossLattice) -> CriticVerdict:
        """Return a fail-closed verdict after one token-level critic assessment."""

        try:
            validate_draft_for_lattice(draft, lattice)
            expected_tokens = _expected_tokens(draft)
            if len(expected_tokens) > self._config.max_candidate_tokens:
                return self._reject("critic_input_token_limit_exceeded")
            payload = _critic_payload(draft=draft, lattice=lattice, tokens=expected_tokens)
        except (TypeError, ValueError):
            return self._reject("critic_input_invalid")

        self._increment_metric("critic_model_calls_total")
        try:
            response = self._converse(payload)
        except Exception as exc:
            self._increment_metric("critic_model_calls_failed")
            logger.warning("critic_model_call_failed error_type=%s", type(exc).__name__)
            return self._reject("critic_service_unavailable")
        self._increment_metric("critic_model_calls_succeeded")

        self._increment_metric("critic_output_validation_attempts")
        try:
            response_text = _extract_critic_response_text(response)
            if len(response_text) > self._config.max_response_characters:
                raise CriticOutputError("critic response exceeds the character limit")
            try:
                assessment = CriticAssessment.model_validate_json(response_text)
            except ValidationError as exc:
                raise CriticOutputError(
                    "critic response did not match the assessment schema"
                ) from exc
            validate_assessment_for_draft(
                assessment,
                draft=draft,
                lattice=lattice,
                expected_tokens=expected_tokens,
            )
        except CriticOutputError as exc:
            self._increment_metric("critic_output_validation_failures")
            logger.warning(
                "critic_output_validation_failed error_type=%s",
                type(exc).__name__,
            )
            return self._reject("critic_output_invalid")

        self._increment_metric("critic_output_validation_successes")
        if assessment.supported:
            self._increment_metric("critic_verdicts_supported")
            return CriticVerdict(supported=True, reason="all_candidate_tokens_supported")
        first_unsupported = next(
            item for item in assessment.token_assessments if not item.supported
        )
        return self._reject(f"unsupported_candidate_token:{first_unsupported.token_index}")

    def _converse(self, payload: Mapping[str, JsonValue]) -> Mapping[str, Any]:
        response: Mapping[str, Any] | None = None
        try:
            response = self._client.converse(
                modelId=self._config.model_id,
                system=[{"text": self._system_prompt}],
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {
                                "text": json.dumps(
                                    payload,
                                    allow_nan=False,
                                    ensure_ascii=True,
                                    separators=(",", ":"),
                                    sort_keys=True,
                                )
                            }
                        ],
                    }
                ],
                inferenceConfig={
                    "maxTokens": self._config.max_tokens,
                    "temperature": float(self._config.temperature),
                },
                requestMetadata={
                    "simplynext_role": "critic",
                    "simplynext_utterance_id": str(payload.get("utterance_id", "unavailable")),
                },
            )
            return response
        finally:
            _log_critic_usage(response=response, model_id=self._config.model_id)

    def _reject(self, reason: str) -> CriticVerdict:
        self._increment_metric("critic_verdicts_rejected")
        return CriticVerdict(supported=False, reason=reason)

    def _increment_metric(self, name: str) -> None:
        if self._metrics is not None:
            self._metrics.increment(name)


def validate_assessment_for_draft(
    assessment: CriticAssessment,
    *,
    draft: AssemblerDraft,
    lattice: GlossLattice,
    expected_tokens: tuple[_ExpectedToken, ...] | None = None,
) -> CriticAssessment:
    """Reject omissions and evidence references outside the assembler draft."""

    validate_draft_for_lattice(draft, lattice)
    tokens = _expected_tokens(draft) if expected_tokens is None else expected_tokens
    if assessment.utterance_id != draft.utterance_id:
        raise CriticGroundingError("critic utterance_id does not match the draft")
    if len(assessment.token_assessments) != len(tokens):
        raise CriticGroundingError("critic must assess every candidate token exactly once")

    for expected, actual in zip(tokens, assessment.token_assessments, strict=True):
        if actual.token_index != expected.token_index or actual.token != expected.token:
            raise CriticGroundingError("critic token does not match the candidate")
        actual_evidence = {(item.slot_id, item.gloss_id) for item in actual.evidence}
        allowed_evidence = {(item.slot_id, item.gloss_id) for item in expected.evidence}
        if not actual_evidence.issubset(allowed_evidence):
            raise CriticGroundingError("critic cited evidence outside the candidate token's part")
        if expected.kind is CriticTokenKind.GAP_MARKER:
            if actual.evidence:
                raise CriticGroundingError("a gap marker cannot cite resolved gloss evidence")
        elif actual.supported and not actual.evidence:
            raise CriticGroundingError("a supported spoken token must cite exact gloss evidence")
    return assessment


def _expected_tokens(draft: AssemblerDraft) -> tuple[_ExpectedToken, ...]:
    tokens: list[_ExpectedToken] = []
    for part in draft.parts:
        if isinstance(part, SupportedTextPart):
            for token in part.text.split():
                tokens.append(
                    _ExpectedToken(
                        token_index=len(tokens),
                        token=token,
                        kind=CriticTokenKind.SPOKEN_TEXT,
                        evidence=part.evidence,
                    )
                )
            continue
        tokens.append(
            _ExpectedToken(
                token_index=len(tokens),
                token=f"[GAP:{part.slot_id}]",
                kind=CriticTokenKind.GAP_MARKER,
                evidence=(),
                gap_slot_id=part.slot_id,
            )
        )
    if not tokens:
        raise CriticGroundingError("critic input must contain at least one candidate token")
    if len(tokens) > MAX_CRITIC_TOKENS:
        raise CriticGroundingError("critic input exceeds the absolute token limit")
    return tuple(tokens)


def _critic_payload(
    *,
    draft: AssemblerDraft,
    lattice: GlossLattice,
    tokens: tuple[_ExpectedToken, ...],
) -> dict[str, JsonValue]:
    lattice_slots: list[JsonValue] = [
        {
            "slot_id": slot.slot_id,
            "resolved_gloss_id": slot.resolved_gloss_id,
            "provenance": slot.provenance.value,
        }
        for slot in lattice.slots
    ]
    candidate_tokens: list[JsonValue] = [
        {
            "token_index": token.token_index,
            "token": token.token,
            "kind": token.kind.value,
            "evidence": [cast(JsonValue, item.model_dump(mode="json")) for item in token.evidence],
            "gap_slot_id": token.gap_slot_id,
        }
        for token in tokens
    ]
    return {
        "schema_version": CRITIC_ASSESSMENT_SCHEMA_VERSION,
        "utterance_id": draft.utterance_id,
        "language": lattice.language.value,
        "lattice_slots": lattice_slots,
        "candidate": {
            "candidate_text": draft.candidate_text,
            "tokens": candidate_tokens,
        },
    }


def _extract_critic_response_text(response: Mapping[str, Any]) -> str:
    try:
        content = response["output"]["message"]["content"]
    except (KeyError, TypeError) as exc:
        raise CriticOutputError("critic response has no output content") from exc
    if not isinstance(content, list) or len(content) != 1:
        raise CriticOutputError("critic response must contain exactly one text block")
    block = content[0]
    if not isinstance(block, Mapping) or set(block) != {"text"}:
        raise CriticOutputError("critic response text block is malformed")
    text = block["text"]
    if not isinstance(text, str) or not text.strip():
        raise CriticOutputError("critic response text is missing")
    return text


def _load_critic_prompt(path: Path) -> str:
    try:
        prompt = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValueError("critic prompt file could not be loaded") from exc
    if not prompt:
        raise ValueError("critic prompt file must not be empty")
    if any(fragment not in prompt for fragment in _REQUIRED_CRITIC_PROMPT_FRAGMENTS):
        raise ValueError("critic prompt is missing a required safety instruction")
    return prompt


def _log_critic_usage(*, response: Mapping[str, Any] | None, model_id: str) -> None:
    usage = None if response is None else response.get("usage")
    if isinstance(usage, Mapping):
        logger.info(
            "critic_model_call model_id=%s input_tokens=%s output_tokens=%s total_tokens=%s",
            model_id,
            usage.get("inputTokens"),
            usage.get("outputTokens"),
            usage.get("totalTokens"),
        )
    else:
        logger.info("critic_model_call model_id=%s token_usage=unavailable", model_id)


__all__ = [
    "CRITIC_ASSESSMENT_SCHEMA_VERSION",
    "DEFAULT_CRITIC_PROMPT_PATH",
    "MAX_CRITIC_RESPONSE_CHARACTERS",
    "MAX_CRITIC_TOKENS",
    "BedrockLatticeCriticNode",
    "CriticAssessment",
    "CriticGroundingError",
    "CriticOutputError",
    "CriticTokenAssessment",
    "CriticTokenKind",
    "LatticeCriticClient",
    "LatticeCriticConfig",
    "validate_assessment_for_draft",
]
