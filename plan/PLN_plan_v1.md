# SimplifyNext backend implementation plan v1

## Metadata

| Field | Value |
| --- | --- |
| Code | `PLN-V1` |
| Status | Milestones 1–3, milestone 4 backend removal and sections 8–9 implemented locally; hosted release and frontend/producer qualification pending |
| Scope | Backend infrastructure and backend-facing contract only |
| Source of truth for | The next implementation round |
| Contract | [TranslatedSignUtterance v1](../TRANSLATED_SIGN_UTTERANCE_V1.md) |
| Last reviewed | 2026-09-15 |

This plan supersedes the earlier GlossLattice implementation plan for the next implementation round.
It does not claim that the planned behavior exists. Existing source, tests, deployments, and their
historical documentation remain the authority for currently implemented behavior until migration is
complete.

## 1. Decisions for this round

1. American Sign Language (`asl`) is the only sign-language source in scope. SgSL is removed from
   new runtime configuration, contracts, tests, fixtures, prompts, and examples.
2. The current frontend team owns recognition and token-level ASL-to-English translation. The
   backend does not host a recognition or sign-translation model and receives no sensing data.
3. `GlossLattice` is replaced by the strict, incompatible `TranslatedSignUtterance v1` contract.
   The new endpoint accepts one completed ordered sequence of individual English words.
4. The assembler and critic remain. They are repurposed to form a grammatical spoken-English
   sentence and independently verify that it is grounded in the submitted words.
5. Accepted conversation history is session-scoped application data. Agent requests receive one
   compact summary plus the latest 10 finalized conversation turns, not an unbounded provider chat.
6. The two-person room implementation is folded into the main backend runtime. The model graph is
   called in-process after a signed utterance is admitted; the production path does not add an
   internal HTTP translator hop.
7. A room is temporary. Either participant can end it for both people, after which all room content,
   context, replay/checkpoint state, credentials, and pending work are erased. Idle expiry is a
   fallback, not the primary privacy mechanism.
8. The initial hosted release remains one process, one worker, and one replica while state is in
   memory. Multiple workers/replicas are prohibited until room state, idempotency, checkpoints, and
   pub/sub are externalized atomically.

## 2. Evidence reviewed

The plan was formed after reviewing the current backend architecture, contracts, implementation
plan, dependencies, source map, graph state, assembler/critic boundary, context tools, session
store, and GlossLattice impact surface.

The `two-way-conversation` directory was also scanned before choosing the room architecture. Its
prototype currently demonstrates:

- room creation and joining by six-character code/QR URL for exactly two participants;
- random participant capabilities hashed in process memory;
- bearer-authenticated HTTP and first-message-authenticated browser WebSockets;
- text/speech messages, words-only submissions, increasing room snapshots, presence, retries, and
  `(sender_id, message_id)` idempotency;
- local camera privacy, tab-scoped recovery state, a 10-minute invitation window, two-hour room TTL,
  300-message room cap, and 100-room process cap;
- termination by either participant and periodic expiry;
- a replaceable HTTP translator that currently receives the latest 30 accepted messages;
- a demo translator that merely joins words and does not form a sentence.

The useful mechanics should be ported and hardened, not copied as an independent production
service. Important gaps to correct are the old minimal word payload, full-snapshot broadcast on each
change, synchronous request latency, a linear 30-message context window, no compaction, model work
while holding the room lock, and incomplete deletion once graph checkpoints/context are introduced.
The stale root `frontend/` directory was not used as an implementation authority.

## 3. Target boundary and request flow

```text
Signer device
  camera -> ASL recognition -> per-sign English words -> local utterance buffer
  -> POST final TranslatedSignUtterance v1
  -> strict admission/idempotency/confidence policy
  -> immutable context snapshot
  -> assembler -> critic -> optional one revision -> confident result or repair
  -> room message event -> both participants

Hearing device
  speech-to-text or typed text -> POST finalized text message
  -> strict admission -> room message event -> both participants
  -> becomes context for later signed utterances
```

No model call occurs for every recognized word, presence event, partial speech draft, reconnect,
typing indicator, hearing text message, cached retry, or rejected payload. A signed utterance gets at
most one initial assembler call, one critic call, and one bounded assembler revision plus final
criticism only under the existing retry policy.

### Ownership table

| Concern | Frontend | Backend |
| --- | --- | --- |
| Camera/media permissions and frames | Owns; remains local | Never receives |
| ASL recognition | Owns | Validates producer metadata only |
| Per-sign translation to English words | Owns | Treats submitted words as current evidence |
| Utterance boundary | Detects and explicitly commits | Accepts final utterances only |
| Ordering/retries | Generates message ID and client sequence | Enforces and replays idempotently |
| Sentence grammar and word order | Does not need to solve | Assembler owns |
| Grounding/safety | Supplies confidence/alternatives | Policy and critic own |
| Conversation transcript/context | Renders current room | Canonical session authority |
| TTS | Plays safe returned text locally | May return `tts_text`; creates no audio file |
| Room lifecycle/deletion | Requests end and clears tab state | Authenticates, broadcasts, cancels, and erases |

## 4. Contract-first implementation

### 4.1. Freeze and publish

1. Frontend and backend owners review the exact schema in
   `TRANSLATED_SIGN_UTTERANCE_V1.md`, particularly canonical word syntax, producer identifiers,
   confidence semantics, alternatives, completion reasons, limits, and repair continuation.
2. Export the normative schema into a versioned backend package resource and generate/hand off the
   client model. Do not maintain independent handwritten field lists.
3. Add one canonical valid fixture and a table of invalid fixtures for every structural and semantic
   invariant.
4. Freeze version `1.0`; future incompatible work uses a new endpoint/schema version.

### 4.2. Planned backend modules

The exact package names may be adjusted during implementation, but responsibilities must remain
separate:

```text
src/simplynext/
├── contracts/
│   ├── translated_sign_utterance.py  strict ingress and semantic invariants
│   ├── room_inputs.py                room create/join/text/control inputs
│   └── room_events.py                ack, message, presence, repair, ended, error union
├── rooms/
│   ├── store.py                      room/auth/order/idempotency/TTL state
│   ├── service.py                    lock-safe admission, work dispatch, terminal commit
│   ├── context.py                    transcript, recent turns, compaction and snapshots
│   └── deletion.py                   one idempotent complete-erasure path
├── api/
│   ├── room_routes.py                create/join/get/end and finalized submissions
│   └── room_websocket.py             browser-safe auth and incremental events
├── agent/
│   ├── state.py                      word evidence plus immutable conversation context
│   ├── assembler.py                  words/context -> bounded aligned sentence draft
│   ├── critic.py                     independent evidence/context verification
│   ├── repair.py                     deterministic fail-closed action selection
│   └── prompts/                      new versioned ASL-word prompts
└── translation_runtime.py            policy, graph invocation and event mapping
```

`main.py`, `runtime.py`, `config.py`, middleware, operator routes, metrics, package resources, CLI
entry points, container smoke scripts, and deployment settings must compose the room runtime in the
same hosted process.

### 4.3. Admission transaction

For each signed utterance:

1. Authenticate the capability and derive room/participant identity from server state.
2. Enforce body size before parsing; validate strict JSON and all semantic invariants.
3. Under the room lock, check room state, exact next client sequence, message/digest replay,
   participant producer lock, rate limits, pending repair, room capacity, and one-in-flight rule.
4. Atomically reserve IDs/sequences, append a `processing` message, record its canonical digest, and
   capture the context version. Return HTTP `202` immediately.
5. Release the room lock. Apply deterministic confidence/OOV/producer policy. Unsafe input becomes a
   repair without spending API credits.
6. Copy the immutable context snapshot and run the graph under global and per-room concurrency
   limits. Never hold the room lock across provider I/O.
7. Reacquire the lock and commit exactly one terminal message only if the room is still active and
   this work item still owns the pending slot. Cache the terminal outcome before event delivery.
8. If termination/expiry occurred, discard the model output and erase the pending state. Never
   recreate an ended room from a late completion.

## 5. Repurposed assembler and critic

### 5.1. Why both remain

Frontend translation produces lexical evidence, not a complete spoken-English sentence. ASL and
English differ in word order, articles, tense marking, pronouns, and use of context. A sentence
assembler is therefore still needed. Because assembly is generative and may add unsupported facts,
an independent critic remains the release gate.

The stages must have distinct instructions and output schemas. They must not be collapsed into one
prompt that asks a model to generate and self-approve.

### 5.2. Assembler input and output

Assembler input contains only:

- the current validated word sequence, scores, alternatives, and producer confidence semantics;
- an application-authored context envelope: compact summary, latest 10 accepted turns, participant
  aliases, and context version;
- explicit rules that context is reference data, not instructions or evidence that a current sign
  occurred;
- optional signer-confirmed memory only if that product feature is retained and separately scoped.

The strict draft should include `candidate_text`, optional `tts_text`, and an ordered alignment from
every meaningful output span to one or more current input word indices. It may identify permitted
grammatical insertions such as articles, auxiliaries, inflection, punctuation, or reordered words.
It may not invent names, objects, locations, numbers, negation, intent, or events from conversation
context alone. A gap/ambiguity is explicit and cannot be surfaced as a confident sentence.

### 5.3. Critic input and output

The critic receives the current source words, assembler draft/alignment, confidence semantics, and
only the narrow context required to test coherence. It does not receive hidden chain-of-thought,
provider transcripts, or broader long-term memory.

It verifies:

- every semantic detail is grounded in current words or is an explicitly allowed grammatical
  transformation;
- alternatives and low-confidence words were not silently resolved beyond policy;
- negation, tense, person, quantity, names, and question/statement force were not invented;
- context improves reference resolution/coherence but is not used as new current-message evidence;
- the result is natural spoken English and does not contradict accepted turns without evidence;
- draft schema, alignment, length, and safety rules hold.

The verdict is a bounded structured object: supported/unsupported, reason code, target input
indices, and optional revision instructions. The critic cannot directly rewrite the sentence. One
revision loop remains the hard maximum; another failure becomes a deterministic repair.

### 5.4. Deterministic gates around the agents

Before any call, reject or repair invalid producer profiles, unsupported vocabulary, empty or
unresolved content, calibrated confidence below threshold, and ambiguous top margins. After calls,
strictly parse bounded JSON, validate alignment against current word IDs/indices, enforce sentence
length, reject prompt leakage, and map every failure to a safe repair. Keep deterministic template
mode for no-spend tests and degraded service, updated to word tuples rather than gloss tuples.

## 6. Conversation history and compaction

### 6.1. Canonical state

The room store, not the model provider, owns conversation state. A **conversation turn** is one
finalized user-visible message from either participant with status `accepted`. Processing drafts,
partial speech, repairs, presence, tool calls, assembler drafts, critic verdicts, retries, and model
responses are not turns.

Each active room holds:

```text
accepted transcript (bounded by room message limit)
compact summary
summary_through_server_sequence
latest 10 accepted turns after that sequence
small overflow batch awaiting compaction
context_version
```

Only the active room can access this state. It is not signer memory, is not reused across rooms,
and is erased with the room.

### 6.2. Prompt window algorithm

1. Append each accepted signer or hearing message to the canonical transcript.
2. Keep the latest 10 accepted turns verbatim, with stable sequence, speaker role, source, and text.
3. When an eleventh turn would leave the window, move the oldest turn into a bounded overflow batch.
4. Compact overflow into the prior summary in batches, ideally 10–20 evicted turns, using an
   asynchronous task after terminal delivery. Do not put summarization on the signed-message latency
   path.
5. Until compaction commits, prompt construction includes the old summary plus the bounded overflow
   and latest 10 turns. Commit only if `summary_through_server_sequence` still matches the task's
   input version; otherwise retry against the new state.
6. Cap the summary at approximately 300–800 tokens and the complete context envelope at a configured
   token budget. Preserve open questions, unresolved references, explicit corrections, current
   topic, and facts needed to interpret likely pronouns. Drop greetings, repetition, filler, and
   superseded details first.
7. If compaction fails or exceeds budget, retain a deterministic bounded extractive digest and
   continue; never block conversation delivery or silently send unbounded history.

A separate summarizer call is optional. The preferred first implementation benchmarks a cheap,
batched Haiku summary against deterministic/extractive compaction. It is enabled only if evals show
material coherence gains; it must not run once per turn. A future alternative is to collect a small
structured context delta in an already-required agent response, but only after grounding and cost
evals prove it safer than batch compaction.

### 6.3. Prompt layout and token efficiency

Use a stable prefix followed by volatile data:

```text
versioned system rules and output schema
stable tool definitions (prefer no tools when direct context is sufficient)
compact summary
latest 10 accepted turns
current TranslatedSignUtterance evidence
```

Construct the context once per signed utterance and project only the fields each stage needs. The
assembler gets summary + 10 turns + current words. The critic gets current words + draft/alignment
+ a narrower relevant context view; it must not receive a duplicated full transcript by default.
Store token counts from provider usage metadata, not raw prompt content.

Prompt caching is secondary to compaction. As of 2026-09-14, Anthropic lists Claude Haiku 4.5 at
USD 1 per million base input tokens and USD 5 per million output tokens; cache reads are USD 0.10
per million, but Haiku 4.5 requires at least 4,096 cacheable prompt tokens. Do not pad a compact
prompt to reach that minimum. If the natural stable prefix exceeds it, enable automatic caching or
an explicit breakpoint before volatile history and verify cache-hit metrics. See Anthropic's
[pricing](https://platform.claude.com/docs/en/about-claude/pricing) and
[prompt-caching documentation](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).

## 7. Two-way room infrastructure

### 7.1. Planned HTTP/WebSocket surface

| Route | Purpose |
| --- | --- |
| `POST /v1/rooms` | Create a two-person temporary room and signer capability |
| `POST /v1/rooms/join` | Exchange a valid room code for the second participant capability |
| `GET /v1/rooms/{code}` | Authenticated recovery snapshot, optionally after a sequence |
| `POST /v1/rooms/{code}/messages` | Finalized hearing text/speech transcript; no agent call |
| `POST /v1/rooms/{code}/sign-utterances` | `TranslatedSignUtterance v1` admission |
| `WS /v1/rooms/{code}/events` | Authenticated deltas, presence, processing, results, repairs, end |
| `DELETE /v1/rooms/{code}` | Either participant ends and erases the room for both |

Preserve the prototype's safe browser WebSocket pattern: accept the socket, require an
`authenticate` packet as the first bounded message within 10 seconds, and never place capabilities
in URLs. QR invitations contain only the public join URL and room code. Use high-entropy nonambiguous
codes, a short join window, constant-time token-digest comparison, exact Origin allow-lists, HTTPS,
WSS, no-store headers, and no-referrer policy.

### 7.2. State and event model

Keep exactly two participant records, capability digests, lifecycle timestamps, independent client
sequences, monotonically increasing room/context versions, bounded message state, request digests,
pending tasks, and subscriber queues.

Send a bounded recovery snapshot on authentication/reconnect, then incremental `message_upsert`,
`presence`, `activity`, and `room_ended` events. Do not rebroadcast the complete transcript on every
keystroke or message transition. Clients ignore events older than their latest room version and
render message identity as `(sender_id, message_id)`.

Presence/activity is lossy and replaceable; message/result/end events are replayable state. Bound
subscriber queues and collapse obsolete presence events, but never drop a terminal message without
making it recoverable through the authenticated snapshot endpoint.

### 7.3. Storage decision

For the first controlled hosted release, use process memory for the lowest latency and shortest data
lifetime, and deploy exactly one worker/replica. Document that restart loses active rooms. This is
acceptable only while that product limitation is explicit.

Before adding replicas or promising restart survival, introduce an ephemeral shared store such as
Redis/Valkey with TLS, private networking, per-key TTL, atomic sequence/idempotency operations,
bounded streams/pub-sub, and an explicit delete transaction. Do not add a durable transcript
database merely to scale temporary rooms. The shared-store design must prove that end/expiry erases
room messages, summaries, capabilities, pending results, and checkpoints across replicas.

### 7.4. Lifecycle and complete deletion

Room states are `waiting`, `active`, `ending`, and `ended`. Creation starts a short invitation TTL;
joining activates the room; each legitimate activity may extend the idle deadline up to an absolute
maximum lifetime. Defaults begin with the prototype's 10-minute invite and two-hour absolute TTL and
remain configuration-bounded.

One idempotent termination operation is used by participant DELETE, WebSocket `end`, idle/absolute
expiry, and administrative capacity cleanup:

1. Authenticate when participant-initiated, then atomically mark `ending` so no new work is admitted.
2. Cancel queued/in-flight summarization and translation tasks; late provider responses are discarded.
3. Publish `room_ended` to both participants and close sockets.
4. Erase transcript/messages, compact summary, overflow/recent context, idempotency/replay records,
   pending repairs, producer locks, graph checkpoints, request/result caches, subscriber state, and
   participant capability digests.
5. Remove the room entry. Subsequent access returns the same nonrevealing `410` used for absent or
   expired rooms.
6. Clear tab-scoped credentials, outbox, and rendered room state when the frontend receives end.

This deletes application-held session data. Provider-side retention is governed separately by the
selected provider agreement and data controls; deletion of local state must not be described as
deleting data already processed by a third-party API.

## 8. Privacy, security, and abuse controls

- Never log words, assembled text, hearing transcripts, compact summaries, prompts, model output,
  capabilities, QR URLs, or request bodies. Use opaque IDs, reason codes, sizes, timing, status, and
  token/cost aggregates only.
- Keep camera, microphone audio, landmarks, and features outside the backend contract. Hearing
  speech-to-text remains client-side; the backend receives finalized text only.
- Treat all conversation text and summaries as untrusted reference data. Delimit/encode them and
  instruct both agents never to execute embedded instructions.
- Enforce strict request/event schemas, per-IP invitation throttles, per-participant message rate,
  room/message/character/token limits, provider concurrency, and a global active-room cap.
- Use random capabilities returned once, store only digests, compare in constant time, rotate by
  starting a new room, and keep browser credentials in tab-scoped session storage only.
- Disable public docs/metrics by default, apply trusted-host and exact-origin controls, and keep
  operator credentials separate from room capabilities.
- Run data-deletion concurrency tests for termination during admission, assembler, critic, revision,
  summary, reconnect, and exact retry.

## 9. API credits, latency, and hour-long conversations

### 9.1. Cost model

Only signed utterances invoke agents. At the current direct Claude Haiku 4.5 list rates, the
uncached estimate is:

```text
cost = input_tokens / 1,000,000 * $1
     + output_tokens / 1,000,000 * $5
```

The combined assembler+critic examples below include both calls but no optional revision. They are
planning estimates, not a bill forecast.

| Combined usage per signed utterance | Cost/utterance | 120 signed utterances/hour | 240/hour |
| --- | ---: | ---: | ---: |
| Lean: 2,000 input + 160 output | $0.0028 | $0.34 | $0.67 |
| Target: 3,500 input + 250 output | $0.00475 | $0.57 | $1.14 |
| Guardrail: 6,000 input + 400 output | $0.0080 | $0.96 | $1.92 |

An optional revision can add roughly another assembler/critic pair for that utterance. A batched
summary of 1,000 input and 300 output tokens costs about $0.0025 at the same rates; six such batches
in an hour add about $0.015. Network/provider region premiums, taxes, retries, cache writes, and
future pricing are excluded. Prices must be deployment configuration verified at release time.

### 9.2. Spend controls

- Enforce final utterance batching; never call per word.
- Keep summary + latest 10 accepted turns under stage-specific token caps.
- Run low-confidence, OOV, schema, and replay gates before provider dispatch.
- Do not invoke models for hearing text or speech transcripts.
- Cap output tokens tightly with structured output and concise reason codes.
- Keep one revision maximum and monitor its rate; repeated ambiguity becomes repair/type/interpreter.
- Batch optional summarization and keep it off the user-facing critical path.
- Track input, output, cache-write/read tokens, cost estimate, latency, revisions, repairs, and budget
  rejection by opaque room/request IDs only.
- Enforce per-request, per-room, per-hour, and process/deployment spend ceilings before dispatch.
  Near a room ceiling, return a clear safe fallback that allows typed chat rather than silently
  degrading or overspending.
- Load-test 60-, 120-, and 240-turn synthetic rooms and assert context size stays approximately
  constant after the first 10 turns.

### 9.3. Latency targets and tactics

Return admission acknowledgements without awaiting a provider. Reuse one long-lived provider client,
bounded connection pool, preloaded prompts/schemas, and in-memory O(1) context state. Keep room locks
out of provider I/O. Publish processing immediately, suppress unsafe streaming drafts, and publish
only critic-approved terminal text. Measure p50/p95 separately for admission, queue, assembler,
critic, revision, terminal commit, and end-to-end delivery. Set service-level targets only after a
hosted mobile baseline; do not invent them in advance.

## 10. Migration and implementation milestones

Sections 8–9 implementation (2026-09-15): exact production origins, private response headers,
payload-free logging, bounded unauthenticated sockets/body reads, explicit proxy policy,
request/room/hour/deployment reservations, a restart-safe aggregate-only spend journal,
bounded p50/p95 metrics and accelerated mixed-room benchmarks are present. See
[hosted verification preparation](./HOSTED_VERIFICATION.md) for production settings,
commands, monitoring and release gates. Section 14 records outstanding acceptance evidence.

Implementation update (2026-09-15): see
[the implemented word/room protocol](./WORD_ROOM_V1.md). Milestones 1–3 and milestone 4’s backend removal have local
source, package and container verification. Milestone 0's shared schema, generated client model, canonical/invalid
fixtures, events and decision record are implemented. The integrated frontend now passes the
canonical and 132 invalid fixtures; owner sign-off remains external acceptance evidence. Section 4's asynchronous admission/deletion
primitives are present. Milestone 3’s summary compaction and milestone 4’s backend cutover are implemented. The retired
runtime is absent. Milestone 4’s frontend integration now has local static analysis, unit/widget
tests, a release web build, and an actual two-participant HTTP/WebSocket smoke. Hosted physical-device
acceptance remains pending. Production producer/model evidence remains required before sentence release.

Current implementation details: deterministic compaction runs in batches of 10 evicted accepted
turns with a 20-turn overflow cap and watermark/generation checks. Prompt projections default to
8,000/3,000 conservative token bounds; extreme-length/Unicode content is explicitly excerpted only
in the prompt while the canonical transcript and stored recent 10 remain verbatim. A late signed
completion invalidates/rebuilds stale summary state. No optional model summarizer is enabled.
See [sentence acceptance and qualification](./WORD_ACCEPTANCE_POLICY.md) for the
implemented two-test policy, topic-change handling and version-bound evaluation evidence.

### Milestone 0 — contract freeze

- Obtain frontend/backend sign-off on `TranslatedSignUtterance v1`.
- Add exported JSON Schema, generated model guidance, fixtures, and a protocol decision record.
- Define room event schemas and version negotiation.

Exit: both teams validate the same canonical and invalid fixtures byte-for-semantics.

### Milestone 1 — contract and room core

- Implement strict utterance, room input, and room event models.
- Port two-person room store behavior, capabilities, code generation, TTL, sequence, idempotency,
  replay, incremental events, and complete deletion into the main backend.
- Add isolated store/service tests, including all termination races.

Exit: no agent dependency is needed to prove secure two-device text rooms and word admission.

### Milestone 2 — agent repurpose

- Replace lattice graph state/evidence with word tokens, alternatives, producer metadata, and
  alignment.
- Replace assembler/critic prompts and response schemas; update repair and confident result mapping.
- Update deterministic templates and direct Anthropic/Bedrock adapters without changing cost guards.
- Preserve independent calls, strict parsing, one revision cap, replay safety, and fail-closed output.

Exit: unit/eval sets prove grammar improvement without unsupported semantic additions.

### Milestone 3 — context and asynchronous processing

- Implement canonical accepted transcript, recent-10 window, summary/overflow state, context version,
  stage-specific projections, token counting, and batched compaction.
- Change signed POST to immediate admission plus background graph work and terminal room events.
- Cancel/discard safely on end and cache terminal outcomes before delivery.

Exit: context remains bounded over 240 turns; no stale summary or late model result can cross rooms or
resurrect an ended room.

### Milestone 4 — remove GlossLattice and integrate the client

- Add new routes alongside legacy routes only for a short controlled migration window if required.
- Update the new frontend against generated v1 models and terminal room events.
- Run dual-version contract tests, then remove GlossLattice routes, models, fixtures, prompts,
  metrics, config, scripts, package exports, and tests. Do not translate legacy fields internally.
- Remove SgSL configuration and examples; assert ASL-only startup and negotiation.

Exit: repository search and package smoke show no live GlossLattice/SgSL runtime surface; legacy
requests are explicitly rejected or the old route is absent.

### Milestone 5 — hosted verification

- Build the reviewed image and deploy one worker/replica with HTTPS/WSS, exact host/origin controls,
  health/readiness, sealed provider credentials, external monitoring, and spend ceilings.
- Run public two-device, QR/code, sign/text, repair, reconnect/replay, termination-during-model-call,
  idle expiry, restart-loss, rollback, and physical-device tests.
- Inspect redacted logs/metrics and record release evidence without conversation content.

Exit: hosted mobile flow passes and privacy/one-worker limitations are accurately disclosed.

### Milestone 6 — optional high availability

- Only if product requirements demand it, design and implement ephemeral shared state/pub-sub,
  distributed locks/idempotency, shared graph checkpoints, and cross-replica deletion.
- Load/failover test before raising replica count.

Exit: restart/failover preserves active rooms while participant end still atomically erases all
copies.

## 11. Impacted current backend areas

| Current area | Planned change |
| --- | --- |
| `contracts/gloss_lattice.py` | Replace with translated utterance model/schema |
| `contracts/sessions.py`, `contracts/events.py` | Replace lattice negotiation/events with room-aware inputs/events |
| `sessions/store.py`, `sessions/lattice_repair.py` | Port useful ordering/replay rules into room-scoped state and repair |
| `api/lattice_websocket.py`, `api/routes.py` | Add room routes/WS; retire lattice transport after cutover |
| `lattice_runtime.py` | Rename/rebuild around word evidence and room terminal commits |
| `agent/state.py`, `graph.py` | Replace lattice keys/run records; add immutable context version/snapshot |
| `agent/assembler.py`, `critic.py`, prompts | Repurpose schemas, grounding, instructions, and tests |
| `agent/repair.py`, `adapter.py` | Target word IDs/indices; keep explicit confirmation for any persistent memory |
| `agent/tools/context.py`, `memory.py`, `lexicon.py` | Replace ad hoc history lookup with bounded room context projection |
| `anthropic_access.py`, `bedrock_access.py` | Update request schemas/token estimates; retain timeout/retry/budget guards |
| `runtime.py`, `main.py`, `config.py` | Compose rooms/context/task registry; ASL-only settings and limits |
| `observability/*` | Rename metrics and add room/context/token/cost/deletion counters without payloads |
| `scripts/protocol_smoke.py`, container smoke | Exercise room create/join/utterance/event/end instead of lattice streaming |
| Tests and fixtures | Replace lattice cases; add room, compaction, concurrency, privacy, and hour-long tests |
| README and `plan/*` | Mark old contract retired and document implemented state only after code lands |

Do not remove generic safety code merely because its name currently contains “lattice.” Preserve
strict validation, canonical digests, monotonic ordering, idempotent replay, bounded graph loops,
fail-closed repairs, payload-free logging, spend guards, and package/deployment checks while changing
their domain types.

## 12. Verification matrix

At minimum, implementation must cover:

- valid/invalid JSON Schema, semantic invariants, size, nonfinite values, unknown fields, exact
  producer profile, sequence gaps/conflicts, identical retries, and repair continuation;
- cross-room/cross-participant auth isolation, QR without credentials, Origin rejection, room/guest
  capacity, rate/cost caps, reconnect and incremental-event ordering;
- assembler grammatical transformations, complete word alignment, context coherence, prompt
  injection attempts, unsupported entities/numbers/negation, low-confidence alternatives, critic
  disagreement, revision cap, malformed/oversized provider output, timeout and cancellation;
- recent 10 turns exactly, compaction boundaries, summary version races, bounded token count, summary
  failure fallback, no internal agent turns in context, and no session-to-session leakage;
- end by either participant during every processing stage, idle expiry, deletion idempotency, late
  completion discard, graph checkpoint removal, browser state clearing, and absence from logs;
- deterministic and mocked-provider unit tests, full backend regression, Ruff, strict mypy, dependency
  checks, wheel/package-resource smoke, container protocol smoke, hosted WSS, and physical devices.

## 13. Documentation and rollout discipline

During implementation, update `UPDATE_LOG.md` after each completed milestone with files, behavior,
verification, migration state, and any deferred risk. Existing documentation must distinguish
implemented behavior from this plan. No deployment may claim GlossLattice retirement, complete room
deletion, context compaction, or hosted two-device support until the matching exit criteria pass.

## 14. Untested, unverified and remaining release work

Executed locally on 2026-09-15 against the integrated backend and Flutter frontend. The backend
suite, frontend suite, shared contract fixtures, browser classifier test, release web build, and
two-participant HTTP/WebSocket smoke pass. No hosted/mobile acceptance or live-provider quality
result is claimed. `docs/INTEGRATION_DEPLOY1.md` records setup, verification, artifact hashes, and
remaining release limits.

### 14.1. Concrete frontend findings and local integration result

| Reviewed source | Original gap | Local integration result |
| --- | --- | --- |
| `two-way-conversation/backend/src/simplynext/conversation/web/app.js` | Uses `/api/rooms`, `/words`, minimal `{message_id,words}`, six-character prototype invitations and full snapshots with `version` | QR and room UX now use `/v1/rooms`, eight-character codes, strict utterances, and incremental `room_version`. |
| Same prototype's render/outbox logic and `frontend/conversation-tests/conversation.spec.cjs` | Tests target the prototype, not this runtime | The room controller merges by `(sender_id,message_id)`, ignores old versions, recovers snapshots, and deduplicates TTS. Automated two-browser-context and physical-device checks remain pending. |
| `frontend-model/appTesting/lib/services/translated_sign_utterance_submission_service.dart` | Correct final payload/202 parsing, but admission-only transport; endpoint/capability read from build-time `SIGNBRIDGE_*` defines | Runtime create/join credentials, first-packet WSS authentication, snapshots, upserts, end handling, and one public build-time API origin are implemented. |
| `frontend-model/appTesting/lib/app_controller.dart` | Pending payload/next sequence are held in memory and pending clears on acknowledgement; no complete v1 room/event controller found | One tab-scoped room owner now shares sequence state across sign, speech, and text, retains exact retries, and clears room data after end/410. |
| Model frontend acknowledgement UI | Shows “waiting for the room result”; actual sentence/repair/TTS consumption remains unverified | Processing, accepted sentences, repairs, and once-only terminal TTS are rendered in the shared conversation. |
| Model controller and retained `landmark_stream*`, `gloss_lattice*`, `bpp_client_integration.dart` services | Legacy session/perception transports remain in source | The release entry point disables their network paths. The room transport test proves sign requests omit landmarks. Physical-device speech-provider verification remains pending. |
| Model `contracts/translated_sign_utterance.dart`, label mapping and recognizer bridge | Producer/version declarations do not prove recognition quality or fixture parity | The canonical and 132 invalid fixtures pass in Flutter; producer literals and artifact digests are recorded. Recognition quality evidence remains pending. |
| Model controller `_personalSignRecognition` / `_producerFor` | Custom signs emit `personal_landmark_templates` / `personal_landmark_templates_v1` / `personal_signs_local_v1`, which the frozen v1 producer schema rejects | Personal-template matches stay local and direct the signer to typed chat. A future contract and evaluation are required for signed ingress. |

Recommended boundary: keep the latest model frontend's local recognition, English-word mapping
and explicit commit buffer; integrate a v1 room session controller using the prototype's usable
QR/chat UX. This backend remains the room/context/terminal authority. Do not deploy a second
prototype translator service or duplicate room state there.

### 14.2. Acceptance and release register

| ID / owner | Unverified or deferred item | Required evidence / next action |
| --- | --- | --- |
| F1 — frontend + backend | Shared contract execution passes locally; owner acceptance remains | Review the canonical/invalid fixture result, recorded versions/hashes, and obtain owner sign-off. |
| F2 — frontend | Integrated room UX passes local tests and protocol smoke | Run automated two-browser contexts and the physical iOS/Android/browser matrix against the selected hosted image. |
| Q1 — recognition/ML + reviewers | Real-producer qualification and score/margin selection | Use held-out captures split by signer/session, device/lighting/vocabulary/alternative coverage and independent human labels. Evaluate every acceptance category, including prompt injection and topic changes. Supply matching policy/report/pipeline/model hashes; never relabel synthetic data. See `plan/WORD_ACCEPTANCE_POLICY.md`. |
| Q2 — backend + ML | Real assembler/critic quality, structured outputs, timeouts and revision rate | Evaluate the exact provider/model on that corpus; retain failures, assess fidelity/naturalness and requalify after pipeline changes. Production sentence acceptance remains disabled without matching evidence. |
| P1 — release/security | Clean reviewed source, final image identity and vulnerability clearance | Review existing migration plus this change, build from the approved clean commit and retain matching label/digest. Any HIGH/CRITICAL scan finding, including unfixed zlib, blocks release until remediated and rescanned. |
| P2 — operator | Actual HTTPS/WSS, effective worker/replica/region, origin/host/proxy policy | Apply prepared manifest/profile and verify overrides/TLS. Test rejected Origins and forwarded-IP spoofing. Application per-peer limits may aggregate users behind one proxy; validate edge per-client-IP throttles separately. |
| P3 — operator | Spend-volume durability across real restart/rollback and storage failures | Provision once for UID 10001, verify single writer and crash/restart carry-forward. Test missing/read-only/full/corrupt storage in staging. Never reset a prior allowance to zero. Local journal tests do not prove hosting-platform durability. |
| P4 — provider/budget owner | Sealed credentials, expiry/refresh, prices, retention and account-wide cost limits | Verify actual model/region prices, credential lifecycle and account alerts/limits; reconcile known spend. The journal covers one deployment, not unrelated services on the account. |
| P5 — operator | Continuous external monitoring and alert delivery | Configure health/readiness plus authenticated aggregate metrics, retention and owner routing. Test alerts. Deployment healthchecks alone do not monitor ongoing health. |
| P6 — operator + frontend | Hosted expiry, end during model work, restart loss and rollback | Execute the runbook matrix on two physical devices, including queue pressure, slow provider, reconnect and SIGTERM. Confirm 410 for old capabilities and no visible late result. |
| L1 — performance/product | Real hour-long conversations, latency targets and actual costs | Local accelerated 60/120/240-turn mixed tests prove state/accounting mechanics. Run real 60-minute mobile sessions and measure stages/delivery/usage. Decide how the 300-total-message cap handles 240 signed turns plus hearing replies and repairs. |
| C1 — backend/ML | Quality of lossy extractive summaries | Evaluate references, corrections, disagreement and topic shifts over representative long conversations. Benchmark an optional batched model summary only if it improves quality within privacy/cost bounds; it remains off. |
| D1 — security + frontend | No content in edge/APM/analytics/crash logs and accurate retention disclosure | Inspect configured collectors with synthetic canaries and verify browser/media cleanup. Application tests cannot prove external collector behavior or erase provider-retained data. |
| H1 — infrastructure | High availability/failover and room restart survival | Deferred milestone 6: design ephemeral shared state, atomic replay/sequence/deletion and pub/sub before adding replicas. Numeric spend persistence does not persist rooms. |

### 14.3. Execution order

1. Complete F1/F2 and Q1/Q2; keep provider-backed sentence release disabled meanwhile.
2. Close P1, then configure the safe text/repair hosted profile and P2/P3/P5.
3. Activate the qualified provider under P4's bounded allowance; execute P6/L1/D1 on devices.
4. Attach content-free evidence and disclose product limits before declaring milestone 5 complete.
   Pursue C1/H1 only with demonstrated quality/availability needs.

Prepared files and procedures: [HOSTED_VERIFICATION.md](./HOSTED_VERIFICATION.md).
