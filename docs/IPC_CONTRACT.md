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
| Culling | `culling.*`（分页入口 `culling.list_page`） | Per-session sync status; analysis and writeback failures remain retryable |
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
  extension first, otherwise the lowest `rowid`).

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

## Directory scanning (`app:scan-directory` returns `ScanResult`)

- The preload bridge `window.gather.scanDirectory(dirPath)` returns
  `ScanResult { files, truncated, scannedTotal, limit }` instead of a bare path
  array. The shape lives in `packages/shared/src/protocol/core.ts` as `ScanResult`.
- `files` is bounded by `MAX_SCANNED_FILES = 50_000` — an IPC/memory bound, not a
  product limit. `scannedTotal` keeps counting photo files past the bound and
  `truncated = scannedTotal > files.length` reports the cut explicitly so the
  renderer can surface "background index will fill in the rest".
- There is deliberately **no configurable limit setting** (P2 idea removed from
  the design); callers read `limit`/`scannedTotal` from the result.

## Session truncation marker (`session.create` + `sessions.truncated_import`)

- `session.create` accepts an optional, additive `truncatedImport` boolean; the
  renderer sets it from `ScanResult.truncated`. Omitted/false keeps existing
  behavior, so old renderers remain compatible.
- The main process persists it as `sessions.truncated_import` (migration v29,
  `INTEGER NOT NULL DEFAULT 0`) and exposes it on `SessionData.truncatedImport`.
  It is a UI hint only — remaining photos are expected to be filled in by a
  background `index.scan` job; it is cleared/resolved by P1 workspace status.

## Analysis staleness foundation (`sessions.index_seq` + `analysis_runs`)

- `sessions.index_seq` (migration v30, `INTEGER NOT NULL DEFAULT 0`) is a
  monotonically increasing cursor: `IndexService.scanSession` bumps it in the
  same transaction as the final photo-count write, and only when the scan
  committed real changes (added photos, content-changed or relinked photos,
  newly missing photos). A no-op scan does not bump it, so analyses are not
  marked stale by scans that changed nothing.
- Analysis services write one `analysis_runs` row per run at entry
  (`status 'running'`, `kind 'similarity' | 'face'`, `photo_count`,
  the `index_seq` snapshot read at start, and a JSON `params` snapshot) and
  finalize it to `'ok'`/`'failed'` on exit. `session_id` is a TEXT foreign key
  (`REFERENCES sessions(id) ON DELETE CASCADE`).
- Staleness is `last_ok_run.index_seq < session.index_seq`; the
  `WorkspaceStatusService` read model consumes these rows. No IPC surface
  changes here — this is internal persistence for the future workspace status.

## Workspace status (`workspace.status`, P0-3 问题一)

- New read-only command `workspace.status` with params `{ sessionId: string }`
  (type `WorkspaceStatusParams` in `packages/shared/src/protocol/workspace.ts`).
  It returns the full `WorkspaceStatus` aggregate — a main-process **pure read
  model** (design_improvements.md 1.4.1–1.4.5); the only allowed write is an
  in-memory TTL cache. Unknown sessions return `err('SESSION_NOT_FOUND')`.
- Shape (type `WorkspaceStatus`, exported from `@gather/shared`):
  `sessionId`, `stage`, `softFlags`, `indexing`, `staleAnalyses`, `xmp`,
  `offlinePhotos`, `failedJobs`, `recommendedNext`, `generatedAt`.
- **Stage semantics** (three hard stages, additive leading stage `created`):
  - `created`: session row exists but `photos` is empty (one-hop import window).
  - `imported`: `photos` count > 0.
  - `indexed`: the latest `metadata.scan` job for the session has
    `status='succeeded'` and no active (queued/running/cancelling) scan work
    exists after it — judged on the `analysis_jobs` table (dedupe key
    `metadata.scan:<sessionId>`; a later active row is always the "latest").
  - `analyzed`: a `kind='similarity'` `status='ok'` `analysis_runs` row exists
    and is **not stale** (`run.index_seq >= sessions.index_seq`, 1.4.2).
- **Soft flags**: `culled` = a written-back culling decision exists
  (`writeback_items` `module='culling'` **or** `metadata_outbox`
  `source_module='culling'` in `written`/`synced`; both statuses count because
  cleanup deletes `synced` rows). `exported` = a `type='export.execute'` job
  with `status='succeeded'` exists.
- **`staleAnalyses`**: one entry per kind (`similarity`/`face`) whose latest
  `ok` run is stale, with its `finished_at` as `lastRunAt`.
- **`xmp`**: reused from `MetadataSyncCoordinator.getSummary(sessionId)`;
  `pending` folds `pending + failed` rows in (1.4.3 defines the xmp_pending
  action over pending/failed rows), `conflict` is the conflict count.
- **`offlinePhotos` TTL contract (1.4.5)**: `COUNT(photos WHERE status='missing')`
  is expensive and lazy-detected. The service caches it per session in an
  in-memory map for **≥ 5 minutes** (`OFFLINE_PHOTOS_TTL_MS` in
  `desktop/src/main/services/workspace/workspace-status.service.ts`); a poll
  inside the TTL returns the cached value without touching the database.
- **`recommendedNext`**: fixed priority list + boolean gates (no rule engine):
  1. `scan_incomplete` (index never succeeded or in progress) → `index`
  2. `xmp.conflict > 0` → `metadata`
  3. `staleAnalyses` non-empty → `similarity`
  4. `failedJobs` non-empty → `jobs`
  5. otherwise the next unsatisfied soft flag: `culling` → `export`
  `null` once everything is satisfied. The C1-connection boolean gate is
  deliberately not wired (no recommendation here is a write-back/cleanup
  action, and it would couple this service to the C1 workstream).
- **Push refresh**: no new event type. The renderer hook
  (`useWorkspaceStatus`) polls every 30s (3s while a `metadata.scan` job is
  active) and is invalidated by existing events — `jobs:progress` terminal
  frames (index/analysis/export completion) and `culling:sync-status`
  (XMP row transitions).


## One-hop import (`session.create_from_directory`, P2 问题三根因修复)

- New command `session.create_from_directory` with params
  `{ name?: string; sourcePath: string }` (type
  `SessionCreateFromDirectoryParams` in `packages/shared/src/protocol/session.ts`).
- **One-hop guarantee**: the payload carries a single directory path — **no
  file-path array ever crosses IPC** on the local-directory import path. The
  main process validates the path (must be a real non-root directory, mirroring
  `sanitizeSessionSourcePath`), creates the session row with
  `import_source='local'` and `source_path` set, then immediately enqueues the
  existing `metadata.scan` background job (`dedupeKey: metadata.scan:<sessionId>`)
  whose in-process streaming walk inserts photos in batches. Photos are never
  inserted synchronously by the command itself.
- The 50,000-file bound (`MAX_SCANNED_FILES`) no longer applies to this path —
  it only bounds the optional `app:scan-directory` UI count preview, which the
  one-hop flow does not call.
- **Double-index dedup**: the renderer's `index.scan` trigger on
  `SessionDetail` entry re-uses the same dedupe key, so
  `jobs.create` collapses the duplicate onto the already-enqueued job
  (unique `analysis_jobs.dedupe_key` index); the renderer trigger remains as a
  harmless fallback for sessions created by other flows.
- **Dashboard 文案规范**: while the `metadata.scan` job is active the session
  card must not show an authoritative count — it shows 扫描中… (or the live
  `正在索引 N…` progress via the existing `jobs:progress` event channel) until
  the index job writes `sessions.photo_count` and a terminal progress frame
  arrives. Truncated imports keep the `≥N` prefix.

## Capture One sync state machine (P1 问题二接线, added with `c1:sync-state`)

- New **direct** IPC `c1:sync-state(sessionId)` (not a `gather:command`; same
  transport style as `c1:health`). Preload bridge:
  `window.gather.getC1SyncState(sessionId)` returning
  `C1SyncStateView { state, reloadAckedAt, xmp: {pending, writing, written,
  failed, conflict, synced} }`. `state` values mirror the main-process
  `CaptureOneSessionState` enum (a unit test keeps the renderer union in
  parity). Read-only aggregation; it never triggers actions.
- **Event wiring**: the `MetadataSyncCoordinator` event sink (set in
  `main/index.ts`) now also feeds `CaptureOneSyncState.observeSummary(summary)`,
  which re-derives the session state from the DB and logs transitions as
  `[capture-one-sync] session <id> 状态转换: a → b`. `c1:reload-metadata`
  additionally calls `observeReloadAck(sessionId)` because the ack write does
  not emit a coordinator summary. The sink only observes — no auto reload, no
  auto cleanup (conservative policy unchanged).
- **Similarity writeback panel (2.3.5)**: Load Metadata / Confirm Sync /
  Cleanup availability is derived by the pure mapping
  `deriveSyncControls({syncState, hasWritten, acked})`:
  `canLoadMetadata` = syncing | c1Read | safeToCleanup;
  `canConfirmSync` = (c1Read ∧ hasWritten ∧ acked) | safeToCleanup;
  `canCleanup` = safeToCleanup only. Status copy (`syncStatusCopy`) sits next
  to the buttons; disabled buttons carry a `title`/hint.
- **Dashboard C1 import preflight (2.3.5)**: the create flow for
  `source === 'capture-one'` calls `c1:health` BEFORE `getSelectedPhotos` and
  renders the four checks (reachable / appRunning / documentOpen /
  automationAuthorized) inline in the create dialog. Gating decision: the C1
  path requires all four checks to pass; on failure `getSelectedPhotos` is not
  called and the failure is shown inline (with 系统设置 → 隐私与安全性 → 自动化
  guidance for `automationAuthorized=false`, -1743) instead of a raw error
  toast. Pure logic lives in `evaluateC1Preflight` / `c1PreflightGuidance`.

## Phase-C workspace UI (P1-1/P1-2 + 问题二 P2 UI, design_improvements.md 1.3/2.3.5)

- **`/sessions/:id` now renders the Workspace Control Center** (index route,
  `pages/SessionDetail/ControlCenter`); the old index redirect to `gallery` is
  gone. All workspace entry points navigate to `/sessions/:id` instead of
  `/sessions/:id/gallery`: Dashboard create/addPhotos/进入 onSuccess and the
  App `CaptureOneImportListener` (c1:plugin-import). The module tabs stay
  untouched; the Control Center 工具箱 row links to the same tab routes.
- **Action Inbox** (1.4.3, pure logic in `workspace-view.ts`): fixed priority —
  scan_incomplete (info) → xmp_conflict (跳转 `/culling`，ConflictPanel) →
  analysis_stale (跳转 `/similarity`) → xmp_pending (跳转 `/culling` 元数据面板)
  → offline_photos (跳转 `/gallery`) → job_failed (最多 3 行，`jobs.retry` +
  invalidate `workspace-status`) → export_pending (跳转 `/export`)。空态文案
  「全部正常」。`scan_incomplete` 判定 = 活跃索引 job ∨ `stage='created'` ∨
  （截断导入且 `stage='imported'`，1.4.4）。
- **推荐下一步** 映射服务端 action id：`scan_incomplete`（信息）/`resolve_conflicts`
  → `/culling`、`re_analyze` → `/similarity`、`retry_jobs` → 全局 `/jobs`、
  `start_culling` → `/culling`、`export` → `/export`；`null` →「一切正常」。
- **C1 健康胶囊**（工作区头部，12s 轮询 `c1:sync-state` + `culling:sync-status`
  事件即时刷新）：绿=已同步/可安全清理、黄=Gather 已写入/同步中/已连接、
  红=连接中断/同步失败/存在冲突；title 含队列计数（pending+writing+written）
  与 `reloadAckedAt`（Intl 格式化）。点击跳转 `/settings`（无页签，面板常驻首屏）。
- **Settings → Capture One 健康面板**（`C1HealthPanel`，独立于既有
  c1_retries/c1_timeout_ms/c1_reload_delay_ms 设置项）：`c1:health` 四层预检
  （重新检测按钮）、`c1:sync-state` 六态队列计数（当前会话）、最近一次命令
  耗时 `latencyMs`、最近同步时间 `reloadAckedAt`。

## i18n P2: menu notifications carry error codes + locale resolution

- **Menu import notifications are error codes** (design_improvements.md 4.4.2):
  the File → Import from Capture One handler emits `gather:notification` with
  `message` as a `GatherErrorCode` — `C1_NO_DOCUMENT` for the no-selection case
  (deliberate deviation from the design doc's `C1_NOT_RUNNING`, since the app
  may be running with an empty selection),
  the underlying code or `C1_SCRIPT_FAILED` for failures. The renderer's
  `gather:notification` handler routes `message` through `translateError`
  (`desktop/src/renderer/utils/errors.ts`), which maps known codes via
  `error.<code>` locale keys and passes unknown text through unchanged.
- **Error payloads are codes, not copy** (4.4.2 sweep): validation/guard
  failures across export (`EXPORT_*`), XMP sync and writeback (`XMP_*`,
  `WRITEBACK_*`), culling and culling history (`CULLING_*`), asset relink
  (`ASSET_RELINK_*`), face service (`FACE_*`), similarity (`SIM_*`) and
  navigation (`NAV_*`) are thrown as `GatherErrorCode` values
  (`packages/shared/src/errors.ts`). IPC `error.message` is therefore a code;
  renderer surfaces render them via `translateError` / `translateErrorCode`
  (`error.<code>` keys) and never display raw codes. `metadata_outbox`
  `error_message` rows likewise store codes (`XMP_CLEANUP_ABORTED_EXTERNAL_EDIT`,
  `XMP_EXTERNAL_EDIT_CONFLICT`).
- **Locale resolution**: `--lang` switch (`app.commandLine.getSwitchValue('lang')`)
  wins, else `app.getLocale()`; anything not `zh`-prefixed maps to `'en'`,
  zh-prefixed to `'zh-CN'`. The menu template is built per locale
  (`desktop/src/main/menu.ts`, `setupAppMenu`), and `rebuildMenu()` rebuilds it
  after a future language switch. Note: Electron/Chromium also consume
  `--lang` for their own UI, so the switch affects both consistently.

## Language switch (i18n P2 收尾: settings override + menu rebuild)

- **Locale precedence** (design_improvements.md 4.2, pure logic in
  `desktop/src/main/locale.ts`, unit-tested): persisted `ui_language` setting
  override > `--lang` switch > `app.getLocale()` > `'en'` fallback; non-zh
  values map to `'en'` via `resolveAppLocale`. An invalid persisted override
  (anything other than `'zh-CN'`/`'en'`) is treated as unset.
- **New direct IPC `app:get-app-locale`** (same transport style as
  `c1:health`, exposed as `window.gather.getAppLocale()`): returns
  `{ language: 'zh-CN' | 'en' }` — the effective locale resolved by the main
  process. The renderer bootstrap (`main.tsx`) awaits it and calls
  `initI18n(language)` BEFORE `ReactDOM.render`, so the UI never paints in
  the wrong language; on IPC failure it falls back to navigator detection.
- **New command `settings.set_language`** with params
  `{ language: 'zh-CN' | 'en' }` (typed in `packages/shared`, allowlisted in
  the preload, exposed as `window.gather.setLanguage` /
  `settingsApi.setLanguage`): validates the value, persists it as the
  `ui_language` app_setting, and rebuilds the application menu
  (`menu.ts setAppLocale`) in the same handler. Invalid values are rejected
  and nothing is written. The Settings page then applies the locale locally
  via `initI18n(language)` — one user action keeps menu + UI copy in sync.
- **Option labels 中文 / English are fixed brand-style names** (identical in
  both locale files): the options name the language itself, so localizing
  them would be self-referential; they are intentionally not translated.
- Settings page default (`ui_language` empty) resolves to `--lang`/system
  locale; `settings.reset` clears the override back to that behavior.



