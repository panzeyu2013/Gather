# GatherUI 渲染/滚动路径性能审计与安全修复（task-6 / perf-ui）

- 日期：2026-11-16（评审目录 2026-11-17-quality-hardening）
- 范围：`desktop/native/gather-app/Sources/GatherUI/**`（排除 `Support/L10n.swift`、`Support/GatherLocalization.swift`、`Resources/en.lproj/**`，以及 ui-copy/task-4 占用的 4 个文件：`Curation/CollectionView.swift`、`Export/ExportView+Delivery.swift`、`Filtering/FilterRuleEditor.swift`、`Metadata/MetadataSyncBar.swift`）
- 边界（重要）：Linux 主机，**无 macOS/Xcode**，本轮**没有编译、没有运行、没有 Instruments 采样**。结论来自源码静态审计 + Swift 6.2 `swiftc -parse` 语法检查 + 仓库门禁。文中"每次省 N 次分配"是**按代码路径推导的构造次数/复杂度**，不是实测耗时。
- 行为约束：不改用户可见文案（en 表零改动）、不改布局/交互、不改 public API；会改变展示输出的候选一律跳过并记录。

## 0. 结论摘要

修复 7 项，涉及 7 个文件（+128/−50 行），全部行为保持：

| # | 位置 | 问题（旧） | 修复（新） | 每次求值消除的分配 |
|---|------|-----------|-----------|------------------|
| 1 | `Support/DateFormatting.swift:32-124` | —（基础设施） | 既有 `DisplayDateFormatters`（本已 `@unchecked Sendable`）内新增 `pattern/localizedTemplate/shortShort` 与**折叠进同一类**的两个 ISO-8601 解析器访问器（复用其 `NSLock`，未新增 `@unchecked Sendable` 类型） | 为 2-6 号提供缓存 |
| 2 | `Support/C1StatusCapsule.swift:324` | 每次 body 调 2 次（正文 `syncedAtText` + `tooltip`），每次新建 `ISO8601DateFormatter` + `DateFormatter` | 共享解析器 + `pattern` 缓存 | **4 次构造/次渲染 → 0** |
| 3 | `Metadata/MetadataBatchSheet.swift:107` | 批次行 `displayDate`：每行新建 3 个 formatter（带小数秒解析器 + 兜底解析器 + 展示 formatter）；`ForEach` 上限 20 行 | 共享解析器 + `mediumShort` 缓存 | **3 次构造/行 → 0**（20 行 ≈ 60 次/次渲染） |
| 4 | `Export/ExportViewModel.swift:214` | `namingPreview` 在导出选项 body 随输入实时求值，每次新建 2 个 `DateFormatter` | `pattern` 缓存 | **2 次构造/次渲染 → 0**（命名输入框每击键） |
| 5 | `Export/WebDAVPublishSheet.swift:373,438` | `historyTime` 发布历史逐行各新建解析器+展示 formatter；`linkExpiryText` 结果区 body 新建解析器 | 共享解析器 + `shortShort` 缓存 | **2 次构造/行、1 次/body → 0** |
| 6 | `Persons/PersonsView.swift:606` | 人物详情 body 调 2 次 `dateText`，每次新建 `DateFormatter` | `pattern` / `localizedTemplate` 缓存 | **2 次构造/次渲染 → 0** |
| 7 | `Culling/CullingInspector.swift:66-71,456-462,736` | body 内重复读 `selectionSummary`（2 次）、`currentGroupAssets`（4-5 次）、`knownGroupCount`（2-3 次），每次都是 O(已加载页) filter / 服务端组查找 | body 顶部各算一次，向下传 | **每次渲染少 ~2 次全页 filter + ~2 次全页扫描 + 3 个数组/Set 临时值**（页 500 张时约少 2-3k 次元素访问） |

剩余最大热点（未改，见 §4）：`CullingViewModel.currentAsset` 仍是 O(page) 的 `first(where:)`，而 `CullingInspector` body 内直接/间接读它 ~18 次、`CullingInfoBar` ~2 次；要修必须引入 photoId→index 索引并覆盖全部 `page = …` 赋值点，属行为可感知改造，本轮不做。

## 1. 审计方法（可复现）

1. 对 `Sources/GatherUI` 全量检索构造点与热点模式：
   `DateFormatter(`, `ISO8601DateFormatter(`, `ByteCountFormatter`, `NumberFormatter(`, `MeasurementFormatter(`, `JSONEncoder(`/`JSONDecoder(`, `NSRegularExpression(`, `String(format:`, `.sorted`, `.filter`, `.map`, `Dictionary(uniqueKeysWithValues`, `Set(`。
2. 逐个判读**调用语境**，而不是只看"有没有 new"：
   - SwiftUI `body` / body 内联闭包 / `ForEach` 行 / `@ViewBuilder` 计算属性 → 每帧或每次行实例化重跑；
   - ViewModel 计算属性若在 body 读取（Observation 追踪）→ 每帧重跑；
   - 数据加载/写盘/用户点击动作 → 非渲染路径，优先级低。
3. 区分"已有缓存（不动）"与"每次新建（候选）"；只对**输出可证明逐字节一致**的候选动手。
4. 每个改过的文件跑 `swiftc -parse -enable-bare-slash-regex`；跑 `check-design-system.sh`、`check-preview-surface.sh --strict`。

## 2. 发现清单（渲染/滚动相关）

判定含义：✅ 已是缓存/无分配（不动）；🔧 本轮修复；⏭ 跳过（低收益/交叉占用/需改造，见 §4）；❓非渲染路径。

### 2.1 formatter / coder 构造点

| 位置 | 语境 | 判定 |
|---|---|---|
| `Support/C1StatusCapsule.swift:324` `formatTime` | 每次 body（`syncedAtText` + `tooltip` 各 1 次）× `ISO8601DateFormatter` + `DateFormatter` | 🔧 #2 |
| `Metadata/MetadataBatchSheet.swift:107` `displayDate` | 批次 `ForEach` 逐行 × 3 formatter | 🔧 #3 |
| `Export/ExportViewModel.swift:214` `namingPreview` | 导出选项 body 每次求值 × 2 `DateFormatter` | 🔧 #4 |
| `Export/WebDAVPublishSheet.swift:373` `historyTime` | 发布历史逐行 × 2 formatter | 🔧 #5 |
| `Export/WebDAVPublishSheet.swift:438` `linkExpiryText` | 交付结果区 body × 1 解析器 | 🔧 #5 |
| `Export/WebDAVPublishSheet.swift:73` `proofExpiresAt` | 勾选"到期"时每次 body × 1 `ISO8601DateFormatter`（输出方向） | ⏭ 低收益（见 §4-8） |
| `Persons/PersonsView.swift:606` `dateText` | 详情 body × 2 `DateFormatter` | 🔧 #6 |
| `Dashboard/SessionRowView.swift:178` `dateText` | 工作区行 | ✅ 已用 `DisplayDateFormatters`（C-8 既有修复） |
| `Settings/SettingsView+MaintenanceSection.swift:248` `dateText` | 备份行 | ✅ 已用共享缓存（既有） |
| `Settings/SettingsView+MaintenanceSection.swift:286` `stamp` | 导出诊断按钮点击 | ❓ 非渲染 |
| `Duplicates/DuplicatesViewModel.swift:460,466` | 成员评分排序 | ✅ `static let` 缓存（既有，loc 正确） |
| `Metadata/MetadataEditorDraft.swift:239` `shiftedDateTime` | 批量时间预览循环（`MetadataBatchEditorSheet:623`，每张照片 1 次） | ⏭ 非 body，但值得缓存（§4-3） |
| `Settings/SettingsViewModel+Sync.swift:48-68` | 12s 轮询/刷新 | ❓ 非渲染；已用无构造的 `Date.ISO8601FormatStyle`（C/P2 既有） |
| `Library/LibraryViewModel.swift:159` | 筛选条件构建（apply 时 1 次） | ❓ 非渲染 |
| `SemanticSearch/SemanticSearchSheetModel.swift:68` | 批次保存时的时间戳 closure | ❓ 非渲染 |
| `Metadata/MetadataTransferService.swift:652` | 模板导入/导出服务 | ❓ 与渲染无关 |
| `Culling/CullingViewStateStore.swift:143` | UserDefaults 存档写入（已节流） | ❓ 写路径 |
| `Filtering/FilterEditorModel.swift:77-83`、`Export/ExportViewModel+Delivery.swift:127,509`、`IngestSheet.swift:801-811`、`SemanticKeywordBatchStore.swift:83-92`、`LibraryViewModel+Filter.swift:132` | `JSONEncoder/Decoder`：规则、交付配方、摄取预设、语义批次、筛选 hash | ❓ 保存/加载/提交路径，不在 body/行 |
| `Support/JSONValueDecoding.swift:64-65` | 通用编码入口（checkpoint/任务载荷） | ❓ 调用方非渲染 |
| `Support/DateFormatting.swift:14` `parseISO8601Date` | 全仓展示解析 | ✅ 值类型 `Date.ISO8601FormatStyle`（C/P2 既有） |
| `Support/DateFormatting.swift:43` `mediumShort` | Dashboard/设置 | ✅ 进程级缓存（C-8 既有） |

其余 `String(format:)`（31 处）均为无 formatter 实例的一次性格式化（`%.0f%%`、`%.2f` 等），单次成本 ~1µs 量级且多数不在逐行路径；**未改**。

### 2.2 body / 计算属性里的重复 O(n) 工作

| 位置 | 语境 | 判定 |
|---|---|---|
| `Culling/CullingInspector.swift:69-71`（旧 97/139/453-459/731） | body 每帧：`selectionSummary` ×2 + `colorSelectionBinding` getter ×1；`currentGroupAssets` ×4-5；`knownGroupCount` ×2-3，均 O(已加载页) 或 O(服务端组) | 🔧 #7 |
| `Culling/CullingInspector.swift:669` `colorSelectionBinding` getter | 每次 body 再算 1 次 `selectionSummary`（Picker 读 binding） | ⏭ 保留（改绑定语义要动 Picker 配合，收益 1 次扫描；见 §4-7） |
| `Culling/CullingViewModel.swift:125` `currentAsset` | O(page) `first(where:)`；inspector body ~18 次、InfoBar ~2 次、TriageCard 等 | ⏭ P0 建议（§4-2） |
| `Culling/CullingInfoBar.swift:235` `currentIndex` | 每次 body ×2 O(page) `firstIndex` | ⏭ 低收益（§4-4） |
| `Culling/CullingFilmstrip.swift:72` | `Array(assets.enumerated())` 每次 body 建 ≤500 元组数组 | ⏭ 改 ForEach 身份需验证滚动/动画（§4-6） |
| `Gallery/GalleryInspector.swift:98-106` `gallerySceneTagSeedIds` | body 读 2 次，内部 `loadedPhotos.contains` O(n)（链式拉满可上万） | ⏭ 需 VM 提供 loadedIdSet（§4-5） |
| `Filtering/FacetBar.swift:81` `visibleGroups` | body 每次 filter+map（维度数 10 以内） | ⏭ 低收益 |
| `SemanticSearch/SemanticSearchSheetModel.swift:85` `labelQueryTerms` | body 每次 split/trim/filter（输入串短） | ⏭ 低收益 |
| `Persons/PersonsViewModel.swift:47` | 人物列表 filter/body（列表小） | ⏭ 低收益 |
| `Dashboard/DashboardViewModel+Derived.swift:35-38` | 仪表盘统计 reduce/body（会话数小） | ⏭ 低收益 |
| `Gallery/GalleryViewModel+Derived.swift:40-126` | `loadedPhotos/filteredPhotos` 记忆化 + 布局缓存 | ✅ 已有（D-3 既有） |
| `Gallery/GalleryGrid.swift:91-123` | justified 布局缓存（key = 代数|指纹|宽|密度） | ✅ 已有 |
| `Culling/CullingGrid.swift:217-252` | 网格行布局缓存 | ✅ 已有 |
| `Culling/CullingViewModel+Keywords.swift:42-44` | 选择集关键词索引（selection+pageVersion 缓存） | ✅ 已有 |
| `Curation/StackFoldIndex.swift` | 字典索引，行内 O(1) 读取 | ✅ 已是索引结构 |

### 2.3 ByteCountFormatter（`ByteCountFormatter.string(fromByteCount:countStyle:)`）

类方法本身每次调用会新建实例（corelibs 实现即如此；macOS 侧同为便捷构造入口）。按调用语境：

| 位置 | 语境 | 判定 |
|---|---|---|
| `Curation/CollectionView.swift:567` | 集合成员**逐行** | ⏭ **ui-copy 占用文件，本轮不碰**（§4-1） |
| `Metadata/MetadataSyncBar.swift:243` | 同步条每次 body | ⏭ 同上（ui-copy 占用） |
| `Export/ExportView+Preview.swift:18,21,66` | 导出预览 2 个汇总值 + ≤8 行清单 | ⏭ 行数 ≤8，收益低（§4-1） |
| `Settings/SettingsView+MaintenanceSection.swift:242` | 备份列表逐行（≤保留份数 20） | ⏭ 收益低（§4-1） |
| `Export/DeliveryConfirmSheet.swift:15` | 确认弹窗 body ≤3 次 | ⏭ 收益低（§4-1） |
| `Metadata/MetadataDisplayRows.swift:48-57` | 手写 B/KB/MB/GB 换算，无 formatter | ✅ 无分配（保持） |

结论：**没有 `ByteCountFormatter()` 实例构造**；真正逐行的是两个被本轮排除的文件（CollectionView / MetadataSyncBar）。剩余 3 处列表都很短，为避免"为一个 helper 改 5 个文件"的横切 churn，本轮只记录建议（§4-1）。同理 `NumberFormatter`/`MeasurementFormatter`/`NSRegularExpression` 在全目录 **0 处**。

### 2.4 滚动路径专项结论

- Lazy 行视图本体（`GalleryCellView`、`CullingFilmThumbView`、`CullingGridCell`、`LibraryCardView`、`MetadataDisplayRows`）**未发现** formatter/coder/排序分配；行内只有字符串插值、l10n、颜色映射，保持不动。
- 滚动相关的大头已由既有工作解决（justified 布局缓存、堆栈折叠索引、缩略图缓存、派生数组记忆化）。
- 本轮的逐行分配集中在**sheet/列表辅助值**（批次记录、WebDAV 发布历史、人名日期）与**每帧认证的检查器派生值**（#7），而不是滚动帧本身。

## 3. 已修复明细（file:line + 为什么行为不变）

### #1 `Support/DateFormatting.swift:32-124` — 共享 formatter/parser 缓存（基础设施）
- `DisplayDateFormatters` 新增 `pattern(_:format:locale:)`、`localizedTemplate(_:template:locale:)`、`shortShort(_:locale:)`；缓存键 = 方法/pattern + `locale` + `Calendar.current` + `TimeZone.current`。
  - 旧实现每次新建 `DateFormatter` ⇒ locale/calendar/timeZone 取**调用时**系统值；键带三者保证运行中改系统设置会命中新实例，**输出不漂移**。
  - 创建顺序与旧代码一致（先 `locale` 再 `dateFormat`/`setLocalizedDateFormatFromTemplate`），样式（`.medium+.short`、`.short+.short`、固定 pattern、yMd 模板）逐项相同。
- 两个 ISO-8601 解析器**折叠进既有 `DisplayDateFormatters` 类**（与 formatter 缓存共用其 `NSLock`）：
  - `internetDateTime(_:)` ≡ `ISO8601DateFormatter()` + `[.withInternetDateTime]`；
  - `internetDateTimeWithFractionalSeconds(_:)` ≡ 再加 `.withFractionalSeconds`。
  - 共用同一把锁无重入：`formatter(key:)` 的 make 闭包不会回调解析方法，解析持锁时间 = 一次 parse。
  - **不新增 `@unchecked Sendable` 类型**：`check-cleanup-ratchet.sh` 的 `unchecked_sendable` 指标只允许收紧、不允许增长（`docs/cleanup-baseline.json`）。初版曾新建 `DisplayISODateParsers: @unchecked Sendable`，该指标 60→61 而 FAIL；按 lead 要求折叠进既有类后回到 60/60（见 §5.2 / §7）。
  - **刻意没有**改用 `parseISO8601Date`：后者会接受小数秒，而 C1 胶囊旧实现解析失败时会回退 `String(iso.prefix(16))`——换成 FormatStyle 会改变显示（例如测试里的 `2026-09-01T10:00:00.000Z` 会从原样前缀变成格式化时间）。保留原 `formatOptions` 才逐字节不变。
  - Swift 6 语言模式（`Package.swift` 显式 `.swiftLanguageMode(.v6)`）下的共享实例/锁写法沿用仓库既有 `DisplayDateFormatters` 形态，解析只在渲染路径调用。

### #2 `Support/C1StatusCapsule.swift:324` — C1 状态胶囊时间
- 旧：`ISO8601DateFormatter`（解析）+ `DateFormatter(locale: l10n.locale, dateFormat: 语言分支)`（展示），每次 `formatTime` 各建 1 个；body 每帧经 `syncedAtText`（正文，L229）与 `tooltip`（`.help`，L240）**调 2 次**。
- 新：`DisplayDateFormatters.shared.internetDateTime`（折叠后的解析器访问器）+ `DisplayDateFormatters.shared.pattern`；locale/格式分支表达式原样保留。
- 行为不变依据：解析器 `formatOptions` 相同；展示 formatter 的 `locale`/`dateFormat` 相同；解析失败回退 `String(iso.prefix(16))` 未变（`GatherAppTests/C1StatusCapsuleTests.swift:41,58` 用的正是带小数秒的 `reloadedAt`，回退路径仍命中）。

### #3 `Metadata/MetadataBatchSheet.swift:107` — 批次记录行日期
- 旧：每行 `ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])` → 失败回退 `ISO8601DateFormatter()` → `DateFormatter(dateStyle: .medium, timeStyle: .short, locale: l10n.locale)`，共 3 次构造；行数上限 20（`recentBatches(limit: 20)`）。
- 新：共享解析器两步 + `DisplayDateFormatters.mediumShort`（内部就是 `.medium + .short + locale`，与旧展示 formatter 配置完全一致）。
- 行为不变依据：解析顺序（先小数秒、后不带）与旧 `??` 顺序一致；展示样式/locale 相同；解析失败仍返回原始串。

### #4 `Export/ExportViewModel.swift:214` — 导出命名预览
- 旧：`DateFormatter(dateFormat: "yyyy-MM-dd")` 与 `DateFormatter(dateFormat: "HH-mm-ss")` 每次求值新建；调用点 `Export/ExportView+Options.swift:75` 在选项 body 里（命名输入框每击键/每次渲染）。
- 新：`DisplayDateFormatters.pattern(Date(), format: "yyyy-MM-dd", locale: .current)`（时间同理）。
- 行为不变依据：固定 pattern 与旧相同；旧 formatter 未设 locale ⇒ 用 `Locale.current`，新实现显式传 `.current`；两次独立 `Date()` 取值的写法也保留（跨秒边界语义不变）；缓存键含 calendar/timeZone 防环境漂移。
- 测试参考：`GatherAppTests/B6bExportMetadataUITests.swift:69-70` 只断言不含日期 token 的预览串（`工作区-IMG_1234.扩展名`），不受影响。

### #5 `Export/WebDAVPublishSheet.swift:373,438` — 发布历史时间 / 链接到期
- `historyTime`：逐行；旧 = `ISO8601DateFormatter(internet)` + `DateFormatter(.short/.short，未设 locale)` → 新 = 共享解析器 + `shortShort(date, locale: .current)`。
  - 风格与旧一致（`.short + .short`，调用时 locale）；解析失败仍原样返回 ISO 串。
- `linkExpiryText`：只把解析器换成共享实例，其余（小时数、l10n 文案）不动；解析失败仍返回 nil（不显示假时长）。

### #6 `Persons/PersonsView.swift:606` — 人物详情日期
- 旧：每次 `DateFormatter(locale: l10n.locale)`，zh 用 `dateFormat = "yyyy年M月d日"`，en 用 `setLocalizedDateFormatFromTemplate("yMd")`；详情 body 调 2 次（创建/更新时间，L417-418）。
- 新：`pattern` / `localizedTemplate` 缓存，两个分支的 locale 与格式设置顺序不变。

### #7 `Culling/CullingInspector.swift:66-71,456-462,736` — 检查器 body 内重复派生
- 旧（同一帧多次求值）：
  - `selectionSummary`（`CullingViewModel+Actions.swift:607`：对已加载页 `filter` + 2 个 `Set(map)`）在 body 内 2 处 + `colorSelectionBinding` getter 1 处；
  - `currentGroupAssets`（`page?.assets.filter`）被 `groupIds`、`subtitle`、`knownGroupCount` 回退分支重复触发 4-5 次；
  - `knownGroupCount`（含 `similarityGroups.first(where:)`）被条件/keepValid/格式化重复触发 2-3 次。
- 新：body 顶部算一次 `summary` / `groupAssets` / `groupKnownCount`；`knownGroupCount` 从计算属性改为 `knownGroupCount(for: [CullingAsset])` 接收已算好的组资产。
- 行为不变依据：三者都是**纯读派生**，同一 body 求值内取值相同；只是从"每次读取重算"变成"每帧算一次后复用"；无布局/交互/文案变化。`colorSelectionBinding` getter 保留原语义（仍自己读 `selectionSummary`），因此#7 之后每帧仍有 1 次全页 filter（见 §4-7）。

## 4. 排序后的剩余建议（本轮未做）

> 原则：需要行为可感知改造/跨文件注入/无法静态证明的地方不硬改。

| 优先级 | 建议 | 影响/理由 | 风险与改法 |
|---|---|---|---|
| P0 | **`CullingViewModel.currentAsset` 加 photoId→index 索引**（`CullingViewModel.swift:125-128`） | culling 页最大单点：inspector body 直接/间接读 ~18 次、InfoBar ~2 次、TriageCard/模板等，每次 O(page≤500) `first(where:)`；连拍 2-3 拍/秒的决策流里每帧都付 | 需要覆盖全部 `page = …` 赋值点（`+Load.swift:89,191,223,233`、`+Actions.swift:39`、`+Grid.swift:463,499`）并在页替换时重建索引；**漏失效会显示错误当前照片**，需专门单测（currentPhotoId 失效回退页首语义不变） |
| P1 | **共享 `DisplayByteCountFormatter`**（`@unchecked Sendable` + `NSLock`，按 `Locale.current.identifier` 换实例），接线 5 处：`Curation/CollectionView.swift:567`（逐行，ui-copy 占用）、`Metadata/MetadataSyncBar.swift:243`、`Export/ExportView+Preview.swift:18,21,66`、`Settings/SettingsView+MaintenanceSection.swift:242`、`Export/DeliveryConfirmSheet.swift:15-16` | 类方法每次调用新建 `ByteCountFormatter`；最热的逐行点恰好都在 ui-copy 占用的两个文件里，本轮未碰 | 输出等价（`countStyle = .file` 与旧调用相同；locale 变化时按 key 换实例）；建议 ui-copy 完成后由 perf 侧接线或直接在两个文件做极小改动 |
| P1 | **`MetadataEditorDraft.shiftedDateTime`（`:239`）缓存 formatter** | 批量时间预览 `MetadataBatchEditorSheet:623` 对每张照片调 1 次、每次新建 `DateFormatter`（locale `en_US_POSIX`、TZ UTC 均固定 ⇒ 缓存完全等价、无环境漂移） | 纯粹是放置问题：`MetadataEditorDraft` 是值类型静态工具箱，Swift 6 下不能放非 Sendable `static let`；可复用新增的共享缓存类（加一个固定 UTC + POSIX 的方法）或新建同款 `@unchecked Sendable` holder |
| P2 | **`CullingInfoBar.currentIndex` hoist**（`:235`，body L48/L52 各读 1 次） | 每次 body 2 次 O(page) `firstIndex`；决策/选择变化都会重绘 infoBar | 可像 #7 一样在 body 顶部算一次；纯读、低风险 |
| P2 | **`GalleryInspector.gallerySceneTagSeedIds`（`:98-106`）改用 id 集合** | body 读 2 次，内部 `loadedPhotos.contains` O(n)；搜索/筛选链式拉满时 n 可达上万 | 由 GalleryViewModel 维护 `loadedPhotoIdSet`（与 `flatCache` 同代数更新）；涉及 VM 字段，需保证刷新/增页/变体变更时同步 |
| P2 | **`CullingFilmstrip` 去掉逐帧 `Array(enumerated())`**（`:72`） | 每次 filmstrip body 建 ≤500 元组数组 | 改 `ForEach(assets.indices)` 会改变 SwiftUI 行身份判定（当前用 `id: photo.id` + `.id()`)，需在 macOS 上验证滚动/自动 scrollTo 行为；**Linux 无法验证，故未改** |
| P2 | `CullingInspector.colorSelectionBinding`（`:669`）复用 body 顶部 `summary` | 每帧仍多 1 次 `selectionSummary` 全页 filter | 需把 Binding 改为"携带 summary 的函数"，getter 捕获 body 期快照；Picker 打开期间 getter 可能晚于状态更新被调用，语义细微变化，故保留 |
| 低 | `FacetBar.visibleGroups`（`:81`）、`SemanticSearchSheetModel.labelQueryTerms`（`:85`）、`PersonsViewModel` 搜索 filter（`:47`）、Dashboard 统计 reduce（`+Derived:35-38`） | 数据量小（≤10 维度/短串/会话数），单次成本远低于 SwiftUI 视图更新本身 | 收益低于 churn 风险，不做 |
| 低 | `WebDAVPublishSheet.proofExpiresAt`（`:73`）输出方向 ISO formatter | 仅"启用到期"时每帧 1 次；同一文件的解析已缓存 | 若做 P1 的 ISO 缓存类时顺手加 `internetDateTimeString(from:)` 即可 |

## 5. 验证（命令 + 输出）

### 5.1 语法检查（Swift 6.2 toolchain，Linux 上仅 parse）
```
.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <每个改动文件>
```
| 文件 | 结果 |
|---|---|
| `Sources/GatherUI/Support/DateFormatting.swift` | EXIT:0 |
| `Sources/GatherUI/Support/C1StatusCapsule.swift` | EXIT:0 |
| `Sources/GatherUI/Metadata/MetadataBatchSheet.swift` | EXIT:0 |
| `Sources/GatherUI/Export/ExportViewModel.swift` | EXIT:0 |
| `Sources/GatherUI/Export/WebDAVPublishSheet.swift` | EXIT:0 |
| `Sources/GatherUI/Persons/PersonsView.swift` | EXIT:0 |
| `Sources/GatherUI/Culling/CullingInspector.swift` | EXIT:0 |

### 5.2 仓库门禁
- `./scripts/check-design-system.sh` → `PASS: no regression`（exit 0；各项 current ≤ baseline，未新增 design-system 字面量/字号）。
- `./scripts/check-preview-surface.sh --strict` → `PASS: #Preview=14, preview files=12, lines=2210`（exit 0；未增删预览宏）。
- `./scripts/check-cleanup-ratchet.sh` → `unchecked_sendable 60/60 ok`、`try_optional 260/261 ok (improved 1)`、其余 `0/0 ok` → `OK（全部指标不超过 baseline）`（exit 0）。
  - 初版新增 `DisplayISODateParsers: @unchecked Sendable` 使 `unchecked_sendable` 61>60 FAIL；折叠进既有 `DisplayDateFormatters` 后修复为 60/60（详见 §7）。
- 未跑：`swift build` / `swift test` / `check-warnings.sh`（需要 macOS SDK/AppKit，Linux 主机不可用）。

### 5.3 行为保持证据
- **文案零改动**：未触碰 `Resources/en.lproj/**`、`Support/L10n.swift`、`Support/GatherLocalization.swift`；所有 format 参数照旧。
- **展示样式对照**（旧→新）：`ISO8601DateFormatter([.withInternetDateTime])`→同名共享实例；`[.withInternetDateTime,.withFractionalSeconds]`→同名共享实例；`dateStyle .medium + timeStyle .short + locale`→`mediumShort`（同配置）；`dateStyle .short + timeStyle .short`→`shortShort`（同配置 + 调用时 locale）；`dateFormat "yyyy-MM-dd"/"HH-mm-ss"/"MM/dd HH:mm"/"MM/dd yyyy HH:mm"/"yyyy年M月d日"`→`pattern`（同 pattern + 同 locale）；`setLocalizedDateFormatFromTemplate("yMd")`→`localizedTemplate`。
- **缓存键防环境漂移**：新增 formatter 方法的 key 含 `Locale`/`Calendar.current`/`TimeZone.current`，运行中修改系统设置会新建实例，不会停在旧环境（旧实现是每次新建 ⇒ 取调用时值）。既有 `mediumShort` 键保持不变（沿用既有 C-8 语义）。
- **#7 纯读派生**：`selectionSummary`/`currentGroupAssets`/`knownGroupCount` 均无副作用，同一帧内多次求值结果相同。
- `git diff --stat`（本轮 7 文件）：`7 files changed, 128 insertions(+), 50 deletions(-)`；`git diff --check` 无空白问题（含 EOF 单换行）。

## 6. 改动文件清单

| 文件 | 变更 |
|---|---|
| `Sources/GatherUI/Support/DateFormatting.swift` | +77/−0：`DisplayDateFormatters` 内新增 `pattern/localizedTemplate/shortShort/environmentKey` + 折叠的 `internetDateTime`/`internetDateTimeWithFractionalSeconds` 访问器（未新增 `@unchecked Sendable` 类型） |
| `Sources/GatherUI/Support/C1StatusCapsule.swift` | `formatTime`（L324）改共享缓存 |
| `Sources/GatherUI/Metadata/MetadataBatchSheet.swift` | `displayDate`（L107）改共享缓存 |
| `Sources/GatherUI/Export/ExportViewModel.swift` | `namingPreview`（L214）改共享缓存 |
| `Sources/GatherUI/Export/WebDAVPublishSheet.swift` | `historyTime`（L373）、`linkExpiryText`（L438）改共享缓存 |
| `Sources/GatherUI/Persons/PersonsView.swift` | `dateText`（L606）改共享缓存 |
| `Sources/GatherUI/Culling/CullingInspector.swift` | body 顶部 hoist 派生（L66-71），相似组块/knownGroupCount 改用 hoist 值（L456-462/L736） |

未提交 git（任务约束）。`.gather/` 下的临时脚本/日志不入库。

## 7. 追加修复：cleanup ratchet 回归（lead 反馈）

- **回归**：初版在 `Support/DateFormatting.swift` 新建了 `final class DisplayISODateParsers: @unchecked Sendable`，使 `./scripts/check-cleanup-ratchet.sh` 的 `unchecked_sendable` 指标 60 → 61，门禁 FAIL（仓库规则：清理 ratchet 只许收紧，不许增长）。
- **修法（行为零变化）**：删除该新类型，把两个 `ISO8601DateFormatter` 解析器与 `internetDateTime(_:)` / `internetDateTimeWithFractionalSeconds(_:)` 访问器**折叠进已经计入 baseline 的 `DisplayDateFormatters`**（同为 `@unchecked Sendable`），复用其现有 `NSLock`：
  - 共用锁无重入：`formatter(key:)` 的 make 闭包不会回调解析方法；
  - 两个解析器的 `formatOptions`、解析顺序、失败回退语义完全不变；
  - 调用点改为 `DisplayDateFormatters.shared.internetDateTime(...)` / `...internetDateTimeWithFractionalSeconds(...)`（C1 胶囊、批次记录、WebDAV 发布历史/链接到期 4 处）。
- **修复后验证**：
  - `./scripts/check-cleanup-ratchet.sh` → `unchecked_sendable 60/60 ok`，整体 `OK（全部指标不超过 baseline）`（exit 0）；
  - `swiftc -parse` 4 个改动文件（DateFormatting + C1StatusCapsule + MetadataBatchSheet + WebDAVPublishSheet）全部 EXIT:0；
  - `check-design-system.sh` PASS、`check-preview-surface.sh --strict` PASS；
  - `git diff --check` 干净（并清掉了折叠时产生的 EOF 多余空行，保持文件以单换行结尾）。
- 经验：本仓共享缓存优先**复用既有 `@unchecked Sendable` 类型/锁**；新增同形态类型会被 cleanup ratchet 拦截。
