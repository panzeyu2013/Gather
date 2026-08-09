<div align="center">

# Gather

**A local-first photo culling and catalog companion for Capture One.**

Turn folders and Capture One selections into focused workspaces for browsing,
culling, similarity review, face keywording, and reliable metadata writeback.

[简体中文](docs/README_CN.md) · [Features](#core-workflows) · [Quick start](#quick-start) · [Contributing](#contributing)

[![CI](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml/badge.svg)](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-252525?logo=apple)
![Node.js 22+](https://img.shields.io/badge/Node.js-22%2B-3c873a?logo=nodedotjs&logoColor=white)
[![MIT License](https://img.shields.io/badge/license-MIT-c56a42.svg)](LICENSE)

</div>

> [!IMPORTANT]
> Gather is under active development. macOS is the primary, tested desktop
> target. A Windows package configuration exists, but the Windows workflow is
> not yet release-validated. The recommended installation path today is a
> local source build.

## Why Gather?

Capture One remains the source of truth for developing photos. Gather focuses
on the high-volume decisions around it: finding related frames, comparing
near-duplicates, applying ratings and labels, assigning people keywords, and
moving those decisions back through metadata.

- **Local-first:** photos, indexes, models, and metadata processing stay on the
  computer; the app does not run an HTTP service.
- **Built for real shoots:** RAW/JPEG variants can be folded into one logical
  photo, while uncertain pairs remain available for manual review.
- **Keyboard-friendly:** pick, reject, rate, navigate, compare, undo, and redo
  without leaving the culling workbench.
- **Recoverable writeback:** metadata changes are persisted and processed by a
  retryable queue with conflict detection and restart recovery.

## Core workflows

| Workflow | What it provides |
| --- | --- |
| **Library** | Cross-workspace search, composable filters, smart albums, logical RAW/JPEG assets, offline-volume relinking, and duplicate candidates. |
| **Culling** | Pick/reject, 0–5 stars, Capture One color labels, auto advance, single/dual/quad comparison, synchronized zoom, batch actions, and undo/redo. |
| **Similarity** | dHash perceptual hashing and hierarchical clustering with adjustable thresholds and per-group keyword writeback. |
| **People** | Local ONNX face detection and encoding, DBSCAN clustering, cluster review/merge/skip, person binding, and XMP keyword writeback. |
| **Export & jobs** | Export presets, variant-aware output, background progress, cancellation, diagnostics, and retryable work. |
| **Capture One** | Import the current selection through AppleScript and return ratings, labels, or keywords through metadata; an optional native plug-in can provide a “Send to Gather” action. |

## Quick start

### Requirements

- macOS 13 or later
- Node.js 22 or later and npm
- Capture One is optional for folder-only workflows and required for direct
  selection import/synchronization
- Face analysis requires compatible SCRFD and ArcFace ONNX models configured
  locally; model binaries are intentionally not committed to this repository

### Run from source

```bash
git clone https://github.com/panzeyu2013/Gather.git
cd Gather
npm install
npm run electron
```

`npm run electron` builds the shared contracts and desktop application, then
launches the production renderer locally.

### Build a macOS package

```bash
npm run dist:mac --workspace=desktop
```

The DMG is written to `desktop/release/`. Distribution builds still require
the packager's own Apple signing and notarization credentials. Published
artifacts, when available, are listed on the
[Releases](https://github.com/panzeyu2013/Gather/releases) page.

## First workflow

1. Create a workspace from a local folder or the current Capture One selection.
2. Open **Culling** and use `P` to pick, `X` to reject, `0`–`5` to rate,
   arrow keys to navigate, and `Cmd/Ctrl+Z` to undo.
3. Use dual or quad comparison for burst sequences. Face alignment reuses
   existing detections and does not start another model run.
4. Review failed or conflicting metadata items, then flush pending changes.
5. In Capture One, run **Image → Load Metadata** (or use one-way Auto Sync =
   Load). Confirm the sync in Gather only after Capture One has loaded it.

Similarity analysis is optional: the culling workflow works on every indexed
photo without requiring a similarity pass first.

## Data and security model

```text
Renderer (React) → typed gather:command IPC → Electron main process
                                             ├─ SQLite (WAL + migrations)
                                             ├─ image / ONNX workers
                                             └─ XMP and embedded metadata writers
```

- `contextIsolation: true`, `sandbox: true`, and `nodeIntegration: false`
- A typed preload bridge exposes the minimum renderer API
- No local web server or listening application port
- Metadata outbox records support retries, conflict handling, and recovery
- RAW/JPEG linking is conservative and manually reversible

See [Architecture Decisions](docs/ADR.md) and the
[IPC Contract](docs/IPC_CONTRACT.md) for the detailed invariants.

## Development

```bash
npm run dev          # Vite + Electron development mode
npm run typecheck    # TypeScript checks for main, renderer, and shared code
npm run lint         # ESLint
npm run test:vitest  # Unit tests
npm run build        # Production build
npm run test:e2e     # Production-build Electron smoke workflows
```

The face workflow E2E suite needs local ONNX models and at least two RAW photos
containing faces. Those fixtures are git-ignored; the test is skipped when they
are unavailable. See [Local test fixtures](tests/fixtures/local-fixtures.md).

## Documentation

- [Development and contributing guide](docs/DEVELOPMENT.md)
- [Testing guide](docs/TEST.md)
- [Roadmap](docs/ROADMAP.md)
- [Architecture decisions](docs/ADR.md)
- [IPC contract](docs/IPC_CONTRACT.md)
- [Native development analysis](docs/NATIVE-DEVELOPMENT-ANALYSIS.md)

## Contributing

Issues and pull requests are welcome. Before submitting a change, read the
[development and contributing guide](docs/DEVELOPMENT.md) and run the checks
that match the changed area. UI changes should include before/after screenshots.

## License

Gather is available under the [MIT License](LICENSE).
