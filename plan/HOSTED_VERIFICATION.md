# Milestone 5 hosted verification runbook

Prepared 2026-09-15. This is a release procedure, not evidence of a deployment. The root
`PLN_plan_v1.md` section 14 tracks missing acceptance evidence. No production-qualified producer
profile, live provider run, deployed configuration, external monitor or physical-device result is
supplied by this change. The image vulnerability gate must pass before release.

## 1. Reviewable production items

| Item | Location / purpose |
| --- | --- |
| Deployment settings | `railway.json`: Docker, Singapore, one replica, readiness, restart/drain policy |
| Safe first profile | `deploy/production.env.example`: text + signed repair, providers off |
| Configuration gate | `scripts/production_preflight.py`; also `/app/ops/production_preflight.py` in image |
| Production artifacts | Pinned Python base; Linux AMD64 `docker/pylock.linux.toml`; normal wheel; UID/GID 10001 |
| Cost controls | Request/room/hour/deployment reservations, persistent numeric-only spend journal |
| Protocol evidence | `scripts/room_protocol_smoke.py --production --origin … --output …` |
| Long-room evidence | `scripts/benchmark_rooms.py`; accelerated synthetic runs, no provider calls |
| Release evidence gate | `scripts/release_evidence.sh`: clean source, matching image revision, inventory, mandatory HIGH/CRITICAL scan |

The checked-in Linux lock is installed directly. Refresh it only in a Linux AMD64 Python 3.12
builder using `UPDATE_LINUX_LOCK=1 scripts/resolve_linux_production_lock.sh`, review versions and
hashes, and rerun verification. OS security updates run during the image build; retain the resulting
image digest and OS inventory rather than claiming bit-for-bit reproducibility across later apt
repositories. Release by the reviewed image digest.

## 2. Platform configuration

1. Select the backend repository/root and reviewed commit. If deployed from a monorepo, configure
   the service root as `backend/` and select its `railway.json` explicitly.
2. Confirm one process, one worker, one replica, one region, no sleeping/autoscaling or extra
   region. The runner fixes `workers=1`; the manifest fixes one Singapore replica. Verify effective
   settings in the platform, including overrides. Zero-overlap and a 30-second drain allow a
   deliberate reconnect/session-loss transition; no seamless migration is promised.
   [Railway configuration reference](https://docs.railway.com/config-as-code/reference).
3. Fill the non-secret profile with the exact public API hostname and HTTPS frontend origin.
   Include `healthcheck.railway.app` in allowed hosts. Railway injects `PORT`; do not override it.
   Set `/readyz` as the deployment healthcheck. It checks transport readiness; the response's
   `sentence_acceptance_ready` must separately be true before claiming live sentence support.
   Railway's healthcheck is deployment-time; configure ongoing external monitoring.
   [Railway healthchecks](https://docs.railway.com/deployments/healthchecks).
4. Put a random dedicated metrics bearer secret in sealed variables. Keep provider credentials
   separate from operator secrets and participant capabilities. Do not put secrets in build args,
   browser build defines, image layers, command-line parameters or evidence captures.
   [Railway sealed variables](https://docs.railway.com/variables).
5. Enforce HTTPS/WSS at the edge. The runner explicitly disables forwarded-IP trust. Application
   invitation/socket throttles use the actual peer address, which may be a shared Railway proxy.
   Until the real proxy topology and spoofing resistance are verified, add per-client-IP throttles
   at the edge and keep the global application limits. Do not solve shared-IP limits by trusting
   arbitrary `X-Forwarded-For`.
6. Disable body/header/URL capture in edge logs, APM, error reporting and analytics. Application
   logs suppress SDK messages and traceback text, but that cannot govern external collectors.

## 3. Deployment spend persistence and provider activation

First verify text and safe repair with all hosted providers off. Then:

1. Complete [producer qualification](WORD_ACCEPTANCE_POLICY.md) with independent human review;
   mount reviewed policy/evaluation files read-only. This round changes pipeline code, so older
   pipeline hashes need requalification. Synthetic fixtures are never production qualification.
2. Mount a persistent volume at `/app/spend` writable by UID/GID 10001, with restricted operator
   access. Only `usage.json` and its writer lock belong there; no room payload or credentials.
   Verify actual mount permissions and persistence on the hosting platform.
   [Railway volumes](https://docs.railway.com/volumes).
3. Provision `usage.json` **once**, using exclusive creation (never overwrite), containing:

   ```json
   {"version":1,"charged_usd":"0","hourly":{}}
   ```

   Zero is valid only for a new, reconciled allowance. For an existing allowance, restore the
   latest journal and set the selected provider's `KNOWN_SPEND_USD` to the reconciled cumulative
   total. Production refuses a missing file; never replace a lost volume with an empty allowance.
   Backups contain only aggregate spend. Restoring an old backup also requires reconciling charges
   incurred after that backup before restarting.
4. The journal reserves to disk before dispatch using atomic replace/fsync. A crash or unknown
   response charges the entire reservation. A file lock rejects concurrent writers. It survives
   service restart and provider changes on that volume. This is single-writer accounting, not a
   distributed budget service; unrelated deployments/accounts require provider-side limits and
   consolidated account monitoring. Use a maintenance cutover when switching providers or when the
   platform's deployment overlap would create a second journal writer.
5. Select one provider, accountable owner, model ID, region/endpoint, all four verified token
   prices, process ceiling and known spend. Direct Haiku 4.5 list prices checked 2026-09-15 are
   $1 input, $5 output, $1.25 five-minute cache write and $0.10 cache read per million tokens.
   Verify Bedrock prices for its actual inference geography separately.
   [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing).
6. Defaults are $0.50/request, $2/room, $5/hour, with the selected provider's $5 deployment ceiling.
   Each assembler/critic/revision call must fit all applicable remaining balances. A request need
   not reserve a complete four-call pipeline upfront; a later budget rejection safely repairs.
   Hourly buckets retain charges for 60–61 minutes and include all pending reservations regardless
   of age. Normal responses settle measured usage; missing usage/failure keeps maximum cost.
7. Keep SDK attempts at one for the initial release. If increased, the guard reserves every
   permitted attempt and charges unreported retry attempts at their maximum even on success.
   This intentionally overestimates spend. Repeated exact client retries do not spend again.
   Budgets are conservative estimates at configured rates, not provider billing enforcement.
8. Keep prompt caching off until actual cache-hit measurements justify it. Never pad prompts.
   Optional model summarization is off; deterministic batching adds no API cost.
9. Run the configuration gate in the prepared production environment before enabling the service:

   ```bash
   python /app/ops/production_preflight.py --pricing-verified-on 2026-09-15
   ```

   Replace the date with the actual verification date. This checks configuration without creating a
   provider client. Starting the application with a provider enabled makes a small guarded preflight
   call. Keep that allowance in the budget. Test credentials/expiry/refresh and account budget
   notifications separately; no production credentials are created by these files.

## 4. Automated checks and evidence

From the backend checkout, with the development environment active:

```bash
make quality
python scripts/export_word_contract.py --check
python scripts/benchmark_rooms.py --output /private/evidence/room-benchmark.json
make docker-build IMAGE=simplynext-backend:reviewed
make container-smoke IMAGE=simplynext-backend:reviewed
make container-smoke-nondefault IMAGE=simplynext-backend:reviewed
TEST_RESULTS_PATH=/private/evidence/quality.txt make release-evidence \
  IMAGE=simplynext-backend:reviewed EVIDENCE_OUTPUT=/private/evidence/release.json
```

Create the evidence directory first. Retain stdout of the quality commands without environment
dumps. The release gate refuses dirty source, an image revision mismatch, or blocking scan findings.
It does not prove source review or hosted acceptance; attach those independent records too.

Against the explicitly selected new hosted service:

```bash
python scripts/room_protocol_smoke.py --base-url https://API_HOST \
  --origin https://CLIENT_HOST --production --output /private/evidence/hosted-room.json
```

This creates and erases a synthetic room, uses two authenticated sockets, checks text, safe signed
repair, exact retry, recovery, end and private headers. It spends no provider credits. It tests two
clients, not two physical devices. Repeat with real allowed browser Origin and native origin-less
connections; unauthorized origins must fail. The harness never retains capabilities/transcripts.
An accepted signed sentence still requires the qualified real client and provider test below.

## 5. Hosted/manual acceptance matrix

Record outcome, UTC timestamp, image/source digest, device/OS/browser/network and numeric timing.
Use synthetic conversations for operational tests. Never attach credentials, room URLs, raw logs,
screenshots containing transcripts, prompts, recognizer captures or model output to release evidence.

| Case | Required observation |
| --- | --- |
| Two physical devices | Signer creates; hearing joins by QR and typed eight-character code; no credential in URL; third participant refused |
| Real signed input | One final commit → 202 processing → one critic-approved sentence and local TTS once; no per-word requests |
| Hearing text/speech | Both clients receive finalized text; provider call counter unchanged; speech recognition/privacy behavior verified on device |
| Repair | Low score, OOV, provider timeout, invalid output and exhausted budget show type/repeat; no sentence/TTS; typed chat remains usable |
| Reconnect/replay | Drop network after POST and before terminal; reconnect snapshot + unchanged retry produce one UI message/TTS; shared sequence for typed and signed input |
| End races | End from either device during admission, assembler, critic, revision, summary and reconnect; both clients clear state; GET/retry gets 410; late result discarded |
| Expiry | On isolated staging use short TTLs; verify invite, idle and absolute expiry; restore production TTLs afterward |
| Restart / rollback | Stop existing writer; restart same volume/image; rooms lost visibly but spend not reset; prior reviewed image + compatible journal rollback works |
| Readiness rejection | Isolated bad configuration never becomes ready or replaces the healthy deployment |
| Browser privacy | Close/end/expiry clears tab capability, outbox, transcript, media and pending TTS; no room state in localStorage or crash reports |
| Hour-long mobile | Run 60, 120, 240 total accepted-turn sessions over real wall-clock time; backgrounding, network switch and reconnect included |
| Limits / spoofing | Header/body/socket bounds and global/per-peer limits hold; forwarded-IP spoof cannot bypass admission; proxy-sharing impact measured |
| Journal failure | Staging read-only/full/missing/corrupt volume blocks paid dispatch; recovery never restores an obsolete zero allowance |

The room cap is **300 total messages**, including repairs and processing admissions, from both
participants. 240 signed + 240 hearing turns cannot fit. Agree on expected conversation rate before
promising an hour for every user. The current profile supports the plan's bounded scenarios, not an
unlimited session duration/message count.

## 6. Monitoring and release decision

Poll HTTPS health/readiness continuously; authenticate `/metrics` using a secret header in the
monitor. Alert on failed checks, restart loops, any journal I/O/accounting failure, budget rejection,
provider failure/usage-unavailable, queue pressure, sustained repairs, and nearing the allowance.
Assign operator and credential/budget owners and verify alerts reach them before opening traffic.

Metrics include four token classes, estimated nano-USD, budget scope, accepted/repair/replay counts,
revisions, context bounds and compaction failures. Timings expose mean/min/max plus p50/p95 over the
last 2,048 samples for admission, room/provider queues, assembler, critic, revision stages, commit,
terminal processing and socket send. These rolling percentiles cannot be averaged across processes;
metrics reset on restart. The spend journal does not. External monitoring must retain aggregates.
Socket-send timing ends at ASGI send; measure actual user-visible delivery on physical devices.

Set latency targets only after that baseline. Compare actual provider usage/cost with estimates;
synthetic benchmark tokens and sub-millisecond local timings are not a bill forecast or mobile SLO.
Provider-side data retention remains subject to the selected provider agreement. Ending a room
erases application-owned data, not data already sent to a provider; in-flight SDK buffers survive
until their bounded request completes. Document both limits in the released product.

Release only after all required matrix rows, scan, qualified sentence flow and ownership evidence
pass. Keep providers off, or keep the service private, while those gates remain pending.

## 7. Current local release blocker

The final local Linux AMD64 image scan on 2026-09-15 reports **0 CRITICAL, 1 HIGH** after OS
updates removed 14 earlier blocking findings. The remaining `CVE-2026-85091` affects the installed
Debian zlib package and is marked unfixed by the current tracker. The unchanged release gate
therefore fails; local functional passes do not authorize publication. Follow the vendor fix,
rebuild and rescan, or separately review a supported alternative base and rerun all gates.
No vulnerability exception or scanner suppression was added.
[Debian security tracker](https://security-tracker.debian.org/tracker/CVE-2026-85091).

Retained scan: [milestone5-image-scan.txt](evidence/milestone5-image-scan.txt). The image is a local
worktree verification artifact labelled `unreviewed`; produce fresh evidence from the clean,
reviewed release commit once this blocker and the external acceptance register are closed.
