#!/usr/bin/env bash
set -euo pipefail

# Run this script in a Python 3.12 Linux builder (for example, the Docker builder
# stage), never on macOS.  The output is platform-specific because pip lock records
# wheel artifacts for the current interpreter/platform.
output_path="${1:-docker/pylock.linux.toml}"
python_bin="${PYTHON_BIN:-python}"
mkdir -p "$(dirname "${output_path}")"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pylock.linux.XXXXXX")"
temporary_path="${temporary_dir}/pylock.linux.toml"
cleanup() {
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT

"${python_bin}" -m pip install --no-cache-dir --upgrade "pip==26.2.1"
"${python_bin}" -m pip lock \
  --no-input \
  --only-final ":all:" \
  -r docker/requirements-production.in \
  -o "${temporary_path}"

if [[ -f "${output_path}" && "${UPDATE_LINUX_LOCK:-0}" != "1" ]]; then
  if ! cmp -s "${temporary_path}" "${output_path}"; then
    echo "Linux production resolution changed; review it and rerun with UPDATE_LINUX_LOCK=1" >&2
    exit 1
  fi
elif [[ ! -f "${output_path}" && "${UPDATE_LINUX_LOCK:-0}" != "1" ]]; then
  echo "Missing reviewed Linux lock: ${output_path}; generate it with UPDATE_LINUX_LOCK=1" >&2
  exit 1
else
  mv -- "${temporary_path}" "${output_path}"
fi

echo "Wrote Linux production lock: ${output_path}"
