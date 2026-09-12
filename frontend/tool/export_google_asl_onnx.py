#!/usr/bin/env python3
"""Export the user-supplied Google ASL PyTorch checkpoint for browser use.

The source repository is intentionally an explicit command-line argument. Its
checkpoint is not committed here: confirm the upstream repository/dataset
licensing before shipping it with a product.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
from pathlib import Path
import sys


DEFAULT_MODEL = "manual/models/asl_model_v20250723_042752.pth"
DEFAULT_OUTPUT = "web/models/google_asl_25_v20250723_042752.onnx"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        required=True,
        type=Path,
        help="Path to a clone of jaganov/google_asl_recognition.",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--output", type=Path, default=Path(DEFAULT_OUTPUT))
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    args = parse_args()
    source = args.source.resolve()
    manual = source / "manual"
    checkpoint_path = source / args.model
    if not manual.is_dir() or not checkpoint_path.is_file():
        raise SystemExit(
            "Expected the upstream repository's manual/ directory and model "
            f"checkpoint at {checkpoint_path}."
        )

    # The upstream class definitions are needed to load its state dict exactly.
    sys.path.insert(0, str(manual))
    import torch
    import onnx

    training = importlib.import_module("step3_prepare_train")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state_dict = checkpoint.get("model_state_dict", checkpoint)
    model = training.ASLModel(input_dim=744, num_classes=25).eval()
    model.load_state_dict(state_dict)

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    example = torch.zeros((1, 16, 543, 3), dtype=torch.float32)
    torch.onnx.export(
        model,
        example,
        output,
        input_names=["landmarks"],
        output_names=["logits"],
        opset_version=17,
        do_constant_folding=True,
        dynamo=False,
    )
    onnx.checker.check_model(onnx.load(output))
    print(
        json.dumps(
            {
                "output": str(output),
                "sha256": sha256(output),
                "checkpoint_sha256": sha256(checkpoint_path),
                "input": [1, 16, 543, 3],
                "labels": 25,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
