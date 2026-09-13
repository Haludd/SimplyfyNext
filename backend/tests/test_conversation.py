"""Real HTTP/WebSocket contracts for the independent words-only room service."""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from simplynext.conversation.app import create_app
from simplynext.conversation.contracts import TranslationResult, WordsInput
from simplynext.conversation.store import RoomStore


def create(client: TestClient, name: str = "Alex") -> dict[str, str]:
    response = client.post("/api/rooms", json={"name": name, "mode": "sign"})
    assert response.status_code == 201
    return response.json()


def join(client: TestClient, host: dict[str, str]) -> dict[str, str]:
    response = client.post(
        "/api/rooms/join", json={"code": host["code"], "name": "Sam", "mode": "speech"}
    )
    assert response.status_code == 201
    return response.json()


def headers(person: dict[str, str]) -> dict[str, str]:
    return {"Authorization": f"Bearer {person['token']}"}


def path(person: dict[str, str], suffix: str = "") -> str:
    return f"/api/rooms/{person['code']}{suffix}"


def words(score: float = 0.96) -> dict[str, Any]:
    return {"message_id": str(uuid4()), "words": [{"word": "HELLO", "confidence": score}]}


def until_message(socket: Any, message_id: str, status: str) -> dict[str, Any]:
    for _ in range(10):
        packet = socket.receive_json()
        if any(m["id"] == message_id and m["status"] == status for m in packet.get("messages", [])):
            return packet
    raise AssertionError("message not broadcast")


def test_two_devices_words_speech_repair_reconnect_and_end() -> None:
    with TestClient(create_app()) as client:
        host = create(client)
        guest = join(client, host)
        assert host["token"] != guest["token"]
        with client.websocket_connect(path(host, "/events")) as a:
            a.send_json({"type": "authenticate", "token": host["token"]})
            assert a.receive_json()["type"] == "snapshot"
            with client.websocket_connect(path(guest, "/events")) as b:
                b.send_json({"type": "authenticate", "token": guest["token"]})
                assert len(b.receive_json()["participants"]) == 2
                payload = words()
                result = client.post(path(host, "/words"), headers=headers(host), json=payload)
                assert result.status_code == 200
                assert result.json()["text"] == "HELLO"
                assert result.json()["demo"] is True
                assert (
                    until_message(a, payload["message_id"], "accepted")["messages"]
                    == until_message(b, payload["message_id"], "accepted")["messages"]
                )
                reply = {"message_id": str(uuid4()), "text": "Hello back!", "source": "speech"}
                assert (
                    client.post(
                        path(guest, "/messages"), headers=headers(guest), json=reply
                    ).status_code
                    == 200
                )
                assert (
                    until_message(a, reply["message_id"], "accepted")["messages"][-1]["sender_id"]
                    == guest["participant_id"]
                )
                repair = client.post(
                    path(host, "/words"), headers=headers(host), json=words(0.3)
                ).json()
                assert repair["status"] == "repair"
                assert repair["text"] is None
                assert "repeat" in repair["prompt"]
        with client.websocket_connect(path(guest, "/events")) as reconnected:
            reconnected.send_json({"type": "authenticate", "token": guest["token"]})
            assert len(reconnected.receive_json()["messages"]) == 3
            assert client.delete(path(host), headers=headers(host)).status_code == 204
            assert reconnected.receive_json() == {"type": "ended"}
        assert client.get(path(host), headers=headers(host)).status_code == 410


def test_message_retry_is_idempotent_and_conflicts_are_rejected() -> None:
    with TestClient(create_app()) as client:
        host = create(client)
        payload = words()
        first = client.post(path(host, "/words"), headers=headers(host), json=payload)
        retry = client.post(path(host, "/words"), headers=headers(host), json=payload)
        assert first.json() == retry.json()
        payload["words"][0]["word"] = "HELP"
        assert (
            client.post(path(host, "/words"), headers=headers(host), json=payload).status_code
            == 409
        )
        assert len(client.get(path(host), headers=headers(host)).json()["messages"]) == 1


@pytest.mark.parametrize(
    "bad_words",
    [
        [],
        [{"word": "HELLO", "confidence": -0.1}],
        [{"word": "HELLO", "confidence": 1.1}],
        [{"word": "HELLO", "confidence": "0.9"}],
        [{"word": "HELLO", "confidence": True}],
        [{"word": "", "confidence": 0.9}],
        [{"word": "HELLO"}],
        [{"word": "HELLO", "confidence": 0.9, "landmarks": [1, 2]}],
        [{"word": "HELLO", "confidence": 0.9}] * 65,
    ],
)
def test_invalid_recognition_never_reaches_room(bad_words: list[Any]) -> None:
    with TestClient(create_app()) as client:
        host = create(client)
        payload = {"message_id": str(uuid4()), "words": bad_words}
        assert (
            client.post(path(host, "/words"), headers=headers(host), json=payload).status_code
            == 422
        )
        assert not client.get(path(host), headers=headers(host)).json()["messages"]


def test_authentication_room_isolation_capacity_and_body_limit() -> None:
    with TestClient(create_app()) as client:
        host = create(client)
        other_room = create(client)
        assert client.get(path(host)).status_code == 401
        assert client.get(path(host), headers=headers(other_room)).status_code == 401
        assert (
            client.post(
                path(host, "/messages"),
                headers=headers(other_room),
                json={"message_id": str(uuid4()), "text": "intruder"},
            ).status_code
            == 401
        )
        join(client, host)
        third = client.post("/api/rooms/join", json={"code": host["code"], "name": "Third"})
        assert third.status_code == 409
        spoof = {
            "message_id": str(uuid4()),
            "text": "spoof",
            "sender_id": other_room["participant_id"],
        }
        assert (
            client.post(path(host, "/messages"), headers=headers(host), json=spoof).status_code
            == 422
        )
        assert (
            client.post(
                path(host, "/words"), headers=headers(host), content="x" * 17000
            ).status_code
            == 413
        )
        with client.websocket_connect(path(host, "/events")) as socket:
            socket.send_json({"type": "authenticate", "token": other_room["token"]})
            assert socket.receive()["code"] == 4401
        with (
            pytest.raises(Exception) as rejected,
            client.websocket_connect(
                path(host, "/events"), headers={"origin": "https://foreign.example"}
            ),
        ):
            pass
        assert rejected.value.code == 4403


def test_expiry_and_invitation_lifetime() -> None:
    store = RoomStore()
    with TestClient(create_app(store=store)) as client:
        host = create(client)
        store.rooms[host["code"]].join_until = 0
        assert (
            client.post("/api/rooms/join", json={"code": host["code"], "name": "Late"}).status_code
            == 410
        )
        store.rooms[host["code"]].expires_at = 0
        assert client.get(path(host), headers=headers(host)).status_code == 410
        assert not store.rooms


class CapturingTranslator:
    mode = "http"

    def __init__(self) -> None:
        self.history: list[dict[str, str]] = []
        self.calls = 0

    async def translate(
        self, payload: WordsInput, context: list[dict[str, str]]
    ) -> TranslationResult:
        self.calls += 1
        self.history = context
        return TranslationResult(status="accepted", text="Hello!")


def test_translation_adapter_receives_both_speakers_without_repair_or_current_input() -> None:
    translator = CapturingTranslator()
    with TestClient(create_app(translator=translator)) as client:
        host = create(client)
        guest = join(client, host)
        for person, text in [(host, "Where is the bus?"), (guest, "Around the corner.")]:
            client.post(
                path(person, "/messages"),
                headers=headers(person),
                json={"message_id": str(uuid4()), "text": text},
            )
        client.post(path(host, "/words"), headers=headers(host), json=words(0.2))
        assert translator.calls == 0
        response = client.post(path(host, "/words"), headers=headers(host), json=words())
        assert response.json()["demo"] is False
        assert translator.calls == 1
        assert [m["sender_id"] for m in translator.history] == [
            host["participant_id"],
            guest["participant_id"],
        ]
        assert [m["text"] for m in translator.history] == [
            "Where is the bus?",
            "Around the corner.",
        ]


class BrokenTranslator:
    mode = "http"

    async def translate(
        self, payload: WordsInput, context: list[dict[str, str]]
    ) -> TranslationResult:
        raise RuntimeError("private provider failure")


def test_translation_failure_becomes_repair_without_provider_details() -> None:
    with TestClient(create_app(translator=BrokenTranslator())) as client:
        host = create(client)
        response = client.post(path(host, "/words"), headers=headers(host), json=words())
        assert response.status_code == 200
        assert response.json()["status"] == "repair"
        assert response.json()["text"] is None
        assert "private" not in response.text


def test_static_ui_is_served_without_ai_dependencies_or_remote_scripts() -> None:
    with TestClient(create_app()) as client:
        response = client.get("/conversation")
        assert response.status_code == 200
        assert "Your side of the conversation" in response.text
        assert "script-src 'self'" in response.headers["content-security-policy"]
        assert client.get("/conversation-assets/app.js").status_code == 200
        assert client.get("/conversation-assets/vendor/qrcode.js").status_code == 200
        assert client.get("/healthz").json()["translation_mode"] == "demo"


@pytest.mark.asyncio
async def test_http_adapter_sends_only_words_and_bounded_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import json

    import httpx

    from simplynext.conversation.translation import HttpTranslator

    captured: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(200, json={"status": "accepted", "text": "Hello!"})

    original_client = httpx.AsyncClient
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda **kwargs: original_client(transport=httpx.MockTransport(respond), **kwargs),
    )
    payload = WordsInput.model_validate(words())
    context = [{"message_id": "prior", "sender_id": "sam", "source": "speech", "text": "Hi"}]
    result = await HttpTranslator("https://translator.example/translate", "test-secret").translate(
        payload, context
    )
    assert result.text == "Hello!"
    assert captured[0].headers["authorization"] == "Bearer test-secret"
    assert json.loads(captured[0].content) == {
        **payload.model_dump(mode="json"),
        "context": context,
    }


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "reply",
    [
        {"status": "repair", "prompt": "Repeat", "text": "invented"},
        {"status": "accepted"},
        {"status": "accepted", "text": "x" * 17000},
    ],
)
async def test_http_adapter_rejects_invalid_or_oversized_output(
    monkeypatch: pytest.MonkeyPatch, reply: dict[str, str]
) -> None:
    import httpx

    from simplynext.conversation.translation import HttpTranslator

    original_client = httpx.AsyncClient
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda **kwargs: original_client(
            transport=httpx.MockTransport(lambda _: httpx.Response(200, json=reply)),
            **kwargs,
        ),
    )
    with pytest.raises(ValueError):
        await HttpTranslator("https://translator.example/translate").translate(
            WordsInput.model_validate(words()), []
        )
