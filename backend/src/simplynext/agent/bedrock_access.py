"""Bedrock access preflight, prompt caching, and process-local spend guard.

The guard sits around the small Converse protocol shared by the assembler and critic.
It reserves a conservative maximum cost before dispatch and records all four billed
token classes after the response.  It is intentionally process-local: the configured
known spend lets the lease owner include costs incurred elsewhere in the AWS account.
"""

from __future__ import annotations

import json
import logging
from collections import OrderedDict
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import ROUND_CEILING, Decimal
from threading import Lock
from typing import Any, Final, Protocol, cast

from simplynext.observability.metrics import MetricsRegistry

DEFAULT_BEDROCK_INPUT_USD_PER_MILLION: Final = Decimal("1.10")
DEFAULT_BEDROCK_OUTPUT_USD_PER_MILLION: Final = Decimal("5.50")
DEFAULT_BEDROCK_CACHE_WRITE_USD_PER_MILLION: Final = Decimal("1.375")
DEFAULT_BEDROCK_CACHE_READ_USD_PER_MILLION: Final = Decimal("0.11")
DEFAULT_BEDROCK_SPEND_LIMIT_USD: Final = Decimal("5.00")
BEDROCK_INPUT_RESERVATION_OVERHEAD_TOKENS: Final = 4_096
MAX_TRACKED_BEDROCK_UTTERANCES: Final = 1_024
TOKENS_PER_MILLION: Final = Decimal(1_000_000)
NANO_USD_PER_USD: Final = Decimal(1_000_000_000)

logger = logging.getLogger(__name__)


class BedrockBudgetExceeded(RuntimeError):
    """Raised before a call whose reservation would exceed the local ceiling."""


class BedrockUsageUnavailable(RuntimeError):
    """Raised after a response without complete, trustworthy token accounting."""


class BedrockPreflightError(RuntimeError):
    """Raised when credentials, region, or the configured model profile fail preflight."""


class _ConverseClient(Protocol):
    def converse(self, **kwargs: Any) -> Mapping[str, Any]: ...


class BedrockControlClient(Protocol):
    """Control-plane operation needed for a non-billable model preflight."""

    def get_inference_profile(self, **kwargs: Any) -> Mapping[str, Any]: ...

    def get_foundation_model(self, **kwargs: Any) -> Mapping[str, Any]: ...


def create_bedrock_client(
    *,
    region_name: str,
    connect_timeout_seconds: float = 5.0,
    read_timeout_seconds: float = 30.0,
    total_max_attempts: int = 3,
) -> _ConverseClient:
    """Create a bounded Bedrock Runtime client without making a network request."""

    try:
        import boto3  # type: ignore[import-untyped]
        from botocore.config import Config  # type: ignore[import-untyped]
    except ImportError as exc:  # pragma: no cover - depends on installation
        raise RuntimeError("boto3 is required for Bedrock lattice assembly") from exc
    return cast(
        _ConverseClient,
        boto3.client(
            "bedrock-runtime",
            region_name=region_name,
            config=Config(
                connect_timeout=connect_timeout_seconds,
                read_timeout=read_timeout_seconds,
                retries={"mode": "standard", "total_max_attempts": total_max_attempts},
            ),
        ),
    )


@dataclass(frozen=True, slots=True)
class BedrockPricing:
    """Explicit per-million-token prices for exactly one configured model."""

    model_id: str
    input_usd_per_million: Decimal = DEFAULT_BEDROCK_INPUT_USD_PER_MILLION
    output_usd_per_million: Decimal = DEFAULT_BEDROCK_OUTPUT_USD_PER_MILLION
    cache_write_usd_per_million: Decimal = DEFAULT_BEDROCK_CACHE_WRITE_USD_PER_MILLION
    cache_read_usd_per_million: Decimal = DEFAULT_BEDROCK_CACHE_READ_USD_PER_MILLION

    def __post_init__(self) -> None:
        if not self.model_id or self.model_id != self.model_id.strip():
            raise ValueError("model_id must be non-empty without surrounding whitespace")
        for name, value in (
            ("input_usd_per_million", self.input_usd_per_million),
            ("output_usd_per_million", self.output_usd_per_million),
            ("cache_write_usd_per_million", self.cache_write_usd_per_million),
            ("cache_read_usd_per_million", self.cache_read_usd_per_million),
        ):
            if not isinstance(value, Decimal) or not value.is_finite() or value < 0:
                raise ValueError(f"{name} must be a finite non-negative Decimal")

    def maximum_cost_usd(self, *, input_tokens: int, output_tokens: int) -> Decimal:
        """Price a reservation using the most expensive possible input-token class."""

        _require_token_count(input_tokens, "input_tokens")
        _require_token_count(output_tokens, "output_tokens")
        input_rate = max(self.input_usd_per_million, self.cache_write_usd_per_million)
        return (
            Decimal(input_tokens) * input_rate
            + Decimal(output_tokens) * self.output_usd_per_million
        ) / TOKENS_PER_MILLION

    def usage_cost_usd(self, usage: BedrockTokenUsage) -> Decimal:
        """Estimate billed dollars from every token class returned by Bedrock."""

        return (
            Decimal(usage.input_tokens) * self.input_usd_per_million
            + Decimal(usage.output_tokens) * self.output_usd_per_million
            + Decimal(usage.cache_write_input_tokens) * self.cache_write_usd_per_million
            + Decimal(usage.cache_read_input_tokens) * self.cache_read_usd_per_million
        ) / TOKENS_PER_MILLION


@dataclass(frozen=True, slots=True)
class BedrockTokenUsage:
    """Strict token counts from one successful Converse response."""

    input_tokens: int
    output_tokens: int
    cache_write_input_tokens: int = 0
    cache_read_input_tokens: int = 0

    def __post_init__(self) -> None:
        for name, value in (
            ("input_tokens", self.input_tokens),
            ("output_tokens", self.output_tokens),
            ("cache_write_input_tokens", self.cache_write_input_tokens),
            ("cache_read_input_tokens", self.cache_read_input_tokens),
        ):
            _require_token_count(value, name)

    @property
    def total_input_tokens(self) -> int:
        return self.input_tokens + self.cache_write_input_tokens + self.cache_read_input_tokens

    @classmethod
    def from_response(cls, response: Mapping[str, Any]) -> BedrockTokenUsage:
        usage = response.get("usage")
        if not isinstance(usage, Mapping):
            raise BedrockUsageUnavailable("Bedrock response did not contain token usage")
        input_tokens = _usage_count(usage, "inputTokens", required=True)
        output_tokens = _usage_count(usage, "outputTokens", required=True)
        return cls(
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_write_input_tokens=_usage_count(usage, "cacheWriteInputTokens", required=False),
            cache_read_input_tokens=_usage_count(usage, "cacheReadInputTokens", required=False),
        )


@dataclass(frozen=True, slots=True)
class BedrockSpendSnapshot:
    """Atomic view of known, reserved, and remaining local budget."""

    spend_limit_usd: Decimal
    estimated_spend_usd: Decimal
    reserved_usd: Decimal
    remaining_usd: Decimal
    completed_calls: int
    rejected_calls: int


@dataclass(frozen=True, slots=True)
class BedrockPreflightResult:
    """Validated identity of an active inference profile in the configured region."""

    region_name: str
    model_id: str
    status: str


@dataclass(frozen=True, slots=True)
class BedrockUtteranceCost:
    """Bounded running token and cost total for one utterance identifier."""

    utterance_id: str
    model_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_write_input_tokens: int = 0
    cache_read_input_tokens: int = 0
    usage_unavailable_calls: int = 0
    estimated_cost_usd: Decimal = Decimal(0)


@dataclass(frozen=True, slots=True)
class _Reservation:
    reservation_id: int
    maximum_cost_usd: Decimal


class BedrockCostGuard:
    """Thread-safe process-local budget shared by every Bedrock model call."""

    def __init__(
        self,
        *,
        pricing: BedrockPricing,
        spend_limit_usd: Decimal = DEFAULT_BEDROCK_SPEND_LIMIT_USD,
        known_spend_usd: Decimal = Decimal(0),
    ) -> None:
        _require_money(spend_limit_usd, "spend_limit_usd", positive=True)
        _require_money(known_spend_usd, "known_spend_usd", positive=False)
        if known_spend_usd > spend_limit_usd:
            raise ValueError("known_spend_usd cannot exceed spend_limit_usd")
        self._pricing = pricing
        self._spend_limit_usd = spend_limit_usd
        self._estimated_spend_usd = known_spend_usd
        self._reservations: dict[int, Decimal] = {}
        self._next_reservation_id = 1
        self._completed_calls = 0
        self._rejected_calls = 0
        self._lock = Lock()

    @property
    def pricing(self) -> BedrockPricing:
        return self._pricing

    def reserve(self, *, model_id: str, input_tokens: int, max_output_tokens: int) -> _Reservation:
        """Atomically reserve worst-case cost or reject before network dispatch."""

        if model_id != self._pricing.model_id:
            raise ValueError("Bedrock model_id has no matching configured pricing")
        maximum_cost = self._pricing.maximum_cost_usd(
            input_tokens=input_tokens,
            output_tokens=max_output_tokens,
        )
        with self._lock:
            reserved = sum(self._reservations.values(), Decimal(0))
            projected = self._estimated_spend_usd + reserved + maximum_cost
            if projected > self._spend_limit_usd:
                self._rejected_calls += 1
                raise BedrockBudgetExceeded(
                    "Bedrock spend ceiling would be exceeded by this model call"
                )
            reservation = _Reservation(self._next_reservation_id, maximum_cost)
            self._next_reservation_id += 1
            self._reservations[reservation.reservation_id] = maximum_cost
            return reservation

    def settle(
        self,
        reservation: _Reservation,
        *,
        usage: BedrockTokenUsage | None,
    ) -> tuple[Decimal, BedrockSpendSnapshot]:
        """Commit actual estimated cost, or the full reservation when usage is unknown."""

        actual_cost = (
            reservation.maximum_cost_usd if usage is None else self._pricing.usage_cost_usd(usage)
        )
        with self._lock:
            reserved_cost = self._reservations.pop(reservation.reservation_id, None)
            if reserved_cost is None or reserved_cost != reservation.maximum_cost_usd:
                raise RuntimeError("Bedrock budget reservation is invalid or already settled")
            self._estimated_spend_usd += actual_cost
            self._completed_calls += 1
            snapshot = self._snapshot_locked()
        return actual_cost, snapshot

    def snapshot(self) -> BedrockSpendSnapshot:
        with self._lock:
            return self._snapshot_locked()

    def _snapshot_locked(self) -> BedrockSpendSnapshot:
        reserved = sum(self._reservations.values(), Decimal(0))
        remaining = max(
            Decimal(0),
            self._spend_limit_usd - self._estimated_spend_usd - reserved,
        )
        return BedrockSpendSnapshot(
            spend_limit_usd=self._spend_limit_usd,
            estimated_spend_usd=self._estimated_spend_usd,
            reserved_usd=reserved,
            remaining_usd=remaining,
            completed_calls=self._completed_calls,
            rejected_calls=self._rejected_calls,
        )


class CostGuardedConverseClient:
    """Converse decorator enforcing pricing, caching, logging, and a hard ceiling.

    The implementation is provider-neutral; the historical class name is retained
    for compatibility with the Bedrock path.
    """

    def __init__(
        self,
        *,
        client: _ConverseClient,
        guard: BedrockCostGuard,
        metrics: MetricsRegistry | None = None,
        prompt_cache_enabled: bool = True,
        provider: str = "bedrock",
    ) -> None:
        self._client = client
        self._guard = guard
        self._metrics = metrics
        self._prompt_cache_enabled = prompt_cache_enabled
        if not provider or provider != provider.strip():
            raise ValueError("provider must be a non-empty identifier")
        self._provider = provider
        self._utterance_costs: OrderedDict[str, BedrockUtteranceCost] = OrderedDict()
        self._utterance_costs_lock = Lock()

    @property
    def spend(self) -> BedrockSpendSnapshot:
        return self._guard.snapshot()

    def utterance_cost(self, utterance_id: str) -> BedrockUtteranceCost | None:
        """Return a safe immutable aggregate without exposing any prompt or response text."""

        if not isinstance(utterance_id, str) or not utterance_id:
            raise ValueError("utterance_id must be a non-empty string")
        with self._utterance_costs_lock:
            return self._utterance_costs.get(utterance_id)

    def converse(self, **kwargs: Any) -> Mapping[str, Any]:
        request = _with_prompt_cache(kwargs) if self._prompt_cache_enabled else dict(kwargs)
        model_id = _required_model_id(request)
        max_output_tokens = _maximum_output_tokens(request)
        estimated_input_tokens = _conservative_input_token_bound(request)
        role, utterance_id = _request_context(request)
        self._increment("model_calls_total")

        try:
            reservation = self._guard.reserve(
                model_id=model_id,
                input_tokens=estimated_input_tokens,
                max_output_tokens=max_output_tokens,
            )
        except BedrockBudgetExceeded:
            self._increment("model_calls_budget_rejected")
            logger.warning(
                "bedrock_cost_guard_rejected model_id=%s role=%s utterance_id=%s",
                model_id,
                role,
                utterance_id,
            )
            raise

        try:
            response = self._client.converse(**request)
        except Exception:
            cost, snapshot = self._guard.settle(reservation, usage=None)
            self._increment("model_calls_failed")
            utterance_cost = self._record_cost(cost, utterance_id=utterance_id, usage=None)
            _log_cost(
                model_id=model_id,
                role=role,
                utterance_id=utterance_id,
                usage=None,
                cost=cost,
                snapshot=snapshot,
                utterance_cost=utterance_cost,
                accounting="reserved_after_failure",
                provider=self._provider,
            )
            raise

        try:
            usage = BedrockTokenUsage.from_response(response)
        except BedrockUsageUnavailable:
            cost, snapshot = self._guard.settle(reservation, usage=None)
            self._increment("model_calls_usage_unavailable")
            utterance_cost = self._record_cost(cost, utterance_id=utterance_id, usage=None)
            _log_cost(
                model_id=model_id,
                role=role,
                utterance_id=utterance_id,
                usage=None,
                cost=cost,
                snapshot=snapshot,
                utterance_cost=utterance_cost,
                accounting="reserved_usage_unavailable",
                provider=self._provider,
            )
            raise

        cost, snapshot = self._guard.settle(reservation, usage=usage)
        self._increment("input_tokens", usage.input_tokens)
        self._increment("output_tokens", usage.output_tokens)
        self._increment("cache_write_input_tokens", usage.cache_write_input_tokens)
        self._increment("cache_read_input_tokens", usage.cache_read_input_tokens)
        utterance_cost = self._record_cost(cost, utterance_id=utterance_id, usage=usage)
        reservation_exceeded = cost > reservation.maximum_cost_usd
        _log_cost(
            model_id=model_id,
            role=role,
            utterance_id=utterance_id,
            usage=usage,
            cost=cost,
            snapshot=snapshot,
            utterance_cost=utterance_cost,
            accounting=("reservation_exceeded" if reservation_exceeded else "response_usage"),
            provider=self._provider,
        )
        if reservation_exceeded:
            self._increment("model_calls_usage_unavailable")
            raise BedrockUsageUnavailable(
                "Bedrock usage exceeded its pre-authorized cost reservation"
            )
        self._increment("model_calls_succeeded")
        return response

    def _increment(self, name: str, amount: int = 1) -> None:
        if self._metrics is not None and amount:
            self._metrics.increment(f"{self._provider}_{name}", amount)

    def _record_cost(
        self,
        cost: Decimal,
        *,
        utterance_id: str,
        usage: BedrockTokenUsage | None,
    ) -> BedrockUtteranceCost:
        nano_usd = int((cost * NANO_USD_PER_USD).to_integral_value(rounding=ROUND_CEILING))
        self._increment("estimated_cost_nano_usd", nano_usd)
        with self._utterance_costs_lock:
            previous = self._utterance_costs.get(
                utterance_id,
                BedrockUtteranceCost(utterance_id=utterance_id),
            )
            updated = BedrockUtteranceCost(
                utterance_id=utterance_id,
                model_calls=previous.model_calls + 1,
                input_tokens=previous.input_tokens + (0 if usage is None else usage.input_tokens),
                output_tokens=previous.output_tokens
                + (0 if usage is None else usage.output_tokens),
                cache_write_input_tokens=previous.cache_write_input_tokens
                + (0 if usage is None else usage.cache_write_input_tokens),
                cache_read_input_tokens=previous.cache_read_input_tokens
                + (0 if usage is None else usage.cache_read_input_tokens),
                usage_unavailable_calls=previous.usage_unavailable_calls + int(usage is None),
                estimated_cost_usd=previous.estimated_cost_usd + cost,
            )
            self._utterance_costs[utterance_id] = updated
            self._utterance_costs.move_to_end(utterance_id)
            while len(self._utterance_costs) > MAX_TRACKED_BEDROCK_UTTERANCES:
                self._utterance_costs.popitem(last=False)
            return updated


def preflight_bedrock_access(
    client: BedrockControlClient,
    *,
    region_name: str,
    model_id: str,
) -> BedrockPreflightResult:
    """Check an active inference profile without performing billable inference."""

    if not region_name or region_name != region_name.strip():
        raise ValueError("region_name must be non-empty without surrounding whitespace")
    if not model_id or model_id != model_id.strip():
        raise ValueError("model_id must be non-empty without surrounding whitespace")
    actual_region = getattr(getattr(client, "meta", None), "region_name", None)
    if actual_region is not None and actual_region != region_name:
        raise BedrockPreflightError("Bedrock control client region does not match configuration")
    is_inference_profile = model_id.startswith(("global.", "us.", "eu.", "au.", "jp."))
    try:
        response = (
            client.get_inference_profile(inferenceProfileIdentifier=model_id)
            if is_inference_profile
            else client.get_foundation_model(modelIdentifier=model_id)
        )
    except Exception as exc:
        raise BedrockPreflightError("Bedrock model preflight failed") from exc
    if not isinstance(response, Mapping):
        raise BedrockPreflightError("Bedrock preflight returned an invalid response")
    if is_inference_profile:
        if response.get("inferenceProfileId") != model_id or response.get("status") != "ACTIVE":
            raise BedrockPreflightError("configured Bedrock inference profile is not active")
        models = response.get("models")
        if not isinstance(models, list) or not models:
            raise BedrockPreflightError("configured Bedrock inference profile has no routed models")
    else:
        details = response.get("modelDetails")
        lifecycle = details.get("modelLifecycle") if isinstance(details, Mapping) else None
        if (
            not isinstance(details, Mapping)
            or details.get("modelId") != model_id
            or not isinstance(lifecycle, Mapping)
            or lifecycle.get("status") != "ACTIVE"
        ):
            raise BedrockPreflightError("configured Bedrock foundation model is not active")
    result = BedrockPreflightResult(
        region_name=region_name,
        model_id=model_id,
        status="ACTIVE",
    )
    logger.info(
        "bedrock_preflight_passed region=%s model_id=%s status=%s",
        result.region_name,
        result.model_id,
        result.status,
    )
    return result


def create_bedrock_control_client(*, region_name: str) -> BedrockControlClient:
    """Create the boto3 Bedrock control-plane client without a network request."""

    try:
        import boto3
    except ImportError as exc:  # pragma: no cover - depends on installation
        raise RuntimeError("boto3 is required for Bedrock access preflight") from exc
    return cast(BedrockControlClient, boto3.client("bedrock", region_name=region_name))


def preflight_bedrock_runtime_access(
    client: CostGuardedConverseClient,
    *,
    region_name: str,
    model_id: str,
) -> None:
    """Prove Bedrock runtime invocation with one minimal, fully accounted call."""

    try:
        preflight_model_runtime_access(
            client,
            provider="bedrock",
            location=region_name,
            model_id=model_id,
        )
    except BedrockBudgetExceeded:
        raise
    except BedrockPreflightError as exc:
        raise BedrockPreflightError(
            "Bedrock runtime preflight failed in "
            f"{region_name}; run 'aws sso login' and verify model access in that region"
        ) from exc


def preflight_model_runtime_access(
    client: CostGuardedConverseClient,
    *,
    provider: str,
    location: str,
    model_id: str,
) -> None:
    """Prove a provider's runtime access with one minimal, fully accounted call."""

    if not provider or provider != provider.strip():
        raise ValueError("provider must be non-empty without surrounding whitespace")
    if not location or location != location.strip():
        raise ValueError("location must be non-empty without surrounding whitespace")
    if not model_id or model_id != model_id.strip():
        raise ValueError("model_id must be non-empty without surrounding whitespace")
    try:
        response = client.converse(
            modelId=model_id,
            system=[
                {
                    "text": (
                        "This is an access preflight. Reply to the user with the single word OK."
                    )
                }
            ],
            messages=[{"role": "user", "content": [{"text": "Reply OK."}]}],
            inferenceConfig={"maxTokens": 2, "temperature": 0.0},
            requestMetadata={
                "simplynext_role": "preflight",
                "simplynext_utterance_id": f"{provider}-access-preflight",
            },
        )
    except BedrockBudgetExceeded:
        raise
    except Exception as exc:
        raise BedrockPreflightError(
            f"{provider} runtime preflight failed at {location}; verify provider access"
        ) from exc
    output = response.get("output")
    message = output.get("message") if isinstance(output, Mapping) else None
    content = message.get("content") if isinstance(message, Mapping) else None
    if not isinstance(content, list) or not any(
        isinstance(block, Mapping) and isinstance(block.get("text"), str) for block in content
    ):
        raise BedrockPreflightError(f"{provider} runtime preflight returned no text content")
    logger.info(
        "%s_runtime_preflight_passed location=%s model_id=%s",
        provider,
        location,
        model_id,
    )


def _with_prompt_cache(kwargs: Mapping[str, Any]) -> dict[str, Any]:
    request = dict(kwargs)
    raw_system = request.get("system")
    if not isinstance(raw_system, (list, tuple)) or not raw_system:
        raise ValueError("cached Bedrock Converse calls require a non-empty system prompt")
    system = list(raw_system)
    if not any(isinstance(block, Mapping) and "cachePoint" in block for block in system):
        system.append({"cachePoint": {"type": "default"}})
    request["system"] = system
    return request


def _required_model_id(request: Mapping[str, Any]) -> str:
    model_id = request.get("modelId")
    if not isinstance(model_id, str) or not model_id or model_id != model_id.strip():
        raise ValueError("Bedrock Converse request requires a valid modelId")
    return model_id


def _maximum_output_tokens(request: Mapping[str, Any]) -> int:
    inference = request.get("inferenceConfig")
    if not isinstance(inference, Mapping):
        raise ValueError("Bedrock Converse request requires inferenceConfig")
    value = inference.get("maxTokens")
    _require_token_count(value, "maxTokens", positive=True)
    return cast(int, value)


def _conservative_input_token_bound(request: Mapping[str, Any]) -> int:
    countable = {
        name: request[name]
        for name in ("messages", "system", "toolConfig", "additionalModelRequestFields")
        if name in request
    }
    try:
        encoded = json.dumps(
            countable,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValueError("Bedrock Converse prompt must be finite JSON") from exc
    return len(encoded) + BEDROCK_INPUT_RESERVATION_OVERHEAD_TOKENS


def _request_context(request: Mapping[str, Any]) -> tuple[str, str]:
    metadata = request.get("requestMetadata")
    if not isinstance(metadata, Mapping):
        return "unspecified", "unavailable"
    role = metadata.get("simplynext_role")
    utterance_id = metadata.get("simplynext_utterance_id")
    return (
        role if isinstance(role, str) and role else "unspecified",
        utterance_id if isinstance(utterance_id, str) and utterance_id else "unavailable",
    )


def _usage_count(usage: Mapping[str, Any], key: str, *, required: bool) -> int:
    value = usage.get(key)
    if value is None and not required:
        return 0
    try:
        _require_token_count(value, key)
    except (TypeError, ValueError) as exc:
        raise BedrockUsageUnavailable(f"Bedrock response has invalid {key}") from exc
    return cast(int, value)


def _require_token_count(value: object, name: str, *, positive: bool = False) -> None:
    if type(value) is not int or value < (1 if positive else 0):
        qualifier = "positive" if positive else "non-negative"
        raise ValueError(f"{name} must be a {qualifier} integer")


def _require_money(value: Decimal, name: str, *, positive: bool) -> None:
    if not isinstance(value, Decimal) or not value.is_finite():
        raise ValueError(f"{name} must be a finite Decimal")
    if value < (Decimal(0) if not positive else Decimal("0.000000001")):
        qualifier = "positive" if positive else "non-negative"
        raise ValueError(f"{name} must be {qualifier}")


def _log_cost(
    *,
    model_id: str,
    role: str,
    utterance_id: str,
    usage: BedrockTokenUsage | None,
    cost: Decimal,
    snapshot: BedrockSpendSnapshot,
    utterance_cost: BedrockUtteranceCost,
    accounting: str,
    provider: str = "bedrock",
) -> None:
    logger.info(
        "%s_cost_usage model_id=%s role=%s utterance_id=%s input_tokens=%s "
        "output_tokens=%s cache_write_input_tokens=%s cache_read_input_tokens=%s "
        "estimated_cost_usd=%s cumulative_estimated_spend_usd=%s remaining_usd=%s "
        "utterance_model_calls=%s utterance_estimated_cost_usd=%s accounting=%s",
        provider,
        model_id,
        role,
        utterance_id,
        None if usage is None else usage.input_tokens,
        None if usage is None else usage.output_tokens,
        None if usage is None else usage.cache_write_input_tokens,
        None if usage is None else usage.cache_read_input_tokens,
        format(cost, "f"),
        format(snapshot.estimated_spend_usd, "f"),
        format(snapshot.remaining_usd, "f"),
        utterance_cost.model_calls,
        format(utterance_cost.estimated_cost_usd, "f"),
        accounting,
    )


__all__ = [
    "BEDROCK_INPUT_RESERVATION_OVERHEAD_TOKENS",
    "DEFAULT_BEDROCK_CACHE_READ_USD_PER_MILLION",
    "DEFAULT_BEDROCK_CACHE_WRITE_USD_PER_MILLION",
    "DEFAULT_BEDROCK_INPUT_USD_PER_MILLION",
    "DEFAULT_BEDROCK_OUTPUT_USD_PER_MILLION",
    "DEFAULT_BEDROCK_SPEND_LIMIT_USD",
    "MAX_TRACKED_BEDROCK_UTTERANCES",
    "BedrockBudgetExceeded",
    "BedrockControlClient",
    "BedrockCostGuard",
    "BedrockPreflightError",
    "BedrockPreflightResult",
    "BedrockPricing",
    "BedrockSpendSnapshot",
    "BedrockTokenUsage",
    "BedrockUsageUnavailable",
    "BedrockUtteranceCost",
    "CostGuardedConverseClient",
    "create_bedrock_client",
    "create_bedrock_control_client",
    "preflight_model_runtime_access",
    "preflight_bedrock_access",
    "preflight_bedrock_runtime_access",
]
