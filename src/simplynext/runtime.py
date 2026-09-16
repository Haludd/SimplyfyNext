"""Process-local service container for the modular backend."""

from __future__ import annotations

from asyncio import Semaphore
from dataclasses import dataclass

from simplynext.config import Settings
from simplynext.observability import MetricsRegistry
from simplynext.rooms.service import RoomService


@dataclass(frozen=True, slots=True)
class RuntimeServices:
    settings: Settings
    metrics: MetricsRegistry
    agent_slots: Semaphore
    rooms: RoomService
