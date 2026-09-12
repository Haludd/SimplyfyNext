"""Authenticated, bounded, idempotent GlossLattice WebSocket transport."""

from __future__ import annotations

import asyncio
import hashlib
import logging
from collections.abc import Mapping
from contextlib import suppress
from time import perf_counter, time
from typing import Any
from uuid import UUID, uuid4

from fastapi import WebSocket, WebSocketDisconnect
from pydantic import TypeAdapter, ValidationError

from simplynext.contracts import (
    ActivityState,
    ContractModel,
    ControlAction,
    ErrorCode,
    GlossLattice,
    InboundLatticeStreamMessage,
    LatticeAckDisposition,
    LatticeAckEvent,
    LatticeActivityEvent,
    LatticeErrorEvent,
    LatticeEvidenceTrace,
    LatticePongEvent,
    LatticeRepairAction,
    LatticeRepairRequiredEvent,
    LatticeTerminalEvent,
    StreamControlMessage,
)
from simplynext.runtime import RuntimeServices
from simplynext.sessions import (
    InvalidSessionToken,
    LatticeConflict,
    LatticeInProgress,
    LatticeQuotaExceeded,
    LatticeRateLimited,
    LatticeReservationDisposition,
    NonMonotonicSequence,
    SessionExpired,
    SessionNotFound,
    SessionStoreError,
)

logger = logging.getLogger(__name__)
_MESSAGE_ADAPTER: TypeAdapter[InboundLatticeStreamMessage] = TypeAdapter(
    InboundLatticeStreamMessage
)
_ALLOWED_CONTROLS = {ControlAction.PING, ControlAction.END}


async def lattice_socket(websocket: WebSocket, session_id: UUID) -> None:
    """Receive committed lattices and return cached or newly computed terminal events."""

    services: RuntimeServices = websocket.app.state.services
    token = _authorization_token(websocket.headers.get("authorization"))
    if token is None:
        await websocket.close(code=4401, reason="Bearer token required")
        return
    if not _origin_allowed(websocket.headers.get("origin"), services.settings.allowed_origins):
        await websocket.close(code=4403, reason="WebSocket origin is not allowed")
        return

    stream_id = uuid4()
    try:
        session = await services.sessions.claim_stream(
        session_id,
        token,
        stream_id,
    )
    except SessionStoreError as exc:
        await websocket.close(code=_close_code(exc), reason=exc.message)
        return

    try:
        await websocket.accept()
        services.metrics.increment("lattice_websocket_connections")
        await _send(
            websocket,
            LatticeActivityEvent(
                session_id=session_id,
                state=ActivityState.IDLE,
                server_ms=_server_ms(),
            ),
        )
        invalid_messages = 0

        while True:
            try:
                packet = await asyncio.wait_for(
                    websocket.receive(),
                    timeout=services.settings.lattice_websocket_idle_timeout_seconds,
                )
            except TimeoutError:
                services.metrics.increment("lattice_websocket_idle_timeouts")
                await websocket.close(code=1001, reason="Lattice stream idle timeout")
                return
            if packet["type"] == "websocket.disconnect":
                services.metrics.increment("lattice_websocket_disconnects")
                return

            raw, byte_count = _text_payload(packet)
            if byte_count > services.settings.gloss_lattice_max_message_bytes:
                services.metrics.increment("oversized_lattice_messages")
                await _send_error(
                    websocket,
                    session_id,
                    ErrorCode.INVALID_MESSAGE,
                    "Message exceeds the negotiated GlossLattice size limit.",
                    retryable=False,
                )
                await websocket.close(code=1009, reason="GlossLattice message too large")
                return
            if raw is None:
                invalid_messages += 1
                if await _reject_invalid_message(
                    websocket,
                    services,
                    session_id,
                    invalid_messages,
                    "Binary WebSocket messages are not supported.",
                ):
                    return
                continue

            validation_started = perf_counter()
            try:
                message = _MESSAGE_ADAPTER.validate_json(raw)
            except ValidationError:
                invalid_messages += 1
                if await _reject_invalid_message(
                    websocket,
                    services,
                    session_id,
                    invalid_messages,
                    "Message does not match the negotiated GlossLattice schema.",
                ):
                    return
                continue
            services.metrics.observe_ms("lattice_validation", _elapsed_ms(validation_started))

            if message.session_id != session_id:
                await _send_error(
                    websocket,
                    session_id,
                    ErrorCode.UNAUTHORIZED,
                    "Message session_id does not match this connection.",
                    retryable=False,
                )
                await websocket.close(code=4401, reason="Session mismatch")
                return

            if isinstance(message, StreamControlMessage):
                if message.action not in _ALLOWED_CONTROLS:
                    invalid_messages += 1
                    if await _reject_invalid_message(
                        websocket,
                        services,
                        session_id,
                        invalid_messages,
                        "The lattice socket supports only ping and end controls.",
                    ):
                        return
                    continue
                try:
                    await services.sessions.apply_control(message, token)
                except SessionStoreError as exc:
                    if await _send_store_error(websocket, session_id, exc):
                        return
                    continue
                invalid_messages = 0
                if message.action is ControlAction.PING:
                    await _send(
                        websocket,
                        LatticePongEvent(
                            session_id=session_id,
                            control_seq=message.control_seq,
                            server_ms=_server_ms(),
                        ),
                    )
                    continue
                await services.sessions.delete(
                    session_id,
                    token,
                    owner_stream_id=stream_id,
                )
                await websocket.close(code=1000, reason="Session ended")
                services.metrics.increment("sessions_ended")
                return

            if session.producer != message.producer:
                invalid_messages += 1
                await _send_error(
                    websocket,
                    session_id,
                    ErrorCode.INVALID_SESSION_STATE,
                    "Lattice producer profile does not match session negotiation.",
                    retryable=False,
                    lattice=message,
                )
                if invalid_messages >= 3:
                    await websocket.close(code=1008, reason="Too many invalid messages")
                    return
                continue

            invalid_messages = 0
            payload_digest = hashlib.sha256(message.model_dump_json().encode("utf-8")).digest()
            keep_open = await _handle_lattice(
                websocket=websocket,
                services=services,
                lattice=message,
                token=token,
                payload_digest=payload_digest,
                byte_count=byte_count,
                validation_started=validation_started,
                signer_id=session.signer_id,
            )
            if not keep_open:
                return
    except WebSocketDisconnect:
        services.metrics.increment("lattice_websocket_disconnects")
    except Exception as exc:
        services.metrics.increment("lattice_websocket_internal_errors")
        logger.error(
            "lattice_socket_failed",
            extra={"session_id": str(session_id), "reason": type(exc).__name__},
        )
        with suppress(RuntimeError, WebSocketDisconnect):
            await _send_error(
                websocket,
                session_id,
                ErrorCode.INTERNAL_ERROR,
                "The lattice stream failed safely. No uncached caption was emitted.",
                retryable=True,
            )
        with suppress(RuntimeError, WebSocketDisconnect):
            await websocket.close(code=1011, reason="Lattice stream internal error")
    finally:
        with suppress(SessionStoreError):
            await services.sessions.release_stream(session_id, token, stream_id)


async def _handle_lattice(
    *,
    websocket: WebSocket,
    services: RuntimeServices,
    lattice: GlossLattice,
    token: str,
    payload_digest: bytes,
    byte_count: int,
    validation_started: float,
    signer_id: str,
) -> bool:
    try:
        replay = await services.sessions.find_lattice_replay(lattice, token, payload_digest)
    except SessionStoreError as exc:
        return not await _send_store_error(websocket, lattice.session_id, exc, lattice=lattice)
    if replay is not None:
        await _send_lattice_replay(
            websocket,
            services,
            lattice,
            replay.cached_event,
            validation_started,
        )
        return True

    queue_started = perf_counter()
    acquired = False
    new_reservation = False
    completed = False
    try:
        try:
            await asyncio.wait_for(
                services.agent_slots.acquire(),
                timeout=services.settings.agent_queue_timeout_seconds,
            )
        except TimeoutError:
            services.metrics.increment("lattice_agent_queue_rejections")
            await _send_error(
                websocket,
                lattice.session_id,
                ErrorCode.RATE_LIMITED,
                "Agent capacity is busy; retry this lattice shortly.",
                retryable=True,
                lattice=lattice,
            )
            return True
        acquired = True
        services.metrics.observe_ms("lattice_agent_queue", _elapsed_ms(queue_started))

        try:
            reservation = await services.sessions.reserve_lattice(
                lattice,
                token,
                payload_digest,
            )
        except SessionStoreError as exc:
            return not await _send_store_error(websocket, lattice.session_id, exc, lattice=lattice)

        new_reservation = reservation.disposition is LatticeReservationDisposition.ACCEPTED
        try:
            await _send(
                websocket,
                LatticeAckEvent(
                    session_id=lattice.session_id,
                    lattice_seq=lattice.lattice_seq,
                    utterance_id=lattice.utterance_id,
                    disposition=LatticeAckDisposition(reservation.disposition.value),
                    server_ms=_server_ms(),
                ),
            )
            services.metrics.observe_ms("lattice_time_to_ack", _elapsed_ms(validation_started))

            if not new_reservation:
                await _send_lattice_replay(
                    websocket,
                    services,
                    lattice,
                    reservation.cached_event,
                    validation_started,
                    acknowledgement_sent=True,
                )
                return True

            services.metrics.increment("gloss_lattices_accepted")
            services.metrics.increment("gloss_lattice_bytes", byte_count)
            services.metrics.increment("gloss_lattice_slots", len(lattice.slots))
            await _send(
                websocket,
                LatticeActivityEvent(
                    session_id=lattice.session_id,
                    state=ActivityState.PROCESSING,
                    lattice_seq=lattice.lattice_seq,
                    utterance_id=lattice.utterance_id,
                    server_ms=_server_ms(),
                ),
            )

            agent_task = asyncio.create_task(
                services.lattice_translation.process_lattice(
                    lattice,
                    signer_id=signer_id,
                )
            )
            cancellation_requested = False
            terminal_event: LatticeTerminalEvent
            while True:
                try:
                    terminal_event = await asyncio.shield(agent_task)
                    break
                except asyncio.CancelledError:
                    if agent_task.done():
                        try:
                            terminal_event = agent_task.result()
                        except (Exception, asyncio.CancelledError):
                            terminal_event = _safe_failure_event(
                                lattice,
                                "agent_execution_cancelled",
                            )
                        break
                    cancellation_requested = True
                except Exception as exc:
                    logger.error(
                        "lattice_agent_execution_failed",
                        extra={
                            "session_id": str(lattice.session_id),
                            "lattice_seq": lattice.lattice_seq,
                            "reason": type(exc).__name__,
                        },
                    )
                    services.metrics.increment("lattice_agent_failures")
                    terminal_event = _safe_failure_event(lattice, "agent_execution_failed")
                    break

            await services.sessions.complete_lattice(
                lattice,
                token,
                payload_digest,
                terminal_event,
            )
            completed = True
            if cancellation_requested:
                raise asyncio.CancelledError
            await _send(websocket, terminal_event)
            await _send(
                websocket,
                LatticeActivityEvent(
                    session_id=lattice.session_id,
                    state=ActivityState.IDLE,
                    server_ms=_server_ms(),
                ),
            )
            return True
        finally:
            if new_reservation and not completed:
                failure = _safe_failure_event(lattice, "agent_delivery_interrupted")
                with suppress(SessionStoreError):
                    await asyncio.shield(
                        services.sessions.complete_lattice(
                            lattice,
                            token,
                            payload_digest,
                            failure,
                        )
                    )
    finally:
        if acquired:
            services.agent_slots.release()


async def _send_lattice_replay(
    websocket: WebSocket,
    services: RuntimeServices,
    lattice: GlossLattice,
    cached_event: LatticeTerminalEvent | None,
    validation_started: float,
    *,
    acknowledgement_sent: bool = False,
) -> None:
    if cached_event is None:
        raise RuntimeError("a completed lattice replay must have a terminal event")
    if not acknowledgement_sent:
        await _send(
            websocket,
            LatticeAckEvent(
                session_id=lattice.session_id,
                lattice_seq=lattice.lattice_seq,
                utterance_id=lattice.utterance_id,
                disposition=LatticeAckDisposition.CACHED,
                server_ms=_server_ms(),
            ),
        )
        services.metrics.observe_ms("lattice_time_to_ack", _elapsed_ms(validation_started))
    services.metrics.increment("lattice_cached_replays")
    await _send(websocket, cached_event)
    await _send(
        websocket,
        LatticeActivityEvent(
            session_id=lattice.session_id,
            state=ActivityState.IDLE,
            server_ms=_server_ms(),
        ),
    )


def _text_payload(packet: Mapping[str, Any]) -> tuple[str | None, int]:
    text = packet.get("text")
    if isinstance(text, str):
        return text, len(text.encode("utf-8"))
    binary = packet.get("bytes")
    return None, len(binary) if isinstance(binary, bytes) else 0


async def _reject_invalid_message(
    websocket: WebSocket,
    services: RuntimeServices,
    session_id: UUID,
    count: int,
    message: str,
) -> bool:
    services.metrics.increment("invalid_lattice_messages")
    await _send_error(
        websocket,
        session_id,
        ErrorCode.INVALID_MESSAGE,
        message,
        retryable=count < 3,
    )
    if count >= 3:
        await websocket.close(code=1008, reason="Too many invalid messages")
        return True
    return False


async def _send_store_error(
    websocket: WebSocket,
    session_id: UUID,
    exc: SessionStoreError,
    *,
    lattice: GlossLattice | None = None,
) -> bool:
    try:
        code = ErrorCode(exc.code)
    except ValueError:
        code = ErrorCode.INVALID_SESSION_STATE
    terminal = isinstance(exc, (InvalidSessionToken, SessionNotFound, SessionExpired))
    retryable = isinstance(exc, (LatticeInProgress, LatticeRateLimited))
    if isinstance(exc, (LatticeConflict, LatticeQuotaExceeded, NonMonotonicSequence)):
        retryable = False
    await _send_error(
        websocket,
        session_id,
        code,
        exc.message,
        retryable=retryable,
        lattice=lattice,
    )
    if terminal:
        await websocket.close(code=_close_code(exc), reason=exc.message)
    return terminal


def _safe_failure_event(lattice: GlossLattice, reason_code: str) -> LatticeRepairRequiredEvent:
    return LatticeRepairRequiredEvent(
        session_id=lattice.session_id,
        lattice_seq=lattice.lattice_seq,
        utterance_id=lattice.utterance_id,
        evidence_trace=_evidence_trace(lattice),
        classifier_version=lattice.producer.classifier_version,
        agent_source="transport_fail_closed",
        latency_ms={"total": 0},
        repair_id=f"repair:{lattice.lattice_seq}",
        action=LatticeRepairAction.ESCALATE_HUMAN_INTERPRETER,
        message=(
            "The language service could not safely process this utterance. "
            "Please use another communication method."
        ),
        confidence=0.0,
        target_slot_ids=tuple(slot.slot_id for slot in lattice.slots),
        reason_codes=(reason_code,),
    )


def _evidence_trace(lattice: GlossLattice) -> tuple[LatticeEvidenceTrace, ...]:
    return tuple(
        LatticeEvidenceTrace(
            slot_index=slot.slot_index,
            slot_id=slot.slot_id,
            start_ms=slot.start_ms,
            end_ms=slot.end_ms,
            resolved_gloss_id=slot.resolved_gloss_id,
            confidence=next(
                (
                    candidate.confidence
                    for candidate in slot.candidates
                    if candidate.gloss_id == slot.resolved_gloss_id
                ),
                None,
            ),
            provenance=slot.provenance,
            candidates=slot.candidates,
        )
        for slot in lattice.slots
    )


async def _send(websocket: WebSocket, event: ContractModel) -> None:
    await websocket.send_json(event.model_dump(mode="json"))


async def _send_error(
    websocket: WebSocket,
    session_id: UUID,
    code: ErrorCode,
    message: str,
    *,
    retryable: bool,
    lattice: GlossLattice | None = None,
) -> None:
    await _send(
        websocket,
        LatticeErrorEvent(
            session_id=session_id,
            code=code,
            message=message,
            retryable=retryable,
            lattice_seq=None if lattice is None else lattice.lattice_seq,
            utterance_id=None if lattice is None else lattice.utterance_id,
        ),
    )


def _authorization_token(value: str | None) -> str | None:
    if value is None:
        return None
    scheme, separator, token = value.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


def _origin_allowed(origin: str | None, allowed_origins: tuple[str, ...]) -> bool:
    """Allow native clients without Origin; require allow-list matches for browsers."""

    return origin is None or not allowed_origins or origin in allowed_origins


def _close_code(exc: SessionStoreError) -> int:
    if isinstance(exc, InvalidSessionToken):
        return 4401
    if isinstance(exc, SessionNotFound):
        return 4404
    if isinstance(exc, SessionExpired):
        return 4408
    return 4409


def _server_ms() -> int:
    return round(time() * 1000)


def _elapsed_ms(started: float) -> int:
    return max(0, round((perf_counter() - started) * 1000))


__all__ = ["lattice_socket"]
