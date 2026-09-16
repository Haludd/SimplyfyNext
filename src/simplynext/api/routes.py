"""Process health, transport readiness and protected aggregate diagnostics."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Header, Request, Response

from simplynext import __version__
from simplynext.api.operator import require_operator_token
from simplynext.runtime import RuntimeServices

health_router = APIRouter(tags=["service"])


def services_from_request(request: Request) -> RuntimeServices:
    services = request.app.state.services
    if not isinstance(services, RuntimeServices):
        raise RuntimeError("application services are not initialized")
    return services


@health_router.get("/", include_in_schema=False)
async def root(request: Request) -> dict[str, str]:
    settings = services_from_request(request).settings
    return {
        "service": "SimplyNext Backend",
        "version": __version__,
        "docs": "/docs" if settings.environment != "production" else "disabled",
    }


@health_router.get("/healthz")
async def health() -> dict[str, str]:
    return {"status": "ok", "version": __version__}


@health_router.get("/readyz")
async def readiness(request: Request, response: Response) -> dict[str, object]:
    services = services_from_request(request)
    settings = services.settings
    provider = (
        "gemini"
        if settings.gemini_enabled
        else "anthropic"
        if settings.anthropic_enabled
        else "bedrock"
        if settings.bedrock_enabled
        else "templates"
        if settings.word_templates_path is not None
        else "disabled"
    )
    policy_ready = settings.word_policy_path is not None and (
        settings.environment != "production" or settings.word_evaluation_path is not None
    )
    sentence_backend_ready = provider in {"gemini", "anthropic", "bedrock"} or (
        settings.environment != "production" and provider == "templates"
    )
    return {
        "status": "ready",
        "rooms": {
            "transport_ready": True,
            "sentence_acceptance_ready": policy_ready and sentence_backend_ready,
            "utterance_schema_version": "1.0",
            "event_schema_version": "1.0",
            "source_language": "asl",
            "max_message_bytes": 16_384,
            "word_policy_configured": settings.word_policy_path is not None,
            "word_templates_configured": settings.word_templates_path is not None,
            "word_provider": provider,
        },
    }


@health_router.get("/metrics")
async def metrics(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> dict[str, object]:
    settings = services_from_request(request).settings
    require_operator_token(
        settings.operator_metrics_token,
        authorization,
        allow_unconfigured=settings.environment != "production",
    )
    return services_from_request(request).metrics.snapshot()
