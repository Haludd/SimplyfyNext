#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: scripts/container_smoke.sh IMAGE [HOST_PORT] [CONTAINER_PORT]}"
host_port="${2:-18000}"
container_port="${3:-8000}"
container_name="simplynext-smoke-$$"

# A fresh local diagnostic capability authenticates only the metrics endpoint.
# Pass by environment name so the token is absent from command arguments/output.
export SIMPLYNEXT_OPERATOR_METRICS_TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"

cleanup() {
  docker rm --force "${container_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm \
  --name "${container_name}" \
  --publish "${host_port}:${container_port}" \
  --env PORT="${container_port}" \
  --env SIMPLYNEXT_ENVIRONMENT=production \
  --env SIMPLYNEXT_HOST=0.0.0.0 \
  --env SIMPLYNEXT_BEDROCK_ENABLED=false \
  --env SIMPLYNEXT_ANTHROPIC_ENABLED=false \
  --env SIMPLYNEXT_OPERATOR_METRICS_TOKEN \
  "${image}" >/dev/null

python - "http://127.0.0.1:${host_port}" <<'PY'
from __future__ import annotations

import sys
import time
from urllib.request import urlopen

base_url = sys.argv[1]
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    try:
        with urlopen(f"{base_url}/healthz", timeout=2) as response:
            if response.status != 200:
                raise RuntimeError(f"healthz returned {response.status}")
        with urlopen(f"{base_url}/readyz", timeout=2) as response:
            if response.status != 200:
                raise RuntimeError(f"readyz returned {response.status}")
        break
    except Exception:
        time.sleep(0.5)
else:
    raise SystemExit("container did not become healthy")
PY

python scripts/room_protocol_smoke.py --base-url "http://127.0.0.1:${host_port}"

docker stop --time 30 "${container_name}" >/dev/null
echo "Container health, protocol, and graceful-stop smoke passed"
