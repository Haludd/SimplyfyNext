from __future__ import annotations

import pytest

from simplynext.agent.anthropic_access import (
    AnthropicConfigurationError,
    AnthropicConverseAdapter,
    AnthropicProviderError,
    create_anthropic_client,
)


class FakeMessages:
    def __init__(self, response: object) -> None:
        self.response = response
        self.calls: list[dict[str, object]] = []

    def create(self, **kwargs: object) -> object:
        self.calls.append(kwargs)
        return self.response


class FakeAnthropicClient:
    def __init__(self, response: object) -> None:
        self.messages = FakeMessages(response)


def _text_response() -> dict[str, object]:
    return {
        "content": [{"type": "text", "text": '{"ok":true}'}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 12, "output_tokens": 4},
    }


def test_text_request_is_translated_and_response_preserves_internal_shape() -> None:
    client = FakeAnthropicClient(_text_response())
    adapter = AnthropicConverseAdapter(client)

    response = adapter.converse(
        modelId="claude-haiku-4-5-20251001",
        system=[{"text": "You are a strict JSON assistant."}],
        messages=[{"role": "user", "content": [{"text": "Return JSON."}]}],
        inferenceConfig={"maxTokens": 40, "temperature": 0.0},
        requestMetadata={"simplynext_role": "assembler"},
    )

    request = client.messages.calls[0]
    assert request["model"] == "claude-haiku-4-5-20251001"
    assert request["max_tokens"] == 40
    assert request["system"] == [{"type": "text", "text": "You are a strict JSON assistant."}]
    assert request["messages"] == [
        {"role": "user", "content": [{"type": "text", "text": "Return JSON."}]}
    ]
    assert request["output_config"]["format"]["type"] == "json_schema"
    assert request["output_config"]["format"]["schema"]["required"] == [
        "schema_version",
        "utterance_id",
        "language",
        "candidate_text",
        "parts",
    ]
    assert response["output"] == {
        "message": {"role": "assistant", "content": [{"text": '{"ok":true}'}]}
    }
    assert response["stopReason"] == "end_turn"
    assert response["usage"] == {
        "inputTokens": 12,
        "outputTokens": 4,
        "totalTokens": 16,
        "cacheWriteInputTokens": 0,
        "cacheReadInputTokens": 0,
    }


def test_tool_blocks_round_trip_without_changing_agent_protocol() -> None:
    client = FakeAnthropicClient(
        {
            "content": [
                {
                    "type": "tool_use",
                    "id": "tool-1",
                    "name": "lookup",
                    "input": {"gloss_id": "HELLO"},
                }
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 8, "output_tokens": 3},
        }
    )
    adapter = AnthropicConverseAdapter(client)

    response = adapter.converse(
        modelId="claude-haiku-4-5-20251001",
        system=[{"text": "Use tools."}],
        messages=[
            {"role": "user", "content": [{"text": "Look up HELLO."}]},
            {
                "role": "assistant",
                "content": [
                    {
                        "toolUse": {
                            "toolUseId": "tool-1",
                            "name": "lookup",
                            "input": {"gloss_id": "HELLO"},
                        }
                    }
                ],
            },
            {
                "role": "user",
                "content": [
                    {
                        "toolResult": {
                            "toolUseId": "tool-1",
                            "content": [{"json": {"caption": "Hello."}}],
                            "status": "success",
                        }
                    }
                ],
            },
        ],
        inferenceConfig={"maxTokens": 40, "temperature": 0.0},
        toolConfig={
            "tools": [
                {
                    "toolSpec": {
                        "name": "lookup",
                        "description": "Look up a grounded gloss entry from trusted state.",
                        "inputSchema": {"json": {"type": "object"}},
                        "strict": True,
                    }
                }
            ]
        },
    )

    request = client.messages.calls[0]
    assert request["tools"] == [
        {
            "name": "lookup",
            "description": "Look up a grounded gloss entry from trusted state.",
            "input_schema": {"type": "object"},
        }
    ]
    messages = request["messages"]
    assert isinstance(messages, list)
    assert messages[1] == {
        "role": "assistant",
        "content": [
            {
                "type": "tool_use",
                "id": "tool-1",
                "name": "lookup",
                "input": {"gloss_id": "HELLO"},
            }
        ],
    }
    assert messages[2] == {
        "role": "user",
        "content": [
            {
                "type": "tool_result",
                "tool_use_id": "tool-1",
                "content": [{"type": "text", "text": '{"caption":"Hello."}'}],
            }
        ],
    }
    assert response["stopReason"] == "tool_use"
    assert response["output"] == {
        "message": {
            "role": "assistant",
            "content": [
                {
                    "toolUse": {
                        "toolUseId": "tool-1",
                        "name": "lookup",
                        "input": {"gloss_id": "HELLO"},
                    }
                }
            ],
        }
    }


def test_cache_marker_maps_to_anthropic_ephemeral_cache_control() -> None:
    client = FakeAnthropicClient(_text_response())
    adapter = AnthropicConverseAdapter(client)

    adapter.converse(
        modelId="claude-haiku-4-5-20251001",
        system=[{"text": "Cache this."}, {"cachePoint": {"type": "default"}}],
        messages=[{"role": "user", "content": [{"text": "Hi"}]}],
        inferenceConfig={"maxTokens": 2, "temperature": 0.0},
    )

    assert client.messages.calls[0]["system"] == [
        {
            "type": "text",
            "text": "Cache this.",
            "cache_control": {"type": "ephemeral"},
        }
    ]


def test_invalid_provider_response_fails_closed() -> None:
    client = FakeAnthropicClient(
        {"content": [{"type": "text", "text": "ok"}], "usage": {"input_tokens": 1}}
    )
    with pytest.raises(AnthropicProviderError, match="output_tokens"):
        AnthropicConverseAdapter(client).converse(
            modelId="claude-haiku-4-5-20251001",
            messages=[{"role": "user", "content": [{"text": "Hi"}]}],
            inferenceConfig={"maxTokens": 2, "temperature": 0.0},
        )


def test_client_requires_standard_anthropic_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(AnthropicConfigurationError, match="ANTHROPIC_API_KEY"):
        create_anthropic_client(api_base_url="https://api.anthropic.com")
