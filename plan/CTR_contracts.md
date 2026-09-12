**SIMPLYNEXT GLOSSLATTICE V1 CONTRACT**

# METADATA

| Field | Value |
| :---- | :---- |
| **Code** | `CTR` |
| **Status** | Frozen v1 |
| **Last reviewed** | 2026-09-06 |
| **Executable authority** | `src/simplynext/contracts/` and contract/transport tests |
| **Fixture** | `tests/fixtures/gloss_lattice_v1.json` |

# 1. PROTOCOL SUMMARY

The protocol has one HTTP negotiation request followed by one authenticated JSON WebSocket. The
client sends `GlossLattice` or `control` messages. The server sends a discriminated event union.
No raw video, landmark, tensor, binary, audio, or unversioned payload is part of this contract.

| Property | Value |
| :------- | :---- |
| Lattice schema | `1.0` |
| Event schema | `1.0` |
| Stream kind | `gloss_lattice` |
| WebSocket encoding | UTF-8 text JSON only |
| Maximum WebSocket message | 32,768 bytes |
| Maximum slots per lattice | 64 |
| Maximum candidates per slot | 5 |
| Languages represented by v1 | `sgsl`, `asl` |
| Timebase | `session_monotonic_ms` |
| Idempotency key | `(session_id, lattice_seq)` plus canonical payload digest |

All models reject unknown fields. Contract identifiers contain 1–128 characters, start with an
ASCII alphanumeric character, and otherwise contain only ASCII alphanumerics, `_`, `.`, `:`, or
`-`. Confidence is finite and lies in `[0, 1]`.

# 2. SESSION NEGOTIATION

## 2.1. Create session

`POST /v1/sessions` with `Content-Type: application/json`:

```json
{
  "language": "sgsl",
  "schema_version": "1.0",
  "stream_kind": "gloss_lattice",
  "client": {
    "platform": "android",
    "app_version": "1.0.0",
    "device_model": "example-device"
  },
  "detector": {
    "name": "mediapipe-holistic",
    "version": "1.0.0",
    "delegate": "gpu"
  },
  "producer": {
    "classifier_id": "temporal_classifier",
    "classifier_version": "1.3.0",
    "confidence_kind": "calibrated_probability",
    "calibration_version": "temperature_v2",
    "vocabulary_version": "sgsl_demo_v1"
  }
}
```

The deployment accepts only the configured language and exact configured producer profile. Client
platform is `ios`, `android`, or `test`; detector delegate is `cpu`, `gpu`, `core_ml`, `nnapi`, or
`unknown`.

A successful request returns HTTP `201`, `Cache-Control: no-store`, and:

```json
{
  "session_id": "12345678-1234-5678-1234-567812345678",
  "stream_token": "opaque-random-capability-at-least-32-characters",
  "token_type": "Bearer",
  "stream_kind": "gloss_lattice",
  "websocket_path": "/v1/sessions/12345678-1234-5678-1234-567812345678/lattices",
  "created_at": "2026-09-06T12:00:00Z",
  "expires_at": "2026-09-06T12:05:00Z",
  "lattice_schema_version": "1.0",
  "max_lattice_message_bytes": 32768,
  "max_lattice_slots": 64,
  "max_candidates_per_slot": 5
}
```

The token is returned once. The client must keep it in memory, never log or persist it, and use it
as `Authorization: Bearer <stream_token>` for the WebSocket and session deletion.

## 2.2. End session over HTTP

`DELETE /v1/sessions/{session_id}` with the bearer header returns HTTP `204`. An active socket must
be ended or closed first; deletion during active Agent processing is rejected.

# 3. WEBSOCKET CONNECTION

Construct `wss://<host><websocket_path>` in production and send the bearer header during upgrade.
Native clients may omit `Origin`. Browser clients must send an origin in the configured allow-list.
Only one active WebSocket may claim a session.

On acceptance the first event is:

```json
{
  "event_schema_version": "1.0",
  "session_id": "12345678-1234-5678-1234-567812345678",
  "type": "activity",
  "state": "idle",
  "lattice_seq": null,
  "utterance_id": null,
  "server_ms": 1788696000000
}
```

# 4. CLIENT-TO-SERVER MESSAGES

## 4.1. GlossLattice

```json
{
  "type": "gloss_lattice",
  "schema_version": "1.0",
  "session_id": "12345678-1234-5678-1234-567812345678",
  "lattice_seq": 0,
  "utterance_id": "utterance-0",
  "language": "sgsl",
  "timebase": "session_monotonic_ms",
  "started_at_ms": 1000,
  "ended_at_ms": 1700,
  "producer": {
    "classifier_id": "temporal_classifier",
    "classifier_version": "1.3.0",
    "confidence_kind": "calibrated_probability",
    "calibration_version": "temperature_v2",
    "vocabulary_version": "sgsl_demo_v1"
  },
  "slots": [
    {
      "slot_index": 0,
      "slot_id": "slot-0",
      "start_ms": 1000,
      "end_ms": 1300,
      "candidates": [
        {"gloss_id": "WATER", "rank": 1, "confidence": 0.96},
        {"gloss_id": "WHAT", "rank": 2, "confidence": 0.02}
      ],
      "resolved_gloss_id": "WATER",
      "provenance": "classifier_high_confidence"
    },
    {
      "slot_index": 1,
      "slot_id": "slot-1",
      "start_ms": 1350,
      "end_ms": 1700,
      "candidates": [
        {"gloss_id": "PLEASE", "rank": 1, "confidence": 0.92}
      ],
      "resolved_gloss_id": "PLEASE",
      "provenance": "classifier_high_confidence"
    }
  ]
}
```

Lattice invariants:

- `lattice_seq` is non-negative, JavaScript-safe, and strictly increases for new content in a
  session.
- Utterance and slot time ranges are positive, chronological, non-overlapping, and contained in
  the utterance range.
- `slot_index` and candidate `rank` are contiguous from zero and one respectively.
- Candidates are unique and ordered by non-increasing confidence.
- `classifier_high_confidence` resolves to rank 1.
- `top_k_signer_confirmed` resolves to a retained candidate.
- `fingerspelled` has a resolved gloss; it may be outside retained candidates.
- `unresolved` has a null resolved gloss.
- Language and producer match both negotiation and deployment configuration.

An identical retry with the same sequence and content replays the cached terminal event. Reusing
the sequence with different content is an error. A later lattice for the same `utterance_id` is
accepted only when it validly answers the immediately pending repair.

## 4.2. Control message

```json
{
  "type": "control",
  "session_id": "12345678-1234-5678-1234-567812345678",
  "control_seq": 1,
  "action": "ping",
  "client_ms": 1788696000000
}
```

`control_seq` strictly increases. `action` is `ping` or `end`. `ping` returns `pong`; `end` erases
the session and closes the socket with code `1000`.

# 5. SERVER-TO-CLIENT EVENTS

Every event includes `event_schema_version: "1.0"`, `session_id`, and a `type` discriminator.

| `type` | Purpose | Required distinguishing fields |
| :----- | :------ | :----------------------------- |
| `lattice_ack` | Atomic acceptance/replay acknowledgement | `lattice_seq`, `utterance_id`, `disposition: accepted|cached`, `server_ms` |
| `activity` | Stream state | `state: idle|processing`; processing also carries lattice correlation |
| `pong` | Ping response | `control_seq`, `server_ms` |
| `error` | Protocol/session/capacity failure | `code`, `message`, `retryable`, optional lattice correlation |
| `lattice_result` | Confident grounded text | shared terminal fields plus `status`, `caption`, `tts_text`, `confidence`, `gloss_id_trace` |
| `lattice_repair_required` | Fail-closed interaction | shared terminal fields plus `status`, `repair_id`, `action`, `message`, `confidence`, targets/choices/reasons |

The normal event order for new work is `lattice_ack` → `activity(processing)` → one terminal event
→ `activity(idle)`. A completed replay is `lattice_ack(cached)` → cached terminal event →
`activity(idle)`.

## 5.1. Shared terminal fields

Both terminal events contain:

- `lattice_seq` and `utterance_id` correlation;
- `evidence_trace`: one ordered item for every lattice slot, containing slot timing, resolved gloss,
  resolved confidence where applicable, provenance, and all retained candidates;
- `classifier_version`;
- nullable `agent_source` and `agent_model_version`;
- `latency_ms`, keyed by bounded identifiers.

The evidence trace is the “gloss trace”: a structured audit trail showing which discrete gloss
identifiers and alternatives supported or blocked the sentence. It is JSON data, not natural-language
reasoning or hidden model chain-of-thought.

## 5.2. Confident result

```json
{
  "event_schema_version": "1.0",
  "session_id": "12345678-1234-5678-1234-567812345678",
  "type": "lattice_result",
  "status": "confident",
  "lattice_seq": 0,
  "utterance_id": "utterance-0",
  "evidence_trace": [
    {
      "slot_index": 0,
      "slot_id": "slot-0",
      "start_ms": 1000,
      "end_ms": 1300,
      "resolved_gloss_id": "WATER",
      "confidence": 0.96,
      "provenance": "classifier_high_confidence",
      "candidates": [
        {"gloss_id": "WATER", "rank": 1, "confidence": 0.96},
        {"gloss_id": "WHAT", "rank": 2, "confidence": 0.02}
      ]
    },
    {
      "slot_index": 1,
      "slot_id": "slot-1",
      "start_ms": 1350,
      "end_ms": 1700,
      "resolved_gloss_id": "PLEASE",
      "confidence": 0.92,
      "provenance": "classifier_high_confidence",
      "candidates": [
        {"gloss_id": "PLEASE", "rank": 1, "confidence": 0.92}
      ]
    }
  ],
  "classifier_version": "1.3.0",
  "agent_source": "bedrock_graph",
  "agent_model_version": "configured-model-id",
  "latency_ms": {"agent": 240, "total": 245},
  "caption": "Water, please.",
  "tts_text": "Water, please.",
  "confidence": 0.92,
  "gloss_id_trace": ["WATER", "PLEASE"]
}
```

`caption` and `tts_text` are UTF-8 JSON strings, not files. `tts_text` is optional text for the
client device's speech synthesizer. The backend does not generate an audio file or stream.

A confident event cannot contain unresolved evidence, and `gloss_id_trace` must exactly match the
resolved gloss sequence in `evidence_trace`.

## 5.3. Repair required

`action` is one of:

- `ask_repeat`;
- `request_fingerspelling`;
- `offer_top_k`;
- `escalate_human_interpreter`.

The event has `status: "uncertain"` and deliberately has no `caption`, `tts_text`, or
`gloss_id_trace`. `offer_top_k` has exactly one target slot and choices copied exactly from that
slot's retained candidates. Other actions have no choices.

## 5.4. Error codes

`invalid_message`, `unauthorized`, `session_not_found`, `session_expired`,
`invalid_session_state`, `non_monotonic_sequence`, `rate_limited`, and `internal_error`.
`retryable` is authoritative for the immediate message. It does not override session expiry or a
terminal WebSocket close.

# 6. CLOSE BEHAVIOR

| Code | Meaning |
| :--- | :------ |
| `1000` | Client ended the session normally |
| `1001` | Server idle timeout |
| `1008` | Repeated invalid messages/policy violation |
| `1009` | Message exceeds 32 KiB |
| `1011` | Internal stream failure after fail-closed handling |
| `4401` | Missing/invalid bearer or session mismatch |
| `4403` | Browser origin rejected |
| `4404` | Session absent |
| `4408` | Session expired |
| `4409` | Invalid session state |

# 7. CHANGE CONTROL

The v1 schema is frozen. Any incompatible field, discriminator, semantic, or limit change requires
a new schema version and parallel client/server support. Compatible bug fixes must update source
models, fixtures, contract tests, transport tests, this document, and client models together.

# 8. CHANGE LOG

| Date | Change |
| :--- | :----- |
| 2026-09-06 | Rewritten to match the implemented GlossLattice-only HTTP/WebSocket contract. |
