"""Lock-safe admission and cancellable terminal dispatch."""

import asyncio
from collections.abc import Awaitable, Callable
from time import perf_counter
from typing import Protocol

from simplynext.agent.words.repair import repair
from simplynext.contracts.room_events import AcceptedOutcome, RepairOutcome, TerminalOutcome
from simplynext.contracts.room_inputs import TextMessage
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1
from simplynext.observability.metrics import MetricsRegistry
from simplynext.rooms.context import (
    CompactionBatch,
    ConversationContext,
    extractive_digest,
    token_bound,
)
from simplynext.rooms.store import Admission, Participant, Room, RoomStore
from simplynext.spend import SpendScope, current_spend_scope


class Translator(Protocol):
    async def process(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
    ) -> TerminalOutcome: ...


class RoomService:
    def __init__(
        self,
        store: RoomStore,
        translator: Translator,
        *,
        slots: asyncio.Semaphore,
        metrics: MetricsRegistry,
        timeout_seconds: float = 90,
        queue_timeout_seconds: float = 2,
        compactor: Callable[[CompactionBatch], Awaitable[str]] | None = None,
    ) -> None:
        self.compactor = compactor or compact_extractive
        self.store = store
        self.translator = translator
        self.slots = slots
        self.metrics = metrics
        self.timeout_seconds = timeout_seconds
        self.queue_timeout_seconds = queue_timeout_seconds

    async def submit(
        self,
        code: str,
        token: str,
        request: TranslatedSignUtteranceV1 | TextMessage,
    ) -> Admission:
        started = perf_counter()
        room = self.store.get(code)
        async with room.lock:
            participant = self.store.authenticate(room, token)
            admission = self.store.admit(room, participant, request)
            if isinstance(request, TranslatedSignUtteranceV1) and admission.context is not None:
                task = asyncio.create_task(
                    self._process(room, participant, request, admission.context)
                )
                room.tasks.add(task)
                task.add_done_callback(room.tasks.discard)
            self._schedule_compaction(room)
            self.metrics.observe_ms("room_admission", (perf_counter() - started) * 1000)
            self.metrics.increment(f"room_admission_{admission.ack.disposition}")
            return admission

    async def _process(
        self,
        room: Room,
        participant: Participant,
        request: TranslatedSignUtteranceV1,
        context: ConversationContext,
    ) -> None:
        outcome: TerminalOutcome
        acquired = False
        started = perf_counter()
        scope = SpendScope(room.spend)
        scope_token = current_spend_scope.set(scope)
        try:
            self.metrics.observe_count(
                "context_assembler_token_bound", token_bound(context.assembler_view())
            )
            self.metrics.observe_count(
                "context_critic_token_bound", token_bound(context.critic_view())
            )
            try:
                await asyncio.wait_for(self.slots.acquire(), timeout=self.queue_timeout_seconds)
                acquired = True
                self.metrics.observe_ms("room_queue", (perf_counter() - started) * 1000)
            except TimeoutError:
                outcome = repair("capacity")
            else:
                async with asyncio.timeout(self.timeout_seconds):
                    outcome = await self.translator.process(request, context)
                if not isinstance(outcome, (AcceptedOutcome, RepairOutcome)):
                    outcome = repair("invalid_output")
        except TimeoutError:
            outcome = repair("timeout")
        except asyncio.CancelledError:
            outcome = repair("cancelled")
        except Exception:
            outcome = repair("provider_failure")
        finally:
            scope.request.erase()
            current_spend_scope.reset(scope_token)
            if acquired:
                self.slots.release()
        commit_started = perf_counter()
        async with room.lock:
            if self.store.commit(room, participant, request.message_id, outcome):
                self.metrics.increment(f"room_terminal_{outcome.status}")
                self.metrics.observe_ms("room_terminal", (perf_counter() - started) * 1000)
                self.metrics.observe_ms("room_commit", (perf_counter() - commit_started) * 1000)
                self._schedule_compaction(room)

    def _schedule_compaction(self, room: Room) -> None:
        # Called after publication. Scheduling does not await summary work on delivery.
        if room.compaction_task is not None or room.history.batch() is None:
            return
        task = asyncio.create_task(self._compact(room))
        room.compaction_task = task
        room.tasks.add(task)
        task.add_done_callback(room.tasks.discard)

    async def _compact(self, room: Room) -> None:
        try:
            while True:
                async with room.lock:
                    if room.state != "active" or self.store.rooms.get(room.code) is not room:
                        return
                    batch = room.history.batch()
                if batch is None:
                    return
                try:
                    async with asyncio.timeout(5):
                        summary = await self.compactor(batch)
                    if not isinstance(summary, str) or len(summary) > 3200:
                        raise ValueError("summary budget exceeded")
                except asyncio.CancelledError:
                    raise
                except Exception:
                    summary = extractive_digest(batch.summary, batch.turns)
                    self.metrics.increment("context_compaction_fallback")
                async with room.lock:
                    if room.state != "active" or self.store.rooms.get(room.code) is not room:
                        return
                    if self.store.expired(room):
                        self.store.erase(room)
                        return
                    if room.history.commit(batch, summary):
                        room.context_version += 1
                        self.metrics.increment("context_compactions")
                    else:
                        self.metrics.increment("context_compaction_stale")
        finally:
            if room.compaction_task is asyncio.current_task():
                room.compaction_task = None

    async def expire_periodically(self, interval_seconds: float = 5) -> None:
        while True:
            await asyncio.sleep(interval_seconds)
            await self.store.purge_expired()


async def compact_extractive(batch: CompactionBatch) -> str:
    # Yield past event delivery; bounded CPU work, no provider spend or thread buffers.
    await asyncio.sleep(0)
    return extractive_digest(batch.summary, batch.turns)
