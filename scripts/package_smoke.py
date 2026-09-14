"""Verify resources and deterministic data after a normal package installation."""

from __future__ import annotations

import importlib.resources
import json
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        raise SystemExit("usage: package_smoke.py WORD_TEMPLATES_PATH")

    import simplynext

    # Resolve through the installed top-level package so this check does not depend
    # on the checkout's src directory or on the agent's optional runtime imports.
    package_root = importlib.resources.files("simplynext")
    for role in ("assembler", "critic"):
        prompt = package_root.joinpath("agent", "prompts", f"word_{role}_v1.txt").read_text()
        if "UNTRUSTED DATA" not in prompt:
            raise SystemExit("packaged word prompt is missing its trust boundary")
    for name in ("translated-sign-utterance-v1.json", "room-events-v1.json"):
        schema = json.loads(package_root.joinpath("contracts", "schemas", name).read_text())
        if schema["$schema"] != "https://json-schema.org/draft/2020-12/schema":
            raise SystemExit("packaged word/room schema is invalid")

    # Import former modules by accident would indicate an incomplete wheel cutover.
    for old in ("lattice_runtime.py", "contracts/gloss_lattice.py", "api/lattice_websocket.py"):
        if package_root.joinpath(old).is_file():
            raise SystemExit("retired runtime resource in wheel")
    from simplynext.translation_runtime import load_word_templates

    templates = load_word_templates(Path(args[0]))
    if not templates:
        raise SystemExit("word templates invalid")
    from uvicorn.protocols.websockets.auto import AutoWebSocketsProtocol

    if AutoWebSocketsProtocol is None:
        raise SystemExit("production WebSocket transport dependency is missing")
    print(
        f"package={simplynext.__name__} word_prompts=2 schemas=2 "
        f"templates={len(templates)} ws=ready"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
