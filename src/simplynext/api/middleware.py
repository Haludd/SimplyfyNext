"""Transport-level resource limits applied before request parsing."""

from __future__ import annotations

import asyncio
import hashlib
from collections import deque
from time import monotonic

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class RequestBodyLimitMiddleware:
    """Reject oversized HTTP bodies even when content length is omitted."""

    def __init__(
        self, app: ASGIApp, *, max_bytes: int, room_prefix: str = "/v1/rooms",
        timeout_seconds: float = 10,
    ) -> None:
        if max_bytes < 1:
            raise ValueError("max_bytes must be positive")
        self.app = app
        self.max_bytes = max_bytes
        self.room_prefix = room_prefix
        self.timeout_seconds = timeout_seconds

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "")
        is_room = path == self.room_prefix or path.startswith(self.room_prefix + "/")
        max_bytes = min(self.max_bytes, 16_384) if is_room else self.max_bytes
        original_send = send

        async def private_send(message: Message) -> None:
            if message["type"] == "http.response.start":
                message["headers"] = list(message.get("headers", [])) + [
                    (b"cache-control", b"no-store"),
                    (b"referrer-policy", b"no-referrer"),
                ]
            await original_send(message)

        if is_room:
            send = private_send

        header_map = dict(scope.get("headers", ()))
        raw_content_length = header_map.get(b"content-length")
        if raw_content_length is not None:
            try:
                if int(raw_content_length) > max_bytes:
                    await self._reject(scope, receive, send)
                    return
            except ValueError:
                pass

        body = bytearray()
        try:
            async with asyncio.timeout(self.timeout_seconds):
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    if message["type"] != "http.request":
                        continue
                    body.extend(message.get("body", b""))
                    if len(body) > max_bytes:
                        await self._reject(scope, receive, send)
                        return
                    if not message.get("more_body", False):
                        break
        except TimeoutError:
            await JSONResponse({"error": "request_timeout"}, status_code=408)(scope, receive, send)
            return
        buffered: deque[Message] = deque([
            {"type": "http.request", "body": bytes(body), "more_body": False}
        ])
        body.clear()

        async def receive_replayed() -> Message:
            return buffered.popleft() if buffered else await receive()

        await self.app(scope, receive_replayed, send)

    async def _reject(self, scope: Scope, receive: Receive, send: Send) -> None:
        path = scope.get("path", "")
        body = {"detail": "Request body exceeds the configured size limit."}
        if path == self.room_prefix or path.startswith(self.room_prefix + "/"):
            body = {"error": "payload_too_large"}
        response = JSONResponse(
            body,
            status_code=413,
        )
        await response(scope, receive, send)


class PrivacyHeadersMiddleware:
    """Cover diagnostics, origin/host errors and normal responses alike."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        async def private_send(message: Message) -> None:
            if message["type"] in {"http.response.start", "websocket.accept"}:
                headers = [(k, v) for k, v in message.get("headers", []) if k.lower() not in {
                    b"cache-control", b"referrer-policy", b"x-content-type-options",
                }]
                message["headers"] = headers + [
                    (b"cache-control", b"no-store"),
                    (b"referrer-policy", b"no-referrer"),
                    (b"x-content-type-options", b"nosniff"),
                ]
            await send(message)

        await self.app(scope, receive, private_send)


class SocketAdmissionMiddleware:
    """Bound all open sockets, including peers that never authenticate."""

    def __init__(
        self, app: ASGIApp, *, maximum: int, per_minute: int, global_per_minute: int,
    ) -> None:
        self.app = app
        self.maximum = maximum
        self.per_minute = per_minute
        self.global_per_minute = global_per_minute
        self.active = 0
        self.attempts: deque[float] = deque()
        self.peers: dict[str, deque[float]] = {}

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "websocket":
            await self.app(scope, receive, send)
            return
        now = monotonic()
        while self.attempts and self.attempts[0] <= now - 60:
            self.attempts.popleft()
        self.peers = {key: times for key, times in self.peers.items() if times[-1] > now - 60}
        if self.active >= self.maximum or len(self.attempts) >= self.global_per_minute:
            await send({"type": "websocket.close", "code": 4429})
            return
        self.attempts.append(now)
        peer = (scope.get("client") or ("unknown", 0))[0]
        key = hashlib.sha256(peer.encode()).hexdigest()
        times = self.peers.setdefault(key, deque())
        while times and times[0] <= now - 60:
            times.popleft()
        if len(times) >= self.per_minute:
            await send({"type": "websocket.close", "code": 4429})
            return
        times.append(now)
        self.active += 1
        try:
            await self.app(scope, receive, send)
        finally:
            self.active -= 1
