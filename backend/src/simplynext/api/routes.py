"""HTTP endpoints outside the GlossLattice streaming loop."""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Request, Response, status

from simplynext import __version__
from simplynext.api.operator import require_operator_token
from simplynext.contracts import (
    SessionCreateRequest,
    SessionCreateResponse,
)
from simplynext.runtime import RuntimeServices
from simplynext.sessions import (
    InvalidSessionToken,
    SessionExpired,
    SessionNotFound,
    SessionStoreError,
    TooManySessions,
)

health_router = APIRouter(tags=["service"])
api_router = APIRouter(tags=["translation"])


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
    assembler_ready = services.lattice_translation.assembler_ready
    ready = assembler_ready
    if not ready:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {
        "status": "ready" if ready else "lattice_assembler_unconfigured",
        "lattice_transport": {
            "ready": True,
            "schema_version": "1.0",
            "max_message_bytes": services.settings.gloss_lattice_max_message_bytes,
        },
        "agent": {
            "ready": True,
            "max_revisions": services.settings.agent_max_revisions,
            "allowed_tools": services.agent_graph.allowed_tools,
        },
        "assembler": {
            "ready": assembler_ready,
            "mode": (
                "bedrock"
                if services.settings.bedrock_enabled
                else "anthropic"
                if services.settings.anthropic_enabled
                else "deterministic"
            ),
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


@api_router.post(
    "/sessions",
    response_model=SessionCreateResponse,
    response_model_exclude_none=True,
    status_code=status.HTTP_201_CREATED,
)
async def create_session(
    payload: SessionCreateRequest,
    request: Request,
    response: Response,
) -> SessionCreateResponse:
    services = services_from_request(request)
    model_language = services.lattice_translation.language
    if payload.language is not model_language:
        raise HTTPException(
            status_code=422,
            detail=f"this deployment is configured for {model_language.value}",
        )
    if payload.producer != services.lattice_translation.approved_producer:
        raise HTTPException(
            status_code=422,
            detail="producer profile is not approved for this deployment",
        )
    try:
        session = await services.sessions.create(payload)
    except TooManySessions as exc:
        services.metrics.increment("session_creation_rate_limited")
        raise _http_session_error(exc) from exc
    response.headers["Cache-Control"] = "no-store"
    services.metrics.increment("sessions_created")
    return session


@api_router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(
    session_id: UUID,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    services = services_from_request(request)
    token = _bearer_token(authorization)
    try:
        await services.sessions.delete(session_id, token)
    except SessionStoreError as exc:
        raise _http_session_error(exc) from exc
    services.metrics.increment("sessions_deleted")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _bearer_token(value: str | None) -> str:
    if value is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Bearer token required",
        )
    scheme, separator, token = value.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Authorization header",
        )
    return token.strip()


def _http_session_error(exc: SessionStoreError) -> HTTPException:
    if isinstance(exc, InvalidSessionToken):
        code = status.HTTP_401_UNAUTHORIZED
    elif isinstance(exc, SessionNotFound):
        code = status.HTTP_404_NOT_FOUND
    elif isinstance(exc, SessionExpired):
        code = status.HTTP_410_GONE
    elif isinstance(exc, TooManySessions):
        code = status.HTTP_429_TOO_MANY_REQUESTS
    else:
        code = status.HTTP_409_CONFLICT
    return HTTPException(status_code=code, detail=exc.message)
