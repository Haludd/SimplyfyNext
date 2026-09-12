"""FastAPI application factory and command-line entry point."""

from __future__ import annotations

import logging
from asyncio import Semaphore
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

import uvicorn
from fastapi import FastAPI, Header, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.docs import get_redoc_html, get_swagger_ui_html
from fastapi.responses import HTMLResponse, JSONResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware

from simplynext import __version__
from simplynext.api.lattice_websocket import lattice_socket
from simplynext.api.middleware import RequestBodyLimitMiddleware
from simplynext.api.operator import require_operator_token
from simplynext.api.routes import api_router, health_router
from simplynext.config import Settings, get_settings
from simplynext.lattice_runtime import (
    LatticeTranslationEngine,
    build_lattice_translation_engine,
)
from simplynext.observability import MetricsRegistry, configure_logging
from simplynext.runtime import RuntimeServices
from simplynext.sessions import EphemeralSessionStore

logger = logging.getLogger(__name__)


def create_app(
    settings: Settings | None = None,
    *,
    lattice_translation: LatticeTranslationEngine | None = None,
) -> FastAPI:
    runtime_settings = settings or get_settings()
    configure_logging(runtime_settings.log_level)
    metrics = (
        lattice_translation.metrics
        if lattice_translation is not None
        else MetricsRegistry()
    )
    lattice_engine = lattice_translation or build_lattice_translation_engine(
        runtime_settings,
        metrics,
    )
    sessions = EphemeralSessionStore(
        ttl_seconds=runtime_settings.session_ttl_seconds,
        max_sessions=runtime_settings.max_active_sessions,
        websocket_path_template=(
            f"{runtime_settings.api_prefix}/sessions/{{session_id}}/lattices"
        ),
        max_lattice_message_bytes=runtime_settings.gloss_lattice_max_message_bytes,
        max_session_creations_per_minute_global=(
            runtime_settings.max_session_creations_per_minute_global
        ),
        max_lattices_per_session=runtime_settings.max_lattices_per_session,
        max_lattices_per_minute=runtime_settings.max_lattices_per_minute,
        max_lattices_per_minute_global=runtime_settings.max_lattices_per_minute_global,
    )
    services = RuntimeServices(
        settings=runtime_settings,
        sessions=sessions,
        lattice_translation=lattice_engine,
        agent_graph=lattice_engine.agent_graph,
        metrics=metrics,
        agent_slots=Semaphore(runtime_settings.max_concurrent_agent_runs),
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.services = services
        yield
        await sessions.purge_expired()

    is_production = runtime_settings.environment == "production"
    public_docs = not is_production
    application = FastAPI(
        title="SimplyNext Backend",
        version=__version__,
        summary="Uncertainty-aware GlossLattice translation service",
        lifespan=lifespan,
        docs_url="/docs" if public_docs else None,
        redoc_url="/redoc" if public_docs else None,
        openapi_url="/openapi.json" if public_docs else None,
    )
    application.state.services = services
    application.add_middleware(
        RequestBodyLimitMiddleware,
        max_bytes=runtime_settings.http_max_body_bytes,
    )
    # Railway terminates TLS upstream, but the app deliberately does not install
    # ProxyHeadersMiddleware or use X-Forwarded-* values for authorization/rate decisions.
    # Any trusted-proxy policy must be enforced at the platform boundary.
    application.add_middleware(
        TrustedHostMiddleware,
        allowed_hosts=list(runtime_settings.allowed_hosts),
    )
    if runtime_settings.allowed_origins:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=list(runtime_settings.allowed_origins),
            allow_credentials=False,
            allow_methods=["GET", "POST", "DELETE"],
            allow_headers=["Authorization", "Content-Type"],
        )
    application.include_router(health_router)
    application.include_router(api_router, prefix=runtime_settings.api_prefix)

    if is_production and runtime_settings.operator_docs_enabled:
        @application.get("/openapi.json", include_in_schema=False)
        async def operator_openapi(
            authorization: str | None = Header(default=None),
        ) -> JSONResponse:
            require_operator_token(
                runtime_settings.operator_docs_token,
                authorization,
                allow_unconfigured=False,
            )
            return JSONResponse(application.openapi())

        @application.get("/docs", include_in_schema=False)
        async def operator_docs(authorization: str | None = Header(default=None)) -> HTMLResponse:
            require_operator_token(
                runtime_settings.operator_docs_token,
                authorization,
                allow_unconfigured=False,
            )
            return get_swagger_ui_html(
                openapi_url="/openapi.json",
                title="SimplyNext Backend - Swagger UI",
            )

        @application.get("/redoc", include_in_schema=False)
        async def operator_redoc(authorization: str | None = Header(default=None)) -> HTMLResponse:
            require_operator_token(
                runtime_settings.operator_docs_token,
                authorization,
                allow_unconfigured=False,
            )
            return get_redoc_html(
                openapi_url="/openapi.json",
                title="SimplyNext Backend - ReDoc",
            )

    @application.websocket(f"{runtime_settings.api_prefix}/sessions/{{session_id}}/lattices")
    async def stream_lattices(websocket: WebSocket, session_id: UUID) -> None:
        await lattice_socket(websocket, session_id)

    logger.info(
        "startup_configuration environment=%s bedrock_enabled=%s anthropic_enabled=%s "
        "port=%s max_active_sessions=%s max_session_creations_per_minute_global=%s "
        "max_lattices_per_session=%s max_lattices_per_minute=%s "
        "max_lattices_per_minute_global=%s max_concurrent_agent_runs=%s "
        "docs_public=%s operator_docs_enabled=%s metrics_protected=%s allowed_hosts=%s",
        runtime_settings.environment,
        runtime_settings.bedrock_enabled,
        runtime_settings.anthropic_enabled,
        runtime_settings.port,
        runtime_settings.max_active_sessions,
        runtime_settings.max_session_creations_per_minute_global,
        runtime_settings.max_lattices_per_session,
        runtime_settings.max_lattices_per_minute,
        runtime_settings.max_lattices_per_minute_global,
        runtime_settings.max_concurrent_agent_runs,
        public_docs,
        is_production and runtime_settings.operator_docs_enabled,
        runtime_settings.operator_metrics_token is not None,
        runtime_settings.allowed_hosts,
    )

    return application


app = create_app()


def run() -> None:
    settings = get_settings()
    uvicorn.run(
        "simplynext.main:app",
        host=settings.host,
        port=settings.port,
        log_config=None,
        ws_max_size=settings.gloss_lattice_max_message_bytes,
        workers=1,
    )
