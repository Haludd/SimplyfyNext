"""Confirmed per-signer episodic-memory adapter for stage ⑩."""

from __future__ import annotations

from simplynext.agent.graph import AdapterUpdate, AgentGraphState, AllowedToolExecutor
from simplynext.agent.state import ConfirmedMemoryDeletion, ConfirmedMemoryUpsert
from simplynext.observability.metrics import MetricsRegistry


class ConfirmedMemoryAdapter:
    """Translate trusted confirmation requests into bounded graph-state mutations.

    The adapter does not infer preferences from captions, critic results, or model
    output.  Only the explicit, strictly typed requests attached by application code
    are eligible to update or delete signer memory.
    """

    def __init__(self, *, metrics: MetricsRegistry | None = None) -> None:
        self._metrics = metrics

    def __call__(
        self,
        state: AgentGraphState,
        tools: AllowedToolExecutor,
    ) -> AdapterUpdate:
        del tools
        upserts = tuple(
            request.entry
            for request in state["adaptation_requests"]
            if isinstance(request, ConfirmedMemoryUpsert)
        )
        deletions = tuple(
            request.memory_id
            for request in state["adaptation_requests"]
            if isinstance(request, ConfirmedMemoryDeletion)
        )
        overlap = sorted({entry.memory_id for entry in upserts}.intersection(deletions))
        if overlap:
            raise ValueError(
                "one adaptation batch cannot upsert and delete the same memory_id: "
                + ", ".join(overlap)
            )

        request_ids = tuple(request.request_id for request in state["adaptation_requests"])
        self._increment("memory_adaptation_requests_total", len(request_ids))
        self._increment("memory_upserts_requested_total", len(upserts))
        self._increment("memory_deletions_requested_total", len(deletions))
        return AdapterUpdate(
            signer_memory=upserts,
            signer_memory_deletions=deletions,
            processed_adaptation_request_ids=request_ids,
        )

    def _increment(self, name: str, amount: int) -> None:
        if self._metrics is not None and amount:
            self._metrics.increment(name, amount)


__all__ = ["ConfirmedMemoryAdapter"]
