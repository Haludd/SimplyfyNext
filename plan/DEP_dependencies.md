**SIMPLYNEXT BACKEND DEPENDENCIES**

# METADATA

| Field | Value |
| :---- | :---- |
| **Code** | `DEP` |
| **Status** | Implemented and locked |
| **Last reviewed** | 2026-09-07 |
| **Manifest authority** | `pyproject.toml` |
| **Resolution authority** | `pylock.toml` (development); `docker/pylock.linux.toml` (production) |

# 1. RUNTIME BASELINE

| Item | Requirement |
| :--- | :---------- |
| Python | `>=3.11,<3.14` |
| Tested development/deployment target | Python 3.12 |
| Build backend | `hatchling>=1.26,<2` |
| Distribution | `simplynext-backend` |
| Import package | `simplynext` |
| Layout | `src/simplynext/` |

The package must remain importable from a normal wheel installation. The root `main.py` is a
checkout convenience and is not the package boundary.

# 2. DIRECT RUNTIME DEPENDENCIES

| Dependency | Constraint | Ownership |
| :--------- | :--------- | :-------- |
| `anthropic` | `>=0.104,<1` | Direct Anthropic Messages API adapter (optional runtime provider) |
| `boto3` | `>=1.35,<2` | Bedrock control-plane and runtime clients; credential provider chain |
| `fastapi` | `>=0.115,<1` | ASGI application, HTTP routes, WebSocket upgrade, CORS |
| `httpx` | `>=0.27,<1` | Anthropic API timeout transport and optional protocol client |
| `langgraph` | `==1.2.11` | Bounded assembler/critic/repair graph and in-memory checkpoints |
| `pydantic` | `>=2.9,<3` | Strict contracts, agent values, and validation |
| `pydantic-settings` | `>=2.6,<3` | `.env` and `SIMPLYNEXT_*` runtime configuration |
| `uvicorn` | `>=0.30,<1` | One-worker ASGI server |

These are the only direct production dependencies. Anthropic and Bedrock are optional at runtime,
but remain in the production image so either reviewed provider can be enabled without rebuilding.
Recognition is client-side; NumPy, MediaPipe,
OpenCV, TensorFlow, PyTorch, and server-side landmark libraries are not backend requirements.

# 3. DIRECT DEVELOPMENT DEPENDENCIES

| Dependency | Constraint | Purpose |
| :--------- | :--------- | :------ |
| `mypy` | `>=1.13,<2` | Strict package type checking |
| `pytest` | `>=8.3,<9` | Test runner |
| `pytest-asyncio` | `>=0.24,<1` | Async session/runtime tests |
| `ruff` | `>=0.8,<1` | Import, correctness, and style checks |
| `websockets` | `>=14,<17` | Explicit Phase 1 HTTP/WebSocket protocol smoke client |

# 4. INSTALL PROFILES

Development environment:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
```

Production-style wheel check:

```bash
python -m pip wheel --no-deps --wheel-dir dist .
python -m pip install --no-deps dist/simplynext_backend-*.whl
python -c "import simplynext; from simplynext.main import app"
```

A production Docker build should use `pip install .` directly or install an externally built,
attested wheel. The production plan owns that choice.

`requirements.txt` contains only `-e .` for compatibility with tools that require that filename.
It is not an independent dependency list. Add or change requirements in `pyproject.toml` only.

# 5. LOCK FILE

`pylock.toml` records a fully resolved Python 3.12 macOS ARM development installation, including
the `dev` extra. It is not the cross-platform container install mechanism. Phase 2 provides
`docker/requirements-production.in`, `scripts/resolve_linux_production_lock.sh`, and the
`make production-lock` target. Run that workflow in a Python 3.12 Linux builder, review and commit
`docker/pylock.linux.toml`, then rerun without `UPDATE_LINUX_LOCK=1`; the script fails if the
reviewed Linux resolution changes (or if the reviewed file is missing). The Docker builder invokes
the same workflow with an explicit first-generation override for its ephemeral in-image lock, so a
clean clone remains buildable before a lock refresh is committed.

Do not assume a macOS wheel URL from the current lock can install in Linux.

# 6. UPDATE PROCEDURE

1. Change the smallest necessary version range in `pyproject.toml`.
2. Re-resolve `pylock.toml` with the approved Python 3.12 environment.
3. Inspect the dependency diff, including transitive additions and platform wheels.
4. Run all tests, Ruff, strict mypy, and `pip check`.
5. Build and install the package in a clean temporary environment from outside the checkout.
6. For runtime changes, build the Linux production image and run both
   `make container-smoke` and `make container-smoke-nondefault`.
7. From the clean release commit, run `make release-evidence` with `TEST_RESULTS_PATH` pointing to
   the retained quality-gate output. The evidence script records the image inventory and blocks on
   CRITICAL/HIGH Docker Scout findings.
8. Update this file when dependency ownership or deployment constraints change.

# 7. DEPENDENCY RULES

- No application code may depend on a development-only package.
- No model SDK may bypass `CostGuardedConverseClient`.
- AWS credentials are configuration supplied by the credential chain, never dependencies or
  committed files.
- Prompt text belongs in the packaged `simplynext.agent.prompts` resources, not an external
  document directory.
- Add a dependency only when standard-library or existing dependency functionality is
  insufficient and the new package has a bounded, tested responsibility.
- Keep the runtime image free of compilers, test tools, caches, credentials, and local `.env` files.

# 8. CURRENT VERIFICATION

The latest clean verification established that the project installs from both the locked editable
path and a normal wheel, imports from outside the repository, and passes `pip check`. The clean
runtime dependency closure does not contain NumPy or a server-side vision stack. The Phase 2 image
build, installed-package smoke, default/non-default port protocol smokes, and non-root/runtime-tooling
checks pass locally. Docker Scout is wired into the release gate; the current pinned Trixie image has
one unfixable HIGH zlib CVE-2026-85091, so release evidence remains blocked until the base image is
fixed or a documented exception is approved.

# 9. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-07 | Added direct Anthropic runtime ownership and Phase 2 Linux lock, container smoke, and release-evidence workflow. |
| 2026-09-06 | Added the opt-in, payload-redacted WebSocket protocol smoke dependency. |
| 2026-09-06 | Rewritten around the current GlossLattice-only Python package and production dependency boundary. |
