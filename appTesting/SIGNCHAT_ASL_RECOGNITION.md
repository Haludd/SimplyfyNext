# Browser-local ASL recognition

The ASL word path now runs entirely in the browser:

```text
camera → MediaPipe Holistic landmarks → Signchat PopSign ONNX → glosses[]
```

The model and label map are served from `web/models/asl-signs/`. The first run
downloads and caches the approximately 21 MB ONNX model through the browser's
normal HTTP cache. Inference uses ONNX Runtime Web with WebGPU when the browser
supports the model and local WASM otherwise, so no camera frames, landmarks, or
recognition requests are sent to a SignBridge backend.

The classifier is sourced from the [Signchat repository](https://github.com/nlevites/signchat/tree/main/asl-classifier-model)
and uses the included PopSign/Kaggle 250-class ONNX export. It recognizes the
vocabulary represented by `sign_to_prediction_index_map.json`; it is not a
general sentence translator. Glosses are accumulated locally in Flutter and
the optional sentence submission endpoint remains disabled unless explicitly
configured.

## Run

From `appTesting/`:

```bash
flutter run -d chrome --web-port 8081
```

No `SIGNBRIDGE_UNISIGN_URL`, GPU service, Python model process, or backend is
required for ASL word recognition.

The model is released in the referenced repository; confirm its model/data
licence and the PopSign/Kaggle terms before commercial deployment.
