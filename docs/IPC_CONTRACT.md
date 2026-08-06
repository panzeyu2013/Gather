# Gather IPC Contract Baseline

This document freezes the public renderer/main-process boundary for the P0 reliability work.
The TypeScript definitions in `packages/shared/src/protocol/` remain the source of truth;
this inventory records the compatibility rules that later migrations must preserve.

## Transport

- Renderer commands use `gather:command` through the preload bridge.
- The renderer may only invoke commands listed in `desktop/src/preload/index.ts`.
- Destructive commands require `{ confirmed: true }` at the preload boundary.
- Renderer code never supplies an arbitrary XMP path to a writer; the main process resolves
  the target file and sidecar.
- Progress and status are emitted as `gather:event` events.

## Command groups

| Group | Commands | Cancellation/status |
|---|---|---|
| Session/photo | `session.*`, `photo.list` | Session status is persisted; import errors are returned per file where supported |
| Culling | `culling.*`（分页入口 `culling.list_page`，`culling.list` 保留兼容） | Per-session sync status; analysis and writeback failures remain retryable |
| Similarity | `sim.analyze`, `sim.cancel_analysis`, `sim.result`, `sim.recluster`, `sim.preview_writeback`, `sim.writeback` | Per-session cancellation and progress |
| Face/person | `fkw.*`, `person.*` | Face analysis cancellation; person mutations require confirmation where destructive |
| Metadata | `metadata.get`, `metadata.set`, `metadata.batch_set`, `metadata.conflicts`, `metadata.resolve_conflict`, `metadata.orphans`, `metadata.resolve_orphan` | Mutations and recovery choices require confirmation; unknown XMP fields are preserved |
| Assets/index | `assets.*`, `index.scan` | Relinking requires confirmation; scans are persistent jobs and missing files are retained |
| Jobs | `jobs.list`, `jobs.cancel`, `jobs.retry`, `jobs.clear_completed` | Status, lease, progress and retry state are persisted |
| Quality/navigation | `quality.*`, `navigation.*` | AI output is advisory; group split/merge is a navigation override only |
| Duplicate/filter/album | `dup.*`, `filter.*`, `album.*` | Duplicate resolution is destructive; global queries are database-paginated |
| Export/template | `export.*`, `template.*` | Export supports cancellation; execute/apply/delete require confirmation |
| Image/settings | `image.*`, `settings.*` | Image work is best-effort and must not crash the main process |

## Compatibility rules

1. Do not rename a command, event, status, or enum without a migration and an updated
   shared-protocol test.
2. Additive command parameters must remain backwards-compatible with existing renderers.
3. Long-running commands must persist enough state for the UI to distinguish running,
   failed, cancelled, and completed work.
4. AI output is advisory and must not mutate Pick/Reject/Rating/Label without an explicit
   user command.
5. Metadata mutations are patches, not complete XMP documents. The writer owns path
   resolution, baseline comparison, merge, backup, and recovery.

## Pagination contract (added with `culling.list_page`)

- Pages are grouped by **logical asset** (`COALESCE(asset_id, id)`); an asset (e.g. a
  RAW+JPEG pair) never spans two pages, and each asset appears exactly once across pages.
- `afterRowId`/`nextRowId` is an **opaque keyset cursor** (the first `rowid` of the last
  asset group). The renderer must round-trip it verbatim and never interpret it.
- `total` counts logical assets, not physical photo rows.
- Filters are pushed down and evaluated on the asset's **preferred variant** (RAW
  extension first, otherwise the lowest `rowid`); `culling.list` keeps the legacy
  row-level behavior for compatibility.

## Similarity result tiers (added with `sim.result`/`sim.preview_writeback`/`sim.writeback`)

- `sim.result`, `sim.preview_writeback`, and `sim.writeback` accept an **optional
  `threshold`** parameter. Without it they resolve the latest non-precomputed result
  (the "main" row); with it they resolve that threshold's precomputed tier.
- Precomputed tier rows are persisted in `similarity_results` and marked
  `"precomputed": true` in `stats_json`. Every consumer that picks "the latest result"
  (`getLatest`, the culling similarity-group SQL predicate, quality relative ranks)
  MUST exclude rows carrying that marker — this invariant is covered by
  `tests/unit/services/similarity/reuse-and-tiers.test.ts`.

## Background jobs (added to `jobs.*`)

- `checksum.backfill` (scope: session, auto-resumed): fills `photos.checksum` +
  `asset_files.checksum` left empty by lazy indexing (`lazy_checksum` setting). Job
  creation is deduped per session (`dedupeKey: checksum.backfill:<sessionId>`).
