"""Gemini GenerateContent adapter for the provider-neutral Converse contract.

The sentence assembler and critic use a compact internal ``converse`` protocol.
This module translates that protocol to Gemini's server-side GenerateContent REST
endpoint and normalizes its response for the existing cost guard. It accepts only
text generation; browser-originated API keys, tools, and media never enter it.
"""

from __future__ import annotations

import os
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, cast
from urllib.parse import quote

import httpx
from dotenv import dotenv_values


class GeminiConfigurationError(RuntimeError):
    """Raised when direct Gemini mode has invalid local configuration."""


class GeminiProviderError(RuntimeError):
    """Raised when a Gemini request or response cannot be safely normalized."""


class GeminiConverseAdapter:
    """Translate the internal Converse request shape to Gemini GenerateContent."""

    def __init__(self, client: httpx.Client) -> None:
        self._client = client

    def converse(self, **kwargs: Any) -> Mapping[str, Any]:
        model_id = _model_id(kwargs)
        payload = _build_generate_content_request(kwargs)
        endpoint = f"models/{quote(model_id, safe='-_.')}:generateContent"
        try:
            response = self._client.post(endpoint, json=payload)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            # Do not attach response bodies or URLs: either could reveal private input.
            raise GeminiProviderError("Gemini GenerateContent request failed") from exc
        try:
            raw = response.json()
        except ValueError as exc:
            raise GeminiProviderError("Gemini response was not valid JSON") from exc
        if not isinstance(raw, Mapping):
            raise GeminiProviderError("Gemini response was not an object")
        return _normalize_response(raw)


def create_gemini_client(
    *,
    api_base_url: str,
    connect_timeout_seconds: float = 5.0,
    read_timeout_seconds: float = 60.0,
    total_max_attempts: int = 1,
    max_connections: int = 4,
) -> GeminiConverseAdapter:
    """Create a bounded Gemini client without dispatching a request."""

    api_key = _read_gemini_api_key()
    if not api_key:
        raise GeminiConfigurationError(
            "Set GEMINI_API_KEY in the environment or local .env before enabling Gemini"
        )
    if total_max_attempts != 1:
        raise GeminiConfigurationError("Gemini total_max_attempts must be exactly one")
    base_url = api_base_url.strip().rstrip("/") + "/"
    if base_url == "/":
        raise GeminiConfigurationError("Gemini API base URL must not be empty")
    return GeminiConverseAdapter(
        httpx.Client(
            base_url=base_url,
            headers={"x-goog-api-key": api_key},
            timeout=httpx.Timeout(read_timeout_seconds, connect=connect_timeout_seconds),
            limits=httpx.Limits(
                max_connections=max_connections,
                max_keepalive_connections=max_connections,
            ),
        )
    )


def _read_gemini_api_key() -> str:
    """Read the server-side secret without adding it to settings or logs."""

    environment_value = os.environ.get("GEMINI_API_KEY", "").strip()
    if environment_value:
        return environment_value
    dotenv_value = dotenv_values(Path.cwd() / ".env").get("GEMINI_API_KEY")
    return dotenv_value.strip() if isinstance(dotenv_value, str) else ""


def _build_generate_content_request(request: Mapping[str, Any]) -> dict[str, Any]:
    _model_id(request)
    inference = request.get("inferenceConfig")
    if not isinstance(inference, Mapping):
        raise GeminiConfigurationError("Gemini request requires inferenceConfig")
    max_tokens = inference.get("maxTokens")
    temperature = inference.get("temperature")
    if type(max_tokens) is not int or max_tokens <= 0:
        raise GeminiConfigurationError("Gemini maxTokens must be a positive integer")
    if type(temperature) not in (int, float) or not 0 <= float(cast(float, temperature)) <= 1:
        raise GeminiConfigurationError("Gemini temperature must be between 0 and 1")
    if request.get("toolConfig") is not None:
        raise GeminiConfigurationError("Gemini word translation does not support tools")

    raw_messages = request.get("messages")
    if not isinstance(raw_messages, Sequence) or isinstance(raw_messages, (str, bytes)):
        raise GeminiConfigurationError("Gemini request messages must be a sequence")
    contents = [_message_to_gemini(message) for message in raw_messages]
    if not contents:
        raise GeminiConfigurationError("Gemini request messages must not be empty")

    generation_config: dict[str, Any] = {
        "maxOutputTokens": max_tokens,
        "temperature": float(cast(float, temperature)),
    }
    if _is_word_role(request.get("requestMetadata")):
        generation_config["responseMimeType"] = "application/json"

    result: dict[str, Any] = {"contents": contents, "generationConfig": generation_config}
    system_instruction = _system_to_gemini(request.get("system"))
    if system_instruction is not None:
        result["systemInstruction"] = system_instruction
    return result


def _model_id(request: Mapping[str, Any]) -> str:
    model_id = request.get("modelId")
    if not isinstance(model_id, str) or not model_id.strip():
        raise GeminiConfigurationError("Gemini request requires a non-empty modelId")
    return model_id.strip()


def _is_word_role(raw_metadata: object) -> bool:
    return isinstance(raw_metadata, Mapping) and raw_metadata.get("simplynext_role") in {
        "word_assembler",
        "word_critic",
    }


def _system_to_gemini(raw_system: object) -> dict[str, list[dict[str, str]]] | None:
    if raw_system is None:
        return None
    if not isinstance(raw_system, Sequence) or isinstance(raw_system, (str, bytes)):
        raise GeminiConfigurationError("Gemini system prompt must be a sequence")
    parts: list[dict[str, str]] = []
    for block in raw_system:
        if not isinstance(block, Mapping):
            raise GeminiConfigurationError("Gemini system block is malformed")
        if "cachePoint" in block:
            continue
        block_text = block.get("text")
        if not isinstance(block_text, str) or not block_text:
            raise GeminiConfigurationError("Gemini system text block is malformed")
        parts.append({"text": block_text})
    return {"parts": parts} if parts else None


def _message_to_gemini(raw_message: object) -> dict[str, Any]:
    if not isinstance(raw_message, Mapping):
        raise GeminiConfigurationError("Gemini message is malformed")
    role = raw_message.get("role")
    if role not in {"user", "assistant"}:
        raise GeminiConfigurationError("Gemini message role must be user or assistant")
    raw_content = raw_message.get("content")
    if not isinstance(raw_content, Sequence) or isinstance(raw_content, (str, bytes)):
        raise GeminiConfigurationError("Gemini message content must be a sequence")
    parts: list[dict[str, str]] = []
    for block in raw_content:
        if not isinstance(block, Mapping) or not isinstance(block.get("text"), str):
            raise GeminiConfigurationError("Gemini word translation only accepts text blocks")
        parts.append({"text": cast(str, block["text"])})
    if not parts:
        raise GeminiConfigurationError("Gemini message content must not be empty")
    return {"role": "model" if role == "assistant" else "user", "parts": parts}


def _normalize_response(raw: Mapping[str, Any]) -> Mapping[str, Any]:
    candidates = raw.get("candidates")
    if (
        not isinstance(candidates, Sequence)
        or isinstance(candidates, (str, bytes))
        or not candidates
    ):
        raise GeminiProviderError("Gemini response had no usable candidate")
    candidate = candidates[0]
    if not isinstance(candidate, Mapping):
        raise GeminiProviderError("Gemini response candidate was malformed")
    content = candidate.get("content")
    if not isinstance(content, Mapping):
        raise GeminiProviderError("Gemini response content was missing")
    parts = content.get("parts")
    if not isinstance(parts, Sequence) or isinstance(parts, (str, bytes)) or not parts:
        raise GeminiProviderError("Gemini response text was missing")
    texts: list[str] = []
    for part in parts:
        if not isinstance(part, Mapping) or not isinstance(part.get("text"), str):
            raise GeminiProviderError("Gemini response contained a non-text part")
        texts.append(cast(str, part["text"]))
    response_text = "".join(texts)
    if not response_text:
        raise GeminiProviderError("Gemini response text was empty")

    usage = raw.get("usageMetadata")
    if not isinstance(usage, Mapping):
        raise GeminiProviderError("Gemini response usage was missing")
    prompt_tokens = _usage_count(usage, "promptTokenCount", required=True)
    cached_tokens = _usage_count(usage, "cachedContentTokenCount", required=False)
    if cached_tokens > prompt_tokens:
        raise GeminiProviderError("Gemini cached token count exceeded prompt token count")
    output_tokens = _usage_count(usage, "candidatesTokenCount", required=True) + _usage_count(
        usage, "thoughtsTokenCount", required=False
    )
    finish_reason = candidate.get("finishReason")
    stop_reason = "end_turn" if finish_reason in {None, "STOP"} else str(finish_reason).lower()
    return {
        "output": {
            "message": {"role": "assistant", "content": [{"text": response_text}]}
        },
        "stopReason": stop_reason,
        "usage": {
            "inputTokens": prompt_tokens - cached_tokens,
            "outputTokens": output_tokens,
            "totalTokens": prompt_tokens + output_tokens,
            "cacheWriteInputTokens": 0,
            "cacheReadInputTokens": cached_tokens,
        },
    }


def _usage_count(usage: Mapping[str, Any], key: str, *, required: bool) -> int:
    value = usage.get(key)
    if value is None and not required:
        return 0
    if type(value) is not int or value < 0:
        raise GeminiProviderError(f"Gemini usage field {key} is invalid")
    return value


__all__ = [
    "GeminiConfigurationError",
    "GeminiConverseAdapter",
    "GeminiProviderError",
    "create_gemini_client",
]
