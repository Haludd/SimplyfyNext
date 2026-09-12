"""GlossLattice-only session negotiation and stream-control contracts."""

from __future__ import annotations

from enum import StrEnum
from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, Field

from .common import ContractModel, SignLanguage
from .gloss_lattice import GLOSS_LATTICE_SCHEMA_VERSION, GlossLatticeProducer


class ClientPlatform(StrEnum):
    """Supported client runtime identifiers."""

    IOS = "ios"
    ANDROID = "android"
    TEST = "test"


class DetectorDelegate(StrEnum):
    """Client-side detector execution delegate."""

    CPU = "cpu"
    GPU = "gpu"
    CORE_ML = "core_ml"
    NNAPI = "nnapi"
    UNKNOWN = "unknown"


class StreamKind(StrEnum):
    """The only supported session stream."""

    GLOSS_LATTICE = "gloss_lattice"


class ClientDescriptor(ContractModel):
    """Client application metadata used for compatibility diagnostics."""

    platform: ClientPlatform
    app_version: str = Field(min_length=1, max_length=64)
    device_model: str | None = Field(default=None, min_length=1, max_length=128)


class DetectorDescriptor(ContractModel):
    """On-device detector metadata supplied during session creation."""

    name: str = Field(min_length=1, max_length=128)
    version: str = Field(min_length=1, max_length=64)
    delegate: DetectorDelegate = DetectorDelegate.UNKNOWN


class SessionCreateRequest(ContractModel):
    """Request for a new GlossLattice translation session."""

    language: SignLanguage
    schema_version: Literal["1.0"] = GLOSS_LATTICE_SCHEMA_VERSION
    stream_kind: StreamKind
    client: ClientDescriptor
    detector: DetectorDescriptor
    producer: GlossLatticeProducer


class SessionCreateResponse(ContractModel):
    """Opaque bearer capability and negotiated lattice limits."""

    session_id: UUID
    stream_token: str = Field(min_length=32, max_length=256)
    token_type: Literal["Bearer"] = "Bearer"
    stream_kind: StreamKind = StreamKind.GLOSS_LATTICE
    websocket_path: str = Field(pattern=r"^/.*")
    created_at: AwareDatetime
    expires_at: AwareDatetime
    lattice_schema_version: Literal["1.0"] = GLOSS_LATTICE_SCHEMA_VERSION
    max_lattice_message_bytes: Literal[32_768] = 32_768
    max_lattice_slots: Literal[64] = 64
    max_candidates_per_slot: Literal[5] = 5


class ControlAction(StrEnum):
    """Client-to-server lifecycle controls for a live lattice stream."""

    END = "end"
    PING = "ping"


class StreamControlMessage(ContractModel):
    """Control message accepted on the authenticated lattice socket."""

    type: Literal["control"] = "control"
    session_id: UUID
    control_seq: int = Field(strict=True, ge=0)
    action: ControlAction
    client_ms: int | None = Field(default=None, strict=True, ge=0)


# Backwards-compatible aliases for the generic create-session naming.
SessionRequest = SessionCreateRequest
SessionResponse = SessionCreateResponse
