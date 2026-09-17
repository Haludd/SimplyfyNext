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

If you serve `build/web` with a static server instead of `flutter run`, rebuild
after every pull. `build/web` is intentionally ignored by Git and can otherwise
contain an older compiled confidence gate:

```bash
flutter build web --release \
  --dart-define=SIGNBRIDGE_API_BASE_URL=http://127.0.0.1:8000
python3 -m http.server 8081 --directory build/web
```

The browser tracker keeps the last reliable nose and shoulder anchors for up
to 0.9 seconds and the locked face mesh for up to 0.85 seconds. Confidence
fades throughout either gap, and the inferred points expire rather than being
treated as permanent detections. This lets a hand cross a shoulder or cheek
without immediately removing the overlay. Camera pixels and Holistic frames
still remain in the browser. During those bounded gaps, the local classifier
receives the persisted face and pose anchors together with the live hand
points, improving continuity for contact signs without a network upload.

To verify the tracker locally, cover one shoulder briefly, perform a
hand-to-cheek sign such as `HOME`, and move slowly toward the camera. The face
and shoulder overlay should bridge a short occlusion and then recover to the
live points. A feature that remains fully outside the frame beyond the bounded
hold interval should disappear. Run the deterministic browser checks with:

```bash
npm run test:web
```

See [`docs/INTEGRATION_DEPLOY1.md`](../docs/INTEGRATION_DEPLOY1.md) for backend,
Railway, Cloudflare tunnel and two-device test instructions.
