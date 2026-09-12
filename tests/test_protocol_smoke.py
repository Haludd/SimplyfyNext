from __future__ import annotations

from argparse import Namespace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID

import pytest

from scripts.protocol_smoke import (
    DEFAULT_CONFIDENT_FIXTURE,
    DEFAULT_REPAIR_FIXTURE,
    SmokeFailure,
    _http_url,
    _prepared_lattice,
    _require_explicit_live_spend_confirmation,
    _session_request,
    _websocket_url,
)
from simplynext.config import Settings
from simplynext.contracts import SessionCreateResponse


def _args(**updates: object) -> Namespace:
    values: dict[str, object] = {
        "base_url": "http://127.0.0.1:8000",
        "language": None,
        "classifier_id": None,
        "classifier_version": None,
        "calibration_version": None,
        "vocabulary_version": None,
        "confident_fixture": DEFAULT_CONFIDENT_FIXTURE,
        "repair_fixture": DEFAULT_REPAIR_FIXTURE,
        "expect_agent_source": "bedrock_graph",
        "confirm_live_spend": False,
        "timeout_seconds": 45.0,
    }
    values.update(updates)
    return Namespace(**values)


def _session() -> SessionCreateResponse:
    now = datetime.now(UTC)
    return SessionCreateResponse(
        session_id=UUID("20000000-0000-4000-8000-000000000001"),
        stream_token="x" * 32,
        websocket_path="/v1/sessions/20000000-0000-4000-8000-000000000001/lattices",
        created_at=now,
        expires_at=now + timedelta(minutes=5),
    )


def test_live_mode_requires_an_explicit_spend_confirmation_before_network_use() -> None:
    with pytest.raises(SmokeFailure, match="confirm-live-spend"):
        _require_explicit_live_spend_confirmation(_args())

    _require_explicit_live_spend_confirmation(_args(confirm_live_spend=True))
    _require_explicit_live_spend_confirmation(
        _args(expect_agent_source="deterministic_template")
    )


def test_phase1_fixtures_are_valid_and_bound_to_the_negotiated_session() -> None:
    settings = Settings(
        _env_file=None,
        recognition_language="asl",
        lattice_classifier_id="released_classifier",
        lattice_classifier_version="2.0",
        lattice_calibration_version="calibration_2",
        lattice_vocabulary_version="asl_release_2",
    )
    request = _session_request(settings, _args())

    confident = _prepared_lattice(
        DEFAULT_CONFIDENT_FIXTURE,
        session=_session(),
        request=request,
        lattice_seq=0,
    )
    repair = _prepared_lattice(
        DEFAULT_REPAIR_FIXTURE,
        session=_session(),
        request=request,
        lattice_seq=1,
    )

    assert confident.session_id == repair.session_id == _session().session_id
    assert confident.language == repair.language == "asl"
    assert confident.producer == repair.producer == request.producer
    assert confident.slots[0].resolved_gloss_id == "HELLO"
    assert repair.slots[0].resolved_gloss_id is None
    assert len(repair.slots[0].candidates) == 2


def test_fixture_failure_reports_only_the_file_name(tmp_path: Path) -> None:
    outside_text = "sensitive-payload-must-not-be-reported"
    invalid = tmp_path / "invalid-fixture.json"
    invalid.write_text(outside_text, encoding="utf-8")
    settings = Settings(_env_file=None, recognition_language="sgsl")

    with pytest.raises(SmokeFailure) as captured:
        _prepared_lattice(
            invalid,
            session=_session(),
            request=_session_request(settings, _args()),
            lattice_seq=0,
        )

    assert invalid.name in str(captured.value)
    assert outside_text not in str(captured.value)


def test_http_and_websocket_urls_are_validated_without_credentials() -> None:
    assert _http_url("https://api.example.test/", "/v1/sessions") == (
        "https://api.example.test/v1/sessions"
    )
    assert _websocket_url("https://api.example.test", "/v1/socket") == (
        "wss://api.example.test/v1/socket"
    )
    with pytest.raises(SmokeFailure, match="credentials"):
        _websocket_url("https://user:secret@example.test", "/v1/socket")
