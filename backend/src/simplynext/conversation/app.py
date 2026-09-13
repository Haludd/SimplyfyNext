"""Run: python -m uvicorn simplynext.conversation.app:app --port 8000 --workers 1."""

import asyncio
import hashlib
import os
from collections import deque
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from time import monotonic, time
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import TypeAdapter

from simplynext.api.middleware import RequestBodyLimitMiddleware

from .contracts import (
    Activity,
    Authenticate,
    JoinInput,
    ParticipantInput,
    SocketInput,
    TextInput,
    TranslationResult,
    WordsInput,
)
from .store import Participant, Room, RoomStore
from .translation import DemoTranslator, HttpTranslator, Translator

STATIC = Path(__file__).parent / "web"
SOCKET_INPUT: TypeAdapter[SocketInput] = TypeAdapter(SocketInput)


def create_app(
    *,
    translator: Translator | None = None,
    store: RoomStore | None = None,
    confidence_threshold: float = 0.75,
) -> FastAPI:
    rooms = store if store is not None else RoomStore()
    endpoint = os.getenv("CONVERSATION_TRANSLATOR_URL")
    engine = translator or (
        HttpTranslator(endpoint, os.getenv("CONVERSATION_TRANSLATOR_TOKEN"))
        if endpoint
        else DemoTranslator()
    )
    # Bounded process-local invitation throttling, independent of room existence.
    attempts: dict[str, deque[float]] = {}

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        async def expire_rooms() -> None:
            while True:
                await asyncio.sleep(5)
                rooms.expire()

        task = asyncio.create_task(expire_rooms())
        try:
            yield
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task

    app = FastAPI(title="SignBridge conversations", lifespan=lifespan)
    app.state.rooms = rooms
    app.add_middleware(RequestBodyLimitMiddleware, max_bytes=16384)
    origins = [
        s.strip() for s in os.getenv("CONVERSATION_ALLOWED_ORIGINS", "").split(",") if s.strip()
    ]
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_methods=["GET", "POST", "DELETE"],
            allow_headers=["Authorization", "Content-Type"],
        )

    @app.middleware("http")
    async def headers(request: Request, call_next: Any) -> Any:
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'; media-src 'self' blob:; "
            "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        )
        return response

    def throttle(request: Request) -> None:
        now = monotonic()
        for key in list(attempts):
            if not attempts[key] or attempts[key][-1] < now - 60:
                del attempts[key]
        ip = request.client.host if request.client else "unknown"
        if ip not in attempts and len(attempts) >= 2048:
            raise HTTPException(429, "Please wait before trying again.")
        bucket = attempts.setdefault(ip, deque())
        while bucket and bucket[0] < now - 60:
            bucket.popleft()
        if len(bucket) >= 20:
            raise HTTPException(429, "Too many invitations. Please wait one minute.")
        bucket.append(now)

    def auth(code: str, authorization: str | None) -> tuple[Room, Participant]:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(401, "Room credentials required.")
        return rooms.authenticate(code, authorization[7:])

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok", "translation_mode": engine.mode}

    @app.get("/")
    async def root() -> RedirectResponse:
        return RedirectResponse("/conversation")

    @app.get("/conversation")
    async def page() -> FileResponse:
        return FileResponse(STATIC / "index.html")

    @app.post("/api/rooms", status_code=201)
    async def create(payload: ParticipantInput, request: Request) -> dict[str, str]:
        throttle(request)
        return rooms.create(payload.name, payload.mode)

    @app.post("/api/rooms/join", status_code=201)
    async def join(payload: JoinInput, request: Request) -> dict[str, str]:
        throttle(request)
        return rooms.join(payload.code, payload.name, payload.mode)

    @app.get("/api/rooms/{code}")
    async def snapshot(code: str, authorization: str | None = Header(None)) -> dict[str, Any]:
        room, _ = auth(code, authorization)
        return rooms.snapshot(room)

    @app.delete("/api/rooms/{code}", status_code=204)
    async def end(code: str, authorization: str | None = Header(None)) -> None:
        room, _ = auth(code, authorization)
        rooms.end(room)

    async def submit(
        code: str,
        payload: TextInput | WordsInput,
        authorization: str | None,
    ) -> dict[str, Any]:
        room, participant = auth(code, authorization)
        request_id = (participant.id, str(payload.message_id))
        digest = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()
        async with room.lock:
            # A room can expire or be ended while a previous translation is running.
            rooms.get(code)
            existing = room.requests.get(request_id)
            if existing:
                if existing[0] != digest:
                    raise HTTPException(
                        409, "This message ID was already used for different content."
                    )
                return existing[1]
            if len(room.messages) >= 300:
                raise HTTPException(409, "This conversation is full. Start a new room.")
            now = time()
            recent = [
                m
                for m in room.messages
                if m["sender_id"] == participant.id and m["created_at"] > now - 10
            ]
            if len(recent) >= 10:
                raise HTTPException(429, "Please slow down before sending another message.")
            message: dict[str, Any] = {
                "id": str(payload.message_id),
                "sender_id": participant.id,
                "sequence": len(room.messages) + 1,
                "created_at": now,
                "source": "sign" if isinstance(payload, WordsInput) else payload.source,
                "status": "processing",
                "text": None,
                "prompt": None,
                "demo": isinstance(payload, WordsInput) and engine.mode == "demo",
            }
            room.messages.append(message)
            room.requests[request_id] = (digest, message)
            participant.activity = "idle"
            rooms.publish(room)
            if isinstance(payload, TextInput):
                result = TranslationResult(status="accepted", text=payload.text)
            elif any(word.confidence < confidence_threshold for word in payload.words):
                result = TranslationResult(
                    status="repair",
                    prompt="Some signs were unclear. Please repeat or type your message.",
                )
            else:
                context = [
                    {
                        "message_id": m["id"],
                        "sender_id": m["sender_id"],
                        "source": m["source"],
                        "text": m["text"],
                    }
                    for m in room.messages
                    if m["status"] == "accepted"
                ][-30:]
                try:
                    result = await asyncio.wait_for(engine.translate(payload, context), timeout=15)
                except Exception:
                    # Do not leak provider responses or credentials to clients/logs.
                    result = TranslationResult(
                        status="repair",
                        prompt="Translation is unavailable. Please try again or type your message.",
                    )
            if room.closed or time() > room.expires_at:
                rooms.end(room)
                raise HTTPException(410, "This conversation has ended.")
            message.update(result.model_dump())
            rooms.publish(room)
            return message

    @app.post("/api/rooms/{code}/messages")
    async def text_message(
        code: str,
        payload: TextInput,
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        return await submit(code, payload, authorization)

    @app.post("/api/rooms/{code}/words")
    async def words_message(
        code: str,
        payload: WordsInput,
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        return await submit(code, payload, authorization)

    @app.websocket("/api/rooms/{code}/events")
    async def events(socket: WebSocket, code: str) -> None:
        origin = socket.headers.get("origin")
        own_origin = (
            f"{'https' if socket.url.scheme == 'wss' else 'http'}://{socket.headers.get('host')}"
        )
        if origin and origin != own_origin and origin not in origins:
            await socket.close(code=4403)
            return
        await socket.accept()
        try:
            raw = await asyncio.wait_for(socket.receive_text(), timeout=10)
            if len(raw.encode()) > 2048:
                raise ValueError("oversized authentication")
            packet = Authenticate.model_validate_json(raw)
            room, participant = rooms.authenticate(code, packet.token)
            if len(participant.subscribers) >= 2:
                raise ValueError("too many connections")
        except (TimeoutError, ValueError, HTTPException, WebSocketDisconnect):
            await socket.close(code=4401)
            return
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=1)
        participant.subscribers.add(queue)
        rooms.publish(room)

        async def read() -> None:
            while True:
                raw = await asyncio.wait_for(socket.receive_text(), timeout=45)
                if len(raw.encode()) > 2048:
                    raise ValueError("oversized event")
                event = SOCKET_INPUT.validate_json(raw)
                rooms.get(code)
                if isinstance(event, Activity):
                    if time() - participant.activity_at < 0.3:
                        continue
                    participant.activity = event.state
                    participant.activity_at = time()
                rooms.publish(room)

        async def write() -> None:
            while True:
                packet = await queue.get()
                await asyncio.wait_for(socket.send_json(packet), timeout=5)
                if packet["type"] == "ended":
                    await socket.close(code=1000)
                    return

        tasks = [asyncio.create_task(read()), asyncio.create_task(write())]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            participant.subscribers.discard(queue)
            if not participant.subscribers:
                participant.activity = "idle"
            rooms.publish(room)
            with suppress(RuntimeError, WebSocketDisconnect):
                await socket.close()

    app.mount("/conversation-assets", StaticFiles(directory=STATIC), name="conversation-assets")
    return app


app = create_app()
