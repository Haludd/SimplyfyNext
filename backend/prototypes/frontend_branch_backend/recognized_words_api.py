#!/usr/bin/env python3
"""Small local backend for browser-recognized ASL words.

It is intentionally separate from the legacy landmark-stream experiment. This
endpoint accepts a compact word-level result only; it rejects camera frames,
landmarks, and feature vectors at the HTTP boundary.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
from typing import Any


MAX_BODY_BYTES = 64 * 1024
MAX_WORD_LENGTH = 80
FORBIDDEN_DATA_FIELDS = frozenset(
    {
        "frames",
        "landmarks",
        "landmark_worlds",
        "feature_vector",
        "hand_motion",
        "image",
        "video",
        "audio",
    }
)


class ValidationError(ValueError):
    """A caller sent a payload outside the word-only transport contract."""


class RecognizedWordStore:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._lock = threading.Lock()

    def append(self, event: dict[str, Any]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        encoded = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
        with self._lock, self._path.open("a", encoding="utf-8") as handle:
            handle.write(encoded)
            handle.write("\n")


def _required_text(value: Any, field: str, *, maximum: int = MAX_WORD_LENGTH) -> str:
    if not isinstance(value, str) or not (text := value.strip()):
        raise ValidationError(f"{field} must be a non-empty string")
    if len(text) > maximum:
        raise ValidationError(f"{field} cannot exceed {maximum} characters")
    return text


def _confidence(value: Any, field: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValidationError(f"{field} must be a number")
    number = float(value)
    if not math.isfinite(number) or not 0 <= number <= 1:
        raise ValidationError(f"{field} must be a finite number in [0, 1]")
    return number


def _contains_forbidden_data(value: Any) -> bool:
    if isinstance(value, dict):
        return any(
            key in FORBIDDEN_DATA_FIELDS or _contains_forbidden_data(nested)
            for key, nested in value.items()
        )
    if isinstance(value, list):
        return any(_contains_forbidden_data(item) for item in value)
    return False


def validate_event(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError("request body must be a JSON object")
    if _contains_forbidden_data(value):
        raise ValidationError("word endpoint does not accept camera or landmark data")
    if value.get("schema_version") != "signbridge.recognized-word.v1":
        raise ValidationError("schema_version must be signbridge.recognized-word.v1")

    source = value.get("source")
    if not isinstance(source, dict):
        raise ValidationError("source must be an object")
    classifier_id = _required_text(source.get("classifier_id"), "source.classifier_id")
    model_version = _required_text(source.get("model_version"), "source.model_version")
    execution = _required_text(source.get("execution"), "source.execution")

    alternatives = value.get("alternatives", [])
    if not isinstance(alternatives, list) or len(alternatives) > 3:
        raise ValidationError("alternatives must contain at most three candidates")
    parsed_alternatives: list[dict[str, Any]] = []
    for index, alternative in enumerate(alternatives):
        if not isinstance(alternative, dict):
            raise ValidationError(f"alternatives[{index}] must be an object")
        parsed_alternatives.append(
            {
                "word": _required_text(alternative.get("word"), f"alternatives[{index}].word"),
                "confidence": _confidence(
                    alternative.get("confidence"),
                    f"alternatives[{index}].confidence",
                ),
                "rank": int(alternative.get("rank", index + 1)),
            }
        )

    return {
        "schema_version": "signbridge.recognized-word.v1",
        "event_id": _required_text(value.get("event_id"), "event_id"),
        "session_id": _required_text(value.get("session_id"), "session_id"),
        "language": _required_text(value.get("language"), "language", maximum=16).upper(),
        "word": _required_text(value.get("word"), "word"),
        "confidence": _confidence(value.get("confidence"), "confidence"),
        "source": {
            "classifier_id": classifier_id,
            "model_version": model_version,
            "execution": execution,
        },
        "started_at": _required_text(value.get("started_at"), "started_at", maximum=64),
        "ended_at": _required_text(value.get("ended_at"), "ended_at", maximum=64),
        "alternatives": parsed_alternatives,
    }


class RecognizedWordsHandler(BaseHTTPRequestHandler):
    store: RecognizedWordStore
    server_version = "SignBridgeRecognizedWords/1.0"

    def do_OPTIONS(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        self._respond(HTTPStatus.NO_CONTENT, {})

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path != "/health":
            self._respond(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        self._respond(HTTPStatus.OK, {"status": "ok", "transport": "word_only"})

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path != "/v1/recognized-signs":
            self._respond(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        try:
            event = validate_event(self._read_json())
        except ValidationError as error:
            self._respond(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(error)})
            return
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._respond(HTTPStatus.BAD_REQUEST, {"error": "invalid_json"})
            return

        event["received_at"] = datetime.now(timezone.utc).isoformat()
        self.store.append(event)
        self._respond(
            HTTPStatus.ACCEPTED,
            {
                "status": "accepted",
                "event_id": event["event_id"],
                "caption": event["word"],
                "tts_text": event["word"],
            },
        )

    def _read_json(self) -> Any:
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length or "")
        except ValueError as error:
            raise ValidationError("Content-Length is required") from error
        if length < 1 or length > MAX_BODY_BYTES:
            raise ValidationError(f"request body must be between 1 and {MAX_BODY_BYTES} bytes")
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _respond(self, status: HTTPStatus, body: dict[str, Any]) -> None:
        encoded = (
            b""
            if status == HTTPStatus.NO_CONTENT
            else json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        # This local development endpoint is called by Flutter Web. Deployments
        # should replace this with an allow-list for the production origin.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        if status != HTTPStatus.NO_CONTENT:
            self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        # Avoid logging a recognized word or any submitted content.
        print(f"{self.address_string()} {self.command} {self.path} {args[1] if len(args) > 1 else ''}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8000, type=int)
    parser.add_argument(
        "--store",
        type=Path,
        default=Path(__file__).parent / "data" / "recognized_words.jsonl",
        help="Local JSONL destination for accepted word events.",
    )
    args = parser.parse_args()

    RecognizedWordsHandler.store = RecognizedWordStore(args.store)
    server = ThreadingHTTPServer((args.host, args.port), RecognizedWordsHandler)
    print(f"Recognized-word API listening at http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping recognized-word API")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
