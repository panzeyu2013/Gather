# Core Reliability Baseline

Baseline branch: `codex/core-reliability-p0-0`

Baseline source commit: `1e214a8`

## Current verification

| Check | Result |
|---|---|
| `npm run typecheck` | Passed |
| `npm run lint` | Passed |
| `npm run test:vitest` | 32 files / 126 tests passed |
| `npm run build` | Passed |
| Database schema | Version 25 snapshot stored in `docs/fixtures/schema-v25.snapshot.json` |
| Production E2E | 10 passed / 1 optional RAW-ONNX fixture test skipped |
| `git diff --check` | Passed |

## P0-0 reference measurements

Measured on the fixed reference machine on 2026-07-30. Times are wall-clock
milliseconds; RSS is the peak of the Electron process tree.

| Metric | 500 | 5,000 | 10,000 |
|---|---:|---:|---:|
| Import duration | 125 ms | 2,158 ms | 7,193 ms |
| First app window | 494 ms | 474 ms | 454 ms |
| Gallery first interactive render | 106 ms | 232 ms | 408 ms |
| Reopen + unchanged index | 693 ms | 1,422 ms | 2,201 ms |
| Unchanged files skipped | 500 / 500 | 5,000 / 5,000 | 10,000 / 10,000 |
| 500-thumbnail throughput | 1,159/s | 1,166/s | 1,169/s |
| Rating → XMP written | 20 ms | 34 ms | 39 ms |
| Culling update p95 | 4 ms | 26 ms | 29 ms |
| Renderer long task maximum | none ≥50 ms | none ≥50 ms | none ≥50 ms |
| Failed / retried jobs | 0 / 0 | 0 / 0 | 0 / 0 |
| Peak RSS | 579 MiB | 995 MiB | 1,275 MiB |
| SQLite size | 2.18 MiB | 16.24 MiB | 31.97 MiB |
| Remaining process RSS after close | 0 | 0 | 0 |

Environment:

- Apple M5 Pro, 18 logical CPUs, 48 GiB RAM;
- internal Apple SSD AP2048Z (NVMe, TRIM enabled);
- macOS 26.5.2 (25F84), arm64;
- Node 22.22.3, Electron 42.4.1;
- ONNX and GPU providers disabled for this I/O and UI baseline.

The benchmark creates valid minimal JPEG files, launches the production Electron
renderer, executes real IPC/import/index/cache/XMP paths, closes and reopens the
application, and removes its isolated temporary workspace. Run it with
`npm run benchmark:application`.

## Synthetic SQLite reference

Measured again on 2026-07-30 on the same reference machine:

| Rows | Transaction import | Reopen + aggregate | SQLite size |
|---:|---:|---:|---:|
| 500 | 12.38 ms | 5.43 ms | 86,016 B |
| 5,000 | 26.29 ms | 5.81 ms | 684,032 B |
| 10,000 | 42.16 ms | 6.77 ms | 1,347,584 B |
| 100,000 | 356.94 ms | 12.19 ms | 14,098,432 B |

The reproducible synthetic SQLite indexing baseline can be generated with
`npm run benchmark:reliability`. It measures transactional inserts, indexed database
reopen/aggregate queries, coordinator RSS delta, and SQLite size at
500/5,000/10,000/100,000 rows. Application image decode, process-tree RSS and
renderer timings are reported separately above.
