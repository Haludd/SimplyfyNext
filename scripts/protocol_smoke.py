"""Explicit, payload-redacted HTTP/WebSocket smoke test for the lattice protocol."""

from __future__ import annotations

import argparse
import asyncio
import json
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, TypeVar, cast
from urllib.parse import urlsplit, urlunsplit

import httpx
from pydantic import BaseModel, TypeAdapter, ValidationError
from websockets.asyncio.client import ClientConnection, connect

from simplynext.config import Settings
from simplynext.contracts import (
    ActivityState,
    ClientDescriptor,
    ClientPlatform,
    ControlAction,
    DetectorDelegate,
    DetectorDescriptor,
    GlossLattice,
    GlossLatticeProducer,
    LatticeAckDisposition,
    LatticeAckEvent,
    LatticeActivityEvent,
    LatticeEvidenceTrace,
    LatticeOutboundEvent,
    LatticePongEvent,
    LatticeRepairRequiredEvent,
    LatticeResultEvent,
    SessionCreateRequest,
    SessionCreateResponse,
    StreamControlMessage,
    StreamKind,
)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIDENT_FIXTURE = PROJECT_ROOT / "tests/fixtures/live_bedrock_confident_v1.json"
DEFAULT_REPAIR_FIXTURE = PROJECT_ROOT / "tests/fixtures/live_bedrock_repair_v1.json"
_OUTBOUND_ADAPTER: TypeAdapter[LatticeOutboundEvent] = TypeAdapter(LatticeOutboundEvent)
_EventT = TypeVar("_EventT", bound=BaseModel)


class SmokeFailure(RuntimeError):
    """A redaction-safe smoke assertion failure."""


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Verify session creation, authenticated WebSocket processing, replay, repair, "
            "metrics, ping, and clean shutdown without printing tokens or lattice text."
        )
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--language", choices=("sgsl", "asl"))
    parser.add_argument("--classifier-id")
    parser.add_argument("--classifier-version")
    parser.add_argument("--calibration-version")
    parser.add_argument("--vocabulary-version")
    parser.add_argument("--confident-fixture", type=Path, default=DEFAULT_CONFIDENT_FIXTURE)
    parser.add_argument("--repair-fixture", type=Path, default=DEFAULT_REPAIR_FIXTURE)
    parser.add_argument(
        "--expect-agent-source",
        choices=("bedrock_graph", "anthropic_graph", "deterministic_template"),
        default="bedrock_graph",
    )
    parser.add_argument(
        "--confirm-live-spend",
        action="store_true",
        help="Required for hosted-model modes; acknowledges billed model calls.",
    )
    parser.add_argument("--timeout-seconds", type=float, default=45.0)
    return parser


def _require_explicit_live_spend_confirmation(args: argparse.Namespace) -> None:
    if args.timeout_seconds <= 0:
        raise SmokeFailure("timeout_seconds must be greater than zero")
    if (
        args.expect_agent_source in {"bedrock_graph", "anthropic_graph"}
        and not args.confirm_live_spend
    ):
        raise SmokeFailure(
            "live hosted-model smoke is disabled until --confirm-live-spend is supplied explicitly"
        )


def _provider_for_source(agent_source: str) -> str | None:
    if agent_source == "bedrock_graph":
        return "bedrock"
    if agent_source == "anthropic_graph":
        return "anthropic"
    return None


def _session_request(settings: Settings, args: argparse.Namespace) -> SessionCreateRequest:
    producer = GlossLatticeProducer(
        classifier_id=args.classifier_id or settings.lattice_classifier_id,
        classifier_version=args.classifier_version or settings.lattice_classifier_version,
        confidence_kind="calibrated_probability",
        calibration_version=args.calibration_version or settings.lattice_calibration_version,
        vocabulary_version=args.vocabulary_version or settings.lattice_vocabulary_version,
    )
    return SessionCreateRequest(
        language=args.language or settings.recognition_language,
        stream_kind=StreamKind.GLOSS_LATTICE,
        client=ClientDescriptor(platform=ClientPlatform.TEST, app_version="phase1-smoke-v1"),
        detector=DetectorDescriptor(
            name="phase1-non-sensitive-fixture",
            version="1.0",
            delegate=DetectorDelegate.CPU,
        ),
        producer=producer,
    )


def _prepared_lattice(
    path: Path,
    *,
    session: SessionCreateResponse,
    request: SessionCreateRequest,
    lattice_seq: int,
) -> GlossLattice:
    try:
        fixture = GlossLattice.model_validate_json(path.read_text(encoding="utf-8"))
    except (OSError, ValidationError) as exc:
        raise SmokeFailure(f"fixture validation failed: {path.name}") from exc
    payload = fixture.model_dump(mode="json")
    payload.update(
        session_id=str(session.session_id),
        lattice_seq=lattice_seq,
        language=request.language.value,
        producer=request.producer.model_dump(mode="json"),
    )
    return GlossLattice.model_validate(payload)


def _http_url(base_url: str, path: str) -> str:
    parts = urlsplit(base_url)
    if parts.scheme not in {"http", "https"} or not parts.netloc:
        raise SmokeFailure("base URL must be an absolute HTTP or HTTPS URL")
    if parts.username is not None or parts.password is not None:
        raise SmokeFailure("base URL must not contain credentials")
    if parts.query or parts.fragment:
        raise SmokeFailure("base URL must not contain a query or fragment")
    base_path = parts.path.rstrip("/")
    suffix = path if path.startswith("/") else f"/{path}"
    return urlunsplit((parts.scheme, parts.netloc, f"{base_path}{suffix}", "", ""))


def _websocket_url(base_url: str, websocket_path: str) -> str:
    parts = urlsplit(_http_url(base_url, websocket_path))
    scheme = "wss" if parts.scheme == "https" else "ws"
    return urlunsplit((scheme, parts.netloc, parts.path, "", ""))


async def _receive(socket: ClientConnection, *, timeout_seconds: float) -> LatticeOutboundEvent:
    try:
        raw = await asyncio.wait_for(socket.recv(), timeout=timeout_seconds)
    except TimeoutError as exc:
        raise SmokeFailure("timed out waiting for a server event") from exc
    if not isinstance(raw, str):
        raise SmokeFailure("server returned a binary event")
    try:
        return _OUTBOUND_ADAPTER.validate_json(raw)
    except ValidationError as exc:
        raise SmokeFailure("server returned an event outside the lattice contract") from exc


async def _expect(
    socket: ClientConnection,
    event_type: type[_EventT],
    *,
    timeout_seconds: float,
) -> _EventT:
    event = await _receive(socket, timeout_seconds=timeout_seconds)
    if not isinstance(event, event_type):
        raise SmokeFailure(
            f"expected {event_type.__name__}, received {type(event).__name__}"
        )
    return event


def _expected_evidence(lattice: GlossLattice) -> tuple[LatticeEvidenceTrace, ...]:
    trace: list[LatticeEvidenceTrace] = []
    for slot in lattice.slots:
        selected = next(
            (
                candidate
                for candidate in slot.candidates
                if candidate.gloss_id == slot.resolved_gloss_id
            ),
            None,
        )
        trace.append(
            LatticeEvidenceTrace(
                slot_index=slot.slot_index,
                slot_id=slot.slot_id,
                start_ms=slot.start_ms,
                end_ms=slot.end_ms,
                resolved_gloss_id=slot.resolved_gloss_id,
                confidence=None if selected is None else selected.confidence,
                provenance=slot.provenance,
                candidates=slot.candidates,
            )
        )
    return tuple(trace)


def _counter(metrics: Mapping[str, Any], name: str) -> int:
    counters = metrics.get("counters")
    if not isinstance(counters, Mapping):
        raise SmokeFailure("metrics response has no counters object")
    value = counters.get(name, 0)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise SmokeFailure(f"metrics counter {name} is invalid")
    return value


async def _metrics(client: httpx.AsyncClient) -> Mapping[str, Any]:
    response = await client.get("/metrics")
    if response.status_code != 200:
        raise SmokeFailure(f"metrics request failed with HTTP {response.status_code}")
    try:
        payload = response.json()
    except ValueError as exc:
        raise SmokeFailure("metrics response is not valid JSON") from exc
    if not isinstance(payload, Mapping):
        raise SmokeFailure("metrics response is not an object")
    return cast(Mapping[str, Any], payload)


async def _exercise_lattice(
    socket: ClientConnection,
    lattice: GlossLattice,
    *,
    timeout_seconds: float,
) -> LatticeResultEvent | LatticeRepairRequiredEvent:
    await socket.send(lattice.model_dump_json())
    ack = await _expect(socket, LatticeAckEvent, timeout_seconds=timeout_seconds)
    if (
        ack.session_id != lattice.session_id
        or ack.lattice_seq != lattice.lattice_seq
        or ack.utterance_id != lattice.utterance_id
    ):
        raise SmokeFailure("lattice acknowledgement correlation is invalid")
    if ack.disposition is not LatticeAckDisposition.ACCEPTED:
        raise SmokeFailure("new lattice was not acknowledged as accepted")
    activity = await _expect(socket, LatticeActivityEvent, timeout_seconds=timeout_seconds)
    if (
        activity.session_id != lattice.session_id
        or activity.lattice_seq != lattice.lattice_seq
        or activity.utterance_id != lattice.utterance_id
        or activity.state is not ActivityState.PROCESSING
    ):
        raise SmokeFailure("accepted lattice did not enter processing state")
    terminal = await _receive(socket, timeout_seconds=timeout_seconds)
    if not isinstance(terminal, (LatticeResultEvent, LatticeRepairRequiredEvent)):
        raise SmokeFailure("processing did not end in a terminal lattice event")
    if (
        terminal.session_id != lattice.session_id
        or terminal.lattice_seq != lattice.lattice_seq
        or terminal.utterance_id != lattice.utterance_id
    ):
        raise SmokeFailure("terminal event correlation is invalid")
    if terminal.evidence_trace != _expected_evidence(lattice):
        raise SmokeFailure("terminal evidence trace does not exactly match the input lattice")
    idle = await _expect(socket, LatticeActivityEvent, timeout_seconds=timeout_seconds)
    if idle.session_id != lattice.session_id or idle.state is not ActivityState.IDLE:
        raise SmokeFailure("terminal event was not followed by idle state")
    return terminal


async def _exercise_replay(
    socket: ClientConnection,
    lattice: GlossLattice,
    expected: LatticeResultEvent,
    *,
    timeout_seconds: float,
) -> None:
    await socket.send(lattice.model_dump_json())
    ack = await _expect(socket, LatticeAckEvent, timeout_seconds=timeout_seconds)
    if (
        ack.session_id != lattice.session_id
        or ack.lattice_seq != lattice.lattice_seq
        or ack.utterance_id != lattice.utterance_id
    ):
        raise SmokeFailure("cached acknowledgement correlation is invalid")
    if ack.disposition is not LatticeAckDisposition.CACHED:
        raise SmokeFailure("identical lattice was not served from replay cache")
    terminal = await _receive(socket, timeout_seconds=timeout_seconds)
    if terminal != expected:
        raise SmokeFailure("replayed terminal event changed")
    idle = await _expect(socket, LatticeActivityEvent, timeout_seconds=timeout_seconds)
    if idle.session_id != lattice.session_id or idle.state is not ActivityState.IDLE:
        raise SmokeFailure("replay was not followed by idle state")


async def _run(args: argparse.Namespace) -> dict[str, object]:
    _require_explicit_live_spend_confirmation(args)
    settings = Settings()
    request = _session_request(settings, args)
    provider = _provider_for_source(args.expect_agent_source)

    timeout = httpx.Timeout(args.timeout_seconds)
    normalized_base_url = _http_url(args.base_url, "").rstrip("/")
    async with httpx.AsyncClient(base_url=normalized_base_url, timeout=timeout) as client:
        response = await client.post("/v1/sessions", json=request.model_dump(mode="json"))
        if response.status_code != 201:
            raise SmokeFailure(f"session creation failed with HTTP {response.status_code}")
        try:
            session = SessionCreateResponse.model_validate_json(response.text)
        except ValidationError as exc:
            raise SmokeFailure("session response failed contract validation") from exc

        confident_lattice = _prepared_lattice(
            args.confident_fixture,
            session=session,
            request=request,
            lattice_seq=0,
        )
        repair_lattice = _prepared_lattice(
            args.repair_fixture,
            session=session,
            request=request,
            lattice_seq=1,
        )
        baseline = await _metrics(client)
        socket_url = _websocket_url(normalized_base_url, session.websocket_path)

        async with connect(
            socket_url,
            additional_headers={"Authorization": f"Bearer {session.stream_token}"},
            open_timeout=args.timeout_seconds,
            max_size=session.max_lattice_message_bytes,
        ) as socket:
            initial = await _expect(
                socket,
                LatticeActivityEvent,
                timeout_seconds=args.timeout_seconds,
            )
            if initial.session_id != session.session_id or initial.state is not ActivityState.IDLE:
                raise SmokeFailure("socket did not begin in idle state")

            confident = await _exercise_lattice(
                socket,
                confident_lattice,
                timeout_seconds=args.timeout_seconds,
            )
            if not isinstance(confident, LatticeResultEvent):
                # Repair reason codes and provider source are intentionally safe diagnostics:
                # they contain no prompt, lattice text, token, or model output. Include them so
                # a live-provider failure is distinguishable from a fixture/policy mismatch.
                reason_codes = ",".join(confident.reason_codes) or "none"
                raise SmokeFailure(
                    "high-confidence fixture did not produce lattice_result "
                    f"(agent_source={confident.agent_source}, reason_codes={reason_codes})"
                )
            if confident.agent_source != args.expect_agent_source:
                raise SmokeFailure("high-confidence result used an unexpected agent source")

            after_confident = await _metrics(client)
            if provider is not None:
                calls_counter = f"{provider}_model_calls_total"
                cost_counter = f"{provider}_estimated_cost_nano_usd"
                if _counter(after_confident, calls_counter) < (
                    _counter(baseline, calls_counter) + 2
                ):
                    raise SmokeFailure("assembler and critic model calls were not both observed")
                if _counter(after_confident, cost_counter) <= _counter(
                    baseline, cost_counter
                ):
                    raise SmokeFailure("model usage did not increase estimated cost")
                if _counter(after_confident, "assembler_output_validation_successes") <= _counter(
                    baseline, "assembler_output_validation_successes"
                ):
                    raise SmokeFailure("assembler output validation success was not observed")
                if _counter(after_confident, "critic_model_calls_succeeded") <= _counter(
                    baseline, "critic_model_calls_succeeded"
                ):
                    raise SmokeFailure("critic success was not observed")

            await _exercise_replay(
                socket,
                confident_lattice,
                confident,
                timeout_seconds=args.timeout_seconds,
            )
            after_replay = await _metrics(client)
            replay_calls_counter: str | None = (
                None if provider is None else f"{provider}_model_calls_total"
            )
            if replay_calls_counter is not None and _counter(
                after_replay, replay_calls_counter
            ) != _counter(
                after_confident, replay_calls_counter
            ):
                raise SmokeFailure("cached replay unexpectedly dispatched a model call")

            repair = await _exercise_lattice(
                socket,
                repair_lattice,
                timeout_seconds=args.timeout_seconds,
            )
            if not isinstance(repair, LatticeRepairRequiredEvent):
                raise SmokeFailure("ambiguous fixture did not produce lattice_repair_required")
            if "caption" in repair.model_dump() or "tts_text" in repair.model_dump():
                raise SmokeFailure("repair event exposed caption or TTS fields")
            after_repair = await _metrics(client)
            if replay_calls_counter is not None and _counter(
                after_repair, replay_calls_counter
            ) != _counter(
                after_replay, replay_calls_counter
            ):
                raise SmokeFailure("ambiguous fixture reached the model instead of local repair")

            await socket.send(
                StreamControlMessage(
                    session_id=session.session_id,
                    control_seq=0,
                    action=ControlAction.PING,
                ).model_dump_json()
            )
            pong = await _expect(socket, LatticePongEvent, timeout_seconds=args.timeout_seconds)
            if pong.session_id != session.session_id or pong.control_seq != 0:
                raise SmokeFailure("pong correlation is invalid")
            await socket.send(
                StreamControlMessage(
                    session_id=session.session_id,
                    control_seq=1,
                    action=ControlAction.END,
                ).model_dump_json()
            )
            await asyncio.wait_for(socket.wait_closed(), timeout=args.timeout_seconds)
            if socket.close_code != 1000:
                raise SmokeFailure("session did not close cleanly")

    report: dict[str, object] = {
        "status": "passed",
        "mode": args.expect_agent_source,
        "model_provider": provider or "deterministic",
        "contracts_validated": True,
        "evidence_trace_exact": True,
        "cached_replay_no_dispatch": True,
        "repair_before_model": True,
        "ping_and_end": True,
    }
    if provider is not None:
        calls_counter = f"{provider}_model_calls_total"
        cost_counter = f"{provider}_estimated_cost_nano_usd"
        calls_delta = _counter(after_repair, calls_counter) - _counter(
            baseline, calls_counter
        )
        cost_delta = _counter(
            after_repair, cost_counter
        ) - _counter(baseline, cost_counter)
        # Keep the original Bedrock report keys stable and add the equivalent
        # provider-specific keys for direct Anthropic runs.
        report[f"{provider}_model_calls_delta"] = calls_delta
        report[f"{provider}_estimated_cost_nano_usd_delta"] = cost_delta
    return report


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = asyncio.run(_run(args))
    except SmokeFailure as exc:
        print(json.dumps({"status": "failed", "reason": str(exc)}, sort_keys=True))
        return 1
    except (httpx.HTTPError, OSError) as exc:
        print(
            json.dumps(
                {"status": "failed", "reason": f"transport failed: {type(exc).__name__}"},
                sort_keys=True,
            )
        )
        return 1
    except Exception as exc:
        print(
            json.dumps(
                {"status": "failed", "reason": f"unexpected failure: {type(exc).__name__}"},
                sort_keys=True,
            )
        )
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
