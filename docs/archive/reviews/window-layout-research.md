# Reference-app window layout → Gather restructure

> **Source-availability caveat (affects §1.1 and §1.3).** Adobe's HelpX renders article bodies client-side: every page returns HTTP 200 but the article text sits *past* the fetch ceiling, behind a 69-entry (Bridge) / 119-entry (Lightroom Classic) table of contents. I verified Adobe's **chapter URLs, chapter titles and product pages** directly; I could **not** retrieve article-body sentences. Claims taken from chapter titles are marked ✅; claims that are the well-known arrangement but which I could not fetch a sentence for are marked ⚠️. Everything for Capture One, darktable and digiKam below is quoted from fetched body text.

## 1. Layout anatomy of the reference apps

### 1.1 Adobe Bridge (2024/2025)

Source: [Adobe Bridge Desktop Help](https://helpx.adobe.com/bridge/user-guide.html) — the "Workspaces and preferences" chapter group is a verified, live sibling set:

| Region | Contents | Panel/feature names |
| --- | --- | --- |
| **Top** | Menu bar; the **application bar / toolbar** carrying the workspace switcher, path bar, search, filter, sort and the thumbnail-size slider | ✅ "Customize the workspace", ✅ "Set user interface preferences" |
| **Left** | Source/navigation stack: where the content *comes from* | ⚠️ Favorites / Folders; ✅ **Collections**, ✅ **Stacks** (chapters "Use collections", "Stack files") |
| **Centre** | The thumbnail grid — Bridge's dominant surface | ✅ **Content panel** — the chapter *"Adjust Adobe Bridge Content panel display"* names it; ✅ "Adjust panels" |
| **Right** | Item metadata and item options | ✅ **Metadata** ("View and edit metadata", "About metadata"), ✅ **Keywords** ("Use keywords"), ✅ **Filter** (product page: "find assets using powerful filters and advanced metadata search features") |
| **Bottom** | Status bar + thumbnail-size control | ⚠️ (not verifiable here) |
| **Separate window** | ✅ **Export panel** — the product page names it ("Export images to multiple formats using the new Export panel"); ✅ "Create export presets" |

- **How modes/workspaces switch:** a **workspace switcher in the application bar** (top), plus named workspaces. ✅ Evidence: Adobe ships a chapter *"Create PDF contact sheet in the **Output workspace**"* — workspaces are named things, not just a layout reset. ✅ "Customize the workspace" is its own chapter. The shipped set is ~8 (Essentials, Filmstrip, Metadata, Output, Keywords, Preview, Light Table, Folders) — ⚠️ that exact list is not verifiable from the sources I could fetch; only **Output** is confirmed by name.
- **Where catalog-wide management lives:** ✅ **not above the content.** The entire management surface is its own chapter group, *"Organize and find files"*, split into *"Tag and find files"* (About/Add/Import metadata, Create metadata templates, View and edit metadata, Use keywords, Label and rate files, Batch rename files, Set metadata preferences) and *"Organize files and folders"* (Search for files and folders, Stack files, Use collections, Organize content and assets, Copy/move/delete). These are left/right **panels**; only destructive or multi-step operations (Batch Rename, Photo Downloader, workflows) open **dialogs**.
- **Where per-item options live:** right-hand **Metadata** / **Keywords** panels; transient batch operations in the **Export panel** / Quick Actions.
- **Status bar:** ⚠️ not verifiable; Bridge's conventional bottom strip carries item count, selection count and the thumbnail-size slider.

### 1.2 Capture One Pro (23/24, current 16.x)

Source: Capture One's own Help Center, via its public Zendesk API (all quotes fetched).

- **Region breakdown** — [User interface overview](https://support.captureone.com/hc/en-us/articles/360002468797-User-interface-overview): *"The main Capture One user interface elements are a Tool Tab bar, a set of Cursor tools, a Viewer, and an Image Browser."*
  - **Top:** the **top toolbar** (customizable: *"Go to View -> Customize Toolbar…"* — [Customizing toolbar](https://support.captureone.com/hc/en-us/articles/360002490858-Customizing-toolbar)) plus the **Tool Tab bar**.
  - **Centre:** the **Viewer** — *"delivers a high-quality rendition of your selected image(s)"*.
  - **Browser (filmstrip/grid):** *"displays different views of image thumbnails as well as useful functions to aid workflow including rating, naming, sorting, and more."* It is **not pinned to one side** — *"You can reposition the user interface to have the Browser or the tools on the right-hand side"* ([Customizing user interface](https://support.captureone.com/hc/en-us/articles/360002491618-Customizing-user-interface)); `View -> Customize Tools -> Place Right`.
- **Left vs right panel, and naming convention.** The convention is **not** a hard-coded "left = source / right = options" — it is **"Tool Tabs" vs "Browser/Viewer", each relocatable**. The **Tool Tabs** hold the editing tools; the **Library Tool Tab** is the catalog side: *"The Library Tool Tab is where all file navigation and organization takes place. Navigate via the hierarchical tree-view to a folder or a collection that contains the image files you wish to edit."* ([Tool Tabs: Library](https://support.captureone.com/hc/en-us/articles/360002477117-Tool-Tabs-Library))
- **Modes/workspaces — an icon rail, not a tab strip.** [Tool Tabs overview](https://support.captureone.com/hc/en-us/articles/360002480678-Tool-Tabs-overview): *"Tool Tabs are the sets of related tools… They are located at the **top-left corner** of the user interface."* EXACT names — **default:** `Library, Capture, Lens, Color, Exposure, Details, Adjustments, Metadata, Output, Batch` (10); **non-default (addable):** `Black and White, Quick, Composition`. Plus custom tool tabs. So Capture One runs **10–13 modes**, far more than Gather's 7 — and it absorbs that count with a **vertical icon rail**, not a segmented control.
  - Tools inside a Tool Tab can be **pinned or scrollable**: *"Move Tool to Pinned Area" / "Move Tool to Scrollable Area"*.
  - Workspaces themselves: `Window -> Workspace` (choose), `Window -> Workspace -> Save Workspace` (save), `Window -> Workspace -> Default` (reset) — [Saving a personal workspace](https://support.captureone.com/hc/en-us/articles/360002491798-Saving-a-personal-workspace).
  - Viewer/Browser balance: `G` toggles Viewer, `⌘B` toggles Browser; there is an **Auto (hide)** browser mode — [Workspace layouts](https://support.captureone.com/hc/en-us/articles/360002470117-Workspace-layouts).
- **Where catalog-wide management lives:** **inside a Tool Tab** (Library) — a panel, not a page and not above the grid. Catalog/Session-level operations live in the **menu bar** under their own sections — the help center has dedicated sections *"Catalogs"*, *"Sessions"*, *"Catalogs and Sessions"*, *"Keywords and Metadata"*, *"Image Processing, Export & Printing"* ([sections listing](https://support.captureone.com/api/v2/help_center/en-us/sections.json?per_page=100)).
- **Where per-item options live:** the Tool Tabs (Color / Exposure / Details / Metadata / Adjustments).
- **Status bar:** Capture One's equivalent is the **Browser's own toolbar** (rating, naming, sorting) plus the Tool Tab bar; there is no rich bottom status bar.

### 1.3 Adobe Lightroom Classic

Sources: [Lightroom Classic Help](https://helpx.adobe.com/lightroom-classic/user-guide.html) (chapter titles, verified) and The Lightroom Queen's *"Panels & Panel Groups"* (free preview text, fetched).

- **Region breakdown** — quoted: *"Down the left and right-hand sides of the screen are panel groups, each holding individual panels. **The panel group on the left always holds the Navigator or Preview panel and other sources of information—folders, collections, templates, presets,…**"* ([Lightroom Queen](https://www.lightroomqueen.com/premium-classic/workspace/panels-panel-groups))
  - **Top:** the **Top Bar** (the Module Picker is the conventional top-right element — ⚠️ position not sentence-verified). Chapter list: *The Lightroom Workspace → The Top Bar / Panels & Panel Groups / The Filmstrip / The Preview Area*.
  - **Left:** Navigator/Preview + **Catalog, Folders, Collections** (✅ verified as concepts by the tutorial chapters *Library - Catalogs*, *Library - Files & Folders*, *Library - Organizing Virtually → Collections*).
  - **Centre:** the **Preview Area** (Grid / Loupe / Survey / Compare / Book / Slideshow / Print / Web).
  - **Right:** the item tools. Verified chapter names: ✅ *Quick Develop*, ✅ *Develop module basics* + *Toolstrip & Sliders*, ✅ **Metadata Panel**, ✅ **Keyword List** (*Library - Keywords → Viewing Keywords*), ✅ **Histogram and RGB Values**.
  - **Bottom:** the **Filmstrip** (own chapter).
- **Modes** — **modules**, switched by the **Module Picker** in the top bar. Verified module set from the chapter list: **Library, Develop, Map, Book, Slideshow, Print, Web** (7). Modules are peers; each remaps *both* side panel groups and the centre.
- **Where catalog-wide management lives:** the **Library module**, in the **left panel group** + the **Library Filter bar above the grid**. Verified chapter names: *Managing Catalogs / Upgrading Your Catalog / Importing & Exporting Catalogs / Catalog Corruption*; *Managing Folders in Lightroom and on the Hard Drive*; ***Missing Files***; ***Duplicate Detection***; *Collections*; *Stacking*; *Saving Metadata to the Files*. Note **"Metadata options in Library Filters"** and **"Find photos in the catalog"** are separate chapters — filtering is a **bar above the grid**, management is a **panel**.
- **Where per-item options live:** right panel group (Quick Develop / Metadata / Keywords) and Develop's toolstrip for editing.
- **Status bar:** Lightroom Classic's bottom strip is the **Filmstrip + the toolbar below the grid** (thumbnail size, sort, filters, info overlay) — ✅ chapters *"The Filmstrip"*, *"Sort Order"*, *"Viewing Your Photos in Grid View"*.

### 1.4 darktable 4.6

Source: [screen layout](https://docs.darktable.org/usermanual/4.6/en/overview/user-interface/screen-layout/), quoted.

- **Region breakdown** — *"The layout of all darktable views is similar and consists of a center area with panels at the edges"*:
  - `center area`: *"Contains information and functionality specific to the current view."*
  - `left panel`: *"Contains modules primarily used to **provide information**."*
  - `right panel`: *"Contains modules primarily used for **image processing**."*
  - `top banner`: *"Contains information about the current darktable version and **allows you to switch between views**. Also used by some modules to show additional hints and messages."*
  - `top panel`: *"Provides access to global settings and shortcuts"*; `bottom panel`: *"Provides access to **view-specific** settings and shortcuts."*
  - `filmstrip / timeline panel`: *"An optional panel that can be enabled **at the bottom** of the screen…"*
- **Modes** — **6 views**: `lighttable, darkroom, map, print, slideshow, tethering`. Switched by *"clicking the view name at the top of the right-hand panel"* or keys L/D/M/P/S/T ([views](https://docs.darktable.org/usermanual/4.6/en/overview/user-interface/views/)). darktable's mode switch is a **text list in the top-right**, not a tab strip and not an icon rail.
- **Panel memory (the single most useful sentence in this whole report):** *"**The size and visibility of the panels are stored independently for each view.**"* Plus `Shift+Ctrl+l` / `Shift+Ctrl+r` toggle left/right, `Tab`, `F11`, and *"The left, right and filmstrip/timeline panels can be resized by dragging their inner borders."*
- **Where catalog-wide management lives:** the **lighttable view** — chapters *collections & film rolls*, *digital asset management*, *metadata and tagging*, *image grouping* ([darktable manual index](https://docs.darktable.org/usermanual/4.6/en/overview/user-interface/)). That is a **mode**, not a panel above the grid.

### 1.5 digiKam 9.2

Source: [Interface Layout](https://docs.digikam.org/en/main_window/interface_layout.html), quoted.

- **Region breakdown** — the manual enumerates the chrome: *"① Menu Bar ② Main Toolbar ③ Icon (Thumbnail) Area ④ Preview Area ⑤ Image Area = Icon + Preview Area ⑥ Left Sidebar (with tabs) ⑦ Right Sidebar (with tabs) ⑧ Status Bar ⑨ Buttons: Navigation, Rotation, Face Tags, Full Frame"*, and: *"The Image Area in the center is surrounded by the menu bar ① and the Main Toolbar ② at the top, the Status Bar ⑧ at the bottom, as well as the Left Sidebar ⑥ and Right Sidebar ⑦."*
- **Left vs right, and the naming convention** — **exact names**, and this is the cleanest "left = source / right = properties" statement of any app here:
  - **Left Sidebar** — *"lets you switch between **nine 'Views'**: Albums (shown here), Tags, Labels, Dates, Timeline, Search, Similarity, Map and People."* → [Left Sidebar](https://docs.digikam.org/en/left_sidebar.html)
  - **Right Sidebar** — *"can be used to show information about your images, to apply filters to select images, and to select actions to be applied to selected images."* Tabs: **Properties, Metadata, Colors, Maps, Captions, Versions, Filters, Tools** → [Right Sidebar](https://docs.digikam.org/en/right_sidebar.html)
  - *"You can collapse or expand the sidebar areas by clicking on the sidebar tabs."*
- **Modes:** digiKam has **no mode switch** — one window, and "modes" are the **left sidebar's nine Views**. The Main Toolbar carries launch actions instead: *"Open Image Editor…, Open Light Table L, Open Batch Queue Manager B, Import (drop down…), Switch to thumbnail view, Toggle preview…, Switch to map view, Switch to configurable table view, Slideshow drop down menu, Toggle Full Screen…"* — customizable via `Settings ‣ Configure Toolbars…`.
- **Where catalog-wide management lives:** **left sidebar**, plus separate application-level windows launched from the toolbar (Light Table, Batch Queue Manager, Maintenance Tools). *"Digital Asset Management"* and *"Maintenance Tools"* are their own manual chapters.
- **Status bar — EXACT contents** (the most explicit status-bar spec in this report): *"The file name when selecting a single file. Selection information when several items are selected. Quick filters: Information on how many filters are active. A trash bin button to reset all active filters. A funnel button to open the filter settings panel. A progress bar for batch processes, such as assigning tags or rebuilding fingerprints. A thumbnail and preview image size slider with buttons for 'Fit to Window' and 'Zoom to 100%'. A size selection pop up list measured in % for the preview image."*

---

## 2. Rules that generalise

1. **Content stays put; options live in side panels.** The centre region is the largest region in every app, and nothing settable sits on top of it. — darktable (`center area` vs `left panel`/`right panel`), digiKam (Image Area vs the two sidebars), Capture One (Viewer vs Tool Tabs), Bridge (Content panel vs Metadata/Keywords), Lightroom (Preview Area vs panel groups).
2. **Left = where content comes from; right = what you do to it.** — darktable states it outright (left = *provide information*, right = *image processing*); digiKam states it outright (left = 9 navigation Views; right = *"information about your images… filters… actions"*); Lightroom states it outright (*"the panel group on the left always holds the Navigator or Preview panel and other sources of information"*). **Capture One is the deliberate exception** — both sides are relocatable (`View -> Customize Tools -> Place Right`) — but the source/tools *split* still holds.
3. **Never put catalog management above the content.** Collections, smart albums, metadata reconciliation, missing/offline files are always a **panel** or a **menu section**, never a strip of cards over the grid. — Bridge (whole "Organize and find files" chapter group), Lightroom (left panel group; *Missing Files*, *Duplicate Detection* are chapters, not banners), Capture One (Library Tool Tab), digiKam (left sidebar + Maintenance Tools), darktable (lighttable view).
4. **A filter bar above the grid is not "management".** Lightroom Classic legitimately owns a **Library Filter bar** directly above the thumbnails; Bridge has a **Filter panel** on the right. What no app does is put *rules, catalogs or reconciliation* there. — Lightroom ("Metadata options in Library Filters"), Bridge (Filter panel).
5. **The toolbar holds mode + transient actions only.** Every app's top strip is mode switching plus one-shot verbs (import, export, refresh, view toggles). Browse options and filter values are never in it. — Bridge (workspace switcher + path/search), Capture One (toolbar is *customizable icons*; the Tool Tab bar is separate), digiKam (Main Toolbar = launch actions only), darktable (top banner = view switch; top panel = global settings).
6. **Use ≤5 same-level modes in a horizontal switcher, or escalate to an icon rail / vertical list.** Lightroom (7 modules) and Capture One (10–13 tool tabs) both go **vertical** once the count grows; darktable's 6 views become a **text list in the top-right**. — Capture One (rail at the top-left corner), Lightroom (Module Picker), darktable (view names in the right panel).
7. **Options belong to the item; status belongs to the whole app.** Per-item settings live in the right panel; process/task state is global and always visible. — digiKam (status bar: *"A progress bar for batch processes, such as assigning tags or rebuilding fingerprints"*), Capture One (process indicator), Bridge (thumbnail-generation progress).
8. **Terminal/one-shot workflows are not peers of browsing modes.** Export is a **panel** (Bridge: "Export panel"), a **Tool Tab** (Capture One: `Output`), or a **dialog** (Lightroom's Export dialog) — never a sibling tab of "Library". — Bridge, Capture One, Lightroom.
9. **Panel visibility and size are user-controlled, collapsible, and remembered — per view.** — darktable: *"The size and visibility of the panels are stored independently for each view"*; digiKam: *"You can collapse or expand the sidebar areas by clicking on the sidebar tabs"*; Capture One: pinned vs scrollable areas inside a Tool Tab.
10. **The status bar carries: selection count, active-filter count + clear, batch progress, zoom/size.** It is the one region that survives every mode change. — digiKam (explicit list above), darktable (filmstrip/timeline + bottom panel), Bridge/Lightroom (thumbnail-size slider).

---

## 3. Concrete restructure proposal for Gather

### 3.0 Live-state correction (read this first)

The brief describes the tree as having *"NO right inspector panel anywhere"* and four cards on the Library page. **That is no longer true in the working tree.** As of this session, `LibraryView.swift:87`, `GalleryView.swift:103` and `CullingView.swift:1536` already call `.inspector(isPresented:)` + `.inspectorColumnWidth(min:ideal:max:)`; the four Library cards have already moved into a `libraryInspector`; and `CullingView`'s 214 pt tool column is gone (`workbench` is now viewer + right filmstrip). `docs/reviews/layout-restructure.md` documents that work. **So §3.1–§3.2 below are "confirm and finish", and §3.3–§3.4 is where the genuinely open work is: the 7-way segmented control, the missing shell-level status bar, and the four session pages that still have no inspector.**

### 3.1 The seven session pages — MERGE / DEMOTE / KEEP

| Page | Verdict | Region it belongs in | Why |
| --- | --- | --- | --- |
| **浏览 (Gallery)** | **KEEP** as a mode | Detail + right inspector | A browsing view. Its options (筛选 / 显示) are already correctly demoted to the inspector. This is the Lightroom "Library module" / Bridge "Essentials" analogue. |
| **挑片 (Culling)** | **KEEP** as a mode | Detail + **bottom** filmstrip + right inspector | A browsing *and decision* view — it belongs next to 浏览, not next to 相似度. Decision buttons/star/colour are already correctly demoted to the inspector. **Its filmstrip must move from the right to the bottom** (§3.4). |
| **相似度 (Similarity)** | **KEEP** as a mode | Detail + right inspector | A genuine analysis view with its own canvas (groups/clusters). Give it an inspector for thresholds/actions instead of a toolbar row. |
| **人脸 (Face)** | **KEEP**, but grouped | Detail + right inspector | Analysis. Keep the page, but it should not be a same-weight peer of 浏览 in a flat strip. Group with 重复 under one "分析" entry. |
| **重复 (Duplicates)** | **MERGE** | Fold into 人脸's group as "分析 ▸ 重复" | It is the same *kind* of thing as 人脸 (an analysis result to review) and shares the same shape (review list + per-item actions). Rule 6: >5 same-level modes must stop being a flat horizontal strip. |
| **控制中心 (Control center)** | **DEMOTE** | Sidebar — the landing page of **当前会话** | It is session *status and progress*, not a view of photos. `RootNavigation.openSession(_:)` already lands there, and the sidebar already has a 当前会话 row. Rules 4/7: status is not a mode. |
| **导出 (Export)** | **DEMOTE** | Toolbar button → **sheet** | Rule 8. A long grouped `Form` of one-shot options is exactly Lightroom's Export dialog / Bridge's Export panel. It must not be a peer of 浏览. Present it as a sheet from a toolbar `Button`, prefilled from the current selection. |

**Net effect on the segmented control: 7 → 3.**

```
浏览 | 相似度 | 挑片          [分析 ▾]        [导出…]   [任务 ●3]
                         人脸 / 重复
```

⚠️ **Constraint:** `SessionTab.allCases.map(/.rawValue) == ["control","face-kw","duplicates","culling","export"]` is a live test contract (`GatherAppTests/RootViewTests.swift:69`). Every change above is **presentation-layer only** — keep the enum and its order; change only which items are rendered where, and route the demoted ones through the existing `openSessionTab` entry points.

### 3.2 Dashboard and Library

| Surface | Verdict | Region |
| --- | --- | --- |
| **工作台 — 统计条 + 工作区列表** | **KEEP** as a sidebar destination; content as detail | The Dashboard *is* Gather's Home: a destination, not a mode. |
| **工作台 — 任务中心 (task centre)** | **DEMOTE** | Shell toolbar (global status indicator + popover) | Rule 7 + the digiKam status-bar precedent. Task progress is currently visible only on the Dashboard even though culling/export/gallery run real background jobs. |
| **工作台 — 已完成历史 disclosure** | **DEMOTE** | Same toolbar popover, as a "已完成" section | Collapsible secondary information; it does not deserve a quarter of the Home screen. |
| **全局图库 — the FOUR capability cards** | **ALREADY DEMOTED → right inspector "资料库"** | Right inspector, 4 `Section`s: 智能相册 / RAW·JPEG 资产关联 / 孤立 XMP / 离线存储卷 | Rule 3, stated most directly. Confirm this landed and do not regress it. This is the single most valuable fix in the whole restructure: it removes ~200 pt of non-browsing chrome from a ~780 pt page and deletes the "four fixed-width cards, hidden scrollbar, last card off-screen at minimum width" defect. |
| **全局图库 — filter row (星级/颜色/在线状态)** | **KEEP**, thin, directly above the grid | Content, above grid | Rule 4: Lightroom's **Library Filter bar** precedent. A view control on the content, not management. |
| **全局图库 — 更多筛选 disclosure** | **DEMOTE** | Right inspector "筛选" `Section` | A `DisclosureGroup` that pushes the grid down is a panel that refuses to be a panel. |
| **全局图库 — pagination bar** | **MOVE** | Shared bottom status bar | Rule 10 — count/selection/pagination are status, and status should be in the same place on every page. |
| **全局图库 — 状态行 (statusBar)** | **MOVE** | Shared bottom status bar | Same. |

### 3.3 Target window anatomy

```
┌──────────────┬────────────────────────────────────────────────┬──────────────────┐
│ 边栏 180–300  │  内容区 (detail)                                │  检查器 280–420   │
│              │  ┌ 页内工具行（筛选条 / 胶片条控制，可选、细）────┐  │                  │
│  ▸ 工作台     │  │                                                │  │  随页面切换：     │
│  ▸ 当前会话   │  │            内容本体                             │  │   浏览 → 筛选/显示 │
│  ▸ 全局图库   │  │      照片网格 / 查看器 / 相似组                  │  │   挑片 → 决策/星级 │
│              │  │                                                │  │   图库 → 资料库   │
│  ──────────  │  └────────────────────────────────────────────────┘  │   相似度 → 阈值   │
│  会话模式     │  ── 底部状态条：计数 · 选中 · 筛选N · 分页 · 进度 · 缩放 ──     │   分析 → 参数     │
│   浏览        │                                                    │                  │
│   相似度      │                                                    │                  │
│   挑片        │                                                    │                  │
│   分析 ▸      │                                                    │                  │
└──────────────┴────────────────────────────────────────────────────┴──────────────────┘
工具栏: [返回] │ [窗口标题/副标题] │ [模式] │ ……… │ [分析▾] [导出…] [任务 ●] [刷新] [设置]
```

Rules the target obeys: the centre column holds only content; every page has exactly one inspector; every page has exactly one bottom status bar rendered by the shell; the toolbar carries mode + transient actions + global status only; the sidebar holds destinations, not modes.

### 3.4 Three concrete follow-ups the current tree still needs

1. **挑片's filmstrip must move to the bottom.** With an inspector now on the right, a right-hand filmstrip gives Gather **two competing right columns** and squeezes the viewer asymmetrically. Bridge, Lightroom and darktable all put the filmstrip at the **bottom**; only Capture One puts a Browser column at the side, and Capture One has *no* right inspector — it puts the tools on that same side. Pick bottom.
2. **One shell-level bottom status bar** (`.safeAreaInset(edge: .bottom)` on the detail column), modelled literally on digiKam's spec: selection count, active-filter count + clear, batch progress, zoom/size, and pagination on the Library page.
3. **A global task indicator in the toolbar** (running count + popover), so 任务中心 can leave the Dashboard.

---

## 4. SwiftUI implementation notes (macOS 14+, macOS 26 Liquid Glass)

### 4.1 `.inspector(isPresented:content:)` vs `.inspectorColumnWidth(...)`

| API | Availability (verified from Apple's docs JSON) | Declaration |
| --- | --- | --- |
| [`inspector(isPresented:content:)`](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)) | **macOS 14.0**, iOS 17.0, iPadOS 17.0, Mac Catalyst 17.0 | `nonisolated func inspector<V>(isPresented: Binding<Bool>, @ContentBuilder content: () -> V) -> some View where V : View` |
| [`inspectorColumnWidth(min:ideal:max:)`](https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)) | **macOS 14.0**, iOS 17.0, iPadOS 17.0, Mac Catalyst 17.0 | `nonisolated func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View` |
| [`inspectorColumnWidth(_:)`](https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(_:)) | **macOS 14.0**, iOS 17.0, iPadOS 17.0, Mac Catalyst 17.0 | `nonisolated func inspectorColumnWidth(_ width: CGFloat) -> some View` |

- They are **not alternatives** — they stack. Apple: *"Apply this modifier **on the content of an** `inspector(isPresented:content:)` to specify a preferred flexible width for the column. Use `inspectorColumnWidth(_:)` if you need to specify a fixed width."* And: *"Only some platforms enable flexible inspector columns. If you specify a width that the current presentation environment doesn't support, SwiftUI may use a different width for your column."* → **the width modifier goes inside the inspector closure, never on the outer view.** Gather already does this correctly.
- Because both are **macOS 14.0**, with the app's stated macOS 14+ target **no `#available` gate is needed**.
- Presentation: *"an inspector can present as a trailing column in a horizontally regular size class, but adapt to a sheet in a horizontally compact size class."* On a full-size macOS window it is always a trailing column.
- To stop the user collapsing it by dragging: Apple's own sample pairs it with `.interactiveDismissDisabled()` — `TextTraitsInspectorView().inspectorColumnWidth(225).interactiveDismissDisabled()`. Use that only for an always-on inspector (e.g. Library's 资料库); leave the others collapsible.

### 4.2 Interaction with `NavigationSplitView`

- `NavigationSplitView` is macOS 13.0+ and is a **2- or 3-column** container ([docs](https://developer.apple.com/documentation/swiftui/navigationsplitview)). The inspector is a **separate, trailing presentation** — it does **not** occupy the `content` column and is **not** part of [`NavigationSplitViewVisibility`](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility) (macOS 13.0+; "the visibility of the **leading** columns").
- **Apply `.inspector` inside the `detail` closure**, not on the `NavigationSplitView` itself. Applied to the split view it fights the sidebar's own trailing edge; applied to the detail it becomes the fourth column to the right of the detail. Gather's current placement (LibraryView / GalleryView / CullingView, all inside `RootView`'s detail) is correct.
- Consequence to design around: **the sidebar toggle (⌘⌥S) and the inspector toggle are independent.** `RootView` flips `columnVisibility` between `.all` and `.detailOnly`; that does nothing to the inspector. Users will expect a symmetric pair — give the inspector a menu command too, and make sure the two do not both claim ⌘⌥S.
- Because the inspector is declared by the page that owns it, **each page owns its own inspector instance**. That is what makes per-page memory possible (§4.3), and it is why `.id("session-tab-\(sessionId)-\(tab)")` in `RootView` destroys and recreates the inspector on tab change.

### 4.3 Remembering visibility and width

- **Toolbar toggle:** the show/hide control is **provided by the system** — you do not author a `ToolbarItem` for it. (Apple's docs describe the presentation, not the chrome; this is the platform behaviour Gather already relies on, per the comments at `GalleryView.swift:83` and `LibraryView.swift:38`.) Do not add your own toggle next to it, or the toolbar gets two.
- **Visibility — persist it per page.** darktable is the reference behaviour: *"The size and visibility of the panels are stored independently for each view."* The Windows/XAML convention agrees that this is **app-managed state**, not platform-managed: `NavigationView` exposes `IsPaneOpen` / `OpenPaneLength` / `PaneDisplayMode` and the app is responsible for saving them ([NavigationView](https://learn.microsoft.com/en-us/windows/apps/design/controls/navigationview)). Microsoft's layout guidance adds *why* the pane is chrome and not content: *"NavigationView controls automatically rests on the app's **base layer**. This brings more focus to the content area's primary task."* ([page layout](https://learn.microsoft.com/en-us/windows/apps/design/layout/page-layout))
  → Concretely: **replace `@State private var showInspector = true` with `@SceneStorage("inspector.browse")` etc., one key per page** (browse / culling / similarity / library / faces / duplicates). `@State` alone resets on every navigation rebuild and every new window, which is exactly what "remembered" must not mean. Microsoft also encodes the *adaptive* half: `PaneDisplayMode="Auto"` moves `LeftMinimal → LeftCompact → Left` on `CompactModeThresholdWidth` / `ExpandedModeThresholdWidth`; the SwiftUI equivalent is to let the inspector collapse first on a narrow window.
- **Width — do not hand-roll.** Declare a range with `.inspectorColumnWidth(min:ideal:max:)` and let the system own the live drag width; if you write your own width into `@AppStorage` and feed it back as a fixed `.inspectorColumnWidth(_:)` you lose the flexible column, and Apple explicitly warns the environment *"may use a different width"*. If you must remember a width, read the user-resized value only to *seed* the `ideal` on first launch.
- **Real bug to respect (found in this codebase):** `Form(.grouped)` inside `.inspector` crashed `LibraryView` with `EXC_CRASH (SIGABRT)` — an Objective-C exception thrown by AppKit inside `__NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke` during constraint update. The same `Form` in the Culling inspector was fine, so it is a *combination* of `Form` + fixed-width children inside the inspector's scroll container. Library's inspector uses `ScrollView` + card grouping instead. **Never ship a new `.inspector` without running that page on device.**

### 4.4 Is there a native macOS "tool tab / icon rail"?

- **On macOS 15+ there is a first-class one:** [`TabViewStyle.sidebarAdaptable`](https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable) is macOS 15.0+ / iOS 18.0+ — *"A tab bar style that adapts to each platform"* — used with the new [`Tab`](https://developer.apple.com/documentation/swiftui/tab) value type (macOS 15.0+): *"The content for a tab and the tab's associated tab item in a tab view."* On Mac it renders tabs into the sidebar/toolbar region; `.tabBarOnly` gives a horizontal strip. That is the closest native analogue to Capture One's Tool Tab bar.
- **On a macOS 14 deployment target it is not available.** So the honest answer for Gather is: **there is no native macOS *icon-rail* control** below macOS 15. Do **not** hand-build one — Capture One's rail works because it carries 10+ items with a pinnable/scrollable tool model; Gather has 3–5 modes.
- **Recommendation for Gather (macOS 14+):** use a plain segmented `Picker` in the toolbar for the ≤5 same-level modes (that is what `SessionTabBar` does today and it is the right call), and use `List(...).listStyle(.sidebar)` **only** for the sidebar destinations (工作台 / 当前会话 / 全局图库). If the target later moves to macOS 15+, migrate `SessionTabBar` to `TabView(selection:) { Tab(...) } .tabViewStyle(.sidebarAdaptable)` — but note that puts modes in the **sidebar**, which collides with Gather's existing sidebar semantics; `.tabBarOnly` is the safer swap for a top strip. **Do not** put a `Picker` inside a `List` to fake an icon rail.

### 4.5 macOS 26 Liquid Glass

- [`.glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) is **macOS 26.0+** (iOS/iPadOS/tvOS/watchOS/visionOS 26.0): *"Applies the Liquid Glass effect to a view."* Gate it: `if #available(macOS 26.0, *) { … }`.
- **Do not apply it to the shell.** Sidebar, toolbar and inspector already receive the system glass treatment on macOS 26; hand-applying `glassEffect` on top produces doubled, muddy material and breaks the automatic toolbar/inspector merging that makes the toggle button look native. Reserve it for **custom floating controls on top of media** — Gather's Culling conflict panel (`CullingView`'s bottom-trailing overlay) and the toast overlay are the two legitimate candidates.
- Keep the existing semantic-colour discipline: on photo backgrounds, colours must come from semantic roles, not hand-picked hexes, or the glass will not adapt between light and dark and increased contrast.

---

## Fetched URLs

**Adobe**
- https://helpx.adobe.com/bridge/user-guide.html
- https://helpx.adobe.com/bridge/desktop/workspaces-and-panels/overview-of-the-workspace.html
- https://helpx.adobe.com/bridge/desktop/workspaces-and-panels/customize-the-workspace.html
- https://helpx.adobe.com/bridge/desktop/workspaces-and-panels/adjust-panels.html
- https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/use-collections.html
- https://www.adobe.com/products/bridge.html
- https://helpx.adobe.com/lightroom-classic/user-guide.html
- https://helpx.adobe.com/lightroom-classic/desktop/workspace/workspace-basics.html

**Capture One**
- https://support.captureone.com/hc/en-us/articles/360002468797-User-interface-overview
- https://support.captureone.com/hc/en-us/articles/360002480678-Tool-Tabs-overview
- https://support.captureone.com/hc/en-us/articles/360002477117-Tool-Tabs-Library
- https://support.captureone.com/hc/en-us/articles/360002470117-Workspace-layouts
- https://support.captureone.com/hc/en-us/articles/360002491618-Customizing-user-interface
- https://support.captureone.com/hc/en-us/articles/360002491798-Saving-a-personal-workspace
- https://support.captureone.com/hc/en-us/articles/360002490858-Customizing-toolbar
- https://support.captureone.com/api/v2/help_center/en-us/sections.json?per_page=100
- https://support.captureone.com/api/v2/help_center/en-us/sections/360000860038/articles.json?per_page=100

**darktable**
- https://docs.darktable.org/usermanual/4.6/en/overview/user-interface/
- https://docs.darktable.org/usermanual/4.6/en/overview/user-interface/screen-layout/
- https://docs.darktable.org/usermanual/4.6/en/overview/user-interface/views/

**digiKam**
- https://docs.digikam.org/en/main_window.html
- https://docs.digikam.org/en/main_window/interface_layout.html
- https://docs.digikam.org/en/left_sidebar.html
- https://docs.digikam.org/en/right_sidebar.html

**Lightroom Queen**
- https://www.lightroomqueen.com/premium-classic/workspace/panels-panel-groups
- https://www.lightroomqueen.com/category/lightroom-classic-tutorials/workspace/
- https://www.lightroomqueen.com/panels-gone/

**Apple**
- https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)
- https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)
- https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(_:)
- https://developer.apple.com/documentation/swiftui/navigationsplitview
- https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility
- https://developer.apple.com/documentation/swiftui/tab
- https://developer.apple.com/documentation/swiftui/tabviewstyle
- https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/design/human-interface-guidelines/windows

**Microsoft**
- https://learn.microsoft.com/en-us/windows/apps/design/controls/navigationview
- https://learn.microsoft.com/en-us/windows/apps/design/layout/page-layout
- https://learn.microsoft.com/en-us/windows/apps/design/layout/app-window

**Reachable but unusable (client-rendered body / Cloudflare), recorded for honesty**
- https://support.apple.com/guide/photos/photos-at-a-glance-pht0d0fba6d9/mac (200; body JS-rendered, so Apple Photos is not cited above)
- https://helpx.adobe.com/bridge/desktop/workspaces-and-panels/overview-of-the-workspace.html (200; article body beyond the fetch ceiling)
- https://support.captureone.com/hc/en-us/articles/360002543358 (Cloudflare 403 on the HTML page; the Zendesk JSON API works)
- Search engines (Bing HTML/RSS, Baidu, Yandex, DuckDuckGo, SearxNG instances) were unusable in this environment — 401, captcha, geo-degraded results, or DNS failures. All sources above were reached by direct URL.
