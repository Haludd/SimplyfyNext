# Word contract and room protocol decision record

Implemented 2026-09-15 for root `PLN_plan_v1.md` sections 4–7 and backend milestones 0–4.
The root `TRANSLATED_SIGN_UTTERANCE_V1.md` remains the normative ingress authority.
This record covers the only ASL room runtime. The retired session endpoints are absent.
Current acceptance details are in [WORD_ACCEPTANCE_POLICY.md](WORD_ACCEPTANCE_POLICY.md).

## Contract handoff

- `src/simplynext/contracts/schemas/translated-sign-utterance-v1.json` is an exact semantic
  export of the normative Draft 2020-12 schema, including its mandatory UUID format.
- `tests/fixtures/translated_sign_utterance_v1.json` is the exact canonical TABLE TABLE example.
- `tests/fixtures/translated_sign_invalid_v1.json` contains 132 named invalid cases. Each row has
  a `layer` (`schema`, `semantic`, or `transport`) and a complete `payload` or `raw_json`.
  Both clients must reject every row, including semantic cases that JSON Schema alone accepts.
- `src/simplynext/contracts/schemas/room-events-v1.json` freezes the event union.
- `client/room-http-v1.schema.json` exports the HTTP inputs, acknowledgements, credentials,
  socket controls and shared definitions; `client/room-v1.ts` is generated from those schemas.
- Run `python scripts/export_word_contract.py --check` to detect drift; omit `--check` to
  regenerate. Never hand-edit the generated client field lists.

Ingress and event versions are independently negotiated as exactly `1.0`. Create/join require
both `schema_version` and `event_schema_version`; the first socket packet requires
`event_schema_version`. Unsupported versions or unknown fields return 422 on HTTP and close
the socket during authentication. Adding fields requires a newly negotiated version.

Backend schema/fixture validation is automated. Frontend execution of this suite and recorded
frontend/backend owner sign-off remain external acceptance evidence; this implementation does
not assert that either team has supplied that evidence.

## HTTP flow

| Method and route | Input and response |
| --- | --- |
| POST `/v1/rooms` | `{schema_version:"1.0",event_schema_version:"1.0",alias:"Signer"}`; 201 credentials |
| POST `/v1/rooms/join` | Same fields plus `code`; 200 hearing-participant credentials |
| GET `/v1/rooms/{code}` | Bearer capability; full bounded recovery snapshot |
| POST `/v1/rooms/{code}/messages` | `{schema_version:"1.0",message_id,client_sequence,source:"text"\|"speech",text}`; 201 accepted message, 200 exact retry |
| POST `/v1/rooms/{code}/sign-utterances` | Frozen ingress; immediate 202 `utterance_ack` |
| DELETE `/v1/rooms/{code}` | Either participant's bearer; 204; subsequent accesses return 410 |

The creator is the signer; the joiner is the hearing participant. Both can submit finalized text,
including a signer's typed fallback. Only the signer can submit signed words. Every participant
shares one exact-next client sequence across their text and signed submissions, starting at zero.
The server derives identity and role from capability state, never from the body.

Each new admitted message reserves `(sender_id,message_id)`, sequence and a canonical SHA-256
digest under the room lock. Equivalent object ordering, whitespace and score `1`/`1.0` are exact
semantic retries. Different content or sequence under an existing ID, sequence reuse under a new
ID, and sequence gaps return 409 `sequence_conflict`. Exact retries precede rate/capacity/pending
checks and never dispatch a second model run. Signed retries retain the original server sequence
and return `disposition:"cached"`; recover current message state through GET or the event stream.

The wire body is UTF-8 JSON and at most 16,384 bytes, enforced before JSON parsing, including
chunked bodies. Duplicate object keys, nonfinite values, strings/booleans as numbers and unknown
fields are rejected. HTTP validation responses are redacted (`invalid_utterance`) without input
values. Oversize returns 413; authentication 401; absent/ended/expired rooms 410; rate/capacity or
another pending signed message 429. Submission while waiting for a second participant is 409.

Repair has no sentence/TTS fields. A repair continuation is a new committed utterance with a new
message ID and the next sequence, or finalized typed text. There is no input `repair_id` extension.

## Events and recovery

Connect to `/v1/rooms/{code}/events`. Within 10 seconds, send:

```json
{"type":"authenticate","event_schema_version":"1.0","token":"CAPABILITY_FROM_HTTP"}
```

The server sends one bounded `snapshot`, then `message_upsert`, `presence`, `activity`, `pong`,
`error`, and `room_ended`. Clients key messages by `(sender_id,message_id)`, merge upserts, and
ignore older room versions. A processing message retains its server sequence when terminal;
therefore recovery returns the complete bounded snapshot, rather than an unsafe filter that
could omit an older message's terminal transition. The joiner's presence makes the room active.

Client controls are `{type:"ping"}`, `{type:"activity",state:"idle"|"typing"|"listening"|"signing"}`,
and `{type:"end"}`. Unknown controls close the connection. Controls/authentication are at most
1,024 bytes; binary frames are rejected. Presence reflects active subscribers, not credentials.

At most two sockets per participant and 32 queued events per subscriber are retained. A slow
subscriber receives `error`/`resync_required` and closes with 1013. Every terminal state is stored
before delivery, so reconnect/GET recovers it. Authentication failures close with 4401, unavailable
rooms with 4410, origin rejection with 4403, malformed packets with 4400, and capacity with 4429.

Use HTTPS/WSS when hosted, exact Origin/host allow-lists, tab-scoped capabilities and no credentials
in URLs. Credentials contain a public `join_path` for the client router; no server-side QR image or
frontend page is added in this milestone. All room HTTP responses have no-store/no-referrer headers.

## Policy and agents

The production vocabulary and producer-specific confidence evaluation have not been supplied.
`SIMPLYNEXT_WORD_POLICY_PATH` must point to a strict `WordPolicy` document with the exact frozen
producer, reviewed vocabulary, `evaluation_id`, `purpose:"producer_evaluated"`, `min_score` and
`min_margin`. These scores remain normalized model scores, never calibrated probabilities. No
legacy probability threshold is reused. Zero scores, ties, insufficient scores/margins, and OOV
primary or alternative words become deterministic repairs before provider dispatch. No profile
means admitted signed messages safely repair with `policy_unconfigured` and no model calls.

`data/word_policy.synthetic.json` is only synthetic test data, not a PopSign vocabulary authority
or empirical calibration. Production startup explicitly refuses its `synthetic_evaluation` purpose and requires matching
reviewed evidence for any `producer_evaluated` policy.
The vocabulary is intentionally limited to examples used by local tests.

The `agent/words/` pipeline receives immutable word
tokens, producer scores and context. Its stateless bounded state machine calls the assembler and
independent critic separately. There are no tools, memory mutations, provider chat history or persisted graph checkpoints. One long-lived cost-guarded provider
client serves the word pipeline; direct Anthropic and Bedrock retain their pricing,
preflight, token usage, retry/timeout and spend guards. Word output schemas are generated from
Pydantic; the cost bound includes the direct provider's additional structured-output schema.
The direct adapter applies the SDK's `transform_schema` before `messages.create`, retaining full
bounds in local Pydantic validation and the system schema. This follows Anthropic's
[documented schema transformation requirements](https://platform.claude.com/docs/en/build-with-claude/structured-outputs#how-sdk-transformation-works);
unsupported provider grammar constraints do not weaken the local release gate.

Assembler output has a bounded candidate, optional identical TTS, ordered per-token alignment and
explicit unresolved indices. Mechanical gates cover every current input index and reject invented
lexical tokens, names, quantities, negation, pronouns, unsupported question force, incorrect indices,
leakage markers, omitted evidence and unreviewed inflections. The critic additionally checks natural
English, context coherence and semantic force and can return bounded revision instructions, never
replacement text. Unsupported criticism permits at most one revision and one final critic call.
Any remaining failure repairs without provider text or draft leakage.

This gate deliberately restricts paraphrases. Articles and present be auxiliaries are allowed only
when semantically licensed; the critic must reject grammatical additions that change meaning.
Deterministic mode uses reviewed exact word tuples in `SIMPLYNEXT_WORD_TEMPLATES_PATH` and a separate
template critic. Contextual template requests repair because templates cannot judge history. Five synthetic positive examples and adversarial unit cases exercise reorderings,
article insertion and grounding; they are not a claim of clinical or production translation quality.

## Lifecycle and context boundary

Default limits: 100 rooms, 300 messages per room, 10-minute invitations, 30-minute idle expiry,
two-hour absolute lifetime, 20 invitation attempts per address/minute, 120 globally/minute and
30 messages per participant/minute. Server-generated room codes use eight random nonambiguous
characters. Participant tokens have 256 bits of randomness and only SHA-256 digests are stored.

One pending signed utterance per room and a shared application semaphore bound model work. The
room lock is released before any provider I/O. Admission captures immutable context; asynchronous
completion checks the original room object and pending owner before one terminal commit. End/expiry
cancels tasks, drains queues to room_ended, and erases messages, replay/digests/sequences, repairs,
producer locks, summaries, participants, capability digests and subscribers. Late output cannot
recreate an ended room. The expiry task runs every five seconds and the same erasure path runs on
access and shutdown. The initial deployment remains exactly one process/worker/replica; restart
loses all active rooms.

Already-running synchronous provider SDK requests cannot be physically stopped by asyncio
cancellation. They finish under their configured SDK timeout; their results are discarded and their
provider concurrency permits are retained until completion. SDK request buffers may remain until
then. Erasing room state does not erase provider-side retention. Tests exercise end during all four
possible model stages, admission, replay, queued work and expiry.

The room stores the canonical accepted transcript, recent 10 verbatim turns, a compact extractive
summary and at most 20 overflow turns. Every 10 evictions schedule asynchronous compaction after
publication; stalls/failures use bounded extraction. Watermark/generation checks reject stale work,
including a signed result completing out of order. All context is erased by the same room end path.
Assembler and critic projections have separate conservative token bounds and explicitly mark
excerpts for extreme input sizes. See [architecture](ARC_architecture.md) for exact budgets and
summary limitations. Context tests cover 60/120/240 turns and summary/translation deletion races.

## Verification and migration

Run the standard quality gates, plus `python scripts/export_word_contract.py --check`.
`python scripts/room_protocol_smoke.py --base-url http://127.0.0.1:8000` exercises text, guaranteed
zero-score no-spend repair, both event subscribers, replay, reconnect and deletion. With the synthetic
profile and example templates configured in development, `--templates` also checks accepted word
assembly and refuses a readiness response identifying a hosted provider.

`scripts/container_smoke.sh` runs only the room protocol. The package smoke checks both word prompts,
both v1 schemas, parsed templates and absence of retired runtime files. Backend contract tests
assert the old session endpoint is absent and non-ASL startup is rejected. The generated client
handoff is unchanged; execution against the current frontend and owner sign-off are still pending.
No stale root frontend or prototype source files were read or modified in this round.
