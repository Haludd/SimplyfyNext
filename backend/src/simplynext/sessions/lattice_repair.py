"""Server-owned correlation state for a pending lattice repair interaction."""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from simplynext.contracts.common import Identifier
from simplynext.contracts.events import (
    LatticeChoice,
    LatticeRepairAction,
    LatticeRepairRequiredEvent,
)
from simplynext.contracts.gloss_lattice import GlossLattice


class PendingLatticeRepair(BaseModel):
    """Trusted state linking a repair event to a later frozen-v1 lattice."""

    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
        str_strip_whitespace=False,
        validate_default=True,
    )

    repair_id: Identifier
    session_id: UUID
    source_lattice_seq: int = Field(ge=0, le=9_007_199_254_740_991)
    utterance_id: Identifier
    action: LatticeRepairAction
    target_slot_ids: tuple[Identifier, ...] = ()
    choices: tuple[LatticeChoice, ...] = ()

    @model_validator(mode="after")
    def validate_state(self) -> PendingLatticeRepair:
        if len(self.target_slot_ids) != len(set(self.target_slot_ids)):
            raise ValueError("target_slot_ids must be unique")
        if self.action is LatticeRepairAction.OFFER_TOP_K:
            if len(self.target_slot_ids) != 1 or not self.choices:
                raise ValueError("offer_top_k requires one target slot and choices")
            if any(choice.slot_id != self.target_slot_ids[0] for choice in self.choices):
                raise ValueError("choices must belong to the target slot")
        elif self.choices:
            raise ValueError("only offer_top_k may retain choices")
        return self

    @classmethod
    def from_event(cls, event: LatticeRepairRequiredEvent) -> PendingLatticeRepair:
        """Capture trusted continuation state when a repair event is finalized."""

        return cls(
            repair_id=event.repair_id,
            session_id=event.session_id,
            source_lattice_seq=event.lattice_seq,
            utterance_id=event.utterance_id,
            action=event.action,
            target_slot_ids=event.target_slot_ids,
            choices=event.choices,
        )

    def accepts_follow_up(self, lattice: GlossLattice) -> bool:
        """Match a new v1 message without trusting a client revision counter."""

        return (
            lattice.session_id == self.session_id
            and lattice.utterance_id == self.utterance_id
            and lattice.lattice_seq > self.source_lattice_seq
        )


__all__ = ["PendingLatticeRepair"]
