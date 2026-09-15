import asyncio
import json
import logging
import sys

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from simplynext.api.middleware import RequestBodyLimitMiddleware, SocketAdmissionMiddleware
from simplynext.config import Settings
from simplynext.main import create_app
from simplynext.observability.logging import JsonFormatter
from simplynext.observability.metrics import MetricsRegistry


@pytest.mark.parametrize(
    "origin",
    [
        "*",
        "https://*.example.com",
        "https://app.example.com/path",
        "https://app.example.com/",
        "https://user:secret@app.example.com",
        "https://app.example.com?x=y",
        "http://app.example.com",
        "null",
    ],
)
def test_production_requires_exact_https_origins(origin):
    with pytest.raises(ValidationError, match="allowed_origins"):
        Settings(_env_file=None, environment="production", allowed_origins=(origin,))


def test_log_formatter_drops_external_content_extras_and_exception_text():
    secret = "PRIVATE transcript capability prompt model output"
    formatter = JsonFormatter()
    try:
        raise RuntimeError(secret)
    except RuntimeError:
        error = sys.exc_info()
    for name in ("httpx", "anthropic", "botocore", "uvicorn.error", "uvicorn.access"):
        record = logging.LogRecord(name, logging.ERROR, "", 1, secret, (), error)
        record.capability = secret
        encoded = formatter.format(record)
        assert secret not in encoded
        assert json.loads(encoded)["exception_type"] == "RuntimeError"
    record = logging.LogRecord("simplynext.test", logging.ERROR, "", 1, "safe_code", (), error)
    record.body = secret
    assert secret not in formatter.format(record)


async def test_body_timeout_and_tiny_chunks_are_bounded():
    called = False

    async def app(scope, receive, send):
        nonlocal called
        called = True

    sent = []

    async def send(event):
        sent.append(event)

    async def slow_receive():
        await asyncio.sleep(1)
        return {"type": "http.request", "body": b""}

    middleware = RequestBodyLimitMiddleware(app, max_bytes=16384, timeout_seconds=0.01)
    await middleware({"type": "http", "path": "/v1/rooms"}, slow_receive, send)
    assert not called and sent[0]["status"] == 408


async def test_unauthenticated_socket_capacity_rate_and_disconnect_cleanup():
    entered, release = asyncio.Event(), asyncio.Event()

    async def app(scope, receive, send):
        entered.set()
        await release.wait()

    middleware = SocketAdmissionMiddleware(app, maximum=1, per_minute=1, global_per_minute=3)
    sent = []

    async def send(event):
        sent.append(event)

    async def receive():
        return {"type": "websocket.connect"}

    scope = {"type": "websocket", "client": ("127.0.0.1", 12)}
    task = asyncio.create_task(middleware(scope, receive, send))
    await entered.wait()
    await middleware(scope, receive, send)
    assert sent[-1]["code"] == 4429 and middleware.active == 1
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    assert middleware.active == 0
    await middleware(scope, receive, send)
    assert sent[-1]["code"] == 4429  # peer rate still applies after disconnect
    assert all("127.0.0.1" not in key for key in middleware.peers)


def test_private_headers_cover_origin_host_errors_and_diagnostics():
    app = create_app(Settings(_env_file=None, environment="test", allowed_origins=()))
    with TestClient(app) as client:
        for path, headers in (
            ("/healthz", {}),
            ("/metrics", {}),
            ("/v1/rooms", {"Origin": "https://evil.example"}),
            ("/v1/rooms", {"Host": "evil.example"}),
        ):
            result = client.get(path, headers=headers)
            assert result.headers["cache-control"] == "no-store"
            assert result.headers["referrer-policy"] == "no-referrer"


def test_runner_explicitly_disables_forwarded_ip_trust(monkeypatch):
    from simplynext import main

    options = {}
    monkeypatch.setattr(main.uvicorn, "run", lambda *args, **kwargs: options.update(kwargs))
    main.run()
    assert options["workers"] == 1
    assert options["proxy_headers"] is False and options["access_log"] is False
    assert options["ws_max_queue"] == 4


def test_percentiles_have_bounded_storage_and_reject_nonfinite_samples():
    metrics = MetricsRegistry()
    for i in range(1, 101):
        metrics.observe_ms("stage", i)
    result = metrics.snapshot()["timings"]["stage"]
    assert result["p50_ms"] == 50 and result["p95_ms"] == 95
    for i in range(5000):
        metrics.observe_ms("stage", i)
    assert metrics.snapshot()["timings"]["stage"]["sample_count"] == 2048
    for value in (float("nan"), float("inf"), -1):
        with pytest.raises(ValueError):
            metrics.observe_ms("stage", value)
