"""Authoritative CTR ingress-v1 GlossLattice wire contract.

This module contains only compact classifier output. Signer identity, repair
continuation, Agent state, and server response events are deliberately separate.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Annotated, Literal
from uuid import UUID

from pydantic import ConfigDict, Field, model_validator

from .common import Confidence, ContractModel, Identifier, SignLanguage

GLOSS_LATTICE_SCHEMA_VERSION: Literal["1.0"] = "1.0"
MAX_GLOSS_CANDIDATES = 5
MAX_GLOSS_LATTICE_SLOTS = 64
MAX_GLOSS_LATTICE_BYTES = 32 * 1024

TimelineMs = Annotated[int, Field(strict=True, ge=0, le=9_007_199_254_740_991)]
CalibratedConfidence = Annotated[Confidence, Field(strict=True)]


class _GlossContractModel(ContractModel):
    """Contract base that rejects, rather than normalizes, surrounding whitespace."""

    model_config = ConfigDict(str_strip_whitespace=False)


class GlossProvenance(StrEnum):
    """How the resolved gloss for a slot was obtained."""

    CLASSIFIER_HIGH_CONFIDENCE = "classifier_high_confidence"
    TOP_K_SIGNER_CONFIRMED = "top_k_signer_confirmed"
    FINGERSPELLED = "fingerspelled"
    UNRESOLVED = "unresolved"


class GlossCandidate(_GlossContractModel):
    """One calibrated closed-vocabulary hypothesis, in rank order."""

    gloss_id: Identifier
    rank: int = Field(strict=True, ge=1, le=MAX_GLOSS_CANDIDATES)
    confidence: CalibratedConfidence


class GlossSlot(_GlossContractModel):
    """One ordered sign position and its retained recognition evidence."""

    slot_index: int = Field(strict=True, ge=0, lt=MAX_GLOSS_LATTICE_SLOTS)
    slot_id: Identifier
    start_ms: TimelineMs
    end_ms: TimelineMs
    candidates: Annotated[
        tuple[GlossCandidate, ...],
        Field(max_length=MAX_GLOSS_CANDIDATES),
    ]
    resolved_gloss_id: Identifier | None
    provenance: GlossProvenance

    @model_validator(mode="after")
    def validate_slot_evidence(self) -> GlossSlot:
        if self.end_ms <= self.start_ms:
            raise ValueError("slot end_ms must be greater than start_ms")

        expected_ranks = list(range(1, len(self.candidates) + 1))
        ranks = [candidate.rank for candidate in self.candidates]
        if ranks != expected_ranks:
            raise ValueError("candidate ranks must be contiguous and ordered from 1")

        gloss_ids = [candidate.gloss_id for candidate in self.candidates]
        if len(gloss_ids) != len(set(gloss_ids)):
            raise ValueError("candidate gloss_id values must be unique within a slot")

        confidences = [candidate.confidence for candidate in self.candidates]
        if any(
            current > previous
            for previous, current in zip(confidences, confidences[1:], strict=False)
        ):
            raise ValueError("candidates must be ordered by non-increasing confidence")

        if self.provenance is GlossProvenance.UNRESOLVED:
            if self.resolved_gloss_id is not None:
                raise ValueError("an unresolved slot cannot have resolved_gloss_id")
            return self

        if self.resolved_gloss_id is None:
            raise ValueError("a resolved slot requires resolved_gloss_id")

        if self.provenance is GlossProvenance.CLASSIFIER_HIGH_CONFIDENCE:
            if not self.candidates:
                raise ValueError("classifier_high_confidence requires candidates")
            if self.resolved_gloss_id != self.candidates[0].gloss_id:
                raise ValueError("classifier_high_confidence must resolve to the rank-1 candidate")

        if (
            self.provenance is GlossProvenance.TOP_K_SIGNER_CONFIRMED
            and self.resolved_gloss_id not in gloss_ids
        ):
            raise ValueError("top_k_signer_confirmed must resolve to a retained candidate")

        return self


class GlossLatticeProducer(_GlossContractModel):
    """Versions needed to reproduce and audit stage ⑤ output."""

    classifier_id: Identifier
    classifier_version: Identifier
    confidence_kind: Literal["calibrated_probability"]
    calibration_version: Identifier
    vocabulary_version: Identifier


class GlossLattice(_GlossContractModel):
    """The only recognition payload allowed to cross from stage ⑤ to stage ⑥."""

    type: Literal["gloss_lattice"]
    schema_version: Literal["1.0"]
    session_id: UUID
    lattice_seq: int = Field(strict=True, ge=0, le=9_007_199_254_740_991)
    utterance_id: Identifier
    language: SignLanguage
    timebase: Literal["session_monotonic_ms"]
    started_at_ms: TimelineMs
    ended_at_ms: TimelineMs
    producer: GlossLatticeProducer
    slots: Annotated[
        tuple[GlossSlot, ...],
        Field(min_length=1, max_length=MAX_GLOSS_LATTICE_SLOTS),
    ]

    @model_validator(mode="after")
    def validate_lattice(self) -> GlossLattice:
        if self.ended_at_ms <= self.started_at_ms:
            raise ValueError("ended_at_ms must be greater than started_at_ms")

        slot_ids = [slot.slot_id for slot in self.slots]
        if len(slot_ids) != len(set(slot_ids)):
            raise ValueError("slot_id values must be unique within an utterance")

        for expected_index, slot in enumerate(self.slots):
            if slot.slot_index != expected_index:
                raise ValueError("slot_index values must be contiguous and ordered from 0")
            if slot.start_ms < self.started_at_ms or slot.end_ms > self.ended_at_ms:
                raise ValueError("slot timestamps must lie within the utterance range")

        for previous, current in zip(self.slots, self.slots[1:], strict=False):
            if current.start_ms < previous.end_ms:
                raise ValueError("slots must be chronological and non-overlapping")

        compact_size = len(self.model_dump_json().encode("utf-8"))
        if compact_size > MAX_GLOSS_LATTICE_BYTES:
            raise ValueError(
                "compact GlossLattice JSON exceeds "
                f"{MAX_GLOSS_LATTICE_BYTES} bytes ({compact_size} bytes)"
            )
        return self
