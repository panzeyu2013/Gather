# R2 独立评审：gather-app（GatherUI / GatherHost）本地-vs-上游改动

- 评审人：review-app（R2 独立评审，非改动作者）
- 评审对象：`origin/main...HEAD`（e5c54f37 → 5ea5c38f，16 commits，220 files）中
  `desktop/native/gather-app/Sources/**`（以及直接相关的 l10n / design 门禁基线）。
- 写作用域：仅本文件。只读评审，未改任何源码/测试/脚本；探针只在 `.gather/r2app/`。
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode。Swift 6.2（`.gather/swift62/usr/bin/swiftc`）
  仅做 `-parse`/纯逻辑探针；**未编译 AppKit/SwiftUI、未运行 App、无 Instruments**。
- 方法：`git diff origin/main...HEAD` + 逐 commit 的 `git log -S` 定位；读改动后真实上下文；
  `swiftc -parse` 全量 331 个 app source 文件；仓库门禁；对纯逻辑（Foundation/Observation、
  PageAssetIndex、selectionSummary、Gallery 查询表、JustifiedLayout、DateFormatting、
  ByteCountFormatter / ISO8601DateFormatter）写独立 Linux 探针做旧/新对拍。
- 文档中的 round3/round4 审计结论按"假设"处理，逐条对照代码与探针复核。

## 0. 结论摘要

- **未发现 P0**（编译破坏/崩溃/数据丢失/安全回归）：没有静态证据。
  - **但有 1×P1 会打红 macOS CI**：`GalleryLayoutCache.rowIndex` 只读新 map，未改动的既有测试
    `JustifiedLayoutTests.layoutCacheMapsItemIndexToRow` 直接写 `cache.rows` 后断言行号 ⇒ `swift test` app 套件必失败
    （A0；非产品运行时 bug，但阻塞合并，修复一行/测试改造即可）。
  - 331/331 app source 文件 `swiftc -parse` 通过（EXIT 0）；关键新写法（@Observable + didSet、
    跨文件 extension 内 nested cache 类型、`nonisolated static` 预取探测）已用 Linux 独立探针 typecheck；
  - 仓库可跑门禁**全绿**：`check-repo-hygiene` / `check-design-system`（基线已收紧）/ `check-cleanup-ratchet` /
    `check-perf-ratchet` + `check-layering` / `check-domain-events` / `check-domain-writes` / `check-no-legacy` /
    `check-select-star` / `check-coded-errors` / `check-backlog-evidence` / `check-preview-surface` /
    `check-docs-facts`，以及 CI 同款 strict 模式（duplicate-symbols/test-catalog/preview-surface/
    select-star/protocol-surface）—— 全部 EXIT 0（见 §2.7）。
- **1×P2 行为回归（Observation 依赖）**：`navigationGroupSizeByPhotoID` 缓存命中路径不再读
  `navigationGroups`，导致仅在 `navigationGroups` 变化时 CullingGrid 不会重算（组计数徽标可陈旧）。
  与 round-3 已按 P0 修掉的 `selectionSummary` 属同一类陷阱，本处漏了同样的"无条件读"补丁
  （当前流程里 `notice`/`errorMessage` 的变化大概率会让父视图重绘、把问题掩盖，属潜在缺陷，见 A1）。
- **1×P2 瞬时错图风险**：`LightboxView.resolvedCurrentIndex` 只校验下标在界内、不校验
  `photos[index].id == currentID`；`photos` 重排/插入/删除后、`onChange` 重建 map 之前的那次 body
  可能显示另一张照片（并预取错的邻居）。旧实现逐帧按 id 线性查找没有该问题。
- **1×P2 行为变化需 macOS 实测**：`PhotoThumbnailCache.setImage` 的 NSCache cost 从"点"改"位图像素"，
  对带 300dpi 元数据的相机 JPEG cost 最高约 17×，512MB 上限下 2560 预览可能从数百张降到约 24 张
  → 淘汰/命中率行为明显变化（语义上更准，但会反向影响它服务的性能目标；无测试/无基准）。
- **其余为 P3**（缓存键/一次性标志/计时标签/打包截断/内存重复/线程安全规范一致性等，见 §1）。
- round3/round4 文档的核心 claim（PageAssetIndex 复用、Grid 布局同几何复用、selectionSummary、
  Gallery 查询表、ForEach 身份）**经独立复核成立**（含我自己的随机对拍，见 §2）。
- 设计令牌/空态/文案迁移：104 处 `.font(...)` → `GatherFont.*` 全部逐字等价（按 GatherStyle.swift
  定义脚本比对）；设计 ratchet 基线**收紧**（font.callout 86→0、empty.contentUnavailable 28→10、
  theme.legacyAlias 15→1）；en.lproj **无 key 删除**、新增 2 个 key 且占位符数量一致；空态品牌化是
  round-2 文档已披露的有意视觉变化（17 处页面级迁移 + 3 处按策略保留）。

## 1. Findings

> 位置均为改动后 HEAD 的 `desktop/native/gather-app/` 相对路径。
> "macOS 不可验证"一列为 Yes/Partly/No：Yes = 结论依赖 macOS 运行时行为（SwiftUI 更新顺序、
> NSCache 淘汰、Apple Foundation 差异），静态/探针只能给结构证据。

| ID | 严重度 | 位置（file:line / commit） | 问题 | 证据（我检查/运行了什么） | 建议修复 | 置信度 | macOS 不可验证 |
|---|---|---|---|---|---|---|---|
| A0 | **P1（CI 必红）** | `Sources/GatherUI/Gallery/GalleryGrid.swift:14-47`（新 `rowByItemIndex`）vs 未改动的测试 `Tests/GatherAppTests/JustifiedLayoutTests.swift:172-200`（commit 2cbe3e68） | `GalleryLayoutCache.rowIndex(containing:)` 改成只读 `rowByItemIndex`；该 map 只在 `store(key:rows:)` 里构建。既有测试 `layoutCacheMapsItemIndexToRow` **直接给 `cache.rows = [...]` 赋值**（不经过 store）后断言 `rowIndex(containing: 0) == 0` ⇒ map 为空 ⇒ 返回 nil ⇒ **`swift test`（app 套件）必失败**。生产路径只用 `store`，所以这不是产品运行时 bug，但会把 macOS CI 打红、阻塞合并。 | 读源码 + 读测试（测试文件在本 diff 中**未被修改**：`git diff --numstat origin/main...HEAD -- JustifiedLayoutTests.swift` 空）；`grep` 确认测试直接写 `cache.rows` 的只有这一处、`GalleryLayoutCache` 无其它写入方。 | 二选一（推荐前两个）：(a) `rowIndex(containing:)` 在 map 未命中时回退一次线性扫（map 只会在直接写 `rows`/首帧空时为空，热路径仍 O(1)）；(b) 给 `rows` 加 `didSet` 重建 map（`store` 只写 rows）；(c) 改测试为调用 `store(key:rows:)`（需测试写作用域）。 | 高 | No（纯逻辑，可在 Linux 复现；我未实际跑 macOS 测试） |
| A1 | **P2** | `Sources/GatherUI/Culling/CullingViewModel+Navigation.swift:234-244`；消费点 `Culling/CullingGrid.swift:319,341`（commit 2cbe3e68） | `navigationGroupSizeByPhotoID` 的**缓存命中路径只读 @ObservationIgnored 的 `navigationGroupsVersion`，不读 `navigationGroups`**。首次 body 求值会 miss 并登记依赖，但之后每次 body 都命中缓存 ⇒ `navigationGroups` 的依赖被"漏登记"；`analyzeNavigation()` / split / merge / `loadNavigation()` 只写 `navigationGroups`、不 bump `pageVersion`（+Navigation.swift:15,28,51,73），CullingGrid body 里也没有其它地方读 `navigationGroups`（`isNavigationGroupViewActive` 只读 filterState）⇒ 网格「组 N 张」折叠徽标可一直陈旧到下一次其它观察属性变化（点选照片等）。旧实现每次读都重建字典、天然登记依赖。 | 读 diff + 调用点；Linux Swift 6.2 `withObservationTracking` 探针（`.gather/r2app/obs2/main.swift`）：缓存命中路径不读底层属性时 onChange **不触发**（fired=false），加 `_ = groups.count` 后触发（fired=true），直接 miss 路径也触发。与 `docs/reviews/2026-11-17-round3-perf/perf-ui-round3.md` §1.3 对 selectionSummary 的同型实验一致。 | 命中路径先无条件读一次受观察属性（`_ = navigationGroups.count`）再返回缓存；`similarGroupAssets(inCurrentPage:)` 同理补 `_ = page` 作为防御（当前调用点先读 currentAsset 所以未触发，但模式相同）。 | 高 | Partly（SwiftUI 用同一 Observation 机制；未真机复验） |
| A2 | **P2** | `Sources/GatherUI/Gallery/LightboxView.swift:54-66`（resolvedCurrentIndex）、`:92-99`（onChange 重建） （commit 2b9bf100/2cbe3e68） | `resolvedCurrentIndex` 命中 `indexByID[currentID]` 时只做 `photos.indices.contains(index)`，**不校验 `photos[index].id == currentID`**。事件刷新（增删/重排 filteredPhotos）后子视图 body 若先于 `.onChange(of: photos)` 重建 map 执行，旧下标指向**另一张照片**：该帧显示错图、`prefetchAdjacent` 预热错邻居。旧实现每次 `photos.first { $0.id == currentID }` 恒按身份定位，无此窗口。注释声称"映射滞后…回退一次线性查找"，但该回退只覆盖"id 不在 map / 越界"，不覆盖"同一下标换了 id"。 | 读代码 + onChange/body 语义分析；无 macOS 运行时。回退分支条件核对（:56-58）。 | `if let i = indexByID[currentID], photos.indices.contains(i), photos[i].id == currentID { return i }` 再走线性回退；或每次 body 对命中项做一次 id 断言（O(1)）。 | 中 | Yes（SwiftUI body/onChange 顺序） |
| A3 | **P2** | `Sources/GatherUI/Support/PhotoThumbnailView.swift:803-824`（commit 2cbe3e68） | NSCache `cost` 由 `NSImage.size`（点）改为最大 rep 的 `pixelsWide×pixelsHigh`（像素）。语义上修掉了 DPI 元数据导致的低估，但**行为变化大且未实测/无测试**：2560px 预览 cost 约 2560×1707×4×1.2 ≈ 21MB，512MB `totalCostLimit` 约只能放 24 张（旧按 300dpi 折算点尺寸时约 1.2MB ⇒ 数百张）。相机 JPEG 常带 300dpi ⇒ 快速连拍浏览/4 宫格时淘汰显著变多，可能反而降低命中率。 | 读代码 + 成本算术；无 macOS benchmark（`grep` tests 无 cost 断言）。 | 保留像素口径但同步重估并放大 `totalCostLimit`（如 1–2GB）或按 rep 的 `bytesPerRow×pixelsHigh` 精确计；补 cost 单测；macOS 上测命中率/内存峰值。 | 中 | Yes（NSCache 淘汰/真实内存） |
| A4 | P3 | `Sources/GatherUI/Support/DateFormatting.swift:54-61,94-125`（另 pre-existing `mediumShort` :64-73） | `pattern`/`localizedTemplate`/`shortShort` 拿到共享 `DateFormatter` 后在**锁外**调用 `string(from:)`；Apple 未承诺 DateFormatter 并发安全。同文件新增的 `fileSize`/`internetDateTime*`/`parseFixedUTC` 都持锁格式化，规范不一致。旧实现每次新建 formatter，天然线程安全。（`mediumShort` 是既有实现，但本 diff 新增了逐行调用点 `Metadata/MetadataBatchSheet.swift:99+`。） | 读代码；Linux 32 线程 × 3000 次混合调用锤测 0 输出漂移（不能证明 macOS 安全）。 | 在锁内完成 `string(from:)`（性能代价极小），或注释/断言该类型只从 MainActor 调用；同时把 `mediumShort` 的 key 补上 Calendar/TimeZone（见 A5）。 | 中 | Partly |
| A5 | P3 | `Sources/GatherUI/Support/DateFormatting.swift:64-73`（既有 key 不足），新增使用点 `Metadata/MetadataBatchSheet.swift` | `mediumShort` 缓存键只有 locale identifier，不含 `Calendar.current`/`TimeZone.current`（新方法 `environmentKey` 都含）。本 diff 把"每行新建 formatter"的批次行时间迁到该缓存；运行中改系统时区后，批次行时间会停在旧时区直到重启（旧实现每行新 formatter 会跟随）。 | 读代码；对比 `environmentKey(:locale:)` (:180-182)。 | `mediumShort` 改用 `environmentKey("mediumShort", locale:)`。 | 高 | Partly（系统时区变更时机） |
| A6 | P3 | `Sources/GatherUI/Support/ThumbnailDiskCache.swift:49-58`（commit 2cbe3e68） | `pruneAtStartupIfNeeded` 先消费一次性标志 `didStartupPrune` 再查 `isEnabled`；若未来任何调用点在其前/在未 enable 时调用，启动 prune 永久不跑。另 detached prune 未跟踪、shutdown 不取消（只删缓存文件，无正确性影响）。 | 读代码；`AppBootstrap.swift:277-280` 当前顺序 isEnabled=true → call，生产路径 OK。 | 先查 `isEnabled`（锁外快速返回），确认 enable 后再 CAS 标志；或在文档中写明 order 约束。 | 高 | No |
| A7 | P3 | `Sources/GatherUI/Support/ThumbnailDiskCache.swift:105-142` | `touchIfStale` 每次命中多一次 stat、1h 内不写 mtime：LRU 精度降为 1h 粒度（热文件可能被当成 1h 前）；系统时钟回拨会让 touch 长期被跳过。读路径本身仍整读文件（既有）。 | 读代码 + 注释口径。 | 可接受则保留并在文档记录精度取舍；若要更准用内存 last-touch 表（无 stat/写）。 | 高 | No |
| A8 | P3 | `Sources/GatherHost/AppBootstrap.swift:189-194,423-439`（commit 0240eb56） | 启动计时语义：`runtimeStart` 记录"发射→await 完成"的**墙钟**，包含与之并行的 `languageSeed`；日志文案却称各阶段"自耗时"⇒ 各行相加会大于 total，误导后续性能分析。并行化本身静态检查未发现共享可变状态（见 §2），但无新测试固定"两者都在 scene 发布前完成"的约束。 | 读 diff + grep（`GatherLocalization` 仅被 GatherHost/LiveSettingsAPI 与 AppBootstrap 引用，`AppRuntime.start`/JobService/WorkflowRegistry 路径零引用）；DB 串行说明见代码注释。 | 分别用"外/内层"时钟测净耗时（或 rename 为 wall/overlap 字段），并在日志里标注 languageSeed ∥ runtimeStart。 | 高 | Partly（真实启动时序/DB 锁竞争） |
| A9 | P3 | `Sources/GatherUI/Culling/CullingFilmstrip.swift:74-86`（commit 2cbe3e68） | 续页 onAppear 用的下标从"body 快照 enumerated 位置"改为 `pageIndex(ofPhotoId:)`（重复 id 取首个）。页内出现重复 photo id（追加页/刷新竞争）时，尾部 4 张触发 loadMore 的位置可与旧实现不同；重复 id 本身也会破坏 ForEach 身份（既有问题）。round4 文档披露了"body 快照 vs 当前页"窗口，未提重复 id。 | 读代码 + round4 文档 §3.5；无证据表明实际会出现重复 id。 | 基本可接受；若要严格等价可保留 (id, offset) 快照或给 ForEach 独立 identity。 | 高 | No |
| A10 | P3 | `Sources/GatherUI/Culling/CullingGrid.swift:298-302`（commit 2cbe3e68） | `packedSize` 用 `UInt64(max(1,w)) << 32 | height & 0xFFFF_FFFF`：width/height > 2^32 时高位被丢弃/截断，理论上可碰撞；当前 `PhotoData.width/height` 是 Int 且来自照片元数据，>4.29e9 px 不可达。0/负值与布局输入的 `max(1,...)` 口径一致（已探针核对）。 | 读代码 + Linux 探针（clamp/打包语义）。 | 打包前 clamp 到 `UInt32.max`，或直接缓存 `(Int,Int)` 元组比较。 | 高 | No |
| A11 | P3 | `Sources/GatherUI/Gallery/GalleryViewModel+Derived.swift:43-105`（commit 2b9bf100/2cbe3e68） | `loadedPhotoLookup` 自己再建一份 `ids: Set<String>`，与 `flatCache.ids` 内容重复（已加载集大时是两倍 id 集合内存），且与 `loadedPhotosAndIDs()` 分两次建表。 | 读代码。 | `loadedPhotoLookup` 直接复用 `loadedPhotosAndIDs().ids`。 | 高 | No |
| A12 | P3 | `Sources/GatherUI/Gallery/GalleryView+Content.swift:337-339`（commit 2cbe3e68） | `moveGalleryCursor` 锚点 `selectedIds.compactMap { indexByID[$0] }.min()` 每次按键 O(选中数)；⌘A 全量选择（上万）时每次方向键 O(k)。round4 文档已记录为 P2 残余，未修。 | 读代码 + 文档 §4.2。 | 可选：VM 内缓存"首个可见选中项"（key=filtered 代数 + selectionVersion）。 | 高 | No |
| A13 | P3（信息） | `Sources/GatherUI/Support/JSONValueDecoding.swift:63-68` | `JSONValue.init(from:)` 改走共享 `JSONValueCoding` 的 JSONEncoder/JSONDecoder（单例类）。默认配置与旧"每次新建"逐字节等价（已核对 Core.swift:122-125 的默认 encoder/decoder 与 DescriptiveMetadata.swift:774-776 复用路径）；风险仅是"共享 coder 被并发使用"（Foundation 的 JSONEncoder/Decoder 在 Swift 6 为 @unchecked Sendable，且全仓库没有修改其配置的代码）。 | 读代码 + grep `JSONValueCoding` 全部引用（无 mutating/配置写入）；core 测试 `JSONValueCodingTests` 断言字节等价的基线。 | 无需改；若担心共享 coder，可保留现状（与 core 侧一致）。 | 高 | Partly |
| A14 | P3 | `Sources/GatherUI/Culling/CullingViewModel.swift:45-51`（page.didSet 的“任何赋值路径”承诺）vs `Culling/CullingViewModel+Keywords.swift:42-46` | 新 `page.didSet` 只失效 `pageAssetIndexCache`/`selectionSummaryCache`；`keywordTargetIndexCache` 仍只按 `selectionKey + pageVersion` 失效。若出现“直接赋值 page 且不 bump pageVersion”的路径（测试已有多处直接赋值，生产 7 处都会 bump），关键词目标索引会陈旧。didSet 注释的“任何赋值路径”覆盖承诺与现状不完全一致（注释本身只声明 currentAsset 索引）。 | `grep -n "vm.page = CullingPage" Tests`（CullingGridPerfTests/CullingGridInteractionTests/CullingKeywordViewModelTests 直接赋值且不 bump）；读 keywordTargetIndex 缓存键。 | 若要彻底一致：page.didSet 里顺带 `keywordTargetIndexCache = nil`（或让该缓存 key 改用 pageAssignmentCount）。 | 高 | No |

## 2. Verified OK（我独立验证过的点）

### 2.1 CullingViewModel page/index/selection 状态（task-27 hotspot 1）

- **`page.didSet` 覆盖所有赋值路径**：`CullingPage`/`CullingAsset` 均为 struct、Sendable
  （`GatherProtocol/Protocol/Culling.swift:253,298`），页内不存在绕过 setter 的原地修改路径
  （`grep` 全 app Sources 的 `page` 写点只有 7 处生产赋值，全部走 `page = …`）；`page = nil`
  也触发 didSet（清索引缓存）。
- **7 处 page 赋值全部 bump `pageVersion`**：+Load:193/221（page 赋值在 226/236）、+Actions:38-39、
  +Grid:463-464/499-500、+Load:88-89；其中无会话路径（+Load:190-196）是本 diff **新补**的 bump
  （审计所述"唯一没有显式 bump 的路径"已修）。
- **PageAssetIndex 语义等价**：Linux 探针（`.gather/r2app/idx_probe.swift`，3000 组随机页/状态替换/
  重排/追加/空页/nil 页/重复 id/缺失 id/currentPhotoId 空或不在页）对旧 `first(where:)`/
  `firstIndex(where:)` 逐项对拍：`currentAsset`(含 state)、`pageIndex`、`pageAsset`、
  `currentPageIndex` **0 mismatch**（assignments=4091，含 205 次复用/1 次重建的语义分支）。
  重复 id 保留首个、currentPageIndex 的 nil→无页/空页、0→id 空/不在页，与旧调用点 `?? 0` 口径一致。
- **`similarGroupAssets` 缓存键（page 赋值代数 + groupId）**：同一键 ⇒ 同一 page.assets 序列 ⇒
  filter 结果相同；页被替换（含决策回显只改 state）时赋值代数必变 ⇒ 重算。旧实现是纯 filter，
  语义一致。（Observation 依赖见 A1 的同类建议，当前调用点先读 currentAsset，未实测到陈旧。）
- **`selectionSummary` 缓存**：`page.didSet` 显式清空 + key=(pageVersion, selectionVersion)，
  两个计数器单调且所有写入都会前进；Linux 探针 10000 次随机操作（页替换含 bump/不 bump、
  选择集赋值/insert/remove/removeAll/formIntersection/subtract/跨页 ghost id）对拍旧纯计算：
  **0 mismatch**。getter 无条件读 `selectedPhotoIds.count` 与 `pageVersion` 保证 Observation 依赖
  （与 round3 文档 §1.3 的探针结论一致；我用 `.gather/r2app/obs_probe.swift` 复核了
  "@Observable + didSet 正常触发"与"Set mutate 触发 didSet"）。
- **`sortedSelectedIds`**：命中路径先读 `selectedPhotoIds.count`（观察依赖保留）；
  `filter { !$0.isEmpty }.sorted()` 与旧 `SceneTagsEntryPolicy.seedPhotoIds(selection:)` 的
  `Set(filter).sorted()` 等价（Set 去重 + 同排序，调用方 Gallery 同样口径）。
- **`activeFilterCount`**：逐项 if 计数与旧"7 元素布尔数组 filter().count"结果逐一对应（7 个维度
  顺序无关），代码直读核对。
- **`currentPageIndex()` 语义**：nil=无页/空页、0=currentPhotoId 空/不在页；所有 4 个调用点保持
  `?? 0`，与旧 guard-else-0 等价（探针逐案对拍）。

### 2.2 CullingGrid 布局缓存与 ForEach 身份（hotspot 2）

- **快路径保持旧 key 语义**：旧 key = `version|assets.count|Int(width)|Int(rowHeight)`；新快路径
  条件 = version + Int(width) + Int(rowHeight) + count 全等 ⇒ 与旧命中集合一致。
- **同几何复用条件**：精确 width/rowHeight 相等 + id 序列 + 打包宽高序列相等；布局函数
  `layoutJustifiedRows` 只消费（顺序、宽高比、containerWidth、targetRowHeight、gap），
  调用点 gap=8 常量（CullingGrid.swift:491-499）⇒ 同条件必然同 rows。`sameGeometry` 用
  `max(1,w)/max(1,h)` 打包，与布局 source 的 `Double(max(1,…))` 口径一致（0/负值 clamp 一致）。
- **复用分支不重建缓存数组**：只更新 `cachedVersion`；条件保证 `cachedIDs/cachedSizes/count` 仍有效。
- **ForEach 身份**：`ForEach(rows(...))` 依赖 `CullingGridRow.id == offset`（struct 已有
  Identifiable），与旧 `ForEach(rows, id: \.offset)` 的 id 类型/值完全相同；行的 `.id(asset.photo.id)`
  滚动目标未改。
- **`currentGroupAssets` 在 CullingInspector body 顶部只算一次**、`knownGroupCount(for:)` 传参复用，
  与旧"每处读取各扫一遍"结果相同（纯读派生）。

### 2.3 Gallery（hotspot 3）

- **`loadedPhotoLookup` / `filteredCache.ids` / `indexByID`**：均按"重复 id 取首个"构建
  （与旧 `first(where:)`/`firstIndex(where:)` 同义）；`locatePendingPhoto` 的 isFound/isFoldedVariant
  集合判定与旧 contains 逐项等价（id/路径/变体 id/变体路径四组）。
- **失效键**：`flatCache`/`loadedPhotoLookupCache` 用 `pagesGeneration`；grep 到 `pages` 全部写点
  （+Scroll:174、+Load:258、+Filter:118、+Events:93）都在同一同步段内 `pagesGeneration += 1`；
  `filteredCache` key 含 generation/search/filter/serverCriteria/sort/stackFoldVersion（逐字沿用旧 key）。
- **键盘游标/打开灯箱**：`moveGalleryCursor` 的锚点 min-index 等于旧 `photos.first(where: selected)`；
  `openGalleryCursor`/`openSelectedInLightbox` 的 min-index 等于旧 first(where:)+firstIndex；
  `toggleGalleryCursor` 的 Set 迭代序保持旧语义（文档明确保留"不确定中取谁"）。重复 id 场景
  indexByID 首值 = 旧 firstIndex 首值。
- **Lightbox 正常路径**：`currentPhoto`/`currentIndex` 在 id 缺失/空数组/currentID nil 时的回退
  （nil / 0）与旧实现一致；`prefetchAdjacent` 改收下标语义等价（旧 `firstIndex` 失败时不预取）。
  （stale-map 边界见 A2。）
- **GalleryLayoutCache.rowByItemIndex**：`store(key:rows:)` 建 item→row 映射（重复 index 取首个），
  `rowIndex(containing:)` 由 O(rows×items) 扫描改 O(1)，与旧 `rows.firstIndex { items.contains }`
  同义；`reset()` 同时清 rows/key/map，`GalleryView.swift:168` 在 filtered 变化时 reset。
  **但**：`rows` 仍是可直接写的 internal 字段且不重建 map，既有测试直接写 `rows` ⇒ 见 A0（CI 红）。
- **GalleryGrid ForEach**：`ForEach(rows.indices, id: \.self)` + `.id(index)`，行身份仍是 Int 下标，
  与旧 `Array(rows.enumerated()), id: \.offset` 的值集合相同。

### 2.4 DateFormatting（hotspot 4）

- **真实源码可在 Linux 编译**：把 `Support/DateFormatting.swift` 原样拷入探针直接 `swiftc` 编译
  （无 SwiftUI 依赖）→ 成功；用它做 oracle 对拍：
  - `mediumShort` / `pattern`（5 种 pattern）/ `localizedTemplate(yMd)` / `shortShort` /
    `internetDateTimeString` / `formatFixedUTC` / `fileSize`：5 locales（zh_CN/en_US/de_DE/ar_EG/th_TH）
    × 4 dates × 3 TZ（Asia/Shanghai、America/New_York、Europe/Berlin），对拍"每次新建同配置 formatter"
    → **0 mismatch**（唯一命中是我探针里故意用 `yyyy-MM-dd'T'HH:mm:ss` 解析带小数秒日期的截断假阳性，
    与实现无关）。
  - `fileSize` 实例 vs 类方法 `ByteCountFormatter.string(fromByteCount:countStyle:)`：0/1/512/1024/
    2048/1000/1e6/5MiB/1GiB/-5 全部逐字节相同（Linux corelibs）。
  - `internetDateTime` / `internetDateTimeWithFractionalSeconds`：与新建
    `ISO8601DateFormatter`（显式 `[.withInternetDateTime]` / +`.withFractionalSeconds`）对拍，
    含 +00:00/+08:00 偏移、坏输入 nil 语义 → 一致。
  - `parseFixedUTC`/`formatFixedUTC`：en_US_POSIX + UTC + 固定 pattern，行为与旧内联实现一致
    （round-trip 有我探针的截断假阳性，非 bug）。
- **仓库已有 oracle 回归测试**：`Tests/GatherAppTests/DisplayDateFormattersTests.swift`（commit 708a6b89）
  把 mediumShort/pattern/localizedTemplate/shortShort/ISO 解析钉在"新建 formatter" oracle 上 —— 该测试
  覆盖了主要新增 API（未覆盖 fileSize/formatFixedUTC/mediumShort 环境键，见 A5；无法在本机运行）。
- **缓存键**：pattern/localizedTemplate/shortShort 的 key 含 locale + `Calendar.current.identifier` +
  `TimeZone.current.identifier`，覆盖旧实现"每次新建取调用时环境"的语义（本轮新方法如此；
  mediumShort 的既有缺项见 A5）。
- **调用点格式语义逐处核对**（旧 vs 新，逐字节同配置）：
  ExportViewModel.namingPreview（yyyy-MM-dd/HH-mm-ss + .current）、WebDAVPublishSheet.historyTime
  （short+short + .current 与旧"不设 locale"等价）、linkExpiryText、MetadataBatchSheet.displayDate
  （先带小数秒解析→回退 plain；样式 medium+short + l10n.locale，与旧完全一致）、MetadataEditorDraft.
  shiftedDateTime（en_US_POSIX/UTC/固定 pattern）、PersonsView.dateText（zh 固定 pattern / en yMd 模板，
  与旧"locale+dateFormat/template"一致）、C1StatusCapsule.formatTime（plain ISO 解析 + locale + 固定 pattern）。
- **线程安全**：新增的 fileSize/ISO/fixedUTC 都在锁内使用共享 formatter；pattern 系列锁外使用的
  风险与既有 mediumShort 相同（A4），Linux 32×3000 混合锤测 0 漂移。
- **"不设 locale" vs `locale: .current` 等价**：namingPreview / historyTime / shortShort 的旧实现
  不显式设 locale（默认 current），新实现显式传 `Locale.current`；Linux 探针对拍
  `DateFormatter()`（无 locale）与 `DateFormatter(); locale = .current` 在 3 组 LANG 下输出一致。
  唯一可感知差异是运行中系统时区/日历变化时的缓存跟随（A5）。

### 2.5 AppBootstrap 启动并行化 / 缓存边界（hotspot 5）

- **并行顺序安全（静态）**：`runtime.start` 与 `languageStore.seed` 互不共享可变状态
  （grep `GatherLocalization` 只在 GatherHost/LiveSettingsAPI 与 AppBootstrap；runtime.start 路径
  AppRuntime/JobService/WorkflowRegistry 无引用）；两者都在 `wire(jobEvents:)`/`embeddingPrep`/
  scene 发布之前 await 完成；失败路径仍先完成 languageSeed 再抛 runtime.start 错误（与旧可观测顺序
  一致）；DB 访问经同一 DBConnection/连接锁串行（代码注释 + DB 实现既有约束）。
- **计时代码本身安全**：`startupTicks()` 用 `DispatchTime.uptimeNanoseconds`（单调）；差值
  `&- / &+` 防溢出；7 个阶段各只记一次；每冷启动一行 info 日志（成本可忽略）；
  `firstScene` 在 scene 赋值后立即取值（真实首帧的上界，文档已写明口径）。失败路径只打总耗时。
- **`ThumbnailDiskCache.pruneAtStartupIfNeeded`（生产顺序）**：`makeScene` 先
  `ThumbnailDiskCache.isEnabled = true` 再调用（AppBootstrap.swift:277-280），utility 后台 prune，
  只删 thumb-cache 目录；一次性标志 + 锁内读取无竞态（A6 是健壮性建议）。
- **`PhotoThumbnailCache.setImage` cost 计算**：`max(0,w)*max(0,h)`、rep 取最大、小图 256KB 下限；
  int 溢出/负值路径有防护（真实图片尺寸下无风险；行为变化见 A3）。
- **`JSONValueDecoding`**：见 A13（等价已验证）。
- **`CullingViewModel+Preload.computePreloadMisses`**：`nonisolated static` + `Task.detached` 的
  调用链上 `PhotoThumbnailCache.image`/`ThumbnailDiskCache.data` 均为非 MainActor（该文件无
  @MainActor）；NSCache/磁盘缓存内部锁；结果只用于"是否预热"（best-effort），失败/竞态不改变正确性；
  `preloadPreviewDimension`/`isViewerPreviewCached` 标 nonisolated 后与单测注入签名兼容。
  `plan(assets:currentPhotoIndex:)` 与旧 `currentIndex(assets:currentPhotoId:)` 的 0 回退口径一致
  （+Preload.swift:126-131），旧入口保留。

### 2.6 设计令牌 / 文案 / a11y / 空态（hotspot 6）

- **字体令牌等价**：用脚本把所有 hunk 的 `-`/`+` `.font(...)` 配对（104 对），逐对按
  `DesignSystem/Tokens/GatherStyle.swift:7-33` 核对：callout↔secondary、callout.monospacedDigit↔mono、
  callout.weight(.semibold)↔secondaryStrong、headline↔cardTitle、title2.weight(.semibold)↔pageTitle、
  title3↔heroSubtitle、title3.weight(.semibold)↔sectionTitle、subheadline.weight(.semibold)↔eyebrow、
  body↔body、body.weight(.semibold)↔bodyStrong、.monospaced()/weight(.medium) 组合按令牌同构 →
  **全部逐字等价**（token 定义即同构造表达式）。数字→token 的 padding/spacing 抽查同样相等
  （Space.xs=4 等）。
- **设计 ratchet 基线只收紧未放宽**：`git diff` 显示 `font.callout 86→0`、`spacing.literalSpacing
  89→86`、`empty.contentUnavailable 28→10`、`theme.legacyAlias 15→1`；`check-design-system.sh` PASS。
- **l10n key 不丢**：`en.lproj/Localizable.strings` 改动 73+/69- 全部是 **value** 行（大小写/术语/
  标点/用词），用 awk 提取 key 集合对比 origin/main：**0 个 key 被删**，新增 2 个 key
  （`"%@，%@"`、`"%@（%@）"`，en 值 `"%@, %@"`/`"%@ (%@)"`，代码 `DuplicatesGroupCardView.swift:147`、
  `SemanticSearchSheet.swift:278` 使用）；zh-Hans 按设计回退 key（文件仅 11 行），无需新增。
  逐行占位符数量核对：所有变更行 key/value 的 %@/%lld/%d 计数一致（5 条含 \" 的行经人工核对也是
  一致：`%@` 转成弯引号但占位符保留）。`l10n("、")` 等标点 key 在 en 有 `"、" = ", "` 映射。
- **空态迁移内容等价**：17 处页面级 `ContentUnavailableView{Label(title,systemImage)} description
  actions` → `GatherEmptyState(icon:title:message:){actions}` 逐处映射（title/message/icon/按钮动作/
  disabled/help 保持）；剩余 `ContentUnavailableView` 6 处 = 2 处 Dashboard List Section 内联 +
  1 处 Persons `.search(text:)` + 3 处注释，与 round-2 文档（design-empty-round2.md §1）分类一致；
  该文档已明确披露"品牌空态是有意的视觉变化、无像素级验证"。
- **a11y**：抽查的 icon-only 按钮（CollectionView 重载/关闭、ExportView+Delivery 删除、FilterRuleEditor、
  LibraryView+Content 清除筛选、MetadataSyncBar 清理备份等）均新增 `.accessibilityLabel(l10n(...))`；
  `GatherEmptyState` 图标 `.accessibilityHidden(true)` + 标题 header trait。
- **未删任何 public API**：diff 的 `-` 行无 public/internal 声明被移除（`knownGroupCount` 改私有签名、
  `isViewerPreviewCached` 加 nonisolated、`plan` 加重载，均保留旧入口/签名兼容）。

### 2.7 构建/门禁

| 检查 | 结果 |
|---|---|
| `swiftc -parse -enable-bare-slash-regex` 全量 `gather-app/Sources/**/*.swift` | **331 parsed / 0 failed**（EXIT 0） |
| `./scripts/check-repo-hygiene.sh`（PATH 加 `.gather`） | **OK**（含 shellcheck / docs 链接 / UI 文案包裹 / CJK 字面量 1718 全包裹） |
| `./scripts/check-design-system.sh` | **PASS: no regression**（基线已收紧） |
| `./scripts/check-cleanup-ratchet.sh` | **OK（全部指标不超过 baseline）** |
| `./scripts/check-perf-ratchet.sh` | **OK（raw_date_formatter 28/28、raw_iso_formatter 30/30、raw_json_encoder 45/45、raw_json_decoder 38/38、raw_regex_compile 3/3、raw_byte_formatter 1/1）** |
| `check-layering` / `check-domain-events` / `check-domain-writes` / `check-no-legacy` / `check-select-star` / `check-coded-errors` / `check-backlog-evidence` / `check-preview-surface` / `check-docs-facts` | **全部 EXIT 0**（本机批量复跑） |
| CI 用的 strict 模式（与 `.github/workflows/ci.yml` 对齐）：`check-duplicate-symbols --strict`、`check-test-catalog --strict`、`check-preview-surface --strict`、`check-select-star --strict`、`check-protocol-surface --strict` | **全部 EXIT 0**（其中 `#Preview=14 / preview files=12 / lines=2210`、@Test 3267/2502、@Suite 419/283 等） |
| 全量门禁套件合计（`scripts/check-*.sh` 去掉 `check-appintents` 自检） | **全部可跑门禁 EXIT 0**；唯一红的是**未跑**：macOS 专属 `check-warnings.sh` 与 `swift test`（含 A0 预判的 1 例失败） |
| Linux 探针（`.gather/r2app/`） | PageAssetIndex 3000 组、selectionSummary 10000 组（均 0 mismatch）；DateFormatting oracle 对拍 0 mismatch；Observation didSet/依赖探针（缓存命中不登记依赖 ⇒ A1 的机制证据）；Swift 6 `-typecheck` 通过：@Observable+didSet、跨文件 extension nested cache、`nonisolated static`+`Task.detached` 预取探测模式 |
| 未能 typecheck 的源码 | `Support/ThumbnailDiskCache.swift`（`import CryptoKit` 在 Linux 无模块，无法整文件 typecheck；本轮只做了静态审查）；GatherUI/GatherHost 其余文件依赖 AppKit/SwiftUI，同样只能 `-parse` |

## 3. Coverage & Limitations

**覆盖范围（已做）**
- `git diff origin/main...HEAD -- desktop/native/gather-app/Sources` 全量浏览（4380 行 diff），
  逐文件读取改动后上下文；重点复读 hotspot 1–6 涉及的全部文件（CullingViewModel 系列、
  CullingGrid、CullingFilmstrip/InfoBar/SecondDisplay/WorkbenchViewer/Inspector、GalleryViewModel
  系列、GalleryGrid/GalleryView+Content/LightboxView/GalleryInspector、DateFormatting、
  AppBootstrap、ThumbnailDiskCache、PhotoThumbnailView、JSONValueDecoding、en.lproj、设计令牌迁移、
  空态迁移）。
- 逐 commit 定位（`git log -S` / `-L` 辅助）：2cbe3e68（round-4 Culling 缓存）、0240eb56（round-3
  O(1) 索引 + 启动）、2b9bf100（round-2 设计/l10n）、d1180d62、708a6b89（formatter 回归测试）、
  6fecfcce…5ea5c38f 的机械/门禁改动。
- 仓库门禁 + 全量语法 parse + 纯逻辑对拍探针（见 §2.7）。

**未覆盖 / 验证上限（必须保留）**
1. **无 macOS/Xcode：未编译、未链接、未运行 App，未跑 `swift build/test/check-warnings`**。
   `swiftc -parse` 只证明语法；全模块类型检查、严格并发（actor 隔离/Sendable 诊断）、
   AppKit/SwiftUI API 可用性、真实渲染都未验证 → 若存在类型/并发编译错误，本轮无法发现（A 类风险）。
2. **SwiftUI 运行时行为只能在 macOS 复验**：ForEach 数据集合类型变化后的 diff/复用、Observation
   body 失效时序（A1/A2 的触发窗口）、`onChange` 与 body 的先后、NSCache 淘汰与实际内存（A3）、
   品牌空态的像素级外观（round-2 文档已声明无像素验证）、日期/字节格式在 Apple Foundation 上的
   逐字节一致性（Linux corelibs 与 Apple Foundation 实现不同，探针只能给结构证据；仓库的
   `DisplayDateFormattersTests` 是 macOS 上的真正 oracle）。
3. **并发/时序类缺陷无法在 Linux 复现**：A2（瞬时错图）与 A1（陈旧徽标）是时序窗口，静态推演为主；
   A3 需要真实内存/命中率基准。
4. 未做全 App 的 a11y 穷举（只抽查本轮新增 label 的站点）；未做全量英文文案语义审校
   （只验证 key/占位符/术语方向，文案是否 HIG 风格由 ui-copy 负责）。
5. Tests 目录（`Tests/GatherAppTests/**`）不是本任务重点，但我对**与 Sources 改动直接相关的既有测试**
   做了兼容性核对：`DisplayDateFormattersTests` 新增且引用保留 API；`CullingNavigationViewTests` 仍用
   `navigationGroupSizeByPhotoID`（值语义未变）；`CullingPreloadTests` 走 `CullingPreloadPlanner` 旧入口
   （保留）。**发现 1 例必红：A0（JustifiedLayoutTests）** —— 该测试文件在本 diff 中未改，靠读代码 + 测试
   逻辑可确定会失败；其余测试未逐条推演（无法在本机运行）。
6. 文档中的性能数字（µs/帧、x 倍）是各 agent 的 Linux 探针结果，我未复跑基准；只复核了算法结构
   （O(page)→O(1)、O(rows×items)→O(1) 等）与语义等价。

## 4. 修复优先级建议（供 lead）

0. **A0（P1，合并前必修）**：`GalleryLayoutCache.rowIndex` 在 map 空时回退线性扫（或给 `rows` 加 didSet
   重建 map / 改测试走 `store`）—— 否则 macOS CI `swift test` app 套件必红。
1. **A1（P2，一行修复）**：`navigationGroupSizeByPhotoID` 命中路径加 `_ = navigationGroups.count`；
   顺带 `similarGroupAssets` 命中路径 `_ = page`（防御同型问题）。
2. **A2（P2，一行修复）**：Lightbox `resolvedCurrentIndex` 命中后校验 `photos[index].id == currentID`。
3. **A3（P2，需 macOS 实测/决策）**：评估 `totalCostLimit` 是否随像素口径上调，并在 macOS 上量
   2560 预览命中率/峰值内存；无数据前不建议仅凭算术改限制。
4. P3 项可批量收（A5 缓存键、A6 一次性标志顺序、A10 clamp、A11 复用 id 集合、A8 计时口径）。
