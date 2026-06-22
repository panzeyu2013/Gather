# Gather Functional Design and Execution Plan

This document turns the current functional review into implementable design plans. It focuses on completing the user workflow rather than changing the core algorithms.

## Goals

- Make Gather reliable for a photographer completing a real Capture One metadata workflow.
- Make destructive file operations explicit, previewable, and recoverable.
- Reduce ambiguity between source-development usage and packaged-app usage.
- Keep the current Electron + Python engine architecture, and evolve it with focused, testable changes.

## Non-Goals

- Replacing the dHash or face clustering algorithms.
- Redesigning the full visual system.
- Adding cloud sync, collaboration, or account features.

## Priority Roadmap

0. Decide product mode: developer/internal tool or end-user packaged app.
1. Standardize the XMP writeback lifecycle across Face KW and Similarity.
2. Split sync confirmation from cleanup, and add explicit cleanup deferral.
3. Add failure details and retry based on shared writeback audit items.
4. Add Similarity writeback preview and source-specific guidance.
5. Add Dashboard safety and session health.
6. Add high-volume Face Keywording workflow improvements.

---

## Cross-Cutting Design: Unified XMP Writeback Lifecycle

### Why This Must Be Shared

Both Face Keywording and Similarity write XMP sidecars. Users experience both as "metadata writeback", so the product should use one lifecycle, one failure model, and one recovery vocabulary across modules.

### Lifecycle

Every writeback-capable module should follow the same sequence:

1. **Plan**: build a file-level writeback plan without modifying disk.
2. **Preview**: show planned changes and warnings to the user.
3. **Execute**: create audit rows, backup original XMP when needed, and write sidecars.
4. **Review Failures**: show per-file status and errors.
5. **Retry**: retry only failed items, leaving successful items untouched.
6. **Confirm Sync**: user confirms the external app has loaded metadata.
7. **Cleanup or Defer**: user either cleans sidecars/backups now or explicitly defers cleanup.

### Shared Commands

Use module-specific command names at the protocol boundary, but keep response shapes shared:

- `fkw.preview_writeback`
- `fkw.execute_writeback`
- `fkw.writeback_items`
- `fkw.retry_failed_writeback`
- `fkw.confirm_sync`
- `fkw.cleanup`
- `sim.preview_writeback`
- `sim.execute_writeback`
- `sim.writeback_items`
- `sim.retry_failed_writeback`
- `sim.confirm_sync`
- `sim.cleanup`

Backward-compatible aliases can remain temporarily:

- `fkw.writeback` -> `fkw.execute_writeback`
- `fkw.confirm_cleanup` -> compatibility wrapper around confirm + cleanup until UI migration is complete.
- `sim.writeback` -> `sim.execute_writeback`

### Shared Writeback Plan Schema

Every preview command should return:

```ts
interface WritebackPlan {
  session_id: string
  module: 'face_kw' | 'similarity'
  summary: {
    selected_groups?: number
    affected_photos: number
    keywords_to_write: number
    sidecars_to_create: number
    sidecars_to_update: number
    warnings: number
  }
  items: WritebackPlanItem[]
  warnings: WritebackWarning[]
}

interface WritebackPlanItem {
  photo_id?: string
  photo_path: string
  filename: string
  sidecar_path: string
  source: 'capture_one' | 'local_files' | 'mixed' | 'unknown'
  planned_keywords: string[]
  existing_keywords?: string[]
  group_id?: string | number
  group_label?: string
  album_names?: string[]
  filename_prefix?: string
  mark_ungrouped?: boolean
  has_existing_xmp: boolean
  backup_required: boolean
  warnings: WritebackWarning[]
}

interface WritebackWarning {
  code:
    | 'file_missing'
    | 'sidecar_locked'
    | 'outside_safe_path'
    | 'not_capture_one_source'
    | 'existing_xmp_will_be_merged'
    | 'cleanup_deferred'
  message: string
  severity: 'info' | 'warning' | 'error'
}
```

### Shared Audit Item Schema

The existing `writeback_items` table should become the shared audit source for both modules. Add fields only when needed through migrations:

- `id`
- `session_id`
- `module`: `face_kw | similarity`
- `photo_id`
- `photo_path`
- `keywords`
- `xmp_path`
- `backup_path`
- `xmp_status`: `pending | written | failed | skipped | cleaned | cleanup_deferred`
- `error_message`
- `attempt_count`
- `last_attempt_at`
- `created_at`
- `updated_at`

Dashboard health, failure retry, cleanup, and export reports should all read from this table instead of module-specific in-memory state.

### Session State Additions

Keep existing `writeback_status`, but add metadata for cleanup:

- `cleanup_status`: `not_applicable | pending | deferred | cleaned | partial | failed`
- `cleanup_deferred_at`: ISO timestamp or null
- `last_writeback_module`: `face_kw | similarity | mixed | null`

If adding columns is too heavy for the first implementation, store these in a session metadata JSON field, but the UI contract should stay the same.

### Acceptance Criteria

- Face KW and Similarity expose the same writeback phases and language.
- A failed writeback item can be traced from Dashboard to module detail to filesystem path.
- Cleanup can be deferred without losing the ability to clean later.
- Preview response and execution audit counts match.

---

## 1. Packaged App Runtime Strategy

### Problem

The README currently says packaged builds still require local `python3` and installed Python dependencies. That makes `npm run dist:mac` look like an end-user installer while the app still behaves like a developer build.

### Proposed Product Decision

Choose one mode explicitly:

- **Developer/Internal Mode**: keep local Python dependency, but make the app say so clearly at startup and in docs.
- **End-User Packaged Mode**: bundle Python engine and dependencies into the app distribution.

Recommended direction: end-user packaged mode if this app is intended for photographers outside the development team.

### User Experience

- On first launch, Gather runs a startup health check.
- If runtime is missing, show a concrete error:
  - Python interpreter not found.
  - Required Python package missing.
  - Engine script missing.
  - Engine version mismatch.
- Give one actionable next step, not a traceback.

### Architecture Design

Current:

- Electron main process starts `python3`.
- Python engine communicates over MessagePack stdin/stdout.

Target:

- `PythonBridge` resolves runtime from packaged resources first.
- Development still prefers `.venv/bin/python`.
- Packaged builds use a bundled runtime path, such as:
  - macOS: `process.resourcesPath/python/bin/python3`
  - Windows: `resources/python/python.exe`
- Engine startup sends a structured `ready` payload. This is the only signal available before the renderer can safely issue engine commands:
  - `version`
  - `python_version`
  - `features`
  - `missing_optional_features`
- `engine.health` is a post-start diagnostic command. It should return the same information plus deeper checks, such as writable DB path, safe path prefixes, optional dependency availability, and thumbnail generation readiness.

### Implementation Steps

1. Define `EngineReadyPayload` and `EngineHealthResponse` in `packages/shared/src/protocol.ts`.
2. Extend Python `ready` event with lightweight runtime information.
3. Add `engine.health` command in Python for deeper diagnostics after startup.
4. Extend `PythonBridge` path resolution for packaged resources.
5. Update `electron-builder.yml` to include bundled engine/runtime artifacts once packaging is chosen.
6. Update startup screen to show health check failures.
7. Update README with one supported install path per release channel.

### Tests

- Unit test Python engine health response.
- TypeScript test runtime path resolution for dev and packaged modes.
- Manual packaging smoke test:
  - Launch app on a clean machine/user account.
  - Run Dashboard load.
  - Import sample photos.

### Acceptance Criteria

- A packaged build either runs without external Python setup or clearly identifies the missing local setup.
- Startup failures are actionable for non-programmers.
- README and app behavior no longer contradict each other.

---

## 2. Confirm Sync and Cleanup Policy

### Problem

The UI says `Confirm Sync`, while the current functional intent also includes cleanup. That is a risky semantic overlap because cleanup can remove Gather-created XMP files or restore backups.

### Proposed Product Decision

Separate confirmation from cleanup in the UI.

Recommended flow:

1. User writes XMP metadata.
2. User loads metadata in Capture One.
3. User clicks `I Loaded Metadata in Capture One`.
4. Gather marks the session synced.
5. Gather then offers `Clean Up XMP Sidecars and Backups`.

### User Experience

After writeback succeeds:

- Show guidance:
  - Select the processed images in Capture One.
  - Use Image -> Load Metadata.
  - Verify keywords.
- Primary button: `I Loaded Metadata in Capture One`.
- Secondary button: `Clean Up Later`.
- After sync confirmation:
  - Show cleanup options:
    - `Remove Gather-created XMP sidecars`
    - `Restore original XMP backups`
    - `Keep backups for now`
- If cleanup is deferred:
  - Mark the session as synced but not cleaned.
  - Keep a visible Dashboard badge: `Cleanup pending`.
  - Allow reopening Step 5 and running cleanup later.

### Architecture Design

Current command:

- `fkw.confirm_cleanup`

Target commands:

- `fkw.confirm_sync`
- `fkw.cleanup`
- Optional future: `fkw.rollback_writeback`

State model:

- `writeback_status = done`: writeback completed.
- `session.status = completed`: user confirmed Capture One loaded metadata.
- `writeback_status = cleaned`: cleanup completed.
- `writeback_status = partial`: cleanup or writeback had failures.
- `cleanup_status = pending`: writeback is done, cleanup is available.
- `cleanup_status = deferred`: user chose `Clean Up Later`.
- `cleanup_status = cleaned`: cleanup completed.
- `cleanup_status = partial`: cleanup ran but some files failed.

### Implementation Steps

1. Add separate protocol commands:
   - `fkw.confirm_sync`
   - `fkw.cleanup`
2. Keep `fkw.confirm_cleanup` temporarily as a backward-compatible alias.
3. Update Face KW Step 5 UI:
   - Rename buttons.
   - Add cleanup options.
   - Show cleanup result summary.
4. Add `cleanup_status` to session metadata or schema.
5. Persist cleanup result in writeback audit items and session metadata.
6. Add Dashboard badge for deferred cleanup.
7. Update `TEST.md` and README flow.

### Tests

- Python service test:
  - confirm sync updates session status but does not remove XMP.
  - cleanup removes/restores expected files.
- Renderer test:
  - buttons progress through sync -> cleanup states.
- Manual Capture One test:
  - verify keywords remain after cleanup.

### Acceptance Criteria

- Users can confirm sync without accidental cleanup.
- Cleanup is explicit and reversible where backups exist.
- Deferred cleanup is visible and resumable.
- The UI wording matches exactly what the backend does.

---

## 3. Shared Writeback Failure Details and Retry

### Problem

Face Keywording exposes `Retry failed items`, and Similarity also writes XMP metadata. A user should not need to learn two different failure models for the same kind of filesystem operation.

### Proposed Behavior

Both writeback modules should use the shared writeback audit model from the cross-cutting design. Face KW can be migrated first, but Similarity must be included in the target design.

### User Experience

After writeback:

- Show counts:
  - Written
  - Failed
  - Skipped
- If failures exist, show a table:
  - File name
  - Full path
  - Error
  - Current status
  - Retry eligible
- Primary action: `Retry Failed Files`.
- Secondary action: `Export Failure Report`.

### Architecture Design

Use existing `writeback_items` as the source of truth.

Add commands:

- `fkw.writeback_items`
- `fkw.retry_failed_writeback`
- `sim.writeback_items`
- `sim.retry_failed_writeback`

### Backend Design

`writeback_items` should support the shared audit schema. The minimum v1 fields are:

- `photo_id`
- `session_id`
- `module`
- `keywords`
- `xmp_path`
- `backup_path`
- `xmp_status`
- `error_message`
- `attempt_count`
- `updated_at`

Retry logic:

- Query failed items for session.
- Re-run XMP writing only for those photo paths.
- Update each item independently.
- Leave successful items untouched.

### Frontend Design

Face KW Step 5 and Similarity result modal:

- Add failure table below result cards.
- Disable cleanup until failed items are resolved or user explicitly chooses to continue.
- Keep partial success visible.
- Use identical labels for statuses and retry actions.

### Implementation Steps

1. Add manager method `get_writeback_items(session_id, module=None, status=None)`.
2. Add module-specific service methods:
   - `FaceKeywordingService.retry_failed_writeback(session_id)`
   - `SimilarityService.retry_failed_writeback(session_id)`
3. Add engine handlers and protocol commands.
4. Update Face KW result rendering.
5. Update Similarity writeback result rendering.
6. Add export report utility, initially as copyable text or downloadable `.txt`.

### Tests

- Backend:
  - failed item retry updates only failed item.
  - successful item is not rewritten.
  - repeated retry preserves failure error if still failing.
  - Face KW and Similarity both create audit rows.
- Renderer:
  - failure table renders.
  - retry button hidden when no failures.
  - status labels match across Face KW and Similarity.

### Acceptance Criteria

- User can identify every failed file.
- User can retry only failures.
- Cleanup cannot accidentally hide unresolved writeback failures.
- Similarity and Face KW failures are visible in a shared Dashboard health summary.

---

## 4. Similarity Writeback Preview

### Problem

Similarity writeback currently moves from selected groups and options directly to execution. Users cannot inspect the exact file-level changes before XMP modification.

### Proposed Behavior

Add a preview step before `Execute Writeback`.

### User Experience

When the user clicks `Execute Writeback`:

1. Gather opens a preview modal or panel.
2. It lists:
   - Selected group count.
   - Affected photo count.
   - Per-photo planned changes.
   - Selected options.
3. User confirms with `Write Metadata`.

Preview rows:

- File name/path.
- Group label.
- IPTC keywords to write.
- Album name to create.
- Filename prefix if enabled.
- Ungrouped marker if enabled.

### Architecture Design

Add command:

- `sim.preview_writeback`

Request:

- `session_id`
- selected `groups`
- `options`

Response:

- `summary`
- `items`
- `warnings`

Similarity-specific item details should extend the shared `WritebackPlanItem` with:

```ts
interface SimilarityWritebackPlanItem extends WritebackPlanItem {
  group_id: string | number
  group_label: string
  planned_keywords: string[]
  album_names: string[]
  filename_prefix?: string
  mark_ungrouped: boolean
  representative: boolean
}
```

The preview response should be treated as a plan snapshot. Execution should either:

- Rebuild the plan from current inputs and verify the summary still matches, or
- Accept a signed/hashable `plan_id` generated by the preview command.

Recommended v1: rebuild and compare counts/options, because it avoids storing server-side temporary plans.

### Backend Design

Move writeback planning into a pure helper:

- `build_similarity_writeback_plan(groups, options)`

Then:

- Preview uses the helper and returns the plan.
- Execute uses the helper and writes the planned changes.
- Execute validates that selected group IDs still exist in the latest analysis result.
- Execute returns a warning if the plan changed between preview and write.

### Frontend Design

In `similarity.ts`:

- Replace direct destructive confirmation with preview modal.
- Keep existing final result modal.
- Disable write button while preview is loading.

### Tests

- Backend:
  - preview and execute produce matching affected counts.
  - options map to expected planned actions.
  - execution rejects deleted/stale group IDs.
- Renderer:
  - no selected groups still warns before preview.
  - preview modal shows selected options.
  - preview modal shows file-level warnings.

### Acceptance Criteria

- No Similarity writeback happens without file-level preview.
- The preview count matches execution result count.
- Users can cancel safely from the preview.

---

## 5. Import Source Awareness

### Problem

Gather supports Capture One import and local file import. The writeback guidance assumes Capture One, but local files may not belong to the active Capture One catalog.

### Proposed Behavior

Track session import source and use source-specific guidance.

### User Experience

Dashboard session rows show source:

- `Capture One`
- `Local Files`
- `Mixed`

Writeback guidance:

- Capture One source:
  - `Use Image -> Load Metadata in Capture One.`
- Local Files source:
  - `XMP sidecars were written next to the selected files. Import or refresh metadata in your photo manager.`

### Architecture Design

Add session metadata:

- `import_source`: `capture_one | local_files | mixed | unknown`
- `source_context`: JSON object with source-specific details.

For each photo, optionally track:

- `source`
- `imported_at`
- `source_context`
- `last_seen_exists`
- `last_seen_at`

Capture One source context should include:

```ts
interface CaptureOneSourceContext {
  app_name: string
  imported_at: string
  document_known: boolean
}
```

File validation status should be refreshed before analysis and writeback:

- If a file no longer exists, block writeback for that file and show a warning.
- If a local-file session is not known to be in Capture One, do not show Capture One-only instructions.
- If a session is mixed, show both guidance blocks and label rows by source.

### Implementation Steps

1. Extend session/photo schema.
2. Update `session.add_photos` to accept `source`.
3. Pass source from Dashboard import handlers.
4. Show source badge in Dashboard and writeback pages.
5. Add file existence validation before analysis and writeback.
6. Update docs and tests.

### Tests

- DB migration preserves existing sessions as `unknown`.
- Capture One import creates `capture_one` session.
- File picker import creates `local_files` session.
- Mixed imports update source to `mixed`.
- Missing imported files produce row-level warnings.

### Acceptance Criteria

- Guidance never assumes Capture One for local-only sessions.
- Dashboard visibly identifies import source.
- Writeback preview warns about missing/offline files before disk writes begin.

---

## 6. Safer Bulk Session Deletion

### Problem

`Delete All Sessions` is useful but dangerous on the Dashboard. There is no export or undo path.

### Proposed Behavior

Move bulk deletion behind a safer interaction.

Options:

1. Remove from Dashboard until export/backup exists.
2. Move to advanced settings.
3. Require typed confirmation: `DELETE ALL`.

Recommended short-term choice: typed confirmation.

### User Experience

Clicking `Delete All Sessions` opens a dialog:

- Shows number of sessions and photos affected.
- Requires typing `DELETE ALL`.
- Confirm button disabled until text matches.
- Focus starts in the text field.
- Escape cancels.
- Tab is trapped inside the dialog.
- The destructive button exposes `aria-disabled` while disabled.

### Architecture Design

No backend change required initially. This can be implemented in renderer.

Future:

- Add export/backup session state before deletion.

### Implementation Steps

1. Create a reusable typed-confirm dialog component.
2. Use it for bulk delete.
3. Include affected counts.
4. Add keyboard and focus handling equivalent to the existing dialog component.
5. Keep normal session delete unchanged.

### Tests

- Renderer test for disabled confirm state.
- Renderer test for focus trap and Escape cancel.
- Manual test:
  - Cancel keeps sessions.
  - Wrong text cannot delete.
  - Correct text deletes.

### Acceptance Criteria

- Accidental bulk deletion is difficult.
- User understands scope before confirming.
- Keyboard-only users can complete or cancel the dialog safely.

---

## 7. Face Keywording Batch Efficiency

### Problem

The current Face KW wizard works for small and medium jobs, but large jobs need faster review actions.

### Proposed Features

- Batch skip visible unbound clusters.
- Keyboard shortcuts:
  - `Enter`: save current binding.
  - `S`: skip current cluster.
  - `N`: next unbound cluster.
  - `P`: previous cluster.
- Recent role/keyword suggestions.
- Duplicate role warning.

### User Experience

In Step 3:

- Role input shows recent names.
- Keyword input suggests previous keywords.
- A small shortcut hint appears near the actions.

In Step 2:

- Multi-select mode for clusters.
- Batch action: `Skip Selected`.

### Architecture Design

Store suggestions locally first:

- v1: in-memory state plus `sessionStorage` only.
- Do not add DB migration for suggestions in the first iteration.
- Do not share suggestions across OS users or app installs.

Later:

- Add persistent `role_history` table.

### Implementation Steps

1. Add keyboard shortcut handler scoped to Face KW page.
2. Add recent role/keyword in-memory store backed by `sessionStorage`.
3. Add batch cluster selection state.
4. Add backend batch skip command, or call existing skip/bind API per selected cluster.

### Tests

- Renderer:
  - shortcuts trigger correct actions.
  - shortcuts do not fire while dialog is open.
  - suggestions dedupe.
- Backend:
  - batch skip persists statuses.

### Acceptance Criteria

- A user can process many clusters without excessive mouse clicks.
- Shortcuts do not interfere with text entry.
- Suggestions are local to the current browser/app session in v1.

---

## 8. Cancellation Feedback

### Problem

Analysis cancellation is supported, but long-running operations may only stop after the current file or phase. The UI should set expectations.

### Proposed Behavior

When cancelling:

- Button text changes to `Cancelling...`.
- Progress message says `Finishing current file, then stopping...`.
- If cancellation completes, status is `Cancelled`.
- If the operation already completed, show `Analysis already completed.`

### Architecture Design

Backend progress events should include:

- `status: cancelled`
- `message`
- optional `cancel_requested: true`
- optional `partial_usable: boolean`

Frontend should distinguish:

- `cancel_requested`
- `cancelled`
- `done`
- `failed`
- `partial_usable`

### Implementation Steps

1. Add cancel-requested progress event when cancel command is accepted.
2. Update Similarity and Face KW cancel UI states.
3. Preserve and display partial results only if backend explicitly returns `partial_usable=true`.
4. Otherwise discard partial result UI and show a clear cancelled state.

### Tests

- Backend cancellation unit tests for both services.
- Renderer tests for cancelling state.

### Acceptance Criteria

- User sees immediate feedback after cancel.
- UI does not imply cancellation is instantaneous.
- Partial data is never shown as complete analysis output.

---

## 9. Dashboard Session Health

### Problem

Dashboard currently lists sessions, but it does not surface enough health information for a user managing multiple jobs.

### Proposed Behavior

Add richer session status badges and filters.

Badges:

- Photos loaded
- Similarity analyzed
- Face analyzed
- Writeback partial
- Writeback done
- Cleaned

Filters:

- All
- Needs review
- Writeback failed
- Completed

### Architecture Design

Session row needs summary data:

- `photo_count`
- `analysis_status`
- `writeback_status`
- maybe `face_cluster_count`
- maybe `similarity_group_count`
- `failed_writeback_count`
- `cleanup_status`
- `cleanup_deferred_at`

`failed_writeback_count` and cleanup badges should come from shared writeback audit/session cleanup state, not from module-specific caches.

### Implementation Steps

1. Add summary fields to `session.list`.
2. Render badges in Dashboard.
3. Add simple filter controls.
4. Add click target to resume the most relevant next step.
5. Link `Writeback failed` rows directly to the relevant module result panel.

### Tests

- Session list includes summary fields.
- Dashboard renders partial failures prominently.
- Filters produce expected row counts.

### Acceptance Criteria

- A user can tell which sessions need attention without opening each one.
- Partial writeback failures are visible from Dashboard.
- Deferred cleanup is visible from Dashboard.

---

## 10. Documentation and Test Plan Alignment

### Problem

README, TEST.md, and implemented behavior can drift as functionality changes.

### Proposed Behavior

Every product decision above should update:

- README user flow.
- TEST manual checklist.
- Developer architecture notes where needed.
- Automated tests for critical behavior.

### Implementation Steps

1. Update README after each feature lands.
2. Keep `TEST.md` as the manual acceptance test source.
3. Add a `docs/release-checklist.md` later for packaging and smoke tests.

### Acceptance Criteria

- Manual test steps match UI labels exactly.
- Docs do not describe unsupported distribution modes.
- Destructive behavior is documented.

---

## Suggested Milestones

### Milestone 0: Product Mode Decision

- Decide whether Gather is a developer/internal tool or an end-user packaged app.
- Decide whether packaged builds must bundle Python and dependencies.
- Decide whether cleanup is automatic, optional, or always separate from sync confirmation.
- Decide whether `Delete All Sessions` remains visible on Dashboard.

### Milestone 1: Safety and Clarity

- Implement the shared writeback lifecycle contracts.
- Split confirm sync and cleanup.
- Add failure details and retry scope.
- Add typed confirmation for Delete All.
- Update README and TEST.md.

### Milestone 2: Preview Before Destructive Writes

- Add Similarity writeback preview.
- Add source-aware writeback guidance.
- Add Dashboard health badges.

### Milestone 3: Distribution Readiness

- Add engine health checks.
- Build and verify packaged app startup.

### Milestone 4: High-Volume Workflow

- Add Face KW shortcuts.
- Add batch skip.
- Add role/keyword suggestions.

## Open Decisions

- Should packaged builds bundle Python and dependencies?
- Should cleanup be automatic after sync confirmation, or always separate?
- Should `Delete All Sessions` remain visible on Dashboard?
- Should local-file sessions support Capture One-specific actions at all?
- Should shared writeback audit migration happen in one release for both modules, or should Face KW migrate first and Similarity follow in the next milestone?
- Should cleanup metadata be stored as explicit DB columns or inside a session metadata JSON field for the first implementation?
