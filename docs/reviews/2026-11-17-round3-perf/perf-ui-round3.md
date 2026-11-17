# Round3 GatherUI 渲染/性能加固（task-17 / perf-ui）

- 日期：2026-11-17（评审目录 2026-11-17-round3-perf）
- 基线：`42a89e01` + 同伴未提交的 round-3 改动（本 agent 未触碰其他 agent 的文件：Support/PhotoThumbnailView.swift、Support/ThumbnailDiskCache.swift、GatherHost/AppBootstrap、core 服务均未编辑）
- 写作用域：`desktop/native/gather-app/Sources/GatherUI/Culling/**`、`.../Gallery/**` + 本文档
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode → **未编译、未运行、无 Instruments**。Swift 6.2 toolchain 仅做 `-parse`；性能/语义证据来自 `.gather/` 下的独立 Linux 探针（swift-corelibs Foundation + 真实 `GatherProtocol` 类型），**不是 macOS 实测**。
- 约束遵守：无用户可见文案/布局/行为变化；无新增 `@unchecked Sendable`（cleanup ratchet 60/60）；未改 design-system baseline / en.lproj；未 git commit。

## 0. 摘要

| # | 修复 | 位置 | 证据 |
|---|------|------|------|
| P0 | `CullingViewModel.selectionSummary` 增加 (pageVersion, selectionVersion) O(1) 缓存；**getter 无条件读 `selectedPhotoIds`** 保证 Observation 依赖 | `CullingViewModel+Actions.swift:605-642`、`CullingViewModel.swift:40-44,216-224` | 800 组随机操作序列对拍 OK；Observation 探针：修复前缓存命中不触发 onChange，修复后触发 |
| P0 | 暴露 O(1) 页索引 helper（`pageIndex(ofPhotoId:)` / `pageAsset(forPhotoId:)` / `currentPageIndex()`），替换 11 处逐帧/逐键 O(page) 查找 | `CullingViewModel.swift:190-214` + 6 个 Culling 文件 | 语义探针 PAGE_INDEX_SEMANTICS_OK；Linux 500 张页 18 次查找 18.79µs → 0.71µs（约 26x） |
| P1 | 预取缓存探测（含磁盘 stat/读整张 JPEG）移出主线程 | `CullingViewModel+Preload.swift:242-268,179-194` | 结构分析 + 语义不变（best-effort 预取）；见 §4 |
| P1 | Gallery：`id→文件名` / id/路径/变体集合 / filtered id→首下标 三套 O(1) 查询表；替换定位循环、nameFor、键盘游标、灯箱打开 | `GalleryViewModel+Derived.swift:39-172`、`GalleryViewModel.swift:338-345`、+Scroll/+Events/+Inspector/+Content | 600 组随机照片集对拍 OK |
| P1 | 灯箱 `currentPhoto/currentIndex` 由每帧 O(n)×2 改 O(1)（indexByID + onChange 重建 + 滞后回退） | `Gallery/LightboxView.swift:23-66,90-99,330-366` | 探针覆盖重复 id/缺 id/刷新后丢 id |
| P2 | 其余 O(page) 命中点（`selectCurrent`、单张提交、`nextPhotoId`、前进/后退、⇧范围、导航组文件名、场景标签 nameFor 等）改走索引 helper | 见 §2 表 | 语义探针 + 行为对拍 |

改动 16 个文件：+311/−94 行（`git diff --stat`）。

## 1. P0：selectionSummary 缓存（含 Observation 依赖修复）

### 1.1 旧实现
```swift
// CullingViewModel+Actions.swift（旧）
public var selectionSummary: SelectionSummary? {
    guard !selectedPhotoIds.isEmpty, let assets = page?.assets else { return nil }
    let selected = assets.filter { selectedPhotoIds.contains($0.photo.id) }
    guard !selected.isEmpty else { return nil }
    return SelectionSummary(selectedCount: selectedPhotoIds.count, loadedCount: selected.count,
        ratings: Set(selected.map { Int($0.state.rating) }), colorLabels: Set(selected.map(\.state.colorLabel)))
}
```
`CullingInspector` body 每帧仍直接读 1 次 + `colorSelectionBinding` getter 1 次（round-2 已把 body 内 3→1）⇒ 每次渲染 2 次 O(page) filter + 2 个 Set。

### 1.2 新实现
- 失效键（都是 O(1) 单调计数器）：
  - `pageVersion`：round-2 审计过 7 处生产 page 赋值点全部 bump；`page.didSet` 另外清空本缓存（测试/未来直接赋值兜底）；
  - `selectionVersion`：`selectedPhotoIds` 新增 `didSet { selectionVersion &+= 1 }`。**已用 Swift 6.2 探针验证** @Observable 属性上的 Set 变更（`insert/remove/removeAll/formIntersection/subtract/赋值`）都会触发 didSet（输出 1..7 逐个递增）。
- getter（`CullingViewModel+Actions.swift:619-642`）：
```swift
public var selectionSummary: SelectionSummary? {
    // Observation 依赖（必须无条件读）：缓存命中也要读 selectedPhotoIds / pageVersion，
    // 否则 SwiftUI body 不会在"只改选择集"时重算摘要（selectionVersion 是 @ObservationIgnored 的纯缓存键）。
    let selectionCount = selectedPhotoIds.count
    if let cached = selectionSummaryCache,
       cached.pageVersion == pageVersion,
       cached.selectionVersion == selectionVersion { return cached.summary }
    ...（原计算逻辑，selectedCount 用 selectionCount）...
    selectionSummaryCache = SelectionSummaryCache(pageVersion: pageVersion,
        selectionVersion: selectionVersion, summary: summary)
    return summary
}
```
- 缓存结构 `SelectionSummaryCache` 与存储 `@ObservationIgnored var selectionSummaryCache` 分别声明在 +Actions extension 与主类体（跨文件 nested type 引用已用 Swift 6.2 独立探针验证可编译）。

### 1.3 Observation 依赖证明（探针实测）
用 `withObservationTracking` 对两个版本做 A/B（Linux Swift 6.2）：
```
with unconditional read（修复后）: onChange fired = true | value after mutation = 10
without unconditional read（旧式 cache-first）: onChange fired = false
OBSERVATION_DEPENDENCY_OK
```
结论：**只读 `selectedPhotoIds.count` 这一句就足以注册依赖**；缓存命中路径不再"什么都不读"。`pageVersion` 在条件判断里恒被读取 ⇒ 页变化同样被观察。两路依赖 + O(1) 缓存键并存。

### 1.4 输出等价证明
- 800 组随机操作序列（页替换含"bump / 不 bump 直接赋值"两种、选择集赋值/insert/remove/removeAll/formIntersection/subtract、跨页 ghost id），每组比较"旧纯计算"与"新缓存 getter"（并二次读取验证命中路径）：
  `SELECTION_SUMMARY_CACHE_OK (800 randomized op sequences)`
- 输出结构不变（selectedCount/loadedCount/ratings/colorLabels；不含顺序语义）。

## 2. P0：O(1) 页索引 helper + 替换清单

### 2.1 helper（CullingViewModel.swift:190-214）
```swift
func pageIndex(ofPhotoId:) -> Int?      // nil = 无页/不在页；重复 id 取首个（与 firstIndex 同义）
func pageAsset(forPhotoId:) -> CullingAsset?   // nil = 无页/不在页
func currentPageIndex() -> Int?         // 无页/空页 → nil；id 空/不在页 → 0（查看器既有口径）
```
复用 round-2 的 `PageAssetIndex`（pageVersion 命中 + page.didSet 失效），不新增类型。

### 2.2 替换点（全部保持 nil/0 回退语义）

| 文件:行 | 旧 | 新 |
|---|---|---|
| `Culling/CullingSecondDisplay.swift:191-194` | 私有 `currentAsset` 线性扫描 | 直接 `viewModel.currentAsset`（同一语义，VM O(1)） |
| `CullingSecondDisplay.swift:295-299` | `assets.firstIndex` | `viewModel.currentPageIndex() ?? 0` |
| `CullingWorkbenchViewer.swift:197-202` | `assets.firstIndex` | `viewModel.currentPageIndex() ?? 0` |
| `CullingWorkbenchViewer.swift:669-671` | `assets.first(where:)`（参考图） | `viewModel.pageAsset(forPhotoId:)` |
| `CullingWorkbenchViewer.swift:1074-1078` | `assets.first(where:)`（细节贴片） | `viewModel.pageAsset(forPhotoId:)` |
| `Culling/CullingInfoBar.swift:238-242` | `page?.assets.firstIndex` | `viewModel.currentPageIndex() ?? 0` |
| `Culling/CullingInspector.swift:229-233` | 场景标签 `page?.assets.first` | `viewModel.pageAsset(forPhotoId:)` |
| `Culling/CullingViewModel+Navigation.swift:340-342` | `page?.assets.first` | `pageAsset(forPhotoId:)` |
| `Culling/CullingViewModel+Grid.swift:52-56` `currentLoadedIndex` | `assets.firstIndex` | `pageIndex(ofPhotoId:)` |
| `CullingViewModel+Grid.swift:144-146,165-168` | startsWith contains | `pageIndex(ofPhotoId:) != nil` |
| `CullingViewModel+Grid.swift:153-156` ⇧ 范围两端 | 2× `firstIndex` | 2× `pageIndex(ofPhotoId:)` |
| `CullingViewModel+Actions.swift:146-148` 组前进 | `firstIndex` | `pageIndex(ofPhotoId:)` |
| `CullingViewModel+Actions.swift:249-251` 单张 before 快照 | `page?.assets.first(where:)` | `pageAsset(forPhotoId:)` |
| `Actions.swift:494-496` 单张提交 | `page?.assets.first(where:)` | `pageAsset(forPhotoId:)` |
| `Actions.swift:649-651` `nextPhotoId` | `firstIndex` | `pageIndex(ofPhotoId:)` |
| `Actions.swift:658-661,681-683,697-699` 前进/后退 | 3× `firstIndex` | `pageIndex(ofPhotoId:)` |
| `Actions.swift:659-661` `selectCurrent` 存在性 | `contains(where:)` | `pageIndex(ofPhotoId:) != nil` |
| `Culling/CullingViewModel+Preload.swift:60-84` 预取计划 | 静态 `firstIndex` | 新增 `plan(assets:currentPhotoIndex:radius:)` 重载；VM 热路径传 `currentPageIndex()`，旧入口保留给单测（行为不变） |

### 2.3 语义/性能证据（Linux，真实 `CullingAsset/CullingPage`）
```
PAGE_INDEX_SEMANTICS_OK
  cases: nil page / empty page / id 命中 / id 缺失 / 重复 id 取首个 /
         currentPhotoId 为空（→0）/ 不在页（→0）/ 直接赋值 page 不 bump（didSet 失效）
old: 18x firstIndex(where:) 500: 18.790 us/call
new: 18x pageIndex 500 (cache hit): 0.710 us/call     // 约 26x
```
注：`currentPageIndex()` 在无页时返回 nil，所有视图调用点保持 `?? 0` ⇒ 与旧 `guard ... else return 0` 等价（探针逐案对拍）。

## 3. Gallery：O(1) 查询表

### 3.1 新增（`GalleryViewModel+Derived.swift:39-172`、`GalleryViewModel.swift:338-345`）
- `GalleryLoadedPhotoLookup`：`ids / filepaths / variantIDs / variantFilepaths / filenamesByID`，与 `pagesGeneration` 同代数**懒构建**（`@ObservationIgnored loadedPhotoLookupCache`）。
- `filteredCache` 扩为 `(key, photos, ids, indexByID)`：`filteredPhotoIdSet` / `filteredPhotoIndexByID` 与 filteredPhotos **同一缓存 key**；`indexByID` 重复 id 取首个（与 `firstIndex(where:)` 同义）。
- `import Observation` 加入 GalleryViewModel.swift（`@ObservationIgnored` 需要；该文件此前仅 Foundation+GatherProtocol）。

### 3.2 替换点

| 文件:行 | 旧 | 新 |
|---|---|---|
| `Gallery/GalleryViewModel+Scroll.swift:63-88` `locatePendingPhoto` 取页循环 | 每轮 2 次 `loadedPhotos.contains { ... }` O(n) | `loadedPhotoLookup` 的 id/path/变体集合 O(1)（语义：任一行 id 或 path 命中，集合等价） |
| `Gallery/GalleryInspector.swift:210-212,226-228` 两个 `nameFor` | 逐行 `loadedPhotos.first(where:)` | `loadedPhotoLookup.filenamesByID[id] ?? id`（重复 id 取首个文件名） |
| `GalleryInspector.swift:257-259` `alreadyVisible` | `filteredPhotos.contains` O(n) | `filteredPhotoIdSet.contains` O(1) |
| `Gallery/GalleryViewModel+Events.swift:100-102` | `formIntersection(loadedPhotos.map(\.id))`（临时数组） | `formIntersection(loadedPhotoIdSet)` |
| `GalleryView+Content.swift:331-345` `moveGalleryCursor` 锚点/起点 | `photos.first(where:)` + `firstIndex` ×2 | `selectedIds.compactMap{indexByID[$0]}.min()`（= 首个可见选中项）+ `indexByID` |
| `GalleryView+Content.swift:355-372` `toggleGalleryCursor` | `photos.contains(where:)` ×2 | `filteredPhotoIdSet.contains` ×2 |
| `GalleryView+Content.swift:374-383` `openGalleryCursor` | `photos.firstIndex(where:)` | `filteredPhotoIndexByID[id]` |
| `GalleryView+Content.swift:384-392` `openSelectedInLightbox` | `first(where:)+firstIndex` | 选中 id 的 filtered 最小下标（O(1) 查表） |
| `Gallery/LightboxView.swift` `currentPhoto/currentIndex` | 每帧 `photos.first` + `photos.firstIndex`（缩放/平移期间逐帧） | `@State indexByID`（init/onChange 重建）+ 滞后回退一次线性查找；`prefetchAdjacent` 直接接收已解析下标 |

### 3.3 语义证据（600 组随机照片集，含重复 id/重复路径/多 variant/随机选择集/键盘游标/丢失当前 id）
```
GALLERY_LOOKUP_SEMANTICS_OK (600 randomized trials)
  isFound / isFoldedVariant / filename / firstIndex / 光标锚点 / 打开灯箱下标 /
  灯箱 currentPhoto 全部与旧线性实现逐案一致
```

## 4. 图片/缩略图管线审计（read-only 分析 + 1 个安全修复）

### 4.1 已确认良好（不重复修）
- 解码统一走 `PhotoThumbnailDecoder.decodeAsync`：后台 DispatchQueue 解码 + `PhotoDecodeGate`（整图 4 / 区域 2）+ 同键在飞去重 + 等待者取消 + 内存/磁盘缓存（`Support/PhotoThumbnailView.swift:549-657`）。
- 渐进细节层只解可见区域（`PhotoViewerGeometry.detailTile`），多格预算按格数收窄；Lightbox/Workbench/SecondDisplay/Filmstrip 都走同一入口（`Support/PhotoThumbnailView.swift:659-745`、`Culling/CullingWorkbenchViewer.swift:688-762`、`Culling/CullingSecondDisplay.swift:427-456`）。
- 邻张预取用与显示完全相同的 cache key，命中即跳过（`Culling/CullingViewModel+Preload.swift:205-222,286-307`；`Gallery/LightboxView.swift:326-341`）。

### 4.2 本轮安全修复（我的 scope 内）
- `Culling/CullingViewModel+Preload.swift:179-194,242-284`：旧实现 `runNeighborPreload` 在 MainActor 上逐条调用 `isViewerPreviewCached`，其磁盘探针 `ThumbnailDiskCache.data` 会 stat + **读整张预览 JPEG**（baseDimension 2560，可达数 MB）+ touch mtime；一次翻片最多 5 条 ⇒ 主线程同步 I/O。现改为 `nonisolated static computePreloadMisses` 内 `Task.detached(priority: .utility)` 计算未命中集（内存 NSCache 与磁盘缓存都自带锁，可安全后台查询），回主线程后再走原有预热顺序；加 `Task.isCancelled/isShutdown` 守卫。查询结果只用于"要不要预热"，不影响正确性/展示。
  - 配套：`preloadPreviewDimension` 标记 `nonisolated static let`；`isViewerPreviewCached` 纯函数标记 `nonisolated static`（单测注入闭包签名不变）。

### 4.3 残余建议（按优先级；涉及 Support/Host 文件由对应 agent 处理，本轮不改）
| 优先级 | 项 | 位置 | 说明/建议 |
|---|---|---|---|
| P1 | `NSImage(data:)` 惰性解码可能把 JPEG 解压推迟到**主线程首次绘制** | `Support/PhotoThumbnailView.swift:272,455,733`（+ `CullingViewModel+Preload.swift:301`、`LightboxView` 经同一 view） | 建议在后台把 Data→CGImage（`CGImageSourceCreateImageAtIndex` / 强制 decode）后再进主线程；或 Host 解码器直接返回 CGImage。需 image-pipeline agent 处理。 |
| P1 | 磁盘缓存探针每次 `stat` + 读整文件 + touch mtime | `Support/ThumbnailDiskCache.swift:84-91` | GUI 显示路径在 decode Task 后台命中磁盘时仍会读整个 JPEG（用于返回 Data，合理）；但"只判是否存在"的场景（预取/负缓存）可加 metadata-only 探针。本轮已把预取探测移出主线程。 |
| P2 | `PhotoThumbnailCache.key` 每次取锁读 epoch（body + task id 每帧） | `Support/PhotoThumbnailView.swift:772-779` | 可缓存 key 到 @State；收益小，注意 invalidateAll 语义。 |
| P2 | 磁盘缓存写入 `Data.write(.atomic)` / prune 目录枚举跑在协作线程 | `Support/ThumbnailDiskCache.swift:93-148` | 建议专用串行 utility queue；现在每次 decode 后可能阻塞协作线程池。 |
| P2 | Gallery 网格按 `thumbnail_size` 设置桶解码（默认 1024），而单元格 160–360pt @2x 实际只需 600–720px | `Gallery/GalleryCellView.swift:40`、`GalleryViewModel.thumbnailSize` | 过度解码约 2–8×内存；但改分辨率=用户可见清晰度/设置语义变化，**非安全**，仅记录。 |
| P3 | 同一照片多档位解码（胶片 256 / 网格 1024 / 查看器 2560 / 参考图 1024–2560） | 各调用点 | 档位设计有意为之（判焦需要真实像素）；不合并。 |
| P3 | `PhotoDecodeGate.acquire` 2→20ms 退避轮询 | `Support/PhotoThumbnailView.swift:513-528` | continuation 排队已因取消语义被放弃；可记录但收益低。 |

## 5. 其余渲染路径残余（本轮与 round-2 已处理之外的 P1/P2）

| 优先级 | 项 | 位置 | 备注 |
|---|---|---|---|
| P2 | `CullingComparison.assets/surveyAssets` 每次 body 对 page 做 `filter` + `firstIndex`（多图/对比布局逐帧） | `Culling/CullingComparison.swift:18-33,53-67` | 纯函数被 SecondDisplay/WorkbenchViewer body 调用；可加"调用方已算好 selected 命中集合/当前下标"的重载（需同步单测） |
| P2 | `currentGroupAssets` 每次 body filter 整页（相似组视图开启时） | `Culling/CullingInspector.swift:801-806` | round-1 已 hoist 成 body 一次；组视图场景 1 次/帧，可接受 |
| P2 | `GalleryView+Content.openPendingPhotoIfAvailable` 两次 `firstIndex`（一次/导航） | `GalleryView+Content.swift:134-146` | 可接 `filteredPhotoIndexByID`（id 路径）；filepath 需 path→index 表，收益低 |
| P3 | `CullingViewStateStore` 恢复存档时 `page.assets.contains` | `Culling/CullingViewStateStore.swift:342,359` | 进页一次 |
| P3 | `CullingViewModel+Actions.swift:150` 组前进从当前下标向后找"不同组"资产 | `:146-150` | 语义需顺序扫描，不做 |
| P3 | `GalleryGrid.rowIndex(containing:)` 逐行 `items.contains` | `GalleryGrid.swift:24-29` | 仅键盘游标变化时调用；行数小 |

## 6. 验证（命令 + 结果）

### 6.1 Swift 6.2 语法检查
```
.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <file>
16/16 改动文件 EXIT:0（ALL_PARSE_OK）
```
覆盖：`CullingViewModel.swift`、`+Actions`、`+Load`（未改，round-2 已 bump）、`+Grid`、`+Preload`、`+Navigation`、`CullingSecondDisplay`、`CullingWorkbenchViewer`、`CullingInfoBar`、`CullingInspector`、`GalleryViewModel.swift`、`+Derived`、`+Scroll`、`+Events`、`GalleryInspector`、`GalleryView+Content`、`LightboxView`。

### 6.2 仓库门禁（最终复跑）
| 门禁 | 结果 |
|---|---|
| `./scripts/check-cleanup-ratchet.sh` | **OK**：`unchecked_sendable 60/60`、`try_optional 257/257`、其余 0/0（无新增 @unchecked / nonisolated(unsafe)） |
| `./scripts/check-design-system.sh` | **PASS: no regression**（exit 0；未改 baseline；`empty.contentUnavailable 6/10 improved -4` 来自同伴在途迁移） |
| `./scripts/check-preview-surface.sh --strict` | **PASS: #Preview=14, preview files=12, lines=2210**（exit 0） |
| `./scripts/check-layering.sh` | **OK**（exit 0） |

### 6.3 行为等价探针（Linux + 真实 GatherProtocol 类型；脚本在 `.gather/tmp/`，gitignored）
- `PAGE_INDEX_SEMANTICS_OK`（nil/empty/命中/缺失/重复 id/current 回退/无 bump 直接赋值；含 26x 基准）
- `SELECTION_SUMMARY_CACHE_OK (800 randomized op sequences)`
- `OBSERVATION_DEPENDENCY_OK`（修复前不触发 / 修复后触发）
- `GALLERY_LOOKUP_SEMANTICS_OK (600 randomized trials)`
- didSet×Set mutate 探针：insert/remove/removeAll/formIntersection/subtract/赋值 全部触发 didSet
- 跨文件 nested type + `nonisolated static let` + `Task.detached` 模式：独立 Swift 6.2 探针 typecheck 通过

### 6.4 验证上限（必须保留）
- **未 macOS 编译/运行**：未跑 `swift build/test/check-warnings`、无 Instruments；`swiftc -parse` 不覆盖类型检查/严格并发，关键新写法已用独立小探针 typecheck，但整套 GatherUI 的真实编译仍需 macOS CI 复核。
- 性能数字是 Linux corelibs 探针的同环境 A/B（真实 DTO 结构），macOS 绝对值不同；收益来自算法结构（O(page)→O(1)）而非微基准绝对值。
- 未新增/修改测试（write scope 不含 Tests）；建议后续为 selectionSummary 缓存与 pageIndex helper 补单测（探针用例可直接转译）。

## 7. 改动文件（16）
| 文件 | 变更 |
|---|---|
| `Culling/CullingViewModel.swift` | page.didSet 同时清 selectionSummaryCache（L40-44）；O(1) pageIndex/pageAsset/currentPageIndex（L190-214）；selectionVersion + selectionSummaryCache 存储（L216-224） |
| `Culling/CullingViewModel+Actions.swift` | selectionSummary 缓存 + 无条件观察读（L605-642）；13 处页查找改 O(1)（L147,249,494,650,660,670,683,699） |
| `Culling/CullingViewModel+Preload.swift` | plan 索引重载（L60-84）；预取探测移出主线程（L179-194,242-284）；nonisolated 标记（L138,273） |
| `Culling/CullingViewModel+Grid.swift` | currentLoadedIndex / 范围选择 / 锚点存在性 O(1)（L52-56,144-168） |
| `Culling/CullingViewModel+Navigation.swift` | fileName O(1)（L340-342） |
| `Culling/CullingSecondDisplay.swift` | currentAsset/currentIndex O(1)（L191-194,295-299） |
| `Culling/CullingWorkbenchViewer.swift` | currentIndex / 参考图 / 细节贴片 O(1)（L197-202,669-671,1074-1078） |
| `Culling/CullingInfoBar.swift` | currentIndex O(1)（L238-242） |
| `Culling/CullingInspector.swift` | 场景标签 nameFor O(1)（L229-233） |
| `Gallery/GalleryViewModel.swift` | import Observation；filteredCache 增 ids/indexByID；loadedPhotoLookupCache（L14,338-345） |
| `Gallery/GalleryViewModel+Derived.swift` | GalleryLoadedPhotoLookup + 懒构建；filtered id 集合/下标；O(1) getters（L39-172） |
| `Gallery/GalleryViewModel+Scroll.swift` | locatePendingPhoto 命中判定 O(1)（L63-88） |
| `Gallery/GalleryViewModel+Events.swift` | selection 交 collection 用同代 id 集（L100-102） |
| `Gallery/GalleryInspector.swift` | 2× nameFor + alreadyVisible O(1)（L210-212,226-228,257-259） |
| `Gallery/GalleryView+Content.swift` | 键盘游标/打开灯箱/选中定位 O(1)（L331-392） |
| `Gallery/LightboxView.swift` | indexByID 状态 + 重建 + 滞后回退；prefetch 传下标（L23-66,90-99,330-366） |

未改：`Resources/en.lproj/**`、`Support/L10n.swift`、`Support/GatherLocalization.swift`、design-system baseline、Support/PhotoThumbnailView.swift、Support/ThumbnailDiskCache.swift、GatherHost/AppBootstrap、core 服务、其他 agent 文件。
