"""Typed LangGraph-compatible state for stages ⑥-⑩.

The graph keeps the validated :class:`GlossLattice` and application-owned memory in
state.  Nodes should put only the small slice of data needed for a model call into a
prompt; landmarks, frames, and feature tensors have no representation here.

LangGraph recognises reducer callables stored in ``Annotated`` metadata.  Keeping the
reducers in this module makes the state usable and testable without making LangGraph a
runtime dependency of the contract layer.
"""

from __future__ import annotations

from collections.abc import Sequence
from enum import StrEnum
from typing import Annotated, Final, Literal, TypeAlias, TypedDict

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

from simplynext.contracts.common import Identifier
from simplynext.contracts.gloss_lattice import GlossLattice

DEFAULT_LOOP_CAP: Final[int] = 1
MAX_ADAPTATION_REQUESTS: Final[int] = 16
MAX_CONVERSATION_CONTENT_CHARACTERS: Final[int] = 4_000
MAX_CONVERSATION_HISTORY_MESSAGES: Final[int] = 64
MAX_MEMORY_KEY_CHARACTERS: Final[int] = 256
MAX_MEMORY_VALUE_CHARACTERS: Final[int] = 1_000

ConversationContent = Annotated[
    str,
    StringConstraints(min_length=1, max_length=MAX_CONVERSATION_CONTENT_CHARACTERS),
]
MemoryKey = Annotated[
    str,
    StringConstraints(min_length=1, max_length=MAX_MEMORY_KEY_CHARACTERS),
]
MemoryValue = Annotated[
    str,
    StringConstraints(min_length=1, max_length=MAX_MEMORY_VALUE_CHARACTERS),
]


class _StateValue(BaseModel):
    """Strict immutable value stored inside graph state."""

    model_config = ConfigDict(
        extra="forbid",
        frozen=True,
        str_strip_whitespace=True,
        validate_default=True,
    )


class ConversationRole(StrEnum):
    """Speaker or producer of one bounded conversation-history entry."""

    SYSTEM = "system"
    SIGNER = "signer"
    HEARING_PARTICIPANT = "hearing_participant"
    ASSISTANT = "assistant"
    TOOL = "tool"


class ConversationMessage(_StateValue):
    """A small text entry; the heavy recognition evidence remains in ``lattice``."""

    message_id: Identifier
    role: ConversationRole
    content: ConversationContent
    utterance_id: Identifier | None = None


class SignerMemoryKind(StrEnum):
    """The three episodic-memory categories promised by stage 10."""

    CORRECTION = "correction"
    PREFERRED_VARIANT = "preferred_variant"
    PERSONAL_SIGN = "personal_sign"


class SignerMemoryEntry(_StateValue):
    """One explicitly confirmed, versioned fact about a signer.

    ``key`` is the stable application lookup key and ``value`` is its confirmed value.
    Requiring the literal ``True`` prevents stage 10 from learning from an inference or
    an uncorrected recognition result.
    """

    memory_id: Identifier
    signer_id: Identifier
    kind: SignerMemoryKind
    key: MemoryKey
    value: MemoryValue
    confirmed_by_signer: Literal[True]
    confirmation_utterance_id: Identifier
    revision: int = Field(default=1, strict=True, ge=1)

    @field_validator("confirmed_by_signer", mode="before")
    @classmethod
    def confirmation_must_be_explicit_boolean_true(cls, value: object) -> Literal[True]:
        if value is not True:
            raise ValueError("confirmed_by_signer must be the boolean true")
        return True


class MemoryAdaptationOperation(StrEnum):
    """Explicit application-owned memory mutation requested by the signer."""

    UPSERT = "upsert"
    DELETE = "delete"


class ConfirmedMemoryUpsert(_StateValue):
    """One signer-confirmed memory value offered to the stage ⑩ adapter."""

    operation: Literal["upsert"] = "upsert"
    request_id: Identifier
    entry: SignerMemoryEntry


class ConfirmedMemoryDeletion(_StateValue):
    """One signer-confirmed request to remove an episodic-memory value."""

    operation: Literal["delete"] = "delete"
    request_id: Identifier
    signer_id: Identifier
    memory_id: Identifier
    confirmed_by_signer: Literal[True]
    confirmation_utterance_id: Identifier

    @field_validator("confirmed_by_signer", mode="before")
    @classmethod
    def confirmation_must_be_explicit_boolean_true(cls, value: object) -> Literal[True]:
        if value is not True:
            raise ValueError("confirmed_by_signer must be the boolean true")
        return True


MemoryAdaptationRequest: TypeAlias = ConfirmedMemoryUpsert | ConfirmedMemoryDeletion
AdaptationRequests = tuple[MemoryAdaptationRequest, ...]
ConversationHistory = tuple[ConversationMessage, ...]
SignerMemory = tuple[SignerMemoryEntry, ...]


def reduce_conversation_history(
    current: ConversationHistory | None,
    updates: ConversationMessage | Sequence[ConversationMessage] | None,
) -> ConversationHistory:
    """Append messages, replacing an existing message with the same stable ID.

    Replacement makes model/tool retries idempotent and follows the useful part of
    LangGraph's ``add_messages`` semantics without importing LangGraph.  Existing order
    is retained; genuinely new messages are appended in update order.  Only the newest
    ``MAX_CONVERSATION_HISTORY_MESSAGES`` entries survive, so a checkpoint cannot grow
    without bound or accidentally become an ever-growing model prompt.
    """

    messages = list(_conversation_messages(current))
    positions: dict[str, int] = {}
    for index, message in enumerate(messages):
        if message.message_id in positions:
            raise ValueError(f"duplicate conversation message_id: {message.message_id}")
        positions[message.message_id] = index

    for message in _conversation_messages(updates):
        position = positions.get(message.message_id)
        if position is None:
            positions[message.message_id] = len(messages)
            messages.append(message)
        else:
            messages[position] = message
    return tuple(messages[-MAX_CONVERSATION_HISTORY_MESSAGES:])


def reduce_signer_memory(
    current: SignerMemory | None,
    updates: SignerMemoryEntry | Sequence[SignerMemoryEntry] | None,
) -> SignerMemory:
    """Merge confirmed signer memory by signer and memory ID.

    The highest revision wins, stale retries are ignored, and two different values at
    the same revision fail loudly.  Sorting the result by identity makes this reducer
    deterministic regardless of branch-update order.
    """

    merged: dict[tuple[str, str], SignerMemoryEntry] = {}
    for entry in (*_memory_entries(current), *_memory_entries(updates)):
        identity = (entry.signer_id, entry.memory_id)
        previous = merged.get(identity)
        if previous is None or entry.revision > previous.revision:
            merged[identity] = entry
            continue
        if entry.revision < previous.revision or entry == previous:
            continue
        raise ValueError(
            "conflicting signer memory at revision "
            f"{entry.revision}: signer_id={entry.signer_id}, memory_id={entry.memory_id}"
        )

    return tuple(merged[identity] for identity in sorted(merged))


class AgentState(TypedDict):
    """Single source of truth shared by the stage 6-10 graph.

    ``conversation_history`` and ``signer_memory`` may receive concurrent partial
    updates and therefore declare reducers.  ``adaptation_requests`` is an ephemeral,
    application-authenticated input consumed by stage ⑩; it is never inferred by a
    model.  The lattice, signer scope, and loop cap are invocation-owned values and use
    ordinary replacement semantics.  ``loop_count`` is also replaced explicitly: each
    refine node computes the next absolute value, which avoids accidental double-counting
    during replay.
    """

    lattice: GlossLattice
    signer_id: Identifier
    adaptation_requests: AdaptationRequests
    conversation_history: Annotated[ConversationHistory, reduce_conversation_history]
    signer_memory: Annotated[SignerMemory, reduce_signer_memory]
    loop_count: int
    loop_cap: int


class AgentStateUpdate(TypedDict, total=False):
    """Partial update shape returned by graph nodes."""

    conversation_history: ConversationHistory
    signer_memory: SignerMemory
    loop_count: int


class LoopLimitReached(RuntimeError):
    """Raised before a refine step could exceed the state-owned hard cap."""


class _StateInitialization(_StateValue):
    signer_id: Identifier
    loop_cap: int = Field(strict=True, ge=0)


def create_agent_state(
    lattice: GlossLattice,
    *,
    signer_id: str,
    conversation_history: ConversationMessage | Sequence[ConversationMessage] | None = None,
    signer_memory: SignerMemoryEntry | Sequence[SignerMemoryEntry] | None = None,
    adaptation_requests: MemoryAdaptationRequest | Sequence[MemoryAdaptationRequest] | None = None,
    loop_cap: int = DEFAULT_LOOP_CAP,
) -> AgentState:
    """Create a valid graph invocation from trusted context and a wire lattice.

    ``signer_id`` is intentionally not read from the frontend lattice.  The caller must
    resolve it from authenticated server-side session context.  Memory or adaptation
    requests for another signer are rejected instead of leaking them into this
    invocation.  Adaptation requests must come from an application flow that obtained
    explicit signer confirmation.
    """

    if not isinstance(lattice, GlossLattice):
        raise TypeError("lattice must be a validated GlossLattice")
    context = _StateInitialization(signer_id=signer_id, loop_cap=loop_cap)
    history = reduce_conversation_history((), conversation_history)
    memory = reduce_signer_memory((), signer_memory)
    adaptations = _memory_adaptation_requests(adaptation_requests)
    foreign_signers = sorted(
        {entry.signer_id for entry in memory if entry.signer_id != context.signer_id}
    )
    adaptation_signers = {_adaptation_signer_id(request) for request in adaptations}
    foreign_signers.extend(
        sorted(signer for signer in adaptation_signers if signer != context.signer_id)
    )
    if foreign_signers:
        raise ValueError(
            "signer memory or adaptation contains entries outside the current signer scope"
        )

    return AgentState(
        lattice=lattice,
        signer_id=context.signer_id,
        adaptation_requests=adaptations,
        conversation_history=history,
        signer_memory=memory,
        loop_count=0,
        loop_cap=context.loop_cap,
    )


def loop_limit_reached(state: AgentState) -> bool:
    """Return whether the graph must route away from another refine iteration."""

    loop_count, loop_cap = _validated_loop_values(state)
    return loop_count >= loop_cap


def next_loop_update(state: AgentState) -> AgentStateUpdate:
    """Return the next absolute loop count, or stop before exceeding the cap."""

    loop_count, loop_cap = _validated_loop_values(state)
    if loop_count >= loop_cap:
        raise LoopLimitReached(f"refine loop cap reached ({loop_count}/{loop_cap})")
    return AgentStateUpdate(loop_count=loop_count + 1)


def _conversation_messages(
    value: ConversationMessage | Sequence[ConversationMessage] | None,
) -> tuple[ConversationMessage, ...]:
    if value is None:
        return ()
    if isinstance(value, ConversationMessage):
        return (value,)
    messages = tuple(value)
    if not all(isinstance(message, ConversationMessage) for message in messages):
        raise TypeError("conversation history must contain ConversationMessage values")
    return messages


def _memory_entries(
    value: SignerMemoryEntry | Sequence[SignerMemoryEntry] | None,
) -> tuple[SignerMemoryEntry, ...]:
    if value is None:
        return ()
    if isinstance(value, SignerMemoryEntry):
        return (value,)
    entries = tuple(value)
    if not all(isinstance(entry, SignerMemoryEntry) for entry in entries):
        raise TypeError("signer memory must contain SignerMemoryEntry values")
    return entries


def _memory_adaptation_requests(
    value: MemoryAdaptationRequest | Sequence[MemoryAdaptationRequest] | None,
) -> AdaptationRequests:
    if value is None:
        return ()
    requests: AdaptationRequests
    if isinstance(value, (ConfirmedMemoryUpsert, ConfirmedMemoryDeletion)):
        requests = (value,)
    else:
        requests = tuple(value)
    if not all(
        isinstance(request, (ConfirmedMemoryUpsert, ConfirmedMemoryDeletion))
        for request in requests
    ):
        raise TypeError("adaptation requests must be confirmed memory mutations")
    if len(requests) > MAX_ADAPTATION_REQUESTS:
        raise ValueError(f"adaptation requests cannot exceed {MAX_ADAPTATION_REQUESTS}")
    request_ids = [request.request_id for request in requests]
    if len(request_ids) != len(set(request_ids)):
        raise ValueError("adaptation request_id values must be unique")
    return requests


def _adaptation_signer_id(request: MemoryAdaptationRequest) -> str:
    if isinstance(request, ConfirmedMemoryUpsert):
        return request.entry.signer_id
    return request.signer_id


def _validated_loop_values(state: AgentState) -> tuple[int, int]:
    loop_count = state["loop_count"]
    loop_cap = state["loop_cap"]
    if type(loop_count) is not int or type(loop_cap) is not int:  # bool is not a valid counter
        raise TypeError("loop_count and loop_cap must be integers")
    if loop_count < 0 or loop_cap < 0:
        raise ValueError("loop_count and loop_cap must be non-negative")
    if loop_count > loop_cap:
        raise ValueError("loop_count cannot exceed loop_cap")
    return loop_count, loop_cap


__all__ = [
    "DEFAULT_LOOP_CAP",
    "MAX_ADAPTATION_REQUESTS",
    "MAX_CONVERSATION_HISTORY_MESSAGES",
    "AdaptationRequests",
    "AgentState",
    "AgentStateUpdate",
    "ConfirmedMemoryDeletion",
    "ConfirmedMemoryUpsert",
    "ConversationHistory",
    "ConversationMessage",
    "ConversationRole",
    "LoopLimitReached",
    "MemoryAdaptationOperation",
    "MemoryAdaptationRequest",
    "SignerMemory",
    "SignerMemoryEntry",
    "SignerMemoryKind",
    "create_agent_state",
    "loop_limit_reached",
    "next_loop_update",
    "reduce_conversation_history",
    "reduce_signer_memory",
]
