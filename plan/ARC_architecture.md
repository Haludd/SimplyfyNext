# SimplyNext backend architecture

Implemented state: ASL words and temporary rooms, 2026-09-15. Source and executable tests are the
runtime authority; the root plan records milestone acceptance and remaining external evidence.

## Flow and boundaries

Frontend finalized words → strict ingress → room/auth/order/digest reservation → HTTP 202 →
producer policy → immutable context → assembler → mechanical grounding → independent critic →
optional one revision/final criticism → exactly one accepted/repair room message.

Typed/speech text is already finalized and becomes accepted context without model work.
No camera/audio, recognition models, provider chat history, persistent signer memory or graph
checkpoints exist in this runtime. The retired session transport is absent.

## Components

| Component | Responsibility |
| --- | --- |
| `contracts/` | Frozen strict ingress, room inputs/events and packaged schemas |
| `rooms/store.py` | Capabilities, TTL, sequences, replay, canonical messages, context and erasure |
| `rooms/context.py` | Accepted-turn history, recent 10, overflow, extractive summary, prompt budgets |
| `rooms/service.py` | Immediate admission, bounded background translation and compaction, terminal commit |
| `agent/words/` | Independent assembly/criticism, strict aligned output, deterministic repairs/evaluation |
| `translation_runtime.py` | Producer/score policy, qualified production evidence, word graph composition |
| `provider_runtime.py` | One shared guarded Anthropic/Bedrock client and access preflight |
| `api/` | HTTP, first-packet-authenticated WebSocket, size and operator controls |
| `observability/` | Content-free token/count/timing/cost aggregates |

## Context

Only accepted visible messages enter canonical history, sorted by stable server sequence. Capture
one immutable snapshot at signed admission. Context includes a compact attributed digest, its
sequence watermark, recent 10 verbatim accepted turns and at most 20 evicted turns awaiting summary.
Compact 10 evictions per asynchronous task after event publication; never await provider I/O under
room locks. A deterministic backpressure digest keeps overflow bounded if scheduling stalls.

Commits compare watermark and generation. Out-of-order signed completion invalidates captured
batches; completion older than the summary watermark rebuilds from the bounded canonical transcript.
Room identity/liveness checks prevent cross-room commits or resurrection after end/expiry.

The digest retains at most 3,000 characters, prioritizing questions, corrections and recent topic
facts with speaker/source/sequence attribution. Greetings are omitted. This is lossy extraction,
not a semantic model summary: open-question resolution and superseded facts are not inferred.
No optional model summarizer is enabled without comparative quality/cost evidence.

Assembler projection: summary + overflow + recent 10 + aliases. Critic projection: up to 1,000
summary characters, latest two recent turns and latest two overflow turns. Context budgets default
to conservative JSON byte/token upper bounds of 8,000 and 3,000 respectively. These are context-only
caps; evidence/schema/output and retries are separately bounded and included in provider spend
reservations. For extreme text/Unicode sizes, projections mark shortened text as excerpts; canonical
messages and stored recent 10 remain verbatim. Provider usage metadata supplies actual token metrics.

## Cancellation and privacy

One signed message per room and global application/provider semaphores bound work. Terminal state
is cached before incremental publication. End, idle/absolute expiry and shutdown share one erasure
path, including history/summary/overflow, credentials, tasks, producer locks and replay. Synchronous
SDK calls already in flight retain their provider permits until timeout/return; their request buffers
can remain until then, and their output cannot be committed. Provider retention is not local erasure.

Exactly one process, worker and replica is required. Restart loses all rooms. Scaling/restart
survival requires a separate reviewed ephemeral shared-store design with atomic deletion and replay.

## Security, spend and latency controls (2026-09-15)

Production rejects wildcard/non-HTTPS origins and DEBUG logging. Private headers cover diagnostics
and errors; the formatter drops external SDK/access messages, arbitrary extras and exception text.
Body collection has a deadline and coalesced bounded buffers. Socket admission limits open peers
and attempts before authentication. Uvicorn explicitly disables forwarded-IP trust, access logging
and WebSocket compression, and bounds receive queues. Edge client-IP controls need hosted testing.

A short shared lock admits provider reservations against request, room, hourly and deployment
balances. Context variables carry ephemeral spend scopes into threads; capabilities are never
provider metadata. End closes/zeros room balances, and late settlement cannot recreate them.
Production persists only numeric total/hourly charges atomically before dispatch, with a single
writer lock. Unknown/in-flight calls retain their maximum charge after restart. Missing/corrupt/
unwritable journals fail closed. Operators must preserve/reconcile the volume and account-wide costs.

SDK attempts default to one; higher attempts reserve and conservatively charge unknown retries.
Reused clients/pools/prompts and stage metrics cover input/output/cache token classes, revisions,
context bounds and p50/p95 over at most 2,048 timing samples. See [runbook](HOSTED_VERIFICATION.md).
