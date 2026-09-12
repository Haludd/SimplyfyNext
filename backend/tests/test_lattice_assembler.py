from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any, cast

import pytest
from pydantic import ValidationError

from simplynext.agent import (
    DEFAULT_ASSEMBLER_PROMPT_PATH,
    AssemblerDraft,
    AssemblerGroundingError,
    AssemblerOutputError,
    BedrockLatticeAssemblerNode,
    DraftEvidence,
    LatticeAssemblerConfig,
)
from simplynext.agent.graph import AgentGraphState, AllowedToolExecutor
from simplynext.agent.state import create_agent_state
from simplynext.contracts import GlossLattice
from simplynext.observability import MetricsRegistry

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"


def _lattice() -> GlossLattice:
    return GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))


def _valid_draft() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "utterance_id": "utterance-42",
        "language": "sgsl",
        "candidate_text": "Water, thank you John [GAP:slot-3]",
        "parts": [
            {
                "kind": "supported_text",
                "text": "Water, thank you",
                "evidence": [
                    {"slot_id": "slot-0", "gloss_id": "WATER"},
                    {"slot_id": "slot-1", "gloss_id": "THANK_YOU"},
                ],
            },
            {
                "kind": "supported_text",
                "text": "John",
                "evidence": [{"slot_id": "slot-2", "gloss_id": "J-O-H-N"}],
            },
            {
                "kind": "gap",
                "slot_id": "slot-3",
                "reason": "unresolved_input",
            },
        ],
    }


def _response(payload: object) -> dict[str, object]:
    text = payload if isinstance(payload, str) else json.dumps(payload)
    return {
        "output": {"message": {"content": [{"text": text}]}},
        "usage": {"inputTokens": 90, "outputTokens": 42, "totalTokens": 132},
    }


class FakeConverseClient:
    def __init__(self, *responses: dict[str, object]) -> None:
        self.responses = list(responses)
        self.calls: list[dict[str, Any]] = []

    def converse(self, **kwargs: Any) -> dict[str, object]:
        self.calls.append(kwargs)
        return self.responses.pop(0)


def _assembler(
    client: FakeConverseClient,
    *,
    metrics: MetricsRegistry | None = None,
) -> BedrockLatticeAssemblerNode:
    return BedrockLatticeAssemblerNode(
        client=client,
        config=LatticeAssemblerConfig(model_id="configured-model-id"),
        metrics=metrics,
    )


def test_versioned_prompt_contains_every_non_invention_rule() -> None:
    prompt = DEFAULT_ASSEMBLER_PROMPT_PATH.read_text(encoding="utf-8")

    assert "A gloss is not a word." in prompt
    assert "Never complete an unfinished utterance." in prompt
    assert "Never fill a missing slot" in prompt
    assert "Return exactly one JSON object and no prose" in prompt


def test_draft_gloss_id_uses_the_wire_contract_length_limit() -> None:
    accepted = DraftEvidence(slot_id="slot-0", gloss_id="G" * 128)
    assert len(accepted.gloss_id) == 128

    with pytest.raises(ValidationError):
        DraftEvidence(slot_id="slot-0", gloss_id="G" * 129)


def test_configured_prompt_cannot_drop_a_required_safety_rule(tmp_path: Path) -> None:
    unsafe_prompt = tmp_path / "assembler_v2.txt"
    unsafe_prompt.write_text("A gloss is not a word.\n", encoding="utf-8")

    with pytest.raises(ValueError, match="safety instruction"):
        BedrockLatticeAssemblerNode(
            client=FakeConverseClient(_response(_valid_draft())),
            config=LatticeAssemblerConfig(
                model_id="configured-model-id",
                prompt_path=unsafe_prompt,
            ),
        )


def test_assembler_marks_an_unresolved_slot_instead_of_bridging_it(caplog) -> None:
    metrics = MetricsRegistry()
    client = FakeConverseClient(_response(_valid_draft()))
    assembler = _assembler(client, metrics=metrics)

    with caplog.at_level(logging.INFO, logger="simplynext.agent.assembler"):
        draft = assembler.assemble(lattice=_lattice())

    assert draft.candidate_text == "Water, thank you John [GAP:slot-3]"
    assert draft.gap_slot_ids == ("slot-3",)
    assert draft.has_gaps is True
    assert len(client.calls) == 1
    assert "assembler_model_call" in caplog.text
    assert metrics.snapshot()["counters"] == {
        "assembler_output_validation_attempts": 1,
        "assembler_output_validation_successes": 1,
    }


def test_assembler_sends_only_compact_lattice_evidence() -> None:
    client = FakeConverseClient(_response(_valid_draft()))

    _assembler(client).assemble(lattice=_lattice())

    call = client.calls[0]
    request = json.loads(call["messages"][0]["content"][0]["text"])
    assert request["slots"][0]["candidates"][0] == {
        "confidence": 0.96,
        "gloss_id": "WATER",
        "rank": 1,
    }
    assert request["slots"][1]["provenance"] == "top_k_signer_confirmed"
    serialized = json.dumps(call).lower()
    assert "landmark" not in serialized
    assert "coordinate" not in serialized
    assert "frame" not in serialized
    assert "signer_id" not in serialized


def test_assembler_implements_the_graph_node_callback() -> None:
    lattice = _lattice()
    state = cast(
        AgentGraphState,
        {
            **create_agent_state(lattice, signer_id="signer-7", loop_cap=1),
            "draft": None,
            "critique": None,
            "result": None,
            "outcome": None,
            "node_path": (),
            "run_record": None,
        },
    )

    payload = _assembler(FakeConverseClient(_response(_valid_draft())))(
        state,
        AllowedToolExecutor(),
    )

    assert payload == _valid_draft()


@pytest.mark.parametrize(
    "response_payload",
    [
        "Water, thank you John tomorrow.",
        {
            **_valid_draft(),
            "candidate_text": "Water, thank you John",
            "parts": _valid_draft()["parts"][:-1],
        },
        {
            **_valid_draft(),
            "candidate_text": "Water, thank you John tomorrow",
            "parts": [
                *_valid_draft()["parts"][:-1],
                {
                    "kind": "supported_text",
                    "text": "tomorrow",
                    "evidence": [{"slot_id": "slot-3", "gloss_id": "TOMORROW"}],
                },
            ],
        },
        {
            **_valid_draft(),
            "candidate_text": "Could I have water tomorrow?",
        },
    ],
)
def test_assembler_rejects_free_text_omission_and_gap_bridging(response_payload: object) -> None:
    metrics = MetricsRegistry()
    assembler = _assembler(FakeConverseClient(_response(response_payload)), metrics=metrics)

    with pytest.raises(AssemblerOutputError):
        assembler.assemble(lattice=_lattice())

    assert metrics.snapshot()["counters"] == {
        "assembler_output_validation_attempts": 1,
        "assembler_output_validation_failures": 1,
    }


def test_assembler_rejects_evidence_that_disagrees_with_resolution() -> None:
    payload = _valid_draft()
    parts = payload["parts"]
    assert isinstance(parts, list)
    first_part = parts[0]
    assert isinstance(first_part, dict)
    evidence = first_part["evidence"]
    assert isinstance(evidence, list)
    evidence[0] = {"slot_id": "slot-0", "gloss_id": "WHAT"}

    with pytest.raises(AssemblerGroundingError, match="contradicts"):
        _assembler(FakeConverseClient(_response(payload))).assemble(lattice=_lattice())


def test_revision_payload_carries_only_prior_structured_draft_and_critic_reason() -> None:
    payload = _valid_draft()
    previous = AssemblerDraft.model_validate_json(json.dumps(payload))
    client = FakeConverseClient(_response(payload))

    _assembler(client).assemble(
        lattice=_lattice(),
        previous_draft=previous,
        critique_reason="unsupported tense",
        revision_number=1,
    )

    request = json.loads(client.calls[0]["messages"][0]["content"][0]["text"])
    assert request["revision"]["number"] == 1
    assert request["revision"]["critic_reason"] == "unsupported tense"
    assert request["revision"]["previous_draft"] == payload
