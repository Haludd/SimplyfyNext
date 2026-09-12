**SIMPLYNEXT BACKEND — CONTRIBUTOR RULES**

# 1. PURPOSE

This repository contains the SimplyNext GlossLattice translation backend. The production code is
the source of truth. Planning documents describe the code that exists and the explicitly remaining
production work; they must not invent unimplemented capabilities.

# 2. REQUIRED READING

Before changing code, read these files in order:

1. `README.md` — setup, runtime behavior, and quality gates.
2. `plan/ARC_architecture.md` — current components and trust boundaries.
3. `plan/CTR_contracts.md` — frozen client/server contract.
4. `plan/PLN_plan.md` — implementation status and next milestones.
5. `plan/DEP_dependencies.md` — dependency ownership and update policy.

Before production operations, also read the local `plan/BPP_backend_production_plan.md` when it is
present. It is an intentionally Git-ignored operator workbook and must never be force-added.

# 3. ENGINEERING RULES

- Keep the package in `src/simplynext/`; `src/` is the packaging root and `simplynext` is the
  public import namespace.
- Treat `src/simplynext/contracts/` and its contract tests as the wire-protocol authority.
- Preserve strict Pydantic validation, bounded payload sizes, monotonic lattice sequencing,
  idempotent replay, and fail-closed repair behavior.
- Never send raw video, landmarks, feature tensors, prompts, model responses, session tokens, or
  AWS credentials to logs.
- Never hard-code credentials. Use the standard AWS credential provider chain.
- Bedrock must remain disabled by default and guarded by explicit ownership, verified pricing,
  bounded retries/timeouts, and a spend ceiling.
- Do not make a low-confidence result fluent. Return a repair event without `caption` or
  `tts_text`.
- Process-local sessions require one worker and one Railway replica. Shared persistence and
  coordination must be implemented before horizontal scaling.
- Add or update tests whenever behavior or a contract changes.
- Do not claim a hosted integration has passed until it has been exercised against the live
  service named in the claim.

# 4. REQUIRED QUALITY GATES

Run from the repository root in the active virtual environment:

```bash
python -m pytest
python -m ruff check .
python -m mypy src scripts
python -m pip check
```

Packaging or dependency changes also require a clean wheel install in a temporary virtual
environment and `python -c "import simplynext"` from outside the repository.

# 5. DOCUMENTATION RULES

- Update architecture and plan status in the same change as the implementation.
- Mark future work as planned, not present.
- Keep examples synchronized with the contract models and tests.
- Place credentials and real tokens only in local or hosting-provider secret stores, never in
  Markdown, `.env.example`, logs, fixtures, or commits.
- Keep `plan/BPP_backend_production_plan.md` local and ignored; copy no filled worksheet values into
  tracked documents.

# 6. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-06 | Marked the production workbook as local-only and sensitive. |
| 2026-09-06 | Replaced the historical research-corpus rules with backend-only contributor rules. |
