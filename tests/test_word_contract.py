from __future__ import annotations

import copy
import json
import re
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, FormatChecker
from pydantic import ValidationError

from scripts.export_word_contract import artifacts
from simplynext.contracts.translated_sign_utterance import (
    TranslatedSignUtteranceV1,
    canonical_digest,
    parse_value,
)

ROOT = Path(__file__).parents[1]
FIXTURE = ROOT / "tests/fixtures/translated_sign_utterance_v1.json"
SCHEMA = ROOT / "src/simplynext/contracts/schemas/translated-sign-utterance-v1.json"
CASES = json.loads((ROOT / "tests/fixtures/translated_sign_invalid_v1.json").read_text())


def test_canonical_fixture_and_schema_match_frozen_document() -> None:
    contract = ROOT / "TRANSLATED_SIGN_UTTERANCE_V1.md"
    blocks = [
        json.loads(block)
        for block in re.findall(r"```json\n(.*?)\n```", contract.read_text(), re.S)
    ]
    schema = json.loads(SCHEMA.read_text())
    assert schema == blocks[1]
    Draft202012Validator.check_schema(schema)
    canonical = json.loads(FIXTURE.read_text())
    assert canonical == blocks[0]
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(canonical)
    assert (
        parse_value(TranslatedSignUtteranceV1, FIXTURE.read_bytes()).model_dump(mode="json")
        == canonical
    )


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_shared_invalid_fixture_table(case: dict) -> None:
    raw = case.get("raw_json", json.dumps(case.get("payload")))
    with pytest.raises((ValueError, ValidationError, RecursionError)):
        parse_value(TranslatedSignUtteranceV1, raw)
    if case["layer"] == "schema":
        validator = Draft202012Validator(
            json.loads(SCHEMA.read_text()), format_checker=FormatChecker()
        )
        assert not validator.is_valid(case["payload"])


def test_no_silent_normalization_and_equivalent_retry_digest() -> None:
    payload = json.loads(FIXTURE.read_text())
    one = parse_value(TranslatedSignUtteranceV1, json.dumps(payload))
    payload["words"][0]["confidence"] = 1
    payload["words"][0]["alternatives"] = []
    two = parse_value(TranslatedSignUtteranceV1, json.dumps(payload))
    payload["words"][0]["confidence"] = 1.0
    assert canonical_digest(two) == canonical_digest(
        parse_value(
            TranslatedSignUtteranceV1,
            json.dumps(payload, sort_keys=True),
        )
    )
    assert canonical_digest(one) != canonical_digest(two)


def test_integral_json_numbers_match_normative_integer_semantics() -> None:
    payload = json.loads(FIXTURE.read_text())
    original = parse_value(TranslatedSignUtteranceV1, json.dumps(payload))
    payload["client_sequence"] = 0.0
    payload["words"][0]["index"] = 0.0
    payload["words"][0]["alternatives"][0]["rank"] = 2.0
    Draft202012Validator(json.loads(SCHEMA.read_text())).validate(payload)
    assert canonical_digest(original) == canonical_digest(
        parse_value(
            TranslatedSignUtteranceV1,
            json.dumps(payload),
        )
    )


def test_valid_word_boundaries_and_score_semantics() -> None:
    payload = json.loads(FIXTURE.read_text())
    payload["words"] = [
        dict(
            index=i,
            token_id=f"t-{i}",
            word="DON'T" if i % 2 else "ICE-CREAM",
            confidence=1,
            alternatives=[],
        )
        for i in range(64)
    ]
    assert len(parse_value(TranslatedSignUtteranceV1, json.dumps(payload)).words) == 64
    payload["words"] = [
        dict(
            index=0,
            token_id="a" * 80,
            word="A" * 80,
            confidence=0.8,
            alternatives=[dict(rank=i, word=f"WORD{i}", confidence=0.5) for i in range(2, 6)],
        )
    ]
    assert (
        len(parse_value(TranslatedSignUtteranceV1, json.dumps(payload)).words[0].alternatives) == 4
    )
    payload["words"][0]["word"] = "7"
    parse_value(TranslatedSignUtteranceV1, json.dumps(payload))  # scores need not sum to one


def test_generated_client_and_event_resources_have_no_drift() -> None:
    for path, expected in artifacts().items():
        assert path.read_text() == expected


def test_admitted_value_is_deeply_immutable() -> None:
    utterance = parse_value(TranslatedSignUtteranceV1, FIXTURE.read_bytes())
    with pytest.raises(ValidationError):
        utterance.words[0].word = "WATER"
    assert isinstance(utterance.words, tuple)
    changed = copy.deepcopy(utterance.model_dump(mode="json"))
    changed["producer"]["translator_version"] = "2.0.0"
    with pytest.raises(ValidationError):
        parse_value(TranslatedSignUtteranceV1, json.dumps(changed))
