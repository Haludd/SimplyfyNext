**SIMPLYNEXT BACKEND ARCHITECTURE**

# METADATA

| Field | Value |
| :---- | :---- |
| **Code** | `ARC` |
| **Status** | Implemented local architecture; hosting work remains |
| **Last reviewed** | 2026-09-06 |
| **Source of truth** | `src/simplynext/` and `tests/` |
| **Contract** | `plan/CTR_contracts.md` |
| **Production plan** | `plan/PLN_plan.md`; local ignored BPP workbook when provisioned |

# 1. SCOPE AND INVARIANT

The backend accepts finalized recognition evidence, not camera or landmark data. The upstream
client owns capture, landmark extraction, segmentation, classification, top-k retention,
calibration, and signer repair collection. The backend owns contract validation, session safety,
translation assembly, grounding critique, confidence policy, repair selection, and result events.

The invariant is: **unsupported or uncertain content must not become a fluent sentence attributed
to the signer.** Every accepted lattice ends as either a grounded `lattice_result` or a
`lattice_repair_required` event containing no caption/TTS text.

# 2. SYSTEM BOUNDARY

```text
Flutter/mobile client                                SimplyNext Python backend
┌──────────────────────────────────────┐             ┌───────────────────────────────┐
│ camera → landmarks → classifier      │             │ FastAPI session negotiation   │
│ → calibrated GlossLattice v1         │ --JSON----> │ authenticated lattice socket   │
│ caption/TTS UI or repair interaction │ <---JSON--- │ policy + bounded AgentGraph    │
└──────────────────────────────────────┘             └───────────────┬───────────────┘
                                                                    │ compact text JSON
                                                                    v
                         Amazon Bedrock Converse or Anthropic Messages (optional)
```

Raw video, landmarks, embedding tensors, and audio do not cross the backend boundary. A hosted
provider receives only a bounded JSON representation of the accepted lattice and tool results; it
never receives camera data.

# 3. IMPLEMENTED MODULE MAP

The `src/simplynext/` directory is intentionally retained. `src/` is the build root and
`simplynext` is the package namespace.

| Module | Implemented responsibility |
| :----- | :------------------------- |
| `src/simplynext/config.py` | Strict environment-backed runtime, provider, policy, and budget settings |
| `src/simplynext/main.py` | FastAPI factory, lifespan, middleware, route mounting, one-worker runner |
| `src/simplynext/runtime.py` | Immutable process service container |
| `src/simplynext/lattice_runtime.py` | Producer/language/confidence policy, graph construction, terminal-event mapping |
| `src/simplynext/contracts/common.py` | Shared strict immutable contract primitives |
| `src/simplynext/contracts/gloss_lattice.py` | Ingress lattice, slot, candidate, provenance, and producer models |
| `src/simplynext/contracts/sessions.py` | Session negotiation and WebSocket control models |
| `src/simplynext/contracts/events.py` | Server acknowledgement, activity, pong, error, result, and repair events |
| `src/simplynext/sessions/store.py` | Bounded in-memory sessions, token hashing, stream claims, replay, quotas, ordering |
| `src/simplynext/sessions/lattice_repair.py` | Pending-repair continuation validation |
| `src/simplynext/api/routes.py` | Health, readiness, metrics, create-session, and delete-session HTTP routes |
| `src/simplynext/api/lattice_websocket.py` | Authenticated bounded stream, parsing, idempotency, backpressure, event emission |
| `src/simplynext/api/middleware.py` | HTTP request-body limit |
| `src/simplynext/agent/state.py` | Strict graph state, bounded history/memory reducers, loop state |
| `src/simplynext/agent/graph.py` | LangGraph topology, thread isolation, allow-listed tools, terminal run record |
| `src/simplynext/agent/assembler.py` | Grounded draft schema and optional Bedrock assembler node |
| `src/simplynext/agent/critic.py` | Independent token/evidence assessment and optional Bedrock critic node |
| `src/simplynext/agent/repair.py` | Deterministic non-speaking repair selection |
| `src/simplynext/agent/adapter.py` | Applies only explicitly confirmed, scoped memory changes |
| `src/simplynext/agent/bedrock_access.py` | AWS clients, preflight, pricing, prompt cache, usage accounting, spend guard |
| `src/simplynext/agent/anthropic_access.py` | Direct Anthropic Messages adapter normalized to the existing Converse-shaped node protocol |
| `src/simplynext/agent/tools/` | Read-only lexicon, conversation-memory, and context-hint tools |
| `src/simplynext/agent/prompts/` | Versioned assembler and critic system prompts |
| `src/simplynext/observability/` | Payload-free JSON logs and thread-safe in-process metrics |
| `scripts/protocol_smoke.py` | Explicit, payload-redacted HTTP/WebSocket Phase 1 verification client |
| `tests/fixtures/live_bedrock_*_v1.json` | Non-sensitive confident and pre-model-repair smoke inputs |

The root `main.py` exists only so a checkout can run before installation. Installed operation uses
the `simplynext-api` console command or `uvicorn simplynext.main:app`.

# 4. REQUEST LIFECYCLE

## 4.1. Session negotiation

1. The client sends `POST /v1/sessions` with language, client/detector metadata, and the exact
   classifier/calibration/vocabulary producer profile.
2. The server rejects a language or producer mismatch.
3. The in-memory store creates a UUID, a cryptographically random bearer token, expiration, and
   negotiated limits. Only the token digest is retained.
4. The response carries the session ID, opaque token, WebSocket path, expiry, and frozen limits.

## 4.2. Stream authentication and controls

1. The client opens `/v1/sessions/{session_id}/lattices` with `Authorization: Bearer <token>`.
2. The server validates the bearer capability and browser `Origin`, then permits one active stream
   per session.
3. Text JSON only is accepted. Binary, oversized, malformed, or cross-session messages fail
   explicitly; repeated invalid messages close the connection.
4. `ping` returns `pong`; `end` deletes the session and closes normally.

## 4.3. Lattice handling

1. Strict Pydantic models reject schema drift, bad chronology, invalid ranks/confidence,
   inconsistent provenance, duplicate slots/candidates, and payloads above 32 KiB.
2. `(session_id, lattice_seq)` and the canonical payload digest implement idempotency. An identical
   retry returns the cached terminal event; a conflicting retry fails.
3. Per-session and global rate limits, per-session quotas, one in-flight sequence, and a bounded
   agent semaphore protect the runtime.
4. The policy checks language, producer identity, unresolved slots, `UNKNOWN`/`OOV`, minimum
   confidence, and the top-1/top-2 margin before any model call.
5. The graph runs only after those checks pass.
6. The terminal event is cached atomically before the connection returns to idle.

# 5. AGENT GRAPH

```text
START → assembler → critic ──supported────────────→ confident → adapter → END
                    │
                    ├─unsupported + revision left→ increment → assembler
                    │
                    └─unsupported + cap reached──→ repair ───→ adapter → END
```

The current revision cap is zero or one; configuration rejects values above one. Graph invocations
are isolated by a mandatory `lattice:{session_id}:{signer_id}` thread identifier and a per-thread
non-blocking lock.

The graph should not be described as four independent AI agents:

- **Assembler** — a model-backed node in Bedrock mode, or exact template renderer in deterministic
  mode. It emits a strict draft split into grounded text parts and explicit gaps.
- **Critic** — a separate model-backed node in Bedrock mode, or deterministic validator. It checks
  every whitespace-delimited candidate token against declared lattice evidence and cannot rewrite.
- **Confident node** — deterministic application code, not a model. It can publish only a validated,
  gap-free, critic-approved draft.
- **Repair node** — deterministic application code, not a model. It selects `ask_repeat`,
  `request_fingerspelling`, `offer_top_k`, or `escalate_human_interpreter` without generating text.
- **Adapter** — deterministic post-terminal logic. It applies only explicit, validated memory
  adaptation requests; current runtime data is process-local.

The two model prompts are versioned in `src/simplynext/agent/prompts/assembler_v1.txt` and
`src/simplynext/agent/prompts/critic_v1.txt`. Their Python loaders verify mandatory safety
fragments at startup.

# 6. EXECUTION MODES

| Mode | Trigger | Behavior | Readiness |
| :--- | :------ | :------- | :-------- |
| Deterministic | `SIMPLYNEXT_BEDROCK_ENABLED=false` and `SIMPLYNEXT_ANTHROPIC_ENABLED=false` | Exact gloss tuple → committed caption template; misses become gaps/repair | Ready only when a valid template file loads |
| Bedrock | `SIMPLYNEXT_BEDROCK_ENABLED=true` | Guarded Converse assembler and separate critic calls | Startup performs control-plane and minimal runtime preflight |
| Anthropic | `SIMPLYNEXT_ANTHROPIC_ENABLED=true` | Guarded Messages API assembler and separate critic calls | Startup performs minimal runtime preflight; key comes from `ANTHROPIC_API_KEY` |

Bedrock mode requires a named lease owner, an explicit local spend ceiling below US$20, current
known spend, matching per-token price inputs, region/model configuration, and credentials supplied
through Boto3's standard provider chain. A conservative cost is reserved before every call. Missing
or untrustworthy usage accounting is charged at the reservation and fails closed.

The process-level ceiling is a safety switch, not AWS account-wide billing enforcement. Hosted
credentials, model access, pricing, and account alarms remain operator responsibilities.

# 7. OUTPUT CONTRACT

All stream messages are JSON. For each newly accepted lattice the normal sequence is:

1. `lattice_ack` (`accepted` or `cached`);
2. `activity: processing` for a new computation;
3. exactly one terminal `lattice_result` or `lattice_repair_required`;
4. `activity: idle`.

A confident result includes `caption`, optional `tts_text`, scalar confidence,
`gloss_id_trace`, complete `evidence_trace`, producer version, model/source identity, and latency.
The client performs TTS locally. A repair event includes an action, message, target slots, retained
choices when applicable, reasons, evidence, and no fluent output fields.

# 8. STATE, AVAILABILITY, AND SCALING

Sessions, replay events, rate buckets, graph checkpoints, metrics, and the hosted-provider spend ledger are
in process memory. Restarting the process invalidates sessions and clears those counters. Multiple
workers or replicas would split state and can route a session to the wrong process.

The first hosted release therefore requires exactly one Uvicorn worker and one Railway replica.
Horizontal scaling is blocked until the following are externalized atomically:

- session/token/stream ownership;
- lattice reservations and cached terminal events;
- sequence, quota, and rate-limit state;
- graph checkpoints and thread locks;
- global concurrency and hosted-provider budget accounting;
- durable metrics/alerting.

# 9. SECURITY AND PRIVACY CONTROLS

Implemented controls:

- strict schemas and unknown-field rejection;
- 256 KiB HTTP and 32 KiB lattice message limits;
- opaque bearer session capabilities stored as hashes;
- constant-time token comparison;
- browser-origin allow-list;
- bounded session count, TTL, rate, quota, concurrency, queue time, socket idle time, model retries,
  model read/connect timeouts, output tokens, tool calls, and graph revisions;
- default-deny model tool executor with only read-only, state-scoped tools;
- no payload, prompt, response, token, or credential logging;
- fail-closed error mapping.

Phase 3 application controls now implemented before untrusted public traffic:

- production disables `/docs`, `/redoc`, and `/openapi.json` by default; any operator override is
  bearer-protected with a dedicated credential;
- `/metrics` requires its own operator bearer credential in production;
- `TrustedHostMiddleware` enforces an explicit production host allow-list;
- global session creation is bounded and rate-limit outcomes are counted;
- startup logs expose modes and numeric limits without secrets;
- no forwarded client-IP header is trusted by the application.

Railway-side controls still require operator evidence: continuous monitoring/alerting, credential
rotation and incident response, browser-origin/TLS validation, a public abuse/load test, and
restart/rollback drills.

# 10. OBSERVABILITY

The service writes one-line JSON logs to standard output. Logs contain correlation and outcome
metadata but no lattice content. `/metrics` exposes process-local counters and timing aggregates,
including sessions, WebSockets, invalid/oversized payloads, replay, queueing, terminal outcomes,
tool calls, repairs, Bedrock calls/tokens/cost, and major latency stages.

This is adequate for local verification. Production requires controlled access to metrics,
Railway log retention/alerting, and an external uptime monitor because the current endpoint is not
a durable metrics backend.

# 11. VERIFIED AND UNVERIFIED CLAIMS

Verified locally as of 2026-09-06:

- 165 tests pass;
- Ruff passes;
- strict mypy passes for 38 source/script files;
- `pip check` passes;
- locked editable and normal wheel installs succeed;
- the payload-redacted smoke client passes end to end against a local deterministic server;
- the normal wheel package smoke reads both prompts and deterministic templates outside the checkout;
- the removed landmark backend has no production references.

Not yet verified:

- live AWS Bedrock access and real model output;
- vulnerability-clear production release status: the final Docker image and both Railway `PORT`
  smokes pass, but Docker Scout reports one currently unfixable HIGH zlib CVE-2026-85091;
- Railway health, restart, WSS, secrets, and rollback behavior;
- the actual client session/WebSocket integration;
- sustained load, fault injection, or production security review.

# 12. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-07 | Added production diagnostics lockdown, operator authentication, host allow-listing, global session-creation limiting, and startup configuration summary. |
| 2026-09-07 | Added direct Anthropic mode and documented Phase 2 packaging/PORT/release evidence workflow. |
| 2026-09-06 | Added Phase 1 smoke tooling status and refreshed the local verification baseline. |
| 2026-09-06 | Rewritten from the implemented GlossLattice-only backend; module map and production gaps corrected. |
