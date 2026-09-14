"""Bounded assemble/critic/revise state machine without persistent checkpoints."""

import asyncio
from collections.abc import Callable
from functools import partial
from time import perf_counter
from typing import TypeVar

from simplynext.agent.words.assembler import WordAssembler, WordOutputFailure, validate_grounding
from simplynext.agent.bedrock_access import BedrockBudgetExceeded
from simplynext.agent.words.critic import WordCritic
from simplynext.agent.words.repair import repair
from simplynext.agent.words.state import WordDraft, WordVerdict
from simplynext.contracts.room_events import AcceptedOutcome, TerminalOutcome
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1
from simplynext.rooms.context import ConversationContext
from simplynext.observability.metrics import MetricsRegistry

T = TypeVar("T")


class WordGraph:
    def __init__(
        self,
        assembler: WordAssembler,
        critic: WordCritic,
        *,
        model_version: str,
        max_revisions: int = 1,
        max_concurrent_calls: int = 4,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        if max_revisions not in (0, 1) or max_concurrent_calls < 1:
            raise ValueError("invalid graph limits")
        self.assembler = assembler
        self.critic = critic
        self.model_version = model_version
        self.max_revisions = max_revisions
        self._slots = asyncio.Semaphore(max_concurrent_calls)
        self._calls: set[asyncio.Task[object]] = set()
        self.metrics = metrics or MetricsRegistry()

    async def _call(self, callback: Callable[[], T], stage: str) -> T:
        queued = perf_counter()
        await self._slots.acquire()
        self.metrics.observe_ms("provider_queue", (perf_counter() - queued) * 1000)

        def measured() -> T:
            started = perf_counter()
            try:
                return callback()
            finally:
                self.metrics.observe_ms(stage, (perf_counter() - started) * 1000)

        task = asyncio.create_task(asyncio.to_thread(measured))
        self._calls.add(task)

        def finished(done: asyncio.Task[T]) -> None:
            self._slots.release()
            self._calls.discard(done)
            if not done.cancelled():
                done.exception()  # Consume a late provider failure after caller cancellation.

        task.add_done_callback(finished)
        # Cancellation discards the result, but a synchronous SDK call still owns
        # its concurrency permit until it returns under the configured SDK timeout.
        return await asyncio.shield(task)

    async def run(
        self,
        utterance: TranslatedSignUtteranceV1,
        context: ConversationContext,
        *,
        policy_version: str,
    ) -> TerminalOutcome:
        draft: WordDraft | None = None
        verdict: WordVerdict | None = None
        try:
            for revision in range(self.max_revisions + 1):
                if revision:
                    self.metrics.increment("word_revisions")
                draft = await self._call(
                    partial(
                        self.assembler.assemble,
                        utterance,
                        context,
                        draft,
                        verdict,
                    ),
                    "word_revision_assembler" if revision else "word_assembler",
                )
                validate_grounding(draft, utterance)
                current_draft = draft
                verdict = await self._call(
                    partial(
                        self.critic.assess,
                        utterance,
                        context,
                        current_draft,
                    ),
                    "word_revision_critic" if revision else "word_critic",
                )
                if any(index >= len(utterance.words) for index in verdict.target_indices):
                    return repair("invalid_output")
                reference_sequences = {
                    t.server_sequence
                    for t in (*context.recent_turns[-2:], *context.overflow_turns[-2:])
                }
                # Summary excerpts are attributed but too lossy to establish a contradiction.
                if not set(verdict.reference_sequences).issubset(reference_sequences):
                    return repair("invalid_output")
                if verdict.supported:
                    validate_grounding(draft, utterance)
                    return AcceptedOutcome(
                        text=draft.candidate_text,
                        tts_text=draft.tts_text,
                        confidence=min(word.confidence for word in utterance.words),
                        model_version=self.model_version,
                        policy_version=policy_version,
                    )
                if (
                    verdict.revision_instruction is None
                    or verdict.revision_instruction == "abstain"
                ):
                    return repair(
                        "context_conflict"
                        if verdict.history_relation in {"contradiction", "uncertain"}
                        else "unnatural_sentence"
                        if not verdict.standalone_coherent
                        else "unsupported_detail",
                        verdict.target_indices,
                    )
            return repair("revision_exhausted", () if verdict is None else verdict.target_indices)
        except BedrockBudgetExceeded:
            # Use an existing v1 reason; do not expand the frozen event union.
            return repair("capacity").model_copy(update={
                "prompt": "Signing translation budget reached. Please type to continue this chat."
            })
        except WordOutputFailure as exc:
            return repair(exc.reason)
        except ValueError:
            return repair("invalid_output")
        except asyncio.CancelledError:
            raise
        except Exception:
            # Never put provider errors, drafts or prompts into room events/logs.
            return repair("provider_failure")
