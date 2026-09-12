# SignBridge Flutter frontend

SignBridge is an uncertainty-aware sign-language communication prototype. The Flutter frontend now focuses on one live translation page:

1. The camera is opened from the **Open camera** button inside the video feed.
2. Live Translator shows the camera, landmark overlay, captions, tracking confidence, and view modes (Raw / Mesh / Clean).
3. Capture starts automatically when a usable hand is detected; the signer does not press a Start button.
4. A sustained pause, or hands leaving the frame after movement, automatically ends the utterance and prepares it for the next processing stage.
5. The video overlay includes a camera-off button. Turning it off stops landmark tracking and releases the camera; the **Open camera** action starts it again.

The older calibration, My signs, and Settings widgets remain in the source for
future work, but they are not part of the current single-page UI.

## Run

Install Flutter, then from this directory run:

```bash
flutter pub get
flutter run
```

The project includes generated Android, iOS, and web platform scaffolding. Verify the setup with `flutter analyze`, `flutter test`, or `flutter run`.

The generated platform files already include the permission descriptions required by the `camera` and `permission_handler` packages: `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in iOS `Info.plist`, plus camera and record-audio permissions in Android `AndroidManifest.xml`.

## Speech features

The current `frontend_track` UI now includes the speech features from the
`frontend_speechtotext` branch without replacing the tracking screen:

- `SpeechToTextService` manages microphone permission, partial/final
  transcripts, locale selection, errors, and safe start/stop behaviour.
- The **Spoken captions** card in the live page lets a user start, stop, and
  clear speech recognition. Speech audio is handled by the device speech
  service and is not sent by this capture-only frontend.
- `TextToSpeechService` reads the latest `tts_text` (or caption) returned by
  the classifier. Use the speaker button in the video overlay after a result
  is available.
- The frontend keeps completed `LandmarkFrame` data in the Stage 3/4 pipeline.
  The full-integration transport sends only the final compact GlossLattice
  result after a Stage 5/6 classifier is connected; raw camera frames and
  landmarks never cross that boundary.

## Hand tracking and sign analysis

Chrome uses MediaPipe Hand Landmarker through `web/hand_tracking.js`. It requests camera permission, tracks up to two hands, and emits 21 points per hand: normalized `x/y`, relative `z`, handedness, confidence, and world-landmark values when available. MediaPipe Pose Landmarker supplies the left and right shoulder points. The preview is mirrored like a selfie camera, and the skeleton overlay applies the same flip so it stays aligned with the displayed hand; the wire format keeps the original unmirrored coordinates. `HandPoseNormalizer` converts those points into the shared `LandmarkFrame` contract. The frame contains coordinate groups, point confidence, subject tracking, and optional face-expression data for the next processing stage.

The first stable pose becomes the subject for the current camera session. The
tracker compares torso/head anchor shape and recent position, ignores other
pose candidates, and holds the original subject as hidden if detection is
temporarily lost. If two people are equally plausible, it refuses to guess
and keeps the original lock. Use the refresh icon in the video overlay to
deliberately stop the old session and choose a new first subject.

Each accepted hand also includes `finger_status` for `thumb`, `index`, `middle`, `ring`, and `pinky`. Each entry is a smoothed landmark-quality signal: `observed`, `uncertain`, or `not_visible`, with a confidence and evidence-frame count. It does not claim that a finger is anatomically missing; a hidden or occluded finger can look the same as an absent finger in a single camera frame. The existing subject lock is unchanged, so these per-finger signals still belong only to the locked signer.

Every emitted landmark's `visibility` is also used as a point-confidence estimate. For hand and face points, the browser combines the detector confidence with local image detail from a small camera patch; for pose points, it also uses MediaPipe's visibility/presence value. `processing_confidence` (and the wire-level `tracking_confidence`) is the average over the active worlds, with missing points counted as zero within their world's expected landmark budget. It is a quality score for deciding whether to trust the frame, not a probability that the point is anatomically present.

The overlay is a 3D-style skeleton projection. It is not pretending that a webcam can recover precise metric depth: `z` is relative depth from the hand model, projected onto the 2D camera view. This is the same compact representation that can be used by a later sequence classifier. Native Apple builds can use Vision's `VNDetectHumanHandPoseRequest` behind the same `TrackingService` interface.

The current local analyzer intentionally reports a useful feature readout (`open hand`, `closed hand`, movement, confidence) instead of claiming that four dictionary entries are a complete ASL translator. The seed lexicon is in `assets/sign_lexicon.json`. It stores the ASL labels and Handspeak reference links for `hello`, `help`, `water`, and `please`, plus the sign parameters to compare: handshape, movement, location, and handedness. Add a licensed dataset and a trained temporal model before presenting a word-level result as reliable.

Chrome also supports an optional facial-expression signal. The Flutter web
camera remains in the browser for hand and shoulder tracking. About once per
second, `web/hand_tracking.js` sends a compressed still image to
`POST /v1/emotions/analyze`; the Python service uses HSEmotion's EfficientNet
ONNX model and falls back to the OpenCV + DeepFace flow from the referenced
GitHub project if HSEmotion is unavailable. It returns the dominant emotion
and class scores. If the local service is unavailable, hand and shoulder
tracking continue but the face signal is left empty.

My signs uses the live tracker rather than placeholder samples. Each valid capture
stores five examples of a fixed local coordinate sample: wrist-centred x/y/z values
for the left and right hands, curated pose/face coordinates, and facial-expression
scores. The saved entry also
keeps its selected language, coordinate-space label, and face signal for audit
and later matching. One-handed signs are accepted; both hands are not required.
The My signs page includes the ASL reference cards from the seed lexicon and
keeps BSL/SgSL as separate profiles until approved, consented examples are
available.

The live pipeline is:

```text
Chrome camera
  → MediaPipe 21-point hand tracker
  → stable subject/hand tracking state
  → body-relative normalisation
  → Flutter UI + LandmarkFrame JSON
  → server-owned LandmarkBatch v1 adapter
  → authenticated WebSocket transport
  → Railway normalisation → segmentation → classification
  → backend result / repair response
```

The `frontend_segment_classify` commit is not a trained Flutter classifier. It
is a Python synthetic test kit that exercises a heuristic `SignAnalyzer` with
generated hand/pose positions, and its README says it does not change the
Flutter app or provide a trained recognizer. It is useful as a protocol
experiment, but the production sign model remains on the server branch.

### Capture boundaries and handoff

Tracking and camera detection run continuously after the camera starts. The
frontend automatically decides the boundaries using the current lightweight
pause detector:

1. When a usable hand from the locked subject appears, the frontend clears
   the utterance buffer and starts storing new frames.
2. Sign one word or sentence. Every accepted frame is stored as one
   `LandmarkFrame` while the live preview continues.
3. After movement has been observed, a visible, locked subject whose hands
   remain still for about one second is automatically finished. If hands leave
   the frame, that absence also starts the same pause timer.
4. In camera-only mode, the frontend stops storing frames and exposes the
   completed `List<LandmarkFrame>` as `AppController.lastUtteranceFrames`.
   In server-stream mode, the Railway segmenter owns the utterance boundary;
   the frontend continuously sends `LandmarkBatch` micro-batches instead.

Frames received before a hand appears or after an utterance ends are still
available for the live preview, but are not included in that utterance. In
camera-only mode, the next stage should consume `lastUtteranceFrames` (or the list returned by
`TrackingService.finishUtterance()`) and then use `LandmarkFrame.toJson()` for
serialization. `AppController.lastUtteranceJson` is also available as a
convenience view. Server-stream mode serializes the live frames into the fixed
backend contract before sending them; it never sends the rich UI-only
`LandmarkFrame.toJson()` shape.

The schema deliberately stores landmarks, not a guessed translation:

```dart
final List<LandmarkFrame> utteranceFrames = <LandmarkFrame>[];
```

Each `LandmarkFrame` contains its timestamp, frame/point confidence,
left/right hand worlds (21 landmarks per detected hand), curated pose points,
curated upper-face and mouth points, handedness/finger quality, and subject
tracking information. A word or sentence is therefore a time-ordered list of
these frames. Velocity, acceleration, classifier labels, and camera images
are not part of this frontend handoff schema.

## Server-owned segmentation and classification

The production path for the backend branch is implemented by these files:

- `lib/contracts/landmark_stream.dart` defines the session, camera, and
  `landmark_batch` JSON schemas.
- `lib/services/landmark_batch_adapter.dart` converts each rich local
  `LandmarkFrame` into the fixed four-world layout: 21 left-hand points, 21
  right-hand points when present, 9 curated pose points, and 16 curated face
  points. Each point is `[x, y, z, confidence]`.
- `lib/services/landmark_stream_session_client.dart` negotiates the ephemeral
  session with `POST /v1/sessions`.
- `lib/services/landmark_stream_websocket_client.dart` sends ordered batches,
  waits for matching `ack` events, and forwards `activity`,
  `utterance_result`, `repair_required`, and `error` events.
- `lib/services/server_landmark_stream_integration.dart` subscribes to the
  continuous MediaPipe `LandmarkFrame` stream and sends bounded batches. The
  data-object button in the live video overlay opens the last acknowledged
  batch as pretty-printed JSON for inspection.
- `AppController.connectToBackend()` switches utterance ownership to the
  server and applies backend captions, confidence, gloss trace, latency, and
  TTS text to the existing UI.

When this path is enabled, the frontend does not run its local heuristic
analyzer or decide when an utterance ends. The backend's hysteresis segmenter
does that from the incoming frames and emits a result after the segment is
committed.

The connection is opt-in so the camera page still works offline. Enable it
with the required environment values:

```bash
flutter run -d ios \
  --dart-define=SIGNBRIDGE_STREAM_ENABLED=true \
  --dart-define=BPP_HTTPS_BASE_URL=https://your-server \
  --dart-define=BPP_WSS_BASE_URL=wss://your-server \
  --dart-define=BPP_LANGUAGE=sgsl \
  --dart-define=BPP_CLIENT_PLATFORM=ios \
  --dart-define=BPP_CLIENT_VERSION=1.0.0 \
  --dart-define=BPP_DETECTOR_NAME=mediapipe-holistic \
  --dart-define=BPP_DETECTOR_VERSION=0.10.35 \
  --dart-define=BPP_DETECTOR_DELEGATE=unknown
```

For a native client use `android` or `ios` as the platform. The current
Railway contract requires `Authorization: Bearer <stream_token>` during the
WebSocket upgrade. Native Flutter can send that header; a browser WebSocket
cannot, so Chrome can still test the camera locally but needs the backend team
to add a secure browser ticket or cookie-based handshake before live WSS
testing can work.

## Full integration handoff

Your current Flutter UI remains unchanged, but the full integration code is
now present in the same project:

- `lib/services/state_normalised_tracking_service.dart` adds Stage 3/4 state
  to every frame received by the UI.
- `lib/integration/segmentation_classification_port.dart` is the seam for the
  next teammate's Stage 5/6 classifier.
- `lib/services/frontend_pipeline_coordinator.dart` connects processed frames
  to completed classifier output.
- `lib/adapters/gloss_lattice_builder.dart` creates the exact backend payload.
- `lib/services/gloss_lattice_frontend_session.dart` and the related session
  classes negotiate the backend session and send GlossLattice over WebSocket.

The older GlossLattice transport coordinator is tested independently and is
still available for a backend that expects finalized classifier output from a
client-side Stage 5/6 service:

```dart
final pipeline = FrontendPipelineCoordinator(
  tracking: stateNormalisedTracking,
  recognition: teammateClassifier,
  submissions: negotiatedSession.submissions,
);
await pipeline.start();
```

When an utterance ends, the completed frames are also available locally:

```dart
final frames = controller.lastUtteranceFrames;
final jsonFrames = controller.lastUtteranceJson;
```

Each item in `frames` is one processed `LandmarkFrame`. The frame JSON contains
the timestamp, tracking confidence, left/right hand worlds, pose points,
curated face points, handedness/finger quality, and subject tracking
information. `SignSequencePayload.toJson()` remains a local/debug wrapper;
production integration uses the GlossLattice adapter instead of the removed
legacy HTTP `hypotheses` + `features` path.

The backend result contract is kept in `SignAnalysisResult.fromJson()` so the
next stage can pass a response such as:

```json
{
  "type": "utterance_result",
  "utterance_id": "utt-123",
  "status": "confident",
  "caption": "water, please.",
  "tts_text": "water, please.",
  "confidence": 0.91,
  "gloss_trace": ["WATER", "PLEASE"],
  "hypotheses": [],
  "model_version": "classifier-v1",
  "latency_ms": {"total": 125}
}
```

The live overlay is ready to display the returned status, caption, confidence,
gloss trace, model version, and latency. `TextToSpeechService` uses
`tts_text` (or `caption` as a fallback) when the next processing stage
provides a confident completed result.

The optional facial-expression snapshot still uses the local emotion endpoint
described in the hand-tracking section only when that separate face service is
configured. Landmark coordinates remain local to this frontend.

The requested [OpenCV + DeepFace repository](https://github.com/manish-9245/Facial-Emotion-Recognition-using-OpenCV-and-Deepface)
is not a drop-in Flutter dependency. The browser tracker keeps the face
landmarks local; the legacy face-image upload switch and old HTTP sign-sequence
client were removed to preserve the full-integration privacy boundary.

`AlignmentEvaluator` remains independent of the UI. It receives normalized
shoulder points, computes midpoint, width, horizontal error, and vertical error,
and returns feedback such as “Move back” or “Position looks good ✓”.

## Legacy client-owned GlossLattice path (BPP Section 6 Phase 4)

The native client integration is prepared in
`lib/services/bpp_client_integration.dart`. It negotiates `POST /v1/sessions`,
waits for the versioned `activity: idle` handshake, opens the authenticated WSS
path returned by the server, sends only validated finalized `GlossLattice` JSON,
supports exact pending-lattice retry, ping, and clean session end, and exposes
backend result/repair events to the existing UI through
`AppController.acceptBackendEvent()`.

This is a separate contract from the server-owned landmark stream above. It is
not enabled by default and is only appropriate when a teammate supplies a real
client-side `SegmentationClassificationPort` that emits finalized
`GlossLattice` results. The server-owned path should be used for the current
`origin/backend` implementation.

When that classifier is available, the composition point is:

```dart
final config = BppClientConfig.fromEnvironment()!;
final integration = await BppClientIntegration.connect(
  config: config,
  tracking: stateNormalisedTracking,
  recognition: teammateClassifier,
  onEvent: controller.acceptBackendEvent,
);
await integration.start();
```

The classifier must emit `ClassifiedUtteranceOutput` only after its temporal
window is finalized. The app then builds and sends one `GlossLattice`; it does
not send `LandmarkFrame` JSON, camera images, raw scores, or guessed captions.

Supply these non-secret values with `--dart-define`; do not put tokens or
credentials in source:

```text
BPP_HTTPS_BASE_URL
BPP_WSS_BASE_URL
BPP_LANGUAGE                 # asl or sgsl
BPP_CLASSIFIER_ID
BPP_CLASSIFIER_VERSION
BPP_CALIBRATION_VERSION
BPP_VOCABULARY_VERSION
BPP_CLIENT_PLATFORM          # android, ios, or test
BPP_CLIENT_VERSION
BPP_DETECTOR_NAME
BPP_DETECTOR_VERSION
BPP_DETECTOR_DELEGATE         # cpu, gpu, nnapi, core_ml, or unknown
```

Optional controls are `BPP_DEVICE_MODEL`, `BPP_SESSION_TIMEOUT_SECONDS`,
`BPP_CONNECT_TIMEOUT_SECONDS`, `BPP_RESPONSE_TIMEOUT_SECONDS`, and
`BPP_MAX_RETRIES`. The bearer `stream_token` is held in memory only. Browser
Flutter remains blocked until the backend provides a secure ticket/cookie
handshake because browser WebSockets cannot set the required Authorization
header.
