"""First-packet authentication, one bounded snapshot and incremental room events."""

import asyncio
import json
from time import perf_counter
from typing import cast

from fastapi import WebSocket, WebSocketDisconnect
from pydantic import TypeAdapter

from simplynext.contracts.room_events import Pong, RoomEnded, RoomError, RoomEvent
from simplynext.contracts.room_inputs import Activity, Authenticate, EndRoom, SocketInput
from simplynext.contracts.translated_sign_utterance import parse_value, strict_json
from simplynext.rooms.service import RoomService
from simplynext.rooms.store import RoomFailure

SOCKET_INPUT: TypeAdapter[SocketInput] = TypeAdapter(SocketInput)


async def packet(socket: WebSocket) -> str:
    message = await socket.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect()
    raw = message.get("text")
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > 1024:
        raise ValueError("invalid_control")
    return raw


async def room_socket(socket: WebSocket, code: str) -> None:
    services = socket.app.state.services
    origin = socket.headers.get("origin")
    if origin is not None and origin not in services.settings.allowed_origins:
        await socket.close(code=4403)
        return
    await socket.accept()
    service = cast(RoomService, services.rooms)
    store = service.store
    tasks: list[asyncio.Task[None]] = []
    try:
        raw = await asyncio.wait_for(packet(socket), timeout=10)
        auth = parse_value(Authenticate, raw, max_bytes=1024)
        room = store.get(code)
        async with room.lock:
            participant = store.authenticate(room, auth.token)
            queue = store.subscribe(room, participant)
        # The reader/writer closures retain only server identity after authentication.
        del auth, raw

        async def write_events() -> None:
            while True:
                event: RoomEvent = await queue.get()
                started = perf_counter()
                await asyncio.wait_for(
                    socket.send_json(event.model_dump(mode="json", exclude_none=True)),
                    timeout=5,
                )
                services.metrics.observe_ms("room_socket_send", (perf_counter() - started) * 1000)
                if isinstance(event, RoomEnded):
                    await socket.close(code=1000)
                    return
                if isinstance(event, RoomError) and event.code == "resync_required":
                    await socket.close(code=1013)
                    return

        async def read_controls() -> None:
            while True:
                raw_control = await packet(socket)
                value = strict_json(raw_control, max_bytes=1024)
                control = SOCKET_INPUT.validate_json(json.dumps(value, allow_nan=False))
                async with room.lock:
                    store.require_participant(room, participant)
                    if isinstance(control, EndRoom):
                        store.erase(room)
                        # Let the writer deliver room_ended and close the socket.
                        return
                    store._rate(participant.control_times, 120)
                    if isinstance(control, Activity):
                        store.activity(room, participant, control)
                    elif not queue.full():
                        queue.put_nowait(Pong(room_version=room.version))

        writer = asyncio.create_task(write_events())
        reader = asyncio.create_task(read_controls())
        tasks = [writer, reader]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
            if reader in done and room.state == "ended":
                await writer
        finally:
            for task in tasks:
                task.cancel()
            # No await here: disconnect cancellation must not strand a subscriber.
            # All store mutations are synchronous within the single event loop.
            store.unsubscribe(room, participant, queue)
            while not queue.empty():
                queue.get_nowait()
            await asyncio.gather(*tasks, return_exceptions=True)
    except asyncio.CancelledError:
        # ASGI server/test-client cancellation is also a disconnect. Cleanup above
        # has already detached the subscriber and cancelled both socket tasks.
        pass
    except WebSocketDisconnect:
        pass
    except RoomFailure as exc:
        await socket.close(code=4401 if exc.status == 401 else 4410 if exc.status == 410 else 4429)
    except (ValueError, UnicodeError, RecursionError, TimeoutError):
        await socket.close(code=4400)
