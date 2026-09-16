from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

import httpx
import pytest
from pydantic import ValidationError

from simplynext.agent.gemini_access import (
    GeminiConfigurationError,
    GeminiConverseAdapter,
    GeminiProviderError,
    create_gemini_client,
)
from simplynext.config import Settings


def _adapter(handler: httpx.MockTransport) -> GeminiConverseAdapter:
    return GeminiConverseAdapter(
        httpx.Client(
            base_url="https://generativelanguage.googleapis.com/v1beta/",
            transport=handler,
        )
    )


def test_word_request_is_translated_and_usage_is_normalized() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1beta/models/gemini-3.1-flash-lite:generateContent"
        body = json.loads(request.content)
        assert body["generationConfig"]["responseMimeType"] == "application/json"
        assert body["systemInstruction"] == {"parts": [{"text": "Return strict JSON."}]}
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {"parts": [{"text": '{"supported":true}'}]},
                        "finishReason": "STOP",
                    }
                ],
                "usageMetadata": {
                    "promptTokenCount": 12,
                    "cachedContentTokenCount": 2,
                    "candidatesTokenCount": 4,
                    "thoughtsTokenCount": 1,
                },
            },
            request=request,
        )

    response = _adapter(httpx.MockTransport(respond)).converse(
        modelId="gemini-3.1-flash-lite",
        system=[{"text": "Return strict JSON."}],
        messages=[{"role": "user", "content": [{"text": "{}"}]}],
        inferenceConfig={"maxTokens": 40, "temperature": 0.0},
        requestMetadata={"simplynext_role": "word_critic"},
    )
    assert response["stopReason"] == "end_turn"
    assert response["usage"] == {
        "inputTokens": 10,
        "outputTokens": 5,
        "totalTokens": 17,
        "cacheWriteInputTokens": 0,
        "cacheReadInputTokens": 2,
    }


def test_missing_key_and_invalid_response_fail_closed(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(GeminiConfigurationError, match="GEMINI_API_KEY"):
        create_gemini_client(api_base_url="https://generativelanguage.googleapis.com/v1beta")

    def respond(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"candidates": []}, request=request)

    with pytest.raises(GeminiProviderError, match="no usable candidate"):
        _adapter(httpx.MockTransport(respond)).converse(
            modelId="gemini-3.1-flash-lite",
            messages=[{"role": "user", "content": [{"text": "{}"}]}],
            inferenceConfig={"maxTokens": 40, "temperature": 0.0},
        )


def test_gemini_requires_owner_pricing_and_exclusive_provider() -> None:
    pricing = {
        "gemini_input_usd_per_million_tokens": Decimal("0"),
        "gemini_output_usd_per_million_tokens": Decimal("0"),
        "gemini_cache_write_usd_per_million_tokens": Decimal("0"),
        "gemini_cache_read_usd_per_million_tokens": Decimal("0"),
    }
    with pytest.raises(ValidationError, match="gemini_lease_owner"):
        Settings(_env_file=None, gemini_enabled=True, **pricing)
    configured = Settings(
        _env_file=None,
        gemini_enabled=True,
        gemini_lease_owner="developer",
        **pricing,
    )
    assert configured.gemini_model_id == "gemini-3.1-flash-lite"
    with pytest.raises(ValidationError, match="only one hosted model"):
        Settings(
            _env_file=None,
            gemini_enabled=True,
            gemini_lease_owner="developer",
            bedrock_enabled=True,
            bedrock_lease_owner="developer",
            **pricing,
        )
