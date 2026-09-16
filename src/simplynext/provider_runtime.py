"""Compose one shared guarded provider client; no recognition or transport dependency."""

from decimal import Decimal
from typing import cast

from simplynext.agent.anthropic_access import create_anthropic_client
from simplynext.agent.bedrock_access import (
    BedrockCostGuard,
    BedrockPricing,
    CostGuardedConverseClient,
    create_bedrock_client,
    create_bedrock_control_client,
    preflight_bedrock_access,
    preflight_bedrock_runtime_access,
    preflight_model_runtime_access,
)
from simplynext.agent.gemini_access import create_gemini_client
from simplynext.config import Settings
from simplynext.observability import MetricsRegistry


def build_provider_client(
    settings: Settings, metrics: MetricsRegistry
) -> CostGuardedConverseClient | None:
    if settings.environment == "production" and (
        settings.bedrock_enabled or settings.anthropic_enabled or settings.gemini_enabled
    ):
        path = settings.provider_spend_journal_path
        if path is None or not path.is_file():
            raise ValueError(
                "provision or recover deployment spend journal before provider startup. "
                "For initial hosted verification, disable Anthropic, Bedrock, and Gemini "
                "(see deploy/production.env.example). "
                "To enable a provider, mount a persistent volume at /app/spend with "
                "usage.json provisioned."
            )
    if settings.bedrock_enabled:
        preflight_bedrock_access(
            create_bedrock_control_client(region_name=settings.aws_region),
            region_name=settings.aws_region,
            model_id=settings.bedrock_model_id,
        )
        pricing = BedrockPricing(
            model_id=settings.bedrock_model_id,
            input_usd_per_million=settings.bedrock_input_usd_per_million_tokens,
            output_usd_per_million=settings.bedrock_output_usd_per_million_tokens,
            cache_write_usd_per_million=settings.bedrock_cache_write_usd_per_million_tokens,
            cache_read_usd_per_million=settings.bedrock_cache_read_usd_per_million_tokens,
        )
        guarded_client = CostGuardedConverseClient(
            client=create_bedrock_client(
                region_name=settings.aws_region,
                connect_timeout_seconds=settings.bedrock_connect_timeout_seconds,
                read_timeout_seconds=settings.bedrock_read_timeout_seconds,
                total_max_attempts=settings.bedrock_total_max_attempts,
                max_connections=settings.max_concurrent_agent_runs,
            ),
            guard=BedrockCostGuard(
                pricing=pricing,
                spend_limit_usd=settings.bedrock_spend_limit_usd,
                known_spend_usd=settings.bedrock_known_spend_usd,
                journal_path=settings.provider_spend_journal_path,
                request_limit_usd=settings.provider_request_spend_limit_usd,
                room_limit_usd=settings.provider_room_spend_limit_usd,
                hourly_limit_usd=settings.provider_hourly_spend_limit_usd,
                total_max_attempts=settings.bedrock_total_max_attempts,
            ),
            metrics=metrics,
            prompt_cache_enabled=settings.bedrock_prompt_cache_enabled,
        )
        preflight_bedrock_runtime_access(
            guarded_client,
            region_name=settings.aws_region,
            model_id=settings.bedrock_model_id,
        )
        return guarded_client
    elif settings.anthropic_enabled:
        anthropic_rates = (
            settings.anthropic_input_usd_per_million_tokens,
            settings.anthropic_output_usd_per_million_tokens,
            settings.anthropic_cache_write_usd_per_million_tokens,
            settings.anthropic_cache_read_usd_per_million_tokens,
        )
        if any(rate is None for rate in anthropic_rates):
            raise ValueError("Anthropic pricing must be configured before startup")
        pricing = BedrockPricing(
            model_id=settings.anthropic_model_id,
            input_usd_per_million=cast(Decimal, settings.anthropic_input_usd_per_million_tokens),
            output_usd_per_million=cast(Decimal, settings.anthropic_output_usd_per_million_tokens),
            cache_write_usd_per_million=cast(
                Decimal, settings.anthropic_cache_write_usd_per_million_tokens
            ),
            cache_read_usd_per_million=cast(
                Decimal, settings.anthropic_cache_read_usd_per_million_tokens
            ),
        )
        guarded_client = CostGuardedConverseClient(
            client=create_anthropic_client(
                api_base_url=settings.anthropic_api_base_url,
                workspace_id=settings.anthropic_workspace_id,
                connect_timeout_seconds=settings.anthropic_connect_timeout_seconds,
                read_timeout_seconds=settings.anthropic_read_timeout_seconds,
                total_max_attempts=settings.anthropic_total_max_attempts,
                max_connections=settings.max_concurrent_agent_runs,
            ),
            guard=BedrockCostGuard(
                pricing=pricing,
                spend_limit_usd=settings.anthropic_spend_limit_usd,
                known_spend_usd=settings.anthropic_known_spend_usd,
                journal_path=settings.provider_spend_journal_path,
                request_limit_usd=settings.provider_request_spend_limit_usd,
                room_limit_usd=settings.provider_room_spend_limit_usd,
                hourly_limit_usd=settings.provider_hourly_spend_limit_usd,
                total_max_attempts=settings.anthropic_total_max_attempts,
            ),
            metrics=metrics,
            prompt_cache_enabled=settings.anthropic_prompt_cache_enabled,
            provider="anthropic",
        )
        preflight_model_runtime_access(
            guarded_client,
            provider="anthropic",
            location=settings.anthropic_api_base_url,
            model_id=settings.anthropic_model_id,
        )
        return guarded_client
    elif settings.gemini_enabled:
        gemini_rates = (
            settings.gemini_input_usd_per_million_tokens,
            settings.gemini_output_usd_per_million_tokens,
            settings.gemini_cache_write_usd_per_million_tokens,
            settings.gemini_cache_read_usd_per_million_tokens,
        )
        if any(rate is None for rate in gemini_rates):
            raise ValueError("Gemini pricing must be configured before startup")
        pricing = BedrockPricing(
            model_id=settings.gemini_model_id,
            input_usd_per_million=cast(
                Decimal, settings.gemini_input_usd_per_million_tokens
            ),
            output_usd_per_million=cast(
                Decimal, settings.gemini_output_usd_per_million_tokens
            ),
            cache_write_usd_per_million=cast(
                Decimal, settings.gemini_cache_write_usd_per_million_tokens
            ),
            cache_read_usd_per_million=cast(
                Decimal, settings.gemini_cache_read_usd_per_million_tokens
            ),
        )
        guarded_client = CostGuardedConverseClient(
            client=create_gemini_client(
                api_base_url=settings.gemini_api_base_url,
                connect_timeout_seconds=settings.gemini_connect_timeout_seconds,
                read_timeout_seconds=settings.gemini_read_timeout_seconds,
                total_max_attempts=settings.gemini_total_max_attempts,
                max_connections=settings.max_concurrent_agent_runs,
            ),
            guard=BedrockCostGuard(
                pricing=pricing,
                spend_limit_usd=settings.gemini_spend_limit_usd,
                known_spend_usd=settings.gemini_known_spend_usd,
                journal_path=settings.provider_spend_journal_path,
                request_limit_usd=settings.provider_request_spend_limit_usd,
                room_limit_usd=settings.provider_room_spend_limit_usd,
                hourly_limit_usd=settings.provider_hourly_spend_limit_usd,
                total_max_attempts=settings.gemini_total_max_attempts,
            ),
            metrics=metrics,
            prompt_cache_enabled=settings.gemini_prompt_cache_enabled,
            provider="gemini",
        )
        preflight_model_runtime_access(
            guarded_client,
            provider="gemini",
            location=settings.gemini_api_base_url,
            model_id=settings.gemini_model_id,
        )
        return guarded_client
    return None
