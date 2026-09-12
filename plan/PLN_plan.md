**SIMPLYNEXT BACKEND IMPLEMENTATION PLAN**

# METADATA

| Field | Value |
| :---- | :---- |
| **Code** | `PLN` |
| **Status** | Local backend complete; production delivery in progress |
| **Last reviewed** | 2026-09-07 |
| **Implemented source of truth** | `src/simplynext/` and `tests/` |
| **Production execution** | Local Git-ignored `plan/BPP_backend_production_plan.md` workbook |

# 1. OBJECTIVE

Deliver a backend that accepts the client's frozen GlossLattice v1 recognition output and returns
either evidence-grounded caption/TTS text or an explicit signer repair. The backend must remain
bounded, replay-safe, observable, and fail closed when evidence, model output, capacity, or external
services are unsafe.

# 2. CURRENT COMPLETION STATEMENT

The repository now contains a complete **local backend vertical slice**, not yet a complete hosted
product. All code required to negotiate a session, accept an authenticated lattice, apply policy,
run deterministic or Bedrock-backed graph nodes, and emit a terminal event is present. Test doubles
prove Bedrock request/response handling without live AWS spend.

The following claims remain intentionally unmade until production gates run:

- that the configured AWS identity can invoke the chosen Bedrock model live;
- that a release image is vulnerability-clear under the blocking CRITICAL/HIGH policy (the
  hardened image builds and its deterministic protocol smokes pass; Docker Scout currently reports
  one unfixable HIGH zlib finding);
- that Railway health, WSS, secrets, restart, and rollback behavior has passed;
- that the actual mobile client can negotiate, stream, recover, render, and speak results.

# 3. IMPLEMENTED BASELINE

## 3.1. Contract and transport

- GlossLattice schema `1.0` and server event schema `1.0` are strict and frozen.
- Session negotiation binds language and exact producer metadata.
- Bearer capabilities are random, returned once, hashed at rest, and checked in constant time.
- WebSocket messages are UTF-8 JSON only and capped at 32 KiB.
- New lattice sequences increase monotonically; identical retries replay the cached terminal event.
- Conflicting retries, excess rate/quota, parallel work, and invalid repair continuations fail
  explicitly.
- Ack, activity, terminal, pong, error, idle, and close behavior is covered by end-to-end tests.

## 3.2. Translation and safety

- Language, producer, unresolved evidence, OOV, confidence, and top-k margin gates execute before
  a model call.
- Deterministic mode maps only exact configured gloss tuples to text.
- Bedrock mode provides separate assembler and critic calls through one guarded Converse client.
- Model JSON is size-bounded, strictly parsed, and grounded to exact lattice evidence.
- The critic assesses each surface token and cannot rewrite the draft.
- Unsupported output receives at most one bounded assembler revision, then deterministic repair.
- Confident output and repair are mutually exclusive contracts.
- Bedrock startup preflight, timeouts, retries, prompt caching, token accounting, and a process-local
  spend ceiling are implemented and unit tested.

## 3.3. Module map

This is the authoritative current folder structure. It deliberately uses the `src/simplynext/`
package namespace.

```text
src/simplynext/
├── __init__.py
├── config.py                     environment-backed Settings
├── main.py                       FastAPI application factory and one-worker runner
├── runtime.py                    runtime service container
├── lattice_runtime.py            policy, graph composition, terminal-event mapping
├── contracts/
│   ├── common.py                 shared strict types
│   ├── gloss_lattice.py          lattice ingress v1
│   ├── sessions.py               negotiation and controls
│   └── events.py                 outbound event union
├── sessions/
│   ├── store.py                  in-memory auth, order, quota, repair and replay state
│   └── lattice_repair.py         repair-continuation rules
├── api/
│   ├── middleware.py             HTTP body limit
│   ├── routes.py                 health, readiness, metrics, session HTTP routes
│   └── lattice_websocket.py      authenticated lattice stream
├── agent/
│   ├── state.py                  bounded typed graph state
│   ├── graph.py                  graph topology and tool boundary
│   ├── assembler.py              draft contract and Bedrock assembler
│   ├── critic.py                 token-grounding critic
│   ├── repair.py                 deterministic repair policy
│   ├── adapter.py                confirmed memory adaptation
│   ├── bedrock_access.py         Bedrock clients, preflight, pricing, cache and budget guard
│   ├── anthropic_access.py       direct Anthropic Messages adapter using the same node shape
│   ├── prompts/
│   │   ├── assembler_v1.txt
│   │   └── critic_v1.txt
│   └── tools/
│       ├── context.py
│       ├── lexicon.py
│       └── memory.py
└── observability/
    ├── logging.py                payload-free JSON logs
    └── metrics.py                in-process counters and timings
```

`tests/` mirrors these concerns with contract, state, graph, tool, Bedrock, session, runtime, API,
transport, repair, replay, and safety coverage. `data/caption_templates.example.json` is the
deterministic no-spend example. `scripts/protocol_smoke.py` is the explicit Phase 1 HTTP/WebSocket
verification client and uses the two non-sensitive `tests/fixtures/live_bedrock_*_v1.json` inputs.

## 3.4. Runtime routes

| Route | Implemented behavior |
| :---- | :------------------- |
| `GET /healthz` | Process liveness; always independent of assembler readiness |
| `GET /readyz` | `200` only when the selected assembler mode is configured |
| `GET /metrics` | Process-local counters and timing snapshots |
| `POST /v1/sessions` | Exact language/producer negotiation and bearer creation |
| `DELETE /v1/sessions/{id}` | Authenticated session erasure |
| `WS /v1/sessions/{id}/lattices` | Authenticated lattice/control ingress and event egress |

# 4. COMPLETED IMPLEMENTATION MILESTONES

## 4.1. Baseline and isolation — complete

- The integration branch was created from the backend baseline.
- Python 3.12 virtual environments and clean dependency installation were proven.
- Package metadata, console entry point, strict static analysis, and isolated packaging checks were
  established.

## 4.2. Frozen contracts — complete

- The imported contract ideas were reimplemented as owned package modules.
- Structural, semantic, size, timeline, provenance, and evidence invariants have executable tests.
- The single client/server boundary is documented in `plan/CTR_contracts.md`.

## 4.3. Agent graph — complete locally

- Typed state, reducers, thread/signer isolation, bounded retry routing, independent assembler and
  critic, deterministic repair, confirmed adapter, and default-deny tools are implemented.
- Prompts are versioned package resources and validated when loaded.
- Real model calls are isolated behind injectable protocols and the cost-guarded client.

## 4.4. Runtime wiring — complete locally

- FastAPI lifespan owns one session store, graph, metrics registry, concurrency semaphore, and
  selected assembler mode.
- Transport commits a terminal event before delivery so disconnection can replay safely.
- All failures either emit a protocol error or cache a safe repair; uncached speculative text is
  never emitted.

## 4.5. Vertical-slice proof — complete locally

- Deterministic happy path, ambiguous/low-confidence repair, replay, invalid contract, session
  auth, limits, cancellation, graph failure, and mocked Bedrock flows are tested.
- Latest baseline: 165 passing tests, Ruff clean, strict mypy clean for 38 source/script files, `pip check`
  clean, and normal-wheel import/resource smoke verified.

## 4.6. Backend scope cleanup — complete

- Server-side recognition and landmark ingestion modules/routes/contracts/tests were removed.
- NumPy and the former recognition dependency closure were removed from the package and lock.
- The client is now the only recognition producer; the backend accepts GlossLattice only.

# 5. REMAINING PRODUCTION MILESTONES

The four milestones below are mandatory and sequential. The release operator's local, Git-ignored
`plan/BPP_backend_production_plan.md` provides detailed commands, manual inputs, controls, and
success criteria without publishing infrastructure values.

## 5.1. Live AWS Bedrock verification — tooling complete; operator run pending

Use an approved AWS identity and region to prove control-plane profile access, one minimal runtime
Converse request, the real assembler/critic path, usage/cost metrics, and spend-guard rejection.
Record model ID, region, identity owner, access expiry, verified token rates, and evidence of success
without recording prompts or user content.

The opt-in `scripts/protocol_smoke.py` command, non-sensitive confident/repair fixtures, startup
preflight composition tests, and pre-dispatch budget rejection proof are implemented. The command
requires an explicit live-spend flag and emits only redacted control results and metric deltas. The
live AWS claim remains pending until an operator injects the account-specific values listed in the
local BPP and records a successful run.

## 5.2. Production packaging — implementation and local Docker verification complete; release scan pending

Phase 2 packaging is implemented in the root `Dockerfile`, `.dockerignore`, `Makefile`, and
operational scripts. The multi-stage Python 3.12 image installs the normal distribution with
production dependencies only, runs as `simplynext`, includes packaged prompts and deterministic
fallback data, binds Railway's injected `PORT` on `0.0.0.0`, and starts one `simplynext-api`
worker. The Linux lock workflow, installed-package resource smoke, container protocol smoke, and
release-evidence/vulnerability policy are committed. The final local image build and both port smokes
pass. The image is 86 MB, runs as the unprivileged `simplynext` UID/GID 999, and has no runtime
`pip` executable. Docker Scout found one HIGH, currently unfixable Debian `zlib` CVE-2026-85091;
the release-evidence target correctly blocks on that finding. Sign this milestone only after a
base-image refresh resolves it or the release owner records a time-bounded, risk-accepted exception
under the existing policy.

## 5.3. Hosting controls — application implementation complete; Railway operator run pending

The service now fails closed for a production public surface: `/docs`, `/redoc`, and
`/openapi.json` are disabled by default; optional operator documentation and `/metrics` use separate
bearer credentials; `TrustedHostMiddleware` enforces an explicit host allow-list; global session
creation is bounded; and startup logs emit modes and numeric limits without secrets. The app does
not consume forwarded client-IP headers for security decisions. These controls are covered by the
API/config/session tests.

The release operator must still deploy the reviewed image to one Railway replica and one worker,
set `SIMPLYNEXT_ENVIRONMENT=production`, exact `SIMPLYNEXT_ALLOWED_HOSTS` and browser origins,
configure `/readyz` health, HTTPS/WSS, restart draining (`RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30`),
external monitoring/alerts, and restart/rollback evidence. With the current direct Anthropic mode,
inject sealed `ANTHROPIC_API_KEY` and the four verified Anthropic token prices instead of AWS
credentials. Enable hosted spend only after the public smoke and rollback drills pass.

## 5.4. Client integration — pending

Generate client models from the frozen contract, negotiate a session, keep the capability in
memory, open WSS with authorization, stream monotonic lattices, handle every event and close code,
perform repair continuation, render caption/evidence, invoke local TTS, and verify reconnect/replay
on a physical device.

# 6. RELEASE GATES

The backend may be called “working and hosted” only when all are true:

- all local quality and packaging gates pass from a clean clone;
- live Bedrock assembler and critic calls pass in the deployment region;
- the configured spend guard and AWS budget controls are active and owned;
- the Railway deployment listens on `0.0.0.0:$PORT` and `/readyz` is green;
- HTTPS session creation and authenticated WSS translation pass through the public domain;
- restart and rollback drills pass with documented session-loss behavior;
- `/metrics` and `/docs` are not unintentionally public;
- one physical client completes confident, repair, replay, ping, and end flows;
- logs contain no lattice text, credentials, bearer tokens, prompts, model output, or raw sensing
  data.

# 7. OUT-OF-SCOPE UNTIL AFTER THE FIRST HOSTED RELEASE

- server-side camera, landmark, segmentation, or classifier processing;
- multiple backend workers or Railway replicas;
- durable conversation memory;
- cross-replica session replay;
- raw Bedrock reasoning exposure;
- server-generated audio files;
- silently widening the frozen v1 contract.

# 8. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-07 | Implemented Phase 3 application hosting controls and documented the Railway operator runbook; public deployment evidence remains pending. |
| 2026-09-06 | Replaced the historical full-product plan with the implemented backend baseline and four remaining production milestones. |
