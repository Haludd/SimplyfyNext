from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID

import pytest

from simplynext.config import Settings
from simplynext.contracts import (
    ClientDescriptor,
    ClientPlatform,
    DetectorDescriptor,
    GlossLattice,
    SessionCreateRequest,
)
from simplynext.lattice_runtime import build_lattice_translation_engine
from simplynext.observability import MetricsRegistry
from simplynext.sessions import (
    EphemeralSessionStore,
    InvalidSessionState,
    LatticeConflict,
    LatticeQuotaExceeded,
    LatticeRateLimited,
    LatticeReservationDisposition,
    NonMonotonicSequence,
    TooManySessions,
)

SESSION_ID = UUID("12345678-1234-5678-1234-567812345678")
TOKEN = "test-token-which-is-at-least-thirty-two-characters"
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"
TEMPLATES_PATH = Path(__file__).parents[1] / "data" / "caption_templates.example.json"


@dataclass
class FakeClock:
    value: datetime

    def __call__(self) -> datetime:
        return self.value

    def advance(self, *, seconds: int) -> None:
        self.value += timedelta(seconds=seconds)


def _engine():
    return build_lattice_translation_engine(
        Settings(
            environment="test",
            allowed_origins=(),
            bedrock_enabled=False,
            caption_templates_path=TEMPLATES_PATH,
            recognition_language="sgsl",
        ),
        MetricsRegistry(),
    )


def _request() -> SessionCreateRequest:
    fixture = GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))
    return SessionCreateRequest(
        language="sgsl",
        stream_kind="gloss_lattice",
        client=ClientDescriptor(platform=ClientPlatform.TEST, app_version="store-test"),
        detector=DetectorDescriptor(name="frontend-perception", version="1"),
        producer=fixture.producer,
    )


def _lattice(*, lattice_seq: int, utterance_id: str) -> GlossLattice:
    fixture = GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))
    payload = fixture.model_dump(mode="json")
    slot = dict(payload["slots"][0])
    slot["candidates"] = [{"gloss_id": "HELLO", "rank": 1, "confidence": 0.96}]
    slot["resolved_gloss_id"] = "HELLO"
    return GlossLattice.model_validate(
        {
            **payload,
            "session_id": str(SESSION_ID),
            "lattice_seq": lattice_seq,
            "utterance_id": utterance_id,
            "slots": [slot],
        }
    )


def _digest(lattice: GlossLattice) -> bytes:
    return hashlib.sha256(lattice.model_dump_json().encode("utf-8")).digest()


@pytest.mark.asyncio
async def test_atomic_reservation_replay_changed_duplicate_and_sequence_gaps() -> None:
    store = EphemeralSessionStore(
        token_factory=lambda: TOKEN,
        id_factory=lambda: SESSION_ID,
    )
    created = await store.create(_request())
    assert created.websocket_path.endswith("/lattices")
    snapshot = await store.authenticate(SESSION_ID, TOKEN)
    assert snapshot.signer_id == f"anonymous:{SESSION_ID}"

    first = _lattice(lattice_seq=7, utterance_id="utterance-7")
    reservation = await store.reserve_lattice(first, TOKEN, _digest(first))
    assert reservation.disposition is LatticeReservationDisposition.ACCEPTED
    terminal = await _engine().process_lattice(first, signer_id=snapshot.signer_id)
    await store.complete_lattice(first, TOKEN, _digest(first), terminal)

    replay = await store.find_lattice_replay(first, TOKEN, _digest(first))
    assert replay is not None
    assert replay.disposition is LatticeReservationDisposition.CACHED
    assert replay.cached_event == terminal

    changed_payload = first.model_dump(mode="json")
    changed_payload["slots"][0]["candidates"][0]["confidence"] = 0.95
    changed = GlossLattice.model_validate(changed_payload)
    with pytest.raises(LatticeConflict, match="different content"):
        await store.find_lattice_replay(changed, TOKEN, _digest(changed))

    gap = _lattice(lattice_seq=9, utterance_id="utterance-9")
    assert (await store.reserve_lattice(gap, TOKEN, _digest(gap))).lattice_seq == 9
    gap_terminal = await _engine().process_lattice(gap, signer_id=snapshot.signer_id)
    await store.complete_lattice(gap, TOKEN, _digest(gap), gap_terminal)

    stale = _lattice(lattice_seq=8, utterance_id="utterance-8")
    with pytest.raises(NonMonotonicSequence):
        await store.reserve_lattice(stale, TOKEN, _digest(stale))


@pytest.mark.asyncio
async def test_quota_rate_and_active_execution_lifecycle_guards() -> None:
    clock = FakeClock(datetime(2026, 9, 6, tzinfo=UTC))
    store = EphemeralSessionStore(
        ttl_seconds=30,
        max_lattices_per_session=1,
        max_lattices_per_minute=1,
        clock=clock,
        token_factory=lambda: TOKEN,
        id_factory=lambda: SESSION_ID,
    )
    await store.create(_request())
    snapshot = await store.authenticate(SESSION_ID, TOKEN)
    first = _lattice(lattice_seq=1, utterance_id="utterance-1")
    await store.reserve_lattice(first, TOKEN, _digest(first))

    with pytest.raises(InvalidSessionState, match="Agent processing"):
        await store.delete(SESSION_ID, TOKEN)
    clock.advance(seconds=31)
    assert await store.purge_expired() == 0

    terminal = await _engine().process_lattice(first, signer_id=snapshot.signer_id)
    await store.complete_lattice(first, TOKEN, _digest(first), terminal)
    second = _lattice(lattice_seq=2, utterance_id="utterance-2")
    with pytest.raises(LatticeQuotaExceeded):
        await store.reserve_lattice(second, TOKEN, _digest(second))

    rate_store = EphemeralSessionStore(
        max_lattices_per_session=10,
        max_lattices_per_minute=1,
        clock=clock,
        token_factory=lambda: TOKEN,
        id_factory=lambda: SESSION_ID,
    )
    await rate_store.create(_request())
    rate_snapshot = await rate_store.authenticate(SESSION_ID, TOKEN)
    await rate_store.reserve_lattice(first, TOKEN, _digest(first))
    rate_terminal = await _engine().process_lattice(first, signer_id=rate_snapshot.signer_id)
    await rate_store.complete_lattice(first, TOKEN, _digest(first), rate_terminal)
    with pytest.raises(LatticeRateLimited):
        await rate_store.reserve_lattice(second, TOKEN, _digest(second))


@pytest.mark.asyncio
async def test_global_session_creation_rate_is_bounded() -> None:
    clock = FakeClock(datetime(2026, 9, 6, tzinfo=UTC))
    # ``create`` allocates the candidate ID before checking the global limit,
    # so the rejected attempt consumes an ID from this deterministic factory.
    next_id = iter((UUID(int=101), UUID(int=102), UUID(int=103)))
    store = EphemeralSessionStore(
        max_session_creations_per_minute_global=1,
        clock=clock,
        token_factory=lambda: TOKEN,
        id_factory=lambda: next(next_id),
    )
    await store.create(_request())
    with pytest.raises(TooManySessions, match="creation rate"):
        await store.create(_request())
    clock.advance(seconds=60)
    await store.create(_request())
