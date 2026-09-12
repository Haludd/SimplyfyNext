# SignBridge frontend integration branch

This document describes the code assembled on `frontend_full_integration`.
It is an integration branch only; it is not merged into `main`.

## What is connected

```text
Browser camera
  -> Harold's MediaPipe bridge and Stage 1/2 tracking
  -> LandmarkFrame (raw Stage 1/2 fields preserved)
  -> Tracking State (Stage 3)
  -> Normalisation (Stage 4)
  -> LandmarkFrame + trackingState + normalisation
  -> SegmentationClassificationPort (Stage 5/6 plug-in point)
  -> ClassifiedUtteranceOutput
  -> GlossLatticeBuilder
  -> exact GlossLattice v1 JSON
  -> negotiated, authenticated WebSocket
  -> backend acknowledgement and terminal result/repair receipt
```

The pipeline does not send camera frames, landmarks, normalised coordinates,
feature windows, or raw classifier scores to the backend. Only the frozen
`GlossLattice` JSON crosses the final frontend/backend boundary.

Harold's optional legacy DeepFace image-upload switch is disabled on this
integration branch so a URL flag cannot bypass that privacy boundary.

## Branch sources

- Stage 1/2 files were selected from `origin/frontend_track` at `dc1cea5`.
- Stage 3/4 models and services come from `frontend_state_norm` at `406cdfb`.
- The frozen GlossLattice adapter comes from
  `frontend_gloss_lattice_adapter` at `445deb3`.
- `origin/frontend_segment_classify` currently equals `main` and contains no
  production Stage 5/6 implementation. Nothing was invented in its place.

The Stage 1/2 branch was not merged wholesale because it also contains
unrelated backend and obsolete raw-landmark transport files. Only its browser
MediaPipe/tracking implementation and camera preview were brought into this
branch.

The unused legacy `UtteranceApiClient` was removed because it posted the old
`hypotheses` + `features` HTTP body and provided a second, incompatible backend
path. No application code referenced it.

## Handoff rules

### Stage 2 to Stage 3

`WebTrackingService` receives Harold's browser events and emits his
`LandmarkFrame`. `StateNormalisedTrackingService` decorates that service and
publishes the processed frames. It does not run MediaPipe itself.

### Stage 3 to Stage 4

The same `LandmarkFrame` instance shape is used. Stage 3 attaches
`trackingState`; Stage 4 attaches `normalisation`. Raw measurements remain
unchanged, and missing landmarks remain missing.

### Stage 4 to Stage 5

Esther's service must implement `SegmentationClassificationPort`:

- `addNormalisedFrame` receives an ordered Stage 4 `LandmarkFrame` and the
  current session-monotonic time.
- `reset` must discard any unfinished temporal window when capture stops or
  restarts.
- `completedUtterances` emits only finished Stage 5/6 results.
- `close` releases Stage 5/6 resources.

This interface deliberately contains no segmentation or classifier algorithm.
The coordinator rejects a frame that bypasses Stage 3/4.

### Stage 6 to WebSocket

`ClassifiedUtteranceOutput` supplies an utterance ID, one monotonic utterance
interval, and ordered `GlossSlotInput` values. The builder maps those values to
the exact frozen names:

| Stage 5/6 meaning | GlossLattice wire name |
| --- | --- |
| utterance identity | `utterance_id` |
| utterance interval | `started_at_ms`, `ended_at_ms` |
| slot identity/order | `slot_id`, `slot_index` |
| slot interval | `start_ms`, `end_ms` |
| class label | `gloss_id` |
| calibrated probability | `confidence` |
| candidate order | `rank` |
| selected label | `resolved_gloss_id` |
| decision source | `provenance` |

The session coordinator owns the single session-monotonic clock and sequence
counters. A failed lattice remains pending. After reconnecting, retry sends the
same object, session ID, sequence number, and bytes so the backend can replay
its cached result safely.

## Runtime status

| Part | Status |
| --- | --- |
| Browser MediaPipe -> Stage 1/2 | Connected |
| Stage 1/2 -> Stage 3/4 | Connected and tested |
| Stage 4 -> Stage 5/6 | Interface connected and tested with a deterministic test double |
| Real Stage 5/6 algorithm | Waiting for Esther's branch |
| Stage 6 -> GlossLattice | Connected and tested |
| HTTP session negotiation | Connected and tested |
| Native Android/iOS authenticated WebSocket | Connected and tested without a live server |
| Browser authenticated WebSocket | Blocked by the backend contract |
| Live backend round trip | Deferred until the backend is ready |

The live `main.dart` activates Harold's web tracker followed by Stage 3/4. It
cannot construct the later pipeline yet because there is no real
`SegmentationClassificationPort` implementation to inject.

## Browser transport blocker

The backend currently requires the bearer token in an `Authorization` header,
and its client platform enum contains `android`, `ios`, and `test`. Standard
browser WebSockets cannot attach a custom `Authorization` header. Therefore the
web connection fails explicitly and never puts the bearer token in a URL.

To enable the browser safely, the backend contract must add both:

1. a `web` client-platform value; and
2. a secure short-lived WebSocket ticket, secure cookie, or equivalent browser
   handshake.

This is a backend/contract decision. The frontend must not work around it by
putting the bearer token in a query string.

## Reliability and lifecycle

- HTTP session creation, WebSocket opening, and backend response waiting have
  bounded timeouts.
- Session negotiation and WebSocket authentication are pinned to the same
  origin, preventing a bearer token from being sent to another host.
- Stop/start cancels and recreates stream subscriptions without duplicates.
- Capture restart resets Stage 3/4 derivative history and Stage 5/6 temporal
  state.
- An asynchronous upstream stream is allowed to deliver its final utterance
  frame before the processed buffer closes.
- Transport failure retains the exact pending lattice and supports replacing a
  dead socket before retry.

## Verification commands

Run from `frontend/`:

```text
flutter test --no-pub
flutter analyze --no-pub
flutter build web --no-pub
```

The unit/integration suite is intentionally backend-free. A final live test
must be run after the backend exposes the agreed `/v1/sessions` and lattice
WebSocket endpoints.
