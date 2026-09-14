"""Lock-safe admission and cancellable terminal dispatch."""

import asyncio
from typing import Protocol

from simplynext.agent.words.repair import repair
from simplynext.contracts.room_events import AcceptedOutcome, RepairOutcome, TerminalOutcome
from simplynext.contracts.room_inputs import TextMessage
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1
from simplynext.observability.metrics import MetricsRegistry
from simplynext.rooms.context import ConversationContext
from simplynext.rooms.store import Admission, Participant, Room, RoomStore


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
    ) -> None:
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
        try:
            try:
                await asyncio.wait_for(self.slots.acquire(), timeout=self.queue_timeout_seconds)
                acquired = True
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
            if acquired:
                self.slots.release()
        async with room.lock:
            if self.store.commit(room, participant, request.message_id, outcome):
                self.metrics.increment(f"room_terminal_{outcome.status}")

    async def expire_periodically(self, interval_seconds: float = 5) -> None:
        while True:
            await asyncio.sleep(interval_seconds)
            await self.store.purge_expired()
