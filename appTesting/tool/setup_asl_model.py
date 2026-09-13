#!/usr/bin/env python3
"""Install the pinned James Bustos model and local TFLite browser runtime.

Requires Python 3 only. Downloads are verified before replacing any file.
Run from any directory; use --check for an offline integrity check.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import tempfile
from urllib.request import urlopen

APP = Path(__file__).resolve().parents[1]
MANIFEST = APP / "web/models/jamesbustos_asl_250_809d456.manifest.json"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def download(url, expected_hash):
    with urlopen(url, timeout=90) as response:
        data = response.read()
    if sha256(data) != expected_hash:
        raise ValueError(f"Checksum mismatch: {url}")
    return data


def install(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        file.write(data)
        temporary = Path(file.name)
    temporary.replace(path)


def valid_file(path, expected_hash):
    return path.is_file() and sha256(path.read_bytes()) == expected_hash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify installed assets without downloading")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    model_path = APP / "web/models" / manifest["model_file"]
    if not args.check and not valid_file(model_path, manifest["model_sha256"]):
        url = ("https://raw.githubusercontent.com/jamesjbustos/sign-language-recognition/"
               f"{manifest['source_commit']}/{manifest['source_checkpoint']}")
        data = bytearray(download(url, manifest["source_checkpoint_sha256"]))
        adaptation = manifest["browser_adaptation"]
        offset = adaptation["input_shape_byte_offset"]
        if struct.unpack_from("<3i", data, offset) != (1, 543, 3):
            raise ValueError("Unexpected original input allocation")
        # The pinned binary makes this offset unambiguous. Only one int32 in
        # the input's Shape vector changes; no weights or operators change.
        struct.pack_into("<i", data, offset, adaptation["browser_frames"])
        if sha256(data) != manifest["model_sha256"]:
            raise ValueError("Unexpected browser model checksum")
        install(model_path, data)

    assets = [(model_path, manifest["model_sha256"])]
    for asset in manifest["runtime_assets"]:
        path = APP / "web/vendor/tflite" / asset["file"]
        if not args.check and not valid_file(path, asset["sha256"]):
            install(path, download(asset["url"], asset["sha256"]))
        assets.append((path, asset["sha256"]))

    missing = [str(path.relative_to(APP)) for path, digest in assets if not valid_file(path, digest)]
    if missing:
        parser.exit(1, "Missing or modified ASL assets:\n" + "\n".join(missing) + "\nRun python3 tool/setup_asl_model.py\n")
    size = sum(path.stat().st_size for path, _ in assets)
    print(f"Verified {len(assets)} ASL assets ({size / 1024**2:.1f} MiB): {manifest['model_id']}")


if __name__ == "__main__":
    main()
