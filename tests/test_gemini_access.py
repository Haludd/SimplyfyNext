from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from simplynext.agent.gemini_access import (
    GeminiConfigurationError,
    GeminiConverseAdapter,
    GeminiProviderError,
    create_gemini_client,
)


def _adapter(handler: httpx.MockTransport) -> GeminiConverseAdapter:
    return GeminiConverseAdapter(
        httpx.Client(base_url="https://generativelanguage.googleapis.com/v1beta/", transport=handler)
    )


def test_text_request_is_translated_and_response_preserves_internal_shape() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1beta/models/gemini-2.5-flash:generateContent"
        assert request.headers["x-goog-api-key"] == "test-key"
        body = json.loads(request.content)
        assert body["systemInstruction"] == {
            "parts": [{"text": "You are a strict JSON assistant."}]
        }
        assert body["contents"] == [
            {"role": "user", "parts": [{"text": "Return JSON."}]}
        ]
        assert body["generationConfig"] == {
            "maxOutputTokens": 40,
            "temperature": 0.0,
            "responseMimeType": "application/json",
        }
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {"parts": [{"text": '{"ok":true}'}]},
                        "finishReason": "STOP",
                    }
                ],
                "usageMetadata": {
                    "promptTokenCount": 12,
                    "candidatesTokenCount": 4,
                    "thoughtsTokenCount": 2,
                },
            },
            request=request,
        )

    adapter = _adapter(httpx.MockTransport(respond))
    adapter._client.headers["x-goog-api-key"] = "test-key"

    response = adapter.converse(
        modelId="gemini-2.5-flash",
        system=[{"text": "You are a strict JSON assistant."}],
        messages=[{"role": "user", "content": [{"text": "Return JSON."}]}],
        inferenceConfig={"maxTokens": 40, "temperature": 0.0},
        requestMetadata={"simplynext_role": "word_assembler"},
    )

    assert response == {
        "output": {"message": {"role": "assistant", "content": [{"text": '{"ok":true}'}]}},
        "stopReason": "end_turn",
        "usage": {
            "inputTokens": 12,
            "outputTokens": 6,
            "totalTokens": 18,
            "cacheWriteInputTokens": 0,
            "cacheReadInputTokens": 0,
        },
    }


def test_cached_usage_is_accounted_without_double_counting() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [{"content": {"parts": [{"text": "{}"}]}, "finishReason": "STOP"}],
                "usageMetadata": {
                    "promptTokenCount": 20,
                    "cachedContentTokenCount": 15,
                    "candidatesTokenCount": 3,
                },
            },
            request=request,
        )

    response = _adapter(httpx.MockTransport(respond)).converse(
        modelId="gemini-2.5-flash",
        messages=[{"role": "user", "content": [{"text": "Return JSON."}]}],
        inferenceConfig={"maxTokens": 40, "temperature": 0.0},
    )

    assert response["usage"] == {
        "inputTokens": 5,
        "outputTokens": 3,
        "totalTokens": 23,
        "cacheWriteInputTokens": 0,
        "cacheReadInputTokens": 15,
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
            modelId="gemini-2.5-flash",
            messages=[{"role": "user", "content": [{"text": "Return JSON."}]}],
            inferenceConfig={"maxTokens": 40, "temperature": 0.0},
        )
