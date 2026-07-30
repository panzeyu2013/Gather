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
- Bulk XMP writeback per group (keywords, filename prefixes, album markers)

### Face Keyword Annotation
- Face detection → feature encoding → DBSCAN clustering
- 5-step wizard: Import & Analyze → Cluster Review → Role Binding → Preview → Writeback
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
2. Open Gather, click **Import from Capture One** or press `Cmd+Shift+I`
3. Go to the **Similarity** page and click **Start Similarity Analysis**
4. Adjust threshold and minimum group size, then confirm groups
5. Configure writeback options and click **Execute Writeback**

### Face Keyword Annotation
1. Import photos (same as above)
2. Go to the **Face KW** page and click **Start Face Analysis**
3. Browse face clusters, filter by All / Unbound / Bound / Skipped
4. Select a cluster → bind a role name and keywords (Enter/comma to add)
5. Preview keyword assignments for all photos
6. Execute writeback, then **Load Metadata** in Capture One
7. Return to Gather and click **Confirm Sync**

### Capture One Native Plugin
1. Build and install the plugin (see [coplugin/Makefile](desktop/coplugin/Makefile)):
   ```bash
   cd desktop/coplugin
   make all
   make install
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

See [docs/DEVELOPER.md](docs/DEVELOPER.md) for detailed architecture docs.

---

## Related Documents

- [中文说明](docs/README_CN.md)
- [Development Guide](docs/DEVELOPER.md)
- [Testing Guide](docs/TEST.md)
- [Contributing](docs/CONTRIBUTING.md)

---

## License

MIT License — see [LICENSE](LICENSE)
