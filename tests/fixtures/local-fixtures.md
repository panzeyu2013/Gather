# Local Face KW e2e fixtures

The `tests/e2e/face-workflow.spec.ts` end-to-end test needs two fixture types
that cannot be committed to the repository (size + third-party licensing +
portrait rights):

- ONNX models: `face_detector.onnx` (SCRFD, ~16 MB) and `face_encoder.onnx`
  (ArcFace, ~166 MB) from InsightFace.
- Real RAW photos that actually contain human faces (`.arw/.cr2/.cr3/.dng/
  .nef/.orf/.raf/.rw2`).

The git-ignored directory `tests/fixtures/local/` holds them locally:

```
tests/fixtures/local/
├── models/
│   ├── face_detector.onnx   # symlinked by the setup script
│   └── face_encoder.onnx
└── raw/                     # your RAW photos with faces
```

## Setup (local)

```bash
node scripts/setup-local-face-fixtures.mjs
```

This symlinks the ONNX models from the app's model directory
(`~/Library/Application Support/Gather/models/`, or `GATHER_MODELS_DIR`) into
`models/` and creates an empty `raw/`. Then drop 2+ RAW photos that contain
human faces into `raw/` — the test asserts real RAW previews decode and real
faces are detected/clustered (`detectionFailures === 0`, `clusters.length > 0`),
so synthetic images will not pass.

## Run

```bash
npm run test:e2e
```

The spec runs when the local fixtures exist and skips with a message otherwise.
To override the locations per run, set `GATHER_FACE_E2E_SOURCE_DIR`,
`GATHER_FACE_E2E_DETECTOR` and `GATHER_FACE_E2E_ENCODER`.

See `docs/TEST.md` section 4 for the corresponding manual Capture One
validation matrix.
