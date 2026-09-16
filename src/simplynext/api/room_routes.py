"""Bounded v1 room HTTP transport; capabilities never come from request identities."""

import logging
from typing import TypeVar, cast

from fastapi import APIRouter, Request
from pydantic import BaseModel
from starlette.responses import JSONResponse, Response

from simplynext.contracts.room_inputs import CreateRoom, JoinRoom, TextMessage
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1, parse_value
from simplynext.rooms.service import RoomService
from simplynext.rooms.store import RoomFailure

room_router = APIRouter()
T = TypeVar("T", bound=BaseModel)
logger = logging.getLogger(__name__)


def service_for(request: Request) -> RoomService:
    return cast(RoomService, request.app.state.services.rooms)


def bearer(request: Request) -> str:
    authorization = request.headers.get("authorization", "")
    if not authorization.startswith("Bearer "):
        raise RoomFailure(401, "unauthorized")
    return authorization[7:]


def require_origin(request: Request) -> None:
    origin = request.headers.get("origin")
    if origin is not None and origin not in request.app.state.services.settings.allowed_origins:
        raise RoomFailure(403, "origin_rejected")


async def read_input(request: Request, model: type[T]) -> T:
    if request.headers.get("content-type", "").split(";", 1)[0].lower() != "application/json":
        raise RoomFailure(422, "invalid_utterance")
    try:
        return parse_value(model, await request.body())
    except (ValueError, UnicodeError, RecursionError):
        raise RoomFailure(422, "invalid_utterance") from None


def reply(model: BaseModel, status: int = 200) -> JSONResponse:
    return JSONResponse(model.model_dump(mode="json", exclude_none=True), status_code=status)


def trace_room_transport(
    request: Request,
    *,
    direction: str,
    endpoint: str,
    payload: BaseModel,
) -> None:
    """Log only finalized room content during an explicitly enabled local demo.

    This route layer never receives a camera frame or landmark payload. Room
    capabilities live in the Authorization header and are intentionally not
    read into the trace.
    """

    settings = request.app.state.services.settings
    if not settings.transport_trace_enabled:
        return
    logger.info(
        "room_transport_trace",
        extra={
            "room_transport": {
                "direction": direction,
                "endpoint": endpoint,
                "payload": payload.model_dump(mode="json", exclude_none=True),
            }
        },
    )


@room_router.post("/rooms")
async def create_room(request: Request) -> JSONResponse:
    require_origin(request)
    inputs = await read_input(request, CreateRoom)
    result = await service_for(request).store.create(
        inputs,
        address=request.client.host if request.client else "unknown",
    )
    return reply(result, 201)


@room_router.post("/rooms/join")
async def join_room(request: Request) -> JSONResponse:
    require_origin(request)
    inputs = await read_input(request, JoinRoom)
    result = await service_for(request).store.join(
        inputs,
        address=request.client.host if request.client else "unknown",
    )
    return reply(result)


@room_router.get("/rooms/{code}")
async def get_room(request: Request, code: str) -> JSONResponse:
    require_origin(request)
    store = service_for(request).store
    room = store.get(code)
    async with room.lock:
        store.authenticate(room, bearer(request))
        # Always recover all bounded messages; a sequence-only filter can miss
        # terminal transitions of a previously received processing message.
        return reply(store.snapshot(room))


@room_router.delete("/rooms/{code}")
async def delete_room(request: Request, code: str) -> Response:
    require_origin(request)
    store = service_for(request).store
    room = store.get(code)
    async with room.lock:
        store.authenticate(room, bearer(request))
        store.erase(room)
    return Response(status_code=204)


async def submit(request: Request, code: str, model: type[T]) -> T:
    require_origin(request)
    store = service_for(request).store
    room = store.get(code)
    async with room.lock:
        store.authenticate(room, bearer(request))
    return await read_input(request, model)


@room_router.post("/rooms/{code}/sign-utterances")
async def sign_utterance(request: Request, code: str) -> JSONResponse:
    inputs = await submit(request, code, TranslatedSignUtteranceV1)
    trace_room_transport(
        request,
        direction="frontend_to_backend",
        endpoint="POST /v1/rooms/{code}/sign-utterances",
        payload=inputs,
    )
    admission = await service_for(request).submit(code, bearer(request), inputs)
    trace_room_transport(
        request,
        direction="backend_to_frontend",
        endpoint="HTTP 202 /v1/rooms/{code}/sign-utterances",
        payload=admission.ack,
    )
    return reply(admission.ack, 202)


@room_router.post("/rooms/{code}/messages")
async def text_message(request: Request, code: str) -> JSONResponse:
    inputs = await submit(request, code, TextMessage)
    trace_room_transport(
        request,
        direction="frontend_to_backend",
        endpoint="POST /v1/rooms/{code}/messages",
        payload=inputs,
    )
    admission = await service_for(request).submit(code, bearer(request), inputs)
    trace_room_transport(
        request,
        direction="backend_to_frontend",
        endpoint="HTTP 200/201 /v1/rooms/{code}/messages",
        payload=admission.message,
    )
    return reply(admission.message, 200 if admission.ack.disposition == "cached" else 201)
