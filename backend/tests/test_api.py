from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from simplynext.config import Settings
from simplynext.main import create_app

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "gloss_lattice_v1.json"


def _producer() -> dict[str, str]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))["producer"]


def _session_request() -> dict[str, Any]:
    return {
        "language": "sgsl",
        "schema_version": "1.0",
        "stream_kind": "gloss_lattice",
        "client": {
            "platform": "test",
            "app_version": "integration-test",
            "device_model": "test-client",
        },
        "detector": {
            "name": "frontend-perception",
            "version": "1",
            "delegate": "cpu",
        },
        "producer": _producer(),
    }


def _authorization(session: dict[str, Any]) -> dict[str, str]:
    return {"Authorization": f"Bearer {session['stream_token']}"}


@pytest.fixture
def client() -> Iterator[TestClient]:
    app = create_app(
        Settings(
            _env_file=None,
            environment="test",
            allowed_origins=(),
            bedrock_enabled=False,
            caption_templates_path=None,
            recognition_language="sgsl",
        )
    )
    with TestClient(app) as test_client:
        yield test_client


def test_health_and_unconfigured_readiness_are_honest(client: TestClient) -> None:
    assert client.get("/healthz").json()["status"] == "ok"
    readiness = client.get("/readyz")

    assert readiness.status_code == 503
    assert readiness.json()["status"] == "lattice_assembler_unconfigured"
    assert readiness.json()["lattice_transport"]["ready"] is True
    assert readiness.json()["agent"]["ready"] is True
    assert readiness.json()["assembler"]["ready"] is False


def test_only_gloss_lattice_application_routes_are_registered(client: TestClient) -> None:
    paths = {route.path for route in client.app.routes if hasattr(route, "path")}

    assert "/v1/sessions/{session_id}/lattices" in paths
    assert "/v1/sessions/{session_id}/landmarks" not in paths
    assert "/v1/utterances" not in paths


def test_session_creation_returns_only_lattice_limits(client: TestClient) -> None:
    response = client.post("/v1/sessions", json=_session_request())

    assert response.status_code == 201
    session = response.json()
    assert session["token_type"] == "Bearer"
    assert session["stream_kind"] == "gloss_lattice"
    assert session["websocket_path"].endswith("/lattices")
    assert session["lattice_schema_version"] == "1.0"
    assert session["max_lattice_message_bytes"] == 32_768
    assert session["max_lattice_slots"] == 64
    assert session["max_candidates_per_slot"] == 5
    assert {"layout", "max_batch_frames", "target_fps"}.isdisjoint(session)


def test_session_creation_global_rate_limit_maps_to_429() -> None:
    app = create_app(
        Settings(
            _env_file=None,
            environment="test",
            allowed_origins=(),
            max_session_creations_per_minute_global=1,
            bedrock_enabled=False,
            caption_templates_path=None,
            recognition_language="sgsl",
        )
    )
    with TestClient(app) as limited:
        assert limited.post("/v1/sessions", json=_session_request()).status_code == 201
        response = limited.post("/v1/sessions", json=_session_request())
        assert response.status_code == 429
        assert response.json()["detail"] == "global session creation rate limit exceeded"


def test_legacy_session_shape_is_rejected(client: TestClient) -> None:
    payload = _session_request()
    payload["stream_kind"] = "landmarks"
    payload["landmark_batch"] = {"frames": []}

    assert client.post("/v1/sessions", json=payload).status_code == 422


def test_session_deletion_requires_the_bearer_capability(client: TestClient) -> None:
    session = client.post("/v1/sessions", json=_session_request()).json()
    path = f"/v1/sessions/{session['session_id']}"

    assert client.delete(path).status_code == 401
    assert client.delete(path, headers={"Authorization": "Bearer wrong-token"}).status_code == 401
    assert client.delete(path, headers=_authorization(session)).status_code == 204
    assert client.delete(path, headers=_authorization(session)).status_code == 404


def _production_client(*, docs: bool = False) -> TestClient:
    app = create_app(
        Settings(
            _env_file=None,
            environment="production",
            allowed_origins=(),
            allowed_hosts=("testserver",),
            operator_docs_enabled=docs,
            operator_docs_token=SecretStr("docs-secret") if docs else None,
            operator_metrics_token=SecretStr("metrics-secret"),
            bedrock_enabled=False,
            caption_templates_path=None,
            recognition_language="sgsl",
        )
    )
    return TestClient(app)


def test_production_hides_docs_and_requires_dedicated_metrics_token() -> None:
    with _production_client() as production:
        assert production.get("/").json()["docs"] == "disabled"
        assert production.get("/docs").status_code == 404
        assert production.get("/openapi.json").status_code == 404
        assert production.get("/redoc").status_code == 404
        assert production.get("/metrics").status_code == 401
        assert (
            production.get(
                "/metrics", headers={"Authorization": "Bearer wrong"}
            ).status_code
            == 401
        )
        assert production.get(
            "/metrics", headers={"Authorization": "Bearer metrics-secret"}
        ).status_code == 200


def test_operator_docs_override_is_bearer_protected() -> None:
    with _production_client(docs=True) as production:
        assert production.get("/docs").status_code == 401
        headers = {"Authorization": "Bearer docs-secret"}
        assert production.get("/docs", headers=headers).status_code == 200
        assert production.get("/openapi.json", headers=headers).status_code == 200


def test_production_rejects_unlisted_host() -> None:
    with _production_client() as production:
        assert production.get("/healthz", headers={"host": "evil.example"}).status_code == 400
