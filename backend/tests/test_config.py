from __future__ import annotations

import pytest
from pydantic import SecretStr, ValidationError

from simplynext.config import Settings


def test_railway_port_overrides_local_prefixed_port(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SIMPLYNEXT_PORT", "8123")
    monkeypatch.delenv("PORT", raising=False)
    assert Settings(_env_file=None).port == 8123

    monkeypatch.setenv("PORT", "9123")
    assert Settings(_env_file=None).port == 9123


@pytest.mark.parametrize("value", ["0", "65536", "not-a-port"])
def test_railway_port_obeys_existing_safe_range(
    value: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("PORT", value)
    with pytest.raises(ValidationError, match="(?i)port"):
        Settings(_env_file=None)


def test_production_hosts_and_operator_docs_require_explicit_controls() -> None:
    settings = Settings(
        _env_file=None,
        environment="production",
        allowed_hosts=("example.up.railway.app",),
        operator_docs_enabled=True,
        operator_docs_token=SecretStr("docs-secret"),
    )
    assert settings.allowed_hosts == ("example.up.railway.app",)

    with pytest.raises(ValidationError, match="operator_docs_token"):
        Settings(
            _env_file=None,
            environment="production",
            allowed_hosts=("example.up.railway.app",),
            operator_docs_enabled=True,
        )

    with pytest.raises(ValidationError, match="allowed_hosts"):
        Settings(_env_file=None, environment="production", allowed_hosts=("*",))


def test_allowed_hosts_parse_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SIMPLYNEXT_ALLOWED_HOSTS", "api.example.com, api.example.com")
    assert Settings(_env_file=None).allowed_hosts == ("api.example.com", "api.example.com")
