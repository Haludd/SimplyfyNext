from __future__ import annotations

import json
from pathlib import Path

import pytest

from simplynext.agent.graph import (
    AdapterUpdate,
    AgentGraphNodes,
    AgentGraphState,
    AllowedToolExecutor,
    ConfidentResult,
    CriticVerdict,
    GraphOutcome,
    GraphPayload,
    RepairAction,
    build_agent_graph,
)
from simplynext.agent.repair import (
    DeterministicRepairNode,
    RepairPlan,
    RepairResponseMode,
    UncertaintyShape,
)
from simplynext.agent.state import create_agent_state
from simplynext.contracts import GlossLattice
from simplynext.observability import MetricsRegistry

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"


def lattice_with_slot_3(**changes: object) -> GlossLattice:
    lattice = GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))
    slots = [slot.model_dump(mode="python") for slot in lattice.slots]
    slots[3].update(changes)
    return GlossLattice.model_validate({**lattice.model_dump(mode="python"), "slots": slots})


def repair_state(gloss_lattice: GlossLattice, *, reason: str) -> AgentGraphState:
    return AgentGraphState(
        **create_agent_state(gloss_lattice, signer_id="signer-7", loop_cap=0),
        draft={"safe": True},
        critique=CriticVerdict(supported=False, reason=reason),
        result=None,
        outcome=None,
        node_path=(),
        run_record=None,
    )


def run_repair(gloss_lattice: GlossLattice, *, reason: str = "unsupported_candidate_token:1"):
    return DeterministicRepairNode()(
        repair_state(gloss_lattice, reason=reason),
        AllowedToolExecutor(),
    )


def repair_plan(details: GraphPayload) -> RepairPlan:
    return RepairPlan.model_validate_json(json.dumps(details))


def test_multiple_retained_hypotheses_offer_exact_top_k_without_a_sentence() -> None:
    result = run_repair(lattice_with_slot_3())
    plan = repair_plan(result.details)

    assert result.action is RepairAction.OFFER_TOP_K
    assert plan.uncertainty_shape is UncertaintyShape.MULTIPLE_RETAINED_CANDIDATES
    assert plan.response_mode is RepairResponseMode.SELECT_TOP_K
    assert [(option.gloss_id, option.rank) for option in plan.options] == [
        ("TOMORROW", 1),
        ("YESTERDAY", 2),
    ]
    assert plan.signer_prompt_gloss_ids == ("WHICH_ONE",)
    assert plan.accepted_reply_gloss_ids == ("TOMORROW", "YESTERDAY", "YES", "NO")
    assert "No spoken sentence was produced" in plan.listener_notice
    serialized = json.dumps(result.model_dump(mode="json"))
    assert all(key not in serialized for key in ('"caption"', '"candidate_text"', '"tts"'))


def test_no_candidates_requests_fingerspelling_and_one_candidate_requests_repeat() -> None:
    fingerspelling = run_repair(lattice_with_slot_3(candidates=[]))
    repeat = run_repair(
        lattice_with_slot_3(candidates=[{"gloss_id": "TOMORROW", "rank": 1, "confidence": 0.42}])
    )

    fingerspelling_plan = repair_plan(fingerspelling.details)
    repeat_plan = repair_plan(repeat.details)
    assert fingerspelling.action is RepairAction.REQUEST_FINGERSPELLING
    assert fingerspelling_plan.signer_prompt_gloss_ids == ("SPELL_IT",)
    assert fingerspelling_plan.response_mode is RepairResponseMode.FINGERSPELL
    assert repeat.action is RepairAction.ASK_REPEAT
    assert repeat_plan.signer_prompt_gloss_ids == ("SAY_THAT_AGAIN",)
    assert repeat_plan.response_mode is RepairResponseMode.REPEAT_UTTERANCE


def test_critic_failure_or_fully_resolved_rejection_escalates_instead_of_guessing() -> None:
    critic_failure = run_repair(lattice_with_slot_3(), reason="critic_output_invalid")
    resolved = run_repair(
        lattice_with_slot_3(
            resolved_gloss_id="TOMORROW",
            provenance="top_k_signer_confirmed",
        )
    )

    assert critic_failure.action is RepairAction.ESCALATE_HUMAN_INTERPRETER
    assert repair_plan(critic_failure.details).uncertainty_shape is UncertaintyShape.CRITIC_FAILURE
    assert resolved.action is RepairAction.ESCALATE_HUMAN_INTERPRETER
    assert (
        repair_plan(resolved.details).uncertainty_shape
        is UncertaintyShape.UNSUPPORTED_RESOLVED_DRAFT
    )


def test_multiple_unresolved_slots_request_a_fresh_utterance() -> None:
    gloss_lattice = lattice_with_slot_3()
    slots = [slot.model_dump(mode="python") for slot in gloss_lattice.slots]
    slots[2].update(
        resolved_gloss_id=None,
        provenance="unresolved",
        candidates=[],
    )
    result = run_repair(
        GlossLattice.model_validate({**gloss_lattice.model_dump(mode="python"), "slots": slots})
    )

    assert result.action is RepairAction.ASK_REPEAT
    assert (
        repair_plan(result.details).uncertainty_shape is UncertaintyShape.MULTIPLE_UNRESOLVED_SLOTS
    )


def test_repair_node_requires_a_rejected_verdict() -> None:
    state = repair_state(lattice_with_slot_3(), reason="fixture")
    state["critique"] = CriticVerdict(supported=True, reason="supported")

    with pytest.raises(ValueError, match="unsupported critic verdict"):
        DeterministicRepairNode()(state, AllowedToolExecutor())


def test_low_confidence_graph_run_returns_only_repair_and_records_the_branch() -> None:
    metrics = MetricsRegistry()
    repair = DeterministicRepairNode(metrics=metrics)

    def assembler(state: AgentGraphState, tools: AllowedToolExecutor) -> GraphPayload:
        del state, tools
        return {"candidate": "intentionally rejected"}

    def critic(state: AgentGraphState, tools: AllowedToolExecutor) -> CriticVerdict:
        del state, tools
        return CriticVerdict(supported=False, reason="unsupported_candidate_token:0")

    def forbidden_confident(state: AgentGraphState, tools: AllowedToolExecutor) -> ConfidentResult:
        del state, tools
        raise AssertionError("low-confidence input must not reach the confident node")

    def adapter(state: AgentGraphState, tools: AllowedToolExecutor) -> AdapterUpdate:
        del state, tools
        return {}

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=assembler,
            critic=critic,
            confident=forbidden_confident,
            repair=repair,
            adapter=adapter,
        )
    )
    output = graph.invoke(
        create_agent_state(lattice_with_slot_3(), signer_id="signer-7", loop_cap=0),
        thread_id="repair-end-to-end",
    )

    assert output["outcome"] is GraphOutcome.REPAIR_REQUIRED
    assert output["result"] is not None
    assert output["result"].kind == "repair"
    assert metrics.snapshot()["counters"] == {
        "repair_action_offer_top_k_total": 1,
        "repair_actions_total": 1,
    }
