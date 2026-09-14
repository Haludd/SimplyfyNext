import asyncio
from uuid import uuid4

import pytest
from test_room_core import DeferredTranslator, pair, service, text_message, utterance

from simplynext.rooms.context import (
    ConversationContext,
    ConversationHistory,
    ConversationTurn,
    extractive_digest,
    token_bound,
)
from simplynext.rooms.store import RoomLimits, RoomStore


def turn(i, text=None):
    return ConversationTurn(
        server_sequence=i, speaker="hearing", source="text", text=text or f"Topic fact number {i}."
    )


@pytest.mark.parametrize("count", [60, 120, 240])
async def test_hour_long_context_is_bounded_and_transcript_complete(count):
    store = RoomStore(RoomLimits(messages_per_minute=300))
    room, _, hearing = await pair(store)
    translator = DeferredTranslator()
    runtime = service(store, translator)
    bounds = []
    for i in range(count):
        await runtime.submit(room.code, hearing.token, text_message(i, f"Topic fact number {i}."))
        await asyncio.sleep(0)
        ctx = store.context(room)
        assert [t.server_sequence for t in ctx.recent_turns] == list(range(max(1, i - 8), i + 2))
        assert len(ctx.overflow_turns) <= 20
        assert token_bound(ctx.assembler_view()) <= 8000
        assert token_bound(ctx.critic_view()) <= 3000
        bounds.append(token_bound(ctx.assembler_view()))
    while room.tasks:
        await asyncio.gather(*tuple(room.tasks))
    assert len(room.history.turns) == len(room.messages) == count
    assert room.history.through == count - 10
    assert not room.history.overflow
    assert translator.calls == 0
    assert max(bounds[30:]) < 8000
    assert room.context_version > count
    frozen = store.context(room)
    store.erase(room)
    assert not room.history.turns and not room.history.summary and not room.history.overflow
    assert room.history.through == 0 and room.compaction_task is None
    assert frozen.recent_turns[-1].server_sequence == count


@pytest.mark.parametrize("failure", ["exception", "oversized"])
async def test_failed_summary_uses_bounded_fallback_after_terminal_delivery(failure):
    store = RoomStore(RoomLimits(messages_per_minute=300))
    room, _, hearing = await pair(store)
    entered, release = asyncio.Event(), asyncio.Event()

    async def broken(batch):
        entered.set()
        await release.wait()
        if failure == "exception":
            raise RuntimeError("PRIVATE provider data")
        return "x" * 3201

    runtime = service(store, DeferredTranslator(), compactor=broken)
    for i in range(20):
        admission = await runtime.submit(room.code, hearing.token, text_message(i))
        assert admission.message.status == "accepted"
    await entered.wait()
    assert len(room.messages) == 20 and room.history.through == 0
    assert len(store.context(room).overflow_turns) == 10
    release.set()
    await asyncio.gather(*tuple(room.tasks))
    assert room.history.through == 10 and room.summary
    assert runtime.metrics.snapshot()["counters"]["context_compaction_fallback"] == 1
    await store.close()


async def test_stalled_summary_overflow_fallback_rejects_stale_commit():
    store = RoomStore(RoomLimits(messages_per_minute=300))
    room, _, hearing = await pair(store)
    entered, release = asyncio.Event(), asyncio.Event()

    async def slow(batch):
        entered.set()
        await release.wait()
        return extractive_digest(batch.summary, batch.turns)

    runtime = service(store, DeferredTranslator(), compactor=slow)
    for i in range(20):
        await runtime.submit(room.code, hearing.token, text_message(i, f"Turn {i}"))
    await entered.wait()
    for i in range(20, 80):
        await runtime.submit(room.code, hearing.token, text_message(i, f"Turn {i}"))
        assert len(room.history.overflow) <= 20
    assert room.history.through >= 50
    release.set()
    await asyncio.gather(*tuple(room.tasks))
    assert room.history.through == 70
    assert runtime.metrics.snapshot()["counters"]["context_compaction_stale"] == 1
    await store.close()


async def test_end_during_summary_discards_even_cancellation_ignoring_completion():
    store = RoomStore(RoomLimits(messages_per_minute=300))
    room, _, hearing = await pair(store)
    entered = asyncio.Event()

    async def ignores_cancel(batch):
        entered.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            return "PRIVATE late summary"

    runtime = service(store, DeferredTranslator(), compactor=ignores_cancel)
    for i in range(20):
        await runtime.submit(room.code, hearing.token, text_message(i))
    await entered.wait()
    tasks = tuple(room.tasks)
    async with room.lock:
        store.erase(room)
    await asyncio.gather(*tasks, return_exceptions=True)
    assert not store.rooms and not room.history.turns and not room.summary
    assert room.compaction_task is None and not room.tasks


@pytest.mark.parametrize("already_compacted", [False, True])
def test_late_signed_turn_invalidates_summary_batch_without_losing_evidence(already_compacted):
    history = ConversationHistory()
    for i in range(1, 26):
        if i != 3:
            history.append(turn(i))
    old = history.batch()
    assert old
    if already_compacted:
        assert history.commit(old, extractive_digest(old.summary, old.turns))
    history.append(
        ConversationTurn(
            server_sequence=3, speaker="signer", source="sign", text="Actually I want water."
        )
    )
    assert not history.commit(old, "STALE")
    while batch := history.batch():
        assert history.commit(batch, extractive_digest(batch.summary, batch.turns))
    assert "Actually I want water." in history.summary
    assert [t.server_sequence for t in history.turns] == list(range(1, 26))
    assert len(history.recent) == 10


async def test_late_model_result_before_compacted_watermark_keeps_canonical_order():
    store = RoomStore(RoomLimits(messages_per_minute=300))
    room, signer, hearing = await pair(store)
    translator = DeferredTranslator()
    runtime = service(store, translator)
    request = utterance()
    await runtime.submit(room.code, signer.token, request)
    await translator.started.wait()
    for i in range(40):
        await runtime.submit(room.code, hearing.token, text_message(i))
        await asyncio.sleep(0)
    assert room.history.through > 1
    translator.release.set()
    while room.tasks:
        await asyncio.gather(*tuple(room.tasks))
    assert room.history.turns[0].source == "sign"
    assert len(room.history.turns) == 41
    assert room.history.turns[0].server_sequence == 1
    assert room.history.through == 31
    await store.close()


def test_extreme_unicode_context_is_excerpted_only_in_prompt_projection():
    ctx = ConversationContext(
        room_id=uuid4(),
        context_version=240,
        summary="🙂" * 3000,
        recent_turns=tuple(turn(i, "🙂" * 2000) for i in range(230, 240)),
        overflow_turns=tuple(turn(i, "🙂" * 2000) for i in range(210, 230)),
    )
    assert all(len(t.text) == 2000 for t in ctx.recent_turns)
    for view, budget in ((ctx.assembler_view(), 8000), (ctx.critic_view(), 3000)):
        assert token_bound(view) <= budget
        assert view["summary_excerpted"]
        assert all(t["excerpted"] for t in view["recent_turns"])


def test_compaction_preserves_attribution_questions_corrections_and_recent_topic():
    turns = tuple(turn(i, "Repetitive filler." * 20) for i in range(1, 15)) + (
        turn(15, "Where is the appointment?"),
        turn(16, "Actually the appointment changed to Friday."),
        turn(17, "Let us discuss dinner."),
    )
    digest = extractive_digest("", turns)
    assert len(digest) <= 3200
    assert "Where is the appointment?" in digest and "changed to Friday" in digest
    assert "[17 hearing/text] Let us discuss dinner." in digest
