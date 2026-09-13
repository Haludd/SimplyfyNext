"""Bounded, process-local rooms. Run one worker; restart intentionally clears rooms."""

import asyncio
import hashlib
import secrets
from dataclasses import dataclass, field
from time import time
from typing import Any
from uuid import uuid4

from fastapi import HTTPException


@dataclass
class Participant:
    id: str
    name: str
    mode: str
    token_digest: str
    activity: str = "idle"
    activity_at: float = 0
    subscribers: set[asyncio.Queue[dict[str, Any]]] = field(default_factory=set)


@dataclass
class Room:
    code: str
    expires_at: float
    join_until: float
    participants: list[Participant] = field(default_factory=list)
    messages: list[dict[str, Any]] = field(default_factory=list)
    requests: dict[tuple[str, str], tuple[str, dict[str, Any]]] = field(default_factory=dict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    version: int = 0
    closed: bool = False


class RoomStore:
    def __init__(self, *, ttl: int = 7200, max_rooms: int = 100) -> None:
        self.ttl = ttl
        self.max_rooms = max_rooms
        self.rooms: dict[str, Room] = {}

    def create(self, name: str, mode: str) -> dict[str, str]:
        self.expire()
        if len(self.rooms) >= self.max_rooms:
            raise HTTPException(429, "All rooms are busy. Try again later.")
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        code = "".join(secrets.choice(alphabet) for _ in range(6))
        while code in self.rooms:
            code = "".join(secrets.choice(alphabet) for _ in range(6))
        room = Room(code, time() + self.ttl, time() + 600)
        self.rooms[code] = room
        return self.add_participant(room, name, mode)

    def get(self, code: str) -> Room:
        self.expire()
        room = self.rooms.get(code)
        if room is None or room.closed:
            raise HTTPException(410, "This room has ended or expired. Start a new conversation.")
        return room

    def join(self, code: str, name: str, mode: str) -> dict[str, str]:
        room = self.get(code)
        if time() > room.join_until:
            raise HTTPException(410, "This invitation expired. Ask for a new conversation.")
        if len(room.participants) >= 2:
            raise HTTPException(409, "This conversation already has two people.")
        result = self.add_participant(room, name, mode)
        self.publish(room)
        return result

    @staticmethod
    def add_participant(room: Room, name: str, mode: str) -> dict[str, str]:
        token = secrets.token_urlsafe(32)
        participant = Participant(
            str(uuid4()), name, mode, hashlib.sha256(token.encode()).hexdigest()
        )
        room.participants.append(participant)
        return {"code": room.code, "participant_id": participant.id, "token": token}

    def authenticate(self, code: str, token: str) -> tuple[Room, Participant]:
        room = self.get(code)
        digest = hashlib.sha256(token.encode()).hexdigest()
        for participant in room.participants:
            if secrets.compare_digest(digest, participant.token_digest):
                return room, participant
        raise HTTPException(401, "Room credentials are invalid.")

    @staticmethod
    def snapshot(room: Room) -> dict[str, Any]:
        return {
            "type": "snapshot",
            "code": room.code,
            "version": room.version,
            "expires_at": room.expires_at,
            "join_until": room.join_until,
            "participants": [
                {
                    "id": p.id,
                    "name": p.name,
                    "mode": p.mode,
                    "online": bool(p.subscribers),
                    "activity": p.activity if time() - p.activity_at < 8 else "idle",
                }
                for p in room.participants
            ],
            "messages": [dict(message) for message in room.messages],
        }

    @staticmethod
    def enqueue(queue: asyncio.Queue[dict[str, Any]], packet: dict[str, Any]) -> None:
        if queue.full():
            queue.get_nowait()
        queue.put_nowait(packet)

    def publish(self, room: Room) -> None:
        if room.closed:
            return
        room.version += 1
        snapshot = self.snapshot(room)
        for participant in room.participants:
            for queue in participant.subscribers:
                self.enqueue(queue, snapshot)

    def end(self, room: Room) -> None:
        room.closed = True
        for participant in room.participants:
            for queue in participant.subscribers:
                self.enqueue(queue, {"type": "ended"})
        self.rooms.pop(room.code, None)

    def expire(self) -> None:
        for room in list(self.rooms.values()):
            if time() > room.expires_at:
                self.end(room)
