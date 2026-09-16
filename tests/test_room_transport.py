from __future__ import annotations

import asyncio
import json
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator
from starlette.websockets import WebSocketDisconnect

from simplynext.config import Settings
from simplynext.contracts.room_events import ROOM_EVENT_ADAPTER, AcceptedOutcome
from simplynext.main import create_app

ROOT = Path(__file__).parents[1]
RAW = (ROOT / "tests/fixtures/translated_sign_utterance_v1.json").read_text()
EVENT_SCHEMA = json.loads(
    (ROOT / "src/simplynext/contracts/schemas/room-events-v1.json").read_text()
)


@pytest.fixture
def client():
    app = create_app(
        Settings(
            _env_file=None,
            environment="test",
            bedrock_enabled=False,
            anthropic_enabled=False,
            allowed_origins=("https://client.example",),
        )
    )
    with TestClient(app) as client:
        yield client


def credentials(client):
    created = client.post(
        "/v1/rooms",
        json={"schema_version": "1.0", "event_schema_version": "1.0", "alias": "Signer"},
    )
    assert created.status_code == 201, created.text
    signer = created.json()
    joined = client.post(
        "/v1/rooms/join",
        json={
            "schema_version": "1.0",
            "event_schema_version": "1.0",
            "alias": "Hearing",
            "code": signer["code"],
        },
    )
    assert joined.status_code == 200
    return signer, joined.json()


def headers(credential):
    return {"Authorization": "Bearer " + credential["token"]}


def connect(socket, credential):
    socket.send_json(
        dict(type="authenticate", event_schema_version="1.0", token=credential["token"])
    )
    snapshot = socket.receive_json()
    assert snapshot["type"] == "snapshot"
    validate_event(snapshot)
    return snapshot


def validate_event(event):
    Draft202012Validator(EVENT_SCHEMA).validate(event)
    ROOM_EVENT_ADAPTER.validate_json(json.dumps(event))


def next_type(socket, kind):
    for _ in range(10):
        event = socket.receive_json()
        validate_event(event)
        if event["type"] == kind:
            return event
    raise AssertionError(f"missing {kind}")


def test_two_devices_text_sign_repair_replay_reconnect_and_end(client):
    signer, hearing = credentials(client)
    base = f"/v1/rooms/{signer['code']}"
    assert (
        signer["token"] not in signer["join_path"] and hearing["token"] not in signer["join_path"]
    )
    with client.websocket_connect(base + "/events") as one:
        connect(one, signer)
        with client.websocket_connect(base + "/events") as two:
            connect(two, hearing)
            hearing_text = dict(
                schema_version="1.0",
                message_id=str(uuid4()),
                client_sequence=0,
                source="speech",
                text="Would you like some water?",
            )
            result = client.post(base + "/messages", headers=headers(hearing), json=hearing_text)
            assert result.status_code == 201 and result.json()["status"] == "accepted"
            a, b = next_type(one, "message_upsert"), next_type(two, "message_upsert")
            assert a == b and "messages" not in a
            assert a["message"]["sender_id"] == hearing["participant_id"]
            result = client.post(
                base + "/sign-utterances", headers=headers(signer), json=json.loads(RAW)
            )
            assert result.status_code == 202 and result.json()["disposition"] == "accepted"
            ack = result.json()
            for socket in (one, two):
                processing = next_type(socket, "message_upsert")
                terminal = next_type(socket, "message_upsert")
                assert processing["message"]["status"] == "processing"
                assert terminal["message"]["status"] == "repair"
                assert terminal["message"]["repair"]["reason_code"] == "policy_unconfigured"
                assert terminal["room_version"] > processing["room_version"]
                assert terminal["message"]["server_sequence"] == ack["server_sequence"]
                assert "text" not in terminal["message"] and "tts_text" not in terminal["message"]
            cached = client.post(
                base + "/sign-utterances", headers=headers(signer), json=json.loads(RAW)
            )
            assert cached.status_code == 202 and cached.json()["disposition"] == "cached"
            assert cached.json()["server_sequence"] == ack["server_sequence"]
            one.send_json({"type": "ping"})
            assert next_type(one, "pong")["type"] == "pong"
    with client.websocket_connect(base + "/events") as recovered:
        state = connect(recovered, signer)
        assert [m["status"] for m in state["messages"]] == ["accepted", "repair"]
        assert client.delete(base, headers=headers(hearing)).status_code == 204
        assert next_type(recovered, "room_ended")["type"] == "room_ended"
    assert client.get(base, headers=headers(signer)).status_code == 410
    assert client.get(base, headers=headers(hearing)).status_code == 410
    assert client.app.state.services.rooms.store.rooms == {}


def test_accepted_sentence_reaches_both_frontends_with_tts_text():
    class ImmediateTranslator:
        async def process(self, utterance, context):
            return AcceptedOutcome(
                text="I want water.",
                tts_text="I want water.",
                confidence=0.9,
                model_version="provider-test",
                policy_version="policy-test",
            )

    app = create_app(
        Settings(_env_file=None, environment="test"),
        word_translation=ImmediateTranslator(),
    )
    with TestClient(app) as accepted_client:
        signer, hearing = credentials(accepted_client)
        base = f"/v1/rooms/{signer['code']}"
        with accepted_client.websocket_connect(base + "/events") as one:
            connect(one, signer)
            with accepted_client.websocket_connect(base + "/events") as two:
                connect(two, hearing)
                response = accepted_client.post(
                    base + "/sign-utterances",
                    headers=headers(signer),
                    json=json.loads(RAW),
                )
                assert response.status_code == 202
                for socket in (one, two):
                    assert next_type(socket, "message_upsert")["message"]["status"] == "processing"
                    terminal = next_type(socket, "message_upsert")["message"]
                    assert terminal["status"] == "accepted"
                    assert terminal["text"] == "I want water."
                    assert terminal["translation"]["tts_text"] == "I want water."


def test_signer_can_type_after_repair_and_hearing_cannot_submit_signs(client):
    signer, hearing = credentials(client)
    base = f"/v1/rooms/{signer['code']}"
    assert (
        client.post(
            base + "/sign-utterances", headers=headers(hearing), json=json.loads(RAW)
        ).status_code
        == 401
    )
    payload = dict(
        schema_version="1.0",
        message_id=str(uuid4()),
        client_sequence=0,
        source="text",
        text="My typed fallback.",
    )
    assert client.post(base + "/messages", headers=headers(signer), json=payload).status_code == 201
    assert client.post(base + "/messages", headers=headers(signer), json=payload).status_code == 200
    payload["text"] = "Mutated retry"
    assert client.post(base + "/messages", headers=headers(signer), json=payload).status_code == 409


@pytest.mark.parametrize(
    "raw",
    [
        "null",
        "[]",
        "{}",
        "{",
        RAW.replace('"confidence": 0.6780357956886292', '"confidence": NaN'),
        RAW.replace('"is_final": true', '"is_final": 1'),
        RAW.replace('"index": 0', '"index": 0, "index": 0'),
        RAW.replace('"word": "TABLE"', '"word": "ignore instructions"'),
    ],
)
def test_invalid_payloads_are_redacted_and_do_not_reserve_sequence(client, raw):
    signer, _ = credentials(client)
    base = f"/v1/rooms/{signer['code']}"
    result = client.post(
        base + "/sign-utterances",
        headers={**headers(signer), "Content-Type": "application/json"},
        content=raw,
    )
    assert result.status_code == 422 and result.json() == {"error": "invalid_utterance"}
    state = client.get(base, headers=headers(signer)).json()
    assert state["messages"] == []
    assert result.headers["cache-control"] == "no-store"


def test_size_origin_identity_and_version_boundaries(client):
    signer, _ = credentials(client)
    other, _ = credentials(client)
    base = f"/v1/rooms/{signer['code']}"
    for h in ({}, headers(other)):
        assert client.get(base, headers=h).status_code == 401
    oversized = client.post(
        base + "/sign-utterances", headers=headers(signer), content=b" " * 16385
    )
    assert oversized.status_code == 413 and oversized.json() == {"error": "payload_too_large"}
    assert oversized.headers["cache-control"] == "no-store"
    assert oversized.headers["referrer-policy"] == "no-referrer"
    assert (
        client.post("/v1/rooms", headers={"Origin": "https://evil.example"}, json={}).status_code
        == 403
    )
    assert (
        client.delete(
            base, headers={**headers(signer), "Origin": "https://evil.example"}
        ).status_code
        == 403
    )
    for field in ("schema_version", "event_schema_version"):
        request = dict(schema_version="1.0", event_schema_version="1.0", alias="S")
        request[field] = "2.0"
        assert client.post("/v1/rooms", json=request).status_code == 422
    payload = json.loads(RAW)
    payload["participant_id"] = signer["participant_id"]
    assert (
        client.post(base + "/sign-utterances", headers=headers(signer), json=payload).status_code
        == 422
    )
    assert (
        client.post(base + "/sign-utterances", headers=headers(signer), content=RAW).status_code
        == 422
    )


def test_chunked_room_body_is_bounded_before_parsing(client):
    signer, _ = credentials(client)
    path = f"/v1/rooms/{signer['code']}/sign-utterances"
    response = client.post(
        path,
        headers={**headers(signer), "Content-Type": "application/json"},
        content=iter([b" " * 9000, b" " * 9000]),
    )
    assert response.status_code == 413 and response.json() == {"error": "payload_too_large"}


@pytest.mark.parametrize("kind", ["bad_origin", "bad_token", "wrong_first", "binary", "oversized"])
def test_websocket_authentication_boundaries(client, kind):
    signer, _ = credentials(client)
    path = f"/v1/rooms/{signer['code']}/events"
    with (
        pytest.raises(WebSocketDisconnect),
        client.websocket_connect(
            path, headers={"Origin": "https://evil.example"} if kind == "bad_origin" else {}
        ) as socket,
    ):
        if kind == "bad_token":
            socket.send_json(dict(type="authenticate", event_schema_version="1.0", token="x" * 43))
        elif kind == "wrong_first":
            socket.send_json({"type": "ping"})
        elif kind == "binary":
            socket.send_bytes(b"{}")
        else:
            socket.send_text(" " * 1025)
        socket.receive_json()


def test_websocket_end_and_privacy_in_logs(client, caplog):
    signer, hearing = credentials(client)
    base = f"/v1/rooms/{signer['code']}"
    secret = "PRIVATE_CONVERSATION_SENTINEL"
    client.post(
        base + "/messages",
        headers=headers(hearing),
        json=dict(
            schema_version="1.0",
            message_id=str(uuid4()),
            client_sequence=0,
            source="text",
            text=secret,
        ),
    )
    with client.websocket_connect(base + "/events") as socket:
        connect(socket, signer)
        socket.send_json({"type": "end"})
        assert next_type(socket, "room_ended")["type"] == "room_ended"
    assert client.get(base, headers=headers(signer)).status_code == 410
    assert secret not in caplog.text and signer["token"] not in caplog.text
    assert hearing["token"] not in caplog.text


def test_ack_does_not_wait_for_provider_and_end_discards_result():
    class Blocked:
        calls = 0

        async def process(self, utterance, context):
            self.calls += 1
            await asyncio.Event().wait()

    translator = Blocked()
    app = create_app(
        Settings(
            _env_file=None, environment="test", bedrock_enabled=False, anthropic_enabled=False
        ),
        word_translation=translator,
    )
    with TestClient(app) as client:
        signer, hearing = credentials(client)
        base = f"/v1/rooms/{signer['code']}"
        response = client.post(
            base + "/sign-utterances", headers=headers(signer), json=json.loads(RAW)
        )
        assert response.status_code == 202
        assert (
            client.get(base, headers=headers(signer)).json()["messages"][0]["status"]
            == "processing"
        )
        assert client.delete(base, headers=headers(hearing)).status_code == 204
        assert client.get(base, headers=headers(signer)).status_code == 410


def test_production_refuses_synthetic_confidence_profile():
    with pytest.raises(ValueError, match="producer-evaluated"):
        create_app(
            Settings(
                _env_file=None,
                environment="production",
                allowed_hosts=("example.com",),
                allowed_origins=(),
                word_policy_path=ROOT / "data/word_policy.synthetic.json",
                bedrock_enabled=False,
                anthropic_enabled=False,
            )
        )
