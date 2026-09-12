from __future__ import annotations

import json
import logging
from decimal import Decimal
from types import SimpleNamespace
from typing import Any

import pytest
from pydantic import ValidationError

from simplynext.agent import (
    BedrockBudgetExceeded,
    BedrockCostGuard,
    BedrockPreflightError,
    BedrockPricing,
    BedrockTokenUsage,
    BedrockUsageUnavailable,
    CostGuardedConverseClient,
    preflight_bedrock_access,
    preflight_bedrock_runtime_access,
)
from simplynext.config import DEFAULT_BEDROCK_MODEL_ID, Settings
from simplynext.observability import MetricsRegistry

MODEL_ID = DEFAULT_BEDROCK_MODEL_ID


class FakeRuntimeClient:
    def __init__(self, *responses: dict[str, object] | BaseException) -> None:
        self.responses = list(responses)
        self.calls: list[dict[str, Any]] = []

    def converse(self, **kwargs: Any) -> dict[str, object]:
        self.calls.append(kwargs)
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


class FakeControlClient:
    def __init__(
        self,
        *,
        region_name: str = "ap-southeast-1",
        status: str = "ACTIVE",
        model_id: str = MODEL_ID,
    ) -> None:
        self.meta = SimpleNamespace(region_name=region_name)
        self.status = status
        self.model_id = model_id
        self.calls: list[dict[str, object]] = []

    def get_inference_profile(self, **kwargs: Any) -> dict[str, object]:
        self.calls.append(kwargs)
        return {
            "inferenceProfileId": self.model_id,
            "status": self.status,
            "models": [{"modelArn": "arn:aws:bedrock:example:model"}],
        }

    def get_foundation_model(self, **kwargs: Any) -> dict[str, object]:
        self.calls.append(kwargs)
        return {
            "modelDetails": {
                "modelId": self.model_id,
                "modelLifecycle": {"status": self.status},
            }
        }


def pricing() -> BedrockPricing:
    return BedrockPricing(model_id=MODEL_ID)


def response_with_usage(
    *,
    payload: object = "ok",
    input_tokens: int = 100,
    output_tokens: int = 20,
    cache_write_tokens: int = 10,
    cache_read_tokens: int = 30,
) -> dict[str, object]:
    return {
        "output": {"message": {"content": [{"text": json.dumps(payload)}]}},
        "usage": {
            "inputTokens": input_tokens,
            "outputTokens": output_tokens,
            "totalTokens": input_tokens + output_tokens,
            "cacheWriteInputTokens": cache_write_tokens,
            "cacheReadInputTokens": cache_read_tokens,
        },
    }


def guarded_client(
    raw: FakeRuntimeClient,
    *,
    spend_limit_usd: Decimal = Decimal("0.10"),
    metrics: MetricsRegistry | None = None,
) -> CostGuardedConverseClient:
    return CostGuardedConverseClient(
        client=raw,
        guard=BedrockCostGuard(pricing=pricing(), spend_limit_usd=spend_limit_usd),
        metrics=metrics,
    )


def converse_request() -> dict[str, object]:
    return {
        "modelId": MODEL_ID,
        "system": [{"text": "Stable safety instructions."}],
        "messages": [{"role": "user", "content": [{"text": "WATER PLEASE"}]}],
        "inferenceConfig": {"maxTokens": 100, "temperature": 0.0},
        "requestMetadata": {
            "simplynext_role": "assembler",
            "simplynext_utterance_id": "utterance-42",
        },
    }


def test_cost_guard_accounts_for_all_token_classes_and_adds_a_cache_checkpoint(
    caplog: pytest.LogCaptureFixture,
) -> None:
    metrics = MetricsRegistry()
    raw = FakeRuntimeClient(response_with_usage())
    client = guarded_client(raw, metrics=metrics)
    request = converse_request()

    with caplog.at_level(logging.INFO, logger="simplynext.agent.bedrock_access"):
        response = client.converse(**request)

    expected_cost = Decimal("0.00023705")
    assert response["usage"]["inputTokens"] == 100
    assert request["system"] == [{"text": "Stable safety instructions."}]
    assert raw.calls[0]["system"][-1] == {"cachePoint": {"type": "default"}}
    assert client.spend.estimated_spend_usd == expected_cost
    assert client.spend.reserved_usd == 0
    assert "utterance_id=utterance-42" in caplog.text
    assert "estimated_cost_usd=0.00023705" in caplog.text
    assert "utterance_estimated_cost_usd=0.00023705" in caplog.text
    assert "WATER PLEASE" not in caplog.text
    assert "Stable safety instructions." not in caplog.text
    utterance_cost = client.utterance_cost("utterance-42")
    assert utterance_cost is not None
    assert utterance_cost.model_calls == 1
    assert metrics.snapshot()["counters"] == {
        "bedrock_cache_read_input_tokens": 30,
        "bedrock_cache_write_input_tokens": 10,
        "bedrock_estimated_cost_nano_usd": 237_050,
        "bedrock_input_tokens": 100,
        "bedrock_model_calls_succeeded": 1,
        "bedrock_model_calls_total": 1,
        "bedrock_output_tokens": 20,
    }


def test_lowered_spend_ceiling_blocks_the_call_before_dispatch() -> None:
    raw = FakeRuntimeClient(response_with_usage())
    metrics = MetricsRegistry()
    client = guarded_client(
        raw,
        spend_limit_usd=Decimal("0.000001"),
        metrics=metrics,
    )

    with pytest.raises(BedrockBudgetExceeded, match="ceiling"):
        client.converse(**converse_request())

    assert raw.calls == []
    assert client.spend.estimated_spend_usd == 0
    assert client.spend.rejected_calls == 1
    assert metrics.snapshot()["counters"] == {
        "bedrock_model_calls_budget_rejected": 1,
        "bedrock_model_calls_total": 1,
    }


def test_missing_usage_fails_closed_and_commits_the_full_reservation() -> None:
    raw = FakeRuntimeClient({"output": {"message": {"content": [{"text": "ok"}]}}})
    client = guarded_client(raw)

    with pytest.raises(BedrockUsageUnavailable, match="token usage"):
        client.converse(**converse_request())

    assert client.spend.completed_calls == 1
    assert client.spend.estimated_spend_usd > 0
    assert client.spend.reserved_usd == 0


def test_usage_cost_is_exact_and_rejects_bool_or_negative_counts() -> None:
    usage = BedrockTokenUsage(
        input_tokens=100,
        output_tokens=20,
        cache_write_input_tokens=10,
        cache_read_input_tokens=30,
    )

    assert usage.total_input_tokens == 140
    assert pricing().usage_cost_usd(usage) == Decimal("0.00023705")
    with pytest.raises(ValueError, match="non-negative integer"):
        BedrockTokenUsage(input_tokens=True, output_tokens=1)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="non-negative integer"):
        BedrockTokenUsage(input_tokens=1, output_tokens=-1)


def test_non_billable_preflight_checks_region_profile_and_active_status() -> None:
    control = FakeControlClient()

    result = preflight_bedrock_access(
        control,
        region_name="ap-southeast-1",
        model_id=MODEL_ID,
    )

    assert result.region_name == "ap-southeast-1"
    assert result.model_id == MODEL_ID
    assert result.status == "ACTIVE"
    assert control.calls == [{"inferenceProfileIdentifier": MODEL_ID}]

    with pytest.raises(BedrockPreflightError, match="region"):
        preflight_bedrock_access(
            FakeControlClient(region_name="us-east-1"),
            region_name="ap-southeast-1",
            model_id=MODEL_ID,
        )
    with pytest.raises(BedrockPreflightError, match="not active"):
        preflight_bedrock_access(
            FakeControlClient(status="INACTIVE"),
            region_name="ap-southeast-1",
            model_id=MODEL_ID,
        )


def test_preflight_also_accepts_an_active_region_local_foundation_model() -> None:
    model_id = "anthropic.claude-haiku-4-5-20251001-v1:0"
    control = FakeControlClient(model_id=model_id)

    result = preflight_bedrock_access(
        control,
        region_name="ap-southeast-1",
        model_id=model_id,
    )

    assert result.status == "ACTIVE"
    assert control.calls == [{"modelIdentifier": model_id}]


def test_runtime_preflight_is_cost_guarded_and_actionable() -> None:
    raw = FakeRuntimeClient(
        response_with_usage(
            payload="OK",
            input_tokens=20,
            output_tokens=1,
            cache_write_tokens=0,
            cache_read_tokens=0,
        )
    )
    client = guarded_client(raw)

    preflight_bedrock_runtime_access(
        client,
        region_name="ap-southeast-1",
        model_id=MODEL_ID,
    )

    assert client.spend.completed_calls == 1
    assert raw.calls[0]["requestMetadata"] == {
        "simplynext_role": "preflight",
        "simplynext_utterance_id": "bedrock-access-preflight",
    }

    failing = guarded_client(FakeRuntimeClient(PermissionError("denied")))
    with pytest.raises(BedrockPreflightError, match="aws sso login"):
        preflight_bedrock_runtime_access(
            failing,
            region_name="ap-southeast-1",
            model_id=MODEL_ID,
        )


def test_bedrock_settings_require_a_named_owner_and_budget_headroom() -> None:
    with pytest.raises(ValidationError, match="lease_owner"):
        Settings(_env_file=None, bedrock_enabled=True, bedrock_lease_owner=None)
    with pytest.raises(ValidationError, match="known_spend"):
        Settings(
            _env_file=None,
            bedrock_known_spend_usd=Decimal("5.01"),
            bedrock_spend_limit_usd=Decimal("5.00"),
        )

    configured = Settings(
        _env_file=None,
        bedrock_enabled=True,
        bedrock_lease_owner="team-owner",
        bedrock_spend_limit_usd=Decimal("0.50"),
    )
    assert configured.bedrock_model_id == MODEL_ID

    with pytest.raises(ValidationError, match="explicit pricing"):
        Settings(
            _env_file=None,
            bedrock_model_id="global.anthropic.some-other-model-v1:0",
        )


def test_anthropic_settings_require_owner_and_verified_pricing() -> None:
    with pytest.raises(ValidationError, match="anthropic_lease_owner"):
        Settings(
            _env_file=None,
            anthropic_enabled=True,
            anthropic_input_usd_per_million_tokens=Decimal("1.00"),
            anthropic_output_usd_per_million_tokens=Decimal("5.00"),
            anthropic_cache_write_usd_per_million_tokens=Decimal("1.25"),
            anthropic_cache_read_usd_per_million_tokens=Decimal("0.10"),
        )
    with pytest.raises(ValidationError, match="all four anthropic pricing"):
        Settings(
            _env_file=None,
            anthropic_enabled=True,
            anthropic_lease_owner="team-owner",
        )

    configured = Settings(
        _env_file=None,
        anthropic_enabled=True,
        anthropic_lease_owner="team-owner",
        anthropic_input_usd_per_million_tokens=Decimal("1.00"),
        anthropic_output_usd_per_million_tokens=Decimal("5.00"),
        anthropic_cache_write_usd_per_million_tokens=Decimal("1.25"),
        anthropic_cache_read_usd_per_million_tokens=Decimal("0.10"),
    )
    assert configured.anthropic_model_id == "claude-haiku-4-5-20251001"

    with pytest.raises(ValidationError, match="only one hosted model"):
        Settings(
            _env_file=None,
            bedrock_enabled=True,
            bedrock_lease_owner="bedrock-owner",
            anthropic_enabled=True,
            anthropic_lease_owner="anthropic-owner",
            anthropic_input_usd_per_million_tokens=Decimal("1.00"),
            anthropic_output_usd_per_million_tokens=Decimal("5.00"),
            anthropic_cache_write_usd_per_million_tokens=Decimal("1.25"),
            anthropic_cache_read_usd_per_million_tokens=Decimal("0.10"),
        )
