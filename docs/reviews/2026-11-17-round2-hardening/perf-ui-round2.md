# Round2 GatherUI 渲染路径性能：currentAsset O(1)、formatter 复用、body hoist（task-10 / perf-ui）

- 日期：2026-11-17（评审目录 2026-11-17-round2-hardening）
- 基线：`4cb3228d` + 同伴未提交的 round-2 改动（本 agent 未触碰这些文件）
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode → **未编译、未运行、无 Instruments**。Swift 6.2 toolchain 只做 `-parse`；性能数字来自 `.gather/` 下的独立 Linux 探针（swift-corelibs Foundation + 真实 `GatherProtocol` 类型），**不是 macOS 实测**，仅用于同环境 A/B 对比。
- 行为约束：无用户可见文案/布局/API 变更；无新增 `@unchecked Sendable`（cleanup ratchet 60/60）；未改 design-system baseline / en.lproj。
- 与 ui-copy（task-13）确认无文件重叠；design-empty 后续迁移 ContentUnavailableView 不受影响。

## 0. 摘要（做了什么 + 证据）

| # | 修复 | 位置 | 关键证据 |
|---|------|------|---------|
| P0 | `CullingViewModel.currentAsset` 由 O(page) 线性扫描改为 pageVersion 索引缓存（位置索引 + `page.didSet` 失效） | `CullingViewModel.swift:40,139-187`、`+Load.swift:193` | 语义探针 `SEMANTICS_OK`；Linux 500 张页 18 次读：旧 ~20.3µs/帧 → 命中 ~2.5µs/帧（8x） |
| P1 | `ByteCountFormatter.string(...)` 逐行/逐帧调用改走现有 `DisplayDateFormatters` 共享缓存 | `Support/DateFormatting.swift:130` + 5 处调用点 | 输出探针 `EQUIVALENCE_OK`；Linux 类方法 ~46.9µs vs 缓存 ~48.2µs（格式化本身占主导，见 §2.1 的诚实结论） |
| P1 | `MetadataEditorDraft.shiftedDateTime` 每张照片新建 DateFormatter → 共享固定 UTC 缓存 | `Metadata/MetadataEditorDraft.swift:237-246` | `EQUIVALENCE_OK`；Linux 65.5µs → 23.0µs/次（~2.85x），批量预演上限 200 张/次 |
| P1 | WebDAV `proofExpiresAt` 每次 body 新建 ISO formatter → 共享缓存 | `Export/WebDAVPublishSheet.swift:73-77` | `EQUIVALENCE_OK`；Linux 43.4µs → 1.12µs/次（~38x） |
| P2 | `CullingInfoBar.currentIndex` 每帧 2 次 O(page) `firstIndex` → 1 次 | `Culling/CullingInfoBar.swift:28,51,55` | 纯 hoist，无行为变化（视图 diff 见 §3.1） |
| P2 | `GalleryInspector.gallerySceneTagSeedIds` 每帧 2 次 `loadedPhotos.contains`（O(n)）→ VM 同代 id 集合 O(1) | `Gallery/GalleryInspector.swift:102-104`、`GalleryViewModel+Derived.swift:39-59`、`GalleryViewModel.swift:339` | id 集合与 `loadedPhotos` 同一 `flatCache` 代数构建，语义等价 |

所有改动文件：14 个 GatherUI 源文件（§6）。未 git commit。

## 1. P0：`CullingViewModel.currentAsset` O(page) → O(1)

### 1.1 旧实现与成本

```swift
// 旧：每次读取都线性扫（CullingViewModel.swift:125-128 @4cb3228d）
public var currentAsset: CullingAsset? {
    guard let currentPhotoId else { return page?.assets.first }
    return page?.assets.first { $0.photo.id == currentPhotoId } ?? page?.assets.first
}
```

- 读取点：`CullingInspector` 一帧直接/间接 **18 次**、`CullingWorkbenchViewer` **25 处**、`CullingInfoBar` 3 次、`CullingTriageCard`/`SecondDisplay`/`Keywords`/`Triage` 等（`grep currentAsset` 全目录 71 处）。页大小 500（单图/对比）或 200（网格）⇒ 每帧上万次 id 比较。
- 语义契约（新实现逐条保持）：`currentPhotoId == nil` → 页首张；id 不在页内 → 页首张（旧 `?? page?.assets.first`）；页为空 → nil；重复 id → **首个**匹配（旧 `first(where:)`）。

### 1.2 新实现（位置索引 + pageVersion + didSet 双保险）

```swift
// CullingViewModel.swift:40
public internal(set) var page: CullingPage? {
    didSet { pageAssetIndexCache = nil }   // 任何赋值路径（含扩展/测试）都失效索引
}

// CullingViewModel.swift:139-187
@ObservationIgnored private var pageAssetIndexCache: PageAssetIndex?
private struct PageAssetIndex {
    let pageVersion: Int
    let assetIndexByPhotoID: [String: Int]   // photoId → 页内下标；重复 id 保留首个
}
private var pageAssetIndex: PageAssetIndex { ...按 pageVersion 命中，否则整页重建... }
public var currentAsset: CullingAsset? {
    let index = pageAssetIndex
    guard let page else { return nil }
    guard let currentPhotoId,
          let position = index.assetIndexByPhotoID[currentPhotoId],
          page.assets.indices.contains(position) else { return page.assets.first }
    return page.assets[position]
}
```

设计取舍（与任务建议的 `[photoId: CullingAsset]` 不同，基于实测）：
- Linux 500 张页、每帧 18 次读（真实 `GatherProtocol.CullingAsset`，`-O`，5 次中位数）：
  - 旧实现 18 次 `first(where:)`：**~20.3µs/帧**；
  - `[photoId: CullingAsset]` 索引重建 + 18 次读：**~121.5µs**（整页大结构体的复制/保活/释放是主导）；
  - **位置索引** `[photoId: Int]` 重建 + 18 次读：**~84µs**（本次采用）；
  - 两种索引命中（同 pageVersion）：18 次读都 ~0.37µs（不含返回结构体拷贝）/~2.5µs（含拷贝）。
- 位置索引额外好处：返回的资产始终从**当前 page 现取**，不会持有旧 `CullingAsset` 快照（决策回显/未来就地更新都不会读到陈旧 state）。
- 重建只发生在 pageVersion 变化时（翻页/排序/筛选/投影/决策回显，`didSet` 再兜底一次）；命中路径覆盖浏览/选择/同步刷新等大多数 body 求值。绝对成本：重建 ~84µs 对 16.7ms 帧预算约 0.5%，命中帧省 ~18µs。

### 1.3 失效证明：page 赋值点 × pageVersion 审计

`page` 是 `public internal(set)`，生产代码只有 7 处赋值（`grep '(self\.)?page\s*='` 逐条核对）：

| # | 赋值点 | pageVersion bump | 说明 |
|---|--------|------------------|------|
| 1 | `+Load.swift:89`（`applySnapshot`） | `:88`（赋值前） | 整页替换，bump 后当前照片若失效会回退新页首张 |
| 2 | `+Load.swift:193-194`（`sessionId` 为空 → `page = nil`） | `:193`（**本次新增**） | 审计发现的唯一缺 bump 路径；清页同样使索引/在途守卫失效 |
| 3 | `+Load.swift:226`（`loadPage` reset 分支） | `:221`（赋值前） | 首页/刷新 |
| 4 | `+Load.swift:233`（`loadPage` 追加分支） | `:221` | 续页拼接 |
| 5 | `+Actions.swift:39`（`applyDecisionStates`） | `:38`（赋值前） | 决策回显替换整页（state 变化） |
| 6 | `+Grid.swift:463`（`applyClientProjection`） | `:464`（赋值后，同一同步段） | 客户端投影页 |
| 7 | `+Grid.swift:499`（`restoreClientProjectionBase`） | `:500`（赋值后，同一同步段） | 退出投影恢复基准页 |

另外 3 处 `pageVersion += 1`（`+Actions.swift:284/361/730`）**不改变 page**：失败路径保留它们是为了让在途 conflicts 守卫/布局缓存继续失效（既有语义），代价是之后一次多余索引重建，可忽略。

双保险与观察语义：
- `page.didSet` 清空缓存 ⇒ 即使未来新增/测试代码直接赋值 `page`（不 bump）也不会读到旧索引；
- `currentAsset` 每次都读取 `page` 与 `pageVersion`（前者即使命中缓存也读，见实现）⇒ Observation 依赖与原实现一致，page 替换仍会触发含 `currentAsset` 的 body 重算；
- call sites 均为同步 MainActor 代码块，bump 与赋值之间无挂起点。

### 1.4 语义/失效验证（独立探针，Linux）

用真实 `GatherProtocol.CullingAsset/CullingPage` 复刻旧/新实现（含 `didSet` 失效）对拍：

```
SEMANTICS_OK (old vs new identical on all cases)
cases: nil page/nil id、empty page、normal second id、missing id→first、duplicate id→first occurrence、
       state-only replace（version bump + 同 id 新 state）、direct page assignment WITHOUT version bump（didSet 兜底）
```

benchmark（`-O`，500 张页，5 次中位数）：

```
old: 18x first(where:) 500:                       20.304 us/call
new cache-hit: 18 reads (500):                     2.532 us/call
new rebuild: invalidation + 18 reads:             84.225 us/call
```

补充：Lead 独立用 Swift 6.2 编译并运行了 `@Observable + didSet` 探针（typecheck OK；运行时输出 "onChange page / didSet-fired / observed=1"），验证本方案在 Observation 下 didSet 触发的缓存失效可被 `withObservationTracking` 观察到。注意：仍非 macOS SwiftUI 构建/运行。

## 2. 复用既有共享 formatter 缓存（不新增 `@unchecked Sendable`）

全部复用 `Support/DateFormatting.swift` 中既有的 `DisplayDateFormatters`（本已 `@unchecked Sendable` + `NSLock`，已计入 cleanup baseline）。新增方法都在该类内，**没有新增类型** ⇒ `unchecked_sendable` 保持 60/60。

### 2.1 ByteCountFormatter（逐行/逐帧 5 处）

新增 `DisplayDateFormatters.fileSize(_:)`（`DateFormatting.swift:130-142`）：与旧 `ByteCountFormatter.string(fromByteCount:countStyle: .file)` 逐字节一致；`countStyle = .file`，locale 变化时重建（旧类方法每次取调用时 locale）；持锁格式化（ByteCountFormatter 没有 DateFormatter 那种公开线程安全承诺）。

调用点（全部逐行/逐帧）：
- `Curation/CollectionView.swift:571`（集合成员行）
- `Metadata/MetadataSyncBar.swift:244`（同步条 body）
- `Settings/SettingsView+MaintenanceSection.swift:244`（备份列表行）
- `Export/ExportView+Preview.swift:18,21`（预览汇总，body）+ `:66`（≤8 行清单）
- `Export/DeliveryConfirmSheet.swift:16`（交付确认 body，≤3 次）

验证：独立探针覆盖 `0/1/512/999/1024/2048/1.5MB/5MB/1GB/3TB` → 旧/新输出 `EQUIVALENCE_OK`。

**诚实结论（成本）**：Linux corelibs 上 `ByteCountFormatter()` 构造仅 ~1.04µs，而格式化一个值 ~47µs；类方法 ~46.9µs vs 缓存实例 ~48.2µs ⇒ 本项在 Linux 上只省一次小对象分配（~2%），不是大收益。保留理由：输出等价、无行为风险，macOS Foundation 的构造/格式化比例未测（无法测），且 5 处都是逐行/逐帧路径；若 macOS 探针显示无收益，可随时回退这 5 处单行调用（见 §5 残余项）。

### 2.2 `MetadataEditorDraft.shiftedDateTime`（批量时间预演逐张，上限 200）

- 旧（`:237-246` @4cb3228d）：每次新建 `DateFormatter`（`en_US_POSIX` + UTC + `yyyy-MM-dd'T'HH:mm:ss`），`MetadataBatchEditorSheet.previewTimeAdjustment` 对每张照片调 1 次（`maxPhotos = 200`）。
- 新：`DisplayDateFormatters.parseFixedUTC(_:format:)` / `formatFixedUTC(_:format:)`（`DateFormatting.swift:152-177`，缓存键含固定 pattern，配置同旧实现，持锁也兼顾 Swift Testing 并行调用）。
- 验证：探针覆盖合法时间/日期进位/闰日/非法串/空串 × 偏移 [-86400,0,3600,86400,400 天] → `EQUIVALENCE_OK`；成本 65.5µs → 23.0µs/次（~2.85x，Linux `-O`）。

### 2.3 WebDAV `proofExpiresAt`（每次 body 求值，启用到期时）

- 旧（`Export/WebDAVPublishSheet.swift:73-78` @4cb3228d）：每次新建 `ISO8601DateFormatter` + `[.withInternetDateTime]` 输出。
- 新：`DisplayDateFormatters.internetDateTimeString(from:)`（`:144-150`，复用既有 ISO formatter，持锁）。
- 验证：`EQUIVALENCE_OK`；43.4µs → 1.12µs/次（~38x）。

## 3. body hoist / O(n)→O(1) 命中

### 3.1 `CullingInfoBar.currentIndex`（2 次 O(page) → 1 次）

- 旧：body 内正文 `Text("\(currentIndex + 1) / ...")` 与 `accessibilityLabel` 各读一次 `currentIndex`（`page.assets.firstIndex(where:)`）。
- 新：`Culling/CullingInfoBar.swift:28` 在 body 顶部 `let index = currentIndex`，`:51`/`:55` 改用 `index + 1`。纯 hoist，取值相同（当前照片不在页内时仍回退 0/1）。

### 3.2 `GalleryInspector.gallerySceneTagSeedIds`（body 每帧 2 次 O(n) `contains` → O(1)）

- 旧：`viewModel.loadedPhotos.contains(where: { $0.id == id })` 每帧 2 次（section body + sheet 种子），`loadedPhotos` 链式拉满时可达上万行。
- 新：`GalleryViewModel+Derived.swift:43-59` 把 **id 集合与照片数组放在同一份 `flatCache`** 里（`GalleryViewModel.swift:339` 缓存类型扩为 `(generation, photos, ids)`），新增 `loadedPhotoIdSet`；`Gallery/GalleryInspector.swift:102-104` 改为 `loadedIDs.contains(id)`。id 集合与 `loadedPhotos` 同 `pagesGeneration` 构建/失效，语义等价（同一次 flatMap 的 id 集合）。

## 4. 其余渲染路径 formatter/coder 审计（本轮未改）

`DateFormatter()` / `ISO8601DateFormatter()` / `ByteCountFormatter` / `JSONEncoder/Decoder` / `NumberFormatter` / `MeasurementFormatter` / `NSRegularExpression` 全目录复查（`4cb3228d` + 本改动后）：

| 位置 | 语境 | 判定 |
|------|------|------|
| `Support/DateFormatting.swift` | 共享缓存工厂内部（构造一次） | ✅ 缓存本体 |
| `Duplicates/DuplicatesViewModel.swift:460-470` | 成员评分用的两个 ISO 解析器 | ✅ `static let`（既有） |
| `Metadata/MetadataTransferService.swift:652` | 模板导入/导出服务 | ❓ 非渲染路径 |
| `Library/LibraryViewModel.swift:159` | 筛选条件构建（apply 时 1 次） | ❓ 非渲染 |
| `SemanticSearch/SemanticSearchSheetModel.swift:68` | 批次保存时间戳 closure | ❓ 非渲染 |
| `Settings/SettingsView+MaintenanceSection.swift:288` | 诊断导出按钮点击时 `stamp()` | ❓ 点击路径（1 次/点击） |
| `Culling/CullingViewStateStore.swift:123,143` | 存档读/写（已节流） | ❓ 写路径 |
| `Filtering/FilterEditorModel.swift:77-83`、`Export/ExportViewModel+Delivery.swift:127,509`、`Culling/IngestSheet.swift:801-811`、`SemanticSearch/SemanticKeywordBatchStore.swift:83-92`、`Library/LibraryViewModel+Filter.swift:132`、`Support/JSONValueDecoding.swift:64-65` | JSON coder 保存/加载/提交/筛选 hash | ❓ 非 body/行 |

结论：本轮后 `Sources/GatherUI` 中**没有剩下** body/逐行路径的 formatter 实例构造（除共享缓存内部）；`String(format:)` 31 处均为无 formatter 的一次性格式化（~1µs 级，多数不在逐行路径），未改。

## 5. 残余 P0/P1/P2（按收益排序，供后续 round）

| 优先级 | 项 | 说明/建议 |
|--------|----|-----------|
| P1 | `CullingViewModel.selectionSummary`（`+Actions.swift:607`）仍是 O(page) filter + 2 个 `Set`；`CullingInspector` body 每帧仍读 2 次（round-1 已把 body 内 3→1，`colorSelectionBinding` getter 仍自读 1 次） | 可按 `(pageVersion, selectedPhotoIds)` 缓存（`pageVersion` 已覆盖 state 变化；选择集变化需比对或引入 selection generation）；改动面比 currentAsset 大，建议独立任务 + 单测 |
| P1 | 决策路径 `pageVersion` 每次都 bump ⇒ 位置索引每决策重建一次（Linux 500 张 ~84µs/次） | 若 macOS profile 显示决策流有热点：可在 `page.didSet` 里用 O(n) id 序列比较（同序列=state-only 替换）保留索引，但需额外等价性测试；当前绝对成本仅 ~0.5% 帧预算，未做 |
| P2 | `CullingViewModel+Preload.swift:113-118 currentIndex(assets:currentPhotoId:)` 每次预取调度 O(page) `firstIndex` | 与 InfoBar 同款问题；预取去抖键已有 pageSignature，可复用/缓存 |
| P2 | `GalleryInspector.swift:211/226` 场景标签/语义面板 `nameFor` closure 内 `loadedPhotos.first(where:)`（每命中行 1 次 O(n)） | 可用 `loadedPhotoIdSet` 同代缓存扩展 `photoId→filename` 字典；sheet 行数通常少，收益中低 |
| P2 | `GalleryView+Scroll.swift:66,76` `loadedPhotos.contains { ... }`（滚动定位/兜底每行） | 同上，可用 id 集合（已有 `loadedPhotoIdSet`） |
| P2 | Byte-count 缓存在 Linux 上仅 ~2% 收益（§2.1） | 若 macOS 探针无收益可回退 5 处单行改动 |
| 低 | `FacetBar.visibleGroups`、`SemanticSearchSheetModel.labelQueryTerms`、Dashboard 统计 reduce、`PersonsViewModel` 搜索 filter 等 | 数据量小，收益低于 churn 风险（round-1 已记录） |

## 6. 改动文件（14）+ 行号

| 文件 | 变更 |
|------|------|
| `Culling/CullingViewModel.swift` | `page.didSet` 失效（L40-44）；`PageAssetIndex` 位置索引 + `currentAsset`（L131-187） |
| `Culling/CullingViewModel+Load.swift` | `page = nil` 路径补 `pageVersion += 1`（L190-196） |
| `Culling/CullingInfoBar.swift` | `currentIndex` body hoist（L28,51,55） |
| `Support/DateFormatting.swift` | 类内新增 `fileSize`/`internetDateTimeString`/`parseFixedUTC`/`formatFixedUTC` + byte formatter 字段（L30-36,130-177）；类注释更新 |
| `Curation/CollectionView.swift` | 成员行 byte 格式化走共享缓存（L571） |
| `Metadata/MetadataSyncBar.swift` | body byte 格式化走共享缓存（L244） |
| `Settings/SettingsView+MaintenanceSection.swift` | 备份列表行 byte 格式化走共享缓存（L242-245） |
| `Export/ExportView+Preview.swift` | 3 处 byte 格式化走共享缓存（L18,21,66） |
| `Export/DeliveryConfirmSheet.swift` | byte 格式化走共享缓存（L15-17） |
| `Export/WebDAVPublishSheet.swift` | `proofExpiresAt` ISO 输出走共享缓存（L73-77） |
| `Metadata/MetadataEditorDraft.swift` | `shiftedDateTime` 走固定 UTC 缓存（L237-247） |
| `Gallery/GalleryViewModel.swift` | `flatCache` 增加同代 id 集合（L338-339） |
| `Gallery/GalleryViewModel+Derived.swift` | `loadedPhotosAndIDs()` + `loadedPhotoIdSet`（L39-59） |
| `Gallery/GalleryInspector.swift` | 场景标签种子 O(1) 命中（L97-106） |

未改：`Resources/en.lproj/**`、`Support/L10n.swift`、`Support/GatherLocalization.swift`、`scripts/design-system-baseline.json`、ui-copy 的 5 个文件。

## 7. 验证（命令 + 结果）

### 7.1 语法检查（Swift 6.2，仅 parse）

```
.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <file>
14/14 文件 EXIT:0（ALL_PARSE_OK）
```

覆盖：`CullingViewModel.swift`、`CullingViewModel+Load.swift`、`CullingInfoBar.swift`、`DateFormatting.swift`、`CollectionView.swift`、`MetadataSyncBar.swift`、`SettingsView+MaintenanceSection.swift`、`ExportView+Preview.swift`、`DeliveryConfirmSheet.swift`、`WebDAVPublishSheet.swift`、`MetadataEditorDraft.swift`、`GalleryViewModel.swift`、`GalleryViewModel+Derived.swift`、`GalleryInspector.swift`。

### 7.2 仓库门禁

| 门禁 | 结果 |
|------|------|
| `./scripts/check-cleanup-ratchet.sh` | OK（`unchecked_sendable 60/60`、`try_optional 260/260` 等全部 ≤ baseline；未新增 `@unchecked Sendable`） |
| `./scripts/check-design-system.sh` | `PASS: no regression`（exit 0；未改 baseline；`theme.legacyAlias` improved 来自同伴在途迁移，非本轮改动） |
| `./scripts/check-preview-surface.sh --strict` | `PASS: #Preview=14, preview files=12, lines=2210`（exit 0） |
| `./scripts/check-layering.sh` | `check-layering: OK`（exit 0） |

### 7.3 行为等价证据（独立探针，Linux + 真实 GatherProtocol 类型）

- `currentAsset` 语义对拍：`SEMANTICS_OK`（nil/empty/missing/duplicate/state-only replace/direct-assign 六类）。
- formatter 输出对拍：`EQUIVALENCE_OK`（byte-count 10 个量级；ISO-8601 输出/两种解析；`shiftedDateTime` 合法/非法/闰日 × 5 种偏移）。
- 探针脚本在 `.gather/tmp/`（gitignored scratch），未入库；基准数字仅供同环境 A/B，不代表 macOS 绝对值。

### 7.4 验证上限（必须保留）

- **未在 macOS 编译/运行**（无 Xcode/SDK），未跑 `swift build`/`swift test`/`check-warnings`、无 Instruments；`@Observable + didSet` 的 Observation 兼容性由 Lead 的独立 Swift 6.2 探针确认（typecheck + runtime），但仍非 macOS SwiftUI 构建。
- 性能收益来自结构分析 + Linux 探针；macOS 上的绝对数值/是否出现回归需真机 profile 复核（建议优先看决策流帧耗时与 `currentAsset` 重建次数）。
- 测试 target 未改动、未新增回归测试（write scope 不含 Tests）：建议后续为 `currentAsset` 的 nil/missing/duplicate/direct-assign 语义补一个单测（现有行为对拍可供参考）。
