# SimplyNext integrated two-way conversation

`integration_deploy1` combines the production room backend, the browser-local
PopSign 250 model, client speech recognition, and the two-device conversation
experience.

Integration inputs reviewed for this branch:

- backend base: `origin/backend` at `c0de56a`
- model frontend: `origin/frontend_model2` at `8e28626` (`appTesting/` imported as `frontend/`)
- room UX reference: `origin/feature/two-way-conversation` at `6755dbb`

The implementation adapts the prototype's QR, tab recovery, shared timeline,
presence, and two-device interaction to the backend-owned `/v1/rooms` protocol.
This replaces the prototype's incompatible `/api/rooms`, six-character codes,
and minimal words payload.

## Runtime boundary

The signer creates a room. The hearing participant scans the invitation QR or
enters its eight-character code. Both devices receive the same canonical room
timeline over an authenticated WebSocket.

The signing device keeps camera frames, MediaPipe landmarks and ONNX inference
inside the browser. A pause completes one isolated sign. Recognized English
words and their normalized model scores accumulate locally until the signer
presses **Send signs**. Only the finalized `TranslatedSignUtterance v1` JSON is
sent to the backend.

The hearing participant records speech through the device speech-recognition
service, reviews the resulting text, and explicitly sends it. The backend never
receives microphone audio. Both participants can type as a fallback.

The current model recognizes the shipped PopSign 250 isolated-sign vocabulary.
Continuous camera capture does not make it a general continuous-ASL model.
Legacy GlossLattice and landmark-stream files inherited from the model branch
remain for historical tests, but `main.dart` does not construct or connect
those transports. The active room path sends only finalized word JSON or
finalized text.

The integrated producer artifacts are pinned by these SHA-256 digests:

- ONNX model: `543ace9db19b170a5f0ad6e8e501a476e3e7f3f232f2b268f8a1ba549731d5ad`
- Model label map: `1fe747c2f44c68dbb396947e35193c96d363f3dede0be8defa5e08546400bf5d`
- Local sign lexicon: `767c826bcf86662ed0be85170fc7755c920c34af93bd52d9eb10c6901bbeae0c`

These hashes identify the integrated files; they are not production quality
evidence. Production sentence acceptance still requires the reviewed
evaluation and policy described in `plan/WORD_ACCEPTANCE_POLICY.md`.

## Local run

Use Python 3.12 and Flutter with Dart 3.13 or newer.

Terminal 1, from the repository root:

```bash
python3.12 -m venv .venv-integration
source .venv-integration/bin/activate
python -m pip install -e '.[dev]'
SIMPLYNEXT_ALLOWED_HOSTS=127.0.0.1,localhost \
SIMPLYNEXT_ALLOWED_ORIGINS=http://localhost:8081 \
python main.py
```

Terminal 2:

```bash
cd frontend
flutter pub get
flutter run -d chrome --web-port 8081 \
  --dart-define=SIGNBRIDGE_API_BASE_URL=http://127.0.0.1:8000
```

Open `http://localhost:8081` in two browser profiles. Physical phones should
use an HTTPS frontend URL so camera and microphone permissions work.

The default backend profile supports two-way typed/speech messages and returns
a safe repair for sign submissions without spending provider credits. For the
checked-in synthetic sign demo, run the backend with:

```bash
SIMPLYNEXT_RECOGNITION_LANGUAGE=asl \
SIMPLYNEXT_BEDROCK_ENABLED=false \
SIMPLYNEXT_ANTHROPIC_ENABLED=false \
SIMPLYNEXT_WORD_POLICY_PATH=data/word_policy.synthetic.json \
SIMPLYNEXT_WORD_TEMPLATES_PATH=data/word_templates.example.json \
SIMPLYNEXT_ALLOWED_HOSTS=127.0.0.1,localhost \
SIMPLYNEXT_ALLOWED_ORIGINS=http://localhost:8081 \
python main.py
```

This synthetic mode is for integration testing and does not qualify the model
for production sentence acceptance.

## Deploy from the same branch

Create two Railway services from `integration_deploy1`.

### Backend service

- Service root: repository root
- Config file: `/railway.json`
- Health check: `/readyz`
- One worker and one replica
- Set `SIMPLYNEXT_ALLOWED_HOSTS` to the backend Railway hostname plus
  `healthcheck.railway.app`.
- Set `SIMPLYNEXT_ALLOWED_ORIGINS` to the exact HTTPS frontend origin.

The existing backend deployment can remain if it runs the same v1 room
contract. Check it with:

```bash
curl https://BACKEND_HOST/readyz
python scripts/room_protocol_smoke.py \
  --base-url https://BACKEND_HOST \
  --origin https://FRONTEND_HOST \
  --production
```

`rooms.transport_ready` must be `true`. `rooms.sentence_acceptance_ready` must
also be `true` before claiming production sign-to-sentence output. If it is
false, room chat works and signed messages safely request repair.

### Frontend service

- Service root: `/frontend`
- Config file: `/frontend/railway.json`
- Build variable: `SIGNBRIDGE_API_BASE_URL=https://BACKEND_HOST`
- Generate an HTTPS public domain, then place that exact origin in the
  backend's `SIMPLYNEXT_ALLOWED_ORIGINS`.

Redeploy the backend after changing its origin allow-list, then redeploy the
frontend. The QR contains only the frontend join URL and public room code.

## Cloudflare quick-tunnel test

```bash
cd frontend
flutter build web --release \
  --dart-define=SIGNBRIDGE_API_BASE_URL=https://BACKEND_HOST
python3 -m http.server 8081 --directory build/web
cloudflared tunnel --url http://localhost:8081
```

Add the printed `https://*.trycloudflare.com` frontend origin to the backend's
exact `SIMPLYNEXT_ALLOWED_ORIGINS`, then restart or redeploy the backend. Create
the room from the tunnel URL so its QR points to the same public frontend.

## Two-device acceptance check

1. On the signing device, start a room and show the invitation QR.
2. On the hearing device, scan the QR, enter a name, and join.
3. Confirm both devices show each other online.
4. On the signer, choose front or back camera, open the camera, sign supported
   isolated words with a short pause between them, review the word buffer, and
   press **Send signs**.
5. Confirm both devices see processing and then an accepted sentence or clear
   repair. Confirm accepted signed text is spoken once on the hearing device.
6. On the hearing device, speak, review the transcript, send it, and confirm it
   appears on both devices.
7. Test typed messages, refresh/reconnect one tab, and verify the timeline
   recovers without duplicate TTS.
8. End from either device and confirm the other closes and old capabilities
   receive HTTP 410.

## Verification commands

```bash
python -m pytest -q
python -m ruff check .
python -m mypy src scripts
python scripts/export_word_contract.py --check

cd frontend
flutter analyze
flutter test
npm run test:web
flutter build web --release \
  --dart-define=SIGNBRIDGE_API_BASE_URL=https://BACKEND_HOST
```
