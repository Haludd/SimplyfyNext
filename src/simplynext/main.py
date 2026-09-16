"""FastAPI application factory and command-line entry point."""

from __future__ import annotations

import asyncio
import logging
from asyncio import Semaphore
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Header, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.docs import get_redoc_html, get_swagger_ui_html
from fastapi.responses import HTMLResponse, JSONResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware

from simplynext import __version__
from simplynext.api.middleware import (
    PrivacyHeadersMiddleware,
    RequestBodyLimitMiddleware,
    SocketAdmissionMiddleware,
)
from simplynext.api.operator import require_operator_token
from simplynext.api.room_routes import room_router
from simplynext.api.room_websocket import room_socket
from simplynext.api.routes import health_router
from simplynext.config import Settings, get_settings
from simplynext.observability import MetricsRegistry, configure_logging
from simplynext.provider_runtime import build_provider_client
from simplynext.rooms.service import RoomService, Translator
from simplynext.rooms.store import RoomFailure, RoomLimits, RoomStore
from simplynext.runtime import RuntimeServices
from simplynext.translation_runtime import build_word_translation_engine, load_word_policy

logger = logging.getLogger(__name__)


def create_app(
    settings: Settings | None = None,
    *,
    word_translation: Translator | None = None,
) -> FastAPI:
    runtime_settings = settings or get_settings()
    configure_logging(runtime_settings.log_level)
    if word_translation is None:
        load_word_policy(runtime_settings)  # Qualification before any provider/preflight I/O.
    metrics = MetricsRegistry()
    provider_client = (
        build_provider_client(runtime_settings, metrics) if word_translation is None else None
    )
    slots = Semaphore(runtime_settings.max_concurrent_agent_runs)
    rooms = RoomService(
        RoomStore(
            RoomLimits(
                max_rooms=runtime_settings.room_max_active,
                max_messages=runtime_settings.room_max_messages,
                invite_seconds=runtime_settings.room_invite_seconds,
                idle_seconds=runtime_settings.room_idle_seconds,
                absolute_seconds=runtime_settings.room_absolute_seconds,
                invitations_per_minute=runtime_settings.room_invitations_per_minute,
                invitations_global_per_minute=runtime_settings.room_invitations_global_per_minute,
                messages_per_minute=runtime_settings.room_messages_per_minute,
            ),
            assembler_token_budget=runtime_settings.context_assembler_token_budget,
            critic_token_budget=runtime_settings.context_critic_token_budget,
        ),
        word_translation
        or build_word_translation_engine(runtime_settings, provider_client, metrics),
        slots=slots,
        metrics=metrics,
        timeout_seconds=runtime_settings.room_translation_timeout_seconds,
        queue_timeout_seconds=runtime_settings.agent_queue_timeout_seconds,
    )
    services = RuntimeServices(
        settings=runtime_settings,
        metrics=metrics,
        agent_slots=slots,
        rooms=rooms,
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.services = services
        expiry_task = asyncio.create_task(rooms.expire_periodically())
        try:
            yield
        finally:
            expiry_task.cancel()
            await asyncio.gather(expiry_task, return_exceptions=True)
            await rooms.store.close()

    is_production = runtime_settings.environment == "production"
    public_docs = not is_production
    application = FastAPI(
        title="SimplyNext Backend",
        version=__version__,
        summary="Temporary conversation rooms and grounded ASL word-to-sentence translation",
        lifespan=lifespan,
        docs_url="/docs" if public_docs else None,
        redoc_url="/redoc" if public_docs else None,
        openapi_url="/openapi.json" if public_docs else None,
    )
    application.state.services = services
    application.add_middleware(
        RequestBodyLimitMiddleware,
        max_bytes=runtime_settings.http_max_body_bytes,
        room_prefix=f"{runtime_settings.api_prefix}/rooms",
        timeout_seconds=runtime_settings.http_body_timeout_seconds,
    )
    application.add_middleware(
        SocketAdmissionMiddleware,
        maximum=runtime_settings.websocket_max_connections,
        per_minute=runtime_settings.websocket_connections_per_minute,
        global_per_minute=runtime_settings.websocket_connections_global_per_minute,
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
    application.add_middleware(PrivacyHeadersMiddleware)
    application.include_router(health_router)
    application.include_router(room_router, prefix=runtime_settings.api_prefix)

    @application.exception_handler(RoomFailure)
    async def room_failure_handler(request: object, exc: RoomFailure) -> JSONResponse:
        metrics.increment(f"room_rejected_{exc.code}")
        return JSONResponse({"error": exc.code}, status_code=exc.status)

    @application.exception_handler(Exception)
    async def internal_failure_handler(request: object, exc: Exception) -> JSONResponse:
        metrics.increment("internal_failures")
        return JSONResponse(
            {"error": "internal_error"},
            status_code=500,
            headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"},
        )

    @application.websocket(f"{runtime_settings.api_prefix}/rooms/{{code}}/events")
    async def stream_room(websocket: WebSocket, code: str) -> None:
        await room_socket(websocket, code)

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

    logger.info(
        "startup_configuration environment=%s bedrock_enabled=%s anthropic_enabled=%s "
        "gemini_enabled=%s word_policy_configured=%s word_templates_configured=%s "
        "port=%s room_max_active=%s max_concurrent_agent_runs=%s workers=1",
        runtime_settings.environment,
        runtime_settings.bedrock_enabled,
        runtime_settings.anthropic_enabled,
        runtime_settings.gemini_enabled,
        runtime_settings.word_policy_path is not None,
        runtime_settings.word_templates_path is not None,
        runtime_settings.port,
        runtime_settings.room_max_active,
        runtime_settings.max_concurrent_agent_runs,
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
        access_log=False,
        proxy_headers=False,
        ws_max_size=16_384,
        ws_max_queue=4,
        ws_per_message_deflate=False,
        timeout_keep_alive=5,
        timeout_graceful_shutdown=15,
        workers=1,
    )
