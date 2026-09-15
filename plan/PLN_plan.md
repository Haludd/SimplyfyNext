# Backend implementation status

Source-of-truth implementation plan: root `PLN_plan_v1.md`. Status reviewed 2026-09-15.

| Milestone | Backend status | Remaining acceptance |
| --- | --- | --- |
| 0: freeze | Schema, generated types, fixtures and event negotiation implemented | Frontend fixture execution and owner sign-off |
| 1: room core | Auth, ordering/replay, HTTP/WS, expiry and complete room erasure implemented | Hosted/physical-device evidence belongs to milestone 5 |
| 2: agents | Independent word assembly/criticism, grounding, one revision and safe repairs implemented | Representative producer/model quality qualification |
| 3: context | Accepted transcript, recent 10, bounded overflow/summary, batched compaction and cancellation implemented | Optional model-summary benchmark is deferred; deterministic summary is active |
| 4: cutover | Retired routes/types/prompts/config/scripts removed; package is word-only | Frontend integration execution remains outside backend workspace |
| 5: hosting | Manifest/profile, spend journal, security, preflight, locked image and smoke/benchmark tooling prepared | Clean release/scan clearance, hosted/mobile, credentials, monitoring and volume/restart/rollback evidence |
| 6: scale | Not implemented | Ephemeral shared store and atomic distributed erasure before replicas |

The production acceptance policy is specified in [WORD_ACCEPTANCE_POLICY.md](WORD_ACCEPTANCE_POLICY.md).
Local synthetic/provider-double tests prove mechanics and adversarial gates, not real-model quality.
A reviewed dataset/report has not been supplied; production qualification must remain unset.

Use `UPDATE_LOG.md` at the workspace root for exact current test/package/container results.

Sections 8–9 are implemented and tested locally. Root `PLN_plan_v1.md` section 14 lists remaining
acceptance work; [HOSTED_VERIFICATION.md](HOSTED_VERIFICATION.md) gives execution instructions.
