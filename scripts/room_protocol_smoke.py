"""No-spend two-participant room smoke. Never prints capabilities or conversation text."""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from typing import Any
from uuid import uuid4

import httpx
from websockets.asyncio.client import connect


async def run_smoke(base_url: str, *, templates: bool = False) -> None:
    base_url = base_url.rstrip("/")
    ws_base = base_url.replace("https://", "wss://", 1).replace("http://", "ws://", 1)
    async with httpx.AsyncClient(timeout=10) as client:
        if templates:
            readiness = (await client.get(base_url + "/readyz")).json()
            if readiness["rooms"]["word_provider"] != "deterministic":
                raise RuntimeError("template smoke refuses a hosted provider")
        response = await client.post(
            base_url + "/v1/rooms",
            json={
                "schema_version": "1.0",
                "event_schema_version": "1.0",
                "alias": "Smoke signer",
            },
        )
        response.raise_for_status()
        signer = response.json()
        room_url = base_url + "/v1/rooms/" + signer["code"]
        signer_headers = {"Authorization": "Bearer " + signer["token"]}
        try:
            response = await client.post(
                base_url + "/v1/rooms/join",
                json={
                    "schema_version": "1.0",
                    "event_schema_version": "1.0",
                    "alias": "Smoke hearing",
                    "code": signer["code"],
                },
            )
            response.raise_for_status()
            hearing = response.json()
            hearing_headers = {"Authorization": "Bearer " + hearing["token"]}
            ws_url = ws_base + "/v1/rooms/" + signer["code"] + "/events"
            async with (
                connect(ws_url, max_size=1_000_000) as first,
                connect(
                    ws_url,
                    max_size=1_000_000,
                ) as second,
            ):
                for socket, credential in ((first, signer), (second, hearing)):
                    await socket.send(
                        json.dumps(
                            {
                                "type": "authenticate",
                                "event_schema_version": "1.0",
                                "token": credential["token"],
                            }
                        )
                    )
                    assert json.loads(await socket.recv())["type"] == "snapshot"
                payload = json.loads(
                    (
                        Path(__file__).parents[1]
                        / "tests/fixtures/translated_sign_utterance_v1.json"
                    ).read_text()
                )
                payload["message_id"] = str(uuid4())
                payload["words"] = [
                    dict(
                        index=0,
                        token_id="w0",
                        word="HELLO",
                        confidence=0.9 if templates else 0.0,
                        alternatives=[],
                    )
                ]
                response = await client.post(
                    room_url + "/sign-utterances", headers=signer_headers, json=payload
                )
                assert response.status_code == 202

                async def terminal(socket: Any) -> dict[str, Any]:
                    async with asyncio.timeout(10):
                        while True:
                            event = json.loads(await socket.recv())
                            message = event.get("message", {})
                            if message.get("message_id") == payload["message_id"] and (
                                message.get("status") != "processing"
                            ):
                                return dict(message)

                one, two = await asyncio.gather(terminal(first), terminal(second))
                assert one == two and one["status"] == ("accepted" if templates else "repair")
                response = await client.post(
                    room_url + "/messages",
                    headers=hearing_headers,
                    json={
                        "schema_version": "1.0",
                        "message_id": str(uuid4()),
                        "client_sequence": 0,
                        "source": "text",
                        "text": "Hello.",
                    },
                )
                assert response.status_code == 201
                retry = await client.post(
                    room_url + "/sign-utterances", headers=signer_headers, json=payload
                )
                assert retry.status_code == 202 and retry.json()["disposition"] == "cached"
            async with connect(ws_url, max_size=1_000_000) as recovery:
                await recovery.send(
                    json.dumps(
                        {
                            "type": "authenticate",
                            "event_schema_version": "1.0",
                            "token": signer["token"],
                        }
                    )
                )
                snapshot = json.loads(await recovery.recv())
                assert len(snapshot["messages"]) == 2
                assert (await client.delete(room_url, headers=hearing_headers)).status_code == 204
                async with asyncio.timeout(10):
                    while json.loads(await recovery.recv())["type"] != "room_ended":
                        pass
            assert (await client.get(room_url, headers=signer_headers)).status_code == 410
        finally:
            await client.delete(room_url, headers=signer_headers)
    print("Room smoke passed: two devices, text, sign, terminal, retry, recovery, complete end.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--templates", action="store_true")
    args = parser.parse_args()
    asyncio.run(run_smoke(args.base_url, templates=args.templates))


if __name__ == "__main__":
    main()
