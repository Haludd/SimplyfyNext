"""Bounded assemble/critic/revise state machine without persistent checkpoints."""

import asyncio
from collections.abc import Callable
from functools import partial
from typing import TypeVar

from simplynext.agent.words.assembler import WordAssembler, WordOutputFailure, validate_grounding
from simplynext.agent.words.critic import WordCritic
from simplynext.agent.words.repair import repair
from simplynext.agent.words.state import WordDraft, WordVerdict
from simplynext.contracts.room_events import AcceptedOutcome, TerminalOutcome
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1
from simplynext.rooms.context import ConversationContext

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
    ) -> None:
        if max_revisions not in (0, 1) or max_concurrent_calls < 1:
            raise ValueError("invalid graph limits")
        self.assembler = assembler
        self.critic = critic
        self.model_version = model_version
        self.max_revisions = max_revisions
        self._slots = asyncio.Semaphore(max_concurrent_calls)
        self._calls: set[asyncio.Task[object]] = set()

    async def _call(self, callback: Callable[[], T]) -> T:
        await self._slots.acquire()
        task = asyncio.create_task(asyncio.to_thread(callback))
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
            for _ in range(self.max_revisions + 1):
                draft = await self._call(
                    partial(
                        self.assembler.assemble,
                        utterance,
                        context,
                        draft,
                        verdict,
                    )
                )
                validate_grounding(draft, utterance)
                current_draft = draft
                verdict = await self._call(
                    partial(
                        self.critic.assess,
                        utterance,
                        context,
                        current_draft,
                    )
                )
                if any(index >= len(utterance.words) for index in verdict.target_indices):
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
                    return repair("unsupported_detail", verdict.target_indices)
            return repair("revision_exhausted", () if verdict is None else verdict.target_indices)
        except WordOutputFailure as exc:
            return repair(exc.reason)
        except ValueError:
            return repair("invalid_output")
        except asyncio.CancelledError:
            raise
        except Exception:
            # Never put provider errors, drafts or prompts into room events/logs.
            return repair("provider_failure")
