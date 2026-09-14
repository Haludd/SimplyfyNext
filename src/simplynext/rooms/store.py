"""Atomic room/auth/admission/replay state; no provider I/O in this module."""

from __future__ import annotations

import asyncio
import hashlib
import secrets
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from time import monotonic
from typing import Any, Literal
from uuid import UUID, uuid4

from simplynext.contracts.room_events import (
    AcceptedMessage,
    AcceptedOutcome,
    ActivityEvent,
    MessageUpsert,
    ParticipantView,
    PresenceEvent,
    ProcessingMessage,
    RepairMessage,
    RoomCredentials,
    RoomEnded,
    RoomError,
    RoomEvent,
    RoomMessage,
    RoomSnapshot,
    TerminalOutcome,
    UtteranceAck,
)
from simplynext.contracts.room_inputs import Activity, CreateRoom, JoinRoom, TextMessage
from simplynext.contracts.translated_sign_utterance import (
    MAX_SEQUENCE,
    TranslatedSignUtteranceV1,
    WordProducer,
    canonical_digest,
)
from simplynext.rooms.context import ConversationContext, ConversationTurn


class RoomFailure(Exception):
    def __init__(self, status: int, code: str) -> None:
        super().__init__(code)
        self.status = status
        self.code = code


@dataclass(frozen=True)
class RoomLimits:
    max_rooms: int = 100
    max_messages: int = 300
    invite_seconds: float = 600
    idle_seconds: float = 1800
    absolute_seconds: float = 7200
    invitations_per_minute: int = 20
    invitations_global_per_minute: int = 120
    messages_per_minute: int = 30
    subscribers_per_participant: int = 2
    subscriber_queue_size: int = 32

    def __post_init__(self) -> None:
        if any(value <= 0 for value in vars(self).values()) or self.max_messages > 300:
            raise ValueError("room limits must be positive, messages capped at 300")


@dataclass(eq=False)
class Participant:
    id: UUID
    alias: str
    role: Literal["signer", "hearing"]
    token_digest: str
    next_sequence: int = 0
    producer: WordProducer | None = None
    pending_repair: UUID | None = None
    request_times: deque[float] = field(default_factory=deque)
    control_times: deque[float] = field(default_factory=deque)
    subscribers: set[asyncio.Queue[RoomEvent]] = field(default_factory=set)

    def view(self) -> ParticipantView:
        return ParticipantView(
            participant_id=self.id,
            alias=self.alias,
            role=self.role,
            online=bool(self.subscribers),
        )


@dataclass(frozen=True)
class Reservation:
    digest: str
    sequence: int
    server_sequence: int


@dataclass(eq=False)
class Room:
    id: UUID
    code: str
    created: float
    last_activity: float
    state: Literal["waiting", "active", "ending", "ended"] = "waiting"
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    participants: dict[UUID, Participant] = field(default_factory=dict)
    messages: dict[int, RoomMessage] = field(default_factory=dict)
    requests: dict[tuple[UUID, UUID], Reservation] = field(default_factory=dict)
    sequences: dict[tuple[UUID, int], UUID] = field(default_factory=dict)
    pending: tuple[UUID, UUID] | None = None
    tasks: set[asyncio.Task[None]] = field(default_factory=set)
    version: int = 0
    context_version: int = 0
    next_server_sequence: int = 1
    summary: str = ""


@dataclass(frozen=True)
class Admission:
    ack: UtteranceAck
    message: RoomMessage
    context: ConversationContext | None


class RoomStore:
    def __init__(
        self,
        limits: RoomLimits | None = None,
        *,
        clock: Callable[[], float] = monotonic,
    ) -> None:
        self.limits = limits or RoomLimits()
        self.clock = clock
        self.rooms: dict[str, Room] = {}
        self._invitations: dict[str, deque[float]] = {}
        self._global_invitations: deque[float] = deque()

    def _rate(self, bucket: deque[float], maximum: int) -> None:
        now = self.clock()
        while bucket and bucket[0] <= now - 60:
            bucket.popleft()
        if len(bucket) >= maximum:
            raise RoomFailure(429, "rate_limited")
        bucket.append(now)

    def invitation_rate(self, address: str) -> None:
        self._rate(self._global_invitations, self.limits.invitations_global_per_minute)
        self._invitations = {
            key: times
            for key, times in self._invitations.items()
            if times and times[-1] > self.clock() - 60
        }
        key = hashlib.sha256(address.encode()).hexdigest()
        self._rate(self._invitations.setdefault(key, deque()), self.limits.invitations_per_minute)

    async def create(self, request: CreateRoom, *, address: str) -> RoomCredentials:
        self.invitation_rate(address)
        await self.purge_expired()
        if len(self.rooms) >= self.limits.max_rooms:
            raise RoomFailure(429, "rate_limited")
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        code = "".join(secrets.choice(alphabet) for _ in range(8))
        while code in self.rooms:
            code = "".join(secrets.choice(alphabet) for _ in range(8))
        room = Room(uuid4(), code, self.clock(), self.clock())
        self.rooms[code] = room
        return self._add_participant(room, request.alias, "signer")

    async def join(self, request: JoinRoom, *, address: str) -> RoomCredentials:
        self.invitation_rate(address)
        room = self.get(request.code)
        async with room.lock:
            self.require_live(room)
            if self.clock() - room.created >= self.limits.invite_seconds:
                raise RoomFailure(410, "room_unavailable")
            if len(room.participants) == 2:
                raise RoomFailure(409, "room_full")
            result = self._add_participant(room, request.alias, "hearing")
            room.state = "active"
            room.last_activity = self.clock()
            participant = room.participants[result.participant_id]
            self.publish(
                room,
                PresenceEvent(
                    room_version=self.bump(room),
                    participant=participant.view(),
                ),
            )
            return result

    @staticmethod
    def _add_participant(
        room: Room,
        alias: str,
        role: Literal["signer", "hearing"],
    ) -> RoomCredentials:
        token = secrets.token_urlsafe(32)
        participant = Participant(uuid4(), alias, role, hashlib.sha256(token.encode()).hexdigest())
        room.participants[participant.id] = participant
        return RoomCredentials(
            code=room.code,
            participant_id=participant.id,
            role=role,
            token=token,
            join_path=f"/join/{room.code}",
        )

    def get(self, code: str) -> Room:
        room = self.rooms.get(code)
        if room is None:
            raise RoomFailure(410, "room_unavailable")
        return room

    def expired(self, room: Room) -> bool:
        now = self.clock()
        return (
            now - room.created >= self.limits.absolute_seconds
            or now - room.last_activity >= self.limits.idle_seconds
            or (room.state == "waiting" and now - room.created >= self.limits.invite_seconds)
        )

    def require_live(self, room: Room) -> None:
        """Caller owns the room lock. Expiry uses the same full erasure path as end."""
        if room.state in {"ending", "ended"} or self.rooms.get(room.code) is not room:
            raise RoomFailure(410, "room_unavailable")
        if self.expired(room):
            self.erase(room)
            raise RoomFailure(410, "room_unavailable")

    def authenticate(self, room: Room, token: str) -> Participant:
        self.require_live(room)
        if not 32 <= len(token) <= 128:
            raise RoomFailure(401, "unauthorized")
        digest = hashlib.sha256(token.encode()).hexdigest()
        found: Participant | None = None
        for participant in room.participants.values():
            if secrets.compare_digest(digest, participant.token_digest):
                found = participant
        if found is None:
            raise RoomFailure(401, "unauthorized")
        return found

    def require_participant(self, room: Room, participant: Participant) -> None:
        self.require_live(room)
        if room.participants.get(participant.id) is not participant:
            raise RoomFailure(401, "unauthorized")

    @staticmethod
    def bump(room: Room) -> int:
        room.version += 1
        return room.version

    def publish(self, room: Room, event: RoomEvent) -> None:
        for participant in room.participants.values():
            for queue in tuple(participant.subscribers):
                if queue.full():
                    while not queue.empty():
                        queue.get_nowait()
                    queue.put_nowait(
                        RoomError(
                            room_version=room.version,
                            code="resync_required",
                        )
                    )
                    participant.subscribers.discard(queue)
                else:
                    queue.put_nowait(event)

    def snapshot(self, room: Room, *, after_sequence: int = 0) -> RoomSnapshot:
        self.require_live(room)
        # room version (not message sequence) is the delta cursor: a processing
        # message keeps its server_sequence when it becomes terminal.
        return RoomSnapshot(
            code=room.code,
            room_version=room.version,
            state="active" if room.state == "active" else "waiting",
            context_version=room.context_version,
            participants=tuple(p.view() for p in room.participants.values()),
            messages=tuple(m for s, m in room.messages.items() if s >= after_sequence),
        )

    def context(self, room: Room) -> ConversationContext:
        turns = tuple(
            ConversationTurn(
                server_sequence=message.server_sequence,
                speaker=room.participants[message.sender_id].role,
                source=message.source,
                text=message.text,
            )
            for message in room.messages.values()
            if isinstance(message, AcceptedMessage)
        )[-10:]
        return ConversationContext(
            room_id=room.id,
            context_version=room.context_version,
            summary=room.summary,
            recent_turns=turns,
            participant_aliases=tuple(p.alias for p in room.participants.values()),
        )

    def admit(
        self,
        room: Room,
        participant: Participant,
        request: TranslatedSignUtteranceV1 | TextMessage,
    ) -> Admission:
        """Caller holds lock; replay precedes rate, pending and capacity gates."""
        self.require_participant(room, participant)
        if room.state != "active":
            raise RoomFailure(409, "room_not_active")
        is_sign = isinstance(request, TranslatedSignUtteranceV1)
        if is_sign and participant.role != "signer":
            raise RoomFailure(401, "unauthorized")
        key = (participant.id, request.message_id)
        digest = canonical_digest(request)
        previous = room.requests.get(key)
        if previous is not None:
            if previous.digest != digest or previous.sequence != request.client_sequence:
                raise RoomFailure(409, "sequence_conflict")
            return Admission(
                ack=UtteranceAck(
                    message_id=request.message_id,
                    client_sequence=request.client_sequence,
                    server_sequence=previous.server_sequence,
                    disposition="cached",
                ),
                message=room.messages[previous.server_sequence],
                context=None,
            )
        if (
            request.client_sequence != participant.next_sequence
            or (participant.id, request.client_sequence) in room.sequences
        ):
            raise RoomFailure(409, "sequence_conflict")
        if is_sign and room.pending is not None:
            raise RoomFailure(429, "rate_limited")
        if (
            len(room.messages) >= self.limits.max_messages
            or participant.next_sequence > MAX_SEQUENCE
        ):
            raise RoomFailure(429, "rate_limited")
        if (
            isinstance(request, TranslatedSignUtteranceV1)
            and participant.producer is not None
            and participant.producer != request.producer
        ):
            raise RoomFailure(409, "sequence_conflict")
        # Capture before reservation: snapshot failure cannot leave a stranded pending slot.
        context = self.context(room) if is_sign else None
        self._rate(participant.request_times, self.limits.messages_per_minute)
        server_sequence = room.next_server_sequence
        message: RoomMessage
        common: dict[str, Any] = dict(
            message_id=request.message_id,
            sender_id=participant.id,
            client_sequence=request.client_sequence,
            server_sequence=server_sequence,
            context_version=room.context_version,
        )
        if isinstance(request, TranslatedSignUtteranceV1):
            message = ProcessingMessage(**common)
            participant.producer = request.producer
            room.pending = key
        else:
            message = AcceptedMessage(**common, source=request.source, text=request.text)
            room.context_version += 1
        participant.next_sequence += 1
        participant.pending_repair = None
        room.next_server_sequence += 1
        room.last_activity = self.clock()
        room.messages[server_sequence] = message
        room.requests[key] = Reservation(digest, request.client_sequence, server_sequence)
        room.sequences[(participant.id, request.client_sequence)] = request.message_id
        self.publish(room, MessageUpsert(room_version=self.bump(room), message=message))
        return Admission(
            ack=UtteranceAck(
                message_id=request.message_id,
                client_sequence=request.client_sequence,
                server_sequence=server_sequence,
                disposition="accepted",
            ),
            message=message,
            context=context,
        )

    def commit(
        self,
        room: Room,
        participant: Participant,
        message_id: UUID,
        outcome: TerminalOutcome,
    ) -> bool:
        """Exactly one terminal commit; stale or ended work cannot recreate state."""
        if room.state != "active" or self.rooms.get(room.code) is not room:
            return False
        if self.expired(room):
            self.erase(room)
            return False
        key = (participant.id, message_id)
        if room.pending != key:
            return False
        previous = room.requests[key]
        message = room.messages[previous.server_sequence]
        if not isinstance(message, ProcessingMessage):
            return False
        common = message.model_dump(exclude={"status", "source"})
        terminal: RoomMessage
        if isinstance(outcome, AcceptedOutcome):
            terminal = AcceptedMessage(
                **common, source="sign", text=outcome.text, translation=outcome
            )
            room.context_version += 1
        else:
            terminal = RepairMessage(**common, repair=outcome)
            participant.pending_repair = message_id
        room.messages[previous.server_sequence] = terminal
        room.pending = None
        self.publish(room, MessageUpsert(room_version=self.bump(room), message=terminal))
        return True

    def subscribe(self, room: Room, participant: Participant) -> asyncio.Queue[RoomEvent]:
        self.require_participant(room, participant)
        if len(participant.subscribers) >= self.limits.subscribers_per_participant:
            raise RoomFailure(429, "rate_limited")
        queue: asyncio.Queue[RoomEvent] = asyncio.Queue(self.limits.subscriber_queue_size)
        participant.subscribers.add(queue)
        self.publish(
            room,
            PresenceEvent(
                room_version=self.bump(room),
                participant=participant.view(),
            ),
        )
        # The connecting subscriber receives one atomic snapshot, then deltas.
        while not queue.empty():
            queue.get_nowait()
        queue.put_nowait(self.snapshot(room))
        return queue

    def unsubscribe(
        self,
        room: Room,
        participant: Participant,
        queue: asyncio.Queue[RoomEvent],
    ) -> None:
        participant.subscribers.discard(queue)
        if room.state in {"waiting", "active"}:
            self.publish(
                room,
                PresenceEvent(
                    room_version=self.bump(room),
                    participant=participant.view(),
                ),
            )

    def activity(self, room: Room, participant: Participant, control: Activity) -> None:
        self.require_participant(room, participant)
        room.last_activity = self.clock()
        self.publish(
            room,
            ActivityEvent(
                room_version=self.bump(room),
                participant_id=participant.id,
                state=control.state,
            ),
        )

    def erase(self, room: Room) -> None:
        """Single idempotent deletion path, called while holding room.lock."""
        if room.state == "ended":
            return
        room.state = "ending"
        ended = RoomEnded(room_version=self.bump(room))
        for task in tuple(room.tasks):
            if task is not asyncio.current_task():
                task.cancel()
        room.tasks.clear()
        for participant in room.participants.values():
            for queue in participant.subscribers:
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(ended)
            participant.subscribers.clear()
            participant.token_digest = ""
            participant.alias = ""
            participant.producer = None
            participant.pending_repair = None
            participant.request_times.clear()
            participant.control_times.clear()
            participant.next_sequence = 0
        room.participants.clear()
        room.messages.clear()
        room.requests.clear()
        room.sequences.clear()
        room.summary = ""
        room.pending = None
        room.context_version = 0
        room.state = "ended"
        if self.rooms.get(room.code) is room:
            del self.rooms[room.code]

    async def purge_expired(self) -> None:
        for room in tuple(self.rooms.values()):
            async with room.lock:
                if self.expired(room):
                    self.erase(room)

    async def close(self) -> None:
        tasks = [task for room in self.rooms.values() for task in room.tasks]
        for room in tuple(self.rooms.values()):
            async with room.lock:
                self.erase(room)
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._invitations.clear()
        self._global_invitations.clear()
