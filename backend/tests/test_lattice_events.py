"""Acceptance tests for the separately versioned lattice response protocol."""

from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID

import pytest
from pydantic import TypeAdapter, ValidationError

from simplynext.agent import RepairAction as GraphRepairAction
from simplynext.contracts import (
    LATTICE_EVENT_SCHEMA_VERSION,
    ActivityState,
    ErrorCode,
    GlossCandidate,
    GlossLattice,
    GlossProvenance,
    LatticeAckDisposition,
    LatticeAckEvent,
    LatticeActivityEvent,
    LatticeChoice,
    LatticeErrorEvent,
    LatticeEvidenceTrace,
    LatticeOutboundEvent,
    LatticePongEvent,
    LatticeRepairAction,
    LatticeRepairRequiredEvent,
    LatticeResultEvent,
)
from simplynext.sessions import PendingLatticeRepair

SESSION_ID = UUID("12345678-1234-5678-1234-567812345678")
OUTBOUND_ADAPTER = TypeAdapter(LatticeOutboundEvent)
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"


def resolved_evidence() -> LatticeEvidenceTrace:
    return LatticeEvidenceTrace(
        slot_index=0,
        slot_id="slot-0",
        start_ms=1_000,
        end_ms=1_300,
        resolved_gloss_id="WATER",
        confidence=0.96,
        provenance=GlossProvenance.CLASSIFIER_HIGH_CONFIDENCE,
        candidates=(GlossCandidate(gloss_id="WATER", rank=1, confidence=0.96),),
    )


def unresolved_evidence() -> LatticeEvidenceTrace:
    return LatticeEvidenceTrace(
        slot_index=0,
        slot_id="slot-0",
        start_ms=1_000,
        end_ms=1_300,
        resolved_gloss_id=None,
        confidence=None,
        provenance=GlossProvenance.UNRESOLVED,
        candidates=(
            GlossCandidate(gloss_id="WATER", rank=1, confidence=0.54),
            GlossCandidate(gloss_id="WHAT", rank=2, confidence=0.41),
        ),
    )


def result_event() -> LatticeResultEvent:
    return LatticeResultEvent(
        session_id=SESSION_ID,
        lattice_seq=7,
        utterance_id="utterance-42",
        evidence_trace=(resolved_evidence(),),
        classifier_version="1.3.0",
        agent_source="exact_template",
        latency_ms={"total": 2},
        caption="Water, please.",
        tts_text="Water, please.",
        confidence=0.96,
        gloss_id_trace=("WATER",),
    )


def repair_event() -> LatticeRepairRequiredEvent:
    return LatticeRepairRequiredEvent(
        session_id=SESSION_ID,
        lattice_seq=7,
        utterance_id="utterance-42",
        evidence_trace=(unresolved_evidence(),),
        classifier_version="1.3.0",
        agent_source="deterministic_repair",
        latency_ms={"total": 1},
        repair_id="repair-7",
        action=LatticeRepairAction.OFFER_TOP_K,
        message="Please choose the intended sign.",
        confidence=0.54,
        target_slot_ids=("slot-0",),
        choices=(
            LatticeChoice(slot_id="slot-0", rank=1, gloss_id="WATER", confidence=0.54),
            LatticeChoice(slot_id="slot-0", rank=2, gloss_id="WHAT", confidence=0.41),
        ),
        reason_codes=("unresolved_slot",),
    )


def test_lattice_outbound_union_contains_all_six_event_kinds() -> None:
    events = (
        LatticeAckEvent(
            session_id=SESSION_ID,
            lattice_seq=7,
            utterance_id="utterance-42",
            disposition=LatticeAckDisposition.ACCEPTED,
            server_ms=3_100,
        ),
        LatticeActivityEvent(
            session_id=SESSION_ID,
            state=ActivityState.PROCESSING,
            lattice_seq=7,
            utterance_id="utterance-42",
            server_ms=3_101,
        ),
        LatticePongEvent(session_id=SESSION_ID, control_seq=3, server_ms=3_102),
        LatticeErrorEvent(
            session_id=SESSION_ID,
            code=ErrorCode.INVALID_MESSAGE,
            message="Invalid lattice.",
            retryable=False,
        ),
        result_event(),
        repair_event(),
    )

    restored = tuple(OUTBOUND_ADAPTER.validate_json(event.model_dump_json()) for event in events)

    assert tuple(event.type for event in restored) == (
        "lattice_ack",
        "activity",
        "pong",
        "error",
        "lattice_result",
        "lattice_repair_required",
    )
    assert all(event.event_schema_version == LATTICE_EVENT_SCHEMA_VERSION for event in restored)

    schema = OUTBOUND_ADAPTER.json_schema()
    assert schema["discriminator"]["propertyName"] == "type"
    assert set(schema["discriminator"]["mapping"]) == {
        "activity",
        "error",
        "lattice_ack",
        "lattice_repair_required",
        "lattice_result",
        "pong",
    }


def test_confident_result_returns_json_text_and_structured_gloss_evidence() -> None:
    event = result_event()
    payload = event.model_dump(mode="json")

    assert payload["caption"] == "Water, please."
    assert payload["tts_text"] == "Water, please."
    assert isinstance(payload["caption"], str)
    assert isinstance(payload["tts_text"], str)
    assert payload["gloss_id_trace"] == ["WATER"]
    assert payload["evidence_trace"][0]["resolved_gloss_id"] == "WATER"
    assert "audio" not in payload

    without_tts = payload.copy()
    del without_tts["tts_text"]
    assert LatticeResultEvent.model_validate_json(json.dumps(without_tts)).tts_text is None


def test_repair_is_fail_closed_and_uses_graph_action_names() -> None:
    event = repair_event()
    payload = event.model_dump(mode="json")

    assert GraphRepairAction is LatticeRepairAction
    assert {action.value for action in LatticeRepairAction} == {
        "ask_repeat",
        "request_fingerspelling",
        "offer_top_k",
        "escalate_human_interpreter",
    }
    assert payload["type"] == "lattice_repair_required"
    assert "caption" not in payload
    assert "tts_text" not in payload
    assert "revision" not in payload
    assert "signer_id" not in payload


def test_outbound_version_and_cross_field_rules_are_frozen() -> None:
    invalid_version = result_event().model_dump(mode="json")
    invalid_version["event_schema_version"] = "2.0"
    with pytest.raises(ValidationError):
        OUTBOUND_ADAPTER.validate_python(invalid_version)

    mismatched_trace = result_event().model_dump()
    mismatched_trace["gloss_id_trace"] = ("WHAT",)
    with pytest.raises(ValidationError, match="exactly match"):
        LatticeResultEvent.model_validate(mismatched_trace)

    invalid_choice = repair_event().model_dump()
    invalid_choice["choices"] = (
        LatticeChoice(slot_id="slot-0", rank=1, gloss_id="OTHER", confidence=0.54),
    )
    with pytest.raises(ValidationError, match="retained candidates"):
        LatticeRepairRequiredEvent.model_validate(invalid_choice)


def test_repair_follow_up_is_correlated_in_trusted_server_state() -> None:
    pending = PendingLatticeRepair.from_event(repair_event())
    fixture = GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))
    follow_up = GlossLattice.model_validate({**fixture.model_dump(), "lattice_seq": 8})

    assert pending.accepts_follow_up(follow_up)
    assert not pending.accepts_follow_up(fixture)
    assert "revision" not in PendingLatticeRepair.model_fields
    assert "signer_id" not in PendingLatticeRepair.model_fields

    other_utterance = GlossLattice.model_validate(
        {**follow_up.model_dump(), "utterance_id": "another-utterance"}
    )
    assert not pending.accepts_follow_up(other_utterance)
