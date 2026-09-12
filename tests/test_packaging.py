from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parents[1]


def test_package_resource_smoke_runs_from_outside_checkout(tmp_path: Path) -> None:
    # The Docker builder runs this same smoke after installing the normal wheel.
    # Locally, execute it from a directory outside the checkout to catch accidental
    # relative-path/resource assumptions without requiring a network build.
    result = subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "scripts" / "package_smoke.py"),
            str(PROJECT_ROOT / "data" / "caption_templates.example.json"),
        ],
        cwd=tmp_path,
        env={key: value for key, value in os.environ.items() if key != "PYTHONPATH"},
        check=True,
        capture_output=True,
        text=True,
    )
    assert "prompts=2" in result.stdout
    assert "templates=" in result.stdout
