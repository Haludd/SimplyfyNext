#!/usr/bin/env python3
"""Compare the browser model against the original pinned TFLite checkpoint.

Requires numpy and tensorflow. Fixtures contain synthetic coordinates only.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import tensorflow as tf

from setup_asl_model import APP, MANIFEST, sha256

CASES = ["right", "left", "both", "stationary", "missing_face", "missing_pose", "empty"]
FIXTURE = APP / "test/fixtures/asl_model_reference.json"


def synthetic_input(kind):
    values = np.full((30, 543, 3), np.nan, dtype=np.float32)
    for frame in range(30):
        if kind == "empty":
            continue
        groups = []
        if kind != "missing_face":
            groups.append((0, 468, .4))
        if kind != "missing_pose":
            groups.append((489, 33, .4))
        if kind in ("left", "both"):
            groups.append((468, 21, .6 - frame * .002))
        if kind != "left":
            groups.append((522, 21, .3 if kind == "stationary" else .3 + frame * .004))
        for offset, count, x in groups:
            for point in range(count):
                values[frame, offset + point] = (x + point * .0001, .35 + point * .0002, -.01)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Original upstream weights/model.tflite")
    parser.add_argument("--write-fixture", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    original = args.source.read_bytes()
    assert sha256(original) == manifest["source_checkpoint_sha256"]
    browser = (APP / "web/models" / manifest["model_file"]).read_bytes()
    assert sha256(browser) == manifest["model_sha256"]
    offset = manifest["browser_adaptation"]["input_shape_byte_offset"]
    assert original[:offset] == browser[:offset] and original[offset + 4:] == browser[offset + 4:]
    reference = tf.lite.Interpreter(model_content=original).get_signature_runner()
    adapted = tf.lite.Interpreter(model_content=browser).get_signature_runner()
    fixtures = {"source_sha256": manifest["source_checkpoint_sha256"], "cases": []}
    maximum = 0.0
    for name in CASES:
        values = synthetic_input(name)
        expected = reference(inputs=values)["outputs"].reshape(-1)
        actual = adapted(inputs=values)["outputs"].reshape(-1)
        np.testing.assert_allclose(actual, expected, atol=1e-6, rtol=1e-5)
        assert expected.shape == (250,) and np.isfinite(expected).all()
        assert abs(float(expected.sum()) - 1) < .001
        maximum = max(maximum, float(np.max(np.abs(actual - expected))))
        fixtures["cases"].append({"name": name, "probabilities": expected.tolist()})
    if args.write_fixture:
        FIXTURE.write_text(json.dumps(fixtures, indent=2) + "\n")
    else:
        recorded = json.loads(FIXTURE.read_text())
        for actual, expected in zip(fixtures["cases"], recorded["cases"], strict=True):
            assert actual["name"] == expected["name"]
            np.testing.assert_allclose(actual["probabilities"], expected["probabilities"], atol=1e-5)
    print(f"Verified {len(CASES)} native equivalence cases; maximum probability error {maximum}")


if __name__ == "__main__":
    main()
