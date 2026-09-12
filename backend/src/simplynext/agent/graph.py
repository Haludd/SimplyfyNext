"""Bounded LangGraph wiring for sign-to-spoken stages 6 through 10.

This module owns orchestration, not model prompts or domain decisions.  Concrete
assembler, critic, outcome, and adapter implementations are injected as callbacks so
the graph can enforce the retry cap and tool boundary independently of any model's
output.
"""

from __future__ import annotations

import json
from _thread import LockType
from collections.abc import Callable, Collection, Mapping
from dataclasses import dataclass
from enum import StrEnum
from threading import Lock
from types import MappingProxyType
from typing import Any, Final, Literal, Protocol, TypeAlias, TypedDict, cast, runtime_checkable
from uuid import UUID

from langgraph.checkpoint.base import BaseCheckpointSaver
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Overwrite
from pydantic import BaseModel, ConfigDict, Field, JsonValue, TypeAdapter, model_validator

from simplynext.agent.state import (
    AgentState,
    ConversationHistory,
    SignerMemory,
    create_agent_state,
    loop_limit_reached,
    next_loop_update,
    reduce_conversation_history,
    reduce_signer_memory,
)
from simplynext.contracts.common import Identifier
from simplynext.contracts.events import LatticeRepairAction as RepairAction
from simplynext.contracts.gloss_lattice import GlossLattice

GraphPayload: TypeAlias = dict[str, JsonValue]
ToolArguments: TypeAlias = dict[str, JsonValue]
AgentTool: TypeAlias = Callable[[ToolArguments], JsonValue]
MAX_GRAPH_LOOP_CAP: Final[int] = 1

_JSON_OBJECT_ADAPTER: TypeAdapter[GraphPayload] = TypeAdapter(dict[str, JsonValue])
_JSON_VALUE_ADAPTER: TypeAdapter[JsonValue] = TypeAdapter(JsonValue)
_IDENTIFIERS_ADAPTER: TypeAdapter[tuple[Identifier, ...]] = TypeAdapter(tuple[Identifier, ...])


class _GraphValue(BaseModel):
    """Strict immutable value stored in graph state or returned to its caller."""

    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
        str_strip_whitespace=True,
        validate_default=True,
    )


class CriticVerdict(_GraphValue):
    """The critic's one decision: whether every proposed detail is supported."""

    supported: bool
    reason: str = Field(default="", max_length=1_000)


class GraphOutcome(StrEnum):
    """Terminal branch selected by graph-owned control flow."""

    CONFIDENT = "confident"
    REPAIR_REQUIRED = "repair_required"


class GraphNodeName(StrEnum):
    """Stable node names used in run records and graph inspection."""

    ASSEMBLER = "assembler"
    CRITIC = "critic"
    INCREMENT_LOOP = "increment_loop"
    CONFIDENT = "confident"
    REPAIR = "repair"
    ADAPTER = "adapter"


class AgentRunRecord(_GraphValue):
    """Small, auditable record of one completed graph invocation."""

    session_id: UUID
    lattice_seq: int = Field(strict=True, ge=0)
    utterance_id: Identifier
    outcome: GraphOutcome
    loop_count: int = Field(strict=True, ge=0)
    loop_cap: int = Field(strict=True, ge=0)
    node_path: tuple[GraphNodeName, ...]
    adaptation_request_ids: tuple[Identifier, ...] = ()
    memory_upserts_applied: int = Field(default=0, strict=True, ge=0)
    memory_deletions_applied: int = Field(default=0, strict=True, ge=0)


class ConfidentResult(_GraphValue):
    """Discriminated terminal envelope for a supported caption payload."""

    kind: Literal["confident"] = "confident"
    payload: GraphPayload


class RepairResult(_GraphValue):
    """Discriminated terminal envelope for a repair action, never a caption."""

    kind: Literal["repair"] = "repair"
    action: RepairAction
    details: GraphPayload = Field(default_factory=dict)


class AgentGraphState(AgentState):
    """T5.1 state plus the bounded graph's per-invocation working values."""

    draft: GraphPayload | None
    critique: CriticVerdict | None
    result: ConfidentResult | RepairResult | None
    outcome: GraphOutcome | None
    node_path: tuple[GraphNodeName, ...]
    run_record: AgentRunRecord | None


class AdapterUpdate(TypedDict, total=False):
    """Persistent values and graph-consumed audit metadata from stage ⑩."""

    conversation_history: ConversationHistory
    signer_memory: SignerMemory
    signer_memory_deletions: tuple[Identifier, ...]
    processed_adaptation_request_ids: tuple[Identifier, ...]


@dataclass(frozen=True, slots=True)
class _ValidatedAdapterUpdate:
    state_update: dict[str, object]
    request_ids: tuple[str, ...]
    upserts_applied: int
    deletions_applied: int


class AgentToolDefinition(_GraphValue):
    """Model-facing name, description, and strict JSON input schema for one tool."""

    name: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")
    description: str = Field(min_length=40, max_length=4_000)
    input_schema: GraphPayload

    @model_validator(mode="after")
    def require_object_input_schema(self) -> AgentToolDefinition:
        if self.input_schema.get("type") != "object":
            raise ValueError("tool input schema must have object as its top-level type")
        return self


@runtime_checkable
class StateAwareAgentTool(Protocol):
    """Read-only tool that receives trusted graph state outside model arguments."""

    @property
    def definition(self) -> AgentToolDefinition:
        """Return the model-facing definition for this tool."""

        ...

    def invoke(self, arguments: ToolArguments, state: AgentState) -> JsonValue:
        """Execute against one validated invocation state."""

        ...


ToolHandler: TypeAlias = AgentTool | StateAwareAgentTool


AssemblerNode: TypeAlias = Callable[
    [AgentGraphState, "AllowedToolExecutor"], Mapping[str, JsonValue]
]
CriticNode: TypeAlias = Callable[[AgentGraphState, "AllowedToolExecutor"], CriticVerdict]
ConfidentNode: TypeAlias = Callable[[AgentGraphState, "AllowedToolExecutor"], ConfidentResult]
RepairNode: TypeAlias = Callable[[AgentGraphState, "AllowedToolExecutor"], RepairResult]
AdapterNode: TypeAlias = Callable[[AgentGraphState, "AllowedToolExecutor"], AdapterUpdate | None]


@dataclass(frozen=True, slots=True)
class AgentGraphNodes:
    """Pure stage behaviours supplied to the orchestration layer.

    Callbacks calculate state only. Irreversible delivery such as TTS or escalation is
    dispatched after success using the run record's ``(session_id, lattice_seq)`` as
    its idempotency key.
    """

    assembler: AssemblerNode
    critic: CriticNode
    confident: ConfidentNode
    repair: RepairNode
    adapter: AdapterNode


class ToolNotAllowedError(PermissionError):
    """Raised when a node tries to cross the graph's explicit tool boundary."""


class ToolStateRequiredError(RuntimeError):
    """Raised when a state-aware tool is invoked without trusted graph state."""


class ThreadScopeError(ValueError):
    """Raised before one checkpoint thread could cross signer or session scope."""


class ThreadInvocationInProgressError(RuntimeError):
    """Raised instead of racing two invocations through one checkpoint thread."""


class AllowedToolExecutor:
    """Default-deny executor exposing only construction-time allow-listed tools.

    This is an application security boundary: a node receives no registry handle and
    cannot call a registered tool through this object unless its name was explicitly
    allowed when the graph was built. Registered tools must be idempotent reads; nodes
    return planned effects and dispatch them only after a completed run.
    """

    __slots__ = ("_tools",)

    def __init__(
        self,
        registry: Mapping[str, ToolHandler] | None = None,
        *,
        allowed_tools: Collection[str] = (),
    ) -> None:
        available = dict(registry or {})
        if isinstance(allowed_tools, str):
            raise TypeError("allowed_tools must be a collection of tool names")
        allowed = frozenset(allowed_tools)
        invalid_names = sorted(
            repr(name)
            for name in (*available, *allowed)
            if not isinstance(name, str) or not name or name.strip() != name
        )
        if invalid_names:
            raise ValueError("tool names must be non-empty and have no surrounding whitespace")
        non_callable = sorted(
            name
            for name, tool in available.items()
            if not callable(tool) and not isinstance(tool, StateAwareAgentTool)
        )
        if non_callable:
            raise TypeError(f"registered tools must be callable: {', '.join(non_callable)}")
        unknown = sorted(allowed.difference(available))
        if unknown:
            raise ValueError(f"allowed_tools contains unregistered tools: {', '.join(unknown)}")

        self._tools: Mapping[str, ToolHandler] = MappingProxyType(
            {name: available[name] for name in sorted(allowed)}
        )

    @property
    def allowed_tools(self) -> tuple[str, ...]:
        """Return the immutable, deterministic allow-list visible to nodes."""

        return tuple(self._tools)

    @property
    def definitions(self) -> tuple[AgentToolDefinition, ...]:
        """Return model-facing definitions for described tools in allow-list order."""

        definitions: list[AgentToolDefinition] = []
        for name, tool in self._tools.items():
            definition = getattr(tool, "definition", None)
            if definition is None:
                continue
            if not isinstance(definition, AgentToolDefinition):
                raise TypeError(f"tool definition must be AgentToolDefinition: {name}")
            if definition.name != name:
                raise ValueError(f"tool definition name does not match registry key: {name}")
            definitions.append(definition)
        return tuple(definitions)

    def call(
        self,
        name: str,
        arguments: Mapping[str, JsonValue] | None = None,
        *,
        state: AgentState | None = None,
    ) -> JsonValue:
        """Validate and call one allowed tool, rejecting all other names."""

        tool = self._tools.get(name)
        if tool is None:
            raise ToolNotAllowedError(f"tool is not allowed: {name}")
        validated_arguments = _JSON_OBJECT_ADAPTER.validate_python(
            dict(arguments or {}), strict=True
        )
        _require_finite_json(validated_arguments, f"{name} arguments")
        if isinstance(tool, StateAwareAgentTool):
            if state is None:
                raise ToolStateRequiredError(f"tool requires trusted graph state: {name}")
            raw_result = tool.invoke(validated_arguments, state)
        else:
            raw_result = tool(validated_arguments)
        result = _JSON_VALUE_ADAPTER.validate_python(raw_result, strict=True)
        _require_finite_json(result, f"{name} result")
        return result


class AgentGraph:
    """Invocation facade that makes ``thread_id`` and signer isolation mandatory."""

    __slots__ = (
        "_checkpointer",
        "_compiled",
        "_thread_locks",
        "_thread_locks_guard",
        "_tools",
    )

    def __init__(
        self,
        *,
        compiled: Any,
        checkpointer: BaseCheckpointSaver[str],
        tools: AllowedToolExecutor,
    ) -> None:
        self._compiled = compiled
        self._checkpointer = checkpointer
        self._thread_locks: dict[str, LockType] = {}
        self._thread_locks_guard = Lock()
        self._tools = tools

    @property
    def checkpointer(self) -> BaseCheckpointSaver[str]:
        """Expose the saver for lifecycle management and checkpoint inspection."""

        return self._checkpointer

    @property
    def allowed_tools(self) -> tuple[str, ...]:
        """Return exactly the tool names made available to graph nodes."""

        return self._tools.allowed_tools

    def get_graph(self) -> Any:
        """Return LangGraph's non-executable representation for inspection."""

        return self._compiled.get_graph()

    def invoke(self, state: AgentState, *, thread_id: str) -> AgentGraphState:
        """Run one transport-deduplicated utterance under the required thread ID."""

        prepared, config = self._prepare_input(state, thread_id)
        thread_lock = self._acquire_thread(thread_id)
        try:
            snapshot = self._compiled.get_state(config)
            _validate_thread_scope(prepared, cast(Mapping[str, object], snapshot.values))
            result = cast(AgentGraphState, self._compiled.invoke(prepared, config=config))
            _require_completed_run(result)
            return result
        finally:
            thread_lock.release()

    async def ainvoke(self, state: AgentState, *, thread_id: str) -> AgentGraphState:
        """Asynchronously run one utterance with the same invariants as ``invoke``."""

        prepared, config = self._prepare_input(state, thread_id)
        thread_lock = self._acquire_thread(thread_id)
        try:
            snapshot = await self._compiled.aget_state(config)
            _validate_thread_scope(prepared, cast(Mapping[str, object], snapshot.values))
            result = cast(AgentGraphState, await self._compiled.ainvoke(prepared, config=config))
            _require_completed_run(result)
            return result
        finally:
            thread_lock.release()

    def _prepare_input(
        self, state: AgentState, thread_id: str
    ) -> tuple[AgentGraphState, dict[str, object]]:
        prepared = _initial_graph_state(state)
        config = _invocation_config(thread_id, prepared["loop_cap"])
        return prepared, config

    def _acquire_thread(self, thread_id: str) -> LockType:
        with self._thread_locks_guard:
            thread_lock = self._thread_locks.setdefault(thread_id, Lock())
        if not thread_lock.acquire(blocking=False):
            raise ThreadInvocationInProgressError(
                "another graph invocation is already running for this thread_id"
            )
        return thread_lock


def build_agent_graph(
    nodes: AgentGraphNodes,
    *,
    tool_registry: Mapping[str, ToolHandler] | None = None,
    allowed_tools: Collection[str] = (),
    checkpointer: BaseCheckpointSaver[str] | None = None,
) -> AgentGraph:
    """Build stages 6-10 with a deterministic, state-owned retry boundary."""

    tool_executor = AllowedToolExecutor(tool_registry, allowed_tools=allowed_tools)
    saver = checkpointer if checkpointer is not None else InMemorySaver()
    builder = StateGraph(AgentGraphState)

    def assembler(state: AgentGraphState) -> dict[str, object]:
        draft = _validated_payload(nodes.assembler(state, tool_executor), "assembler")
        return {
            "draft": draft,
            "critique": None,
            "node_path": (*state["node_path"], GraphNodeName.ASSEMBLER),
        }

    def critic(state: AgentGraphState) -> dict[str, object]:
        if state["draft"] is None:
            raise RuntimeError("critic requires an assembler draft")
        verdict = nodes.critic(state, tool_executor)
        if not isinstance(verdict, CriticVerdict):
            raise TypeError("critic node must return CriticVerdict")
        return {
            "critique": verdict,
            "node_path": (*state["node_path"], GraphNodeName.CRITIC),
        }

    def route_after_critic(
        state: AgentGraphState,
    ) -> Literal["confident", "increment_loop", "repair"]:
        verdict = state["critique"]
        if verdict is None:
            raise RuntimeError("critic routing requires a verdict")
        if verdict.supported:
            return GraphNodeName.CONFIDENT.value
        if loop_limit_reached(state):
            return GraphNodeName.REPAIR.value
        return GraphNodeName.INCREMENT_LOOP.value

    def increment_loop(state: AgentGraphState) -> dict[str, object]:
        return {
            **next_loop_update(state),
            "node_path": (*state["node_path"], GraphNodeName.INCREMENT_LOOP),
        }

    def confident(state: AgentGraphState) -> dict[str, object]:
        result = nodes.confident(state, tool_executor)
        if not isinstance(result, ConfidentResult):
            raise TypeError("confident node must return ConfidentResult")
        _require_finite_json(result.payload, "confident")
        return {
            "result": result,
            "outcome": GraphOutcome.CONFIDENT,
            "node_path": (*state["node_path"], GraphNodeName.CONFIDENT),
        }

    def repair(state: AgentGraphState) -> dict[str, object]:
        result = nodes.repair(state, tool_executor)
        if not isinstance(result, RepairResult):
            raise TypeError("repair node must return RepairResult")
        _require_finite_json(result.details, "repair")
        return {
            "result": result,
            "outcome": GraphOutcome.REPAIR_REQUIRED,
            "node_path": (*state["node_path"], GraphNodeName.REPAIR),
        }

    def adapter(state: AgentGraphState) -> dict[str, object]:
        if state["outcome"] is None or state["result"] is None:
            raise RuntimeError("adapter requires a terminal outcome and result")
        validated = _validated_adapter_update(nodes.adapter(state, tool_executor), state=state)
        update = validated.state_update
        node_path = (*state["node_path"], GraphNodeName.ADAPTER)
        update["adaptation_requests"] = ()
        update["node_path"] = node_path
        update["run_record"] = AgentRunRecord(
            session_id=state["lattice"].session_id,
            lattice_seq=state["lattice"].lattice_seq,
            utterance_id=state["lattice"].utterance_id,
            outcome=state["outcome"],
            loop_count=state["loop_count"],
            loop_cap=state["loop_cap"],
            node_path=node_path,
            adaptation_request_ids=validated.request_ids,
            memory_upserts_applied=validated.upserts_applied,
            memory_deletions_applied=validated.deletions_applied,
        )
        return update

    builder.add_node(GraphNodeName.ASSEMBLER.value, assembler)
    builder.add_node(GraphNodeName.CRITIC.value, critic)
    builder.add_node(GraphNodeName.INCREMENT_LOOP.value, increment_loop)
    builder.add_node(GraphNodeName.CONFIDENT.value, confident)
    builder.add_node(GraphNodeName.REPAIR.value, repair)
    builder.add_node(GraphNodeName.ADAPTER.value, adapter)

    builder.add_edge(START, GraphNodeName.ASSEMBLER.value)
    builder.add_edge(GraphNodeName.ASSEMBLER.value, GraphNodeName.CRITIC.value)
    builder.add_conditional_edges(
        GraphNodeName.CRITIC.value,
        route_after_critic,
        {
            GraphNodeName.CONFIDENT.value: GraphNodeName.CONFIDENT.value,
            GraphNodeName.INCREMENT_LOOP.value: GraphNodeName.INCREMENT_LOOP.value,
            GraphNodeName.REPAIR.value: GraphNodeName.REPAIR.value,
        },
    )
    builder.add_edge(GraphNodeName.INCREMENT_LOOP.value, GraphNodeName.ASSEMBLER.value)
    builder.add_edge(GraphNodeName.CONFIDENT.value, GraphNodeName.ADAPTER.value)
    builder.add_edge(GraphNodeName.REPAIR.value, GraphNodeName.ADAPTER.value)
    builder.add_edge(GraphNodeName.ADAPTER.value, END)

    return AgentGraph(
        compiled=builder.compile(checkpointer=saver),
        checkpointer=saver,
        tools=tool_executor,
    )


def _initial_graph_state(state: AgentState) -> AgentGraphState:
    try:
        loop_count = state["loop_count"]
        lattice = state["lattice"]
        signer_id = state["signer_id"]
        history = state["conversation_history"]
        memory = state["signer_memory"]
        adaptations = state["adaptation_requests"]
        loop_cap = state["loop_cap"]
    except KeyError as exc:
        raise ValueError(f"agent state is missing required key: {exc.args[0]}") from exc
    if type(loop_count) is not int or loop_count != 0:
        raise ValueError("each graph invocation must start with loop_count=0")

    base = create_agent_state(
        lattice,
        signer_id=signer_id,
        conversation_history=history,
        signer_memory=memory,
        adaptation_requests=adaptations,
        loop_cap=loop_cap,
    )
    if base["loop_cap"] > MAX_GRAPH_LOOP_CAP:
        raise ValueError(f"loop_cap cannot exceed the hard graph maximum ({MAX_GRAPH_LOOP_CAP})")
    return AgentGraphState(
        **base,
        draft=None,
        critique=None,
        result=None,
        outcome=None,
        node_path=(),
        run_record=None,
    )


def _invocation_config(thread_id: str, loop_cap: int) -> dict[str, object]:
    if not isinstance(thread_id, str) or not thread_id or thread_id.strip() != thread_id:
        raise ValueError("thread_id must be a non-empty string without surrounding whitespace")
    # The explicit state counter owns the product rule.  This framework guard is a
    # secondary fail-safe sized for the longest legal route plus modest overhead.
    recursion_limit = max(10, (loop_cap + 1) * 4 + 4)
    return {
        "configurable": {"thread_id": thread_id},
        "recursion_limit": recursion_limit,
    }


def _validated_payload(value: Mapping[str, JsonValue], node_name: str) -> GraphPayload:
    if not isinstance(value, Mapping):
        raise TypeError(f"{node_name} node must return a mapping")
    validated = _JSON_OBJECT_ADAPTER.validate_python(dict(value), strict=True)
    _require_finite_json(validated, node_name)
    return validated


def _validate_thread_scope(state: AgentGraphState, prior_values: Mapping[str, object]) -> None:
    prior_signer = prior_values.get("signer_id")
    if prior_signer is not None and prior_signer != state["signer_id"]:
        raise ThreadScopeError("thread_id is already scoped to a different signer")

    prior_lattice = prior_values.get("lattice")
    if prior_lattice is None:
        return
    if not isinstance(prior_lattice, GlossLattice):
        raise ThreadScopeError("thread checkpoint contains an invalid lattice scope")
    if prior_lattice.session_id != state["lattice"].session_id:
        raise ThreadScopeError("thread_id is already scoped to a different conversation session")


def _validated_adapter_update(
    value: AdapterUpdate | None,
    *,
    state: AgentGraphState,
) -> _ValidatedAdapterUpdate:
    if value is None:
        return _ValidatedAdapterUpdate({}, (), 0, 0)
    if not isinstance(value, Mapping):
        raise TypeError("adapter node must return a mapping or None")
    update: dict[str, object] = dict(value)
    unexpected = sorted(update.keys() - AdapterUpdate.__optional_keys__)
    if unexpected:
        raise ValueError(f"adapter returned forbidden state keys: {', '.join(unexpected)}")

    history = value.get("conversation_history")
    if history is not None:
        update["conversation_history"] = reduce_conversation_history((), history)

    memory = value.get("signer_memory")
    normalized_memory: SignerMemory = ()
    if memory is not None:
        normalized_memory = reduce_signer_memory((), memory)
        if any(entry.signer_id != state["signer_id"] for entry in normalized_memory):
            raise ValueError("adapter returned memory outside the current signer scope")
        update["signer_memory"] = normalized_memory

    deletion_ids = _validated_identifiers(
        value.get("signer_memory_deletions", ()),
        name="signer_memory_deletions",
    )
    if set(deletion_ids).intersection(entry.memory_id for entry in normalized_memory):
        raise ValueError("adapter cannot upsert and delete the same memory_id")

    request_ids = _validated_identifiers(
        value.get("processed_adaptation_request_ids", ()),
        name="processed_adaptation_request_ids",
    )
    allowed_request_ids = {request.request_id for request in state["adaptation_requests"]}
    if not set(request_ids).issubset(allowed_request_ids):
        raise ValueError("adapter reported an unknown adaptation request_id")

    current_by_id = {entry.memory_id: entry for entry in state["signer_memory"]}
    merged_memory = reduce_signer_memory(state["signer_memory"], normalized_memory)
    merged_by_id = {entry.memory_id: entry for entry in merged_memory}
    upserts_applied = sum(
        current_by_id.get(entry.memory_id) != merged_by_id[entry.memory_id]
        for entry in normalized_memory
    )
    deletion_set = set(deletion_ids)
    deletions_applied = len(deletion_set.intersection(merged_by_id))
    if deletion_ids:
        retained = tuple(entry for entry in merged_memory if entry.memory_id not in deletion_set)
        update["signer_memory"] = Overwrite(value=retained)

    update.pop("signer_memory_deletions", None)
    update.pop("processed_adaptation_request_ids", None)
    return _ValidatedAdapterUpdate(
        state_update=update,
        request_ids=request_ids,
        upserts_applied=upserts_applied,
        deletions_applied=deletions_applied,
    )


def _validated_identifiers(value: object, *, name: str) -> tuple[str, ...]:
    try:
        identifiers = _IDENTIFIERS_ADAPTER.validate_python(value, strict=True)
    except Exception as exc:
        raise ValueError(f"adapter returned invalid {name}") from exc
    if len(identifiers) != len(set(identifiers)):
        raise ValueError(f"adapter returned duplicate {name}")
    return identifiers


def _require_completed_run(state: AgentGraphState) -> None:
    if state.get("run_record") is None:
        raise RuntimeError("graph reached END without a run record")


def _require_finite_json(value: JsonValue, source: str) -> None:
    try:
        json.dumps(value, allow_nan=False, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{source} value must be finite JSON") from exc


__all__ = [
    "AdapterUpdate",
    "AgentGraph",
    "AgentGraphNodes",
    "AgentGraphState",
    "AgentRunRecord",
    "AgentTool",
    "AgentToolDefinition",
    "AllowedToolExecutor",
    "ConfidentResult",
    "CriticVerdict",
    "GraphNodeName",
    "GraphOutcome",
    "GraphPayload",
    "MAX_GRAPH_LOOP_CAP",
    "RepairAction",
    "RepairResult",
    "StateAwareAgentTool",
    "ThreadInvocationInProgressError",
    "ThreadScopeError",
    "ToolNotAllowedError",
    "ToolHandler",
    "ToolStateRequiredError",
    "build_agent_graph",
]
