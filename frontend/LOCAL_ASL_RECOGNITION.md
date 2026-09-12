# Local Google ASL recognition

The browser now runs the linked Google ASL model locally. Camera images and
the full 543-point MediaPipe tensor stay in JavaScript; Flutter receives only a
recognized word, confidence, and the three best candidates. The backend API
receives that compact result only.

This model is used only when the selected language is **ASL**. BSL and SgSL
continue through their existing capture path because their signs must not be
interpreted with an ASL-trained vocabulary. Do not enable
`SIGNBRIDGE_STREAM_ENABLED` at the same time: that setting selects the separate
server-owned landmark classifier architecture.

After a capture completes, the bottom of the live camera preview shows a
**RECOGNITION OUTPUT** panel with the detected word, confidence, and up to
three alternatives. It also shows a compact **Model input** audit: the model
receives the complete MediaPipe Holistic topology — 468 face, 33 pose, 21
left-hand, and 21 right-hand landmarks (543 total), with x/y/z coordinates —
resampled to its required 16-frame sequence. The audit reports how many of
the selected frames contained each hand; it exposes no raw coordinates.

The checkpoint's own preprocessing selects 20 face entries and all 42 hand
entries; it does not use pose values as classifier features. Face landmarks
must therefore remain enabled: they are part of the trained feature set and
provide the reference used to normalize a signer's coordinates. Pose remains
in the 543-slot tensor and tracker only to preserve the model's landmark
indices and to keep the Holistic subject/hand association stable.

If the generic model confidently reads a person's signing incorrectly (for
example, it calls their `bye` motion `blue`), use **Wrong word? Teach it** in
that panel and enter the correct word. This saves a normalized model-aligned
motion template in that browser's local storage only; it does not change the model,
does not globally relabel `blue`, and is not submitted to the backend. The
current template format uses the same 20 face + 42 hand feature geometry and
normalization as the checkpoint. Repeat the same sign and correction three to
five times to cover natural variation. On later close matches, the local
template takes precedence over the generic model result.

The model recognizes the upstream project's 25 ASL labels: `hello`, `please`,
`thankyou`, `bye`, `mom`, `dad`, `boy`, `girl`, `man`, `child`, `drink`,
`sleep`, `go`, `happy`, `sad`, `hungry`, `thirsty`, `sick`, `bad`, `red`,
`blue`, `green`, `yellow`, `black`, and `white`.

This build uses the compatible `v20250723_042752` checkpoint. Its upstream
manifest reports a slightly higher held-out validation score than the earlier
checkpoint, but that number is not a guarantee of webcam accuracy for a new
signer. The browser also rejects low-confidence or ambiguous predictions
instead of sending a likely wrong word to the backend.

## Landmark compatibility

The checkpoint was trained and its reference live tool was run with MediaPipe
Holistic: one coherent stream of 468 face points, 33 pose points, then 21
left-hand and 21 right-hand points. The browser therefore uses the pinned
`@mediapipe/holistic@0.5.1675471629` graph rather than independently combining
the newer Hand, Pose, and Face Task models. It preserves Holistic's native
left/right slots, requests the reference tool's 640×480 / 30 FPS camera mode,
and keeps the reference tool's continuous 30-frame capture buffer before
resampling to the ONNX model's 16-frame input. A missing hand is preserved as
zeros in its own 21-point slot, rather than shifting the other hand's values.
Because this ONNX export has a fixed 16-frame time axis, the browser waits for
a complete 16-frame window instead of repeating a short five-frame capture.
Do not replace this with separately sampled landmarks without retraining or
validating the classifier.

The ignored local asset is expected at:

```text
web/models/google_asl_25_v20250723_042752.onnx
```

It has been exported in this workspace. To recreate it from an authorized
clone of the upstream repository, install PyTorch and ONNX, then run from
`frontend/`:

```bash
python3 tool/export_google_asl_onnx.py \
  --source /path/to/google_asl_recognition \
  --output web/models/google_asl_25_v20250723_042752.onnx
```

The source model file is ignored by git because it is a generated binary and
the upstream repository does not provide a clear redistribution license.
Confirm the upstream model and dataset terms before shipping it.

## Run the word backend

From the repository root, run the word-only local backend:

```bash
python3 backend/prototypes/frontend_branch_backend/recognized_words_api.py
```

Then launch the Flutter web app with its endpoint:

```bash
cd frontend
flutter run -d chrome \
  --dart-define=SIGNBRIDGE_WORD_SUBMISSION_URL=http://127.0.0.1:8000/v1/recognized-signs
```

The prototype stores accepted word events in
`backend/prototypes/frontend_branch_backend/data/recognized_words.jsonl`.
It rejects raw video, landmarks, feature vectors, and utterance frames. The
local server permits browser CORS for development; replace that wildcard with
your deployed frontend origin before production.

The web recognizer downloads ONNX Runtime from a pinned CDN, matching the
existing MediaPipe loading model. A production offline deployment should vendor
that runtime and serve it from the same origin.
