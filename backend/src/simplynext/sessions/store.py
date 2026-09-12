"""Thread-safe in-memory storage for ephemeral GlossLattice sessions."""

from __future__ import annotations

import hashlib
import hmac
import secrets
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from threading import RLock
from uuid import UUID, uuid4

from simplynext.contracts import (
    ControlAction,
    GlossLattice,
    GlossLatticeProducer,
    LatticeRepairRequiredEvent,
    LatticeTerminalEvent,
    SessionCreateRequest,
    SessionCreateResponse,
    SignLanguage,
    StreamControlMessage,
    StreamKind,
)
from simplynext.contracts.gloss_lattice import MAX_GLOSS_LATTICE_BYTES

from .lattice_repair import PendingLatticeRepair


class SessionState(StrEnum):
    READY = "ready"
    STREAMING = "streaming"
    ENDED = "ended"


class SessionStoreError(Exception):
    """Base exception with a stable machine-readable code."""

    code = "session_store_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class SessionNotFound(SessionStoreError):
    code = "session_not_found"


class InvalidSessionToken(SessionStoreError):
    code = "unauthorized"


class SessionExpired(SessionStoreError):
    code = "session_expired"


class InvalidSessionState(SessionStoreError):
    code = "invalid_session_state"


class NonMonotonicSequence(SessionStoreError):
    code = "non_monotonic_sequence"


class TooManySessions(SessionStoreError):
    code = "rate_limited"


class LatticeConflict(SessionStoreError):
    code = "invalid_session_state"


class LatticeInProgress(SessionStoreError):
    code = "invalid_session_state"


class LatticeRateLimited(SessionStoreError):
    code = "rate_limited"


class LatticeQuotaExceeded(SessionStoreError):
    code = "rate_limited"


class LatticeReservationDisposition(StrEnum):
    ACCEPTED = "accepted"
    CACHED = "cached"


@dataclass(frozen=True, slots=True)
class SessionSnapshot:
    session_id: UUID
    signer_id: str
    language: SignLanguage
    state: SessionState
    created_at: datetime
    last_seen_at: datetime
    expires_at: datetime
    last_control_seq: int | None
    stream_kind: StreamKind
    producer: GlossLatticeProducer
    last_lattice_seq: int | None
    lattice_count: int


@dataclass(frozen=True, slots=True)
class LatticeReservation:
    session_id: UUID
    lattice_seq: int
    utterance_id: str
    disposition: LatticeReservationDisposition
    cached_event: LatticeTerminalEvent | None = None


@dataclass(slots=True)
class _LatticeRecord:
    lattice_seq: int
    utterance_id: str
    payload_digest: bytes
    terminal_event: LatticeTerminalEvent | None = None


@dataclass(slots=True)
class _SessionRecord:
    session_id: UUID
    signer_id: str
    token_digest: bytes
    request: SessionCreateRequest
    state: SessionState
    created_at: datetime
    last_seen_at: datetime
    expires_at: datetime
    last_control_seq: int = -1
    active_stream_id: UUID | None = None
    active_lattice_seq: int | None = None
    last_lattice_seq: int = -1
    lattice_records: dict[int, _LatticeRecord] = field(default_factory=dict)
    latest_lattice_seq_by_utterance: dict[str, int] = field(default_factory=dict)
    pending_repairs: dict[str, PendingLatticeRepair] = field(default_factory=dict)
    lattice_received_at: deque[datetime] = field(default_factory=deque)


class EphemeralSessionStore:
    """Bounded live-session state with no persistence or plaintext token storage."""

    def __init__(
        self,
        *,
        ttl_seconds: int = 900,
        max_sessions: int = 128,
        websocket_path_template: str = "/v1/sessions/{session_id}/lattices",
        max_lattice_message_bytes: int = MAX_GLOSS_LATTICE_BYTES,
        max_session_creations_per_minute_global: int = 60,
        max_lattices_per_session: int = 100,
        max_lattices_per_minute: int = 30,
        max_lattices_per_minute_global: int = 120,
        clock: Callable[[], datetime] | None = None,
        token_factory: Callable[[], str] | None = None,
        id_factory: Callable[[], UUID] | None = None,
    ) -> None:
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        if max_sessions < 1:
            raise ValueError("max_sessions must be positive")
        if max_session_creations_per_minute_global < 1:
            raise ValueError("max_session_creations_per_minute_global must be positive")
        if "{session_id}" not in websocket_path_template:
            raise ValueError("websocket_path_template must contain {session_id}")
        if max_lattice_message_bytes != MAX_GLOSS_LATTICE_BYTES:
            raise ValueError("CTR v1 max_lattice_message_bytes must be exactly 32768")
        if max_lattices_per_session < 1:
            raise ValueError("max_lattices_per_session must be positive")
        if max_lattices_per_minute < 1:
            raise ValueError("max_lattices_per_minute must be positive")
        if max_lattices_per_minute_global < 1:
            raise ValueError("max_lattices_per_minute_global must be positive")

        self._ttl = timedelta(seconds=ttl_seconds)
        self._max_sessions = max_sessions
        self._max_session_creations_per_minute_global = max_session_creations_per_minute_global
        self._websocket_path_template = websocket_path_template
        self._max_lattices_per_session = max_lattices_per_session
        self._max_lattices_per_minute = max_lattices_per_minute
        self._max_lattices_per_minute_global = max_lattices_per_minute_global
        self._clock = clock or (lambda: datetime.now(UTC))
        self._token_factory = token_factory or (lambda: secrets.token_urlsafe(32))
        self._id_factory = id_factory or uuid4
        self._records: dict[UUID, _SessionRecord] = {}
        self._global_session_created_at: deque[datetime] = deque()
        self._global_lattice_received_at: deque[datetime] = deque()
        self._lock = RLock()

    async def create(
        self,
        request: SessionCreateRequest,
        *,
        signer_id: str | None = None,
    ) -> SessionCreateResponse:
        """Create a session and return its bearer capability exactly once."""

        if signer_id is not None and (
            not isinstance(signer_id, str) or not signer_id.strip()
        ):
            raise ValueError("signer_id must be omitted or a non-empty trusted identifier")

        now = self._now()
        session_id = self._id_factory()
        token = self._token_factory()
        if len(token) < 32:
            raise ValueError("token_factory must return at least 32 characters")
        record = _SessionRecord(
            session_id=session_id,
            signer_id=signer_id or f"anonymous:{session_id}",
            token_digest=self._token_digest(token),
            request=request,
            state=SessionState.READY,
            created_at=now,
            last_seen_at=now,
            expires_at=now + self._ttl,
        )
        with self._lock:
            self._purge_expired_locked(now)
            self._prune_window(self._global_session_created_at, now)
            if (
                len(self._global_session_created_at)
                >= self._max_session_creations_per_minute_global
            ):
                raise TooManySessions("global session creation rate limit exceeded")
            if len(self._records) >= self._max_sessions:
                raise TooManySessions("maximum number of active sessions reached")
            if session_id in self._records:
                raise ValueError("id_factory returned an existing session_id")
            self._records[session_id] = record
            self._global_session_created_at.append(now)

        return SessionCreateResponse(
            session_id=session_id,
            stream_token=token,
            websocket_path=self._websocket_path_template.format(session_id=session_id),
            created_at=now,
            expires_at=record.expires_at,
        )

    async def create_session(
        self,
        request: SessionCreateRequest,
        *,
        signer_id: str | None = None,
    ) -> SessionCreateResponse:
        return await self.create(request, signer_id=signer_id)

    async def authenticate(
        self,
        session_id: UUID | str,
        token: str,
        *,
        touch: bool = True,
    ) -> SessionSnapshot:
        now = self._now()
        with self._lock:
            return self._snapshot(
                self._authorized_record(session_id, token, now, touch=touch)
            )

    async def claim_stream(
        self,
        session_id: UUID | str,
        token: str,
        stream_id: UUID,
    ) -> SessionSnapshot:
        """Exclusively bind one live WebSocket to a session."""

        now = self._now()
        with self._lock:
            record = self._authorized_record(session_id, token, now, touch=True)
            if record.active_stream_id not in (None, stream_id):
                raise InvalidSessionState("session already has an active stream")
            record.active_stream_id = stream_id
            return self._snapshot(record)

    async def release_stream(
        self,
        session_id: UUID | str,
        token: str,
        stream_id: UUID,
    ) -> bool:
        now = self._now()
        with self._lock:
            record = self._authorized_record(session_id, token, now, touch=False)
            if record.active_stream_id != stream_id:
                return False
            record.active_stream_id = None
            return True

    async def reserve_lattice(
        self,
        lattice: GlossLattice,
        token: str,
        payload_digest: bytes,
    ) -> LatticeReservation:
        """Atomically reserve one new lattice or return its completed replay."""

        self._validate_payload_digest(payload_digest)
        now = self._now()
        with self._lock:
            record = self._authorized_record(lattice.session_id, token, now, touch=True)
            self._validate_lattice_session(record, lattice)
            cached = self._existing_lattice_reservation(record, lattice, payload_digest)
            if cached is not None:
                return cached
            self._validate_new_lattice_submission(record, lattice, now)

            record.lattice_records[lattice.lattice_seq] = _LatticeRecord(
                lattice_seq=lattice.lattice_seq,
                utterance_id=lattice.utterance_id,
                payload_digest=payload_digest,
            )
            record.latest_lattice_seq_by_utterance[lattice.utterance_id] = lattice.lattice_seq
            record.last_lattice_seq = lattice.lattice_seq
            record.lattice_received_at.append(now)
            self._global_lattice_received_at.append(now)
            record.active_lattice_seq = lattice.lattice_seq
            if record.state is SessionState.READY:
                record.state = SessionState.STREAMING
            return LatticeReservation(
                session_id=record.session_id,
                lattice_seq=lattice.lattice_seq,
                utterance_id=lattice.utterance_id,
                disposition=LatticeReservationDisposition.ACCEPTED,
            )

    async def find_lattice_replay(
        self,
        lattice: GlossLattice,
        token: str,
        payload_digest: bytes,
    ) -> LatticeReservation | None:
        """Check replay and admission without consuming Agent capacity."""

        self._validate_payload_digest(payload_digest)
        now = self._now()
        with self._lock:
            record = self._authorized_record(lattice.session_id, token, now, touch=True)
            self._validate_lattice_session(record, lattice)
            replay = self._existing_lattice_reservation(record, lattice, payload_digest)
            if replay is not None:
                return replay
            self._validate_new_lattice_submission(record, lattice, now)
            return None

    async def complete_lattice(
        self,
        lattice: GlossLattice,
        token: str,
        payload_digest: bytes,
        terminal_event: LatticeTerminalEvent,
    ) -> None:
        """Cache exactly one safe terminal event for an accepted lattice."""

        self._validate_payload_digest(payload_digest)
        now = self._now()
        with self._lock:
            record = self._authorized_record(lattice.session_id, token, now, touch=True)
            lattice_record = record.lattice_records.get(lattice.lattice_seq)
            if lattice_record is None:
                raise LatticeConflict("lattice was not reserved")
            if lattice_record.utterance_id != lattice.utterance_id or not hmac.compare_digest(
                lattice_record.payload_digest, payload_digest
            ):
                raise LatticeConflict("lattice completion does not match its reservation")
            if (
                terminal_event.session_id != lattice.session_id
                or terminal_event.lattice_seq != lattice.lattice_seq
                or terminal_event.utterance_id != lattice.utterance_id
            ):
                raise LatticeConflict("terminal event does not match its lattice")
            if lattice_record.terminal_event is not None:
                raise LatticeConflict("lattice already has a terminal event")
            lattice_record.terminal_event = terminal_event
            if isinstance(terminal_event, LatticeRepairRequiredEvent):
                record.pending_repairs[lattice.utterance_id] = PendingLatticeRepair.from_event(
                    terminal_event
                )
            else:
                record.pending_repairs.pop(lattice.utterance_id, None)
            if record.active_lattice_seq == lattice.lattice_seq:
                record.active_lattice_seq = None

    async def apply_control(
        self,
        message: StreamControlMessage,
        token: str,
    ) -> SessionSnapshot:
        """Apply an ordered lattice-stream control transition."""

        now = self._now()
        with self._lock:
            record = self._authorized_record(message.session_id, token, now, touch=True)
            if message.control_seq <= record.last_control_seq:
                raise NonMonotonicSequence(
                    f"control_seq must be greater than {record.last_control_seq}"
                )
            if message.action is ControlAction.END:
                if record.state is SessionState.ENDED:
                    raise InvalidSessionState("session is already ended")
                record.state = SessionState.ENDED
            elif record.state is SessionState.ENDED:
                raise InvalidSessionState("session is ended")

            record.last_control_seq = message.control_seq
            return self._snapshot(record)

    async def delete(
        self,
        session_id: UUID | str,
        token: str,
        *,
        owner_stream_id: UUID | None = None,
    ) -> None:
        """Erase all in-memory state for an authenticated session."""

        now = self._now()
        with self._lock:
            record = self._authorized_record(session_id, token, now, touch=False)
            if record.active_stream_id is not None and record.active_stream_id != owner_stream_id:
                raise InvalidSessionState("close the active stream before deleting its session")
            if record.active_lattice_seq is not None:
                raise InvalidSessionState("cannot delete a session during Agent processing")
            self._erase_record(record)
            del self._records[record.session_id]

    async def purge_expired(self) -> int:
        now = self._now()
        with self._lock:
            return self._purge_expired_locked(now)

    async def count(self) -> int:
        with self._lock:
            return len(self._records)

    def _authorized_record(
        self,
        session_id: UUID | str,
        token: str,
        now: datetime,
        *,
        touch: bool,
    ) -> _SessionRecord:
        canonical_id = self._canonical_id(session_id)
        record = self._records.get(canonical_id)
        if record is None:
            raise SessionNotFound("session does not exist")
        if now >= record.expires_at and record.active_lattice_seq is None:
            self._erase_record(record)
            del self._records[canonical_id]
            raise SessionExpired("session has expired")
        if not isinstance(token, str) or not hmac.compare_digest(
            record.token_digest,
            self._token_digest(token),
        ):
            raise InvalidSessionToken("stream token is invalid")
        if touch:
            record.last_seen_at = now
            record.expires_at = now + self._ttl
        return record

    def _purge_expired_locked(self, now: datetime) -> int:
        expired_ids = [
            session_id
            for session_id, record in self._records.items()
            if now >= record.expires_at and record.active_lattice_seq is None
        ]
        for session_id in expired_ids:
            self._erase_record(self._records[session_id])
            del self._records[session_id]
        return len(expired_ids)

    @staticmethod
    def _prune_window(events: deque[datetime], now: datetime) -> None:
        minute_ago = now - timedelta(minutes=1)
        while events and events[0] <= minute_ago:
            events.popleft()

    @staticmethod
    def _erase_record(record: _SessionRecord) -> None:
        record.lattice_records.clear()
        record.latest_lattice_seq_by_utterance.clear()
        record.pending_repairs.clear()
        record.lattice_received_at.clear()

    @staticmethod
    def _canonical_id(session_id: UUID | str) -> UUID:
        if isinstance(session_id, UUID):
            return session_id
        try:
            return UUID(str(session_id))
        except (TypeError, ValueError, AttributeError) as exc:
            raise SessionNotFound("session does not exist") from exc

    @staticmethod
    def _token_digest(token: str) -> bytes:
        if not isinstance(token, str):
            return b""
        return hashlib.sha256(token.encode("utf-8")).digest()

    def _now(self) -> datetime:
        value = self._clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("clock must return a timezone-aware datetime")
        return value.astimezone(UTC)

    @staticmethod
    def _validate_payload_digest(payload_digest: bytes) -> None:
        if (
            not isinstance(payload_digest, bytes)
            or len(payload_digest) != hashlib.sha256().digest_size
        ):
            raise ValueError("payload_digest must be a SHA-256 digest")

    @staticmethod
    def _validate_lattice_session(record: _SessionRecord, lattice: GlossLattice) -> None:
        if lattice.language is not record.request.language:
            raise LatticeConflict("lattice language does not match the session")
        if lattice.producer != record.request.producer:
            raise LatticeConflict("lattice producer profile does not match the session")

    @staticmethod
    def _existing_lattice_reservation(
        record: _SessionRecord,
        lattice: GlossLattice,
        payload_digest: bytes,
    ) -> LatticeReservation | None:
        existing = record.lattice_records.get(lattice.lattice_seq)
        if existing is None:
            return None
        if existing.utterance_id != lattice.utterance_id or not hmac.compare_digest(
            existing.payload_digest,
            payload_digest,
        ):
            raise LatticeConflict("lattice_seq was already used with different content")
        if existing.terminal_event is None:
            raise LatticeInProgress("this lattice is already being processed")
        return LatticeReservation(
            session_id=record.session_id,
            lattice_seq=lattice.lattice_seq,
            utterance_id=lattice.utterance_id,
            disposition=LatticeReservationDisposition.CACHED,
            cached_event=existing.terminal_event,
        )

    def _validate_new_lattice_submission(
        self,
        record: _SessionRecord,
        lattice: GlossLattice,
        now: datetime,
    ) -> None:
        if record.active_lattice_seq is not None:
            raise LatticeInProgress(
                f"lattice_seq {record.active_lattice_seq} is still being processed"
            )
        if lattice.lattice_seq <= record.last_lattice_seq:
            raise NonMonotonicSequence(
                f"lattice_seq must be greater than {record.last_lattice_seq}"
            )

        previous_seq = record.latest_lattice_seq_by_utterance.get(lattice.utterance_id)
        if previous_seq is not None:
            pending = record.pending_repairs.get(lattice.utterance_id)
            if pending is None or not pending.accepts_follow_up(lattice):
                raise LatticeConflict(
                    "a later message for an utterance requires a preceding repair response"
                )

        if record.state is SessionState.ENDED:
            raise InvalidSessionState("cannot submit a lattice after session end")
        if len(record.lattice_records) >= self._max_lattices_per_session:
            raise LatticeQuotaExceeded("session lattice quota has been reached")

        minute_ago = now - timedelta(minutes=1)
        while record.lattice_received_at and record.lattice_received_at[0] <= minute_ago:
            record.lattice_received_at.popleft()
        if len(record.lattice_received_at) >= self._max_lattices_per_minute:
            raise LatticeRateLimited("too many new lattices in the last minute")
        while (
            self._global_lattice_received_at
            and self._global_lattice_received_at[0] <= minute_ago
        ):
            self._global_lattice_received_at.popleft()
        if len(self._global_lattice_received_at) >= self._max_lattices_per_minute_global:
            raise LatticeRateLimited("global lattice rate limit reached")

    @staticmethod
    def _snapshot(record: _SessionRecord) -> SessionSnapshot:
        return SessionSnapshot(
            session_id=record.session_id,
            signer_id=record.signer_id,
            language=record.request.language,
            state=record.state,
            created_at=record.created_at,
            last_seen_at=record.last_seen_at,
            expires_at=record.expires_at,
            last_control_seq=None if record.last_control_seq < 0 else record.last_control_seq,
            stream_kind=record.request.stream_kind,
            producer=record.request.producer,
            last_lattice_seq=None if record.last_lattice_seq < 0 else record.last_lattice_seq,
            lattice_count=len(record.lattice_records),
        )
