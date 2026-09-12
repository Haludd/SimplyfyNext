"""Public GlossLattice wire contracts for the SimplyNext backend."""

from typing import Annotated, TypeAlias

from pydantic import Field

from .common import MAX_IDENTIFIER_CHARACTERS, Confidence, ContractModel, Identifier, SignLanguage
from .events import (
    LATTICE_EVENT_SCHEMA_VERSION,
    ActivityState,
    ErrorCode,
    LatticeAckDisposition,
    LatticeAckEvent,
    LatticeActivityEvent,
    LatticeChoice,
    LatticeErrorEvent,
    LatticeEvidenceTrace,
    LatticeOutboundEvent,
    LatticePongEvent,
    LatticeRepairAction,
    LatticeRepairRequiredEvent,
    LatticeResultEvent,
    LatticeTerminalEvent,
)
from .gloss_lattice import (
    GLOSS_LATTICE_SCHEMA_VERSION,
    MAX_GLOSS_CANDIDATES,
    MAX_GLOSS_LATTICE_BYTES,
    MAX_GLOSS_LATTICE_SLOTS,
    GlossCandidate,
    GlossLattice,
    GlossLatticeProducer,
    GlossProvenance,
    GlossSlot,
)
from .sessions import (
    ClientDescriptor,
    ClientPlatform,
    ControlAction,
    DetectorDelegate,
    DetectorDescriptor,
    SessionCreateRequest,
    SessionCreateResponse,
    SessionRequest,
    SessionResponse,
    StreamControlMessage,
    StreamKind,
)

InboundLatticeStreamMessage: TypeAlias = Annotated[
    GlossLattice | StreamControlMessage,
    Field(discriminator="type"),
]

__all__ = [
    "ActivityState",
    "ClientDescriptor",
    "ClientPlatform",
    "Confidence",
    "ContractModel",
    "ControlAction",
    "DetectorDelegate",
    "DetectorDescriptor",
    "ErrorCode",
    "GLOSS_LATTICE_SCHEMA_VERSION",
    "GlossCandidate",
    "GlossLattice",
    "GlossLatticeProducer",
    "GlossProvenance",
    "GlossSlot",
    "Identifier",
    "InboundLatticeStreamMessage",
    "LATTICE_EVENT_SCHEMA_VERSION",
    "LatticeAckDisposition",
    "LatticeAckEvent",
    "LatticeActivityEvent",
    "LatticeChoice",
    "LatticeErrorEvent",
    "LatticeEvidenceTrace",
    "LatticeOutboundEvent",
    "LatticePongEvent",
    "LatticeRepairAction",
    "LatticeRepairRequiredEvent",
    "LatticeResultEvent",
    "LatticeTerminalEvent",
    "MAX_GLOSS_CANDIDATES",
    "MAX_GLOSS_LATTICE_BYTES",
    "MAX_GLOSS_LATTICE_SLOTS",
    "MAX_IDENTIFIER_CHARACTERS",
    "SessionCreateRequest",
    "SessionCreateResponse",
    "SessionRequest",
    "SessionResponse",
    "SignLanguage",
    "StreamControlMessage",
    "StreamKind",
]
