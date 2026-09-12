"""Process-local service container for the modular backend."""

from __future__ import annotations

from asyncio import Semaphore
from dataclasses import dataclass

from simplynext.agent import AgentGraph
from simplynext.config import Settings
from simplynext.lattice_runtime import LatticeTranslationEngine
from simplynext.observability import MetricsRegistry
from simplynext.sessions import EphemeralSessionStore


@dataclass(frozen=True, slots=True)
class RuntimeServices:
    settings: Settings
    sessions: EphemeralSessionStore
    lattice_translation: LatticeTranslationEngine
    agent_graph: AgentGraph
    metrics: MetricsRegistry
    agent_slots: Semaphore
