"""Room-owned accepted history, batched extractive compaction and bounded projections."""

import json
import re
from dataclasses import dataclass, field
from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field

from simplynext.contracts.translated_sign_utterance import Sequence, StrictValue


class ConversationTurn(StrictValue):
    server_sequence: Sequence
    speaker: Literal["signer", "hearing"]
    source: Literal["sign", "text", "speech"]
    text: str = Field(min_length=1, max_length=2000)


def token_bound(value: object) -> int:
    """Conservative serialized-byte bound, NOT a provider tokenizer/usage count."""
    return len(json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode())


def extractive_digest(summary: str, turns: tuple[ConversationTurn, ...]) -> str:
    """Keep attributed excerpts; never synthesize facts or execute transcript instructions.

    Prioritize questions/corrections and recent substance. Excerpts carry sequence and role;
    later corrections remain alongside older claims rather than silently rewriting them.
    """
    lines = summary.splitlines() + [
        f"[{t.server_sequence} {t.speaker}/{t.source}] {t.text[:240].replace(chr(10), ' ')}"
        + (" [excerpt]" if len(t.text) > 240 else "")
        for t in turns
        if t.text.strip().lower().rstrip(".!") not in {"hi", "hello", "thanks", "thank you", "ok"}
    ]
    unique = list(dict.fromkeys(lines))
    priority = [
        i
        for i, line in enumerate(unique)
        if re.search(r"\?|\b(actually|correction|instead|changed|mean|rather)\b", line, re.I)
    ]
    # Reserve half for questions/corrections and half for recent topic/reference facts.
    chosen: set[int] = set()
    used = 0
    for i in reversed(priority):
        if used + len(unique[i]) + 1 <= 1400:
            chosen.add(i)
            used += len(unique[i]) + 1
    for i in reversed(range(len(unique))):
        if i not in chosen and used + len(unique[i]) + 1 <= 3000:
            chosen.add(i)
            used += len(unique[i]) + 1
    return "\n".join(unique[i] for i in sorted(chosen))


class ConversationContext(StrictValue):
    room_id: UUID
    context_version: Sequence
    summary: str = Field(default="", max_length=3200)
    summary_through_server_sequence: Sequence = 0
    recent_turns: Annotated[tuple[ConversationTurn, ...], Field(max_length=10)] = ()
    overflow_turns: Annotated[tuple[ConversationTurn, ...], Field(max_length=20)] = ()
    participant_aliases: Annotated[
        tuple[Annotated[str, Field(min_length=1, max_length=40)], ...], Field(max_length=2)
    ] = ()
    assembler_token_budget: int = Field(default=8000, ge=4000, le=32000)
    critic_token_budget: int = Field(default=3000, ge=2000, le=8000)

    def _project(self, *, critic: bool) -> dict[str, object]:
        # The immutable snapshot retains verbatim recent turns. If extreme-length or
        # Unicode input exceeds the prompt budget, use explicitly marked excerpts.
        # The canonical transcript is never truncated.
        budget = self.critic_token_budget if critic else self.assembler_token_budget
        recent = self.recent_turns[-2:] if critic else self.recent_turns
        overflow = self.overflow_turns[-2:] if critic else self.overflow_turns
        limit = 2000
        while True:

            def project(turn: ConversationTurn, limit: int = limit) -> dict[str, object]:
                data = turn.model_dump(mode="json")
                data["text"] = turn.text[:limit]
                data["excerpted"] = len(turn.text) > limit
                return data

            summary = self.summary[: min(limit * 2, 1000 if critic else 3200)]
            result: dict[str, object] = {
                "context_version": self.context_version,
                "summary_through_server_sequence": self.summary_through_server_sequence,
                "summary": summary,
                "summary_excerpted": summary != self.summary,
                "recent_turns": [project(t) for t in recent],
                "overflow_turns": [project(t) for t in overflow],
            }
            if not critic:
                result["participant_aliases"] = self.participant_aliases
            if token_bound(result) <= budget:
                return result
            if limit == 0:
                raise ValueError("context metadata exceeds budget")
            limit //= 2

    def assembler_view(self) -> dict[str, object]:
        return self._project(critic=False)

    def critic_view(self) -> dict[str, object]:
        return self._project(critic=True)


@dataclass(frozen=True)
class CompactionBatch:
    generation: int
    through: int
    summary: str
    turns: tuple[ConversationTurn, ...]


@dataclass
class ConversationHistory:
    # Canonical accepted transcript, bounded by the store's 300-message cap.
    turns: list[ConversationTurn] = field(default_factory=list)
    summary: str = ""
    through: int = 0
    generation: int = 0

    @property
    def recent(self) -> tuple[ConversationTurn, ...]:
        return tuple(self.turns[-10:])

    @property
    def overflow(self) -> tuple[ConversationTurn, ...]:
        return tuple(t for t in self.turns[:-10] if t.server_sequence > self.through)

    def append(self, turn: ConversationTurn) -> None:
        if self.turns and turn.server_sequence < self.turns[-1].server_sequence:
            self.generation += 1
        self.turns.append(turn)
        self.turns.sort(key=lambda t: t.server_sequence)
        if turn.server_sequence <= self.through:
            # A signed turn admitted earlier can finish after newer text has compacted.
            # Rebuild from canonical data and invalidate any captured summary task.
            self.summary = extractive_digest("", tuple(self.turns[:-10]))
            self.through = self.turns[-11].server_sequence if len(self.turns) > 10 else 0
            self.generation += 1
        # Backpressure fallback bounds overflow even if the async task stalls/fails.
        while len(self.overflow) > 20:
            batch = self.batch()
            assert batch is not None
            self.commit(batch, extractive_digest(batch.summary, batch.turns))

    def batch(self) -> CompactionBatch | None:
        overflow = self.overflow
        if len(overflow) < 10:
            return None
        return CompactionBatch(self.generation, self.through, self.summary, overflow[:10])

    def commit(self, batch: CompactionBatch, summary: str) -> bool:
        if batch.generation != self.generation or batch.through != self.through:
            return False
        if not isinstance(summary, str) or len(summary) > 3200:
            raise ValueError("invalid summary")
        self.summary = summary
        self.through = batch.turns[-1].server_sequence
        self.generation += 1
        return True

    def clear(self) -> None:
        self.turns.clear()
        self.summary = ""
        self.through = 0
        self.generation += 1
