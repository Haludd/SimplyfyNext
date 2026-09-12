"""Runtime configuration for the SimplyNext backend.

Only non-secret application settings live here. AWS credentials are deliberately
left to the standard AWS credential provider chain and are never model fields.
"""

from __future__ import annotations

from decimal import Decimal
from functools import lru_cache
from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import AliasChoices, Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

from simplynext.contracts import GlossLatticeProducer, Identifier, SignLanguage

DEFAULT_BEDROCK_MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
DEFAULT_ANTHROPIC_MODEL_ID = "claude-haiku-4-5-20251001"
DEFAULT_ANTHROPIC_API_BASE_URL = "https://api.anthropic.com"


class Settings(BaseSettings):
    """Non-secret settings loaded from ``SIMPLYNEXT_`` environment variables."""

    model_config = SettingsConfigDict(
        env_prefix="SIMPLYNEXT_",
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_name: str = "SimplyNext Backend"
    environment: Literal["development", "test", "production"] = "development"
    host: str = "127.0.0.1"
    # Railway injects PORT directly.  It wins over the local SIMPLYNEXT_PORT alias
    # when both are present; local development retains the existing prefixed name.
    port: int = Field(
        default=8000,
        ge=1,
        le=65_535,
        validation_alias=AliasChoices("PORT", "SIMPLYNEXT_PORT"),
    )
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    api_prefix: str = "/v1"
    allowed_origins: Annotated[tuple[str, ...], NoDecode] = (
        "http://localhost:3000",
        "http://localhost:8080",
    )
    allowed_hosts: Annotated[tuple[str, ...], NoDecode] = (
        "localhost",
        "127.0.0.1",
        "testserver",
    )
    # Production docs are disabled unless an operator explicitly enables them with a
    # separate bearer credential. Metrics follow the same dedicated-credential policy.
    operator_docs_enabled: bool = False
    operator_docs_token: SecretStr | None = None
    operator_metrics_token: SecretStr | None = None

    session_ttl_seconds: int = Field(default=900, ge=30, le=86_400)
    max_active_sessions: int = Field(default=128, ge=1, le=10_000)
    max_session_creations_per_minute_global: int = Field(default=60, ge=1, le=100_000)
    http_max_body_bytes: int = Field(default=262_144, ge=4_096, le=4_194_304)
    gloss_lattice_max_message_bytes: Literal[32_768] = 32_768
    max_lattices_per_session: int = Field(default=100, ge=1, le=10_000)
    max_lattices_per_minute: int = Field(default=30, ge=1, le=10_000)
    max_lattices_per_minute_global: int = Field(default=120, ge=1, le=100_000)
    max_concurrent_agent_runs: int = Field(default=4, ge=1, le=128)
    agent_queue_timeout_seconds: float = Field(default=2.0, gt=0.0, le=60.0)
    lattice_websocket_idle_timeout_seconds: float = Field(default=120.0, gt=0.0, le=3_600.0)

    lattice_classifier_id: Identifier = "temporal_classifier"
    lattice_classifier_version: Identifier = "1.3.0"
    lattice_calibration_version: Identifier = "temperature_v2"
    lattice_vocabulary_version: Identifier = "sgsl_demo_v1"

    caption_templates_path: Path | None = None
    recognition_language: SignLanguage = SignLanguage.ASL
    min_recognition_confidence: float = Field(default=0.80, ge=0.0, le=1.0)
    min_recognition_margin: float = Field(default=0.15, ge=0.0, le=1.0)
    bedrock_enabled: bool = False
    aws_region: str = "ap-southeast-1"
    bedrock_model_id: str = DEFAULT_BEDROCK_MODEL_ID
    bedrock_lease_owner: str | None = None
    bedrock_spend_limit_usd: Decimal = Field(
        default=Decimal("5.00"),
        gt=0,
        lt=Decimal("20.00"),
    )
    bedrock_known_spend_usd: Decimal = Field(default=Decimal(0), ge=0)
    bedrock_input_usd_per_million_tokens: Decimal = Field(default=Decimal("1.10"), ge=0)
    bedrock_output_usd_per_million_tokens: Decimal = Field(default=Decimal("5.50"), ge=0)
    bedrock_cache_write_usd_per_million_tokens: Decimal = Field(default=Decimal("1.375"), ge=0)
    bedrock_cache_read_usd_per_million_tokens: Decimal = Field(default=Decimal("0.11"), ge=0)
    bedrock_prompt_cache_enabled: bool = True
    bedrock_connect_timeout_seconds: float = Field(default=5.0, gt=0.0, le=60.0)
    bedrock_read_timeout_seconds: float = Field(default=30.0, gt=0.0, le=300.0)
    bedrock_total_max_attempts: int = Field(default=3, ge=1, le=10)

    # Direct Anthropic API mode is opt-in and deliberately keeps the API key out of
    # Settings.  The adapter reads ANTHROPIC_API_KEY from the process environment.
    anthropic_enabled: bool = False
    anthropic_model_id: str = DEFAULT_ANTHROPIC_MODEL_ID
    anthropic_api_base_url: str = DEFAULT_ANTHROPIC_API_BASE_URL
    anthropic_workspace_id: str | None = None
    anthropic_lease_owner: str | None = None
    anthropic_spend_limit_usd: Decimal = Field(default=Decimal("5.00"), gt=0, lt=Decimal("20.00"))
    anthropic_known_spend_usd: Decimal = Field(default=Decimal(0), ge=0)
    anthropic_input_usd_per_million_tokens: Decimal | None = Field(default=None, ge=0)
    anthropic_output_usd_per_million_tokens: Decimal | None = Field(default=None, ge=0)
    anthropic_cache_write_usd_per_million_tokens: Decimal | None = Field(default=None, ge=0)
    anthropic_cache_read_usd_per_million_tokens: Decimal | None = Field(default=None, ge=0)
    anthropic_prompt_cache_enabled: bool = False
    anthropic_connect_timeout_seconds: float = Field(default=5.0, gt=0.0, le=60.0)
    anthropic_read_timeout_seconds: float = Field(default=60.0, gt=0.0, le=300.0)
    anthropic_total_max_attempts: int = Field(default=3, ge=1, le=10)
    agent_max_revisions: int = Field(default=1, ge=0, le=1)

    @field_validator("api_prefix")
    @classmethod
    def validate_api_prefix(cls, value: str) -> str:
        value = value.strip()
        if not value.startswith("/"):
            raise ValueError("api_prefix must begin with '/'")
        if value != "/" and value.endswith("/"):
            raise ValueError("api_prefix must not end with '/'")
        return value

    @field_validator("allowed_origins", mode="before")
    @classmethod
    def parse_allowed_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return tuple(item.strip() for item in value.split(",") if item.strip())
        return value

    @field_validator("allowed_hosts", mode="before")
    @classmethod
    def parse_allowed_hosts(cls, value: object) -> object:
        if isinstance(value, str):
            return tuple(item.strip() for item in value.split(",") if item.strip())
        return value

    @field_validator("operator_docs_token", "operator_metrics_token", mode="before")
    @classmethod
    def empty_operator_token_is_unconfigured(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @field_validator("caption_templates_path", mode="before")
    @classmethod
    def empty_optional_value_is_unconfigured(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @field_validator("bedrock_lease_owner", mode="before")
    @classmethod
    def normalize_bedrock_lease_owner(cls, value: object) -> object:
        if isinstance(value, str):
            normalized = value.strip()
            return normalized or None
        return value

    @field_validator("anthropic_workspace_id", "anthropic_lease_owner", mode="before")
    @classmethod
    def normalize_anthropic_optional_strings(cls, value: object) -> object:
        if isinstance(value, str):
            normalized = value.strip()
            return normalized or None
        return value

    @field_validator(
        "anthropic_input_usd_per_million_tokens",
        "anthropic_output_usd_per_million_tokens",
        "anthropic_cache_write_usd_per_million_tokens",
        "anthropic_cache_read_usd_per_million_tokens",
        mode="before",
    )
    @classmethod
    def empty_anthropic_price_is_unconfigured(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @field_validator("bedrock_model_id", mode="before")
    @classmethod
    def use_default_model_for_blank_value(cls, value: object) -> object:
        if value is None or (isinstance(value, str) and not value.strip()):
            return DEFAULT_BEDROCK_MODEL_ID
        return value

    @field_validator(
        "host",
        "aws_region",
        "bedrock_model_id",
        "anthropic_model_id",
        "anthropic_api_base_url",
        "app_name",
        "lattice_classifier_id",
        "lattice_classifier_version",
        "lattice_calibration_version",
        "lattice_vocabulary_version",
    )
    @classmethod
    def reject_empty_strings(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("value must not be empty")
        return value

    @model_validator(mode="after")
    def require_bedrock_ownership_and_budget_headroom(self) -> Self:
        if self.environment == "production" and not self.allowed_hosts:
            raise ValueError("allowed_hosts must contain the public production hostname")
        if self.environment == "production" and "*" in self.allowed_hosts:
            raise ValueError("allowed_hosts must not contain '*' in production")
        if (
            self.environment == "production"
            and self.operator_docs_enabled
            and self.operator_docs_token is None
        ):
            raise ValueError(
                "operator_docs_token is required when operator_docs_enabled is true"
            )
        if self.bedrock_known_spend_usd > self.bedrock_spend_limit_usd:
            raise ValueError("bedrock_known_spend_usd cannot exceed bedrock_spend_limit_usd")
        if self.bedrock_enabled and self.bedrock_lease_owner is None:
            raise ValueError("bedrock_lease_owner is required when Bedrock is enabled")
        if self.bedrock_enabled and self.anthropic_enabled:
            raise ValueError("only one hosted model provider may be enabled")
        if self.anthropic_known_spend_usd > self.anthropic_spend_limit_usd:
            raise ValueError("anthropic_known_spend_usd cannot exceed anthropic_spend_limit_usd")
        if self.anthropic_enabled:
            if self.anthropic_lease_owner is None:
                raise ValueError("anthropic_lease_owner is required when Anthropic is enabled")
            anthropic_pricing = (
                self.anthropic_input_usd_per_million_tokens,
                self.anthropic_output_usd_per_million_tokens,
                self.anthropic_cache_write_usd_per_million_tokens,
                self.anthropic_cache_read_usd_per_million_tokens,
            )
            if any(rate is None for rate in anthropic_pricing):
                raise ValueError(
                    "all four anthropic pricing fields are required when Anthropic is enabled"
                )
        pricing_fields = {
            "bedrock_input_usd_per_million_tokens",
            "bedrock_output_usd_per_million_tokens",
            "bedrock_cache_write_usd_per_million_tokens",
            "bedrock_cache_read_usd_per_million_tokens",
        }
        if self.bedrock_model_id != DEFAULT_BEDROCK_MODEL_ID and not pricing_fields.issubset(
            self.model_fields_set
        ):
            raise ValueError(
                "a non-default bedrock_model_id requires all four explicit pricing fields"
            )
        return self

    @property
    def cors_origins(self) -> tuple[str, ...]:
        """Compatibility name used by some FastAPI examples."""

        return self.allowed_origins

    @property
    def recognition_confidence_threshold(self) -> float:
        return self.min_recognition_confidence

    @property
    def recognition_margin_threshold(self) -> float:
        return self.min_recognition_margin

    @property
    def approved_lattice_producer(self) -> GlossLatticeProducer:
        """Return the sole producer profile accepted by this deployment."""

        return GlossLatticeProducer(
            classifier_id=self.lattice_classifier_id,
            classifier_version=self.lattice_classifier_version,
            confidence_kind="calibrated_probability",
            calibration_version=self.lattice_calibration_version,
            vocabulary_version=self.lattice_vocabulary_version,
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the process-wide settings instance."""

    return Settings()
