from __future__ import annotations

import asyncio
import logging
from decimal import Decimal
from pathlib import Path
from typing import cast

import pytest

import simplynext.lattice_runtime as lattice_runtime
from simplynext.agent import AgentGraph, CostGuardedConverseClient
from simplynext.config import Settings
from simplynext.contracts import GlossLattice, LatticeRepairRequiredEvent, LatticeResultEvent
from simplynext.lattice_runtime import build_lattice_translation_engine
from simplynext.observability import JsonFormatter, MetricsRegistry

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"
TEMPLATES_PATH = Path(__file__).parents[1] / "data" / "caption_templates.example.json"


def _settings(*, templates: Path | None = TEMPLATES_PATH) -> Settings:
    return Settings(
        environment="test",
        allowed_origins=(),
        bedrock_enabled=False,
        caption_templates_path=templates,
        recognition_language="sgsl",
    )


def _fixture() -> GlossLattice:
    return GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))


def _hello_lattice() -> GlossLattice:
    fixture = _fixture().model_dump(mode="json")
    slot = dict(fixture["slots"][0])
    slot["candidates"] = [{"gloss_id": "HELLO", "rank": 1, "confidence": 0.96}]
    slot["resolved_gloss_id"] = "HELLO"
    return GlossLattice.model_validate({**fixture, "slots": [slot]})


def test_no_spend_composition_returns_a_grounded_confident_event() -> None:
    metrics = MetricsRegistry()
    engine = build_lattice_translation_engine(_settings(), metrics)

    event = asyncio.run(engine.process_lattice(_hello_lattice(), signer_id="signer-7"))

    assert isinstance(event, LatticeResultEvent)
    assert event.caption == "Hello."
    assert event.tts_text == "Hello."
    assert event.gloss_id_trace == ("HELLO",)
    assert event.evidence_trace[0].resolved_gloss_id == "HELLO"
    assert event.agent_source == "deterministic_template"
    assert event.agent_model_version == "deterministic_template_v1"
    assert engine.agent_graph.allowed_tools == ()
    counters = metrics.snapshot()["counters"]
    assert counters["lattice_utterances_confident"] == 1
    assert counters["lattice_agent_invocations"] == 1


def test_unresolved_lattice_repairs_before_agent_assembly() -> None:
    metrics = MetricsRegistry()
    engine = build_lattice_translation_engine(_settings(), metrics)

    event = asyncio.run(engine.process_lattice(_fixture(), signer_id="signer-7"))

    assert isinstance(event, LatticeRepairRequiredEvent)
    assert event.action == "offer_top_k"
    assert event.target_slot_ids == ("slot-3",)
    assert len(event.choices) == 2
    assert "caption" not in event.model_dump()
    counters = metrics.snapshot()["counters"]
    assert counters["lattice_unresolved_before_agent"] == 1
    assert counters.get("lattice_agent_invocations", 0) == 0


def test_completion_log_has_correlation_and_latency_but_no_lattice_payload(
    caplog: pytest.LogCaptureFixture,
) -> None:
    engine = build_lattice_translation_engine(_settings(), MetricsRegistry())

    with caplog.at_level(logging.INFO, logger="simplynext.lattice_runtime"):
        event = asyncio.run(
            engine.process_lattice(_hello_lattice(), signer_id="sensitive-signer-context")
        )

    record = next(record for record in caplog.records if record.message == "lattice_processed")
    rendered = JsonFormatter().format(record)
    assert record.session_id == str(event.session_id)  # type: ignore[attr-defined]
    assert record.lattice_seq == event.lattice_seq  # type: ignore[attr-defined]
    assert record.utterance_id == event.utterance_id  # type: ignore[attr-defined]
    assert record.outcome == "confident"  # type: ignore[attr-defined]
    assert record.latency_total_ms >= 0  # type: ignore[attr-defined]
    assert "HELLO" not in rendered
    assert "Hello." not in rendered
    assert "sensitive-signer-context" not in rendered


def test_missing_template_uses_one_revision_then_repairs_fail_closed() -> None:
    engine = build_lattice_translation_engine(_settings(templates=None), MetricsRegistry())

    event = asyncio.run(engine.process_lattice(_hello_lattice(), signer_id="signer-7"))

    assert isinstance(event, LatticeRepairRequiredEvent)
    assert event.action == "escalate_human_interpreter"
    assert event.reason_codes == ("deterministic_template_missing",)
    assert event.agent_source == "deterministic_repair"


def test_unapproved_producer_is_rejected_before_agent() -> None:
    engine = build_lattice_translation_engine(_settings(), MetricsRegistry())
    payload = _hello_lattice().model_dump(mode="json")
    payload["producer"]["classifier_version"] = "unapproved-version"
    lattice = GlossLattice.model_validate(payload)

    event = asyncio.run(engine.process_lattice(lattice, signer_id="signer-7"))

    assert isinstance(event, LatticeRepairRequiredEvent)
    assert event.reason_codes == ("producer_profile_mismatch",)
    assert event.agent_source == "server_policy"


def test_agent_exception_is_converted_to_a_fail_closed_repair() -> None:
    class FailingGraph:
        async def ainvoke(self, *args: object, **kwargs: object) -> object:
            raise RuntimeError("test graph failure")

    engine = build_lattice_translation_engine(_settings(), MetricsRegistry())
    engine.agent_graph = cast(AgentGraph, FailingGraph())

    event = asyncio.run(engine.process_lattice(_hello_lattice(), signer_id="signer-7"))

    assert isinstance(event, LatticeRepairRequiredEvent)
    assert event.action == "escalate_human_interpreter"
    assert event.reason_codes == ("agent_execution_failed",)
    assert "caption" not in event.model_dump()


def test_bedrock_composition_runs_both_startup_preflights(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(
        _env_file=None,
        environment="test",
        allowed_origins=(),
        bedrock_enabled=True,
        bedrock_lease_owner="phase1-owner",
        recognition_language="sgsl",
    )
    control_client = object()
    runtime_client = object()
    calls: list[tuple[str, object]] = []
    monkeypatch.setattr(
        lattice_runtime,
        "create_bedrock_control_client",
        lambda **_kwargs: control_client,
    )
    monkeypatch.setattr(
        lattice_runtime,
        "create_bedrock_client",
        lambda **_kwargs: runtime_client,
    )
    monkeypatch.setattr(
        lattice_runtime,
        "preflight_bedrock_access",
        lambda client, **_kwargs: calls.append(("control", client)),
    )
    monkeypatch.setattr(
        lattice_runtime,
        "preflight_bedrock_runtime_access",
        lambda client, **_kwargs: calls.append(("runtime", client)),
    )

    engine = build_lattice_translation_engine(settings, MetricsRegistry())

    assert engine.ready is True
    assert engine.agent_source == "bedrock_graph"
    assert calls[0] == ("control", control_client)
    assert calls[1][0] == "runtime"
    assert isinstance(calls[1][1], CostGuardedConverseClient)


@pytest.mark.parametrize("failed_preflight", ["control", "runtime"])
def test_bedrock_composition_fails_instead_of_advertising_readiness(
    monkeypatch: pytest.MonkeyPatch,
    failed_preflight: str,
) -> None:
    settings = Settings(
        _env_file=None,
        environment="test",
        allowed_origins=(),
        bedrock_enabled=True,
        bedrock_lease_owner="phase1-owner",
        recognition_language="sgsl",
    )
    monkeypatch.setattr(
        lattice_runtime,
        "create_bedrock_control_client",
        lambda **_kwargs: object(),
    )
    monkeypatch.setattr(
        lattice_runtime,
        "create_bedrock_client",
        lambda **_kwargs: object(),
    )

    def preflight(name: str) -> None:
        if failed_preflight == name:
            raise RuntimeError(f"{name} preflight failed")

    monkeypatch.setattr(
        lattice_runtime,
        "preflight_bedrock_access",
        lambda _client, **_kwargs: preflight("control"),
    )
    monkeypatch.setattr(
        lattice_runtime,
        "preflight_bedrock_runtime_access",
        lambda _client, **_kwargs: preflight("runtime"),
    )

    with pytest.raises(RuntimeError, match=f"{failed_preflight} preflight failed"):
        build_lattice_translation_engine(settings, MetricsRegistry())


def test_anthropic_composition_uses_normalized_converse_adapter_without_contract_changes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(
        _env_file=None,
        environment="test",
        allowed_origins=(),
        anthropic_enabled=True,
        anthropic_lease_owner="phase1-owner",
        anthropic_input_usd_per_million_tokens=Decimal("1.00"),
        anthropic_output_usd_per_million_tokens=Decimal("5.00"),
        anthropic_cache_write_usd_per_million_tokens=Decimal("1.25"),
        anthropic_cache_read_usd_per_million_tokens=Decimal("0.10"),
        recognition_language="sgsl",
    )

    class FakeAnthropicRuntime:
        def converse(self, **_kwargs: object) -> dict[str, object]:
            return {
                "output": {
                    "message": {"content": [{"text": "OK"}]},
                },
                "usage": {
                    "inputTokens": 10,
                    "outputTokens": 1,
                    "cacheWriteInputTokens": 0,
                    "cacheReadInputTokens": 0,
                },
            }

    monkeypatch.setattr(
        lattice_runtime,
        "create_anthropic_client",
        lambda **_kwargs: FakeAnthropicRuntime(),
    )

    engine = build_lattice_translation_engine(settings, MetricsRegistry())

    assert engine.ready is True
    assert engine.agent_source == "anthropic_graph"
    assert engine.agent_model_version == "claude-haiku-4-5-20251001"
