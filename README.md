# Gather — Smart Photo Organizer for Capture One

Visually group similar photos and annotate faces with keywords, helping photographers efficiently organize their Capture One catalogs.

---

## Features

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
cd desktop
npm install
npm run dist:mac
```

The built `.dmg` will be in `desktop/release/`.

---

## Usage

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
cd desktop
npm install          # Install dependencies
npm run dev          # Start dev mode (hot reload)
npm run typecheck    # TypeScript type checking
npm run lint         # ESLint
npm test             # Vitest unit tests
npm run dist:mac     # Build macOS .dmg
```

See [DEVELOPER.md](DEVELOPER.md) for detailed architecture docs.

---

## Related Documents

- [中文说明](README_CN.md)
- [Development Guide](DEVELOPER.md)
- [Testing Guide](TEST.md)
- [Contributing](CONTRIBUTING.md)

---

## License

MIT License — see [LICENSE](LICENSE)
