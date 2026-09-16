from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr, ValidationError

from simplynext.config import Settings
from simplynext.main import create_app


def test_room_readiness_does_not_claim_unconfigured_sentence_acceptance():
    with TestClient(create_app(Settings(_env_file=None, environment="test"))) as client:
        assert client.get("/healthz").status_code == 200
        ready = client.get("/readyz")
        assert ready.status_code == 200
        assert ready.json()["rooms"]["transport_ready"]
        assert not ready.json()["rooms"]["sentence_acceptance_ready"]
        assert ready.json()["rooms"]["word_provider"] == "disabled"
        assert not ready.json()["rooms"]["word_policy_configured"]
        assert ready.json()["rooms"]["source_language"] == "asl"


def test_room_readiness_reports_local_template_sentence_mode() -> None:
    root = Path(__file__).parents[1]
    settings = Settings(
        _env_file=None,
        environment="test",
        word_policy_path=root / "data/word_policy.synthetic.json",
        word_templates_path=root / "data/word_templates.example.json",
    )
    with TestClient(create_app(settings)) as client:
        rooms = client.get("/readyz").json()["rooms"]
        assert rooms["sentence_acceptance_ready"]
        assert rooms["word_provider"] == "templates"
        assert rooms["word_templates_configured"]


def test_retired_routes_are_absent_and_non_asl_startup_fails():
    with TestClient(create_app(Settings(_env_file=None))) as client:
        assert client.post("/v1/sessions", json={"stream_kind": "gloss_lattice"}).status_code == 404
        assert client.post("/v1/utterances", json={}).status_code == 404
        assert all("lattices" not in getattr(r, "path", "") for r in client.app.routes)
    with pytest.raises(ValidationError):
        Settings(_env_file=None, recognition_language="sgsl")


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
            production.get("/metrics", headers={"Authorization": "Bearer wrong"}).status_code == 401
        )
        assert (
            production.get(
                "/metrics", headers={"Authorization": "Bearer metrics-secret"}
            ).status_code
            == 200
        )


def test_operator_docs_override_is_bearer_protected() -> None:
    with _production_client(docs=True) as production:
        assert production.get("/docs").status_code == 401
        headers = {"Authorization": "Bearer docs-secret"}
        assert production.get("/docs", headers=headers).status_code == 200
        assert production.get("/openapi.json", headers=headers).status_code == 200


def test_production_rejects_unlisted_host() -> None:
    with _production_client() as production:
        assert production.get("/healthz", headers={"host": "evil.example"}).status_code == 400
