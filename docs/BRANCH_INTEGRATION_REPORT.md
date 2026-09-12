# Full integration branch report

## Result

`full_integration` combines the newest frontend/integration branch with the
newest production backend branch without mixing their source trees:

- `frontend/` contains the Flutter client.
- `backend/` contains the production Python/FastAPI backend.
- `backend/prototypes/frontend_branch_backend/` preserves the older
  experimental backend that arrived with the frontend history. It is not a
  production entry point.

## Branch audit

| Remote branch | Audited tip | Role | Integration decision |
| --- | --- | --- | --- |
| `origin/front_back` | `5fbb5c0` | Newest combined Flutter/integration line | Used as the frontend base |
| `origin/integration/gloss-lattice-only` | `ed07180` | Newest production GlossLattice backend | Merged into `full_integration` |
| `origin/backend` | `4477f72` | Earlier production-backend checkpoint | Already an ancestor of the selected backend branch |
| `origin/frontend_track` | `dc1cea5` | MediaPipe/web tracking | Already an ancestor of the selected frontend branch |
| `origin/frontend_state_norm` | `406cdfb` | Tracking state and normalisation | Its current service/contract work is present in the selected frontend line |
| `origin/frontend_full_integration` | `37fc407` | Earlier perception + GlossLattice integration | Superseded by the selected frontend line; key integration files match |
| `origin/frontend_gloss_lattice_adapter` | `445deb3` | Earlier frozen frontend adapter | Superseded by `frontend_full_integration` and the selected frontend line |
| `origin/frontend_segment_classify` | `ad79226` | Python heuristic/synthetic Stage 5/6 experiment | Preserved only as a prototype; not a trained Flutter classifier |
| `origin/frontend` | `ad79226` | Same remote tip as the Stage 5/6 experiment | Not selected as the current integrated Flutter base |
| `origin/front_back_contract` | `1088fae` | Older contract branch | Superseded by executable contracts and tests in the selected lines |
| `origin/frontend_speechtotext` | `48a8d67` | Earlier speech work | Current speech files are already present in the selected frontend line |
| `origin/docs` | `1482b02` | Backend documentation checkpoint | Already included in the selected backend ancestry |

## Contract check

The production boundary is `GlossLattice` v1:

- Frontend Dart schema: `frontend/lib/contracts/gloss_lattice.dart`
- Backend Python schema: `backend/src/simplynext/contracts/gloss_lattice.py`
- Frontend fixture: `frontend/test/fixtures/gloss_lattice_v1.json`
- Backend fixture: `backend/tests/fixtures/gloss_lattice_v1.json`

The frontend also contains an older/raw `LandmarkBatch` streaming route. That
route is not the protocol implemented by the selected production backend,
which deliberately rejects camera frames, landmarks, and feature tensors.
It must not be configured as though it were the GlossLattice endpoint.

## Remaining end-to-end blockers

The merge makes the two current codebases and their frozen transport contract
available in one branch, but it does not invent missing perception assets:

1. The repository has a browser classifier manifest but no distributable ONNX
   weights.
2. Android and iOS still select `DemoTrackingService`; Harold's real MediaPipe
   implementation in the selected branch is web-only.
3. `FrontendPipelineCoordinator` exposes a
   `SegmentationClassificationPort`, but the selected Flutter code does not
   contain a production calibrated Stage 5/6 implementation to supply final
   top-k probabilities.
4. The raw-landmark WebSocket route and production GlossLattice backend are
   different protocols. The production path must be
   segmentation/classification -> `GlossLattice` -> BPP WebSocket.

Until those items are supplied, passing unit/contract tests demonstrates
component compatibility; it does not prove a real camera video can complete
the entire phone-to-backend pipeline.
