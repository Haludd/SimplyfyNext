"""Typed, measured, default-deny tools for the stage ⑥ assembler."""

from __future__ import annotations

import inspect
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Final, TypeVar, cast

from pydantic import BaseModel, JsonValue

from simplynext.agent.graph import (
    AgentToolDefinition,
    GraphPayload,
    ToolArguments,
    ToolHandler,
)
from simplynext.agent.state import AgentState
from simplynext.contracts import SignLanguage
from simplynext.observability import MetricsRegistry

from .context import (
    ContextHintRequest,
    ContextHintResult,
    ContextHintSource,
    ContextHintStore,
    ContextHintSummary,
    SessionContextHint,
    context_hint,
)
from .lexicon import (
    SgslLexicon,
    SgslLexiconEntry,
    SgslLexiconLookupRequest,
    SgslLexiconLookupResult,
    WordSenseKey,
    sgsl_lexicon_lookup,
)
from .memory import (
    ConversationMemoryRequest,
    ConversationMemoryResult,
    ConversationMessageSummary,
    SignerMemorySummary,
    conversation_memory,
)

SGSL_LEXICON_TOOL_NAME: Final = "sgsl_lexicon_lookup"
CONVERSATION_MEMORY_TOOL_NAME: Final = "conversation_memory"
CONTEXT_HINT_TOOL_NAME: Final = "context_hint"
STAGE6_TOOL_NAMES: Final = (
    SGSL_LEXICON_TOOL_NAME,
    CONVERSATION_MEMORY_TOOL_NAME,
    CONTEXT_HINT_TOOL_NAME,
)

_RequestModel = TypeVar("_RequestModel", bound=BaseModel)


class Stage6ToolSet:
    """Immutable registry, definitions, and counters for the three assembler tools."""

    __slots__ = ("_metrics", "_registry")

    def __init__(
        self,
        *,
        lexicon: SgslLexicon,
        context_hints: ContextHintStore | None = None,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._metrics = metrics if metrics is not None else MetricsRegistry()
        store = context_hints if context_hints is not None else ContextHintStore()
        handlers: dict[str, ToolHandler] = {
            SGSL_LEXICON_TOOL_NAME: _LexiconTool(
                lexicon=lexicon,
                metrics=self._metrics,
                definition=_definition(
                    SGSL_LEXICON_TOOL_NAME,
                    sgsl_lexicon_lookup,
                    SgslLexiconLookupRequest,
                ),
            ),
            CONVERSATION_MEMORY_TOOL_NAME: _ConversationMemoryTool(
                metrics=self._metrics,
                definition=_definition(
                    CONVERSATION_MEMORY_TOOL_NAME,
                    conversation_memory,
                    ConversationMemoryRequest,
                ),
            ),
            CONTEXT_HINT_TOOL_NAME: _ContextHintTool(
                store=store,
                metrics=self._metrics,
                definition=_definition(
                    CONTEXT_HINT_TOOL_NAME,
                    context_hint,
                    ContextHintRequest,
                ),
            ),
        }
        self._registry: Mapping[str, ToolHandler] = MappingProxyType(handlers)

    @property
    def registry(self) -> Mapping[str, ToolHandler]:
        """Return all handlers; the graph must still allow-list each exposed name."""

        return self._registry

    @property
    def allowed_tools(self) -> tuple[str, ...]:
        """Return the complete stage ⑥ tool-name tuple for explicit graph configuration."""

        return STAGE6_TOOL_NAMES

    @property
    def definitions(self) -> tuple[AgentToolDefinition, ...]:
        """Return prompt-facing definitions in stable name order."""

        definitions: list[AgentToolDefinition] = []
        for name in STAGE6_TOOL_NAMES:
            definition = getattr(self._registry[name], "definition", None)
            if not isinstance(definition, AgentToolDefinition):
                raise TypeError(f"stage 6 tool has no valid definition: {name}")
            definitions.append(definition)
        return tuple(definitions)

    @property
    def metrics(self) -> MetricsRegistry:
        """Expose counters used to compute aggregate and per-tool success rates."""

        return self._metrics

    def bedrock_tool_config(self) -> dict[str, JsonValue]:
        """Render the definitions in the Amazon Bedrock Converse ``toolConfig`` shape."""

        tools: list[JsonValue] = []
        for definition in self.definitions:
            tools.append(
                {
                    "toolSpec": {
                        "name": definition.name,
                        "description": definition.description,
                        "inputSchema": {"json": definition.input_schema},
                        "strict": True,
                    }
                }
            )
        return {"tools": tools}


@dataclass(frozen=True, slots=True)
class _LexiconTool:
    lexicon: SgslLexicon
    metrics: MetricsRegistry
    definition: AgentToolDefinition

    def invoke(self, arguments: ToolArguments, state: AgentState) -> JsonValue:
        def operation() -> JsonValue:
            if state["lattice"].language is not SignLanguage.SGSL:
                raise ValueError("sgsl_lexicon_lookup is available only for an SgSL lattice")
            request = _request(SgslLexiconLookupRequest, arguments)
            result = sgsl_lexicon_lookup(request, lexicon=self.lexicon)
            return cast(JsonValue, result.model_dump(mode="json"))

        return _measure(self.metrics, self.definition.name, operation)


@dataclass(frozen=True, slots=True)
class _ConversationMemoryTool:
    metrics: MetricsRegistry
    definition: AgentToolDefinition

    def invoke(self, arguments: ToolArguments, state: AgentState) -> JsonValue:
        def operation() -> JsonValue:
            request = _request(ConversationMemoryRequest, arguments)
            result = conversation_memory(
                request,
                conversation_history=state["conversation_history"],
                signer_memory=state["signer_memory"],
                signer_id=state["signer_id"],
            )
            return cast(JsonValue, result.model_dump(mode="json"))

        return _measure(self.metrics, self.definition.name, operation)


@dataclass(frozen=True, slots=True)
class _ContextHintTool:
    store: ContextHintStore
    metrics: MetricsRegistry
    definition: AgentToolDefinition

    def invoke(self, arguments: ToolArguments, state: AgentState) -> JsonValue:
        def operation() -> JsonValue:
            request = _request(ContextHintRequest, arguments)
            session_hints = self.store.for_session(state["lattice"].session_id)
            result = context_hint(request, hints=session_hints)
            return cast(JsonValue, result.model_dump(mode="json"))

        return _measure(self.metrics, self.definition.name, operation)


def _definition(
    name: str,
    function: Callable[..., object],
    request_model: type[BaseModel],
) -> AgentToolDefinition:
    description = inspect.getdoc(function)
    if description is None:
        raise ValueError(f"tool function has no model-facing docstring: {name}")
    schema = cast(GraphPayload, request_model.model_json_schema(mode="validation"))
    return AgentToolDefinition(name=name, description=description, input_schema=schema)


def _request(model: type[_RequestModel], arguments: ToolArguments) -> _RequestModel:
    payload = json.dumps(arguments, allow_nan=False, ensure_ascii=True, separators=(",", ":"))
    return model.model_validate_json(payload)


def _measure(
    metrics: MetricsRegistry,
    tool_name: str,
    operation: Callable[[], JsonValue],
) -> JsonValue:
    metrics.increment("agent_tool_calls_total")
    metrics.increment(f"agent_tool_{tool_name}_calls_total")
    try:
        result = operation()
    except Exception:
        metrics.increment("agent_tool_calls_failed")
        metrics.increment(f"agent_tool_{tool_name}_calls_failed")
        raise
    metrics.increment("agent_tool_calls_succeeded")
    metrics.increment(f"agent_tool_{tool_name}_calls_succeeded")
    return result


__all__ = [
    "CONTEXT_HINT_TOOL_NAME",
    "CONVERSATION_MEMORY_TOOL_NAME",
    "SGSL_LEXICON_TOOL_NAME",
    "STAGE6_TOOL_NAMES",
    "ContextHintRequest",
    "ContextHintResult",
    "ContextHintSource",
    "ContextHintStore",
    "ContextHintSummary",
    "ConversationMemoryRequest",
    "ConversationMemoryResult",
    "ConversationMessageSummary",
    "SessionContextHint",
    "SgslLexicon",
    "SgslLexiconEntry",
    "SgslLexiconLookupRequest",
    "SgslLexiconLookupResult",
    "SignerMemorySummary",
    "Stage6ToolSet",
    "WordSenseKey",
    "context_hint",
    "conversation_memory",
    "sgsl_lexicon_lookup",
]
