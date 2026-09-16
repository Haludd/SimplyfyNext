"""Structured logging that never serializes client perception payloads."""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from typing import Any


class JsonFormatter(logging.Formatter):
    """Only application-authored messages; no SDK wire logs or exception strings."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": (
                record.getMessage() if record.name.startswith("simplynext.")
                else "external_log_suppressed"
            ),
        }
        if record.exc_info:
            payload["exception_type"] = (
                record.exc_info[0].__name__ if record.exc_info[0] else "unknown"
            )
        trace = getattr(record, "room_transport", None)
        if trace is not None:
            payload["room_transport"] = trace
        return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


def configure_logging(level: str = "INFO") -> None:
    """Configure process logging once at application startup."""

    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level.upper())
    for name in ("anthropic", "httpx", "httpcore", "boto3", "botocore", "urllib3"):
        logging.getLogger(name).setLevel(logging.WARNING)
