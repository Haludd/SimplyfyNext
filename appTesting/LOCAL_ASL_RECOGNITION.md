**LOCAL ASL RECOGNITION**





# METADATA
<details>
<summary>Document code, status, review date, and usage instructions.</summary>

| Field                   | Value                                    |
| :---------------------- | :--------------------------------------- |
| **Code**                | `LAR`                                    |
| **Status**              | Live                                     |
| **Last reviewed**       | 2026-09-13                               |
| **Source of truth for** | Browser ASL inference and capture handoff |

The frontend runs the James Bustos 250-sign TensorFlow Lite model locally. [S1]
Camera images and classifier coordinates remain in JavaScript; Flutter receives the result and
input counts. The optional word backend receives accepted words. This remains a closed-vocabulary
ASL demonstration; signer accuracy and continuous sentence translation are not established here.

</details>

---





# 1. RUN
From `appTesting/`:

```bash
python3 tool/setup_asl_model.py
flutter pub get
flutter run -d chrome
```

The installer downloads the pinned checkpoint and browser runtime, verifies every SHA-256, and
prepares the browser input allocation. Existing valid files are reused. The combined assets are
19.1 MiB, below the competition's 5 GB submission limit. Model weights and downloaded runtime
files are installed by the setup script, so a fresh clone should run the installer before
`flutter build web`.

The selected language must be **ASL**. The **Open camera** button starts tracking. The signer keeps
the face and at least one hand visible, signs one word, then pauses briefly. Every pause completes
exactly one sign; the next sign starts a fresh model window, so signs are never combined into an
utterance. The previous result stays visible until the next completed result. Incomplete,
interrupted, ambiguous, and low-confidence captures request another attempt. Local corrections
use **Wrong word? Teach it**.

The optional word backend starts from the repository root:

```bash
python3 backend/recognized_words_api.py
```

The frontend can send accepted words to it:

```bash
flutter run -d chrome \
  --dart-define=SIGNBRIDGE_WORD_SUBMISSION_URL=http://127.0.0.1:8000/v1/recognized-signs
```

Recognition does not require this backend. The model and inference runtime are served locally;
the existing MediaPipe camera tracker still loads its pinned Holistic assets from a CDN.
Camera access requires localhost or HTTPS.

---





# 2. MODEL AND COORDINATES
1. The source is `weights/model.tflite` at commit
   `809d456d3ebefe83ca0e23dca0b13a740eaf771c` of the requested repository. [S1]
   The old 25-word ONNX asset, manifest, exporter, and runtime integration have been removed.
2. Input is `[30, 543, 3]`, without a batch axis: **468 face, 21 left hand, 33 pose, 21 right hand**.
   Native image x/y/z values and Holistic hand slots are retained. Missing points are **NaN**.
   The model replaces NaN internally. This differs from the removed model's slot order and zero
   filling. CSS preview reflection does not change classifier coordinates. [S2]
3. The graph selects 13 face landmarks (`0, 9, 11, 13, 14, 17, 117, 118, 119, 199, 346, 347, 348`)
   and all 75 hand/pose landmarks. The TFLite graph includes preprocessing and softmax. [S1, S3]
   Output is `[1, 250]` probabilities; a second softmax must not be applied.
4. The 250 labels follow the exact upstream prediction-index map, including uppercase `TV` at
   index 0. That order was checked against the sorted unique signs in upstream `train.csv`,
   which the reference live application uses. `hello`, `please`, `water`, `bye`, and `thankyou`
   are included. [S2, S4]
5. The original input has dynamic time and an initial allocation of one frame. The installer
   changes only that initial allocation to 30 frames for TFJS-TFLite; weights, operators, and
   the dynamic signature remain unchanged. The source and adapted hashes are recorded in
   `web/models/jamesbustos_asl_250_809d456.manifest.json`.
6. The runtime is TFJS core/CPU `4.9.0` with TFJS-TFLite `0.0.1-alpha.10`. It runs a single
   inference thread with SIMD and non-SIMD fallback assets. [S5] Two startup passes prime the
   dynamic LSTM allocation and validate the resulting probabilities. The first call can return
   a stale output view in this runtime; its output is discarded. Every prediction disposes its
   temporary TFJS tensors.

---





# 3. CAPTURE AND PERSONAL CORRECTIONS
The tracker requests unmirrored 640×480 video at 30 FPS and processes each decoded frame once.
Actual dimensions also travel through Flutter to the separate landmark encoder. Captures keep
three frames of leading context and at most 180 frames or six seconds. A tracking gap longer
than 350 ms, an overflowed capture, or fewer than 30 tracked-hand frames rejects the capture.

The frontend trims idle context and samples longer completed signs evenly to 30 real frames.
This whole-sign sampling is an application policy; the upstream live demo uses a rolling
30-frame window. [S2] Short captures are rejected rather than repeated. Slow movement is measured
from both the initial hand pose and the previous frame. Acceptance requires at least 70% probability, matching the linked repository's threshold. The top class is retained as a tentative `Possible sign` when it falls below that threshold. These are demonstration
thresholds, not a measured accuracy guarantee for an unseen signer.

Personal corrections match a normalized local gesture signature and can store five examples per
word. The label must belong to the new 250-sign vocabulary. The model-specific storage key is
`signbridge.asl.jamesbustos-250.templates.v1`. Previous 25-word templates remain in browser storage
but are not loaded or used to override this model. Personal normalization is independent of model
preprocessing. Correction remains disabled while inference is running.

The separate backend landmark adapter continues to emit 9 pose, 21 points per present hand, and
16 face points; absent hands remain null. `SIGNBRIDGE_STREAM_ENABLED` selects the existing
server-owned recognition architecture. Its bearer-header WebSocket transport supports native
clients, not browser WebSockets. The local ASL path sends accepted words over HTTP, identifying
its classifier as `jamesbustos_asl_250`. The older `backend/run.py` entry point references missing
modules and is not the local ASL word backend.

---





# 4. VALIDATION
From `appTesting/`:

```bash
python3 tool/setup_asl_model.py --check
flutter analyze
flutter test
npm ci
npm run test:web
npx playwright install chromium
npm run test:browser
flutter build web
```

The browser test also accepts `CHROME_PATH` pointing to an installed Chrome executable. It blocks
external network requests and executes the real model using synthetic landmarks with expected
probabilities generated from the original checkpoint. Right-hand, left-hand, both-hand,
stationary, missing-face, missing-pose, and empty cases run twice in opposite orders to check
for stale outputs or retained state. It also verifies result decoding, vocabulary corrections,
and stable TFJS tensor counts.

Optional native equivalence checks require TensorFlow and NumPy:

```bash
python3 tool/verify_asl_model.py --source /path/to/upstream/weights/model.tflite
```

On 2026-09-13, all seven native comparisons were identical. Fourteen browser/native comparisons
had maximum absolute probability error `0.0000035017728805541992`. The 290 Flutter regression
tests and 17 JavaScript tests passed, static analysis found no issues, and the web build succeeded.
The built page also opened a synthetic 640×480 camera feed, loaded the replacement model, and
produced MediaPipe frames in Chrome using software WebGL. Synthetic fixtures
verify model integration and numerical consistency; they do not measure recognition accuracy
with a person signing. A live trial with the intended signers remains necessary for that claim.

Runtime licenses are installed beside the vendor assets. Model/dataset redistribution terms
still require review before distribution.

---





# 5. SOURCES
1. **[S1]** Requested model repository and checkpoint, pinned commit `809d456`.
   https://github.com/jamesjbustos/sign-language-recognition/blob/809d456d3ebefe83ca0e23dca0b13a740eaf771c/weights/model.tflite
   Primary binary; tensor shapes and graph operators were inspected locally.
2. **[S2]** Reference live inference: packing order, NaN missing values, window, and label decoding.
   https://github.com/jamesjbustos/sign-language-recognition/blob/809d456d3ebefe83ca0e23dca0b13a740eaf771c/streamlit/app.py
   Primary implementation source.
3. **[S3]** Training notebook: selected landmarks and NaN handling, checked against the binary.
   https://github.com/jamesjbustos/sign-language-recognition/blob/809d456d3ebefe83ca0e23dca0b13a740eaf771c/Guides/Train_Model.ipynb
   Primary implementation source; the delivered checkpoint is authoritative.
4. **[S4]** Exact upstream label mapping.
   https://github.com/jamesjbustos/sign-language-recognition/blob/809d456d3ebefe83ca0e23dca0b13a740eaf771c/asl-signs/sign_to_prediction_index_map.json
   Primary vocabulary source.
5. **[S5]** TensorFlow's TFLite browser package and pinned runtime metadata.
   https://github.com/tensorflow/tfjs/tree/master/tfjs-tflite
   https://cdn.jsdelivr.net/npm/@tensorflow/tfjs-tflite@0.0.1-alpha.10/package.json
   Primary runtime documentation; every installed file is checksum-pinned in the manifest.
