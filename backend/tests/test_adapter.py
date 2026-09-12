from __future__ import annotations

from pathlib import Path
from typing import cast

import pytest
from pydantic import ValidationError

from simplynext.agent.adapter import ConfirmedMemoryAdapter
from simplynext.agent.graph import (
    AgentGraphNodes,
    AgentGraphState,
    AllowedToolExecutor,
    ConfidentResult,
    CriticVerdict,
    GraphPayload,
    RepairResult,
    build_agent_graph,
)
from simplynext.agent.state import (
    ConfirmedMemoryDeletion,
    ConfirmedMemoryUpsert,
    SignerMemoryEntry,
    SignerMemoryKind,
    create_agent_state,
)
from simplynext.contracts import GlossLattice
from simplynext.observability import MetricsRegistry

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"


def lattice(*, lattice_seq: int, utterance_id: str) -> GlossLattice:
    fixture = GlossLattice.model_validate_json(FIXTURE_PATH.read_text(encoding="utf-8"))
    return GlossLattice.model_validate(
        {
            **fixture.model_dump(mode="python"),
            "lattice_seq": lattice_seq,
            "utterance_id": utterance_id,
        }
    )


def correction(*, revision: int = 1) -> SignerMemoryEntry:
    return SignerMemoryEntry(
        memory_id="water-correction",
        signer_id="signer-7",
        kind=SignerMemoryKind.CORRECTION,
        key="classifier-gloss:WATER",
        value="DRINK_WATER",
        confirmed_by_signer=True,
        confirmation_utterance_id="utterance-42",
        revision=revision,
    )


class MemoryAwareScenario:
    def __init__(self, adapter: ConfirmedMemoryAdapter) -> None:
        self.adapter = adapter

    def assembler(self, state: AgentGraphState, tools: AllowedToolExecutor) -> GraphPayload:
        del tools
        return {
            "memory_values": [entry.value for entry in state["signer_memory"]],
        }

    def critic(self, state: AgentGraphState, tools: AllowedToolExecutor) -> CriticVerdict:
        del state, tools
        return CriticVerdict(supported=True, reason="fixture")

    def confident(self, state: AgentGraphState, tools: AllowedToolExecutor) -> ConfidentResult:
        del tools
        return ConfidentResult(payload=cast(GraphPayload, state["draft"]))

    def repair(self, state: AgentGraphState, tools: AllowedToolExecutor) -> RepairResult:
        del state, tools
        raise AssertionError("fixture must not enter repair")

    def nodes(self) -> AgentGraphNodes:
        return AgentGraphNodes(
            assembler=self.assembler,
            critic=self.critic,
            confident=self.confident,
            repair=self.repair,
            adapter=self.adapter,
        )


def test_confirmed_correction_is_honored_for_the_rest_of_the_conversation() -> None:
    metrics = MetricsRegistry()
    graph = build_agent_graph(MemoryAwareScenario(ConfirmedMemoryAdapter(metrics=metrics)).nodes())
    entry = correction()
    upsert = ConfirmedMemoryUpsert(request_id="request-upsert-1", entry=entry)

    learned = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=7, utterance_id="utterance-42"),
            signer_id="signer-7",
            adaptation_requests=(upsert,),
        ),
        thread_id="conversation-memory-adaptation",
    )
    remembered = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=8, utterance_id="utterance-43"),
            signer_id="signer-7",
        ),
        thread_id="conversation-memory-adaptation",
    )

    assert learned["signer_memory"] == (entry,)
    assert learned["adaptation_requests"] == ()
    assert learned["run_record"] is not None
    assert learned["run_record"].adaptation_request_ids == ("request-upsert-1",)
    assert learned["run_record"].memory_upserts_applied == 1
    assert learned["run_record"].memory_deletions_applied == 0
    assert remembered["draft"] == {"memory_values": ["DRINK_WATER"]}
    assert metrics.snapshot()["counters"] == {
        "memory_adaptation_requests_total": 1,
        "memory_upserts_requested_total": 1,
    }


def test_confirmed_deletion_removes_memory_and_is_audited() -> None:
    graph = build_agent_graph(MemoryAwareScenario(ConfirmedMemoryAdapter()).nodes())
    entry = correction()
    graph.invoke(
        create_agent_state(
            lattice(lattice_seq=7, utterance_id="utterance-42"),
            signer_id="signer-7",
            adaptation_requests=(ConfirmedMemoryUpsert(request_id="request-upsert", entry=entry),),
        ),
        thread_id="conversation-memory-deletion",
    )
    deletion = ConfirmedMemoryDeletion(
        request_id="request-delete",
        signer_id="signer-7",
        memory_id=entry.memory_id,
        confirmed_by_signer=True,
        confirmation_utterance_id="utterance-43",
    )
    deleted = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=8, utterance_id="utterance-43"),
            signer_id="signer-7",
            adaptation_requests=(deletion,),
        ),
        thread_id="conversation-memory-deletion",
    )
    after_deletion = graph.invoke(
        create_agent_state(
            lattice(lattice_seq=9, utterance_id="utterance-44"),
            signer_id="signer-7",
        ),
        thread_id="conversation-memory-deletion",
    )

    assert deleted["signer_memory"] == ()
    assert deleted["run_record"] is not None
    assert deleted["run_record"].adaptation_request_ids == ("request-delete",)
    assert deleted["run_record"].memory_upserts_applied == 0
    assert deleted["run_record"].memory_deletions_applied == 1
    assert after_deletion["draft"] == {"memory_values": []}


def test_unconfirmed_or_cross_signer_adaptation_is_rejected_before_the_graph() -> None:
    with pytest.raises(ValidationError, match="boolean true"):
        ConfirmedMemoryDeletion.model_validate(
            {
                "request_id": "request-delete",
                "signer_id": "signer-7",
                "memory_id": "water-correction",
                "confirmed_by_signer": False,
                "confirmation_utterance_id": "utterance-43",
            }
        )

    foreign = ConfirmedMemoryUpsert(
        request_id="request-foreign",
        entry=SignerMemoryEntry(**{**correction().model_dump(), "signer_id": "signer-8"}),
    )
    with pytest.raises(ValueError, match="outside the current signer scope"):
        create_agent_state(
            lattice(lattice_seq=7, utterance_id="utterance-42"),
            signer_id="signer-7",
            adaptation_requests=(foreign,),
        )


def test_adapter_rejects_conflicting_upsert_and_deletion_in_one_batch() -> None:
    entry = correction()
    state = create_agent_state(
        lattice(lattice_seq=7, utterance_id="utterance-42"),
        signer_id="signer-7",
        adaptation_requests=(
            ConfirmedMemoryUpsert(request_id="request-upsert", entry=entry),
            ConfirmedMemoryDeletion(
                request_id="request-delete",
                signer_id="signer-7",
                memory_id=entry.memory_id,
                confirmed_by_signer=True,
                confirmation_utterance_id="utterance-42",
            ),
        ),
    )
    graph_state = AgentGraphState(
        **state,
        draft={},
        critique=CriticVerdict(supported=True, reason="fixture"),
        result=ConfidentResult(payload={}),
        outcome="confident",
        node_path=(),
        run_record=None,
    )

    with pytest.raises(ValueError, match="cannot upsert and delete"):
        ConfirmedMemoryAdapter()(graph_state, AllowedToolExecutor())
