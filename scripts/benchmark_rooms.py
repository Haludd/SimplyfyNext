"""Accelerated 60/120/240-turn mixed rooms; fake provider, real admission/graph/accounting."""

from __future__ import annotations

import argparse
import asyncio
import json
from decimal import Decimal
from pathlib import Path
from typing import Any
from uuid import uuid4

from simplynext.agent.bedrock_access import (
    BedrockCostGuard,
    BedrockPricing,
    CostGuardedConverseClient,
)
from simplynext.agent.words.assembler import ProviderWordAssembler, WordProvider
from simplynext.agent.words.critic import ProviderWordCritic
from simplynext.agent.words.graph import WordGraph
from simplynext.config import Settings
from simplynext.contracts.room_inputs import CreateRoom, JoinRoom, TextMessage
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1, parse_value
from simplynext.observability.metrics import MetricsRegistry
from simplynext.rooms.service import RoomService
from simplynext.rooms.store import RoomLimits, RoomStore
from simplynext.translation_runtime import WordTranslationEngine, load_word_policy

ROOT = Path(__file__).resolve().parents[1]


class SyntheticProvider:
    """Fixed approved outputs for synthetic evidence only. Never opens a network client."""

    def __init__(self) -> None:
        self.draft = json.loads((ROOT / "data/word_templates.example.json").read_text())[
            "templates"
        ][0]["draft"]
        self.calls = 0

    def converse(self, **request: Any) -> dict[str, Any]:
        self.calls += 1
        assembler = request["requestMetadata"]["simplynext_role"] == "word_assembler"
        output = (
            self.draft
            if assembler
            else {
                "schema_version": "1.0",
                "supported": True,
                "standalone_coherent": True,
                "history_relation": "continuation",
                "reference_sequences": [],
                "reason_code": "supported",
                "target_indices": [],
                "revision_instruction": None,
            }
        )
        return {
            "stopReason": "end_turn",
            "output": {"message": {"content": [{"text": json.dumps(output)}]}},
            # Simulated counts, deliberately fixed; NOT measured provider usage.
            "usage": {"inputTokens": 1750, "outputTokens": 125},
        }


async def benchmark(count: int) -> dict[str, Any]:
    now = [0.0]
    store = RoomStore(RoomLimits(), clock=lambda: now[0])
    metrics = MetricsRegistry()
    budget = BedrockCostGuard(
        pricing=BedrockPricing(
            model_id="synthetic",
            input_usd_per_million=Decimal(1),
            output_usd_per_million=Decimal(5),
            cache_write_usd_per_million=Decimal("1.25"),
            cache_read_usd_per_million=Decimal("0.1"),
        ),
        request_limit_usd=Decimal("0.50"),
        room_limit_usd=Decimal(2),
        hourly_limit_usd=Decimal(5),
        clock=lambda: now[0],
    )
    raw = SyntheticProvider()
    client = CostGuardedConverseClient(
        client=raw,
        guard=budget,
        metrics=metrics,
        prompt_cache_enabled=False,
    )
    provider = WordProvider(client, "synthetic")
    graph = WordGraph(
        ProviderWordAssembler(provider),
        ProviderWordCritic(provider),
        model_version="synthetic",
        metrics=metrics,
    )
    policy = load_word_policy(
        Settings(  # type: ignore[call-arg]
            _env_file=None,
            environment="test",
            bedrock_enabled=False,
            anthropic_enabled=False,
            word_policy_path=ROOT / "data/word_policy.synthetic.json",
        )
    )
    service = RoomService(
        store,
        WordTranslationEngine(graph, policy),
        slots=asyncio.Semaphore(4),
        metrics=metrics,
    )
    signer = await store.create(
        CreateRoom(
            schema_version="1.0",
            event_schema_version="1.0",
            alias="Synthetic signer",
        ),
        address="local",
    )
    hearing = await store.join(
        JoinRoom(
            schema_version="1.0",
            event_schema_version="1.0",
            alias="Synthetic hearing",
            code=signer.code,
        ),
        address="local",
    )
    room = store.get(signer.code)
    fixture = json.loads((ROOT / "tests/fixtures/translated_sign_utterance_v1.json").read_text())
    fixture["words"] = [
        dict(index=i, token_id=f"w{i}", word=word, confidence=0.9, alternatives=[])
        for i, word in enumerate(("WATER", "I", "WANT"))
    ]
    for i in range(count):
        now[0] = i * 3600 / count
        if i % 2:
            fixture.update(message_id=str(uuid4()), client_sequence=i // 2)
            request = parse_value(TranslatedSignUtteranceV1, json.dumps(fixture))
            await service.submit(room.code, signer.token, request)
            while room.tasks:
                await asyncio.gather(*tuple(room.tasks))
                await asyncio.sleep(0)  # allow completed-task cleanup callbacks to run
            # Reconnect snapshot and exact retries must not add calls/turns.
            assert (
                await service.submit(room.code, signer.token, request)
            ).ack.disposition == "cached"
            assert store.snapshot(room).messages[-1].status == "accepted"
        else:
            await service.submit(
                room.code,
                hearing.token,
                TextMessage(
                    schema_version="1.0",
                    message_id=uuid4(),
                    client_sequence=i // 2,
                    source="speech" if i % 4 else "text",
                    text="Would you like water?",
                ),
            )
        await asyncio.sleep(0)
    while room.tasks:
        await asyncio.gather(*tuple(room.tasks))
        await asyncio.sleep(0)
    assert len(room.messages) == len(room.history.turns) == count
    assert len(room.history.recent) == 10
    assert raw.calls == count  # two stages for each of count/2 signed turns
    result = {
        "turns": count,
        "signed_utterances": count // 2,
        "simulated_seconds": 3600,
        "model_calls": raw.calls,
        "simulated_cost_usd": str(room.spend.spent),
        "metrics": metrics.snapshot(),
    }
    await store.close()
    assert not store.rooms and not room.messages and room.spend.spent == 0
    return result


async def run() -> dict[str, Any]:
    return {
        "kind": "accelerated_synthetic_no_network",
        "provider_usage": "simulated",
        "latency_scope": "local execution only; excludes network and mobile delivery",
        "runs": [await benchmark(count) for count in (60, 120, 240)],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(asyncio.run(run()), indent=2) + "\n")
    print("Synthetic 60/120/240-turn benchmark passed; no provider credits used.")


if __name__ == "__main__":
    main()
