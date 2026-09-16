import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from scripts.benchmark_rooms import benchmark
from scripts.production_preflight import check
from simplynext.config import Settings
from simplynext.main import create_app


def production(**updates):
    values = dict(
        environment="production",
        host="0.0.0.0",
        allowed_hosts=("api.test.example",),
        operator_metrics_token=SecretStr("x" * 43),
    )
    values.update(updates)
    return Settings(_env_file=None, **values)


def test_production_configuration_gate_checks_concrete_controls_without_provider_calls():
    assert check(production())["configuration"] == "passed"
    for values in (
        {"environment": "test"},
        {"host": "127.0.0.1"},
        {"allowed_hosts": ("api.example.invalid",)},
        {"operator_metrics_token": None},
        {"operator_docs_enabled": True, "operator_docs_token": SecretStr("docs")},
    ):
        with pytest.raises(ValueError):
            check(production(**values))


@pytest.mark.parametrize("count", [60, 120, 240])
async def test_mixed_hour_benchmark_uses_real_graph_with_no_network(count):
    result = await benchmark(count)
    assert result["model_calls"] == count
    bounds = result["metrics"]["values"]
    assert bounds["context_assembler_token_bound"]["maximum"] <= 8000
    assert bounds["context_critic_token_bound"]["maximum"] <= 3000
    assert result["metrics"]["counters"]["room_admission_cached"] == count // 2


def test_unexpected_server_error_is_private_and_contains_no_exception_text():
    app = create_app(Settings(_env_file=None, environment="test"))

    @app.get("/v1/rooms/failure-test")
    async def broken():
        raise RuntimeError("PRIVATE request-body prompt credential")

    # Use a distinct route outside the existing {code} route's matching path.
    @app.get("/test-internal-failure")
    async def failure():
        return await broken()

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/test-internal-failure")
        assert response.status_code == 500
        assert response.json() == {"error": "internal_error"}
        assert response.headers["cache-control"] == "no-store"
        assert "PRIVATE" not in response.text


def test_production_manifest_is_single_region_and_single_replica():
    document = json.loads((Path(__file__).parents[1] / "railway.json").read_text())
    regions = document["deploy"]["multiRegionConfig"]
    assert len(regions) == 1 and sum(r["numReplicas"] for r in regions.values()) == 1
    assert document["deploy"]["healthcheckPath"] == "/readyz"
