"""Deterministic, non-speaking repair policy for stage ⑨."""

from __future__ import annotations

from enum import StrEnum
from typing import Annotated, Final, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from simplynext.agent.graph import (
    AgentGraphState,
    AllowedToolExecutor,
    RepairAction,
    RepairResult,
)
from simplynext.contracts.common import Confidence, Identifier, SignLanguage
from simplynext.contracts.gloss_lattice import GlossSlot
from simplynext.observability.metrics import MetricsRegistry

REPAIR_PLAN_SCHEMA_VERSION: Final = "1.0"
MAX_LISTENER_NOTICE_CHARACTERS: Final = 240
RepairReason = Annotated[str, StringConstraints(min_length=1, max_length=1_000)]
ListenerNotice = Annotated[
    str,
    StringConstraints(min_length=1, max_length=MAX_LISTENER_NOTICE_CHARACTERS),
]

_UNSAFE_CRITIC_REASONS: Final = (
    "critic_input_missing",
    "critic_input_invalid",
    "critic_input_token_limit_exceeded",
    "critic_output_invalid",
    "critic_service_unavailable",
)


class _RepairValue(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
        str_strip_whitespace=True,
        validate_default=True,
    )


class UncertaintyShape(StrEnum):
    """Evidence pattern used to choose one of the four repair actions."""

    CRITIC_FAILURE = "critic_failure"
    MULTIPLE_UNRESOLVED_SLOTS = "multiple_unresolved_slots"
    NO_RETAINED_CANDIDATES = "no_retained_candidates"
    SINGLE_RETAINED_CANDIDATE = "single_retained_candidate"
    MULTIPLE_RETAINED_CANDIDATES = "multiple_retained_candidates"
    UNSUPPORTED_RESOLVED_DRAFT = "unsupported_resolved_draft"


class RepairResponseMode(StrEnum):
    """Frontend interaction that can answer the repair without spoken language."""

    REPEAT_UTTERANCE = "repeat_utterance"
    FINGERSPELL = "fingerspell"
    SELECT_TOP_K = "select_top_k"
    CONTACT_INTERPRETER = "contact_interpreter"


class RepairOption(_RepairValue):
    """One retained lattice hypothesis that the signer may select directly."""

    gloss_id: Identifier
    rank: int = Field(strict=True, ge=1, le=5)
    confidence: Confidence


class RepairPlan(_RepairValue):
    """Machine-readable repair UI plan; deliberately contains no proposed sentence."""

    schema_version: Literal["1.0"]
    utterance_id: Identifier
    language: SignLanguage
    action: RepairAction
    uncertainty_shape: UncertaintyShape
    reason: RepairReason
    unresolved_slot_ids: tuple[Identifier, ...]
    signer_prompt_gloss_ids: tuple[Identifier, ...]
    accepted_reply_gloss_ids: tuple[Identifier, ...]
    response_mode: RepairResponseMode
    options: tuple[RepairOption, ...] = ()
    listener_notice: ListenerNotice


class DeterministicRepairNode:
    """Choose a bounded repair from lattice uncertainty, never synthesize a caption."""

    def __init__(self, *, metrics: MetricsRegistry | None = None) -> None:
        self._metrics = metrics

    def __call__(
        self,
        state: AgentGraphState,
        tools: AllowedToolExecutor,
    ) -> RepairResult:
        del tools
        verdict = state.get("critique")
        if verdict is None or verdict.supported:
            raise ValueError("repair requires an unsupported critic verdict")

        unresolved = tuple(
            slot for slot in state["lattice"].slots if slot.resolved_gloss_id is None
        )
        action, shape = _select_action(verdict.reason, unresolved)
        target = unresolved[0] if len(unresolved) == 1 else None
        options = (
            tuple(
                RepairOption(
                    gloss_id=candidate.gloss_id,
                    rank=candidate.rank,
                    confidence=candidate.confidence,
                )
                for candidate in target.candidates
            )
            if action is RepairAction.OFFER_TOP_K and target is not None
            else ()
        )
        prompt_glosses, reply_glosses, response_mode = _interaction_for(action, options)
        plan = RepairPlan(
            schema_version=REPAIR_PLAN_SCHEMA_VERSION,
            utterance_id=state["lattice"].utterance_id,
            language=state["lattice"].language,
            action=action,
            uncertainty_shape=shape,
            reason=verdict.reason or "critic_rejected_without_reason",
            unresolved_slot_ids=tuple(slot.slot_id for slot in unresolved),
            signer_prompt_gloss_ids=prompt_glosses,
            accepted_reply_gloss_ids=reply_glosses,
            response_mode=response_mode,
            options=options,
            listener_notice=(
                "Translation is uncertain. No spoken sentence was produced; "
                "the signer is being asked to clarify."
            ),
        )
        self._increment("repair_actions_total")
        self._increment(f"repair_action_{action.value}_total")
        return RepairResult(
            action=action,
            details=plan.model_dump(mode="json"),
        )

    def _increment(self, name: str) -> None:
        if self._metrics is not None:
            self._metrics.increment(name)


def _select_action(
    reason: str,
    unresolved: tuple[GlossSlot, ...],
) -> tuple[RepairAction, UncertaintyShape]:
    if reason in _UNSAFE_CRITIC_REASONS:
        return RepairAction.ESCALATE_HUMAN_INTERPRETER, UncertaintyShape.CRITIC_FAILURE
    if not unresolved:
        return (
            RepairAction.ESCALATE_HUMAN_INTERPRETER,
            UncertaintyShape.UNSUPPORTED_RESOLVED_DRAFT,
        )
    if len(unresolved) > 1:
        return RepairAction.ASK_REPEAT, UncertaintyShape.MULTIPLE_UNRESOLVED_SLOTS

    candidate_count = len(unresolved[0].candidates)
    if candidate_count == 0:
        return RepairAction.REQUEST_FINGERSPELLING, UncertaintyShape.NO_RETAINED_CANDIDATES
    if candidate_count == 1:
        return RepairAction.ASK_REPEAT, UncertaintyShape.SINGLE_RETAINED_CANDIDATE
    return RepairAction.OFFER_TOP_K, UncertaintyShape.MULTIPLE_RETAINED_CANDIDATES


def _interaction_for(
    action: RepairAction,
    options: tuple[RepairOption, ...],
) -> tuple[tuple[str, ...], tuple[str, ...], RepairResponseMode]:
    if action is RepairAction.ASK_REPEAT:
        return ("SAY_THAT_AGAIN",), ("YES", "NO"), RepairResponseMode.REPEAT_UTTERANCE
    if action is RepairAction.REQUEST_FINGERSPELLING:
        return ("SPELL_IT",), ("YES", "NO"), RepairResponseMode.FINGERSPELL
    if action is RepairAction.OFFER_TOP_K:
        return (
            ("WHICH_ONE",),
            tuple(option.gloss_id for option in options) + ("YES", "NO"),
            RepairResponseMode.SELECT_TOP_K,
        )
    return (
        ("INTERPRETER_HELP",),
        ("YES", "NO"),
        RepairResponseMode.CONTACT_INTERPRETER,
    )


__all__ = [
    "MAX_LISTENER_NOTICE_CHARACTERS",
    "REPAIR_PLAN_SCHEMA_VERSION",
    "DeterministicRepairNode",
    "RepairOption",
    "RepairPlan",
    "RepairResponseMode",
    "UncertaintyShape",
]
