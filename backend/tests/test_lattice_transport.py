from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Callable, Iterator
from concurrent.futures import CancelledError
from pathlib import Path
from threading import Event
from time import perf_counter, sleep
from typing import Any
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from simplynext.api.lattice_websocket import _close_code
from simplynext.config import Settings
from simplynext.contracts import GlossLattice, LatticeTerminalEvent, StreamControlMessage
from simplynext.lattice_runtime import (
    LatticeTranslationEngine,
    build_lattice_translation_engine,
)
from simplynext.main import create_app
from simplynext.observability import MetricsRegistry
from simplynext.sessions import InvalidSessionState, SessionExpired

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"
TEMPLATES_PATH = Path(__file__).parents[1] / "data" / "caption_templates.example.json"


@pytest.fixture
def client() -> Iterator[TestClient]:
    app = create_app(
        Settings(
            environment="test",
            allowed_origins=(),
            bedrock_enabled=False,
            caption_templates_path=TEMPLATES_PATH,
            recognition_language="sgsl",
        )
    )
    with TestClient(app) as test_client:
        yield test_client


def _producer() -> dict[str, str]:
    return _fixture_payload()["producer"]


def _session_request() -> dict[str, Any]:
    return {
        "language": "sgsl",
        "schema_version": "1.0",
        "stream_kind": "gloss_lattice",
        "client": {"platform": "test", "app_version": "lattice-transport-test"},
        "detector": {
            "name": "frontend-perception",
            "version": "1",
            "delegate": "cpu",
        },
        "producer": _producer(),
    }


def _create_session(client: TestClient) -> dict[str, Any]:
    response = client.post("/v1/sessions", json=_session_request())
    assert response.status_code == 201
    session = response.json()
    assert session["stream_kind"] == "gloss_lattice"
    assert session["websocket_path"].endswith("/lattices")
    assert session["lattice_schema_version"] == "1.0"
    assert session["max_lattice_message_bytes"] == 32_768
    assert session["max_lattice_slots"] == 64
    assert session["max_candidates_per_slot"] == 5
    assert "layout" not in session
    assert "max_batch_frames" not in session
    return session


def _headers(session: dict[str, Any], *, origin: str | None = None) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {session['stream_token']}"}
    if origin is not None:
        headers["Origin"] = origin
    return headers


def _fixture_payload() -> dict[str, Any]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def _hello_payload(session_id: str, *, lattice_seq: int = 7) -> dict[str, Any]:
    payload = _fixture_payload()
    payload["session_id"] = session_id
    payload["lattice_seq"] = lattice_seq
    slot = dict(payload["slots"][0])
    slot["candidates"] = [{"gloss_id": "HELLO", "rank": 1, "confidence": 0.96}]
    slot["resolved_gloss_id"] = "HELLO"
    payload["slots"] = [slot]
    return payload


def _delayed_engine(
    settings: Settings,
    *,
    delay_seconds: float,
    started: Event | None = None,
) -> LatticeTranslationEngine:
    engine = build_lattice_translation_engine(settings, MetricsRegistry())
    original: Callable[..., Awaitable[LatticeTerminalEvent]] = engine.process_lattice

    async def delayed(
        lattice: GlossLattice,
        *,
        signer_id: str,
    ) -> LatticeTerminalEvent:
        if started is not None:
            started.set()
        await asyncio.sleep(delay_seconds)
        return await original(lattice, signer_id=signer_id)

    engine.process_lattice = delayed  # type: ignore[method-assign]
    return engine


def test_session_requires_explicit_stream_kind_and_approved_producer(client: TestClient) -> None:
    missing_kind = _session_request()
    del missing_kind["stream_kind"]
    assert client.post("/v1/sessions", json=missing_kind).status_code == 422

    changed_producer = _session_request()
    changed_producer["producer"]["calibration_version"] = "unknown-calibration"
    response = client.post("/v1/sessions", json=changed_producer)
    assert response.status_code == 422
    assert response.json()["detail"] == "producer profile is not approved for this deployment"


def test_lattice_websocket_confident_result_and_exact_cached_replay(client: TestClient) -> None:
    session = _create_session(client)
    payload = _hello_payload(session["session_id"])

    with client.websocket_connect(
        session["websocket_path"],
        headers=_headers(session),
    ) as socket:
        idle = socket.receive_json()
        assert idle["type"] == "activity"
        assert idle["state"] == "idle"
        assert idle["session_id"] == session["session_id"]

        socket.send_json(payload)
        acknowledgement = socket.receive_json()
        processing = socket.receive_json()
        result = socket.receive_json()
        idle = socket.receive_json()

        assert acknowledgement["type"] == "lattice_ack"
        assert acknowledgement["disposition"] == "accepted"
        assert processing["state"] == "processing"
        assert result["type"] == "lattice_result"
        assert result["caption"] == "Hello."
        assert result["tts_text"] == "Hello."
        assert result["gloss_id_trace"] == ["HELLO"]
        assert result["agent_source"] == "deterministic_template"
        assert idle["state"] == "idle"

        socket.send_json(payload)
        cached_ack = socket.receive_json()
        cached_result = socket.receive_json()
        cached_idle = socket.receive_json()

        assert cached_ack["disposition"] == "cached"
        assert cached_result == result
        assert cached_idle["state"] == "idle"

        changed = json.loads(json.dumps(payload))
        changed["slots"][0]["candidates"][0]["confidence"] = 0.95
        socket.send_json(changed)
        conflict = socket.receive_json()
        assert conflict["type"] == "error"
        assert conflict["code"] == "invalid_session_state"
        assert conflict["retryable"] is False
        assert conflict["lattice_seq"] == payload["lattice_seq"]

    counters = client.get("/metrics").json()["counters"]
    assert counters["lattice_utterances_confident"] == 1
    assert counters["lattice_cached_replays"] == 1
    assert counters["lattice_agent_invocations"] == 1


def test_unresolved_slot_returns_graph_native_repair_without_caption(client: TestClient) -> None:
    session = _create_session(client)
    payload = _fixture_payload()
    payload["session_id"] = session["session_id"]

    with client.websocket_connect(
        session["websocket_path"],
        headers=_headers(session),
    ) as socket:
        assert socket.receive_json()["state"] == "idle"
        socket.send_json(payload)
        assert socket.receive_json()["type"] == "lattice_ack"
        assert socket.receive_json()["state"] == "processing"
        repair = socket.receive_json()
        assert socket.receive_json()["state"] == "idle"

    assert repair["type"] == "lattice_repair_required"
    assert repair["action"] == "offer_top_k"
    assert repair["target_slot_ids"] == ["slot-3"]
    assert "caption" not in repair
    assert "tts_text" not in repair
    counters = client.get("/metrics").json()["counters"]
    assert counters["lattice_unresolved_before_agent"] == 1
    assert counters.get("lattice_agent_invocations", 0) == 0


def test_disconnect_after_ack_reconnects_to_the_cached_terminal_result() -> None:
    settings = Settings(
        environment="test",
        allowed_origins=(),
        bedrock_enabled=False,
        caption_templates_path=TEMPLATES_PATH,
        recognition_language="sgsl",
    )
    engine = _delayed_engine(settings, delay_seconds=0.08)
    app = create_app(settings, lattice_translation=engine)

    with TestClient(app) as reconnecting_client:
        session = _create_session(reconnecting_client)
        payload = _hello_payload(session["session_id"])

        with pytest.raises(CancelledError), reconnecting_client.websocket_connect(
            session["websocket_path"],
            headers=_headers(session),
        ) as socket:
            assert socket.receive_json()["state"] == "idle"
            socket.send_json(payload)
            acknowledgement = socket.receive_json()
            assert acknowledgement["type"] == "lattice_ack"
            assert acknowledgement["disposition"] == "accepted"

        sleep(0.15)
        with reconnecting_client.websocket_connect(
            session["websocket_path"],
            headers=_headers(session),
        ) as socket:
            assert socket.receive_json()["state"] == "idle"
            socket.send_json(payload)
            acknowledgement = socket.receive_json()
            result = socket.receive_json()
            assert socket.receive_json()["state"] == "idle"

        assert acknowledgement["disposition"] == "cached"
        assert result["type"] == "lattice_result"
        assert result["caption"] == "Hello."
        counters = reconnecting_client.get("/metrics").json()["counters"]
        assert counters["lattice_agent_invocations"] == 1
        assert counters["lattice_cached_replays"] == 1


def test_agent_capacity_returns_a_bounded_retryable_rate_limit() -> None:
    settings = Settings(
        environment="test",
        allowed_origins=(),
        bedrock_enabled=False,
        caption_templates_path=TEMPLATES_PATH,
        recognition_language="sgsl",
        max_concurrent_agent_runs=1,
        agent_queue_timeout_seconds=0.02,
    )
    started = Event()
    engine = _delayed_engine(settings, delay_seconds=0.15, started=started)
    app = create_app(settings, lattice_translation=engine)

    with TestClient(app) as overloaded_client:
        first_session = _create_session(overloaded_client)
        second_session = _create_session(overloaded_client)
        with overloaded_client.websocket_connect(
            first_session["websocket_path"],
            headers=_headers(first_session),
        ) as first_socket:
            assert first_socket.receive_json()["state"] == "idle"
            first_socket.send_json(_hello_payload(first_session["session_id"]))
            assert first_socket.receive_json()["disposition"] == "accepted"
            assert first_socket.receive_json()["state"] == "processing"
            assert started.wait(timeout=1.0)

            with overloaded_client.websocket_connect(
                second_session["websocket_path"],
                headers=_headers(second_session),
            ) as second_socket:
                assert second_socket.receive_json()["state"] == "idle"
                started_at = perf_counter()
                second_socket.send_json(_hello_payload(second_session["session_id"]))
                rejection = second_socket.receive_json()
                elapsed = perf_counter() - started_at

            assert rejection["type"] == "error"
            assert rejection["code"] == "rate_limited"
            assert rejection["retryable"] is True
            assert elapsed < 1.0
            assert first_socket.receive_json()["type"] == "lattice_result"
            assert first_socket.receive_json()["state"] == "idle"

        counters = overloaded_client.get("/metrics").json()["counters"]
        assert counters["lattice_agent_queue_rejections"] == 1
        assert counters["lattice_agent_invocations"] == 1


def test_lattice_control_is_strict_and_only_ping_or_end_is_allowed(client: TestClient) -> None:
    session = _create_session(client)
    session_id = UUID(session["session_id"])

    with client.websocket_connect(
        session["websocket_path"],
        headers=_headers(session),
    ) as socket:
        assert socket.receive_json()["state"] == "idle"
        socket.send_json(
            StreamControlMessage(
                session_id=session_id,
                control_seq=0,
                action="ping",
            ).model_dump(mode="json")
        )
        pong = socket.receive_json()
        assert pong["type"] == "pong"
        assert pong["control_seq"] == 0

        forbidden = {
            "type": "control",
            "session_id": session["session_id"],
            "control_seq": 1,
            "action": "start",
        }
        for attempt in range(3):
            forbidden["control_seq"] = attempt + 1
            socket.send_json(forbidden)
            error = socket.receive_json()
            assert error["code"] == "invalid_message"
            assert error["retryable"] is (attempt < 2)
        with pytest.raises(WebSocketDisconnect) as closed:
            socket.receive_json()
        assert closed.value.code == 1008


def test_raw_size_binary_origin_and_auth_boundaries(client: TestClient) -> None:
    session = _create_session(client)

    with (
        pytest.raises(WebSocketDisconnect) as missing_auth,
        client.websocket_connect(session["websocket_path"]),
    ):
        pass
    assert missing_auth.value.code == 4401

    unknown_path = f"/v1/sessions/{uuid4()}/lattices"
    with (
        pytest.raises(WebSocketDisconnect) as missing_session,
        client.websocket_connect(
            unknown_path,
            headers={"Authorization": f"Bearer {session['stream_token']}"},
        ),
    ):
        pass
    assert missing_session.value.code == 4404

    assert _close_code(SessionExpired("expired")) == 4408
    assert _close_code(InvalidSessionState("wrong stream")) == 4409

    with client.websocket_connect(
        session["websocket_path"],
        headers=_headers(session),
    ) as socket:
        assert socket.receive_json()["state"] == "idle"
        socket.send_text("x" * 32_769)
        assert socket.receive_json()["code"] == "invalid_message"
        with pytest.raises(WebSocketDisconnect) as oversized:
            socket.receive_json()
        assert oversized.value.code == 1009

    binary_session = _create_session(client)
    with client.websocket_connect(
        binary_session["websocket_path"],
        headers=_headers(binary_session),
    ) as socket:
        assert socket.receive_json()["state"] == "idle"
        for attempt in range(3):
            socket.send_bytes(b"not-json")
            error = socket.receive_json()
            assert error["code"] == "invalid_message"
            assert error["retryable"] is (attempt < 2)
        with pytest.raises(WebSocketDisconnect) as binary_closed:
            socket.receive_json()
        assert binary_closed.value.code == 1008

    restricted = create_app(
        Settings(
            environment="test",
            allowed_origins=("https://allowed.example",),
            bedrock_enabled=False,
            caption_templates_path=TEMPLATES_PATH,
            recognition_language="sgsl",
        )
    )
    with TestClient(restricted) as restricted_client:
        restricted_session = _create_session(restricted_client)
        with (
            pytest.raises(WebSocketDisconnect) as bad_origin,
            restricted_client.websocket_connect(
                restricted_session["websocket_path"],
                headers=_headers(restricted_session, origin="https://blocked.example"),
            ),
        ):
            pass
        assert bad_origin.value.code == 4403


def test_non_strict_number_unknown_field_and_session_mismatch_are_rejected(
    client: TestClient,
) -> None:
    session = _create_session(client)
    payload = _hello_payload(session["session_id"])

    with client.websocket_connect(
        session["websocket_path"],
        headers=_headers(session),
    ) as socket:
        assert socket.receive_json()["state"] == "idle"

        non_strict = {**payload, "lattice_seq": 7.0}
        socket.send_json(non_strict)
        assert socket.receive_json()["code"] == "invalid_message"

        unknown = {**payload, "landmarks": []}
        socket.send_json(unknown)
        assert socket.receive_json()["code"] == "invalid_message"

        mismatch = {**payload, "session_id": str(uuid4())}
        socket.send_json(mismatch)
        error = socket.receive_json()
        assert error["code"] == "unauthorized"
        with pytest.raises(WebSocketDisconnect) as closed:
            socket.receive_json()
        assert closed.value.code == 4401


@pytest.mark.parametrize(
    "forbidden_field",
    ["landmarks", "frames", "tensors", "unknown_v1_field"],
)
def test_raw_perception_and_unknown_fields_never_pass_v1(
    client: TestClient,
    forbidden_field: str,
) -> None:
    session = _create_session(client)
    payload = {**_hello_payload(session["session_id"]), forbidden_field: []}

    with client.websocket_connect(
        session["websocket_path"],
        headers=_headers(session),
    ) as socket:
        assert socket.receive_json()["state"] == "idle"
        socket.send_json(payload)
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["code"] == "invalid_message"
    assert error["retryable"] is True
