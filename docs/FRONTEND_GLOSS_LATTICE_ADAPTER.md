# Frontend GlossLattice Adapter

This guide explains how the frontend turns completed segmentation and classifier results into the
exact `GlossLattice` JSON accepted by the backend. It is an integration guide, not a second wire
contract. The frozen source of truth remains `CTR_contracts.md` on the `front_back_contract`
branch. If this guide ever disagrees with that contract, `CTR_contracts.md` wins.

## The boundary in one picture

```text
Stage 4: normalisation
        |
        | LandmarkFrame with body-relative motion data
        v
Stage 5: segmentation (Esther)
        |
        | FeatureWindow + boundary information (frontend only)
        v
Stage 6: classifier and calibration (Esther)
        |
        | ordered calibrated candidates + resolution decision
        v
GlossLatticeBuilder                 <-- this adapter branch
        |
        | one validated GlossLattice
        v
compact JSON serializer
        |
        | one unchanged WebSocket text message
        v
WebSocket                           <-- transport only
        |
        v
backend GlossLattice receiver
```

The adapter is like a packing desk: it takes frontend results and packs them into the exact box
shape required by the backend. The WebSocket is only the delivery vehicle. It must not rename,
guess, add, or remove fields.

There is deliberately no direct normalisation-to-WebSocket mapping. Normalised coordinates and
motion values are inputs to segmentation and classification. Only compact symbolic classifier
evidence crosses the network.

## Ownership

| Branch | Owner/responsibility | What this adapter must not do |
| --- | --- | --- |
| `frontend_track` | Subject tracking and MediaPipe landmark extraction | Reimplement MediaPipe or alter Harold's `LandmarkFrame` output |
| `frontend_state_norm` | Tracking state and body-relative normalisation | Alter Stage 3/4 behaviour |
| `frontend_segment_classify` | Segmentation, classification, calibration, and classifier decisions | Reimplement Esther's algorithms |
| `front_back_contract` | Frozen `GlossLattice` v1 names, meanings, limits, and golden fixture | Quietly change the contract from an integration branch |
| `frontend_gloss_lattice_adapter` | Convert completed frontend decisions to the frozen wire model and send that model unchanged | Add backend state or invent a second wire format |
| `backend` | Authenticate, validate, assemble, critique, and return a result or repair request | Trust client-controlled identity or raw perception data |

The adapter belongs on `frontend_gloss_lattice_adapter` because it joins separately owned frontend
stages to the shared wire boundary. Contract changes still require agreement and belong on
`front_back_contract`.

## Public integration seam

The frontend adapter uses these types:

- `frontend/lib/contracts/gloss_lattice.dart`
  - `GlossLatticeContract`
  - `GlossLatticeLanguage`
  - `GlossProvenance`
  - `GlossLatticeProducer`
  - `GlossCandidate`
  - `GlossSlot`
  - `GlossLattice`
  - `GlossLatticeValidationException`
- `frontend/lib/adapters/gloss_lattice_builder.dart`
  - `CalibratedGlossCandidateInput`
  - `GlossSlotInput`
  - `GlossLatticeBuilder`
- `frontend/lib/services/gloss_lattice_websocket_client.dart`
  - `GlossLatticeTextChannel`
  - `WebSocketGlossLatticeTextChannel`
  - `GlossLatticeWebSocketClient`
  - `GlossLatticeSubmissionReceipt`
  - `GlossLatticeWebSocketException`

`GlossLatticeBuilder` is constructed with the session ID, selected language, and producer profile.
At an utterance boundary, integration code calls `build` with the next lattice sequence number, the
stable utterance ID, utterance times, and ordered `GlossSlotInput` values.

Each `GlossSlotInput` contains:

| Adapter input | Meaning |
| --- | --- |
| `slotId` | Stable identifier for this segmented sign position; normally derived from the feature window ID |
| `startMs` | Inclusive slot start on the session monotonic clock |
| `endMs` | Exclusive slot end on the same clock |
| `candidatesInRankOrder` | Zero to five classifier candidates, already ordered best first |
| `resolvedGlossId` | Selected gloss ID, or `null` when unresolved |
| `provenance` | The exact rule that authorized the resolution |

Each `CalibratedGlossCandidateInput` contains `glossId` and `calibratedConfidence`. A raw model
score is not a calibrated confidence and must not be passed as one.

This seam intentionally does not import Esther's future concrete classifier class. When her output
is available, one small integration function should translate it into these two input types. The
frozen wire classes must not be changed to match an internal classifier representation.

## Exact envelope mapping

All eleven root properties are required.

| Wire property | Exact source | Rule |
| --- | --- | --- |
| `type` | `GlossLatticeContract` | Constant `gloss_lattice` |
| `schema_version` | `GlossLatticeContract` | Constant `1.0` |
| `session_id` | Session-creation response | UUID; must equal the authenticated WebSocket session |
| `lattice_seq` | Frontend session sequence coordinator | Non-negative safe integer; increases for each new lattice |
| `utterance_id` | Frontend utterance coordinator | Stable identifier for the logical utterance |
| `language` | Session configuration | Exactly `sgsl` or `asl` |
| `timebase` | `GlossLatticeContract` | Constant `session_monotonic_ms` |
| `started_at_ms` | Earliest boundary of the completed utterance | Session-relative monotonic milliseconds |
| `ended_at_ms` | Exclusive end boundary of the utterance | Same clock; strictly greater than `started_at_ms` |
| `producer` | Session configuration | Must exactly repeat the five-field profile used to create the session |
| `slots` | Ordered `GlossSlotInput` list | One to 64 chronological slots |

The producer has exactly these five required properties:

| Wire property | Source/meaning |
| --- | --- |
| `classifier_id` | Stable classifier family or artifact ID |
| `classifier_version` | Exact classifier version used for this session |
| `confidence_kind` | Constant `calibrated_probability` |
| `calibration_version` | Exact calibration artifact/version used |
| `vocabulary_version` | Exact vocabulary whose case-sensitive IDs appear in candidates |

Do not rebuild producer metadata for every utterance. Store the negotiated session profile and use
that same immutable value for session creation and every lattice in that session.

## Exact slot and candidate mapping

| Wire property | Adapter source | Rule |
| --- | --- | --- |
| `slot_index` | Position in the ordered `slots` input | Builder assigns `0, 1, 2, ...`; do not take an unrelated frame index |
| `slot_id` | `GlossSlotInput.slotId` | Unique stable identifier, normally mapped from `FeatureWindow.window_id` |
| `start_ms` | `GlossSlotInput.startMs` | Inclusive session-monotonic start |
| `end_ms` | `GlossSlotInput.endMs` | Exclusive session-monotonic end |
| `candidates` | `GlossSlotInput.candidatesInRankOrder` | Zero to five entries, best calibrated confidence first |
| `resolved_gloss_id` | `GlossSlotInput.resolvedGlossId` | Required property whose value may be `null` |
| `provenance` | `GlossSlotInput.provenance` | One of the four frozen values below |

Candidate mapping is intentionally small:

| Wire property | Adapter source | Rule |
| --- | --- | --- |
| `gloss_id` | `CalibratedGlossCandidateInput.glossId` | Opaque, case-sensitive vocabulary key |
| `rank` | Position in `candidatesInRankOrder` | Builder assigns `1, 2, 3, ...`; maximum 5 |
| `confidence` | `CalibratedGlossCandidateInput.calibratedConfidence` | Finite calibrated probability from `0.0` through `1.0` |

The four provenance values have different meanings:

- `classifier_high_confidence`: at least one candidate exists and the resolved ID equals rank 1.
- `top_k_signer_confirmed`: the signer selected one of the retained candidates.
- `fingerspelled`: a non-null fingerspelled/lexicon ID was supplied; it need not be in candidates.
- `unresolved`: no gloss was selected, so `resolved_gloss_id` is exactly `null`.

Provenance is an authorization rule, not a description of how segmentation fired. Therefore
`segmenter_arm` and `BoundaryEvent.reason` must never be copied into `provenance`.

## The monotonic timing requirement

All four time fields use one clock origin established when the frontend session begins:

```text
session begins: elapsed time = 0 ms
frame A captured: elapsed time = 1000 ms
frame B captured: elapsed time = 1300 ms
```

In Dart, a session-owned `Stopwatch` is a suitable monotonic clock. Capture its elapsed time when
each frame enters the pipeline and retain the mapping long enough for segmentation to identify the
first and final frame of a window.

Do not use:

- `DateTime.now()`;
- `millisecondsSinceEpoch`;
- an ISO-8601 timestamp string;
- `frame_range.start` or `frame_range.end` renamed to milliseconds;
- `frameIndex * 33` as a replacement for measured capture time.

A frame index says which frame it was. A timestamp says when it was captured. They are not the same
piece of information, even in a nominal 30 FPS pipeline where frames may be delayed or dropped.

`FeatureWindow.frame_range` remains useful internally. The Stage 5/6 integration must look up the
corresponding captured monotonic times and populate `GlossSlotInput.startMs` and `endMs`. Intervals
are half-open (`[start_ms, end_ms)`): the start belongs to the slot and the end does not.

## Frontend data that must stay inside the frontend

The wire contract rejects unknown properties. The adapter must consume or discard internal data,
not forward it. In particular, a `GlossLattice` must not contain:

- camera frames, images, base64 media, or audio;
- `LandmarkFrame`, hand/pose/face landmarks, or tracking-state details;
- `normalized_coordinates`, `normalisedCoordinates`, velocity, or acceleration;
- `FeatureWindow`, `frame_range`, `frame_index_range`, or feature arrays;
- boundary events, `event_type`, `reason`, or `segmenter_arm`;
- raw classifier `score`, `class_scores`, tensors, or embeddings;
- segmentation-level `confidence`, `refused`, or `calibrated` flags;
- the old `hypotheses` or `features` HTTP objects;
- ISO fields such as `started_at` and `ended_at`;
- prompts, captions, TTS text, signer identity, conversation history, or Agent state.

These distinctions are important:

| Frontend value | Why it is not a wire replacement |
| --- | --- |
| `FeatureWindow.confidence` | Measures a segmentation/window property, not calibrated probability for a gloss |
| Raw classifier `score` | May be a logit or model-specific number; it is not necessarily in `[0, 1]` |
| `segmenter_arm` | Explains which detector emitted a window; it is not a resolution provenance rung |
| `BoundaryEvent.reason` | Explains a boundary event; it does not authorize a gloss selection |
| `frame_range` | Contains frame indexes, not session-monotonic milliseconds |

## Validation rules

The Dart model and builder protect the local structural rules before anything is sent:

1. Identifiers contain 1-128 ASCII characters, start with a letter or digit, and thereafter use
   only letters, digits, `_`, `.`, `:`, or `-`.
2. Integer wire values are real non-negative integers no larger than `9,007,199,254,740,991`.
3. The utterance has positive duration: `ended_at_ms > started_at_ms`.
4. There are 1-64 slots.
5. Slot indexes are contiguous from zero and equal array order.
6. Slot IDs are unique.
7. Every slot has positive duration and lies inside the utterance interval.
8. Slots are chronological and do not overlap. Gaps are allowed.
9. There are 0-5 candidates per slot.
10. Candidate ranks are contiguous from one and equal array order.
11. Candidate gloss IDs are unique within their slot.
12. Candidate confidences are finite, in `[0, 1]`, and non-increasing. They need not sum to one.
13. Resolution and provenance follow the four rules above.
14. Unknown JSON properties are never emitted.

Session integration has additional responsibilities that cannot be proven from one lattice alone:

1. `session_id` matches the authenticated WebSocket route and token.
2. `producer` exactly matches the profile used when creating the session.
3. A new `lattice_seq` is greater than every previously accepted sequence in that session.
4. An exact retry reuses the same `(session_id, lattice_seq)` and identical semantic content.
5. All times come from the same session monotonic clock origin.

Finally, the WebSocket client must UTF-8 encode one compact JSON object and reject payloads larger
than 32,768 bytes. It receives an already-connected and authenticated text channel. It does not
perform classification or reinterpret the lattice.

## Esther integration checklist

At the Stage 5/6 handoff, integration code should:

1. Keep Esther's `FeatureWindow` and boundary information internal.
2. Preserve a stable window/slot ID and the capture-time mapping for its first and last frame.
3. Calibrate class outputs before creating `CalibratedGlossCandidateInput` values.
4. Sort retained candidates best first and retain no more than five.
5. Make the resolution decision explicit with both `resolvedGlossId` and `GlossProvenance`.
6. Create one `GlossSlotInput` per chronological sign position.
7. Call `GlossLatticeBuilder.build` once the utterance is complete.
8. Give the completed `GlossLattice` to `GlossLatticeWebSocketClient` without changing its JSON.

Esther's classes do not need to use wire-style snake_case names. Dart may use `windowId` and
`calibratedConfidence`; only `GlossLattice.toJson()` owns exact wire names such as `slot_id` and
`resolved_gloss_id`. Keeping naming conversion in this one adapter prevents each pipeline stage
from inventing its own backend format.

## Verification source

`frontend/test/fixtures/gloss_lattice_v1.json` is an exact copy of the authoritative backend
fixture `front_back_contract:tests/fixtures/gloss_lattice_v1.json`. It deliberately contains all
four provenance cases. Contract tests should parse this same content, verify exact snake_case JSON,
and prove that frontend serialization stays compatible with backend validation.
