# SimplyNext backend

Temporary two-person text/sign rooms with grounded ASL word-to-sentence translation.
The frontend owns recognition, word translation, camera/audio and speech-to-text. This service
accepts finalized `TranslatedSignUtterance v1` words or finalized typed/speech text.

## Implemented

- Strict ASL-only ingress, two participant capabilities, exact sequence/digest replay, bounded
  HTTP/WebSocket transport and incremental terminal events.
- Immediate signed HTTP 202 admission, then an independent assembler and critic with at most
  one revision. Hearing text, controls, retries and rejected evidence make no model calls.
- Room-owned accepted transcript, recent 10 turns, batched extractive summary, bounded overflow,
  immutable context and separate assembler/critic prompt budgets.
- Topic-change-aware sentence acceptance, lexical grounding and a version-bound production
  evaluation gate. See [acceptance policy](plan/WORD_ACCEPTANCE_POLICY.md).
- End/expiry/shutdown erase all room-owned content, credentials, replay and pending work.
  Already-issued synchronous provider calls finish under SDK timeouts and their results are discarded.
- Request/room/hour/deployment spend reservations; production persists only numeric spend totals
  so restart cannot reset the allowance.
- Exact production HTTPS origins, bounded unauthenticated sockets/body reads, explicit proxy
  distrust, private headers, content-free logs and rolling p50/p95 stage measurements.

Milestones 2–3 and the backend removal exit of milestone 4 are implemented. Frontend execution,
owner sign-off, representative producer/model qualification and hosted/mobile verification remain
external acceptance work. The retired session routes return 404. The frozen ingress/events did not change.

## Run locally

Use Python 3.12 (supported range 3.11–3.13) and an editable development install:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'
cp .env.example .env
python main.py
python scripts/room_protocol_smoke.py --base-url http://127.0.0.1:8000
```

The default supports typed chat and safe signed repair with no API spending. For a synthetic
accepted-sentence demo, disable hosted providers and configure:

```bash
SIMPLYNEXT_ENVIRONMENT=development \
SIMPLYNEXT_RECOGNITION_LANGUAGE=asl \
SIMPLYNEXT_BEDROCK_ENABLED=false SIMPLYNEXT_ANTHROPIC_ENABLED=false \
SIMPLYNEXT_WORD_POLICY_PATH=data/word_policy.synthetic.json \
SIMPLYNEXT_WORD_TEMPLATES_PATH=data/word_templates.example.json \
python main.py
python scripts/room_protocol_smoke.py --base-url http://127.0.0.1:8000 --templates
```

Templates accept reviewed exact sentences only with empty history; contextual judgments require
an independent provider critic. The synthetic profile cannot qualify production.
Old local environment files must set `SIMPLYNEXT_RECOGNITION_LANGUAGE=asl` and remove retired
session/classifier/caption-template settings. No legacy payload is converted internally.

## API and client handoff

| Surface | Purpose |
| --- | --- |
| `GET /healthz`, `GET /readyz` | Process and room readiness; reports sentence acceptance separately |
| `POST /v1/rooms`, `POST /v1/rooms/join` | Create/join a two-person room |
| `GET /v1/rooms/{code}` | Authenticated full bounded recovery snapshot |
| `POST /v1/rooms/{code}/messages` | Final typed/speech text |
| `POST /v1/rooms/{code}/sign-utterances` | Immediate 202 signed admission |
| `WS /v1/rooms/{code}/events` | First-packet authentication, snapshots, incremental events |
| `DELETE /v1/rooms/{code}` | Either participant ends and erases the room |

[WORD_ROOM_V1.md](plan/WORD_ROOM_V1.md) specifies inputs, events, retry/recovery and deletion.
Generated models are in `client/`; package schemas and canonical/invalid fixtures have a drift check.
QR invitations contain only the public join path and room code; never embed capabilities.

## Provider and deployment controls

Both providers default off. Choose one: direct Anthropic (`ANTHROPIC_API_KEY` injected as a secret)
or Bedrock (standard AWS credential chain). Require the explicit lease owner, verified model prices,
timeout/retry limits and spend ceiling in `.env.example`. Both use the shared cost guard and access
preflight. Startup with a hosted provider can incur the small guarded preflight request.
Production sentence acceptance also requires matching `SIMPLYNEXT_WORD_POLICY_PATH` and
`SIMPLYNEXT_WORD_EVALUATION_PATH`; invalid qualification fails before provider initialization.
No configured policy means safe no-spend repair for signed requests, with typed rooms available.

Deploy exactly one worker and one replica. State is memory-only and restart loses active rooms.
Use HTTPS/WSS, exact allowed origins/hosts, Railway's injected `PORT`, `/readyz`, and external
monitoring. Public docs are disabled in production; `/metrics` needs the separate operator token.
Access logging is disabled by the runner to avoid request URLs in service logs. Do not enable SDK
wire debugging. Provider retention is separate from room deletion.

[Hosted verification preparation](plan/HOSTED_VERIFICATION.md) supplies the production profile,
Railway manifest, spend-volume setup, no-network configuration gate and device matrix.
Root `PLN_plan_v1.md` section 14 tracks frontend/producer/operator acceptance. A blocking image
vulnerability scan prevents release even when local tests pass. Preparation does not deploy or
enable a live provider.

```bash
make docker-build IMAGE=simplynext-backend:local
make container-smoke IMAGE=simplynext-backend:local
make container-smoke-nondefault IMAGE=simplynext-backend:local
```

No hosted deployment or physical-device result is implied by local container checks. Before release,
run the vulnerability/evidence gate from a clean reviewed commit and verify real two-device WSS,
QR, reconnect, termination, expiry, restart and rollback behavior.

## Quality gates

```bash
python -m pytest -q
python -m ruff check .
python -m mypy src scripts
python -m pip check
python scripts/export_word_contract.py --check
```

Packaging changes also require a normal wheel installed in a clean temporary environment and
`scripts/package_smoke.py data/word_templates.example.json` run outside the checkout.

## Documents

- [Architecture](plan/ARC_architecture.md), [contracts](plan/CTR_contracts.md),
  [implementation status](plan/PLN_plan.md), [dependency policy](plan/DEP_dependencies.md).
- Root `CODEX_PROMPT.md`, `PLN_plan_v1.md`, `TRANSLATED_SIGN_UTTERANCE_V1.md` and `UPDATE_LOG.md`
  govern this implementation round.
- The ignored `plan/BPP_backend_production_plan.md` is a private historical operator workbook;
  reconcile it with this runtime before operating. Never commit filled secret/hosting values.
