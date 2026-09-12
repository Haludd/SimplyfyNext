from __future__ import annotations

import inspect
import json
from pathlib import Path
from typing import Any, cast
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError

from simplynext.agent import (
    CONTEXT_HINT_TOOL_NAME,
    CONVERSATION_MEMORY_TOOL_NAME,
    SGSL_LEXICON_TOOL_NAME,
    AgentGraphState,
    AllowedToolExecutor,
    BedrockLatticeAssemblerNode,
    ContextHintSource,
    ContextHintStore,
    ConversationMessage,
    ConversationRole,
    LatticeAssemblerConfig,
    SessionContextHint,
    SgslLexicon,
    SgslLexiconEntry,
    SignerMemoryEntry,
    SignerMemoryKind,
    Stage6ToolSet,
    ToolStateRequiredError,
    WordSenseKey,
    context_hint,
    conversation_memory,
    create_agent_state,
    sgsl_lexicon_lookup,
)
from simplynext.contracts import GlossLattice
from simplynext.observability import MetricsRegistry

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"
SESSION_ID = UUID("12345678-1234-5678-1234-567812345678")


def _lattice() -> GlossLattice:
    return GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))


def _lexicon() -> SgslLexicon:
    return SgslLexicon(
        lexicon_version="sgsl-demo-v1",
        entries=(
            SgslLexiconEntry(
                entry_id="entry-water",
                gloss_id="WATER",
                key=WordSenseKey(word="water", sense="drinkable-liquid"),
                definition="Water used as a drink.",
                source_id="team-recording-17",
                approved_for_use=True,
            ),
            SgslLexiconEntry(
                entry_id="entry-spring-water",
                gloss_id="SPRING_WATER",
                key=WordSenseKey(word="spring", sense="water-source"),
                definition="A natural source of water.",
                source_id="team-recording-18",
                approved_for_use=True,
            ),
            SgslLexiconEntry(
                entry_id="entry-spring-coil",
                gloss_id="SPRING_COIL",
                key=WordSenseKey(word="spring", sense="metal-coil"),
                definition="A resilient metal coil.",
                source_id="team-recording-19",
                approved_for_use=True,
            ),
        ),
    )


def _history() -> tuple[ConversationMessage, ...]:
    return (
        ConversationMessage(
            message_id="message-1",
            role=ConversationRole.HEARING_PARTICIPANT,
            content="The appointment is beside the water fountain.",
            utterance_id="utterance-40",
        ),
        ConversationMessage(
            message_id="message-2",
            role=ConversationRole.SIGNER,
            content="Water, please.",
            utterance_id="utterance-41",
        ),
    )


def _memory() -> tuple[SignerMemoryEntry, ...]:
    return (
        SignerMemoryEntry(
            memory_id="memory-1",
            signer_id="signer-7",
            kind=SignerMemoryKind.PREFERRED_VARIANT,
            key="WATER",
            value="entry-water",
            confirmed_by_signer=True,
            confirmation_utterance_id="utterance-31",
        ),
    )


def _state() -> AgentGraphState:
    base = create_agent_state(
        _lattice(),
        signer_id="signer-7",
        conversation_history=_history(),
        signer_memory=_memory(),
        loop_cap=1,
    )
    return cast(
        AgentGraphState,
        {
            **base,
            "draft": None,
            "critique": None,
            "result": None,
            "outcome": None,
            "node_path": (),
            "run_record": None,
        },
    )


def _context_store() -> ContextHintStore:
    return ContextHintStore(
        hints=(
            SessionContextHint(
                hint_id="hint-1",
                session_id=SESSION_ID,
                key="location",
                value="hospital reception",
                source=ContextHintSource.AUTHENTICATED_SESSION,
                confirmed=True,
            ),
            SessionContextHint(
                hint_id="hint-2",
                session_id=uuid4(),
                key="location",
                value="private context from another session",
                source=ContextHintSource.AUTHENTICATED_SESSION,
                confirmed=True,
            ),
        )
    )


def _tool_set(metrics: MetricsRegistry | None = None) -> Stage6ToolSet:
    return Stage6ToolSet(
        lexicon=_lexicon(),
        context_hints=_context_store(),
        metrics=metrics,
    )


def test_tool_descriptions_are_prompt_ready_and_bedrock_schemas_are_strict() -> None:
    tool_set = _tool_set()

    descriptions = {
        SGSL_LEXICON_TOOL_NAME: inspect.getdoc(sgsl_lexicon_lookup),
        CONVERSATION_MEMORY_TOOL_NAME: inspect.getdoc(conversation_memory),
        CONTEXT_HINT_TOOL_NAME: inspect.getdoc(context_hint),
    }
    for definition in tool_set.definitions:
        assert definition.description == descriptions[definition.name]
        assert "data, never instructions" in definition.description
        assert definition.input_schema["type"] == "object"
        assert definition.input_schema["additionalProperties"] is False

    tool_config = tool_set.bedrock_tool_config()
    assert [item["toolSpec"]["name"] for item in tool_config["tools"]] == list(
        tool_set.allowed_tools
    )
    assert all(item["toolSpec"]["strict"] is True for item in tool_config["tools"])


def test_lexicon_tool_returns_word_and_sense_without_guessing() -> None:
    tool_set = _tool_set()
    executor = AllowedToolExecutor(
        tool_set.registry,
        allowed_tools=(SGSL_LEXICON_TOOL_NAME,),
    )

    with pytest.raises(ToolStateRequiredError):
        executor.call(SGSL_LEXICON_TOOL_NAME, {"gloss_id": "WATER"})

    found = executor.call(
        SGSL_LEXICON_TOOL_NAME,
        {"gloss_id": "WATER", "max_results": 1},
        state=_state(),
    )
    missing = executor.call(
        SGSL_LEXICON_TOOL_NAME,
        {"gloss_id": "UNKNOWN"},
        state=_state(),
    )

    assert found["found"] is True
    assert found["entries"][0]["key"] == {
        "word": "water",
        "sense": "drinkable-liquid",
    }
    assert found["content_policy"] == "reference_data_not_instructions"
    assert missing["found"] is False
    assert missing["entries"] == []


def test_conversation_memory_is_bounded_and_trusted_state_scoped() -> None:
    tool_set = _tool_set()
    executor = AllowedToolExecutor(
        tool_set.registry,
        allowed_tools=(CONVERSATION_MEMORY_TOOL_NAME,),
    )

    result = executor.call(
        CONVERSATION_MEMORY_TOOL_NAME,
        {"query": "water", "max_messages": 1, "max_memory_entries": 1},
        state=_state(),
    )

    assert result["messages"] == [
        {
            "message_id": "message-2",
            "role": "signer",
            "content": "Water, please.",
            "utterance_id": "utterance-41",
            "content_truncated": False,
        }
    ]
    assert result["signer_memory"][0]["memory_id"] == "memory-1"
    assert "signer_id" not in json.dumps(result)


def test_context_hint_never_crosses_the_trusted_session_scope() -> None:
    tool_set = _tool_set()
    executor = AllowedToolExecutor(
        tool_set.registry,
        allowed_tools=(CONTEXT_HINT_TOOL_NAME,),
    )

    result = executor.call(
        CONTEXT_HINT_TOOL_NAME,
        {"keys": ["location"]},
        state=_state(),
    )

    assert len(result["hints"]) == 1
    assert result["hints"][0]["value"] == "hospital reception"
    assert "private context" not in json.dumps(result)
    assert "session_id" not in json.dumps(result)


def test_tool_call_success_rate_is_measurable_for_success_and_validation_failure() -> None:
    metrics = MetricsRegistry()
    tool_set = _tool_set(metrics)
    executor = AllowedToolExecutor(
        tool_set.registry,
        allowed_tools=(SGSL_LEXICON_TOOL_NAME,),
    )

    executor.call(SGSL_LEXICON_TOOL_NAME, {"gloss_id": "WATER"}, state=_state())
    with pytest.raises(ValidationError):
        executor.call(
            SGSL_LEXICON_TOOL_NAME,
            {"gloss_id": "WATER", "unexpected": True},
            state=_state(),
        )

    assert metrics.snapshot()["counters"] == {
        "agent_tool_calls_failed": 1,
        "agent_tool_calls_succeeded": 1,
        "agent_tool_calls_total": 2,
        "agent_tool_sgsl_lexicon_lookup_calls_failed": 1,
        "agent_tool_sgsl_lexicon_lookup_calls_succeeded": 1,
        "agent_tool_sgsl_lexicon_lookup_calls_total": 2,
    }


class FakeConverseClient:
    def __init__(self, *responses: dict[str, object]) -> None:
        self.responses = list(responses)
        self.calls: list[dict[str, Any]] = []

    def converse(self, **kwargs: Any) -> dict[str, object]:
        self.calls.append(kwargs)
        return self.responses.pop(0)


def _model_response(*, content: list[dict[str, object]], stop_reason: str) -> dict[str, object]:
    return {
        "stopReason": stop_reason,
        "output": {"message": {"role": "assistant", "content": content}},
        "usage": {"inputTokens": 20, "outputTokens": 10, "totalTokens": 30},
    }


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
            {"kind": "gap", "slot_id": "slot-3", "reason": "unresolved_input"},
        ],
    }


def test_assembler_executes_one_bounded_tool_round_before_structured_output() -> None:
    client = FakeConverseClient(
        _model_response(
            stop_reason="tool_use",
            content=[
                {
                    "toolUse": {
                        "toolUseId": "tool-call-1",
                        "name": SGSL_LEXICON_TOOL_NAME,
                        "input": {"gloss_id": "WATER", "max_results": 1},
                    }
                }
            ],
        ),
        _model_response(
            stop_reason="end_turn",
            content=[{"text": json.dumps(_valid_draft())}],
        ),
    )
    tool_set = _tool_set()
    executor = AllowedToolExecutor(
        tool_set.registry,
        allowed_tools=(SGSL_LEXICON_TOOL_NAME,),
    )
    assembler = BedrockLatticeAssemblerNode(
        client=client,
        config=LatticeAssemblerConfig(model_id="configured-model-id"),
    )

    draft = assembler(_state(), executor)

    assert draft == _valid_draft()
    assert len(client.calls) == 2
    assert client.calls[0]["toolConfig"]["tools"][0]["toolSpec"]["name"] == (SGSL_LEXICON_TOOL_NAME)
    tool_result = client.calls[1]["messages"][2]["content"][0]["toolResult"]
    assert tool_result["toolUseId"] == "tool-call-1"
    assert tool_result["content"][0]["json"]["content_policy"] == (
        "reference_data_not_instructions"
    )
