from __future__ import annotations

import asyncio
import json
from pathlib import Path
from uuid import uuid4

import pytest

from simplynext.agent.words.repair import repair
from simplynext.contracts.room_events import AcceptedOutcome, RoomEnded, RoomError
from simplynext.contracts.room_inputs import CreateRoom, JoinRoom, TextMessage
from simplynext.contracts.translated_sign_utterance import TranslatedSignUtteranceV1, parse_value
from simplynext.observability import MetricsRegistry
from simplynext.rooms.service import RoomService
from simplynext.rooms.store import RoomFailure, RoomLimits, RoomStore

FIXTURE = Path(__file__).parent / "fixtures/translated_sign_utterance_v1.json"


def utterance(sequence=0, **updates):
    payload = json.loads(FIXTURE.read_text())
    payload.update(message_id=str(uuid4()), client_sequence=sequence, **updates)
    return parse_value(TranslatedSignUtteranceV1, json.dumps(payload))


def text_message(sequence=0, text="A hearing turn."):
    return TextMessage(
        schema_version="1.0", message_id=uuid4(), client_sequence=sequence, text=text, source="text"
    )


async def pair(store):
    signer = await store.create(
        CreateRoom(schema_version="1.0", event_schema_version="1.0", alias="Signer"), address="a"
    )
    hearing = await store.join(
        JoinRoom(
            schema_version="1.0", event_schema_version="1.0", alias="Hearing", code=signer.code
        ),
        address="b",
    )
    room = store.get(signer.code)
    return room, signer, hearing


class DeferredTranslator:
    def __init__(self, *, ignore_cancel=False):
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.calls = 0
        self.contexts = []
        self.ignore_cancel = ignore_cancel

    async def process(self, utterance, context):
        self.calls += 1
        self.contexts.append(context)
        self.started.set()
        try:
            await self.release.wait()
        except asyncio.CancelledError:
            if not self.ignore_cancel:
                raise
        return AcceptedOutcome(
            text="Table.", confidence=0.6, model_version="fake", policy_version="test"
        )


def service(store, translator, **kwargs):
    return RoomService(
        store, translator, slots=asyncio.Semaphore(2), metrics=MetricsRegistry(), **kwargs
    )


async def test_auth_capabilities_and_two_person_capacity():
    store = RoomStore()
    room, signer, hearing = await pair(store)
    other_room, other_signer, _ = await pair(store)
    assert len(signer.code) == 8 and signer.token not in signer.join_path
    assert all(p.token_digest != signer.token for p in room.participants.values())
    for token in ("", "x" * 43, other_signer.token):
        with pytest.raises(RoomFailure) as caught:
            store.authenticate(room, token)
        assert caught.value.status == 401
    assert store.authenticate(room, hearing.token).role == "hearing"
    with pytest.raises(RoomFailure) as caught:
        await store.join(
            JoinRoom(
                schema_version="1.0", event_schema_version="1.0", alias="Third", code=room.code
            ),
            address="c",
        )
    assert caught.value.code == "room_full"
    store.erase(room)
    assert store.authenticate(other_room, other_signer.token)


async def test_admission_is_atomic_replay_safe_and_does_not_hold_lock_during_work():
    store = RoomStore()
    translator = DeferredTranslator()
    runtime = service(store, translator)
    room, signer, hearing = await pair(store)
    request = utterance()
    admissions = await asyncio.gather(
        *[runtime.submit(room.code, signer.token, request) for _ in range(8)]
    )
    assert sum(a.ack.disposition == "accepted" for a in admissions) == 1
    assert {a.ack.server_sequence for a in admissions} == {1}
    await translator.started.wait()
    assert translator.calls == 1 and not room.lock.locked()
    await runtime.submit(room.code, hearing.token, text_message())
    assert translator.contexts[0].recent_turns == ()  # immutable admission snapshot
    assert store.context(room).recent_turns[0].text == "A hearing turn."
    with pytest.raises(RoomFailure) as caught:
        await runtime.submit(room.code, signer.token, utterance(1))
    assert caught.value.status == 429
    translator.release.set()
    await asyncio.gather(*room.tasks)
    cached = await runtime.submit(room.code, signer.token, request)
    assert cached.message.status == "accepted" and cached.ack.disposition == "cached"
    assert translator.calls == 1 and room.pending is None
    assert len(room.messages) == 2 and room.context_version == 2
    assert not store.commit(
        room,
        room.participants[signer.participant_id],
        request.message_id,
        repair("provider_failure"),
    )


async def test_sequence_conflicts_and_repair_continuation():
    store = RoomStore()
    room, signer, hearing = await pair(store)
    p = store.authenticate(room, signer.token)
    req = utterance()
    admission = store.admit(room, p, req)
    for changed in (req.model_copy(update={"client_sequence": 1}), utterance(0), utterance(2)):
        with pytest.raises(RoomFailure) as caught:
            store.admit(room, p, changed)
        assert caught.value.code == "sequence_conflict"
    changed_payload = req.model_dump(mode="json")
    changed_payload["words"][0]["confidence"] = 0.7
    with pytest.raises(RoomFailure):
        store.admit(room, p, parse_value(TranslatedSignUtteranceV1, json.dumps(changed_payload)))
    store.commit(room, p, req.message_id, repair("low_score", (0,)))
    assert p.pending_repair == req.message_id
    assert store.admit(room, p, req).message.status == "repair"
    new = store.admit(room, p, utterance(1))
    assert new.ack.server_sequence == admission.ack.server_sequence + 1
    assert p.pending_repair is None
    h = store.authenticate(room, hearing.token)
    with pytest.raises(RoomFailure) as caught:
        store.admit(room, h, utterance())
    assert caught.value.status == 401


@pytest.mark.parametrize("mode", ["before_dispatch", "during_provider", "late_provider", "retry"])
async def test_end_races_erase_every_record_and_discard_late_work(mode):
    store = RoomStore()
    translator = DeferredTranslator(ignore_cancel=mode == "late_provider")
    runtime = service(store, translator)
    room, signer, hearing = await pair(store)
    p = store.authenticate(room, signer.token)
    q = store.subscribe(room, p)
    req = utterance()
    await runtime.submit(room.code, signer.token, req)
    tasks = tuple(room.tasks)
    if mode != "before_dispatch":
        await translator.started.wait()
    if mode == "retry":
        await runtime.submit(room.code, signer.token, req)
    async with room.lock:
        store.authenticate(room, hearing.token)  # either participant may terminate
        store.erase(room)
        store.erase(room)
    translator.release.set()
    await asyncio.gather(*tasks, return_exceptions=True)
    assert room.state == "ended" and room.code not in store.rooms
    assert not room.participants and not room.messages and not room.requests and not room.sequences
    assert not room.tasks and room.pending is None and room.summary == ""
    assert p.token_digest == "" and p.alias == "" and p.producer is None
    assert p.pending_repair is None and not p.request_times and not p.subscribers
    assert isinstance(q.get_nowait(), RoomEnded) and q.empty()
    with pytest.raises(RoomFailure) as caught:
        await runtime.submit(room.code, signer.token, req)
    assert caught.value.status == 410


@pytest.mark.parametrize("expiry", ["invitation", "idle", "absolute"])
async def test_expiry_uses_complete_erasure(expiry):
    now = [0.0]
    store = RoomStore(
        RoomLimits(invite_seconds=10, idle_seconds=20, absolute_seconds=40), clock=lambda: now[0]
    )
    if expiry == "invitation":
        c = await store.create(
            CreateRoom(schema_version="1.0", event_schema_version="1.0", alias="S"), address="a"
        )
        room = store.get(c.code)
        now[0] = 10
    else:
        room, _, _ = await pair(store)
        now[0] = 20 if expiry == "idle" else 40
        if expiry == "absolute":
            room.last_activity = 39
    await store.purge_expired()
    assert room.state == "ended" and not store.rooms
    assert not room.participants


async def test_event_overflow_requires_recovery_and_terminal_remains_cached():
    store = RoomStore(RoomLimits(subscriber_queue_size=2))
    room, signer, hearing = await pair(store)
    p = store.authenticate(room, signer.token)
    h = store.authenticate(room, hearing.token)
    queue = store.subscribe(room, p)
    assert queue.get_nowait().type == "snapshot"
    for i in range(3):
        store.admit(room, h, text_message(i))
    assert isinstance(queue.get_nowait(), RoomError)
    assert queue not in p.subscribers
    assert len(store.snapshot(room).messages) == 3
    recovered = store.subscribe(room, p).get_nowait()
    assert recovered.type == "snapshot" and len(recovered.messages) == 3


async def test_message_capacity_and_rate_do_not_block_cached_retries():
    store = RoomStore(RoomLimits(max_messages=1, messages_per_minute=1))
    room, signer, _ = await pair(store)
    p = store.authenticate(room, signer.token)
    req = text_message()
    store.admit(room, p, req)
    assert store.admit(room, p, req).ack.disposition == "cached"
    with pytest.raises(RoomFailure) as caught:
        store.admit(room, p, text_message(1))
    assert caught.value.status == 429 and p.next_sequence == 1


async def test_latest_ten_context_excludes_repairs_processing_and_other_rooms():
    store = RoomStore()
    room, signer, hearing = await pair(store)
    p = store.authenticate(room, signer.token)
    h = store.authenticate(room, hearing.token)
    for i in range(12):
        store.admit(room, h, text_message(i, f"Turn {i}"))
    req = utterance()
    store.admit(room, p, req)
    store.commit(room, p, req.message_id, repair("low_score"))
    context = store.context(room)
    assert len(context.recent_turns) == 10
    assert context.recent_turns[0].text == "Turn 2"
    assert context.context_version == 12
    other, _, _ = await pair(store)
    assert store.context(other).recent_turns == ()


async def test_timeout_queue_rejection_and_unexpected_failure_are_terminal_repairs():
    for behavior in ("timeout", "capacity", "failure"):
        store = RoomStore()
        translator = DeferredTranslator()
        runtime = service(store, translator, timeout_seconds=0.01, queue_timeout_seconds=0.01)
        room, signer, _ = await pair(store)
        if behavior == "capacity":
            runtime.slots = asyncio.Semaphore(0)
        elif behavior == "failure":

            async def fail(*args):
                raise RuntimeError("secret provider details")

            translator.process = fail
        await runtime.submit(room.code, signer.token, utterance())
        await asyncio.gather(*room.tasks)
        result = next(iter(room.messages.values()))
        assert result.status == "repair"
        assert result.repair.reason_code == {"failure": "provider_failure"}.get(behavior, behavior)
        assert "secret" not in result.model_dump_json()
        assert room.pending is None


async def test_invitation_rate_room_capacity_and_subscriber_limits():
    now = [0.0]
    store = RoomStore(RoomLimits(max_rooms=1, invitations_per_minute=2), clock=lambda: now[0])
    room, signer, _ = await pair(store)
    with pytest.raises(RoomFailure) as caught:
        await store.create(
            CreateRoom(schema_version="1.0", event_schema_version="1.0", alias="S"),
            address="new-address",
        )
    assert caught.value.status == 429
    store.invitation_rate("repeated")
    store.invitation_rate("repeated")
    with pytest.raises(RoomFailure) as caught:
        store.invitation_rate("repeated")
    assert caught.value.status == 429
    now[0] = 60
    store.invitation_rate("repeated")
    p = store.authenticate(room, signer.token)
    store.subscribe(room, p)
    store.subscribe(room, p)
    with pytest.raises(RoomFailure) as caught:
        store.subscribe(room, p)
    assert caught.value.status == 429


async def test_expiry_during_work_and_commit_clears_pending_without_resurrection():
    now = [0.0]
    store = RoomStore(RoomLimits(idle_seconds=1), clock=lambda: now[0])
    translator = DeferredTranslator(ignore_cancel=True)
    runtime = service(store, translator)
    room, signer, _ = await pair(store)
    await runtime.submit(room.code, signer.token, utterance())
    await translator.started.wait()
    tasks = tuple(room.tasks)
    now[0] = 1
    translator.release.set()
    await asyncio.gather(*tasks, return_exceptions=True)
    assert room.state == "ended" and not room.messages and not room.requests and not store.rooms


async def test_admission_and_end_contend_for_the_same_lock():
    store = RoomStore()
    translator = DeferredTranslator()
    runtime = service(store, translator)
    room, signer, _ = await pair(store)
    await room.lock.acquire()
    submit = asyncio.create_task(runtime.submit(room.code, signer.token, utterance()))
    await asyncio.sleep(0)
    store.erase(room)
    room.lock.release()
    with pytest.raises(RoomFailure) as caught:
        await submit
    assert caught.value.status == 410
    assert translator.calls == 0 and room.messages == {}


async def test_unicode_context_stays_bounded_without_rejecting_valid_admission():
    store = RoomStore()
    room, signer, hearing = await pair(store)
    h = store.authenticate(room, hearing.token)
    for i in range(10):
        store.admit(room, h, text_message(i, "\U0001f600" * 2000))
    p = store.authenticate(room, signer.token)
    admission = store.admit(room, p, utterance())
    assert len(admission.context.recent_turns) == 10
    assert len(admission.context.model_dump_json().encode()) < 96_000


@pytest.mark.parametrize(
    "blocked_stage",
    [1, 2, 3, 4],
    ids=[
        "assembler",
        "critic",
        "revision",
        "final_critic",
    ],
)
async def test_end_during_each_agent_stage_cannot_publish_or_start_another_stage(blocked_stage):
    from threading import Event

    from simplynext.agent.words.assembler import ProviderWordAssembler, WordProvider
    from simplynext.agent.words.critic import ProviderWordCritic
    from simplynext.agent.words.graph import WordGraph
    from simplynext.translation_runtime import WordPolicy, WordTranslationEngine

    started, release = Event(), Event()
    templates = json.loads(
        (Path(__file__).parents[1] / "data/word_templates.example.json").read_text()
    )["templates"]

    class Client:
        calls = 0

        def converse(self, **kwargs):
            self.calls += 1
            if self.calls == blocked_stage:
                started.set()
                release.wait(timeout=2)
            value = (
                templates[0]["draft"]
                if self.calls % 2
                else dict(
                    schema_version="1.0",
                    supported=False,
                    reason_code="unnatural_sentence",
                    target_indices=[],
                    revision_instruction="improve_grammar",
                )
            )
            return {
                "stopReason": "end_turn",
                "output": {
                    "message": {
                        "content": [
                            {"text": json.dumps(value)},
                        ]
                    }
                },
            }

    client = Client()
    provider = WordProvider(client, "test")
    graph = WordGraph(
        ProviderWordAssembler(provider), ProviderWordCritic(provider), model_version="test"
    )
    policy = parse_value(
        WordPolicy, (Path(__file__).parents[1] / "data/word_policy.synthetic.json").read_bytes()
    )
    store = RoomStore()
    runtime = service(store, WordTranslationEngine(graph, policy))
    room, signer, _ = await pair(store)
    request = utterance(
        words=[
            dict(index=i, token_id=f"w{i}", word=word, confidence=0.9, alternatives=[])
            for i, word in enumerate(templates[0]["words"])
        ]
    )
    await runtime.submit(room.code, signer.token, request)
    tasks = tuple(room.tasks)
    assert await asyncio.to_thread(started.wait, 1)
    async with room.lock:
        store.erase(room)
    await asyncio.gather(*tasks, return_exceptions=True)
    assert not room.messages and not room.requests and not room.tasks
    release.set()
    await asyncio.gather(*graph._calls)
    await asyncio.sleep(0)
    assert client.calls == blocked_stage
    assert not graph._calls and room.state == "ended" and not store.rooms
