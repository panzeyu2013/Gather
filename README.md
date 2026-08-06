# Gather — Smart Photo Organizer for Capture One

Visually group similar photos and annotate faces with keywords, helping photographers efficiently organize their Capture One catalogs.

---

## Features

### Culling Workbench
- Cull every workspace photo without running similarity analysis first
- Independent Pick / Reject, 0–5 star rating, and Capture One color labels
- Auto advance, filtered and similarity scopes, batch actions, and undo / redo
- Single, dual, and quad comparison with synchronized zoom and face alignment
- Durable background XMP sidecar queue with retry, conflict detection, and restart recovery

### Similarity Grouping
- dHash perceptual hashing + hierarchical clustering to find visually similar images
- Adjustable threshold (4–20) and minimum group size, real-time result updates
- Keyword writeback per group: writes `dc:subject` keywords into XMP sidecars

### Face Keyword Annotation
- Face detection → feature encoding → DBSCAN clustering
- 3-step flow: 分析 (Analyze) → 审核 (Review: bind / merge / skip) → 写回 (Writeback), then confirm sync
- Merge clusters, remove members, bind/skip assignments
- Writes `dc:subject` XMP keywords, with confirm-sync and cleanup after writeback

### Capture One Integration
- **One-click import** of selected photos from Capture One via AppleScript (`Cmd+Shift+I`)
- **Native plugin** (COOpenWithPlugin) — right-click photos in Capture One, "Send to Gather"
- Photo paths are passed via `gather://` deep link, auto-creating a workspace

### Native Desktop Experience
- Standalone Electron app, no browser needed
- Dark theme, toast notifications, step-by-step navigation

---

## Installation

### Download
Pre-built `.dmg` releases are available on the [Releases](https://github.com/panzeyu2013/Gather/releases) page.

### Build from Source

```bash
npm install
npm run build
npm run electron
```

For a packaged macOS build, run `npm run dist:mac --workspace=desktop`; the
result is written to `desktop/release/`.

---

## Usage

### Culling
1. Import a folder or Capture One selection into a workspace.
2. Open **Culling**. Similarity analysis is optional.
3. Use `P` for Pick, `X` for Reject, `0`–`5` for rating, arrow keys to navigate,
   and `Cmd/Ctrl+Z` to undo. Enable auto advance for keyboard-first review.
4. Use dual/quad mode for comparison; face alignment reuses existing face
   detections and does not run a new model.
5. Ratings and colors are merged into XMP sidecars in the background. Resolve
   failed/conflict items, or click **Write XMP now** for an immediate flush.
6. In Capture One, run **Image → Load Metadata** (or use one-way Auto Sync =
   Load). Return to Gather, confirm that Capture One loaded the metadata, and
   only then restore/remove temporary sidecars if desired.

### Similarity Grouping
1. Select photos in Capture One
2. Open Gather and import via the Dashboard import dialog (create a workspace with source "Capture One" or a local folder), or press `Cmd+Shift+I` with photos selected in Capture One
3. Go to the **Similarity** page and click **Start Similarity Analysis**
4. Adjust threshold and minimum group size, then confirm groups
5. Enter keywords for the confirmed groups and click **Execute Writeback** (writes `dc:subject` keywords into XMP sidecars)

### Face Keyword Annotation
1. Import photos (same as above)
2. **分析 (Analyze)**: go to the **Face KW** page and click **Start Face Analysis**
3. **审核 (Review)**: browse clusters (All / Unbound / Bound / Skipped), select one to bind a role name and keywords (Enter/comma to add), merge clusters, or skip
4. **写回 (Writeback)**: preview assignments, execute writeback, then **Load Metadata** in Capture One
5. Return to Gather and click **Confirm Sync**

### Capture One Native Plugin
The `GatherLink.coplugin` is built and bundled into the macOS `.dmg` under
`Gather.app/Contents/Resources/plugins/` when the Capture One SDK is present on
the build machine (packaging is skipped gracefully otherwise).

1. Install from the packaged app or source build:
   ```bash
   # Bundled: copy from the app bundle
   cp -R "/Applications/Gather.app/Contents/Resources/plugins/GatherLink.coplugin" \
     "$HOME/Library/Application Support/Capture One/Plug-ins/"
   # Or build from source (see coplugin/Makefile)
   cd desktop/coplugin && make all && make install
   ```
2. Restart Capture One
3. Right-click any photo → **Open With** → **Send to Gather**

---

## Architecture

```
Electron Desktop App
  ├── Main Process (Node.js)
  │   ├── Similarity Service (dHash + hierarchical clustering)
  │   ├── Face KW Service (ONNX Runtime + DBSCAN)
  │   ├── Writeback Service (XMP via fast-xml-parser)
  │   ├── Capture One Bridge (osascript)
  │   └── Deep Link Handler (gather:// protocol)
  ├── Preload (contextBridge, security isolation)
  └── Renderer (React 18 + Vite + CSS Modules)

Storage: SQLite via better-sqlite3 (WAL mode)
Plugin: GatherLink.coplugin (COOpenWithPlugin, Swift)
```

- IPC: `gather:command` pattern via `ipcMain.handle` / `contextBridge`
- Security: `contextIsolation: true`, `sandbox: true`, `nodeIntegration: false`
- Packaging: electron-builder → `.dmg` (macOS)

---

## Development

```bash
npm install
npm run dev           # Start Vite/Electron development mode
npm run build         # Build shared contracts and desktop app
npm run typecheck     # TypeScript type checking
npm run lint          # ESLint
npm run test:vitest   # Vitest unit tests
npm run test:e2e      # Production Electron smoke workflow
npm run electron      # Build and launch the local production app
```

The face-keyword end-to-end test needs ONNX models and RAW photos with faces,
which cannot be committed. Run `node scripts/setup-local-face-fixtures.mjs`
and drop 2+ RAW photos (or symlink a folder) into `tests/fixtures/local/raw/`;
the test then runs automatically, otherwise it is skipped.
See [tests/fixtures/local-fixtures.md](tests/fixtures/local-fixtures.md).

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the developer and contributing guide.

---

## Related Documents

- [中文说明](docs/README_CN.md)
- [Development & Contributing Guide](docs/DEVELOPMENT.md)
- [Testing Guide](docs/TEST.md)
- [Roadmap](docs/ROADMAP.md)
- [Native Development Analysis](docs/NATIVE-DEVELOPMENT-ANALYSIS.md)

---

## License

MIT License — see [LICENSE](LICENSE)
