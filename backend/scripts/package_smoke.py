"""Verify resources and deterministic data after a normal package installation."""

from __future__ import annotations

import importlib.resources
import json
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        raise SystemExit("usage: package_smoke.py CAPTION_TEMPLATES_PATH")

    import simplynext

    # Resolve through the installed top-level package so this check does not depend
    # on the checkout's src directory or on the agent's optional runtime imports.
    package_root = importlib.resources.files("simplynext")
    prompt_paths = tuple(
        package_root.joinpath("agent", "prompts", name)
        for name in ("assembler_v1.txt", "critic_v1.txt")
    )
    for prompt_path in prompt_paths:
        prompt = prompt_path.read_text(encoding="utf-8")
        if not prompt_path.is_file() or not prompt.strip():
            raise SystemExit(f"packaged prompt is empty: {prompt_path.name}")

    template_path = Path(args[0])
    templates = json.loads(template_path.read_text(encoding="utf-8"))
    if not isinstance(templates, dict) or not templates:
        raise SystemExit("deterministic template data is empty or malformed")
    print(f"package={simplynext.__name__} prompts=2 templates={len(templates)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
