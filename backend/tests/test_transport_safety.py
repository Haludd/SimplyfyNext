from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from simplynext.config import Settings
from simplynext.contracts import (
    ClientDescriptor,
    ClientPlatform,
    DetectorDescriptor,
    GlossLatticeProducer,
    SessionCreateRequest,
)
from simplynext.main import create_app
from simplynext.sessions import EphemeralSessionStore, InvalidSessionState, TooManySessions


@dataclass
class FakeClock:
    value: datetime

    def __call__(self) -> datetime:
        return self.value

    def advance(self, *, seconds: int) -> None:
        self.value += timedelta(seconds=seconds)


def _session_request() -> SessionCreateRequest:
    return SessionCreateRequest(
        language="sgsl",
        stream_kind="gloss_lattice",
        client=ClientDescriptor(platform=ClientPlatform.TEST, app_version="transport-test"),
        detector=DetectorDescriptor(name="test-detector", version="1"),
        producer=GlossLatticeProducer(
            classifier_id="temporal_classifier",
            classifier_version="1.3.0",
            confidence_kind="calibrated_probability",
            calibration_version="temperature_v2",
            vocabulary_version="sgsl_demo_v1",
        ),
    )


def _test_app(*, http_max_body_bytes: int = 4096):
    return create_app(
        Settings(
            environment="test",
            allowed_origins=(),
            bedrock_enabled=False,
            caption_templates_path=None,
            http_max_body_bytes=http_max_body_bytes,
        )
    )


@pytest.mark.asyncio
async def test_session_cap_rejects_growth_but_creation_purges_expired_records() -> None:
    clock = FakeClock(datetime(2026, 9, 5, tzinfo=UTC))
    store = EphemeralSessionStore(ttl_seconds=30, max_sessions=2, clock=clock)

    await store.create(_session_request())
    await store.create(_session_request())
    with pytest.raises(TooManySessions):
        await store.create(_session_request())

    clock.advance(seconds=30)
    await store.create(_session_request())
    assert await store.count() == 1


@pytest.mark.asyncio
async def test_stream_claim_is_exclusive_and_only_owner_can_release_it() -> None:
    store = EphemeralSessionStore()
    session = await store.create(_session_request())
    owner = uuid4()
    contender = uuid4()

    await store.claim_stream(session.session_id, session.stream_token, owner)
    with pytest.raises(InvalidSessionState):
        await store.claim_stream(session.session_id, session.stream_token, contender)

    assert not await store.release_stream(session.session_id, session.stream_token, contender)
    with pytest.raises(InvalidSessionState):
        await store.claim_stream(session.session_id, session.stream_token, contender)

    assert await store.release_stream(session.session_id, session.stream_token, owner)
    await store.claim_stream(session.session_id, session.stream_token, contender)


def test_oversized_http_body_is_rejected_before_validation() -> None:
    with TestClient(_test_app()) as client:
        response = client.post(
            "/v1/sessions",
            content=b"x" * 4097,
            headers={"content-type": "application/json"},
        )

    assert response.status_code == 413
    assert response.json() == {"detail": "Request body exceeds the configured size limit."}


def test_chunked_oversized_http_body_is_also_rejected() -> None:
    with TestClient(_test_app()) as client:
        response = client.post(
            "/v1/sessions",
            content=(b"x" * 1024 for _ in range(5)),
            headers={"content-type": "application/json"},
        )

    assert response.status_code == 413


def test_hypothesis_replay_endpoint_is_absent_by_default() -> None:
    with TestClient(_test_app()) as client:
        response = client.post("/v1/utterances", json={})

    assert response.status_code == 404


def test_session_language_must_match_the_deployment_model() -> None:
    with TestClient(_test_app()) as client:
        response = client.post(
            "/v1/sessions",
            json=_session_request().model_dump(mode="json"),
        )

    assert response.status_code == 422
    assert response.json()["detail"] == "this deployment is configured for asl"
