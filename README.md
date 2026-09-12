# SimplyNext full integration

This branch combines the latest reviewed frontend/integration line with the
latest production backend line while keeping their codebases separate.

## Repository layout

```text
frontend/                    Flutter camera and on-device perception client
backend/                     Production GlossLattice/FastAPI backend
  src/simplynext/            Installable backend Python package
  tests/                     Backend unit and protocol tests
  prototypes/                Older experiments; not production entry points
docs/                        Frontend/backend integration documentation
plan/                        Shared architecture and contract documentation
processing_contracts.schema.json
                             Shared processing schema reference
```

Do not import code from `backend/prototypes/` into the production backend.
Those files are retained only so earlier experiments and data are not lost.

## Frontend

```powershell
Set-Location frontend
flutter pub get
flutter analyze
flutter test
```

The tracked browser classifier manifest is present, but its generated ONNX
weights are intentionally not committed because redistribution permission is
unresolved. See `frontend/LOCAL_ASL_RECOGNITION.md` before attempting local
ASL inference. Android/iOS still use `DemoTrackingService`; real native
MediaPipe must be supplied before a phone build is an end-to-end camera test.

## Backend

Run backend commands from `backend/` so its standard `src/` package layout,
Docker build context, data paths, and tests resolve correctly:

```powershell
Set-Location backend
python -m pip install -e ".[dev]"
$env:SIMPLYNEXT_CAPTION_TEMPLATES_PATH = "data/caption_templates.example.json"
$env:SIMPLYNEXT_LATTICE_VOCABULARY_VERSION = "sgsl_demo_v1"
$env:SIMPLYNEXT_RECOGNITION_LANGUAGE = "asl"
python -m pytest
python main.py
```

The production backend accepts compact `GlossLattice` messages. It does not
accept camera frames, landmark arrays, or feature tensors.

## Integration boundary

The executable frontend wire contract is in
`frontend/lib/contracts/gloss_lattice.dart`. The executable backend contract
is in `backend/src/simplynext/contracts/`. Their shared golden fixture is
stored on both sides and must remain byte-for-byte identical:

- `frontend/test/fixtures/gloss_lattice_v1.json`
- `backend/tests/fixtures/gloss_lattice_v1.json`

The frontend includes the authenticated session/WebSocket client and a
`SegmentationClassificationPort` integration seam. A production build still
requires a real, calibrated Stage 5/6 implementation and its distributable
model asset before it can send truthful classifier probabilities.

## Branches integrated

- Frontend/integration base: `origin/front_back` at `5fbb5c0`
- Production backend: `origin/integration/gloss-lattice-only` at `ed07180`

Older stage branches were audited but not merged again because their current
tracking, normalisation, and GlossLattice files are already present in the
newer frontend integration line. The older Python segmentation prototype is
not a Flutter Stage 5/6 implementation and is not part of the production
backend protocol.
