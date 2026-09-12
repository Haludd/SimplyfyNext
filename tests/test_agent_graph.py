from __future__ import annotations

from pathlib import Path
from threading import Event, Thread
from typing import cast
from uuid import UUID

import pytest
from pydantic import JsonValue, ValidationError

from simplynext.agent.graph import (
    MAX_GRAPH_LOOP_CAP,
    AdapterUpdate,
    AgentGraphNodes,
    AgentGraphState,
    AllowedToolExecutor,
    ConfidentResult,
    CriticVerdict,
    GraphNodeName,
    GraphOutcome,
    GraphPayload,
    RepairAction,
    RepairResult,
    ThreadInvocationInProgressError,
    ThreadScopeError,
    ToolNotAllowedError,
    build_agent_graph,
)
from simplynext.agent.state import (
    ConversationMessage,
    ConversationRole,
    SignerMemoryEntry,
    SignerMemoryKind,
    create_agent_state,
)
from simplynext.contracts import GlossLattice

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"
SESSION_ID = UUID("12345678-1234-5678-1234-567812345678")


def lattice(
    *,
    lattice_seq: int = 7,
    utterance_id: str = "utterance-42",
    session_id: UUID = SESSION_ID,
) -> GlossLattice:
    fixture = GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))
    return GlossLattice.model_validate(
        {
            **fixture.model_dump(),
            "lattice_seq": lattice_seq,
            "utterance_id": utterance_id,
            "session_id": session_id,
        }
    )


class Scenario:
    def __init__(self, *, support_after_critic_call: int | None) -> None:
        self.support_after_critic_call = support_after_critic_call
        self.calls: list[str] = []
        self.assembler_calls = 0
        self.critic_calls = 0

    def assembler(self, state: AgentGraphState, tools: AllowedToolExecutor) -> GraphPayload:
        del state, tools
        self.calls.append("assembler")
        self.assembler_calls += 1
        return {"attempt": self.assembler_calls}

    def critic(self, state: AgentGraphState, tools: AllowedToolExecutor) -> CriticVerdict:
        del state, tools
        self.calls.append("critic")
        self.critic_calls += 1
        supported = (
            self.support_after_critic_call is not None
            and self.critic_calls >= self.support_after_critic_call
        )
        return CriticVerdict(supported=supported, reason="fixture verdict")

    def confident(self, state: AgentGraphState, tools: AllowedToolExecutor) -> ConfidentResult:
        del state, tools
        self.calls.append("confident")
        return ConfidentResult(payload={"text": "Water."})

    def repair(self, state: AgentGraphState, tools: AllowedToolExecutor) -> RepairResult:
        del state, tools
        self.calls.append("repair")
        return RepairResult(action=RepairAction.ASK_REPEAT)

    def adapter(self, state: AgentGraphState, tools: AllowedToolExecutor) -> AdapterUpdate:
        del state, tools
        self.calls.append("adapter")
        return {}

    def nodes(self) -> AgentGraphNodes:
        return AgentGraphNodes(
            assembler=self.assembler,
            critic=self.critic,
            confident=self.confident,
            repair=self.repair,
            adapter=self.adapter,
        )


def test_forced_disagreement_stops_at_cap_and_records_exact_route() -> None:
    scenario = Scenario(support_after_critic_call=None)
    graph = build_agent_graph(scenario.nodes())
    state = create_agent_state(lattice(), signer_id="signer-7", loop_cap=1)

    result = graph.invoke(state, thread_id="conversation-forced-disagreement")

    assert result["loop_count"] == 1
    assert result["outcome"] is GraphOutcome.REPAIR_REQUIRED
    assert result["result"] == RepairResult(action=RepairAction.ASK_REPEAT)
    assert scenario.assembler_calls == 2
    assert scenario.critic_calls == 2
    assert scenario.calls == [
        "assembler",
        "critic",
        "assembler",
        "critic",
        "repair",
        "adapter",
    ]
    assert result["run_record"] is not None
    assert result["run_record"].loop_count == 1
    assert result["run_record"].loop_cap == 1
    assert result["run_record"].session_id == lattice().session_id
    assert result["run_record"].lattice_seq == lattice().lattice_seq
    assert result["run_record"].outcome is GraphOutcome.REPAIR_REQUIRED
    assert result["run_record"].node_path == (
        GraphNodeName.ASSEMBLER,
        GraphNodeName.CRITIC,
        GraphNodeName.INCREMENT_LOOP,
        GraphNodeName.ASSEMBLER,
        GraphNodeName.CRITIC,
        GraphNodeName.REPAIR,
        GraphNodeName.ADAPTER,
    )


def test_critic_acceptance_takes_confident_path_without_refinement() -> None:
    scenario = Scenario(support_after_critic_call=1)
    graph = build_agent_graph(scenario.nodes())

    result = graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=1),
        thread_id="conversation-confident",
    )

    assert result["loop_count"] == 0
    assert result["outcome"] is GraphOutcome.CONFIDENT
    assert scenario.calls == ["assembler", "critic", "confident", "adapter"]
    assert result["run_record"] is not None
    assert result["run_record"].node_path == (
        GraphNodeName.ASSEMBLER,
        GraphNodeName.CRITIC,
        GraphNodeName.CONFIDENT,
        GraphNodeName.ADAPTER,
    )


def test_one_disagreement_then_acceptance_uses_the_single_refinement() -> None:
    scenario = Scenario(support_after_critic_call=2)
    graph = build_agent_graph(scenario.nodes())

    result = graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=1),
        thread_id="conversation-refined",
    )

    assert result["loop_count"] == 1
    assert result["outcome"] is GraphOutcome.CONFIDENT
    assert result["node_path"] == (
        GraphNodeName.ASSEMBLER,
        GraphNodeName.CRITIC,
        GraphNodeName.INCREMENT_LOOP,
        GraphNodeName.ASSEMBLER,
        GraphNodeName.CRITIC,
        GraphNodeName.CONFIDENT,
        GraphNodeName.ADAPTER,
    )
    assert "repair" not in scenario.calls


def test_zero_cap_routes_first_disagreement_directly_to_repair() -> None:
    scenario = Scenario(support_after_critic_call=None)
    graph = build_agent_graph(scenario.nodes())

    result = graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=0),
        thread_id="conversation-zero-cap",
    )

    assert result["loop_count"] == 0
    assert scenario.assembler_calls == 1
    assert scenario.critic_calls == 1
    assert GraphNodeName.INCREMENT_LOOP not in result["node_path"]
    assert result["outcome"] is GraphOutcome.REPAIR_REQUIRED


def test_graph_rejects_a_loop_cap_above_the_absolute_product_ceiling() -> None:
    scenario = Scenario(support_after_critic_call=None)
    graph = build_agent_graph(scenario.nodes())

    with pytest.raises(ValueError, match="hard graph maximum"):
        graph.invoke(
            create_agent_state(lattice(), signer_id="signer-7", loop_cap=MAX_GRAPH_LOOP_CAP + 1),
            thread_id="over-limit",
        )

    assert scenario.calls == []


@pytest.mark.parametrize("invalid", (1, "true", "yes"))
def test_critic_verdict_never_coerces_a_truthy_value_to_approval(invalid: object) -> None:
    with pytest.raises(ValidationError):
        CriticVerdict.model_validate({"supported": invalid})


def test_checkpoints_carry_conversation_within_thread_and_isolate_other_threads() -> None:
    scenario = Scenario(support_after_critic_call=1)
    graph = build_agent_graph(scenario.nodes())
    first = ConversationMessage(
        message_id="message-1",
        role=ConversationRole.SIGNER,
        content="WATER",
    )
    second = ConversationMessage(
        message_id="message-2",
        role=ConversationRole.ASSISTANT,
        content="Water.",
    )

    graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7", conversation_history=(first,)),
        thread_id="conversation-persistent",
    )
    continued = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=8, utterance_id="utterance-43"),
            signer_id="signer-7",
            conversation_history=(second,),
        ),
        thread_id="conversation-persistent",
    )
    isolated = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=8, utterance_id="utterance-43"),
            signer_id="signer-7",
            conversation_history=(second,),
        ),
        thread_id="conversation-isolated",
    )

    assert continued["conversation_history"] == (first, second)
    assert isolated["conversation_history"] == (second,)


def test_new_utterance_resets_working_values_on_a_reused_thread() -> None:
    scenario = Scenario(support_after_critic_call=None)
    graph = build_agent_graph(scenario.nodes())
    first = graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=1),
        thread_id="conversation-reset",
    )
    assert first["loop_count"] == 1
    assert first["outcome"] is GraphOutcome.REPAIR_REQUIRED

    scenario.support_after_critic_call = scenario.critic_calls + 1
    second = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=8, utterance_id="utterance-43"),
            signer_id="signer-7",
            loop_cap=1,
        ),
        thread_id="conversation-reset",
    )

    assert second["loop_count"] == 0
    assert second["outcome"] is GraphOutcome.CONFIDENT
    assert second["node_path"] == (
        GraphNodeName.ASSEMBLER,
        GraphNodeName.CRITIC,
        GraphNodeName.CONFIDENT,
        GraphNodeName.ADAPTER,
    )


def test_thread_cannot_be_reused_for_another_signer() -> None:
    scenario = Scenario(support_after_critic_call=1)
    graph = build_agent_graph(scenario.nodes())
    graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7"),
        thread_id="signer-scoped-thread",
    )
    call_count = len(scenario.calls)

    with pytest.raises(ThreadScopeError, match="different signer"):
        graph.invoke(
            create_agent_state(lattice(), signer_id="signer-8"),
            thread_id="signer-scoped-thread",
        )

    assert len(scenario.calls) == call_count


def test_thread_cannot_be_reused_for_another_conversation_session() -> None:
    scenario = Scenario(support_after_critic_call=1)
    graph = build_agent_graph(scenario.nodes())
    graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7"),
        thread_id="session-scoped-thread",
    )
    call_count = len(scenario.calls)

    with pytest.raises(ThreadScopeError, match="different conversation session"):
        graph.invoke(
            create_agent_state(
                lattice(
                    session_id=UUID("87654321-4321-8765-4321-876543218765"),
                    lattice_seq=1,
                    utterance_id="other-session-utterance",
                ),
                signer_id="signer-7",
            ),
            thread_id="session-scoped-thread",
        )

    assert len(scenario.calls) == call_count


def test_same_thread_invocations_are_rejected_instead_of_racing() -> None:
    scenario = Scenario(support_after_critic_call=1)
    entered = Event()
    release = Event()

    def blocking_assembler(state: AgentGraphState, tools: AllowedToolExecutor) -> GraphPayload:
        entered.set()
        if not release.wait(timeout=2):
            raise TimeoutError("test did not release the graph node")
        return scenario.assembler(state, tools)

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=blocking_assembler,
            critic=scenario.critic,
            confident=scenario.confident,
            repair=scenario.repair,
            adapter=scenario.adapter,
        )
    )
    worker_errors: list[BaseException] = []

    def run_first_invocation() -> None:
        try:
            graph.invoke(
                create_agent_state(lattice(), signer_id="signer-7"),
                thread_id="busy-thread",
            )
        except BaseException as exc:  # pragma: no cover - asserted after joining
            worker_errors.append(exc)

    worker = Thread(target=run_first_invocation)
    worker.start()
    assert entered.wait(timeout=2)
    try:
        with pytest.raises(ThreadInvocationInProgressError, match="already running"):
            graph.invoke(
                create_agent_state(
                    lattice(lattice_seq=8, utterance_id="utterance-43"),
                    signer_id="signer-7",
                ),
                thread_id="busy-thread",
            )
    finally:
        release.set()
        worker.join(timeout=2)

    assert not worker.is_alive()
    assert worker_errors == []


def test_thread_id_is_required_and_normalized_state_must_start_at_zero() -> None:
    graph = build_agent_graph(Scenario(support_after_critic_call=1).nodes())
    state = create_agent_state(lattice(), signer_id="signer-7")

    with pytest.raises(ValueError, match="thread_id"):
        graph.invoke(state, thread_id=" ")
    with pytest.raises(ValueError, match="loop_count=0"):
        graph.invoke({**state, "loop_count": 1}, thread_id="invalid-state")


class ToolScenario(Scenario):
    def __init__(self, tool_name: str) -> None:
        super().__init__(support_after_critic_call=1)
        self.tool_name = tool_name

    def assembler(self, state: AgentGraphState, tools: AllowedToolExecutor) -> GraphPayload:
        del state
        self.calls.append("assembler")
        self.assembler_calls += 1
        tool_result = tools.call(self.tool_name, {"gloss_id": "WATER"})
        return {"tool_result": tool_result}


def lookup(arguments: dict[str, JsonValue]) -> JsonValue:
    return {"found": arguments.get("gloss_id") == "WATER"}


def test_tools_are_default_deny_and_only_explicit_names_are_callable() -> None:
    denied = ToolScenario("lookup")
    denied_graph = build_agent_graph(denied.nodes(), tool_registry={"lookup": lookup})
    assert denied_graph.allowed_tools == ()
    with pytest.raises(ToolNotAllowedError, match="lookup"):
        denied_graph.invoke(
            create_agent_state(lattice(), signer_id="signer-7"),
            thread_id="tools-denied",
        )

    allowed = ToolScenario("lookup")
    allowed_graph = build_agent_graph(
        allowed.nodes(),
        tool_registry={"lookup": lookup},
        allowed_tools=("lookup",),
    )
    result = allowed_graph.invoke(
        create_agent_state(lattice(), signer_id="signer-7"),
        thread_id="tools-allowed",
    )

    assert allowed_graph.allowed_tools == ("lookup",)
    assert result["draft"] == {"tool_result": {"found": True}}
    with pytest.raises(ValueError, match="unregistered"):
        build_agent_graph(allowed.nodes(), allowed_tools=("missing",))


def test_non_finite_node_payload_is_rejected_before_it_enters_state() -> None:
    scenario = Scenario(support_after_critic_call=1)

    def invalid_assembler(state: AgentGraphState, tools: AllowedToolExecutor) -> GraphPayload:
        del state, tools
        return {"confidence": float("nan")}

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=invalid_assembler,
            critic=scenario.critic,
            confident=scenario.confident,
            repair=scenario.repair,
            adapter=scenario.adapter,
        )
    )

    with pytest.raises(ValueError, match="finite JSON"):
        graph.invoke(
            create_agent_state(lattice(), signer_id="signer-7"),
            thread_id="non-finite-payload",
        )


def test_repair_branch_rejects_a_confident_result_envelope() -> None:
    scenario = Scenario(support_after_critic_call=None)

    def invalid_repair(state: AgentGraphState, tools: AllowedToolExecutor) -> RepairResult:
        del state, tools
        return cast(RepairResult, ConfidentResult(payload={"text": "Unsupported guess."}))

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=scenario.assembler,
            critic=scenario.critic,
            confident=scenario.confident,
            repair=invalid_repair,
            adapter=scenario.adapter,
        )
    )

    with pytest.raises(TypeError, match="repair node must return RepairResult"):
        graph.invoke(
            create_agent_state(lattice(), signer_id="signer-7", loop_cap=0),
            thread_id="wrong-repair-envelope",
        )


def test_adapter_cannot_override_graph_control_state() -> None:
    scenario = Scenario(support_after_critic_call=1)

    def malicious_adapter(state: AgentGraphState, tools: AllowedToolExecutor) -> AdapterUpdate:
        del state, tools
        return cast(AdapterUpdate, {"loop_count": 999})

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=scenario.assembler,
            critic=scenario.critic,
            confident=scenario.confident,
            repair=scenario.repair,
            adapter=malicious_adapter,
        )
    )

    with pytest.raises(ValueError, match="forbidden state keys: loop_count"):
        graph.invoke(
            create_agent_state(lattice(), signer_id="signer-7"),
            thread_id="malicious-adapter",
        )


def test_adapter_cannot_write_memory_for_another_signer() -> None:
    scenario = Scenario(support_after_critic_call=1)
    foreign_memory = SignerMemoryEntry(
        memory_id="foreign-memory",
        signer_id="signer-8",
        kind=SignerMemoryKind.CORRECTION,
        key="classifier-gloss:WATER",
        value="DRINK_WATER",
        confirmed_by_signer=True,
        confirmation_utterance_id="utterance-42",
    )

    def foreign_adapter(state: AgentGraphState, tools: AllowedToolExecutor) -> AdapterUpdate:
        del state, tools
        return {"signer_memory": (foreign_memory,)}

    graph = build_agent_graph(
        AgentGraphNodes(
            assembler=scenario.assembler,
            critic=scenario.critic,
            confident=scenario.confident,
            repair=scenario.repair,
            adapter=foreign_adapter,
        )
    )

    with pytest.raises(ValueError, match="outside the current signer scope"):
        graph.invoke(
            create_agent_state(lattice(), signer_id="signer-7"),
            thread_id="foreign-memory",
        )


@pytest.mark.asyncio
async def test_async_invocation_uses_same_bounded_graph() -> None:
    graph = build_agent_graph(Scenario(support_after_critic_call=None).nodes())

    result = await graph.ainvoke(
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=1),
        thread_id="async-graph",
    )

    assert result["outcome"] is GraphOutcome.REPAIR_REQUIRED
    assert result["run_record"] is not None
    assert result["run_record"].loop_count == 1
