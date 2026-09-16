import asyncio
import json
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from threading import Event

import pytest
from test_room_core import pair, service, text_message
from test_word_agents import ENTRIES, engine, response, utterance, verdict

from simplynext.agent.bedrock_access import (
    BedrockBudgetExceeded,
    BedrockCostGuard,
    BedrockPricing,
    BedrockTokenUsage,
    CostGuardedConverseClient,
)
from simplynext.rooms.store import RoomStore
from simplynext.spend import SpendAccount, SpendScope, current_spend_scope


def guard(**kwargs):
    return BedrockCostGuard(
        pricing=BedrockPricing(
            model_id="mock-word-model",
            input_usd_per_million=Decimal(1),
            output_usd_per_million=Decimal(5),
            cache_write_usd_per_million=Decimal(1),
            cache_read_usd_per_million=Decimal("0.1"),
        ),
        **kwargs,
    )


def reserve(budget):
    return budget.reserve(model_id="mock-word-model", input_tokens=100, max_output_tokens=0)


@pytest.mark.parametrize("kind", ["request", "room", "hourly", "process"])
def test_all_ceiling_scopes_reject_before_dispatch(kind):
    key = "spend_limit_usd" if kind == "process" else kind + "_limit_usd"
    budget = guard(**{key: Decimal("0.00015")})
    room = SpendAccount()
    scope = SpendScope(room)
    token = current_spend_scope.set(scope)
    try:
        first = reserve(budget)
        budget.settle(first, usage=BedrockTokenUsage(100, 0))
        if kind == "room":
            current_spend_scope.set(SpendScope(room))
        with pytest.raises(BedrockBudgetExceeded) as caught:
            reserve(budget)
        assert caught.value.scope == ("hour" if kind == "hourly" else kind)
        assert budget.snapshot().reserved_usd == 0
    finally:
        current_spend_scope.reset(token)


def test_concurrent_room_reservations_are_atomic_and_isolated():
    budget = guard(room_limit_usd=Decimal("0.0002"))
    room = SpendAccount()

    def attempt(_):
        token = current_spend_scope.set(SpendScope(room))
        try:
            return reserve(budget)
        except BedrockBudgetExceeded:
            return None
        finally:
            current_spend_scope.reset(token)

    with ThreadPoolExecutor(max_workers=8) as pool:
        reservations = [r for r in pool.map(attempt, range(8)) if r is not None]
    assert len(reservations) == 2
    token = current_spend_scope.set(SpendScope(SpendAccount()))
    try:
        another = reserve(budget)
        budget.settle(another, usage=BedrockTokenUsage(100, 0))
    finally:
        current_spend_scope.reset(token)
    for reservation in reservations:
        budget.settle(reservation, usage=None)
    assert room.spent == Decimal("0.0002") and room.reserved == 0


def test_hourly_rollover_cannot_release_outstanding_reservations():
    now = [0.0]
    budget = guard(hourly_limit_usd=Decimal("0.00015"), clock=lambda: now[0])
    pending = reserve(budget)
    now[0] = 7200
    with pytest.raises(BedrockBudgetExceeded):
        reserve(budget)
    budget.settle(pending, usage=None)
    now[0] += 3600
    with pytest.raises(BedrockBudgetExceeded):
        reserve(budget)  # conservative minute boundary
    now[0] += 60
    assert reserve(budget)
    assert len(budget._hourly) <= 61


def test_hidden_sdk_retries_and_unknown_usage_are_conservatively_charged():
    budget = guard(total_max_attempts=3)
    reservation = reserve(budget)
    assert reservation.maximum_cost_usd == Decimal("0.0003")
    cost, _ = budget.settle(reservation, usage=BedrockTokenUsage(10, 0))
    assert cost == Decimal("0.00021")  # final usage + two unknown attempts
    cost, _ = budget.settle(reserve(budget), usage=None)
    assert cost == Decimal("0.0003")


def test_erasure_blocks_dispatch_and_late_settlement_cannot_recreate_room_cost():
    budget = guard()
    scope = SpendScope(SpendAccount())
    token = current_spend_scope.set(scope)
    try:
        pending = reserve(budget)
        scope.room.erase()
        scope.request.erase()
        with pytest.raises(BedrockBudgetExceeded):
            reserve(budget)
        budget.settle(pending, usage=None)
        assert scope.room.spent == scope.room.reserved == 0
        assert scope.request.spent == scope.request.reserved == 0
        assert budget.snapshot().estimated_spend_usd == Decimal("0.0001")
    finally:
        current_spend_scope.reset(token)


async def test_budget_repair_preserves_typed_chat_and_exact_retries_make_no_calls():
    class NeverCall:
        def converse(self, **kwargs):
            pytest.fail("budget must reject before provider dispatch")

    budget = guard(request_limit_usd=Decimal("0.000001"))
    client = CostGuardedConverseClient(client=NeverCall(), guard=budget, prompt_cache_enabled=False)
    store = RoomStore()
    room, signer, hearing = await pair(store)
    runtime = service(store, engine(client))
    request = utterance()
    await runtime.submit(room.code, signer.token, request)
    await asyncio.gather(*tuple(room.tasks))
    terminal = room.messages[1]
    assert terminal.status == "repair" and terminal.repair.action == "ask_type"
    assert "budget" in terminal.repair.prompt
    assert "text" not in terminal.repair.model_dump()
    await runtime.submit(room.code, signer.token, request)
    assert budget.snapshot().rejected_calls == 1
    text = await runtime.submit(room.code, hearing.token, text_message())
    assert text.message.status == "accepted"
    await store.close()


@pytest.mark.parametrize("stage", [0, 1, 2, 3])
async def test_deletion_during_each_provider_stage_preserves_permit_and_erases_state(stage):
    started, release = Event(), Event()

    class BlockingProvider:
        calls = 0

        def converse(self, **kwargs):
            index = self.calls
            self.calls += 1
            if index == stage:
                started.set()
                assert release.wait(5)
            return response(ENTRIES[0]["draft"] if index % 2 == 0 else verdict(index == 3))

    raw = BlockingProvider()
    budget = guard()
    client = CostGuardedConverseClient(client=raw, guard=budget, prompt_cache_enabled=False)
    translator = engine(client)
    store = RoomStore()
    room, signer, _ = await pair(store)
    runtime = service(store, translator)
    try:
        await runtime.submit(room.code, signer.token, utterance())
        assert await asyncio.to_thread(started.wait, 3)
        tasks = tuple(room.tasks)
        async with room.lock:
            store.erase(room)
        await asyncio.gather(*tasks, return_exceptions=True)
        assert translator.graph._calls  # actual synchronous call still owns a slot
        release.set()
        await asyncio.gather(*tuple(translator.graph._calls))
        assert raw.calls == stage + 1
        assert not store.rooms and not room.messages and not room.history.turns
        assert not room.requests and not room.participants and room.pending is None
        assert room.spend.closed and room.spend.spent == room.spend.reserved == 0
        assert budget.snapshot().reserved_usd == 0
        assert budget.snapshot().completed_calls == stage + 1
        assert not client._utterance_costs
    finally:
        release.set()
        await store.close()


def test_restart_keeps_outstanding_charge_and_rejects_second_writer(tmp_path):
    path = tmp_path / "usage.json"
    budget = guard(journal_path=path, spend_limit_usd=Decimal("0.00015"))
    reserve(budget)
    with pytest.raises(ValueError, match="active writer"):
        guard(journal_path=path)
    budget._journal.close()  # simulate prior process exiting without a response
    restarted = guard(journal_path=path, spend_limit_usd=Decimal("0.00015"))
    assert restarted.snapshot().estimated_spend_usd == Decimal("0.0001")
    with pytest.raises(BedrockBudgetExceeded):
        reserve(restarted)
    content = path.read_text()
    assert set(__import__("json").loads(content)) == {"version", "charged_usd", "hourly"}
    assert path.stat().st_mode & 0o777 == 0o600
    restarted._journal.close()


def test_corrupt_or_unwritable_journal_fails_before_dispatch(tmp_path, monkeypatch):
    path = tmp_path / "usage.json"
    path.write_text('{"version":1,"charged_usd":"NaN","hourly":{}}')
    with pytest.raises(ValueError, match="journal is invalid"):
        guard(journal_path=path)
    path.write_text('{"version":1,"charged_usd":"0","hourly":{}}')
    budget = guard(journal_path=path)

    def fail(*args):
        raise OSError("disk unavailable")

    monkeypatch.setattr(budget._journal, "write", fail)
    with pytest.raises(OSError):
        reserve(budget)
    assert budget.snapshot().reserved_usd == Decimal("0.0001")
    budget._journal.close()


def test_init_spend_journal_provisions_safely_and_refuses_overwrite(tmp_path):
    from simplynext.spend_journal import init_spend_journal

    path = tmp_path / "usage.json"
    init_spend_journal(path, charged_usd=Decimal("1.25"))
    assert path.is_file()
    assert path.stat().st_mode & 0o777 == 0o600
    journal = json.loads(path.read_text())
    assert journal == {"version": 1, "charged_usd": "1.25", "hourly": {}}

    # Refuse to overwrite existing file
    with pytest.raises(FileExistsError):
        init_spend_journal(path)
