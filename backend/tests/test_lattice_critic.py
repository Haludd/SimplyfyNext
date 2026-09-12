from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any, cast

import pytest

from simplynext.agent import (
    DEFAULT_ASSEMBLER_PROMPT_PATH,
    DEFAULT_CRITIC_PROMPT_PATH,
    AssemblerDraft,
    BedrockLatticeCriticNode,
    CriticVerdict,
    LatticeCriticConfig,
    create_agent_state,
)
from simplynext.agent.graph import AgentGraphState, AllowedToolExecutor
from simplynext.contracts import GlossLattice
from simplynext.observability import MetricsRegistry

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"


def _lattice() -> GlossLattice:
    return GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))


def _draft(*, invented_token: bool = False) -> AssemblerDraft:
    first_text = "Water, unicorn" if invented_token else "Water,"
    candidate_text = f"{first_text} thank you John [GAP:slot-3]"
    return AssemblerDraft.model_validate_json(
        json.dumps(
            {
                "schema_version": "1.0",
                "utterance_id": "utterance-42",
                "language": "sgsl",
                "candidate_text": candidate_text,
                "parts": [
                    {
                        "kind": "supported_text",
                        "text": first_text,
                        "evidence": [{"slot_id": "slot-0", "gloss_id": "WATER"}],
                    },
                    {
                        "kind": "supported_text",
                        "text": "thank you",
                        "evidence": [{"slot_id": "slot-1", "gloss_id": "THANK_YOU"}],
                    },
                    {
                        "kind": "supported_text",
                        "text": "John",
                        "evidence": [{"slot_id": "slot-2", "gloss_id": "J-O-H-N"}],
                    },
                    {"kind": "gap", "slot_id": "slot-3", "reason": "unresolved_input"},
                ],
            }
        )
    )


def _token_assessment(
    token_index: int,
    token: str,
    *,
    supported: bool = True,
    slot_id: str | None = None,
    gloss_id: str | None = None,
    reason: str = "licensed by the cited resolved gloss",
) -> dict[str, object]:
    evidence: list[dict[str, str]] = []
    if slot_id is not None and gloss_id is not None:
        evidence.append({"slot_id": slot_id, "gloss_id": gloss_id})
    return {
        "token_index": token_index,
        "token": token,
        "supported": supported,
        "evidence": evidence,
        "reason": reason,
    }


def _supported_assessment() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "utterance_id": "utterance-42",
        "supported": True,
        "token_assessments": [
            _token_assessment(0, "Water,", slot_id="slot-0", gloss_id="WATER"),
            _token_assessment(1, "thank", slot_id="slot-1", gloss_id="THANK_YOU"),
            _token_assessment(2, "you", slot_id="slot-1", gloss_id="THANK_YOU"),
            _token_assessment(3, "John", slot_id="slot-2", gloss_id="J-O-H-N"),
            _token_assessment(4, "[GAP:slot-3]", reason="exact supplied gap marker"),
        ],
    }


def _invented_token_assessment() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "utterance_id": "utterance-42",
        "supported": False,
        "token_assessments": [
            _token_assessment(0, "Water,", slot_id="slot-0", gloss_id="WATER"),
            _token_assessment(
                1,
                "unicorn",
                supported=False,
                slot_id="slot-0",
                gloss_id="WATER",
                reason="WATER does not license unicorn",
            ),
            _token_assessment(2, "thank", slot_id="slot-1", gloss_id="THANK_YOU"),
            _token_assessment(3, "you", slot_id="slot-1", gloss_id="THANK_YOU"),
            _token_assessment(4, "John", slot_id="slot-2", gloss_id="J-O-H-N"),
            _token_assessment(5, "[GAP:slot-3]", reason="exact supplied gap marker"),
        ],
    }


def _response(payload: object) -> dict[str, object]:
    return {
        "output": {"message": {"content": [{"text": json.dumps(payload)}]}},
        "usage": {"inputTokens": 80, "outputTokens": 40, "totalTokens": 120},
    }


class FakeConverseClient:
    def __init__(self, *responses: dict[str, object] | BaseException) -> None:
        self.responses = list(responses)
        self.calls: list[dict[str, Any]] = []

    def converse(self, **kwargs: Any) -> dict[str, object]:
        self.calls.append(kwargs)
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


def _critic(
    client: FakeConverseClient,
    *,
    metrics: MetricsRegistry | None = None,
) -> BedrockLatticeCriticNode:
    return BedrockLatticeCriticNode(
        client=client,
        config=LatticeCriticConfig(model_id="configured-critic-model-id"),
        metrics=metrics,
    )


def _state(draft: AssemblerDraft) -> AgentGraphState:
    return cast(
        AgentGraphState,
        {
            **create_agent_state(_lattice(), signer_id="signer-7", loop_cap=1),
            "draft": draft.model_dump(mode="json"),
            "critique": None,
            "result": None,
            "outcome": None,
            "node_path": (),
            "run_record": None,
        },
    )


def test_critic_has_an_independent_versioned_single_purpose_prompt() -> None:
    prompt = DEFAULT_CRITIC_PROMPT_PATH.read_text(encoding="utf-8")

    assert DEFAULT_CRITIC_PROMPT_PATH != DEFAULT_ASSEMBLER_PROMPT_PATH
    assert "One question: is every candidate token supported" in prompt
    assert "Do not revise, translate, improve, or complete" in prompt
    assert "Every whitespace-delimited candidate token" in prompt
    assert "Return exactly one JSON object and no prose" in prompt


def test_configured_prompt_cannot_drop_token_audit_rules(tmp_path: Path) -> None:
    unsafe_prompt = tmp_path / "critic_v2.txt"
    unsafe_prompt.write_text("Check the candidate.\n", encoding="utf-8")

    with pytest.raises(ValueError, match="safety instruction"):
        BedrockLatticeCriticNode(
            client=FakeConverseClient(_response(_supported_assessment())),
            config=LatticeCriticConfig(
                model_id="configured-critic-model-id",
                prompt_path=unsafe_prompt,
            ),
        )


def test_supported_candidate_passes_the_token_evidence_audit(
    caplog: pytest.LogCaptureFixture,
) -> None:
    metrics = MetricsRegistry()
    client = FakeConverseClient(_response(_supported_assessment()))
    critic = _critic(client, metrics=metrics)

    with caplog.at_level(logging.INFO, logger="simplynext.agent.critic"):
        verdict = critic.review(draft=_draft(), lattice=_lattice())

    assert verdict == CriticVerdict(
        supported=True,
        reason="all_candidate_tokens_supported",
    )
    assert "critic_model_call" in caplog.text
    assert metrics.snapshot()["counters"] == {
        "critic_model_calls_succeeded": 1,
        "critic_model_calls_total": 1,
        "critic_output_validation_attempts": 1,
        "critic_output_validation_successes": 1,
        "critic_verdicts_supported": 1,
    }


def test_hand_written_sentence_with_a_word_without_support_is_rejected() -> None:
    client = FakeConverseClient(_response(_invented_token_assessment()))

    verdict = _critic(client).review(draft=_draft(invented_token=True), lattice=_lattice())

    assert verdict.supported is False
    assert verdict.reason == "unsupported_candidate_token:1"


def test_critic_cannot_omit_the_unsupported_token_to_approve_a_sentence() -> None:
    assessment = _invented_token_assessment()
    token_assessments = assessment["token_assessments"]
    assert isinstance(token_assessments, list)
    assessment["token_assessments"] = [
        {**item, "token_index": index}
        for index, item in enumerate(token_assessments)
        if isinstance(item, dict) and item["token"] != "unicorn"
    ]
    assessment["supported"] = True
    metrics = MetricsRegistry()

    verdict = _critic(
        FakeConverseClient(_response(assessment)),
        metrics=metrics,
    ).review(draft=_draft(invented_token=True), lattice=_lattice())

    assert verdict == CriticVerdict(supported=False, reason="critic_output_invalid")
    assert metrics.snapshot()["counters"] == {
        "critic_model_calls_succeeded": 1,
        "critic_model_calls_total": 1,
        "critic_output_validation_attempts": 1,
        "critic_output_validation_failures": 1,
        "critic_verdicts_rejected": 1,
    }


def test_critic_cannot_cite_a_resolved_gloss_outside_the_token_part() -> None:
    assessment = _supported_assessment()
    token_assessments = assessment["token_assessments"]
    assert isinstance(token_assessments, list)
    first = token_assessments[0]
    assert isinstance(first, dict)
    first["evidence"] = [{"slot_id": "slot-1", "gloss_id": "THANK_YOU"}]

    verdict = _critic(FakeConverseClient(_response(assessment))).review(
        draft=_draft(),
        lattice=_lattice(),
    )

    assert verdict == CriticVerdict(supported=False, reason="critic_output_invalid")


def test_critic_prompt_contains_only_compact_lattice_and_draft_evidence() -> None:
    client = FakeConverseClient(_response(_supported_assessment()))

    _critic(client).review(draft=_draft(), lattice=_lattice())

    call = client.calls[0]
    assert "toolConfig" not in call
    payload = json.loads(call["messages"][0]["content"][0]["text"])
    assert payload["lattice_slots"][0] == {
        "provenance": "classifier_high_confidence",
        "resolved_gloss_id": "WATER",
        "slot_id": "slot-0",
    }
    assert payload["candidate"]["tokens"][0]["evidence"] == [
        {"gloss_id": "WATER", "slot_id": "slot-0"}
    ]
    serialized = json.dumps(call).lower()
    assert "landmark" not in serialized
    assert "coordinate" not in serialized
    assert "candidate" in serialized
    assert "configured-critic-model-id" in serialized


def test_critic_is_a_graph_callback_and_model_failure_vetoes() -> None:
    accepted = _critic(FakeConverseClient(_response(_supported_assessment())))(
        _state(_draft()),
        AllowedToolExecutor(),
    )
    failed = _critic(FakeConverseClient(RuntimeError("Bedrock unavailable")))(
        _state(_draft()),
        AllowedToolExecutor(),
    )

    assert accepted.supported is True
    assert failed == CriticVerdict(supported=False, reason="critic_service_unavailable")
