"""Transport-level resource limits applied before request parsing."""

from __future__ import annotations

from collections import deque

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class RequestBodyLimitMiddleware:
    """Reject oversized HTTP bodies even when content length is omitted."""

    def __init__(self, app: ASGIApp, *, max_bytes: int, room_prefix: str = "/v1/rooms") -> None:
        if max_bytes < 1:
            raise ValueError("max_bytes must be positive")
        self.app = app
        self.max_bytes = max_bytes
        self.room_prefix = room_prefix

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

        received = 0
        buffered: deque[Message] = deque()
        while True:
            message = await receive()
            buffered.append(message)
            if message["type"] == "http.disconnect":
                break
            if message["type"] != "http.request":
                continue
            received += len(message.get("body", b""))
            if received > max_bytes:
                await self._reject(scope, receive, send)
                return
            if not message.get("more_body", False):
                break

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
