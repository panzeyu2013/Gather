# Round4 GatherUI 渲染性能：Culling 索引复用 + Gallery 渲染审计（task-22 / perf-ui）

- 日期：2026-11-18（评审目录 2026-11-18-round4-perf）
- 基线：`2521c00b` + 同伴未提交 round-4 改动（本 agent 未触碰其他 agent 文件：Support/PhotoThumbnailView、Support/ThumbnailDiskCache、Host/AppBootstrap、core 服务均未编辑）
- 写作用域：`desktop/native/gather-app/Sources/GatherUI/Culling/**`、`.../Gallery/**` + 本文档
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode → **未编译、未运行、无 Instruments**。Swift 6.2 toolchain 仅 `-parse`；性能/语义证据来自 `.gather/tmp/` 下独立 Linux 探针（swift-corelibs Foundation + 真实 `GatherProtocol` DTO），**不是 macOS 实测**。
- 约束：无用户可见文案/布局/行为变化；无新增 `@unchecked Sendable`（cleanup ratchet 60/60）；未改 design-system baseline / en.lproj；未 git commit。

## 0. 摘要

| # | 修复 | 位置 | 证据 |
|---|------|------|------|
| P0 | Culling 页索引在 **state-only 替换**时复用：`page.didSet` 自增赋值代数，索引按 O(n) id 序列比较后沿用，重排/换页才重建 | `Culling/CullingViewModel.swift:38-51,138-208` | `PAGE_INDEX_REUSE_SEMANTICS_OK`；Linux 500 张页决策帧 155.5µs → **44.5µs**（含页面构造；复用 205 次仅 1 次重建） |
| P1 | Culling 网格布局缓存同几何复用：决策回显不再每拍 relayout 500 张 | `Culling/CullingGrid.swift:217-300` | `GRID_LAYOUT_REUSE_SEMANTICS_OK`；23.9µs → **0.4µs**/决策 |
| P1 | `navigationGroupSizeByPhotoID` 按 groups 赋值代数缓存（网格 body 每帧读，旧实现每帧重建整个字典） | `CullingViewModel+Navigation.swift:230-244`、`CullingViewModel.swift:308-317` | `ROUND4_CACHES_EQUIVALENCE_OK` |
| P1 | `activeFilterCount` 去掉每次读取的 7 元素数组 + filter 分配 | `CullingViewModel.swift:107-124` | 计数等价（无序/顺序无关） |
| P1 | 选择集排序快照缓存（场景标签种子）：Culling 复用已有 `selectionVersion`，Gallery 新增同机制；每帧 O(k log k) → O(1) | `CullingViewModel.swift:275-291`、`GalleryViewModel.swift:262-270`、`GalleryViewModel+Derived.swift:160-176`、两个 Inspector | `ROUND4_CACHES_EQUIVALENCE_OK`；Observation 依赖保留 |
| P1 | `currentGroupAssets` 按（page 赋值代数, groupId）缓存在 VM：选择/当前照片变化不再每帧 filter 整页 | `CullingViewModel.swift:240-259`、`CullingInspector.swift:811-817` | 纯读派生，同键同结果 |
| P2 | 胶片条 `ForEach(Array(assets.enumerated()))` 去掉每帧数组分配，ForEach 身份仍为 photo.id | `Culling/CullingFilmstrip.swift:70-90` | 身份等价（见 §3.5 的边界说明） |
| P2 | 两个网格 `ForEach` 去掉 `Array(rows.enumerated())` 包装，身份仍是 Int 行号 | `CullingGrid.swift:326-334`、`Gallery/GalleryGrid.swift:62-72` | 身份值相同（offset == index） |
| P2 | Gallery 布局缓存建行时顺手建 item→row 映射，键盘游标定位从 O(rows×items) 降到 O(1) | `Gallery/GalleryGrid.swift:14-47` | `ROUND4_CACHES_EQUIVALENCE_OK`（300 组随机行） |

改动 9 个文件（+250/−47）。

## 1. P0：Culling PageAssetIndex 在 state-only 更新时复用

### 1.1 旧实现（round-3）
```swift
// PageAssetIndex 只有 pageVersion + 字典；page.didSet 直接清空缓存
public internal(set) var page: CullingPage? {
    didSet { pageAssetIndexCache = nil; selectionSummaryCache = nil }
}
private var pageAssetIndex: PageAssetIndex {
    if let cached = pageAssetIndexCache, cached.pageVersion == pageVersion { return cached }
    ...重建 photoId→下标字典（500 张实测约 84µs）...
}
```
决策回显（P/X/星级/色标）用**同 id 顺序、只改 state**的新 `CullingPage` 替换 page，并 bump `pageVersion` ⇒ 每按一次就整页重建字典。

### 1.2 新实现（`CullingViewModel.swift:38-51,138-208`）
- `page.didSet`：`pageAssignmentCount &+= 1`；`selectionSummaryCache = nil`（state 影响摘要，必须失效）；page 变 nil 时释放索引缓存。**不再无条件清空位置索引**。
- `PageAssetIndex { var pageAssignmentCount; let orderedPhotoIDs: [String]; let assetIndexByPhotoID: [String: Int] }`。
- `pageAssetIndex`：
  1. 赋值代数相同 → O(1) 直接命中；
  2. 代数不同 → `pageAssetIDsMatch(cached.orderedPhotoIDs)` 做 O(n) id 序列比较（同 id 顺序 ⇒ 位置索引仍有效，仅更新代数）；
  3. 序列不同（重排/筛选/换页/追加）→ 重建 + 保存 id 序列。
- 返回的资产始终从**当前 page 现取**（`page.assets[position]`），state 不会过期；重复 id 仍保留首个（与旧 `first(where:)` 同义）。
- **pageVersion 语义未动**：+Load/+Grid/+Actions 的 7 处生产赋值点照旧 bump（其他缓存/在途守卫依赖它）；本缓存改用更强的"赋值代数 + 序列证明"，覆盖不 bump pageVersion 的直接赋值（测试/未来代码）。

### 1.3 语义/成本证据（Linux，真实 CullingAsset/CullingPage）
```
PAGE_INDEX_REUSE_SEMANTICS_OK
  cases: 初始 500 张 / state-only 替换 / 重排序 / 追加 resize / 不 bump 的直接赋值 /
         empty page / nil page / 重复 id 首个 / 缺失 id / currentPhotoId 回退
  与旧实现（每次重建）逐项对拍：pageIndex/pageAsset/currentAsset 完全一致
old rebuild-every-decision: 155.502 us/decision（含页面构造 + 18 次读取）
new reuse-on-same-sequence: 44.490 us/decision
new rebuilds total=1, reuse total=205（200 个决策帧）
```

## 2. P1：CullingGridLayoutCache 同几何复用

- 旧（`CullingGrid.swift:217-252` @2521c00b）：key = `version|assets.count|Int(width)|Int(rowHeight)`，`pageVersion` 每决策 +1 ⇒ 每次决策重跑 justified layout（500 张约 24µs）。
- 新（`CullingGrid.swift:217-300`）：缓存同时保存 id 顺序 + 量化宽高（UInt64 打包）+ 精确 width/rowHeight + count：
  - 快路径保持旧 key 语义（version + Int(width) + Int(rowHeight) + count）；
  - version 变了但 **精确 width/rowHeight、id 顺序、宽高全部相同** → 直接复用旧行（O(n) 比较）；
  - 其余（重排/筛选/换页/宽度或密度变化/亚像素宽度变化）→ relayout，与旧实现输出逐项一致。
- 布局函数只依赖（顺序、宽高比、容器宽、目标行高、gap），因此"同 id+同宽高"⇒ 行几何必然相同（探针证明）。

### 2.1 等价/成本证据（真实 JustifiedLayout + 模拟 id/宽高）
```
GRID_LAYOUT_REUSE_SEMANTICS_OK
  cases: state-only（复用）/ reorder（重建）/ append（重建）/
         fractional width（亚像素变化时按旧语义重建）/ width 整档变化 / rowHeight 变化
  新旧 rows 数组逐项 ==（JustifiedLayoutRow: Equatable）
old relayout-every-decision (500): 23.9 us/decision
new geometry-compare+reuse (500):    0.4 us/decision
```

## 3. 其余 Culling 修复

### 3.1 `navigationGroupSizeByPhotoID`（+Navigation:230-244）
旧实现每次读取 `O(组×成员)` 重建字典；`CullingGrid` body 每帧读一次。现在 `navigationGroups` 加 `didSet { navigationGroupsVersion &+= 1 }`，字典按该代数缓存（同数据 ⇒ 结果相同；重复 id 后者覆盖与旧实现同序）。

### 3.2 `activeFilterCount`（CullingViewModel:107-124）
旧实现每次读取构造 7 元素布尔数组再 `filter`；检查器/工具栏每帧读 1-3 次。改为逐个 if 计数，零分配、结果相同。

### 3.3 选择集排序快照 + 场景标签种子
- Culling：`sortedSelectedIds`（`CullingViewModel.swift:275-291`）复用已有 `selectionVersion`；缓存内容 = `selectedPhotoIds.filter { !$0.isEmpty }.sorted()`（与旧 `SceneTagsEntryPolicy.seedPhotoIds` 的"去空串再排序"同口径）。
- Gallery：`selectedIds` 加 `didSet { selectionVersion &+= 1 }`、`sortedSelectionCache`（`GalleryViewModel.swift:262-270`），`sortedSelectedIds` 见 `+Derived:160-176`。
- 两处 Observation 依赖：命中缓存也先读 `selectedPhotoIds.count` / `selectedIds.count`（只改选择集时 body 会重算；与 round-3 selectionSummary 同一教训）。
- `SceneTagsEntryPolicy.seedPhotoIds(sortedSelection:currentPhotoId:)`（CullingInspector:28-35）直接返回快照（调用方已按同口径清洗），旧入口保留给其他调用/单测。

### 3.4 `currentGroupAssets`（相似组检查器）
`CullingViewModel.similarGroupAssets(inCurrentPage:)`（:240-259）缓存键 =（page 赋值代数, groupId）；`CullingInspector` 旧实现每次 body filter 整页（组视图/相似组决策打开时每帧）。同键结果只依赖 page+groupId，选择/当前照片变化命中缓存；页替换（含决策回显）重算一次。

### 3.5 逐帧分配清理
- `CullingFilmstrip.swift:70-90`：旧 `ForEach(Array((page?.assets ?? []).enumerated()), id: \.element.photo.id)` 每帧分配 ≤500 元组；改为 `ForEach(page?.assets ?? [], id: \.photo.id)`，身份仍是 photo.id；续页判断改为 `onAppear` 时 `viewModel.pageIndex(ofPhotoId:)` O(1)。
  - 边界说明：onAppear 的下标从"body 快照位置"变为"当前页位置"。只有当 body 创建后、onAppear 前 page 恰好被替换（现实窗口极小）才可能不同；续页 `loadMoreIfNeeded/loadMore` 自带 hasMore/isFetching 去重，属 best-effort 触发，不影响数据正确性。
- `CullingGrid.swift:326-334` / `GalleryGrid.swift:62-72`：去掉 `Array(rows.enumerated())` 包装；行身份仍是 Int offset（`CullingGridRow.id == offset`；Gallery 用 `rows.indices` 的 self），值不变。

## 4. Gallery 渲染审计 + 修复

### 4.1 已修复
- `GalleryLayoutCache.rowIndex(containing:)`：建行时顺手建 `rowByItemIndex: [Int: Int]`（`GalleryGrid.swift:14-47`），方向键移动从 O(rows×items) 扫描 → O(1)。`store(key:rows:)` 是唯一写入口（reset 同步清表）。
- `GalleryGrid` 行 ForEach 去掉 enumerated 包装（见 §3.5）。
- 场景标签种子改走 VM 的 `sortedSelectedIds`（§3.3）。

### 4.2 审计结论（ranked residual）
| 优先级 | 项 | 位置 | 说明/建议 |
|---|---|---|---|
| P2 | 网格/胶片条缩略图解码桶偏大 | `Gallery/GalleryGrid.swift:181` → `GalleryCellView.swift:40`；`Culling/CullingFilmstrip.swift:145` | Gallery 用 `thumbnail_size` 设置桶（默认 1024）解码，而单元格约 160–300pt、@2x 实际需 600–720px；胶片条 140×100pt 用 size 256。改小=用户可见清晰度/设置语义变化，**非安全**，仅记录（Support 侧 perf-runtime 负责最终解码策略）。 |
| P2 | `moveGalleryCursor` 锚点 O(k) | `GalleryView+Content.swift:331-347` | `selectedIds.compactMap { indexByID[$0] }.min()` 方向键每次 O(选中数)；常规选择小，⌘A 全选时 O(k)。可加 VM 缓存"首个可见选中项"（key=filtered 代数+selectionVersion），但需新缓存维度，本轮未做。 |
| P2 | `openPendingPhotoIfAvailable` 两次线扫 | `GalleryView+Content.swift:134-146` | 入口意图一次性调用，可接 `filteredPhotoIndexByID`（id 分支），filepath 分支需 path→index 表；收益低。 |
| P3 | `layoutRows` 每 body 拼 cache key 字符串 | `GalleryGrid.swift:88-97` | key 含 `filteredFingerprint` 字符串（既有）；可改为结构化字段比较，收益 ns 级，未做。 |
| P3 | `GalleryView+Content.toggleGalleryCursor` 的 `selectedIds.first(where:)` | :355-372 | O(k) 且语义依赖 Set 迭代序（既有实现如此），改 min-index 会改变"不确定中取谁"的次序，**保留原语义**。 |
| P3 | Gallery 无主动预取 | `GalleryGrid.swift` | 网格靠 LazyVStack onAppear 加载；灯箱 ±1 预取（LightboxView:326-341）已与显示同键、受解码闸门约束。 |
| — | Lightbox `currentPhoto/currentIndex` | `Gallery/LightboxView.swift` | round-3 已改 O(1) indexByID；本轮无新增问题。 |

## 5. Culling 残余（ranked；未改，需真机/更大改动）

| 优先级 | 项 | 位置 | 说明 |
|---|---|---|---|
| P2 | `CullingComparison.assets/surveyAssets` 每次 body 对 page 做 filter + firstIndex | `Culling/CullingComparison.swift:18-33,53-67`；调用 `CullingWorkbenchViewer.swift:937-950`、`CullingSecondDisplay.swift:197-216` | 仅 2/3/4/Survey 对比布局每帧 O(page)；可加"调用方已算 selectedAssets/currentIndex"的重载（纯函数 + 单测同步），并配合 VM 缓存"页内选中资产"。风险：改公共纯函数 API，建议单独 task。 |
| P2 | 组视图 `reprojectIfNeeded` 每次 pageVersion 变化跑 projection + matches | `CullingViewModel+Grid.swift:471-483`、`CullingGrid.swift:314-324` | 决策回显 bump 版本 ⇒ 组视图下每拍 O(n log n) 投影比较；可先用"同 id 序列"快速判定 no-op（复用 §1 的序列比较思路），需确认投影语义。 |
| P2 | 网格 body 每帧读 `assets`（page?.assets 拷贝）+ ForEach cells | `CullingGrid.swift:305,317-344` | 数组 COW 拷贝 O(1)，主要是 SwiftUI 视图构建；无法安全进一步降。 |
| P3 | `CullingTriageCard` / `CullingKeywordPanel` 的 `Array(...enumerated())` | `CullingTriageCard.swift:204`、`CullingKeywordPanel.swift:486` | 元素 ≤30/少量，收益低。 |
| 需 macOS 验证 | 两个网格/胶片条 ForEach 数据集合类型变化 | §3.5 | 身份值已证明相同（offset/photo.id），但 SwiftUI 的 diff/复用行为**只能在 macOS 真机确认**；若真机出现滚动/动画异常，回退到 Array(enumerated()) 仅损失一处分配。 |

## 6. 验证（命令 + 结果）

### 6.1 语法检查（Swift 6.2）
```
.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <file>
9/9 改动文件 EXIT:0（ALL_PARSE_OK）
```
覆盖：`CullingViewModel.swift`、`CullingViewModel+Navigation.swift`、`CullingInspector.swift`、`CullingGrid.swift`、`CullingFilmstrip.swift`、`GalleryViewModel.swift`、`GalleryViewModel+Derived.swift`、`GalleryInspector.swift`、`GalleryGrid.swift`。

### 6.2 仓库门禁（最终复跑，全部 exit 0）
| 门禁 | 结果 |
|---|---|
| `./scripts/check-perf-ratchet.sh` | **OK**：`raw_date_formatter 28/28`、`raw_iso_formatter 30/30`、`raw_json_encoder 45/45`、`raw_json_decoder 38/38`、`raw_regex_compile 3/3`、`raw_byte_formatter 1/1`、`blocking_sleep 0/1 improved`（无新增构造点） |
| `./scripts/check-cleanup-ratchet.sh` | **OK**：`unchecked_sendable 60/60`、`try_optional 256/257 improved`、其余 0/0 |
| `./scripts/check-design-system.sh` | **PASS: no regression**（exit 0；未改 baseline；`empty.contentUnavailable 6/10 improved` 来自同伴迁移） |
| `./scripts/check-preview-surface.sh --strict` | **PASS: #Preview=14, preview files=12, lines=2210** |
| `./scripts/check-layering.sh` | **OK** |

### 6.3 语义/性能探针（Linux，真实 GatherProtocol DTO / 真实 JustifiedLayout；脚本在 .gather/tmp/）
- `PAGE_INDEX_REUSE_SEMANTICS_OK`（11 类场景与旧实现逐项对拍 + 205 次复用/1 次重建 + 155.5→44.5µs/决策）
- `GRID_LAYOUT_REUSE_SEMANTICS_OK`（6 类场景 rows 逐项相等 + 23.9→0.4µs/决策）
- `ROUND4_CACHES_EQUIVALENCE_OK`（Gallery rowIndex 映射 300 组随机行、sortedSelectedIds 500 组随机变更、navigationGroupSize 300 组随机组）

### 6.4 验证上限（必须保留）
- **未 macOS 编译/运行**：未跑 `swift build/test/check-warnings`、无 Instruments；`-parse` 不覆盖类型检查/严格并发，关键新写法已用独立小探针，但整套 GatherUI 需 macOS CI 复核（重点：ForEach 数据集合类型变化、`@ObservationIgnored` 缓存字段、`didSet` 计数）。
- 性能数字是 Linux corelibs 同环境 A/B；macOS 绝对值不同，但收益来自算法结构（消除 O(n) 重建/O(rows×items) 扫描/O(k log k) 排序）。
- 未新增/修改测试（写作用域不含 Tests）；建议为 pageIndex 复用语义与 grid 布局复用补单测（探针用例可直接转译）。

## 7. 改动文件（9）
| 文件 | 变更 |
|---|---|
| `Culling/CullingViewModel.swift` | page.didSet 赋值代数 + 不清索引（L38-51）；索引序列复用（L138-208）；similarGroupAssets 缓存（L240-259）；sortedSelectedIds（L275-291）；activeFilterCount 零分配（L107-124）；navigationGroups 代数（L308-317） |
| `Culling/CullingGrid.swift` | 布局缓存同几何复用（L217-300）；ForEach 去 enumerated（L326-334） |
| `Culling/CullingViewModel+Navigation.swift` | group size 字典缓存（L230-244） |
| `Culling/CullingInspector.swift` | 种子快路径重载（L28-35）+ 使用 sortedSelectedIds/similarGroupAssets（L695-701,811-817） |
| `Culling/CullingFilmstrip.swift` | ForEach 去每帧数组分配 + O(1) 续页下标（L70-90） |
| `Gallery/GalleryViewModel.swift` | selectedIds didSet/selectionVersion/sortedSelectionCache（L262-270） |
| `Gallery/GalleryViewModel+Derived.swift` | sortedSelectedIds 缓存（L160-176） |
| `Gallery/GalleryInspector.swift` | 种子用 sortedSelectedIds（L106-109） |
| `Gallery/GalleryGrid.swift` | rowByItemIndex 映射（L14-47）；ForEach indices（L62-72） |

未改：`Resources/en.lproj/**`、`Support/L10n.swift`、`Support/GatherLocalization.swift`、design-system baseline、Support/PhotoThumbnailView.swift、Support/ThumbnailDiskCache.swift、GatherHost/AppBootstrap、core 服务、其他 agent 文件。
