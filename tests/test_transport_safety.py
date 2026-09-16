from fastapi.testclient import TestClient

from simplynext.config import Settings
from simplynext.main import create_app


def _test_app(*, http_max_body_bytes: int = 4096):
    return create_app(
        Settings(
            _env_file=None,
            environment="test",
            allowed_origins=(),
            bedrock_enabled=False,
            http_max_body_bytes=http_max_body_bytes,
        )
    )


def test_oversized_http_body_is_rejected_before_validation() -> None:
    with TestClient(_test_app()) as client:
        response = client.post(
            "/v1/rooms",
            content=b"x" * 4097,
            headers={"content-type": "application/json"},
        )

    assert response.status_code == 413
    assert response.json() == {"error": "payload_too_large"}


def test_chunked_oversized_http_body_is_also_rejected() -> None:
    with TestClient(_test_app()) as client:
        response = client.post(
            "/v1/rooms",
            content=(b"x" * 1024 for _ in range(5)),
            headers={"content-type": "application/json"},
        )

    assert response.status_code == 413


def test_hypothesis_replay_endpoint_is_absent_by_default() -> None:
    with TestClient(_test_app()) as client:
        response = client.post("/v1/utterances", json={})

    assert response.status_code == 404
