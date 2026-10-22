<div align="center">

# Gather

**A local-first native photo culling and catalog companion for Capture One.**

Gather turns folders and Capture One selections into focused workspaces for
browsing, culling, similarity review, face keywording, and reliable metadata
writeback.

[简体中文](docs/README.md) · [Features](#core-workflows) · [Quick start](#quick-start)

[![CI](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml/badge.svg)](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-252525?logo=apple)
[![MIT License](https://img.shields.io/badge/license-MIT-c56a42.svg)](LICENSE)

</div>

> [!IMPORTANT]
> Gather is a macOS Swift/SwiftUI application. The current source-build
> workflow produces an unsigned `.app`; signing, notarization, installation
> and commercial-signal validation are separate release activities.

## Why Gather?

Capture One remains the source of truth for developing photos. Gather focuses
on high-volume decisions: finding related frames, comparing near-duplicates,
applying ratings and labels, assigning people keywords, and moving those
decisions back through metadata.

- **Local-first:** photos, indexes, models, and metadata processing stay on the
  computer; the app does not run a local web service.
- **Native workflow:** SwiftUI pages call 16 typed domain APIs (110 methods)
  in-process across eight SwiftPM targets; there is no Electron, browser
  renderer, JavaScript IPC runtime, or string-command router.
- **Recoverable writeback:** metadata changes are persisted in the `deliveries`
  queue and processed with conflict detection and restart recovery.
- **RAW/JPEG aware:** variants can be folded into one logical photo while
  uncertain pairs remain available for review.

## Core workflows

| Workflow | What it provides |
| --- | --- |
| **Dashboard and Library** | Workspaces, cross-workspace browsing, filters, logical RAW/JPEG assets, and paginated galleries. |
| **Culling** | Pick/reject, ratings, color labels, comparison, undo/redo, metadata sync, retry, and cleanup. |
| **Similarity and duplicates** | dHash clustering, threshold review, exact/visual duplicate groups, and safe resolution. |
| **People and face keywords** | Native Vision analysis orchestration, cluster review, person binding, and XMP keyword writeback. |
| **Export and jobs** | Preview, variant-aware output, JPEG/TIFF conversion, XMP copy, resumable jobs, cancellation, and reports. |

## Quick start

### Requirements

- macOS 14 or later
- Xcode command-line tools or Xcode with Swift 6.0+ support
- Capture One is optional for folder-only workflows
- Face analysis requires the system Vision framework; real-dataset quality
  validation is an external acceptance activity

### Run tests

```bash
cd desktop/native/gather-core
swift test

cd ../gather-app
# App tests share process-wide MainActor/language state; run them serially
# (the same flag CI uses) to keep lifecycle assertions deterministic.
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --no-parallel
```

### Build a macOS application bundle

```bash
./desktop/native/build.sh
```

The bundle is assembled at `release/Gather.app`. Set
`CONFIGURATION=release` for a release build. The script does not require a
JavaScript toolchain and leaves signing disabled unless `CODESIGN_IDENTITY`
is explicitly provided. When signing, it applies hardened runtime plus
`desktop/native/Gather.entitlements` (Apple Events for the Capture One bridge)
and re-reads the signed entitlements. Assembly also asserts the bundled
`FaceModels/SFace.mlpackage` + `manifest.json` and non-empty
`Localizable.strings` for both localizations before declaring success.

## Data and security model

```text
SwiftUI (GatherUI)
  ↓ AppServices：16 个域协议 / 110 个类型化方法（同进程直连）
GatherHost（AppComposition 组合根 / AppRuntime / Live*API）
  ↓
GatherApplication（服务编排、JobService）
  ├─ GatherDelivery：DeliveryCoordinator（XMP 写回：重试 / 冲突 / 重启恢复）
  ├─ GatherPersistence：SQLite WAL + SchemaV1（43 表 / 373 列 / user_version=2）
  └─ GatherAnalysis：dHash/LSH 聚类、Vision 人脸、RAW/ImageIO 解码
```

The eight targets are `GatherProtocol` (values, API, error codes),
`GatherPersistence` (SchemaV1, Database, repositories), `GatherDelivery`
(delivery engine), `GatherAnalysis`, `GatherApplication` (services),
`GatherUI`, `GatherHost`, and `GatherApp`. `AppComposition` is
the single composition root; `AppRuntime` owns job lifecycle. There is no
118-command router; `Database.open(at:)` opens the current schema (V2),
migrating a well-formed V1 database with a no-op transaction.

Destructive operations use the compile-time `Confirmed<T>` marker plus real UI
confirmation, photo paths are resolved from database-owned assets, and
writeback is persisted in `deliveries` with retries, conflict handling, and
restart recovery.

See [Architecture Decisions](docs/ADR.md), [Development guide](docs/DEVELOPMENT.md)
(tests and gates), and [Roadmap](docs/ROADMAP.md).

## Documentation

- [Development and contributing guide](docs/DEVELOPMENT.md)
- [Roadmap](docs/ROADMAP.md)
- [Architecture decisions](docs/ADR.md)
- [简体中文文档](docs/README.md)
- [Historical archive](docs/archive/README.md)

## Contributing

Issues and pull requests are welcome. Before submitting a change, run the
native core and app test suites and the bundle build when the changed area
touches packaging or app startup.

## License

Gather is available under the [MIT License](LICENSE).
