# Two-device SignBridge conversations

Implemented on `feature/two-way-conversation`, based on `origin/full_integration` at `d2bf3f7`.
This is a browser companion with a launch card in the existing Flutter app. It uses words and
confidence JSON; it does not call the old GlossLattice, landmark, or recognition-session routes.

## What works now

- Start a two-person room; join by QR link or six-character code without an account/install.
- Both screens receive the same ordered typed, spoken, and accepted sign-input messages.
- Speech creates an editable draft; Send commits it. Typing works when speech is unavailable.
- Incoming signed messages can be read aloud, with manual replay and opt-in automatic playback.
- Camera preview stays local. Upload/paste words JSON, try clearly labelled samples, or attach a
  classifier using the JavaScript function/event described below.
- A low confidence word causes a repeat prompt. No uncertain sentence is displayed or spoken.
- Refresh/reconnect restores the room in the same tab. Stable message IDs deduplicate retries.
- Pending submissions are retained in that tab; Retry resends the same ID and content.
- Ending a room closes it for both people. Invitations expire after 10 minutes; rooms after
  2 hours. Rooms are limited to 300 messages and the process to 100 rooms.

Demo mode is the default. It joins supplied words literally with spaces and labels the message
“Demo word preview · no sentence translation”. Camera preview does not perform recognition.
The literal words/confidence inputs are real JSON submissions even when translation is simulated.

## Start the service

Use Python 3.11–3.13. From the repository root, Linux/macOS:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e 'backend[conversation]'
python -m uvicorn simplynext.conversation.app:app --host 0.0.0.0 --port 8000 --workers 1 --ws-max-size 2048 --no-access-log
```

Windows PowerShell, from the repository root:

```powershell
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install -e "backend[conversation]"
.venv\Scripts\python -m uvicorn simplynext.conversation.app:app --host 0.0.0.0 --port 8000 --workers 1 --ws-max-size 2048 --no-access-log
```

Existing virtual environments can be reused; skip their creation. No AI credentials, classifier
weights, Node install, or Flutter build is needed to run this UI. Dependencies declared by the
backend package are installed, but its old AI service is not started.

Open **http://localhost:8000/conversation**. `/healthz` reports `translation_mode` (`demo` or `http`).
The old `python backend/main.py` entry point starts the earlier service, not this conversation UI.

### First test: two tabs

1. Tab A: enter a name, select Signing, and start a conversation.
2. Open the invitation link in an independent tab (or use the code on `/conversation`). Enter a
   second name and join. If your browser duplicates tab storage, use a private window instead.
3. Type from either side. Both screens should show each message once, with opposite alignment.
4. On A, expand **Test signing input**, then try HELLO and an unclear sign. B receives the literal
   demo HELLO; the unclear sign asks A to repeat while B sees “Clarifying a sign”.
5. Upload `frontend/conversation-fixtures/words.json`. Uploading the same message ID again must
   not duplicate it. A different utterance needs a new UUID; the sample button generates one.
6. On B, select Speak, start/stop the microphone, review the draft, and Send. Test Read aloud and
   the incoming-sign playback checkbox. These depend on browser/OS speech support.
7. Refresh B: existing messages return without automatic speech replay. Disconnect/reconnect B
   and send from A: missed messages return. If an outgoing request failed, use its Retry button.
8. End from either side. Both screens close the room and future joins fail.

### Two phones

Both devices need to reach the same server. Start/create the room from the shared server address,
not `localhost`: a QR pointing to `localhost` would point to the scanning phone itself.

For a same-Wi-Fi **text/JSON** demonstration, open `http://<computer-LAN-IP>:8000/conversation`
on both phones. The server must bind `0.0.0.0`, and the machine's firewall must allow that port.
If running under WSL, Windows/WSL networking can require forwarding; running the service directly
in Windows or using an HTTPS reverse proxy to the WSL service avoids assuming WSL's address is
reachable from the phone.

For **camera/microphone** testing, put the service behind an HTTPS reverse proxy or your existing
HTTPS development host. Forward `/conversation`, `/conversation-assets/*`, `/api/*` (including
WebSocket upgrades), and `/healthz` to this same service. Generate the QR from that HTTPS URL.
Trust forwarded proxy headers only from the actual proxy. Keep exactly one worker/replica.

Browser media capture needs a secure context (HTTPS, except localhost).
[MDN media access](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia).
Speech recognition support varies and may send audio to the browser provider's online service;
SignBridge's room API receives only the final text.
[MDN speech recognition](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition).
Physical phone permissions, audio quality, and QR camera scanning still need manual acceptance.

### Open from the Flutter app

The live translator screen includes **Two-device conversation**. Enter the room service URL in
its launch dialog, or provide it when starting Flutter:

```bash
cd frontend
flutter run -d chrome --dart-define=CONVERSATION_URL=https://your-shared-host/conversation
```

The web build opens the companion in a new browser tab. Native builds provide a copyable browser
link. The new chat screen is not embedded as native Flutter widgets. Its camera/classifier state
is independent of the older Flutter live screen; launching it does not automatically attach the
older camera model. The JSON integration below is the new handoff.

## Frontend/classifier handoff

One completed signing utterance is represented by ordered words with numeric confidence in [0,1]:

```json
{
  "message_id": "5dfe3a9b-d360-4167-9ea3-0d9b6c87127b",
  "words": [
    {"word": "HELLO", "confidence": 0.96},
    {"word": "HELP", "confidence": 0.91}
  ]
}
```

The HTTP contract requires `message_id` (UUID) and 1–64 words. Each word has at most 80 characters.
Unknown fields, string/boolean/nonfinite scores, landmarks, frames, and extra model arrays are
rejected. The total HTTP body is limited to 16 KiB. Confidence 0.75 is currently a provisional
application threshold, not a claim that your classifier's probabilities are calibrated.

The UI accepts this shape as an uploaded `.json` file or pasted JSON. You may omit `message_id`
in the UI; it generates one before sending. Reuse that ID only for retries of the same utterance.
Changed content with an existing ID returns HTTP 409. A repeat/correction is a new message/UUID.

In the conversation page, connect your classifier at the point where an utterance is complete:

```javascript
const messageId = window.signBridgeConversation.submitWords({
  words: [
    {word: "HELLO", confidence: 0.96},
    {word: "HELP", confidence: 0.91}
  ]
});
```

This synchronously validates/enqueues and returns the message ID, not an acknowledgement or
translation promise. Delivery/result state appears in the conversation UI. The equivalent event:

```javascript
window.dispatchEvent(new CustomEvent("signbridge:words", {
  detail: {message_id: crypto.randomUUID(), words: [{word: "HELLO", confidence: 0.96}]}
}));
```

These hooks apply to scripts in this page. A classifier in a different application should use
HTTP with its own participant credentials, or be bundled into the companion page. Do not send
credentials using cross-origin messages or invitation URLs. An individual-word model needs a
frontend utterance buffer and explicit commit/pause rule; send once per intended chat message.

### HTTP room API for another frontend

| Endpoint | Request / behavior |
| --- | --- |
| `POST /api/rooms` | `{ "name": "Alex", "mode": "sign" }` creates a room |
| `POST /api/rooms/join` | `{ "code": "ABC234", "name": "Sam", "mode": "speech" }` joins |
| `GET /api/rooms/{code}` | Authenticated full snapshot for recovery |
| `POST /api/rooms/{code}/messages` | `{ "message_id": "<UUID>", "text": "Hello", "source": "text" }`; source may be `speech` |
| `POST /api/rooms/{code}/words` | The words JSON above |
| `WS /api/rooms/{code}/events` | Authenticated room snapshots and lifecycle events |
| `DELETE /api/rooms/{code}` | Either participant ends the room for both |

Create/join returns `{code, participant_id, token}`. Use `Authorization: Bearer <token>` for HTTP.
Do not use the legacy translation session token. A participant can send either text or words;
`mode` selects the initial UI input, not a hearing-status restriction.

A browser WebSocket authenticates with its **first message**, not a URL credential:

```json
{"type":"authenticate","token":"<the participant token>"}
```

Then send `{"type":"ping"}` at least every 30 seconds. Optional activity:
`{"type":"activity","state":"typing"}` (`idle`, `listening`, `signing` also supported).
Snapshots carry increasing `version`, ordered messages (`sequence`), participants, presence, and
expiry. Ignore older versions. Render message identity as `(sender_id, id)`. A message transitions
from `processing` to `accepted` or `repair`; the room snapshot replaces that message, not its ID.
The terminal `{"type":"ended"}` event closes the room. Text payloads never go through translation.

The packaged page is same-origin by default. If a separately hosted frontend calls the service,
set `CONVERSATION_ALLOWED_ORIGINS=https://your-frontend.example` (comma-separated exact origins).
This applies to HTTP CORS and WebSocket origin validation. Origins are not participant credentials.

## Backend teammate: attach words-to-sentence translation

Set a server-side URL, then start/restart the room service:

```bash
export CONVERSATION_TRANSLATOR_URL=http://127.0.0.1:9000/translate
# Optional if the endpoint needs authentication; keep it in environment configuration:
# export CONVERSATION_TRANSLATOR_TOKEN=...
```

PowerShell uses `$env:CONVERSATION_TRANSLATOR_URL = "http://127.0.0.1:9000/translate"`.
The adapter POSTs the same `message_id` and `words`, plus trusted room context:

```json
{
  "message_id": "5dfe3a9b-d360-4167-9ea3-0d9b6c87127b",
  "words": [{"word":"HELLO","confidence":0.96}],
  "context": [
    {"message_id":"<prior UUID>","sender_id":"<participant UUID>","source":"speech","text":"How can I help?"}
  ]
}
```

Reply with exactly one outcome:

```json
{"status":"accepted","text":"Hello!"}
```

or:

```json
{"status":"repair","prompt":"Please repeat the last sign."}
```

An accepted result requires text; a repair requires a prompt and prohibits text. Responses over
16 KiB, invalid JSON/schema, timeouts, and HTTP failures become a generic repair prompt, without
exposing backend details. Input below the confidence threshold is repaired before calling the
translator. The adapter does not implement your teammate's assembler or critic.

Context contains the latest 30 **accepted** messages from both people, excluding partial speech,
processing states, repair prompts, and the current submission. Full chat history stays in the room
up to its 300-message limit. There is no automatic AI summarisation yet. Previous conversation
text is reference data for your assembler/critic, not instructions or evidence for missing signs.
This separates chat-history lifetime from the bounded context sent to a stateless translation API.

If your teammate's existing API uses different JSON keys, adapt only
`backend/src/simplynext/conversation/translation.py`, keeping the room/UI contract stable.
An in-process translator can instead implement `Translator` and be injected into `create_app`.

## Tests and code map

Backend regression checks, from the root:

```bash
python -m pip install -e 'backend[dev,conversation]'
python -m pytest backend/tests/test_conversation.py -q
cd backend
python -m pytest -q
python -m ruff check src scripts tests/test_conversation.py
python -m mypy src scripts
python -m pip check
```

Browser tests, with the conversation server already running on port 8000:

```bash
cd frontend/conversation-tests
npm install
npx playwright install chromium
npm test
```

Linux may also need Playwright's documented browser system dependencies (`npx playwright install-deps chromium`).
Override the test origin with `CONVERSATION_TEST_URL` if needed. Tests use separate browser contexts,
check the actual QR using an independent decoder, check mobile overflow, refresh/reconnect, JSON
upload, repair, and idempotency. Speech/TTS tests use deterministic browser doubles; they do not
prove a real phone microphone or voice works. Test screenshots go into `test-results/`.

| Path | Responsibility |
| --- | --- |
| `backend/src/simplynext/conversation/contracts.py` | Words and room input/output contracts |
| `backend/src/simplynext/conversation/store.py` | Room credentials, expiry, participants, snapshots |
| `backend/src/simplynext/conversation/app.py` | HTTP/WS routes, ordering, retries, confidence gate |
| `backend/src/simplynext/conversation/translation.py` | Demo and real HTTP translation adapters |
| `backend/src/simplynext/conversation/web/` | Packaged responsive UI and vendored QR library |
| `backend/tests/test_conversation.py` | Room/translation protocol tests |
| `frontend/conversation-tests/` | Browser interaction tests |
| `frontend/lib/ui/conversation_launch.dart` | Existing Flutter screen's companion launch card |
| `frontend/conversation-fixtures/` | Ready-to-upload classifier JSON examples |

## Boundaries and remaining work

This is an ephemeral, one-worker MVP. Room credentials and pending sends live in that browser tab's
sessionStorage for refresh recovery; the server hashes credentials in memory. Ending/expiry clears
server room history, and the UI clears the tab's room state on receiving the end event. Closing all
server processes loses rooms; they are not backed by a database. Messages are transport-encrypted
when hosted on HTTPS; this is not end-to-end encryption.

Still to integrate/validate: the real classifier in the companion page, calibrated confidence and
utterance boundaries, your actual words-to-sentence backend, real mobile microphone/TTS/camera
behavior, native Flutter chat embedding if desired, durable multi-worker storage, and context
summarisation. No deployment or physical-device test is implied by local/browser automation.

## Verification on this branch

Local verification on 2026-09-13: 185 backend tests passed (including 20 new room/adapter checks),
3 Chromium browser scenarios passed, Ruff on `src`, `scripts`, and the new tests passed,
strict mypy passed, and `pip check` passed. A broader `ruff check .` reports 13 pre-existing
issues in the unchanged `backend/prototypes/` files.
A wheel was built and installed into an isolated environment; package import and bundled UI
resources were verified outside the checkout. Desktop and 390px-wide screenshots were inspected.
Flutter SDK tools are not installed in this environment, so the Flutter launch card was not built
or analyzed here. Run `flutter analyze` and `flutter test` in `frontend/` on your Flutter machine.
