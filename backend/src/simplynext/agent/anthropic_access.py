"""Direct Anthropic Messages API adapter for the existing model-node contract.

The assembler and critic intentionally depend on the small ``converse`` protocol used
by the Bedrock implementation.  This module translates that internal request shape to
Anthropic's Messages API and normalizes the response back to the existing Bedrock-like
shape.  The public contracts and the evidence/grounding validators therefore remain
unchanged.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping, Sequence
from typing import Any, Protocol, cast

import httpx

# Anthropic structured outputs constrain the model's direct text response to JSON.  These
# deliberately describe only the wire shape; the existing Pydantic models still perform the
# authoritative semantic, grounding, and cross-field validation after the response is received.
_ASSEMBLER_OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "schema_version": {"type": "string", "const": "1.0"},
        "utterance_id": {"type": "string", "minLength": 1, "maxLength": 128},
        "language": {"type": "string", "enum": ["sgsl", "asl"]},
        "candidate_text": {"type": "string", "minLength": 1, "maxLength": 12_288},
        "parts": {
            "type": "array",
            "minItems": 1,
            "maxItems": 64,
            "items": {
                "anyOf": [
                    {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "kind": {"type": "string", "const": "supported_text"},
                            "text": {"type": "string", "minLength": 1, "maxLength": 160},
                            "evidence": {
                                "type": "array",
                                "minItems": 1,
                                "maxItems": 64,
                                "items": {
                                    "type": "object",
                                    "additionalProperties": False,
                                    "properties": {
                                        "slot_id": {"type": "string", "minLength": 1},
                                        "gloss_id": {"type": "string", "minLength": 1},
                                    },
                                    "required": ["slot_id", "gloss_id"],
                                },
                            },
                        },
                        "required": ["kind", "text", "evidence"],
                    },
                    {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "kind": {"type": "string", "const": "gap"},
                            "slot_id": {"type": "string", "minLength": 1},
                            "reason": {
                                "type": "string",
                                "enum": ["unresolved_input", "translation_abstained"],
                            },
                        },
                        "required": ["kind", "slot_id", "reason"],
                    },
                ]
            },
        },
    },
    "required": ["schema_version", "utterance_id", "language", "candidate_text", "parts"],
}

_CRITIC_OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "schema_version": {"type": "string", "const": "1.0"},
        "utterance_id": {"type": "string", "minLength": 1, "maxLength": 128},
        "supported": {"type": "boolean"},
        "token_assessments": {
            "type": "array",
            "minItems": 1,
            "maxItems": 512,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "token_index": {"type": "integer", "minimum": 0, "exclusiveMaximum": 512},
                    "token": {"type": "string", "minLength": 1, "maxLength": 160},
                    "supported": {"type": "boolean"},
                    "evidence": {
                        "type": "array",
                        "maxItems": 64,
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "properties": {
                                "slot_id": {"type": "string", "minLength": 1},
                                "gloss_id": {"type": "string", "minLength": 1},
                            },
                            "required": ["slot_id", "gloss_id"],
                        },
                    },
                    "reason": {"type": "string", "minLength": 1, "maxLength": 240},
                },
                "required": ["token_index", "token", "supported", "evidence", "reason"],
            },
        },
    },
    "required": ["schema_version", "utterance_id", "supported", "token_assessments"],
}


class AnthropicConfigurationError(RuntimeError):
    """Raised when direct Anthropic mode is not configured safely."""


class AnthropicProviderError(RuntimeError):
    """Raised when an Anthropic response cannot be normalized safely."""


class _AnthropicMessagesClient(Protocol):
    def create(self, **kwargs: Any) -> Any:
        """Create one Anthropic Messages API response."""


class _AnthropicClient(Protocol):
    messages: _AnthropicMessagesClient


def create_anthropic_client(
    *,
    api_base_url: str,
    workspace_id: str | None = None,
    connect_timeout_seconds: float = 5.0,
    read_timeout_seconds: float = 60.0,
    total_max_attempts: int = 3,
) -> AnthropicConverseAdapter:
    """Create a direct Anthropic client without making a network request.

    The API key is intentionally read only from the standard ``ANTHROPIC_API_KEY``
    process environment variable.  It is never a Pydantic application setting.
    """

    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key:
        raise AnthropicConfigurationError(
            "ANTHROPIC_API_KEY must be exported before Anthropic mode is enabled"
        )
    try:
        import anthropic
    except ImportError as exc:  # pragma: no cover - depends on installation
        raise AnthropicConfigurationError(
            "the anthropic package is required for direct Anthropic mode"
        ) from exc

    # Keep connect and response-read limits distinct.  The SDK accepts an httpx.Timeout
    # object and forwards it to its underlying HTTP client.
    client_kwargs: dict[str, Any] = {
        "api_key": api_key,
        "base_url": api_base_url,
        "timeout": httpx.Timeout(
            read_timeout_seconds,
            connect=connect_timeout_seconds,
        ),
        "max_retries": max(0, total_max_attempts - 1),
    }
    if workspace_id:
        client_kwargs["default_headers"] = {"anthropic-workspace-id": workspace_id}
    client = anthropic.Anthropic(**client_kwargs)
    return AnthropicConverseAdapter(cast(_AnthropicClient, client))


class AnthropicConverseAdapter:
    """Translate internal Converse-shaped calls to Anthropic Messages requests."""

    def __init__(self, client: _AnthropicClient) -> None:
        self._client = client

    def converse(self, **kwargs: Any) -> Mapping[str, Any]:
        request = _build_messages_request(kwargs)
        response = self._client.messages.create(**request)
        return _normalize_response(response)


def _build_messages_request(request: Mapping[str, Any]) -> dict[str, Any]:
    model_id = request.get("modelId")
    if not isinstance(model_id, str) or not model_id.strip():
        raise AnthropicConfigurationError("Anthropic request requires a non-empty modelId")

    inference = request.get("inferenceConfig")
    if not isinstance(inference, Mapping):
        raise AnthropicConfigurationError("Anthropic request requires inferenceConfig")
    max_tokens = inference.get("maxTokens")
    temperature = inference.get("temperature")
    if type(max_tokens) is not int or max_tokens <= 0:
        raise AnthropicConfigurationError("Anthropic maxTokens must be a positive integer")
    if type(temperature) not in (int, float):
        raise AnthropicConfigurationError("Anthropic temperature must be between 0 and 1")
    temperature_value = cast(int | float, temperature)
    if not 0 <= float(temperature_value) <= 1:
        raise AnthropicConfigurationError("Anthropic temperature must be between 0 and 1")

    raw_messages = request.get("messages")
    if not isinstance(raw_messages, Sequence) or isinstance(raw_messages, (str, bytes)):
        raise AnthropicConfigurationError("Anthropic request messages must be a sequence")

    result: dict[str, Any] = {
        "model": model_id.strip(),
        "max_tokens": max_tokens,
        "temperature": float(temperature_value),
        "messages": [_message_to_anthropic(message) for message in raw_messages],
    }
    output_config = _structured_output_config(request.get("requestMetadata"))
    if output_config is not None:
        result["output_config"] = output_config
    system = _system_to_anthropic(request.get("system"))
    if system:
        result["system"] = system
    tools = _tools_to_anthropic(request.get("toolConfig"))
    if tools:
        result["tools"] = tools
    return result


def _structured_output_config(raw_metadata: object) -> dict[str, Any] | None:
    """Return a constrained JSON output format for assembler/critic calls only."""

    if not isinstance(raw_metadata, Mapping):
        return None
    role = raw_metadata.get("simplynext_role")
    if not isinstance(role, str):
        return None
    schema = {
        "assembler": _ASSEMBLER_OUTPUT_SCHEMA,
        "critic": _CRITIC_OUTPUT_SCHEMA,
    }.get(role)
    if schema is None:
        return None
    return {"format": {"type": "json_schema", "schema": schema}}


def _system_to_anthropic(raw_system: object) -> list[dict[str, Any]]:
    if raw_system is None:
        return []
    if not isinstance(raw_system, Sequence) or isinstance(raw_system, (str, bytes)):
        raise AnthropicConfigurationError("Anthropic system prompt must be a sequence")

    blocks: list[dict[str, Any]] = []
    for raw_block in raw_system:
        if not isinstance(raw_block, Mapping):
            raise AnthropicConfigurationError("Anthropic system block is malformed")
        if "cachePoint" in raw_block:
            if not blocks:
                raise AnthropicConfigurationError("Anthropic cachePoint has no preceding text")
            # The internal cache marker is intentionally provider-neutral.  Anthropic
            # represents the same boundary as cache_control on the preceding block.
            blocks[-1]["cache_control"] = {"type": "ephemeral"}
            continue
        text = raw_block.get("text")
        if not isinstance(text, str) or not text:
            raise AnthropicConfigurationError("Anthropic system text block is malformed")
        blocks.append({"type": "text", "text": text})
    return blocks


def _message_to_anthropic(raw_message: object) -> dict[str, Any]:
    if not isinstance(raw_message, Mapping):
        raise AnthropicConfigurationError("Anthropic message is malformed")
    role = raw_message.get("role")
    if role not in {"user", "assistant"}:
        raise AnthropicConfigurationError("Anthropic message role must be user or assistant")
    raw_content = raw_message.get("content")
    if not isinstance(raw_content, Sequence) or isinstance(raw_content, (str, bytes)):
        raise AnthropicConfigurationError("Anthropic message content must be a sequence")
    content = [_content_block_to_anthropic(block) for block in raw_content]
    if not content:
        raise AnthropicConfigurationError("Anthropic message content must not be empty")
    return {"role": role, "content": content}


def _content_block_to_anthropic(raw_block: object) -> dict[str, Any]:
    if not isinstance(raw_block, Mapping):
        raise AnthropicConfigurationError("Anthropic content block is malformed")
    if "text" in raw_block:
        text = raw_block.get("text")
        if not isinstance(text, str):
            raise AnthropicConfigurationError("Anthropic text block is malformed")
        return {"type": "text", "text": text}

    if "toolUse" in raw_block:
        tool_use = raw_block.get("toolUse")
        if not isinstance(tool_use, Mapping):
            raise AnthropicConfigurationError("Anthropic toolUse block is malformed")
        tool_use_id = tool_use.get("toolUseId")
        name = tool_use.get("name")
        arguments = tool_use.get("input")
        if not isinstance(tool_use_id, str) or not tool_use_id:
            raise AnthropicConfigurationError("Anthropic toolUse id is missing")
        if not isinstance(name, str) or not name:
            raise AnthropicConfigurationError("Anthropic toolUse name is missing")
        if not isinstance(arguments, Mapping):
            raise AnthropicConfigurationError("Anthropic toolUse input must be an object")
        return {
            "type": "tool_use",
            "id": tool_use_id,
            "name": name,
            "input": dict(arguments),
        }

    if "toolResult" in raw_block:
        tool_result = raw_block.get("toolResult")
        if not isinstance(tool_result, Mapping):
            raise AnthropicConfigurationError("Anthropic toolResult block is malformed")
        tool_use_id = tool_result.get("toolUseId")
        if not isinstance(tool_use_id, str) or not tool_use_id:
            raise AnthropicConfigurationError("Anthropic toolResult id is missing")
        raw_result_content = tool_result.get("content")
        if not isinstance(raw_result_content, Sequence) or isinstance(
            raw_result_content, (str, bytes)
        ):
            raise AnthropicConfigurationError("Anthropic toolResult content is malformed")
        result_blocks: list[dict[str, Any]] = []
        for item in raw_result_content:
            if not isinstance(item, Mapping):
                raise AnthropicConfigurationError("Anthropic toolResult item is malformed")
            if "text" in item:
                text = item.get("text")
                if not isinstance(text, str):
                    raise AnthropicConfigurationError("Anthropic toolResult text is malformed")
                result_blocks.append({"type": "text", "text": text})
            elif "json" in item:
                result_blocks.append(
                    {
                        "type": "text",
                        "text": json.dumps(
                            item["json"], ensure_ascii=True, separators=(",", ":")
                        ),
                    }
                )
            else:
                raise AnthropicConfigurationError("Anthropic toolResult item is unsupported")
        if not result_blocks:
            raise AnthropicConfigurationError("Anthropic toolResult content must not be empty")
        result: dict[str, Any] = {
            "type": "tool_result",
            "tool_use_id": tool_use_id,
            "content": result_blocks,
        }
        if tool_result.get("status") == "error":
            result["is_error"] = True
        return result

    raise AnthropicConfigurationError("Anthropic content block type is unsupported")


def _tools_to_anthropic(raw_tool_config: object) -> list[dict[str, Any]]:
    if raw_tool_config is None:
        return []
    if not isinstance(raw_tool_config, Mapping):
        raise AnthropicConfigurationError("Anthropic toolConfig is malformed")
    raw_tools = raw_tool_config.get("tools")
    if not isinstance(raw_tools, Sequence) or isinstance(raw_tools, (str, bytes)):
        raise AnthropicConfigurationError("Anthropic toolConfig.tools is malformed")
    tools: list[dict[str, Any]] = []
    for raw_tool in raw_tools:
        if not isinstance(raw_tool, Mapping):
            raise AnthropicConfigurationError("Anthropic tool definition is malformed")
        spec = raw_tool.get("toolSpec")
        if not isinstance(spec, Mapping):
            raise AnthropicConfigurationError("Anthropic toolSpec is malformed")
        name = spec.get("name")
        description = spec.get("description")
        schema = spec.get("inputSchema")
        if not isinstance(name, str) or not name:
            raise AnthropicConfigurationError("Anthropic tool name is missing")
        if not isinstance(description, str) or not description:
            raise AnthropicConfigurationError("Anthropic tool description is missing")
        if not isinstance(schema, Mapping) or not isinstance(schema.get("json"), Mapping):
            raise AnthropicConfigurationError("Anthropic tool input schema is malformed")
        tools.append(
            {
                "name": name,
                "description": description,
                "input_schema": dict(schema["json"]),
            }
        )
    return tools


def _response_as_mapping(response: object) -> Mapping[str, Any]:
    if isinstance(response, Mapping):
        return cast(Mapping[str, Any], response)
    to_dict = getattr(response, "to_dict", None)
    if callable(to_dict):
        converted = to_dict()
        if isinstance(converted, Mapping):
            return cast(Mapping[str, Any], converted)
    raise AnthropicProviderError("Anthropic response could not be converted to an object")


def _normalize_response(response: object) -> Mapping[str, Any]:
    raw = _response_as_mapping(response)
    raw_content = raw.get("content")
    if not isinstance(raw_content, Sequence) or isinstance(raw_content, (str, bytes)):
        raise AnthropicProviderError("Anthropic response content is missing")

    content: list[dict[str, Any]] = []
    for raw_block in raw_content:
        if not isinstance(raw_block, Mapping):
            raise AnthropicProviderError("Anthropic response content block is malformed")
        block_type = raw_block.get("type")
        if block_type == "text":
            text = raw_block.get("text")
            if not isinstance(text, str):
                raise AnthropicProviderError("Anthropic response text block is malformed")
            content.append({"text": text})
        elif block_type == "tool_use":
            tool_use_id = raw_block.get("id")
            name = raw_block.get("name")
            input_value = raw_block.get("input")
            if not isinstance(tool_use_id, str) or not tool_use_id:
                raise AnthropicProviderError("Anthropic response tool id is missing")
            if not isinstance(name, str) or not name:
                raise AnthropicProviderError("Anthropic response tool name is missing")
            if not isinstance(input_value, Mapping):
                raise AnthropicProviderError("Anthropic response tool input is malformed")
            content.append(
                {
                    "toolUse": {
                        "toolUseId": tool_use_id,
                        "name": name,
                        "input": dict(input_value),
                    }
                }
            )
        else:
            raise AnthropicProviderError(
                f"Anthropic response content type is unsupported: {block_type!r}"
            )

    usage = raw.get("usage")
    if not isinstance(usage, Mapping):
        raise AnthropicProviderError("Anthropic response usage is missing")
    input_tokens = _required_usage_count(usage, "input_tokens")
    output_tokens = _required_usage_count(usage, "output_tokens")
    cache_write = _optional_usage_count(usage, "cache_creation_input_tokens")
    cache_read = _optional_usage_count(usage, "cache_read_input_tokens")
    return {
        "output": {"message": {"role": "assistant", "content": content}},
        "stopReason": raw.get("stop_reason") or "end_turn",
        "usage": {
            "inputTokens": input_tokens,
            "outputTokens": output_tokens,
            "totalTokens": input_tokens + output_tokens,
            "cacheWriteInputTokens": cache_write,
            "cacheReadInputTokens": cache_read,
        },
    }


def _required_usage_count(usage: Mapping[str, Any], key: str) -> int:
    value = usage.get(key)
    if type(value) is not int or value < 0:
        raise AnthropicProviderError(f"Anthropic usage field {key} is invalid")
    return value


def _optional_usage_count(usage: Mapping[str, Any], key: str) -> int:
    value = usage.get(key, 0)
    if type(value) is not int or value < 0:
        raise AnthropicProviderError(f"Anthropic usage field {key} is invalid")
    return value


__all__ = [
    "AnthropicConfigurationError",
    "AnthropicConverseAdapter",
    "AnthropicProviderError",
    "create_anthropic_client",
]
