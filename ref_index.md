**SIMPLYNEXT BACKEND DOCUMENT INDEX**

# 1. PURPOSE

This index lists the maintained backend documents. Historical research, imported contracts,
scratch notes, and third-party repository reports are intentionally not part of this repository.

# 2. MAINTAINED DOCUMENTS

| File | Authority |
| :--- | :-------- |
| `README.md` | Installation, local operation, API summary, and quality gates |
| `CLAUDE.md` | Contributor and automation constraints |
| `plan/ARC_architecture.md` | Implemented backend architecture and trust boundaries |
| `plan/CTR_contracts.md` | Frozen GlossLattice v1 HTTP/WebSocket contract |
| `plan/DEP_dependencies.md` | Python runtime and dependency policy |
| `plan/PLN_plan.md` | Completed implementation and remaining milestones |

`plan/BPP_backend_production_plan.md` is a local, Git-ignored operator workbook. It is not a
maintained repository document and may contain sensitive infrastructure metadata.

# 3. AUTHORITY ORDER

When documents disagree, use this order:

1. Executable contract and behavior tests.
2. Source code under `src/simplynext/`.
3. `plan/CTR_contracts.md` for the published wire protocol.
4. `plan/ARC_architecture.md` for component ownership.
5. `plan/PLN_plan.md` for future work; the local BPP may add operator-specific execution values.
6. `README.md` and `plan/DEP_dependencies.md` for operational guidance.

# 4. UPDATE POLICY

- A contract change updates the models, tests, `CTR`, `ARC`, `PLN`, and client fixtures together.
- A module move updates `ARC` and `README` in the same change.
- A dependency change updates `pyproject.toml`, `pylock.toml`, and `DEP` together.
- A completed production gate updates the local BPP and the non-sensitive status summary in `PLN`.

# 5. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-06 | Reclassified the BPP as a local, ignored operator workbook. |
| 2026-09-06 | Reduced the registry to maintained backend documents only. |
