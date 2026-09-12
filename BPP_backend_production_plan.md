**SIMPLYNEXT BACKEND PRODUCTION PLAN**

> **Integration layout:** Run backend commands from `backend/`. Shared plan
> documents remain in the repository-root `plan/` directory.

# METADATA

| Field | Value |
| :---- | :---- |
| **Code** | `BPP` |
| **Status** | Local sensitive workbook; Git-ignored; all four production phases pending |
| **Last reviewed** | 2026-09-06 |
| **Target** | One Railway-hosted API service calling Amazon Bedrock |
| **Prerequisite** | Local backend and quality gates in `plan/PLN_plan.md` |

# 1. OUTCOME AND DEPLOYMENT DECISION

The first hosted topology is:

```text
mobile client ──HTTPS/WSS──> Railway: SimplyNext FastAPI (1 replica, 1 worker)
                                      │
                                      └──TLS/AWS SDK──> Amazon Bedrock Converse
```

Railway hosts the backend process, public TLS domain, deployment, and logs. AWS hosts only the
Bedrock inference endpoint and AWS-side identity/budget controls. The service is not “production
ready” merely because it starts on Railway; all four phases and release gates below must pass.

The one-replica/one-worker limit is mandatory for the current code. Session ownership, replay,
rate buckets, graph checkpoints, metrics, and model spend state are process-local. Railway does not
provide sticky sessions, so replicas cannot be increased until that state is externalized.

# 2. MANUAL INPUT WORKSHEET

## 2.1. Instructions

An accountable operator must collect these values before implementation. Record names, IDs, dates,
and non-secret decisions in the local values table below. Place actual credential values only in
the local shell or Railway's sealed-variable UI.

| Required input | Manual source/action | Where it is entered |
| :------------- | :------------------- | :------------------ |
| Release commit SHA and branch | Select the reviewed commit on `integration/gloss-lattice-only` or its release branch | Railway service source and release record |
| AWS account/sandbox ID | Confirm in AWS console or `aws sts get-caller-identity` | Release record only |
| Bedrock lease owner | Name one person responsible for credentials and spend | `SIMPLYNEXT_BEDROCK_LEASE_OWNER` |
| AWS Region | Confirm the selected inference profile/model is callable there | `SIMPLYNEXT_AWS_REGION`; align `AWS_DEFAULT_REGION` when used |
| Bedrock model/inference profile ID | Copy exactly from the Bedrock model catalog/profile | `SIMPLYNEXT_BEDROCK_MODEL_ID` |
| Four current token rates | Verify input, output, cache-write, and cache-read rates for that exact ID/region | Four `SIMPLYNEXT_BEDROCK_*_USD_PER_MILLION_TOKENS` variables |
| Known account spend | Check immediately before each release/demo | `SIMPLYNEXT_BEDROCK_KNOWN_SPEND_USD` |
| Local process ceiling | Select a value with headroom below the AWS/account cap; code requires `<20.00` | `SIMPLYNEXT_BEDROCK_SPEND_LIMIT_USD` |
| Runtime AWS identity | Obtain least-privilege temporary credentials or an approved refreshable external-workload identity | Standard AWS credential provider chain; never a `SIMPLYNEXT_*` setting |
| Credential expiration/rotation owner | Record exact expiry and refresh procedure | Secret-management runbook |
| AWS budget alarm | Create/verify threshold and recipients in AWS Billing | AWS console; record alarm name only |
| Recognition language | Choose `sgsl` or `asl`; it must match the client | `SIMPLYNEXT_RECOGNITION_LANGUAGE` |
| Producer identity | Copy exact classifier, classifier version, calibration version, and vocabulary version from the released client | Four `SIMPLYNEXT_LATTICE_*` variables |
| Client web origin, if any | Copy exact HTTPS origin(s), comma-separated; mobile apps normally omit `Origin` | `SIMPLYNEXT_ALLOWED_ORIGINS` |
| Railway project/service/environment | Create or select the production resources | Railway dashboard/release record |
| Railway region and size | Select Singapore/nearest client region and measured CPU/RAM | Railway service settings |
| Public hostname | Generate Railway domain first; add custom domain later if required | Client environment and smoke tests |
| Diagnostic access owner | Decide who may view metrics/docs and how monitoring authenticates | Application config and monitoring service |

This complete file is intentionally excluded by `.gitignore`. Do not force-add it. Ignoring the file
does not make raw secrets safe to store in Markdown: local backups, editor history, indexing, and
screen sharing can still expose them. Never paste AWS secret keys, session tokens, certificates,
private keys, client bearer tokens, or live lattice content into this table.

## 2.2. Values

Fill the second column locally. Use exact values rather than descriptions or placeholders. For
credentials, record only the method, principal identity, storage confirmation, owner, and expiry;
enter the secret material directly into its approved destination.

| Key | Value to be keyed in locally | Required check/format |
| :-- | :--------------------------- | :-------------------- |
| Worksheet updated at |  | ISO-8601 date/time with timezone |
| Release branch | integration/gloss-lattice-only | Exact Git branch |
| Release commit SHA |  | Full reviewed Git SHA |
| AWS account/sandbox ID |  | 12-digit account ID; not a root identity |
| AWS principal ARN |  | Exact ARN returned by `aws sts get-caller-identity` |
| Bedrock lease owner |  | Accountable person's name |
| `SIMPLYNEXT_AWS_REGION` |  | AWS Region containing/calling the selected profile |
| `AWS_DEFAULT_REGION` |  | Must agree with the approved Region when set |
| `SIMPLYNEXT_BEDROCK_MODEL_ID` |  | Exact active foundation-model or inference-profile ID |
| Model access verified at |  | ISO-8601 date/time with timezone |
| Anthropic first-time-use complete |  | `yes`, `no`, or `not_applicable` |
| `SIMPLYNEXT_BEDROCK_INPUT_USD_PER_MILLION_TOKENS` |  | Verified decimal rate for exact model/profile |
| `SIMPLYNEXT_BEDROCK_OUTPUT_USD_PER_MILLION_TOKENS` |  | Verified decimal rate for exact model/profile |
| `SIMPLYNEXT_BEDROCK_CACHE_WRITE_USD_PER_MILLION_TOKENS` |  | Verified decimal rate for exact model/profile |
| `SIMPLYNEXT_BEDROCK_CACHE_READ_USD_PER_MILLION_TOKENS` |  | Verified decimal rate for exact model/profile |
| Pricing verified at |  | ISO-8601 date/time with timezone and source URL |
| `SIMPLYNEXT_BEDROCK_KNOWN_SPEND_USD` |  | Fresh decimal account spend |
| Known spend checked at |  | ISO-8601 date/time with timezone |
| `SIMPLYNEXT_BEDROCK_SPEND_LIMIT_USD` |  | Decimal greater than zero and less than `20.00` |
| AWS budget alarm name |  | Exact AWS alarm/budget name |
| AWS budget threshold |  | Decimal USD threshold |
| AWS budget recipient/owner |  | Named monitored contact |
| AWS credential method |  | `sso`, `temporary_sts`, `roles_anywhere`, or `aws_compute_role` |
| Credential destination |  | Local shell/profile or Railway sealed variables; no raw secret here |
| Credential material installed |  | `yes` or `no`; enter secrets only in the destination above |
| Credential expiry |  | ISO-8601 date/time with timezone, or `automatic_refresh` |
| Credential rotation owner |  | Named accountable person |
| `SIMPLYNEXT_RECOGNITION_LANGUAGE` | asl | Exactly `sgsl` or `asl`; must match released client |
| `SIMPLYNEXT_LATTICE_CLASSIFIER_ID` |  | Exact released-client value |
| `SIMPLYNEXT_LATTICE_CLASSIFIER_VERSION` |  | Exact released-client value |
| `SIMPLYNEXT_LATTICE_CALIBRATION_VERSION` |  | Exact released-client value |
| `SIMPLYNEXT_LATTICE_VOCABULARY_VERSION` |  | Exact released-client value |
| `SIMPLYNEXT_ALLOWED_ORIGINS` |  | Exact comma-separated HTTPS browser origins; state `native_only` if none |
| Railway project | SimplifyNext_Hackathon; dc8c49f1-2beb-45e7-a62b-6173fa130bcd | Exact name and project ID |
| Railway service | SignBridge; 2a62e182-9e0e-4431-a3c2-fa1ee1b10a01 | Exact name and service ID |
| Railway environment | production; 514394e9-9959-4cb6-8a6f-c6b96d831508 | Exact production environment name/ID |
| Railway source branch/SHA | integration/gloss-lattice-only | Must equal reviewed release branch/SHA |
| Railway region | Southeast Asia (Singapore, Singapore) | Selected region; first release should be nearest target clients |
| Railway CPU/RAM allocation | 8 vCPU; 8GB RAM | Measured service allocation |
| Railway replica count |  | Must be `1` until shared state is implemented |
| Uvicorn worker count | 1 | Must be `1` until shared state is implemented |
| Railway public hostname | signbridge-production-91dd.up.railway.app | Hostname only; HTTPS/WSS required |
| Custom hostname | not_configured | Exact hostname or `not_configured` |
| Diagnostics owner |  | Named person/team |
| Metrics protection method | not_public | Dedicated operator authentication or `not_public` |
| Production API docs enabled |  | Must be `no` unless explicitly approved |
| Continuous monitor name/URL |  | Monitor identifier; do not include secret query values |
| Client target platforms | ions, android | Exact released targets, for example `ios,android` |
| Release evidence location |  | Non-secret ticket/run identifier |
| Final operator sign-off |  | Name and ISO-8601 date/time |

# 3. PHASE 1 — LIVE AWS BEDROCK VERIFICATION

## 3.1. Objective

Prove the current Bedrock control-plane preflight, minimal billed runtime preflight, assembler,
critic, strict parsing, evidence grounding, usage accounting, and spend guard against the real AWS
account before introducing container or Railway variables.

## 3.2. AWS administrator actions

1. In the selected AWS account and region, open the Bedrock model catalog and confirm the exact
   configured model or inference profile is active.
2. For an Anthropic model, complete the first-time-use form. Confirm AWS Marketplace/payment
   prerequisites and accept the applicable terms before production invocation.
3. Grant the runtime identity only the operations the current code uses:
   `bedrock:GetInferenceProfile` for a regional/global inference profile or
   `bedrock:GetFoundationModel` for a foundation model, plus `bedrock:InvokeModel` for Converse.
   Scope the invocation resource to the selected model/profile ARN where the account policy permits;
   have the AWS administrator validate the final policy rather than copying a wildcard demo policy.
4. Create or verify the account-level budget/alert and name the recipient. The application ceiling
   supplements this; it is not a replacement for AWS billing controls.
5. Choose the credential path:

   - **Local verification:** AWS IAM Identity Center/SSO profile or temporary STS credentials.
   - **Short hosted demo:** the temporary access-key ID, secret, and session token may be entered as
     sealed Railway variables, but the service stops working when they expire and must be refreshed. GO WITH THIS ✅
   - **Unattended production:** use an approved automatically refreshing external-workload method
     such as IAM Roles Anywhere, or host the compute on AWS with an attached IAM role. Do not label
     a service dependent on manually refreshed credentials as unattended production.

AWS recommends temporary credentials instead of long-lived access keys. Boto3 already searches its
standard credential chain; the application deliberately does not accept credential fields.

## 3.3. Local operator actions

With `.venv` active, authenticate without writing credentials to the repository. For an SSO
profile:

```bash
aws sso login --profile <approved-profile>
export AWS_PROFILE=<approved-profile>
export AWS_DEFAULT_REGION=<approved-region>
aws sts get-caller-identity
```

For issued temporary credentials, export all three values in the current shell instead:

```bash
export AWS_ACCESS_KEY_ID=<temporary-access-key-id>
export AWS_SECRET_ACCESS_KEY=<temporary-secret-access-key>
export AWS_SESSION_TOKEN=<temporary-session-token>
export AWS_DEFAULT_REGION=<approved-region>
```

Then enter the non-secret application values in the local, ignored `.env`:

```dotenv
SIMPLYNEXT_ENVIRONMENT=development
SIMPLYNEXT_RECOGNITION_LANGUAGE=<sgsl-or-asl>
SIMPLYNEXT_LATTICE_CLASSIFIER_ID=<released-client-value>
SIMPLYNEXT_LATTICE_CLASSIFIER_VERSION=<released-client-value>
SIMPLYNEXT_LATTICE_CALIBRATION_VERSION=<released-client-value>
SIMPLYNEXT_LATTICE_VOCABULARY_VERSION=<released-client-value>
SIMPLYNEXT_BEDROCK_ENABLED=true
SIMPLYNEXT_AWS_REGION=<approved-region>
SIMPLYNEXT_BEDROCK_MODEL_ID=<exact-model-or-profile-id>
SIMPLYNEXT_BEDROCK_LEASE_OWNER=<accountable-name>
SIMPLYNEXT_BEDROCK_SPEND_LIMIT_USD=<approved-local-ceiling>
SIMPLYNEXT_BEDROCK_KNOWN_SPEND_USD=<fresh-account-spend>
SIMPLYNEXT_BEDROCK_INPUT_USD_PER_MILLION_TOKENS=<verified-rate>
SIMPLYNEXT_BEDROCK_OUTPUT_USD_PER_MILLION_TOKENS=<verified-rate>
SIMPLYNEXT_BEDROCK_CACHE_WRITE_USD_PER_MILLION_TOKENS=<verified-rate>
SIMPLYNEXT_BEDROCK_CACHE_READ_USD_PER_MILLION_TOKENS=<verified-rate>
```

The four committed rates are defaults, not proof of current price. Re-key verified values whenever
the model ID changes and immediately before a production release.

## 3.4. Implementation work

1. Add `scripts/protocol_smoke.py` with CLI arguments for base URL, language, and producer fields.
   It must create a session, open the returned socket with the bearer header, send a supplied
   lattice, validate every received event using the package models, issue `ping`, and end cleanly.
   It must redact tokens and payload text from output.
2. Add an opt-in `live_bedrock` pytest marker or a separate smoke command excluded from normal test
   runs. It must never run merely because credentials exist.
3. Create two non-sensitive live fixtures matching the released vocabulary:

   - a high-confidence utterance expected to pass assembler and critic;
   - an ambiguous or OOV utterance expected to repair before any model call.

4. Add a test that starts with a deliberately insufficient local ceiling and proves the guard
   rejects before dispatch. Use a fake client for the no-dispatch assertion; do not waste a live
   call to prove unit behavior.
5. Keep the current startup behavior: when Bedrock is enabled, construction verifies the active
   model/profile and performs one minimal, cost-accounted Converse call. Startup must fail rather
   than advertise readiness when either preflight fails.

## 3.5. Verification sequence

```bash
python -m pytest
python -m ruff check .
python -m mypy src
python -m pip check
python main.py
```

In a second shell, run the smoke command against `http://127.0.0.1:8000`, then inspect `/metrics`
and structured logs. Stop the service after evidence is captured.

## 3.6. Success criteria

- `aws sts get-caller-identity` resolves the intended account and non-root principal.
- Startup logs one successful control-plane and runtime preflight for the exact region/model.
- The high-confidence fixture produces a schema-valid `lattice_result` after real assembler and
  critic calls, with the exact input evidence trace.
- The uncertain fixture produces `lattice_repair_required` and does not increment model-call
  metrics.
- Bedrock input/output/cache token counters and estimated nano-USD cost increase consistently with
  provider usage metadata; prompts and response text are absent from logs.
- The no-headroom test raises the budget exception before client dispatch.
- Actual spend remains under both the application ceiling and AWS account budget.
- Region, model ID, pricing verification time, identity ARN, credential expiry, and test timestamp
  are recorded without secrets or user content.

# 4. PHASE 2 — PRODUCTION PACKAGING

## 4.1. Objective

Produce a small, non-root Python 3.12 Linux image that installs the real distribution, contains the
versioned prompts and deterministic fallback data, obeys Railway's `PORT`, and passes the full
protocol smoke without a source checkout or development dependencies.

## 4.2. Implementation work

1. Update `Settings`/the console runner to accept Railway's injected `PORT` while preserving
   `SIMPLYNEXT_PORT` for local use. Add precedence and range tests. Production must bind
   `0.0.0.0:$PORT` and continue using exactly one worker.
2. Add a root `Dockerfile`. It must:

   - use a pinned Python 3.12 slim base, ultimately pinned by immutable image digest;
   - build/install `simplynext-backend` as a normal package, not an editable checkout;
   - install production dependencies only;
   - create and run as an unprivileged user;
   - set unbuffered output and disable bytecode/cache writes where appropriate;
   - include package prompts and `data/caption_templates.example.json`;
   - start `simplynext-api` directly so it receives termination signals;
   - contain no `.env`, AWS credentials, tests, VCS data, local caches, or build toolchain in the
     final stage.

3. Add `.dockerignore` covering `.git`, virtual environments, caches, tests, local secrets, build
   output, non-runtime data, and editor files.
4. Create a Linux production lock or constraints workflow. The existing lock was resolved on macOS
   ARM and must not be treated as a Linux wheel lock. Pin the installer version, generate the
   production resolution in a Linux builder, review it, and fail CI on an unreviewed resolution
   change.
5. Add an image test that reads both prompt resources with `importlib.resources`/their configured
   paths, loads the deterministic template, and imports the package from outside the source tree.
6. Add a container smoke target that runs deterministic mode, checks `/healthz` and `/readyz`, then
   executes `scripts/protocol_smoke.py` for result, replay, ping, and end.
7. Emit release evidence: source SHA, image digest, Python/pip versions, dependency inventory, test
   results, and build timestamp. Scan the image for known vulnerabilities and define which severity
   blocks release.

Railway automatically detects a root file named `Dockerfile`; a custom path requires an explicit
platform variable. Its health checker uses the injected `PORT`, so application compatibility is a
release gate rather than a dashboard workaround.

## 4.3. Local verification sequence

```bash
docker build --pull -t simplynext-backend:<git-sha> .
docker run --rm -p 8000:8000 \
  -e PORT=8000 \
  -e SIMPLYNEXT_ENVIRONMENT=production \
  -e SIMPLYNEXT_HOST=0.0.0.0 \
  -e SIMPLYNEXT_CAPTION_TEMPLATES_PATH=/app/data/caption_templates.example.json \
  simplynext-backend:<git-sha>
```

Run the smoke script from another terminal. A separate container run with Bedrock enabled may use
temporary credentials only after Phase 1 passes; do not bake them into a layer or build argument.

## 4.4. Success criteria

- The build starts from a clean clone and produces the same reviewed dependency resolution.
- The final container runs as non-root and contains neither development tools nor secret files.
- `PORT=8000` and a second non-default port both work on `0.0.0.0`.
- `/healthz` is `200`; `/readyz` is `200` with a configured deterministic template and `503` when
  no assembler is configured.
- Result, repair, replay, ping, end, maximum-size rejection, and graceful `SIGTERM` behavior pass.
- Prompts and template data are readable after normal package installation.
- Image digest, inventory, scan, and all quality-gate results are attached to the release record.

# 5. PHASE 3 — RAILWAY HOSTING AND CONTROLS

## 5.1. Objective

Deploy the reviewed image once in deterministic mode, secure and observe the public surface, prove
restart/rollback/WSS, and only then enable Bedrock with an approved credential lifecycle.

## 5.2. Pre-public code controls

Implement and test these before generating a public domain:

1. Disable `/docs`, `/openapi.json`, and `/redoc` by default in production; allow an explicit
   operator-only override for troubleshooting.
2. Protect `/metrics` with a dedicated operator credential or do not expose it publicly. Never
   reuse a client stream token.
3. Add a bounded global creation rate for `POST /v1/sessions`; `max_active_sessions` alone allows an
   attacker to exhaust every slot. If a real application identity/JWT issuer exists, validate it
   before session creation. An embedded permanent mobile API key is not an identity system.
4. Add an allowed-host configuration and production middleware test for the Railway/custom host.
5. Verify the trusted-proxy policy before using forwarded client IPs for security decisions.
6. Add a startup configuration summary containing modes and numeric limits but no secrets.

## 5.3. Railway operator actions

1. Create/select the Railway project, production environment, and one backend service.
2. Connect the reviewed Git repository and release branch/commit. Keep root directory `/`; Railway
   should detect the root `Dockerfile`.
3. Select the Singapore/closest supported region, **one replica**, and measured CPU/RAM. Do not
   enable autoscaling or another replica.
4. Set the deployment healthcheck path to `/readyz`. Railway requires a `2xx` response before it
   activates the new deployment, but that healthcheck is deployment-time only; configure an
   external continuous monitor for `/healthz` and `/readyz`.
5. Set restart-on-failure and `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30`; test the actual WebSocket
   close/reconnect behavior during a deployment.
6. Enter the non-secret service variables below in the Variables tab, review staged changes, and
   deploy with Bedrock disabled:

```dotenv
SIMPLYNEXT_ENVIRONMENT=production
SIMPLYNEXT_HOST=0.0.0.0
SIMPLYNEXT_LOG_LEVEL=INFO
SIMPLYNEXT_ALLOWED_ORIGINS=<exact-https-client-origins>
SIMPLYNEXT_SESSION_TTL_SECONDS=300
SIMPLYNEXT_MAX_ACTIVE_SESSIONS=128
SIMPLYNEXT_HTTP_MAX_BODY_BYTES=262144
SIMPLYNEXT_MAX_LATTICES_PER_SESSION=100
SIMPLYNEXT_MAX_LATTICES_PER_MINUTE=30
SIMPLYNEXT_MAX_LATTICES_PER_MINUTE_GLOBAL=120
SIMPLYNEXT_MAX_CONCURRENT_AGENT_RUNS=4
SIMPLYNEXT_AGENT_QUEUE_TIMEOUT_SECONDS=2
SIMPLYNEXT_LATTICE_WEBSOCKET_IDLE_TIMEOUT_SECONDS=120
SIMPLYNEXT_RECOGNITION_LANGUAGE=<sgsl-or-asl>
SIMPLYNEXT_LATTICE_CLASSIFIER_ID=<released-client-value>
SIMPLYNEXT_LATTICE_CLASSIFIER_VERSION=<released-client-value>
SIMPLYNEXT_LATTICE_CALIBRATION_VERSION=<released-client-value>
SIMPLYNEXT_LATTICE_VOCABULARY_VERSION=<released-client-value>
SIMPLYNEXT_CAPTION_TEMPLATES_PATH=/app/data/caption_templates.example.json
SIMPLYNEXT_MIN_RECOGNITION_CONFIDENCE=0.80
SIMPLYNEXT_MIN_RECOGNITION_MARGIN=0.15
SIMPLYNEXT_AGENT_MAX_REVISIONS=1
SIMPLYNEXT_BEDROCK_ENABLED=false
RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30
```

`PORT` is injected by Railway and should not be copied from `.env.example` once code support is
implemented. The recognition language and all producer values must be copied from the released
client, not accepted from the sample above.

7. Deploy, inspect build/runtime logs, confirm `/readyz`, and generate a Railway public domain.
   Railway provides HTTPS certificates and supports WebSockets through its HTTP/1.1 edge. Run the
   protocol smoke using `https://<domain>` and `wss://<domain>`.
8. Configure continuous external HTTPS monitoring, Railway log alerts, AWS budget alerts, and an
   owner/contact channel. Alert on readiness failure, restart loop, elevated 5xx, queue rejections,
   Bedrock failure/budget rejection, and approaching credential expiry.
9. Trigger a restart. Confirm old sessions fail visibly and the smoke client creates a new session.
   Deploy a deliberately failing candidate to verify `/readyz` prevents activation, then roll back
   to the recorded image/source SHA.

## 5.4. Enable Bedrock on Railway

First choose the credential grade:

- For a time-bounded demonstration, manually enter `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` as **sealed** service variables, record expiry,
  and schedule replacement before expiry.
- For unattended production, configure an approved refreshing mechanism. IAM Roles Anywhere can
  issue temporary credentials to non-AWS workloads through a credential helper, but it requires a
  trust anchor, profile, role, end-entity certificate, private key handling, and container/runtime
  configuration. Alternatively, move the backend runtime to AWS compute with an attached role.
- Never use root credentials or bake credentials into the image. Avoid long-lived IAM-user keys.

Then key the verified non-secret Bedrock values from Phase 1 and stage
`SIMPLYNEXT_BEDROCK_ENABLED=true`. Review every staged variable change before deploying. Startup
must pass both preflights; `/readyz` must remain `200`. Run high-confidence and repair smoke cases,
inspect redacted logs/metrics, and compare application cost estimates with AWS usage.

## 5.5. Success criteria

- The public service is the recorded commit/image, one replica, one worker, correct region, and
  listens on Railway's `PORT`.
- `/readyz` gated the deploy; external monitoring subsequently checks health continuously.
- HTTPS is valid and authenticated WSS completes result, repair, replay, ping, and end.
- Exact browser origins/hosts are restricted; native origin-less connectivity is verified.
- Public users cannot read docs, OpenAPI, or metrics and cannot exhaust session creation within the
  tested limit.
- Logs and alerts contain correlations/outcomes, never secrets, prompts, lattice text, or model
  responses.
- Restart and rollback evidence exists; the client-visible session-loss behavior is understood.
- Bedrock preflight and real flow pass under a named, non-root, least-privilege identity.
- Credential expiry/automatic refresh and budget alerts have named owners and have been tested.

# 6. PHASE 4 — CLIENT INTEGRATION

## 6.1. Objective

Connect the real released classifier to the frozen session and lattice protocol over the public
domain and prove user-visible caption, local TTS, uncertainty repair, replay, and lifecycle behavior
on physical target devices.

## 6.2. Manual client inputs

Key these values in the client's environment/flavor configuration, not source constants:

| Client value | Source |
| :----------- | :----- |
| HTTPS base URL | https://signbridge-production-91dd.up.railway.app |
| WSS base URL | wss://signbridge-production-91dd.up.railway.app |
| Language | sgsl |
| Producer object | Exact four deployed producer identifiers plus `calibrated_probability` |
| Schema versions | Lattice `1.0`, event `1.0` |
| Client/detector descriptors | Released app, device, detector, version, and delegate |
| Retry limits/timeouts | Product decision within server TTL/idle/size limits |

The current bearer-header WebSocket contract directly supports Flutter iOS/Android clients that
can set upgrade headers. A browser WebSocket API cannot set an arbitrary `Authorization` header;
if Flutter Web is a required target, redesign and version the authentication transport before
claiming browser support.

## 6.3. Client implementation work

1. Implement immutable client models for every `CTR` request/event discriminator and reject unknown
   types or schema versions visibly.
2. On conversation start, call `POST /v1/sessions`. Treat `422` as a release-config mismatch, `429`
   as temporary capacity, and other non-success responses as unavailable service.
3. Keep `stream_token` only in memory. Build the WSS URL from the trusted base and returned relative
   `websocket_path`; pass `Authorization: Bearer <token>` during upgrade. Never put the token in a
   URL, analytics event, crash report, or log.
4. Wait for initial `activity: idle`, then send only finalized UTF-8 lattice JSON. Maintain one
   strictly increasing `lattice_seq` per session and one increasing `control_seq`.
5. Treat `lattice_ack` as admission, not completion. Show processing only from activity events.
6. On `lattice_result`, correlate session/sequence/utterance, render `caption`, optionally display
   the `gloss_id_trace`/evidence UI, and pass `tts_text ?? caption` to the device's local speech
   synthesizer. Do not expect an audio file from the backend.
7. On `lattice_repair_required`, render the exact action:

   - `ask_repeat` — recapture the utterance;
   - `request_fingerspelling` — enter fingerspelling capture;
   - `offer_top_k` — show only returned choices and send the confirmed lattice;
   - `escalate_human_interpreter` — show the safe fallback channel.

   A repair continuation keeps the same `utterance_id`, uses a higher `lattice_seq`, and updates
   resolved gloss/provenance from actual signer input. It must not merely resend guessed content.
8. On a retryable `error`, retry with bounded exponential backoff. For a lattice whose disposition
   is unknown after disconnect, reconnect to the same live session and resend exactly the same
   sequence/content to receive cached replay. Never change content under an existing sequence.
9. On close `4401`, `4404`, `4408`, `4409`, or after a backend restart, discard the capability and
   negotiate a new session. On normal conversation end, send `control:end`; fall back to
   authenticated HTTP `DELETE` only after the socket is closed.
10. Add contract fixtures shared by value with backend fixtures and automated tests for every event,
    error, close code, disconnect point, duplicated lattice, and schema mismatch.

## 6.4. End-to-end test matrix

Run on at least one physical iOS/Android target in the deployment region:

| Case | Expected result |
| :--- | :-------------- |
| Valid high-confidence signs | One grounded caption, one local TTS utterance, exact evidence trace |
| Low confidence/top-k ambiguity | Repair UI; no caption or speech |
| OOV/unknown sign | Fingerspelling repair; no model guess |
| Identical resend after disconnect | Cached terminal event, no duplicate speech/UI action |
| Changed payload under same sequence | Non-retryable protocol error |
| Ping while idle | Matching pong |
| App background/network switch | Visible reconnect; replay or new session according to server state |
| Backend restart | Old session rejected; new negotiation succeeds |
| Credential/Bedrock failure | Repair/unavailable state; never uncached model text |
| End conversation | Server erases session and socket closes normally |

## 6.5. Success criteria

- The released client and deployment use identical language and producer values.
- Physical-device HTTPS/WSS negotiation works without bypassing TLS or logging the token.
- Confident text is rendered and spoken once; repair events never trigger speech.
- Every server event and close code has a deterministic UI/state transition.
- Replay prevents duplicate computation and duplicate user-visible output.
- Repair selection is grounded in signer action and accepted as a later lattice.
- Airplane mode, network switching, process restart, and expired credentials fail visibly and
  recover according to the documented state machine.
- A redaction review confirms no camera data, lattice content, tokens, prompts, model responses, or
  credentials leave their intended boundary.

# 7. FINAL RELEASE CHECKLIST

- [ ] Phase 1 live Bedrock criteria signed by the AWS lease owner.
- [ ] Phase 2 image digest, dependency inventory, scan, and container smoke attached.
- [ ] Phase 3 Railway settings, health, monitoring, restart, rollback, security, and Bedrock smoke
      attached.
- [ ] Phase 4 physical-device matrix attached.
- [ ] One worker and one replica confirmed.
- [ ] Account budget alarm and process spend ceiling confirmed.
- [ ] Credential expiry or automatic refresh tested.
- [ ] Client language and producer profile exactly match deployment.
- [ ] Contract remains schema `1.0`, or a separately reviewed version migration exists.
- [ ] `ARC`, `PLN`, `DEP`, `CTR`, `README`, and this plan reflect the released code.

# 8. OFFICIAL OPERATIONAL SOURCES

- [Boto3 credential provider chain](https://docs.aws.amazon.com/boto3/latest/guide/credentials.html)
- [Amazon Bedrock model access and Anthropic first-time use](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- [Amazon Bedrock inference permissions](https://docs.aws.amazon.com/bedrock/latest/userguide/inference.html)
- [Bedrock Runtime Converse API](https://docs.aws.amazon.com/botocore/latest/reference/services/bedrock-runtime/client/converse.html)
- [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [IAM Roles Anywhere for external workloads](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [Railway Dockerfile behavior](https://docs.railway.com/builds/dockerfiles)
- [Railway variables and sealed values](https://docs.railway.com/variables)
- [Railway deployment healthchecks and `PORT`](https://docs.railway.com/deployments/healthchecks)
- [Railway public networking and TLS](https://docs.railway.com/networking/public-networking)
- [Railway WebSocket and public-network limits](https://docs.railway.com/networking/public-networking/specs-and-limits)
- [Railway replica routing and lack of sticky sessions](https://docs.railway.com/deployments/optimize-performance)

# 9. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-06 | Created the four-phase production plan from the current backend and official AWS/Railway behavior. |
