# SignBridge conversation frontend

This Flutter frontend combines browser-local PopSign 250 recognition with a
two-person SimplyNext room.

- The signer creates a room and shares its QR or eight-character code.
- MediaPipe and the ONNX classifier remain in the browser.
- Pauses separate isolated signs; the signer explicitly sends the accumulated
  words as one `TranslatedSignUtterance v1` message.
- The hearing participant speaks or types a response.
- Both devices receive processing, accepted, repair, presence and end events
  from the backend WebSocket.
- Accepted signed messages can be read aloud on the hearing device.
- Front and rear cameras can be selected from the live preview.

The model covers the shipped PopSign 250 isolated-sign vocabulary. It does not
recognize arbitrary continuous ASL.

The release entry point disables the inherited GlossLattice and landmark
network transports. Camera data stays local; room requests contain finalized
English words plus confidence scores, or finalized typed/speech text.

## Run

```bash
flutter pub get
flutter run -d chrome --web-port 8081 \
  --dart-define=SIGNBRIDGE_API_BASE_URL=http://127.0.0.1:8000
```

Use HTTPS for camera and microphone access outside localhost. The backend must
allow this frontend's exact origin.

See [`docs/INTEGRATION_DEPLOY1.md`](../docs/INTEGRATION_DEPLOY1.md) for backend,
Railway, Cloudflare tunnel and two-device test instructions.
