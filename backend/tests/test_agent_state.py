from __future__ import annotations

from typing import get_args, get_type_hints
from uuid import UUID

import pytest
from pydantic import ValidationError

from simplynext.agent.state import (
    MAX_CONVERSATION_HISTORY_MESSAGES,
    AgentState,
    ConversationMessage,
    ConversationRole,
    LoopLimitReached,
    SignerMemoryEntry,
    SignerMemoryKind,
    create_agent_state,
    loop_limit_reached,
    next_loop_update,
    reduce_conversation_history,
    reduce_signer_memory,
)
from simplynext.contracts import (
    GLOSS_LATTICE_SCHEMA_VERSION,
    GlossCandidate,
    GlossLattice,
    GlossLatticeProducer,
    GlossProvenance,
    GlossSlot,
)


def lattice() -> GlossLattice:
    return GlossLattice(
        type="gloss_lattice",
        schema_version=GLOSS_LATTICE_SCHEMA_VERSION,
        session_id=UUID("12345678-1234-5678-1234-567812345678"),
        lattice_seq=4,
        utterance_id="utterance-4",
        language="sgsl",
        timebase="session_monotonic_ms",
        started_at_ms=100,
        ended_at_ms=500,
        producer=GlossLatticeProducer(
            classifier_id="temporal-classifier",
            classifier_version="1.0.0",
            confidence_kind="calibrated_probability",
            calibration_version="temperature-v1",
            vocabulary_version="sgsl-demo-v1",
        ),
        slots=(
            GlossSlot(
                slot_index=0,
                slot_id="slot-0",
                start_ms=150,
                end_ms=450,
                candidates=(GlossCandidate(gloss_id="WATER", rank=1, confidence=0.96),),
                resolved_gloss_id="WATER",
                provenance=GlossProvenance.CLASSIFIER_HIGH_CONFIDENCE,
            ),
        ),
    )


def memory(*, revision: int = 1, value: str = "WATER") -> SignerMemoryEntry:
    return SignerMemoryEntry(
        memory_id="water-variant",
        signer_id="signer-7",
        kind=SignerMemoryKind.PREFERRED_VARIANT,
        key="classifier-gloss:WATER",
        value=value,
        confirmed_by_signer=True,
        confirmation_utterance_id="utterance-4",
        revision=revision,
    )


def test_state_initialization_keeps_validated_lattice_and_server_signer_scope() -> None:
    gloss_lattice = lattice()
    message = ConversationMessage(
        message_id="message-1",
        role=ConversationRole.SIGNER,
        content="WATER",
        utterance_id=gloss_lattice.utterance_id,
    )
    entry = memory()

    state = create_agent_state(
        gloss_lattice,
        signer_id=" signer-7 ",
        conversation_history=(message,),
        signer_memory=(entry,),
        loop_cap=2,
    )

    assert state["lattice"] is gloss_lattice
    assert state["signer_id"] == "signer-7"
    assert state["conversation_history"] == (message,)
    assert state["signer_memory"] == (entry,)
    assert state["loop_count"] == 0
    assert state["loop_cap"] == 2


def test_typed_state_exposes_langgraph_compatible_reducers_without_dependency() -> None:
    hints = get_type_hints(AgentState, include_extras=True)

    assert reduce_conversation_history in get_args(hints["conversation_history"])[1:]
    assert reduce_signer_memory in get_args(hints["signer_memory"])[1:]
    assert get_args(hints["lattice"]) == ()
    assert get_args(hints["loop_count"]) == ()


def test_conversation_reducer_is_append_only_except_for_idempotent_id_replacement() -> None:
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
    corrected_first = ConversationMessage(
        message_id="message-1",
        role=ConversationRole.SIGNER,
        content="WATER PLEASE",
    )

    reduced = reduce_conversation_history((first,), (second, corrected_first))

    assert reduced == (corrected_first, second)
    with pytest.raises(ValueError, match="duplicate conversation message_id"):
        reduce_conversation_history((first, first), ())


def test_conversation_history_is_bounded_to_the_newest_messages() -> None:
    messages = tuple(
        ConversationMessage(
            message_id=f"message-{index}",
            role=ConversationRole.ASSISTANT,
            content=f"caption {index}",
        )
        for index in range(MAX_CONVERSATION_HISTORY_MESSAGES + 1)
    )

    reduced = reduce_conversation_history((), messages)

    assert len(reduced) == MAX_CONVERSATION_HISTORY_MESSAGES
    assert reduced[0].message_id == "message-1"
    assert reduced[-1].message_id == f"message-{MAX_CONVERSATION_HISTORY_MESSAGES}"


def test_signer_memory_requires_confirmation_and_merges_by_highest_revision() -> None:
    original = memory(revision=1, value="WATER")
    corrected = memory(revision=2, value="DRINK_WATER")

    assert reduce_signer_memory((original,), (original,)) == (original,)
    assert reduce_signer_memory((original,), (corrected,)) == (corrected,)
    assert reduce_signer_memory((corrected,), (original,)) == (corrected,)

    with pytest.raises(ValidationError):
        SignerMemoryEntry.model_validate(
            {
                **original.model_dump(),
                "confirmed_by_signer": False,
            }
        )
    with pytest.raises(ValidationError):
        SignerMemoryEntry.model_validate(
            {
                **original.model_dump(),
                "confirmed_by_signer": 1,
            }
        )
    with pytest.raises(ValueError, match="conflicting signer memory"):
        reduce_signer_memory((original,), (memory(value="OTHER"),))


def test_state_rejects_memory_from_another_signer() -> None:
    foreign = SignerMemoryEntry(
        **{
            **memory().model_dump(),
            "signer_id": "signer-8",
        }
    )

    with pytest.raises(ValueError, match="outside the current signer scope"):
        create_agent_state(lattice(), signer_id="signer-7", signer_memory=(foreign,))


def test_loop_helpers_stop_before_the_state_owned_cap() -> None:
    state = create_agent_state(lattice(), signer_id="signer-7", loop_cap=1)

    assert loop_limit_reached(state) is False
    state.update(next_loop_update(state))
    assert state["loop_count"] == 1
    assert loop_limit_reached(state) is True
    with pytest.raises(LoopLimitReached, match="1/1"):
        next_loop_update(state)

    invalid_state = {**state, "loop_count": 2}
    with pytest.raises(ValueError, match="cannot exceed"):
        loop_limit_reached(invalid_state)  # type: ignore[arg-type]


def test_state_factory_requires_the_wire_model_and_non_negative_cap() -> None:
    with pytest.raises(TypeError, match="validated GlossLattice"):
        create_agent_state({}, signer_id="signer-7")  # type: ignore[arg-type]
    with pytest.raises(ValidationError):
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=-1)
    with pytest.raises(ValidationError):
        create_agent_state(lattice(), signer_id="signer-7", loop_cap=True)
