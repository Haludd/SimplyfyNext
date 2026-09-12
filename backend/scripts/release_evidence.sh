#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: scripts/release_evidence.sh IMAGE [OUTPUT_JSON]}"
output_path="${2:-release-evidence.json}"
scan_path="${VULNERABILITY_SCAN_PATH:-${output_path%.json}.scan.txt}"
test_results_path="${TEST_RESULTS_PATH:-}"

if [[ -z "${test_results_path}" || ! -f "${test_results_path}" ]]; then
  echo "TEST_RESULTS_PATH must point to retained quality-gate output" >&2
  exit 2
fi

mkdir -p "$(dirname "${output_path}")" "$(dirname "${scan_path}")"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/simplynext-evidence.XXXXXX")"
cleanup() {
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT

source_sha="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Release evidence requires a clean source tree at ${source_sha}" >&2
  exit 2
fi
image_digest="$(docker image inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)"
if [[ "${image_digest}" == "<no value>" ]]; then
  image_digest=""
fi
image_content_id="$(docker image inspect --format='{{.Id}}' "${image}")"
build_timestamp="$(docker image inspect --format='{{.Created}}' "${image}" 2>/dev/null || true)"
if [[ -z "${build_timestamp}" || "${build_timestamp}" == "<no value>" ]]; then
  build_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

docker run --rm --entrypoint python "${image}" --version > "${temporary_dir}/python.txt"
if docker run --rm --entrypoint sh "${image}" -c 'command -v pip >/dev/null 2>&1'; then
  docker run --rm --entrypoint python "${image}" -m pip --version > "${temporary_dir}/pip.txt"
else
  printf '%s\n' 'not installed (runtime image intentionally strips pip)' > "${temporary_dir}/pip.txt"
fi
docker run --rm --entrypoint python "${image}" -c '
import importlib.metadata as metadata
import json

print(json.dumps([
    {"name": distribution.metadata["Name"], "version": distribution.version}
    for distribution in sorted(metadata.distributions(), key=lambda item: item.metadata["Name"].lower())
]))
' > "${temporary_dir}/dependencies.json"

# Docker Scout is the required release scanner. CRITICAL and HIGH findings
# block release; lower severities remain visible in the attached scan output.
if ! docker scout cves --exit-code --only-severity critical,high "${image}" > "${scan_path}" 2>&1; then
  echo "CRITICAL/HIGH vulnerability scan failed or found a blocking vulnerability" >&2
  echo "See ${scan_path}" >&2
  exit 1
fi

python - "${output_path}" "${image}" "${source_sha}" "${image_digest}" "${image_content_id}" "${build_timestamp}" \
  "${temporary_dir}/python.txt" "${temporary_dir}/pip.txt" "${temporary_dir}/dependencies.json" \
  "${scan_path}" "${test_results_path}" <<'PY'
from __future__ import annotations

import hashlib
import json
import pathlib
import sys


(
    output_path,
    image,
    source_sha,
    image_digest,
    image_content_id,
    build_timestamp,
    python_path,
    pip_path,
    dependencies_path,
    scan_path,
    test_results_path,
) = sys.argv[1:]


def read_one_line(path: str) -> str:
    return pathlib.Path(path).read_text(encoding="utf-8").strip()


dependencies = json.loads(pathlib.Path(dependencies_path).read_text(encoding="utf-8"))
test_results: dict[str, object] = {"status": "not_supplied"}
if test_results_path:
    result_file = pathlib.Path(test_results_path)
    if result_file.is_file():
        test_results = {
            "status": "provided",
            "path": str(result_file),
            "sha256": hashlib.sha256(result_file.read_bytes()).hexdigest(),
        }

evidence = {
    "source_sha": source_sha,
    "source_tree_clean": True,
    "image": image,
    "image_digest": image_digest or None,
    "image_content_id": image_content_id,
    "build_timestamp": build_timestamp,
    "python_version": read_one_line(python_path),
    "pip_version": read_one_line(pip_path),
    "dependency_inventory": dependencies,
    "test_results": test_results,
    "vulnerability_scan": {
        "scanner": "docker scout cves",
        "output_path": scan_path,
        "blocking_severities": ["CRITICAL", "HIGH"],
        "status": "passed",
    },
}
pathlib.Path(output_path).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
print(f"Wrote release evidence: {output_path}")
PY
