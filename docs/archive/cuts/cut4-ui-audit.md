# Cut 4 前置只读审计：UI 状态层、本地化与 Preview

> 任务：Cut 4（UI 重构 + 本地化）开工前的只读审计。交付物仅本文件；
> 未修改任何源码/测试/Package，未运行构建与测试。
>
> 基线：分支 `refactor`，HEAD `82603e0`，工作树含 Cut 3 收尾的未提交迁移
> （文件已从 `gather-app/<Feature>/` 移到 `gather-app/Sources/GatherUI/<Feature>/`）。
> 行号以**当前工作树**为准；Cut 3 合并后可能整体漂移，引用前请重新 `read` 核对。
>
> 阅读口径：`docs/reviews/refactor-design-breaking-2026-10-21.md` 第 6 章是
> **算法**（相似度/人脸），与 UI 无关；本审计对应的是该文件 §5（UI：一次性切到
> 新状态模型）与 §9「Cut 4」验收，以及 `docs/reviews/refactor-design-2026-10-21.md`
> §5（工作流 C，含更细的 SessionWorkspace/ViewState/LanguageStore 草案）。
> 决策依据：`docs/refactor-decisions.md` D-014（UI 不得依赖 Analysis）、
> D-017（Cut 4 把 Shell 迁入 GatherUI）、D-019（显式注入，禁服务定位器）、
> D-105（Cut 3 关闭：7 target、UI 只 import Protocol）。
>
> 方法与边界：只做 `grep`/`read`/`wc` 与只读门禁脚本；未跑 `swift build`/
> `swift test`，未做 GUI/Preview 目视验收。测试数字引用 D-093/D-105 的已记录
> 基线（app 461/55、core 1057/149），本次未复跑。

---

## 0. 结论摘要

### 0.1 关键数字（可复核）

| 项 | 实测 | 设计值 | 差异 |
| --- | --- | --- | --- |
| `GatherLocalization.l(` 代码调用 | **1,481** 处（另有 1 处注释） | 1,439（breaking）/ 1,497（保守版） | **+42（+2.9%）** |
| `GatherLocalization.*` 全部引用 | **1,533** 处（含 1 处注释） | 未给 | — |
| 字面量 key 调用 / 唯一 key | 1,466 / **1,034** | 未给 | 432 处重复使用同一 key |
| en 表条目 / 唯一键 | **1,408 / 1,397** | 未给 | 11 个重复键（3 个译文冲突） |
| 表内 `%lld` / `%d` / `%@` 键 | **145 / 3 / 94** | 未给 | 0 个 `.stringsdict` |
| 正则覆盖不到的中文 | 原始扫描 **92 行**（SettingsView 76；真正可见约 80） | 未给 | codemod 覆盖不到 |
| `isActive` 生产站点 | **40 处** | 目标 0 | — |
| `SessionDraftCache` 字段 | **10 个**（4 VM 字典 + 4 意图容器 + LRU 2） | 目标删除 | — |
| `.id(languageVersion)` | **1 处**（RootView:443） | 目标 0 | — |
| stored `errorMessage` | **7 个 VM / 154 处赋值 / 15 处渲染**（另有 3 处其他错误渲染） | 设计写“6 个 VM” | 少算 1 个 |
| `#Preview` | **0** | ≥12 | — |
| 状态字段（14 个持有者） | **213** | 未给 | 见 §1.0 |
| 6 个巨型 View 行数 | 3,567 / 2,123 / 1,870 / 1,187 / 1,182 / 1,362 | 3,525 / 2,098 / 1,756 / 1,073 / 1,139 / — | 全部增长 |

只读门禁当前状态（本次实跑，2026-10-22）：

```text
check-cleanup-ratchet: unchecked 53/53、try? 234/242（余量 8）、prepare 126/126、todo 0、withKnownIssue 0 → OK
check-duplicate-symbols: 379 个 Swift 文件；RequestGate 定义 0 份（脚本已为 Cut 4 预留规则）→ PASS
check-layering: UI/Host/App/core 四层 17 条 import 规则全过 → OK
```

### 0.2 已确认问题（按优先级）

- **P0-1（状态门控分叉）**：`isActive` 是**死通道**——RootView 四处传常量
  `true`（`RootView.swift:637/658/688/707`），而真正的可见性由 **8 套**互不相同的
  机制承担（Culling VM 自管 `isActive`、Gallery 由 RootView.onChange + onDisappear、
  Similarity 只由 RootView 停轮询、Dashboard 用 `isVisible`、Control 无门控靠视图
  Task 生命周期、C1 胶囊引用计数、Library `.disabled`、Persons `.task(id:)`）。
  直接删参数会删掉其中 4 套唯一门控。
- **P0-2（本地化时序）**：7 个 VM 存**已本地化字符串**（154 处赋值），
  `APIErrorPresentation.message(for:)` 在 VM 内就调用 `errorText`。当前靠
  `.id(languageVersion)` 整树重建掩盖；**必须先改 CommandError/LocalizedText，
  再删 `.id`**，顺序反了会出现“切语言后旧文案残留”。
- **P0-3（设计与实际不符）**：errorMessage 是 **7** 个 VM 不是 6 个；
  `SessionControlViewModel` 完全不缓存；设计 Workspace 只列 4 个 VM，漏了
  control/gallery/similarity 三个会话级 VM。
- **P1-1**：语言状态 4 个载体 + 4 个重复写点；菜单仍依赖版本号（设计已承认）。
- **P1-2**：l10n 表 11 个重复键、3 个译文冲突、6 个缺失键、145 个复数敏感
  `%lld`、92 行正则覆盖不到的中文（约 80 行真正未本地化）、12 处
  `操作失败：%@` 前缀拼接。
- **P1-3**：Preview = 0；Tests 里的 Stub API 不能被 Sources 的 `#Preview` 复用，
  需要新增 `#if DEBUG` PreviewSupport（约 600-900 行 fixture）。
- **P2**：`RootView.refreshWindowTitle` 每次导航同步查库（:992）；
  RootView 自建第二个 `CaptureOneBridge`（:430-434，Bootstrap 已有一个）。

---

## 1. 会话/工作区状态盘点

### 1.0 总表：14 个持有者 / 213 个状态字段

> 口径：**存储属性**（含 `private`/`private(set)` 与派生缓存），不含计算属性、
> 常量与 `@Environment`。逐项清单见 §1.1-§1.3。

| # | 持有者 | 字段数 | 主要状态类别 |
| --- | --- | --- | --- |
| 1 | `RootView`（@State） | 12 | 导航、5 个页面 VM、草稿缓存、语言版本、窗口标题、新建请求、列可见性 |
| 2 | `RootNavigation` | 6 | destination、lastSessionId、photo id/path、sessionOrigin、previousDestination |
| 3 | `SessionDraftCache` | 10 | LRU 顺序/活动会话、4 个 VM 字典、4 个 pending 意图容器（另有 1 个 `static let maxSessions`） |
| 4 | `DashboardViewModel` | 11 | 列表/状态/任务/预检/3 个错误/可见性 |
| 5 | `GalleryViewModel` | 12 | 分页、筛选、搜索、选择、缩略图尺寸、状态、phase/actionError |
| 6 | `LibraryViewModel` | 15 | 分页、筛选、会话过滤、相册、关联候选、孤立 XMP、卷、phase/actionError |
| 7 | `CullingViewModel` | 25 | 页/摘要/同步/历史/冲突、筛选、选择、当前照片、导航组、相似组、2 个错误、isActive |
| 8 | `FaceKeywordingViewModel` | 28 | 簇/结果/预览/写回、步骤、角色/关键字/eps/minSamples、3 个错误、派生数组 |
| 9 | `ExportViewModel` | 27 | 预览/结果/报告、14 个表单字段、进度、fieldError/planError/errorMessage |
| 10 | `DuplicatesViewModel` | 14 | 分组/扫描结果/阈值/分页/展开/进度/错误 |
| 11 | `SessionControlViewModel` | 8 | 会话/工作区状态/任务/同步/错误/提示 |
| 12 | `SimilarityViewModel` | 24 | phase/结果/分析态/进度/选择/写回/同步/参数/展开态 |
| 13 | `PersonsViewModel` | 5 | phase/persons/selected/searchText/actionError |
| 14 | `SettingsViewModel` | 16 | 设置值/编辑缓冲/滑杆/模型状态/语言/后端/C1 健康/同步/下载/错误 |
| | **合计** | **213** | 其中 4 类关键机制见 §1.4-§1.8 |

补充：`ContentView` **不存在**（`grep -rn 'struct ContentView' Sources` = 0）。
旧设计里的 `ContentView` 职责已由 `RootView.detail`（`RootView.swift:627-718`）承担。

### 1.1 RootView：12 个 @State + 2 个 @Environment

| 字段 | 行 | 作用域 | 备注 |
| --- | --- | --- | --- |
| `navigation` | 361 | 全局壳层 | `RootNavigation`，见 §1.2 |
| `viewModel`（Dashboard） | 362 | 全局 | 常驻，跨目的地复用 |
| `libraryViewModel` | 363 | 全局 | 常驻 |
| `galleryViewModel` | 364 | 单会话（可空） | 仅在目的地/会话变化时替换（`syncViewModels` :952-984） |
| `similarityViewModel` | 365 | 单会话（可空） | 同上；替换前显式停两路轮询（:964-965） |
| `personsViewModel` | 366 | 全局 | 常驻 |
| `columnVisibility` | 367 | 壳层布局 | ⌘⌥S |
| `faceKwInitialRole` | 369 | 一次性深链 | 离开人脸页即清空（:517-519），进 View init（:764/891） |
| `languageVersion` | 371 | 语言 | 唯一驱动 `.id`（:443） |
| `windowTitle` | 373 | 标题 | 每次导航同步查库刷新（:987-994） |
| `newWorkspaceRequest` | 377 | 跨页请求 | ⌘N/导入（:461-476） |
| `draftCache` | 379 | 会话草稿 | `SessionDraftCache`，见 §1.3 |
| `reduceMotion`（@Environment） | 380 | 动画 | — |
| `openSettings`（@Environment） | 383 | 系统设置 | macOS 14 公开 API |

`RootView` 其余非状态依赖：`appServices: AppServices`（:356）+ 3 个 provider
（:357-359）。**这 4 个依赖是 RootView 迁入 GatherUI 的唯一障碍**：
`AppServices`（`GatherHost/APIs/AppServices.swift:30`）本身 import 了
Persistence/Analysis/Domain，UI 不能依赖。见 §4.6 `RootShellDependencies`。

### 1.2 RootNavigation：6 个字段 + 11 个派生判定

| 字段 | 行 | 说明 |
| --- | --- | --- |
| `destination` | 54 | `.dashboard/.page/.library/.gallery/.similarity/.sessionTab` |
| `lastSessionId` | 111 | 侧栏「当前会话」回退项（N07） |
| `pendingGalleryPhotoId` | 118 | 一次性照片目标（id） |
| `pendingGalleryPhotoPath` | 119 | 一次性照片目标（path，相似度成员行） |
| `sessionOrigin` | 137 | 粗粒度来源（5 值） |
| `previousDestination` | 143 | 精确单步返回（B1） |

派生：`isDashboard/isLibrary/isPersons/isSettings`（:61-64）、
`gallerySessionId/similaritySessionId/sessionTabDestination/currentSessionId/
sidebarSessionId`（:77-122）、`isGallery/isSessionTab`（:67-75）。
动作：`selectDashboard/selectLibrary/selectWeb/openSession/openGallery/
openSimilarity/openSessionTab/goBack/backFrom*`（:101-243）。
清理：`pruneIntents`（:250-266）、`clearPendingGalleryPhoto`（:269-272）。

**注意**：`pendingGalleryPhoto*` 被 RootNavigation 持有，但语义是“页面入口意图”，
不是导航身份。设计把它归入 `WorkspaceIntent.galleryPhoto` 是对的，但这会破坏
`ReviewFixTests.swift:408-421` 的 3 条断言（见 §7.1 测试影响）。

### 1.3 SessionDraftCache：10 个存储字段 + 1 个静态上限

| 字段 | 行 | 说明 |
| --- | --- | --- |
| `recentSessionIds` | 297 | LRU 顺序 |
| `activeSessionId` | 299 | 淘汰时跳过（B7） |
| `maxSessions = 8`（static） | 301 | **与设计 capacity 6 不一致**（不计入 10 个字段） |
| `exportViewModels` | 325 | `[String: ExportViewModel]` |
| `faceViewModels` | 326 | `[String: FaceKeywordingViewModel]` |
| `cullingViewModels` | 330 | `[String: CullingViewModel]` |
| `duplicatesViewModels` | 331 | `[String: DuplicatesViewModel]` |
| `pendingExportIntent` | 333 | `[String: ExportRangeIntent]` |
| `pendingCullingConflicts` | 335 | `Set<String>` |
| `pendingGalleryFilter` | 337 | `[String: GalleryFilter]` |
| `pendingFaceAnalyze` | 339 | `Set<String>` |

方法：`noteAccess`（:303-311，命中也要记访问）、`evict`（:314-323）。
**没有 `control/gallery/similarity` 的 VM 字典**——这三个 VM 的生命周期分别是：
control 每次进页面新建（`SessionControlView.swift:359-365`），gallery/similarity
由 RootView 单槽持有（:364-365），离开即丢（只保留最后一个会话）。

### 1.4 `isActive` 全量位置（40 处生产 + 2 处测试）

> 排除 `CullingViewModel.FilterState.isActive`（筛选是否激活，与可见性无关，
> `CullingView.swift:43/896/902`）。以下均为“页面/VM 可见性”语义。

| 文件 | 行 | 角色 |
| --- | --- | --- |
| CullingView (VM) | 147 | `public var isActive = true`（VM 门控） |
| CullingView (VM) | 262, 271 | 域补刷/延迟刷新守卫 |
| CullingView (VM) | 374, 380 | 画质分析 500ms 轮询循环条件 |
| CullingView (View) | 1557, 1562 | `onAppear/onDisappear` 写 VM |
| GalleryView | 59, 83, 93 | 属性/init 参数/赋值 |
| GalleryView | 171, 183, 222, 276, 496 | 启动轮询/onChange/事件守卫/传胶囊/照片定位守卫 |
| SimilarityView | 95, 116, 125, 213 | 属性/init/赋值/传胶囊（**无轮询门控**） |
| LibraryView | 22, 30, 35, 89, 118 | 属性/init/赋值/`.disabled`/事件守卫 |
| PersonsView | 25, 34, 41, 81, 82, 91 | 属性/init/赋值/`.task(id:)`/加载守卫/事件守卫 |
| C1StatusCapsule | 143, 151, 157, 165, 170, 180 | 胶囊订阅门控 |
| RootView | 637, 658, 688, 707 | **全部传常量 `true`（死通道）** |
| LayoutBudgetTests | 282, 283 | 测试构造参数 |

### 1.5 可见性/轮询的 8 套机制（4a 必须先收敛）

| # | 机制 | 证据 | 失效方式 |
| --- | --- | --- | --- |
| 1 | Culling VM 自管 `isActive` | `CullingView.swift:147/1557/1562` | 页面销毁 → onDisappear |
| 2 | Gallery 轮询由外壳停 | `RootView.swift:527-529` + `GalleryView.swift:180-182` | 双保险，重复 |
| 3 | Gallery `isActive` onChange | `GalleryView.swift:183-195` | 参数恒 true → 永不触发 |
| 4 | Similarity 两路轮询由外壳停 | `RootView.swift:535-538`、`:972-979` | 只有外壳一条路 |
| 5 | Dashboard `isVisible` + start/stop | `DashboardViewModel.swift:349/735-750`、`RootView.swift:531-542` | 外壳显式驱动 |
| 6 | Control 无门控 | `SessionControlView.swift:453-466` 无限 `while` | 依赖视图销毁取消 Task |
| 7 | C1 胶囊引用计数订阅 | `C1StatusCapsule.swift:163-186` | onDisappear + isActive |
| 8 | Library `.disabled` / Persons `.task(id:)` | `LibraryView.swift:89`、`PersonsView.swift:81` | 参数恒 true → 形同虚设 |

> 设计目标：`SessionWorkspace.setVisible(_:)` 一套取代 8 套。**风险**：机制 3/7/8
> 目前由常量 true 喂着，删参数时必须把语义迁进 workspace，否则这些门控直接消失。

### 1.6 语言状态：4 个载体 + 4 个重复写入点

| 载体 | 行 | 说明 |
| --- | --- | --- |
| `GatherLocalization.appLanguage`（锁盒） | `GatherLocalization.swift:12-32/411-418` | 进程级全局，`l()`/`errorText()` 读它 |
| `RootView.languageVersion` | `RootView.swift:371/455` | 驱动 `.id`（:443） |
| `GatherApp.commandsLanguageVersion` | `GatherApp.swift:28/64-66/71` | 驱动 SwiftUI `Commands` 重建（无 Observation） |
| `SettingsViewModel.language` | `SettingsView.swift:119/229` | 设置页选择器；加载时由 `ui_language` 播种（:195） |

4 个重复写入点（同一 `languageChanged` 通知各自再写一次全局）：
`RootView.swift:451-456`、`DashboardView.swift:104-108`、`GatherAppDelegate.swift:168-171`、
`LiveSettingsAPI.swift:58-75`（唯一真正持久化 + 广播的入口）。

派生：`GatherLocalization.appLocale`（:431-433）被 Dashboard/C1 用于日期格式化。

### 1.7 其他会话/选择/筛选/草稿状态（逐页）

- **Dashboard**（`DashboardViewModel.swift:349-368`）：`phase`、`sessions`、
  `statuses`、`scanJobs`、`jobs`、`isCreating`、`createError`、`actionError`、
  `jobsError`、`c1Preflight`、`isVisible`；视图另有 12 个 `@State`
  （新建/删除/历史/多选/节流时间，`DashboardView.swift:41-61/711-714`）。
- **Gallery**（`GalleryViewModel.swift:260-313`）：`phase`、`session`、
  `actionError`、`selectedIds`、`thumbnailSize`、`workspaceStatus`、`search`、
  `filter`、`expandVariants` + 私有已提交副本 `committedSearch/Filter/Expand`；
  视图：`density/lightboxIndex/layoutCache/refreshDeferred*/pendingInitialPhoto*`
  （`GalleryView.swift:65-123`）。
- **Library**（`LibraryViewModel.swift:370-387`）：`phase`、`sessions`、`photos`、
  `total`、`page`、`isFetching`、`actionError`、`albums`、`assetCandidates`、
  `metadataOrphans`、`assetVolumes`、`isSupportBusy`、`filter`、`sessionFilter`、
  `selectedAlbumId`；视图 8 个 `@State` + 2 个 `@SceneStorage`。
- **Culling**（`CullingView.swift:124-168`）：页/摘要/同步/历史/冲突、`isLoading`、
  `isQualityBusy`、`qualityJob`、`errorMessage`、`notice`、`pendingDomainRefresh`、
  `lastSyncError`、`reloadAcked`、`filterState`、`autoAdvance`、`isActive`、
  `currentPhotoId`、`selectedPhotoIds`、`navigationGroups`、`isNavigationBusy`、
  `selectedNavigationGroupId(s)`、`similarityGroups`、`scopeMode`、
  `selectedSimilarityGroupId`；视图 19 个 `@State` + 2 个 `@SceneStorage`。
- **Face**（`FaceKeywordingView.swift:92-139`）：簇/分析结果/预览/写回结果、
  `isLoading/isWritingBack`、`errorMessage/errorDetail/notice`、`analysisPhase`、
  进度三元组、`modelsMissing`、`encodingFailureWarning`、`isSyncConfirmed`、
  `step/roleName/keywords/eps/minSamples/mergeTargetId/selectedClusterId/roleFilter`、
  `reviewActionError`、派生 `boundClusters/unboundClusters/roleNames`。
- **Export**（`ExportView.swift:35-75`）：`preview/result/report`、`isWorking/
  isPreviewing/isExporting`、`errorMessage/notice/planError/fieldError`、
  `exportProgress/currentFileName/sessionName`、14 个表单字段。
- **Duplicates**（`DuplicatesView.swift:117-141`）：`groups/scanResult/isScanning/
  isLoading/errorMessage/notice`、进度三元组、`scanJobId`、`threshold/showExact/
  scannedThreshold/visibleGroupCount/expandedGroupIds`。
- **Control**（`SessionControlView.swift:27-42`）：`session/workspaceStatus/jobs/
  syncStatus/isWorking/isLoading/errorMessage/notice`；视图 `scrollToStagesRequested/
  showJobHistory`（:330-332）——**这两个视图态每次进页都丢**。
- **Similarity**（`SimilarityViewModel.swift:124-176`）：`phase/result/isAnalyzing/
  isReclustering/isCanceling/isLoading/errorMessage`、进度三元组、`selectedGroupIds/
  writebackPreview/writebackResult/isSyncBusy/writebackMessage/syncView/reloadAcked/
  writebackKeywords/threshold/minGroupSize/groupingMode/expandedGroupIds/
  showAllMemberGroupIds/resultParams`。
- **Persons**（`PersonsViewModel.swift:30-38`）：`phase/persons/selected/searchText/
  actionError` + `selectionGeneration`。
- **Settings**（`SettingsView.swift:111-159`）：`values/edits/sliderValues/modelStatus/
  errorMessage/notice/language/backend/c1Health/c1HealthError/c1Checking/syncStatus/
  syncSessionId/syncReloadAckedAt/syncStateError/downloadPhase`。

### 1.8 stored `errorMessage`：7 处声明

| # | VM | 声明 | 赋值点 | View 渲染点 |
| --- | --- | --- | --- | --- |
| 1 | CullingViewModel | `CullingView.swift:133` | 45 | 1491、1513 |
| 2 | FaceKeywordingViewModel | `FaceKeywordingView.swift:100` | 28 | 1194、1331 |
| 3 | SimilarityViewModel | `SimilarityViewModel.swift:130` | 28 | 245、649 |
| 4 | SettingsViewModel | `SettingsView.swift:117` | 22 | 1362-1364 |
| 5 | ExportViewModel | `ExportView.swift:41` | 11 | 726、1075 |
| 6 | DuplicatesViewModel | `DuplicatesView.swift:121` | 11 | 474、699 |
| 7 | SessionControlViewModel | `SessionControlView.swift:34` | 9 | 381、417、423 |
| | **合计** | 7 | **154** | **15**（errorMessage）+ 3（lastSyncError 2267 / planError 929 / reviewActionError 1677）= **18** |

另有 19 个“非 errorMessage 的存储型错误/失败态”，4b/4a 必须一起收：
`lastSyncError`（Culling:139）、`errorDetail`（Face:103）、`reviewActionError`
（Face:139）、`planError`（Export:257）、`fieldError`（Export:55，枚举但承载定位）、
`createError/actionError/jobsError`（Dashboard:358-362）、`actionError`（Library:376）、
`actionError`（Gallery:302）、`actionError`（Persons:34）、`writebackMessage`
（Similarity:139）、`c1HealthError/syncStateError`（Settings:125/138）、
`LoadPhase.failed(String)`（Dashboard:351、Gallery:291、Library:370、Persons:30）、
`Phase.error(String)`（Similarity:87）。
另有 6 个 `notice`（Settings/Culling/Control/Face/Export/Duplicates）。

---

## 2. 7 个 ViewModel 的 errorMessage/stored error 清单与 ViewState 映射

### 2.1 统一契约（4a 第一批新增文件，零调用点）

```swift
// Support/ViewState.swift
public enum ViewState<V: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading(previous: V?)
    case loaded(V)
    case failed(CommandError)
    case cancelled
    public var value: V? { if case .loaded(let v) = self { return v }; return nil }
    public var isLoading: Bool { if case .loading = self { return true }; return false }
}

// Support/CommandError.swift
public struct CommandError: Error, Equatable, Sendable {
    public let code: String          // "EXPORT_DIR_INVALID" / "CODE::p1" / 散文诊断
    public let params: [String]
    public let diagnostic: String
    public let retryable: Bool
    public init(code: String, params: [String] = [], diagnostic: String = "", retryable: Bool = false)
    public init(_ error: any Error)  // GatherError/SessionServiceError/APIError/Router/Bridge/NSError
}

// Support/RequestGate.swift
@MainActor public final class RequestGate {
    public private(set) var generation = 0
    @discardableResult public func begin() -> Int
    public func isCurrent(_ issued: Int) -> Bool
    public func cancel()
}
```

### 2.2 逐 VM 映射

| VM | 现有存储错误 | 迁移后 | ViewState 载体 |
| --- | --- | --- | --- |
| **Culling** | `errorMessage`(133)、`lastSyncError`(139)、`isLoading`(130) | `actionError: CommandError?`、`syncError: CommandError?` | `page: ViewState<CullingPage>`（主列表）；`summary/syncStatus/history/conflicts` 保留为辅助快照（可再收敛为 `CullingAuxState`） |
| **FaceKeywording** | `errorMessage`(100)、`errorDetail`(103)、`reviewActionError`(139) | `analysisError: CommandError?`（`diagnostic` 带原文）、`reviewError: CommandError?` | `clusters: ViewState<[FaceClusterData]>`；`analysisPhase` 保留（进度状态机，不是加载态） |
| **Export** | `errorMessage`(41)、`planError`(257)、`fieldError`(55) | `actionError: CommandError?`、`planError: CommandError?`；`fieldError` 保留为“错误定位”派生（由 code 映射） | `preview: ViewState<ExportPreview>`；`result/report` 保持事件结果 |
| **Duplicates** | `errorMessage`(121) | `actionError: CommandError?` | `groups: ViewState<[DuplicateGroup]>`；`scanResult` 独立 |
| **SessionControl** | `errorMessage`(34)、`isLoading`(33) | `loadError: CommandError?` | `snapshot: ViewState<SessionControlSnapshot>`（session+status+sync 三合一；jobs 保持独立 `jobsError`） |
| **Similarity** | `errorMessage`(130)、`phase.error(String)`(87)、`writebackMessage`(139) | `phase: ViewState<SimilarityResult>`（`.failed(CommandError)`） + `writebackNotice: LocalizedText?` | 结果/加载统一一个 ViewState；`writebackMessage` 归入 notice |
| **Settings** | `errorMessage`(117)、`c1HealthError`(125)、`syncStateError`(138) | `actionError: CommandError?`；两个 Bool 保留（子面板失败标记） | `settings: ViewState<SettingsSnapshot>`（values+modelStatus）；C1/同步面板各自 ViewState |

### 2.3 4 个列表 VM 也必须迁（设计漏项）

`Dashboard/Gallery/Library/Persons` 用 `LoadPhase.failed(String)` 存**文案**：
`DashboardViewModel.swift:351/404/421`、`GalleryViewModel.swift:291`（`phase`）、
`LibraryViewModel.swift:370`、`PersonsViewModel.swift:30/72`。设计 §5.2 说“删除
LoadPhase 旧桥”，但 §5.3 只点名 6 个 VM。实际是 **11 个 VM**：7 个 errorMessage +
4 个 LoadPhase。`LoadPhase` 可保留为 `ViewState.phase` 的过渡桥（设计已给），
但 `.failed(String)` 必须先变成 `.failed(CommandError)`。

### 2.4 错误文案边界（关键设计约束）

现状：`APIErrorPresentation.message(for:)`（`Support/APIErrorPresentation.swift:19-39`）
在 **VM 内**把任意 Error 立刻变成当前语言的字符串。若只把字段类型改成
`CommandError` 而不动写入点，VM 仍会在事件发生时把 `CommandError` 转成旧语言字符串。
因此 4a 必须同时拆成两段：

1. `CommandError.init(_:)`：只取码/参数/诊断，**不查表、不格式化**；
2. `L10n.errorText(_:)`：在 View 渲染时查 `errorMessages` 模板 + `{{param}}` 插值
   （保留 `GatherLocalization.swift:251-293` 的双形态解析：`CODE::p1::p2` 与
   `CODE: 散文`，未知码回退“发生未知错误”）。
3. 保留 `APIErrorPresentation` 作为 `CommandError` 的构造适配器（供 Host/Bootstrap
   与尚未迁移处使用），但**不再产出上屏字符串**。

### 2.5 测试影响（已确认）

- 测试中 `errorMessage` 引用 **60 处**；`LayoutBudgetTests` 仅 2 处 `isActive`。
- 大量断言在 `AppLanguageLock.withStableCopy` 下比较中文文案
  （如 `PersonsViewModelTests.swift:182`、`GalleryViewModelTests.swift:527`、
  `DashboardViewModelTests.swift:615`）。改成 `CommandError` 后这些断言必须改为
  **断言 code**（推荐），否则每加一种语言就再断一次文案。
- `ReviewFixTests.swift:408-421` 的 `pendingGalleryPhoto` 断言必须随
  `WorkspaceIntent` 重写（设计 §5.8 已列）。

---

## 3. 本地化调用统计与 codemod 风险

### 3.1 复核结论

- `GatherLocalization.l(`：**1,481 处代码调用**（另有 1 处仅出现在注释
  `DashboardView.swift:735`，不计），比设计的 **1,439 多 42 处（+2.9%）**。
- 全部 `GatherLocalization.*` 引用：**1,533 处**（含 1 处注释，代码引用 1,532）；
  其中非 `l()` 的 **51 处**必须单独设计替换（见 §3.4）。
- 1,481 处中：**1,466 处是字面量 key**，**15 处是动态 key**（§3.5）；
  字面量只对应 **1,034 个唯一 key**（432 处重复使用）。
- en 表：**1,408 条目 / 1,397 唯一键**（11 个重复键，其中 3 个译文不同 → 后者
  覆盖前者）；6 个代码在用的 key **不在表里**（en 界面回落中文）。

> 结论：设计的 1,439 是 Cut 0/Cut 1 时点快照；Cut 1 之后 UI 又新增了约 42 处。
> codemod 的**基数应以 1,481 + 51 = 1,532 为准**，且必须按“文件”而不是“行”计
> commit，否则 1,532 处无法逐条 review。

### 3.2 按目录（`l(` 计数 / 全部 `GatherLocalization.*`）

| 目录 | `l(` | 全部 | 备注 |
| --- | --- | --- | --- |
| GatherUI/Culling | 265 | 269 | 最大单页 |
| GatherUI/FaceKeywording | 183 | 189 | |
| GatherUI/Similarity | 143 | 146 | 含 VM 39 |
| GatherUI/Library | 121 | 124 | 含 VM 6 |
| GatherUI/ControlCenter | 117 | 120 | |
| GatherUI/Dashboard | 113（+1 注释） | 122 | 含 VM 23 |
| GatherUI/Settings | 108 | 111 | |
| GatherUI/Export | 98 | 101 | |
| GatherUI/Gallery | 85 | 85 | 含 VM 8 |
| GatherUI/Duplicates | 80 | 82 | |
| GatherUI/Persons | 56 | 58 | |
| GatherUI/Support | 41 | 50 | 共享组件/页签/胶囊 |
| GatherHost | 67 | 72 | Delegate 49、RootView 10、Commands 5、AppImport 2、Bootstrap 1 |
| GatherApp | 4 | 4 | 启动占位 |
| **合计** | **1,481** | **1,533** | — |

### 3.3 Top 文件（`l(` 出现次数）

```text
265  GatherUI/Culling/CullingView.swift
183  GatherUI/FaceKeywording/FaceKeywordingView.swift
117  GatherUI/ControlCenter/SessionControlView.swift
115  GatherUI/Library/LibraryView.swift
108  GatherUI/Settings/SettingsView.swift
104  GatherUI/Similarity/SimilarityView.swift
 98  GatherUI/Export/ExportView.swift
 90  GatherUI/Dashboard/DashboardView.swift（另 1 处注释）
 80  GatherUI/Duplicates/DuplicatesView.swift
 77  GatherUI/Gallery/GalleryView.swift
 55  GatherUI/Persons/PersonsView.swift
 49  GatherHost/GatherAppDelegate.swift
 39  GatherUI/Similarity/SimilarityViewModel.swift
 23  GatherUI/Dashboard/DashboardViewModel.swift
 14  GatherUI/Support/SessionTabBar.swift
 13  GatherUI/Support/GatherBadge.swift
```

> 设计 §5.7 的每页预算（Culling 255 / Face 181 / Control 108 / Settings 101 /
> Export 96 / Duplicates 69）**全部偏低**：实测 265/183/117/108/98/80。

### 3.4 非 `l()` 的 51 处（必须单独迁移）

| API | 次数 | 语义 | 迁移目标 |
| --- | --- | --- | --- |
| `errorText` | 26 | 错误码 → 文案（含 `CODE::p`） | `l10n.errorText(CommandError)`；VM 内改存 code |
| `progressPhaseText` | 7 | 相位码 → 文案 | `l10n.progressPhaseText(_:)` |
| `setAppLanguage` | 5 | 写全局 | `LanguageStore.set`（菜单/Delegate 例外） |
| `cancellationNotice` | 4 | 取消提示 | `LocalizedText.cancel(action:)` |
| `jobErrorMessage` | 3 | 任务错误码 → 文案 | `l10n.jobErrorMessage(_:)` |
| `appLocale` | 2 | 日期 locale | `l10n.locale` |
| `jobTypeText` | 1 | 任务类型 | `l10n.jobTypeText(_:)` |
| `isParameterizedErrorCode` | 1 | 码形判定（Library:804） | 移入 CommandError |
| `errorMessages`（直接查表） | 1 | `SessionControlView.swift:808` | `l10n.errorText` |
| `appLanguage` | 1 | 读全局（C1:308） | `l10n.language` |

### 3.5 codemod 风险清单（按危险度）

**R1 动态 key（15 处，无法正则替换）**

- 12 处在 `SettingsView`：`l(field.zhLabel)`（:279/300/304/308/735/739/1738）、
  `l(group.titleZh)`（:1408/1767）、`l(title)`/`l(description)`（:1777/1779）、
  `l(option.labelZh)`（:1859）。这些 key 来自 `static let settingGroups`
  （:36-100 区段，**76 行中文字面量**）。静态表在首次访问时求值；若表项改成
  `(L10n) -> String` 闭包，需同步改 5 个调用点与 `SettingField/SettingGroup`
  的类型（public struct，测试 `SettingsCatalogTests` 会受影响）。
- 2 处在 `GatherAppDelegate`（:385/465）：`l(sidebarVisible ? "隐藏侧栏" : "显示侧栏")`
  ——菜单是允许保留 `GatherLocalization` 的例外，可不动。
- 1 处在 `C1StatusCapsule.swift:256`：`let l: (String) -> String = { GatherLocalization.l($0) }`
  ——局部闭包，正则 `GatherLocalization.l(` → `l10n` 会把闭包捕获改坏，需手工
  改成 `let l = l10n.callAsFunction` 或直接传 `L10n`。

**R2 `String(format:)`（211 处，其中 202 处直接包 `l()`）**

- 机械替换必须先外后内：`String(format: l("x %lld"), n)` →
  `l10n.format("x %lld", n)`，不能只换 `l` 保留 `String(format:)`（会丢 locale）。
- 参数类型风险：`%lld` 必须配 `Int`，`%@` 必须配对象；现有代码混用
  `Int/Double/String`。批量改写若换错参数类型，**运行时会崩**（`String(format:)`
  对 `%@` 传 Int 是未定义行为）。建议 codemod 只做“文本包裹”，参数原样保留，
  由编译器 + 逐页 smoke 兜底。
- `String(format:)` 里的 `%%`（如 `"%@ · 置信度 %lld%%"`）必须原样保留。

**R3 复数（145 个 `%lld` + 3 个 `%d`，0 个 `.stringsdict`）**

- 现在英文用“硬编码复数”近似：只有 1 处 `(s)`（`en.lproj:330`），其余是
  `"%lld photos"`。count=1 时英文语法错误（"1 photos"）。迁移到 `l10n.format`
  不会变好也不会变坏。**4b 应显式声明“不引入复数系统”**，否则会膨胀成
  `stringsdict` + 145 键的重写，超出 Cut 4 预算；若要修，单列 Cut 5。
- 例外：`String(format: l(" 等 %d 个"), failedCount)`（RootView:494）与
  `"%lld 张照片已导入；…"`（:498）是导入汇总句，英文表已改写为
  `" and %d more"`，语序依赖前缀拼接 —— 属 R4。

**R4 字符串拼接/语序（12 + 9 + 6 处）**

- `"操作失败：%@"` 前缀拼接 **12 处**（Settings:1366、Culling:1491、Control:382、
  Gallery:239、Similarity:247、Library:78、Dashboard:66、Face:1195、Persons:47/509、
  Export:727、Duplicates:474）。英文前缀 `"Operation failed: %@"` 尚可，但错误本身
  可能已是完整句，读起来是“Operation failed: The export directory is invalid.”。
  建议 4b 改为 `GatherErrorBanner(error:)` 自带标题，删掉 12 处前缀拼接。
- `+=` / `+` 多句拼接 9 处：`CullingView.swift:1216`（`；另有 %lld 条`）、
  `SimilarityView.swift:39/41`、`FaceKeywordingView.swift:355/368/412/839/841`、
  `CullingView.swift:3380`（`分析失败` + `" ⚠"`）。多句拼接无法翻译语序，
  必须合成单模板或 `[LocalizedText]` 渲染。
- 插值拼接 6 处：`CullingView.swift:1993`、`GalleryView.swift:824`、
  `DashboardView.swift:671`、`ExportView.swift:484`、`DuplicatesView.swift:683/684`。
  这些是 “数字 + 本地化词” 的固定顺序，zh/en 恰好同序；仍应改为
  `l10n.format("人脸 %lld")` 形式，避免第三种语言翻车。

**R5 正则覆盖不到的中文（原始扫描 92 行；真正用户可见约 80 行）**

- `SettingsView.swift` 76 行：`zhLabel/zhDesc/titleZh` 静态表（作为 key 可保留，
  但改成闭包会动类型）+ 2 条模型错误散文（:323/328，含路径插值，**永远中文**）。
- 2 处硬编码中文日期格式：`PersonsView.swift:479` 与 `DateFormatting.swift:60`
  按**系统语言**判定而不是 `ui_language`（Persons 注释自认“页面无 ui_language
  访问通道”）。4a 有 `l10n` 后应改判 `l10n.language`，否则“设置里切 en、系统
  仍是 zh”时日期仍是中文格式。
- `LiveSettingsAPI.swift:105` 的“内置 SFace”标签未本地化（模型路径回显）。
- 不计入：`C1StatusCapsule.swift` 8 行走局部 `l` 闭包（已本地化，但 codemod
  R1 会漏改）；`GatherCommonViews.swift` 4 行是 `@available` 开发者文案；
  `GatherAppDelegate.swift:220` 是菜单标题比对。
- 这些不进 `l()`，所以“1,481 → 0”门禁通过后 en 界面仍会有中文。4b 需要单独的
  “CJK 字面量 allowlist”（含“必须为 0”与“允许保留”两类），否则验收指标是假的。

**R6 表质量（会直接让 parity 测试红）**

- 11 个重复键（`全部/返回/星级/颜色/…`）；其中 3 个译文冲突：
  `星级`（Star Rating / Rating）、`存在 XMP 冲突，请先裁决`、
  `有写入失败项，请先重试` —— `.strings` 后者覆盖前者，实际生效值不可预期。
- 6 个代码在用但表里没有的 key：
  `重新分析人脸`、`将写入 %lld 张照片 + %lld 个 XMP 边车，共 %lld 个文件。`、
  `其中 %lld 项存在问题，导出时会失败。`、
  `未在当前工作区找到这张照片（可能已被移除或不在本工作区）。`、
  `模型包缺少必需文件：%@`、`模型包中的文件为空：%@`。
- `zh-Hans.lproj` 只有 10 条（中文即 key 的设计成立），但意味着 **zh 表不能做
  parity 基线**；parity 应以“代码 key 集合 ⊆ en 表键集合”+“无重复键”双向断言。

**R7 分页/长文本性能**

- `l()` 每次调用 `Bundle.localizedString`（有 bundle 缓存，但无字符串缓存）。
  网格每帧数百次调用（`GalleryCellView` 的 chip、`Face` 的成员行）。4b 把
  `l()` 变成 `l10n(...)` 后调用次数不变；建议 `L10n` 内部加
  `[String: String]` 缓存（按语言一份），否则 codemod 后滚动性能与现在持平，
  不会变差但也不会变好。**不要**在 `body` 里新建 `L10n` 实例（设计给的是
  `LanguageStore.l10n` 计算属性，值类型，成本低）。

### 3.6 建议的 codemod 执行规则

1. 先做“结构替换”（`String(format: l("…"), args)` → `l10n.format("…", args)`），
   再做“裸替换”（`l("…")` → `l10n("…")`）；两条正则分开跑，避免嵌套漏改。
2. 每文件一个 commit；每个 commit 必须 `swift build` 通过（GatherUI target 单独
   可构建）。**不要**一次全仓替换后编译——1,532 处错误无法定位。
3. 15 个动态 key 先手工改类型（Settings 静态表 → 闭包），再跑正则。
4. `errorText/jobErrorMessage/progressPhaseText/cancellationNotice` 不参与正则，
   逐调用点手工改（51 处）。
5. 每完成一个目录，跑一次 `grep -c 'GatherLocalization\.l(' <dir>` 并把数字写进
   commit message，形成可审计的递减序列（1,481 → 0）。
6. 新增 `docs/i18n-migration.lst`：只允许 `GatherAppDelegate/GatherAppCommands`
   两个菜单文件 + `AppBootstrap`（启动失败兜底）保留旧 API；其余文件计数必须为 0。

---

## 4. SessionStore / SessionWorkspace / WorkspaceIntent 设计

### 4.1 职责边界（先分清三件事）

| 关注点 | 现在 | 4a 后 |
| --- | --- | --- |
| **导航身份**（在哪个页面） | `RootNavigation` | 保留 `RootNavigation`（不动，测试已 pin） |
| **会话生命周期**（哪些 workspace 活着、可见性、LRU） | `SessionDraftCache` + RootView 各处 onChange | `SessionStore` + `SessionWorkspace` |
| **入口意图**（进页后要做什么） | 4 个 pending 容器 + `faceKwInitialRole` + 2 个 photo 字段 | `WorkspaceIntent` 单一队列，take-and-clear |

`SessionStore` **不持有 destination**。把导航也塞进去会让 `RootNavigationTests`
（10 条）与 `goBack` 语义全部重写，收益低、冲突面大。

### 4.2 状态字段

`SessionStore`（壳层单例，@MainActor）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `activeSessionId` | `String?` | 当前可见 workspace；nil = 非会话页 |
| `lastSessionId` | `String?` | 侧栏“当前会话”回退（迁自 RootNavigation.lastSessionId） |
| `pinnedSessionId` | `String?` | 不淘汰（迁自 draftCache.activeSessionId） |
| `workspaces` | `[String: SessionWorkspace]` | 活动表 |
| `recent` | `[String]` | LRU 顺序 |
| `capacity` | `Int` | **建议 6**（设计值）；现 8 |
| `makeWorkspace` | `(String) -> SessionWorkspace` | 工厂闭包（注入 API） |

`SessionWorkspace`（每会话）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sessionId` | `String` | — |
| `culling / duplicates / export / face` | 4 个 VM | 设计已列 |
| `control / gallery / similarity` | 3 个 VM | **设计漏列，必须补**（否则 control 每次重建、gallery/similarity 仍单槽） |
| `lifecycle` | `.active/.suspended/.closed` | 显式生命周期 |
| `isVisible` | `Bool` | 唯一可见性真相（= activeSessionId 命中且目的地属于本会话） |
| `pendingIntents` | `[WorkspaceIntent.Kind: WorkspaceIntent]` | take-and-clear |
| `staleDomains` | `Set<GatherDomain>` | 隐藏期登记的失效域 |
| `sessionName` | `String?` | 缓存标题，替代 `RootView.refreshWindowTitle` 的同步查库 |

`WorkspaceIntent`：

```swift
public enum WorkspaceIntent: Equatable, Sendable {
    case galleryFilter(GalleryFilter)
    case galleryPhoto(id: String?, path: String?)
    case cullingConflicts
    case faceAnalyze
    case faceRole(String)
    case exportRange(ExportRangeIntent)
    public enum Kind: Hashable, Sendable {
        case galleryFilter, galleryPhoto, cullingConflicts, faceAnalyze, faceRole, exportRange
    }
    public var kind: Kind { … }
}
```

### 4.3 动作

```swift
@MainActor @Observable
public final class SessionStore {
    public private(set) var activeSessionId: String?
    public private(set) var lastSessionId: String?
    public init(capacity: Int = 6, make: @escaping (String) -> SessionWorkspace)
    public func workspace(for id: String) -> SessionWorkspace      // 命中提序 + 建
    @discardableResult
    public func activate(_ id: String?) -> SessionWorkspace?        // suspend 旧、activate 新、LRU 淘汰
    public func pin(_ id: String?)
    public func evict(_ id: String)
    public func endSession(_ id: String)                            // 删除会话后清理
}

@MainActor @Observable
public final class SessionWorkspace: Identifiable {
    public enum Lifecycle: Equatable { case active, suspended, closed }
    public let sessionId: String
    public let culling: CullingViewModel
    public let duplicates: DuplicatesViewModel
    public let export: ExportViewModel
    public let face: FaceKeywordingViewModel
    public let control: SessionControlViewModel
    public let gallery: GalleryViewModel
    public let similarity: SimilarityViewModel
    public private(set) var lifecycle: Lifecycle = .suspended
    public private(set) var isVisible = false
    public private(set) var sessionName: String?

    public func setVisible(_ visible: Bool)        // 启停 8 套轮询 + flush staleDomains
    public func enqueue(_ intent: WorkspaceIntent)
    public func take(_ kind: WorkspaceIntent.Kind) -> WorkspaceIntent?   // 取出即清
    public func close()                            // cancel Task、清大数组
}
```

`setVisible` 的内部映射（把 §1.5 的 8 套机制收成一张表）：

| VM | visible=true | visible=false |
| --- | --- | --- |
| culling | `isActive = true`；`flushDeferredDomainRefresh()` | `isActive = false`（停 500ms 轮询） |
| gallery | `startIndexStatusPolling()`；补 `refreshDeferredWhileHidden` | `stopIndexStatusPolling()` |
| similarity | 按状态恢复 progress/result 轮询 | 停两路轮询 |
| control | 启动 fallback 轮询（从 View 的 `while` 迁入 VM） | 停轮询 |
| dashboard（全局，不在 workspace） | `isVisible = true; startAutoRefresh()` | `isVisible = false; stopAutoRefresh()` |
| library/persons（全局） | 允许事件刷新 | 跳过事件刷新（替代 `isActive` 参数） |

### 4.4 订阅/失效

现状是 **每个 View 各自订阅**（Gallery:204-218、Culling:1564-1572、Control:467-484、
Library:114-124、Persons:87-92、Dashboard:87-108、Similarity:View 内订阅 +
VM 轮询）。迁移后：

1. `SessionWorkspace` 在 `activate` 时订阅 `GatherEventCenter.domainChanged` /
   `jobTerminal` / `c1SyncStatus` **一次**，按 `sessionId` 过滤后转发给可见 VM；
2. 不可见时只记 `staleDomains`（替代 `pendingDomainRefresh` /
   `refreshDeferredWhileHidden` 两份私有标记）；
3. `setVisible(true)` → 按 `staleDomains` 补刷一次，清空集合；
4. `suspended` 期间**不发命令**（沿用现有“隐藏页不发命令”约定）；
5. `close()` 取消所有 `Task`（Gallery `statusPollTask/fetchTask`、
   Similarity `pollTask/resultPollTask/tierTask`、Culling `refreshTask`、
   Control 轮询、Face reload Task）。
6. 语言/菜单/Toast 仍走 NotificationCenter（不在 workspace 内），由 Shell 订阅。

**失效边界**：`workspace(for:)` 命中后必须 `noteAccess`（现有 B7 修复），淘汰时
跳过 `pinnedSessionId`；`activate(nil)` 只 suspend，不淘汰。

### 4.5 与现有 VM 的接缝（逐个）

| 接缝 | 现状 | 4a 改法 |
| --- | --- | --- |
| Culling | 外壳 `cullingViewModel(for:)`（:772-792）创建；View `onAppear/onDisappear` 写 `isActive` | 工厂放进 Workspace；`isActive` 私有化，由 `setVisible` 写 |
| Face | 创建时传 `initialRoleFilter: faceKwInitialRole`（:764）；VM 有 `initialRoleSeeded`（:134） | 改为 `enqueue(.faceRole(role))`，View/VM 在 `.task` 中 `take` 后调 `applyRoleFilter`；删 `initialRoleSeeded` |
| Export | 创建后由 View `applyRangeIntent(rangeIntent)`（`ExportView.swift:90-93`） | `take(.exportRange)` 后调用；`onConsumeRangeIntent` 回调删除 |
| Duplicates | 与 culling 同构 | 同构 |
| Control | 每次 View init 新建（`SessionControlView.swift:359-365`），无缓存；轮询在 View 的 `.task` | 进 Workspace；轮询迁到 VM `setVisible` |
| Gallery | RootView 单槽 `galleryViewModel`（:364），`syncViewModels`（:952-961）换会话；轮询由外壳/视图双停 | 进 Workspace（每会话独立）；删 `syncViewModels` |
| Similarity | 单槽 + `syncViewModels`（:962-980）；轮询由外壳停 | 进 Workspace；`setVisible` 统一 |
| Gallery 照片意图 | `RootNavigation.pendingGalleryPhotoId/Path`（:118-119）→ View init（:676-677）→ VM `.task` 消费 | `WorkspaceIntent.galleryPhoto`；View 在 `.task` take；删 2 个导航字段 |
| Gallery 筛选意图 | `draftCache.pendingGalleryFilter`（:337） | `WorkspaceIntent.galleryFilter` |
| Culling 冲突意图 | `draftCache.pendingCullingConflicts`（:335） | `WorkspaceIntent.cullingConflicts` |
| Face 分析意图 | `draftCache.pendingFaceAnalyze`（:339） | `WorkspaceIntent.faceAnalyze` |
| 窗口标题 | `refreshWindowTitle` 同步 `provider.listSessions()`（:987-994） | Workspace 异步 `SessionAPI.get` 缓存 `sessionName`；标题读缓存 |

### 4.6 RootView 迁入 GatherUI 的依赖形状（D-017 的硬约束）

`RootView` 现在 import 了 `GatherPersistence/Analysis/Domain`（:13-15），只因为
`AppServices`（Host 类型）。迁 UI 时必须换成 UI-owned 的依赖包：

```swift
// GatherUI/Shell/RootShellDependencies.swift
public struct RootShellDependencies {
    public let session: any SessionAPI
    public let job: any JobAPI
    public let settings: any SettingsAPI
    public let culling: any CullingAPI
    public let navigation: any NavigationAPI
    public let metadata: any MetadataAPI
    public let quality: any QualityAPI
    public let face: any FaceAPI
    public let similarity: any SimilarityAPI
    public let duplicate: any DuplicateAPI
    public let export: any ExportAPI
    public let person: any PersonAPI
    public let captureOne: any CaptureOneBridging
    public let dashboardProvider: any DashboardDataProvider
    public let libraryProvider: any LibraryDataProvider
    public let galleryProvider: any GalleryDataProvider
}
```

`GatherApp` 侧由 `AppBootstrap.SceneState`（:30-38）组装：
`RootView(deps: .init(appServices: scene.appServices, captureOne: scene.captureOneBridge,
providers: …))`。这样：
- UI 仍只 import Protocol（layering 门禁不变）；
- RootView 不再自建 `CaptureOneBridge`（:430-434 的双实例消失）；
- `sessionName` 走 `deps.session.get`，不再需要 Host 的 `LiveDashboardDataProvider` 强转。

### 4.7 待裁决（3 项，需写进 refactor-decisions）

1. **Workspace 是否包含 gallery/similarity/control**：设计只列 4 个。若不包含，
   control 每次重建、gallery/similarity 仍单槽，状态层只完成一半；若包含，
   6 个 workspace × 7 个 VM = 42 个 VM，gallery 最多 1,000 张/会话、
   similarity 结果可能是大数组，**必须把 capacity 从 8 降到 4-6 并在 close()
   清空大数组**。建议：包含，capacity 6。
2. **`SessionControlViewModel` 的轮询所有权**：现在在 View 的 `.task`（:453-466）。
   迁进 VM 后必须由 `setVisible` 启停；若沿用“View 消失即取消”，则 workspace
   常驻会让轮询永久运行（隐藏页空转）。建议迁入 VM。
3. **`SessionStore` 放 GatherUI 还是 Host**：D-017 说 Shell 迁 UI。放 UI 需要
   §4.6 的依赖包；放 Host 则 UI 页面拿不到 Environment。建议放 UI，Host 只做装配。

---

## 5. View 拆分

### 5.1 现状规模（实测）

| 文件 | 行数 | 设计值 | 结构 |
| --- | --- | --- | --- |
| `Culling/CullingView.swift` | **3,567** | 3,525 | VM 30-1442 + View 1443-2768 + 6 个私有 View/工具 |
| `FaceKeywording/FaceKeywordingView.swift` | **2,123** | 2,098 | VM 50-824 + 9 个 Pending 结构 + View 948-2023 + MemberRow |
| `Settings/SettingsView.swift` | **1,870** | 1,756 | 6 个模型结构 + VM 101-954 + ModelInstaller 1019-1185 + View 1227-1870 |
| `Gallery/GalleryView.swift` | **1,362** | — | LayoutCache + SessionTab + View 50-834 + Cell + Lightbox + ScrollCatcher |
| `ControlCenter/SessionControlView.swift` | **1,187** | 1,073 | VM 17-248 + Inbox/Recommended 模型 + View 313-1187 |
| `Export/ExportView.swift` | **1,182** | 1,139 | VM 29-606 + Confirmation + View 646-1182 |
| `Similarity/SimilarityView.swift` | **974** | — | 4 个 Pending + View + GroupCard + MemberCell |
| `Dashboard/DashboardView.swift` | **937** | — | View + SessionRow + JobRow + NewSessionSheet |
| `Library/LibraryView.swift` | **933** | — | View + LibraryCard + ColorOption |
| `Duplicates/DuplicatesView.swift` | **874** | — | 2 个 Pending + VM 111-407 + View + GroupCard |
| `Persons/PersonsView.swift` | **537** | — | View + ListRow + Detail + CreateSheet |
| `GatherHost/RootView.swift` | **996** | 1,050（任务口径） | Navigation 18-273 + DraftCache 284-340 + RootView 353-996 |

### 5.2 CullingView → 9 个文件（单文件 ≤600，CullingView ≤200）

| 目标文件 | 源区间 | 行数 | 依赖 |
| --- | --- | --- | --- |
| `CullingViewModel.swift` | 30-1442 | 1,413 | 5 个 API + CaptureOneBridging |
| `CullingView.swift`（壳） | 1443-1745、1746-1794 | ~350 | VM、回调、`PendingCullingAction` |
| `CullingActionController.swift`（新） | 把 View 的 confirm/apply 分支（1455/2456-2557 等）抽出 | ~250 | VM、`MetadataAPI` |
| `Views/CullingToolbar.swift` | 1795-2020 | 226 | VM、`DecisionButtonView`(2769-2804) |
| `Views/CullingInspector.swift` | 2021-2199 | 179 | VM、`GatherTheme` |
| `Views/CullingInfoBar.swift` | 2200-2374 | 175 | VM、`C1StatusCapsule` |
| `Views/CullingFilmstrip.swift` | 2375-2455 + `CullingFilmThumbView` 2805-2926 | 183 | VM、缩略图端口 |
| `Views/CullingViewer.swift` | `CullingWorkbenchViewer` 2997-3505 + `WindowBridge` 3506-3521 + `ViewerZoomChrome` 3553-3567 | ~520 | VM、AppKit、`PhotoViewerGeometry` |
| `Views/CullingConflictPanel.swift` | 2456-2557 | 102 | `MetadataConflict`、确认回调 |
| `CullingShortcutMap.swift`（新） | 快捷键 1960/1969/2216/2225/3121-3142 | ~80 | 纯函数，可单测 |

拆分注意：`CullingWorkbenchViewer` 有 13 个 `@State`（3002-3024），拆出后
**必须保持同一视图身份**（不能在外面套 `.id`），否则缩放/监听状态每次翻页重置。
`WindowBridge`/`ViewerZoomChrome` 是 `NSViewRepresentable`/`ViewModifier`，
可留在 Viewer 文件，不必单独成文件。

### 5.3 FaceKeywordingView → 6 个文件

| 目标 | 源区间 | 行数 |
| --- | --- | --- |
| `FaceKeywordingViewModel.swift` | 50-824 | 775 |
| `FaceKeywordingView.swift`（body + banners + stepPicker） | 948-1190、1191-1303 | ~355 |
| `Views/FaceAnalyzeStep.swift` | 1304-1476 | 173 |
| `Views/FaceReviewStep.swift` | 1477-1522 + clusterPane 1523-1658 + detailPane 1659-1792 | ~316 |
| `Views/FaceWritebackStep.swift` | 1793-2023 | 231 |
| `Views/FaceMemberRow.swift` + `FaceClusterCount.swift` | 2024-2091、2094-2122 | ~100 |

9 个 `PendingFace*`（825-947）随确认弹窗留在壳文件，或抽
`FaceKeywordingConfirmations.swift`（~120 行）。

### 5.4 GalleryView → 5 个文件

| 目标 | 源区间 | 行数 |
| --- | --- | --- |
| `GalleryView.swift`（壳/工具栏/筛选/检查器） | 50-423 + 591-834 | ~620（仍偏大，可再拆） |
| `Views/GalleryGrid.swift`（cell + justified row） | 715-834 + 837-944 | ~230 |
| `Views/GalleryLightbox.swift` | 424-518 + 954-1319 | ~460 |
| `Views/GalleryIndexHeader.swift` | 519-590 | ~72 |
| `Views/GalleryScrollCatcher.swift` | 1325-1362 | ~38 |

`SessionTab`（25-33）应移到 `Shell/SessionTab.swift`（现在它在 Gallery 文件里，
RootView 依赖它）。

### 5.5 其余

- `SettingsView`（1,870）：`SettingsView`（1227-1360 壳）+
  `Views/SettingsGeneral.swift`（1361-1594）+
  `Views/SettingsC1Health.swift`（1595-1696）+
  `Views/SettingsLanguage.swift`（1697-1717）+
  `Views/SettingsFace.swift`（1718-1869）+ `SettingsModels.swift`（34-100）+
  `ModelInstaller.swift`（1019-1185）+ `C1Probe.swift`（955-1017）。
- `SessionControlView`（1,187）：壳 + `Views/StageTimeline.swift`（592-704）+
  `Views/ActionInbox.swift`（705-871）+ `Views/RecommendedNext.swift`（872-997）+
  `Views/JobsCard.swift`（1095-1186）+ `Views/SyncCard.swift`（1023-1094）。
- `ExportView`（1,182）：`ExportViewModel.swift`（29-606）+
  `ExportView.swift`（646-857）+ `Views/ExportRangeSection.swift`（896-938）+
  `Views/ExportOptions.swift`（939-1082）+ `Views/ExportPreview.swift`（1083-1150）+
  `Views/ExportResult.swift`（1151-1182）+ `Views/ExportProgress.swift`（858-895）。
- `DuplicatesView`（874）：VM + `Views/DuplicatesScanControls.swift`（620-679）+
  `Views/DuplicateGroupCard.swift`（754-874）。
- `SimilarityView`（974）：`Views/SimilarityAnalysisPanel.swift`（317-437）+
  `Views/SimilarityWritebackPanel.swift`（438-613）+
  `Views/SimilarityGroups.swift`（747-973）。
- `DashboardView`（937）：`Views/DashboardSessions.swift`（230-414）+
  `Views/DashboardJobs.swift`（586-702）+
  `Views/NewWorkspaceSheet.swift`（703-936）。
- `LibraryView`（933）：`Views/LibraryFilters.swift`（188-319）+
  `Views/LibraryInspector.swift`（320-663）+ `Views/LibraryGrid.swift`（690-932）。
- `RootView`（996 → ≤300）：
  `Shell/RootNavigation.swift`（18-273，**已独立类，直接搬**）+
  `Shell/RootSidebar.swift`（553-623）+
  `Shell/RootDetail.swift`（627-718）+
  `Shell/SessionTabHost.swift`（844-948）+
  `Shell/WorkspaceFactories.swift`（731-842）+
  `RootView.swift`（353-552 + 950-996，~250）。

### 5.6 拆分顺序

1. 先搬 `RootNavigation` / `SessionTab`（纯移动，编译即验证）；
2. 再拆“叶子”私有 View（Cell/Row/Card/确认弹窗），不动 body；
3. 最后拆 `body` 的章节（toolbar/inspector/infoBar/filmstrip/viewer）；
4. 每拆一块跑 `swift build`；**每拆一块提交**，避免 3,567 行的巨型 diff。
5. 拆分时禁止顺手改行为（尤其 `.task/.onAppear/.onDisappear` 的位置）；
   4c 的验收只认“行数/Preview/编译”，行为变更留给后续。

---

## 6. Preview 现状与 ≥12 目标清单

### 6.1 现状：0

```text
grep -rn '#Preview' desktop/native/gather-app/Sources → 0
find . -name '*Preview*' (排除 .build)          → 0
```

设计 §5.4 要求“每个拆出的 View 必须有 #Preview，目标 ≥12”；当前一个都没有。
`Tests/GatherAppTests/Support/` 下有 5 组 Stub API（`StubCullingAPI.swift` 691 行、
`StubSimilarityAPI.swift` 377、`StubFaceAPI.swift` 370、`StubAPIs.swift` 370、
`StubExportMetadataAPIs.swift` 281 等），但 **GatherUI 不能依赖 Tests**，
必须复制/上移到 Sources 的 `#if DEBUG` 目录（或新建 `GatherPreviewSupport`
target 由 UI 在 DEBUG 下依赖——SwiftPM 不支持按配置依赖，实际只能同 target
`#if DEBUG`）。

### 6.2 Fixture 基础设施（必须先做，否则 12 个 Preview 无法编译）

```text
GatherUI/Preview/
├── PreviewFixtures.swift        // 固定 id/日期/路径/计数，确定性
├── PreviewAPIs.swift           // #if DEBUG：12 个 API 的内存实现
├── PreviewProviders.swift      // Dashboard/Library/GalleryDataProvider
├── PreviewImageDecoder.swift   // 注册 1×1 PNG，避免读盘
└── PreviewHost.swift           // 统一 environment(LanguageStore.preview) + 主题
```

- `PreviewAPIs` 只需实现 **view 用到的方法**（不是 12 个协议的全部方法）：
  可用 `#if DEBUG` + `fatalError("unused in preview")` 兜底其余。
- `PreviewImageDecoder` 实现 `ImageDecoderPort`（`Support/ImageDecoderPort.swift:55-63`），
  返回 32×32 纯色 JPEG；通过 `ImageDecodingRegistry.install`（:73）注册。
- `LanguageStore.preview`（`.zhHans`）与 `.previewEnglish`（`.en`）两套，用于
  验证“同一 Preview 切语言不重建 VM”。
- 所有 fixture 必须 `#if DEBUG`，否则会把 stub 打进 release bundle（体积与
  攻击面）；`build.sh` 的 release 构建需确认 `DEBUG` 未定义。

### 6.3 ≥12 个目标 Preview

| # | Preview | 需要的 fixture | 额外依赖 |
| --- | --- | --- | --- |
| 1 | Culling 工作台（有照片/筛选/检查器） | `CullingPage`(3 assets)、`CullingSummary`、`MetadataSyncSummary`、`FilterState` | `StubCullingAPI`；`ImageDecoderPort` |
| 2 | Culling 空态 / 加载失败 | 空 page、`CommandError(code:"CULLING_LOAD_FAILED")` | 同上 |
| 3 | Culling 冲突面板 | `MetadataConflict` ×2 + 选择回调 | `StubMetadataAPI` |
| 4 | Face 分析步（进度 + 模型缺失条） | `FaceAnalysisResult`、progress 3/12、`modelsMissing` | `StubFaceAPI`、`StubJobAPI` |
| 5 | Face 审核步（绑定/未绑定 + 选中簇） | `FaceClusterData` ×6（2 绑定）、成员 12 | 同上 |
| 6 | Face 写回步（预览 + 报告） | `WritebackPreview`(3 项)、`WritebackResult`(2 失败) | 同上 |
| 7 | Gallery 网格（12 张，含变体/人脸徽标） | `GalleryPhotoData` ×12、`SessionData` | `StubGalleryProvider` |
| 8 | Gallery Lightbox（选中一张） | 同上 + `initialPhotoId` | 同上 |
| 9 | Library 网格 + 检查器（相册/候选/孤立） | `GlobalPhotoResult` ×8、`SmartAlbumData` ×2、`AssetLinkCandidateData` ×1、`MetadataOrphan` ×1、`AssetVolumeData` ×1 | `StubLibraryProvider` |
| 10 | Dashboard（2 会话 + 运行中任务 + 失败任务） | `SessionData` ×2、`WorkspaceStatus` ×2、`AnalysisJobData` ×3 | `StubDashboardProvider` |
| 11 | 控制中心（索引中 + 待办 + 推荐） | `WorkspaceStatus`(active)、`AnalysisJobData` ×2、`MetadataSyncSummary` | `StubSession/Culling/Job/Quality` |
| 12 | 重复检测（分组 + 阈值过期） | `DuplicateGroup` ×3、`scannedThreshold=4` vs `threshold=10` | `StubDuplicateAPI` |
| 13 | 相似度（结果分组 + 写回面板） | `SimilarityResult`(3 组/12 张)、`WritebackPreview` | `StubSimilarityAPI` |
| 14 | 导出（预览 + 空间不足） | `ExportPreview`(freeSpace 0)、`ExportResult` | `StubExportAPI` |
| 15 | 设置（普通 + C1 健康 + 语言） | `[String:String]` 15 键、`MLStatusData`、`C1HealthSnapshot` | `StubSettingsAPI` |
| 16 | 人物库（列表 + 详情） | `PersonData` ×5、`PersonDetailData` | `StubPersonAPI` |
| 17 | RootSidebar（三种选中态） | `RootNavigation(destination:)` | 仅侧栏；不构造 AppServices |

**建议交付 14 个**（1-14），15-16 作为拆分奖励，17 作为 RootView 拆分的验证。

### 6.4 不能直接 Preview 的

- `RootView` 全壳：需要 `AppServices`（16 个 API + `AppRuntime` + DB）。
  除非先拆出 `RootSidebar`/`RootDetail`（§5.5），否则只能预览子壳。
- `GatherApp`/`Settings` Scene：依赖 `AppBootstrap` 异步启动与 DB，不做。
- `CullingWorkbenchViewer` 的滚轮/缩放：可 Preview 静态布局，交互需人工。

---

## 7. 分步计划（4a / 4b / 4c）

> 总体顺序：**4a 状态层 → 4b l10n → 4c View 拆分/Preview**。
> 理由：4b 的 `l10n` 需要 4a 的 `LanguageStore`；4c 的 Preview 需要 4a 的
> `ViewState` 与 4b 的 `L10n`（否则 fixture 里还要构造中文错误串）。
> 三步都在 `refactor` 分支上按“可编译小步”推进，**禁止 4a 与 4c 并行改同一文件**。

### 7.1 4a：状态层 + ViewState + LanguageStore（约 8-10 人日）

#### 4a-0 新增类型（零调用点，1 人日）

- 新增：`Support/ViewState.swift`、`Support/CommandError.swift`、
  `Support/RequestGate.swift`、`Support/LocalizedText.swift`、
  `Localization/L10n.swift`、`Localization/LanguageStore.swift`、
  `Workspace/WorkspaceIntent.swift`、`Workspace/SessionWorkspace.swift`、
  `Workspace/SessionStore.swift`、`Shell/RootShellDependencies.swift`。
- 不同步任何调用点；不删任何旧类型。
- 新增测试：`RequestGateTests`（交错起代只认末代、cancel 不落 failed）、
  `ViewStateTests`、`CommandErrorTests`（`CODE::p1::p2`、`CODE: 散文`、散文回退）、
  `SessionStoreTests`（LRU、pinned 不淘汰、evict、take-and-clear）、
  `LanguageStoreTests`（切换计数、`l10n` 值语义）。

验收：
```bash
cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
cd ../..
./scripts/check-duplicate-symbols.sh   # RequestGate 必须恰好 1 份定义
./scripts/check-cleanup-ratchet.sh     # try? 不得超 242（新代码尽量 0 个 try?）
./scripts/check-layering.sh
```

测试影响：只增不改；既有 461/55 必须原样绿。
风险：新增 public 类型进入 `GatherUI` 公共面（可用 `package` 降到包内）；
`RequestGate` 若被测试 helper 同名定义会触发 duplicate 门禁（脚本已预设）。

#### 4a-1 VM 错误态迁移（3 人日，逐个 VM 合并）

顺序：**Similarity → Culling → Face → Export → Duplicates → Control → Settings**，
再 **Dashboard → Gallery → Library → Persons**（LoadPhase）。
- 每个 VM：`errorMessage: String?` → `CommandError?`；`LoadPhase.failed(String)`
  → `ViewState.failed(CommandError)`；删除 VM 内的 `Self.message(for:)` 调用
  （改为 `CommandError(error)`）。
- 每个 VM 完成即改它的测试：断言 code，不断言文案。
- View 侧先保留旧渲染（用 `APIErrorPresentation` 适配器把 CommandError 转字符串），
  保证同一 PR 可编译；下个 PR 再换 `GatherErrorBanner`。

验收：`grep -rn 'var errorMessage' Sources/GatherUI` = 0；
`grep -rn 'LoadPhase.failed' ...` = 0；`swift test`；ratchet 不升。

测试影响：**60 处** errorMessage 断言；`APIErrorPresentationTests` 需保留
（适配器语义不变）；`ErrorLocalizationCoverageTests` 仍应过（错误码表未动）。
风险：`CommandError.init` 的散文回退若与旧 `errorText` 不一致，会出现
“未知错误”泛化（旧行为对未知码回退通用文案，需逐条对齐）。

#### 4a-2 Workspace/Store 接线（3 人日）

- RootView 删除 `SessionDraftCache`、`syncViewModels`、`faceKwInitialRole`、
  `pendingGalleryPhoto*`（迁到 intent）、`refreshWindowTitle` 的同步查库。
- `SessionTabHost` 从 environment 取 workspace；页面 init 不再传 VM。
- 删除 8 套可见性机制，统一 `workspace.setVisible`。
- **暂不删** `.id(languageVersion)`（留到 4a-3，等所有 VM 的错误态与文案都改成渲染期解析）。
- 保留 `RootNavigation`（只删 2 个 photo 字段与 `lastSessionId` 迁出）。

验收：
```bash
grep -rn 'SessionDraftCache\|draftCache' Sources            # 0
grep -rn 'pendingGalleryPhoto\|pendingExportIntent\|pendingFaceAnalyze\|pendingCullingConflicts\|pendingGalleryFilter' Sources  # 0
grep -rn 'isActive' Sources/GatherUI | grep -v filterState   # 0（除 capsule 内部可保留）
grep -rn '\.id(languageVersion)' Sources                    # 0
swift test --no-parallel
```

测试影响：`ReviewFixTests:408-421` 重写为 intent 断言；`LayoutBudgetTests:282-283`
删 `isActive:` 参数；`RootViewTests` 若 RootNavigation 搬家需改 import
（测试已同时 import GatherUI/Host，影响小）。
风险（P0）：可见性门控缺失 → 隐藏页继续 3s/1s 轮询；`SessionControlView` 的
`while` 若留在 View 会随 workspace 常驻而永久运行。必须为每个 VM 写
“setVisible(false) 后轮询停止”的单测（fake API 计数）。

#### 4a-3 LanguageStore 接线（1.5 人日）

- `GatherApp` 两处 `.environment(languageStore)`（WindowGroup + Settings）。
- `SettingsViewModel.setLanguage` 改为调 `languageStore.set`（持久化仍在 API）；
  删除 4 个重复写点，只保留 `LiveSettingsAPI` 的持久化 + `LanguageStore` 的广播。
- `RootView` 删除 `languageVersion` 与 `.id(languageVersion)`（**本步才删**）；
  `GatherApp.commandsLanguageVersion` 保留（菜单无 Observation）。
- `GatherLocalization.l` 暂时保留（4b 才清），但 `L10n` 已可用。

验收：新增 `RootShellTests`：切语言后 `RootView` 的 destination 与
`ObjectIdentifier(workspace)` 不变；`swift test`。
风险：Settings 场景不在 RootView 的 `.id` 内，切语言本来就靠 Observation；
删 `.id` 后必须确认 Settings/菜单/Toast 三处仍刷新（Toast 中心是全局，
需要在 show 时取 `l10n`，不能缓存字符串）。

#### 4a 总验收

```bash
cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
cd ../..
for f in check-layering check-duplicate-symbols check-cleanup-ratchet check-test-catalog check-no-legacy; do ./scripts/$f.sh; done
```

### 7.2 4b：l10n codemod（约 6-8 人日）

#### 4b-1 表修复（1 人日，先做）

- 去重 11 个键、裁决 3 个冲突译文（`星级` 等）。
- 补 6 个缺失键。
- 把 2 处硬编码中文日期格式（`PersonsView.swift:479`、`DateFormatting.swift:60`）
  从“系统语言”改判 `l10n.language`。
- 新增 `LocalizationParityTests`：代码 key 集合 ⊆ en 键集合；无重复键；
  每个 key 的 `%@/%lld/%%` 占位符数量一致。

#### 4b-2 分页迁移（每页 0.5-1 人日）

顺序（按调用量）：Culling(265) → Face(183) → Similarity(143+39) →
Library(121+6) → Control(117) → Dashboard(114+23) → Settings(108) →
Export(98) → Gallery(85+8) → Duplicates(80) → Persons(56) → Support(41) →
Host 菜单例外(67) → App(4)。

每页规则：
1. 动态 key 先手工；
2. `String(format: l(...))` → `l10n.format(...)`；
3. 裸 `l(...)` → `l10n(...)`；
4. `errorText/jobErrorMessage/...` 手工；
5. `+ / +=` 拼接合成单模板；
6. 编译 + 该页测试 + 计数递减。

#### 4b-3 Host/菜单/启动兜底（1 人日）

- `GatherAppDelegate`（49 处）与 `GatherAppCommands`（5 处）保留
  `GatherLocalization`（设计允许），但改成 `GatherLocalization.l` 唯一入口，
  不再直接读 `appLanguage`。
- `AppBootstrap` 失败文案（:74）改为 `CommandError` + `l10n`（启动早期无
  Environment，可在 Scene 层转换）。
- `RootView` 的 10 处随 4b 一起转 `l10n`。

#### 4b 验收

```bash
grep -rn 'GatherLocalization\.l(' Sources/GatherUI | wc -l          # 0
grep -rn 'GatherLocalization\.l(' Sources/GatherHost | wc -l        # 仅菜单/Delegate 允许，写入 allowlist
grep -rn 'String(format:.*GatherLocalization' Sources | wc -l       # 0
swift test --no-parallel
./scripts/check-docs.sh --strict
```

测试影响：所有中文文案断言（AppLanguageLock 包裹的那些）需改为
`l10n` 同源查询或 code 断言；`ErrorLocalizationCoverageTests` 必须仍全绿
（177 个错误码的覆盖不变）。
风险：
1. 漏改一处 → 切语言后该处**不刷新**（因为不再有 `.id` 重建）；
2. `String(format:)` 参数类型错配 → 运行时崩溃；
3. 145 个 `%lld` 的英文单复数问题被“迁移”放大成可见缺陷；
4. 15 个动态 key/静态表若改成闭包，`SettingsCatalogTests` 与 5 个调用点要同步改。

### 7.3 4c：View 拆分 + Preview（约 8-10 人日）

#### 4c-1 叶子 View 抽取（3 人日）

- 先抽 §5 表中的 Cell/Row/Card/面板（不动 body）。
- 每抽一个文件，`swift build`；不新增行为。

#### 4c-2 巨型 body 拆分（4 人日）

- Culling（9 文件）→ Face（6）→ Gallery（5）→ Settings（8）→ Control（6）→
  Export（7）→ Duplicates（3）→ Similarity（4）→ Dashboard（3）→ Library（3）→
  RootView（6）。
- 单文件 ≤600 行；CullingView ≤200；RootView ≤300。
- `swift build` 的 type-check 时间应下降（拆分后单表达式复杂度降低）。

#### 4c-3 Preview（2-3 人日）

- 先做 §6.2 的 PreviewSupport（约 600-900 行）。
- 再做 §6.3 的 14 个 `#Preview`，每个都能独立编译。
- 加 `scripts/check-preview-surface.sh`（设计 §7.3 承诺但**当前不存在**）：
  `grep -c '#Preview'` ≥12，且 Preview 目录只允许 `#if DEBUG`。

#### 4c 验收

```bash
for f in Culling/CullingView FaceKeywording/FaceKeywordingView Settings/SettingsView \
         Gallery/GalleryView ControlCenter/SessionControlView Export/ExportView; do
  echo "$f $(wc -l < Sources/GatherUI/$f.swift)"
done
grep -rn '#Preview' Sources/GatherUI | wc -l        # ≥12
swift test --no-parallel
./scripts/check-layering.sh
```

测试影响：`LayoutBudgetTests` 直接构造 4 个页面（:266-284、:299-326），
拆分后 init 签名若变（去 `isActive`/改 environment）需同步；该测试是**唯一**
能拦住“最小宽度回归”的自动化，必须保留并补 Culling/Face/Export 的最小宽度用例。
风险：
1. SwiftUI 视图身份变化 → `@State` 重置（尤其 CullingViewer 的缩放、
   Gallery 的 layoutCache、Lightbox index）；
2. `private` 类型跨文件后需改 `fileprivate/internal`，可能扩大 API 面；
3. 大文件拆分产生巨型 diff，与 4a/4b 并行必冲突；
4. Preview 的 stub 若漏 `#if DEBUG`，会进 release 包；
5. 无 GUI 自动化，拆分后的视觉回归**只能人工验收**（必须写进交付说明，
   不得声称已验收）。

### 7.4 汇总：Cut 4 验收清单

| # | 指标 | 命令 | 目标 |
| --- | --- | --- | --- |
| 1 | 存储型 errorMessage | `grep -rn 'var errorMessage' Sources/GatherUI` | 0 |
| 2 | isActive | `grep -rn 'isActive' Sources/GatherUI \| grep -v filterState` | 0（胶囊内部可留） |
| 3 | draftCache | `grep -rn 'SessionDraftCache\|draftCache' Sources` | 0 |
| 4 | .id(languageVersion) | `grep -rn '\.id(languageVersion)' Sources` | 0 |
| 5 | 旧 l() | `grep -rn 'GatherLocalization\.l(' Sources/GatherUI` | 0 |
| 6 | Preview | `grep -rn '#Preview' Sources/GatherUI \| wc -l` | ≥12 |
| 7 | RootView 行数 | `wc -l RootView.swift` | ≤300 |
| 8 | 单文件行数 | `find Sources/GatherUI -name '*.swift' \| xargs wc -l` | ≤600（CullingView ≤200） |
| 9 | 测试 | app `swift test --no-parallel`、core `swift test` | 全绿 |
| 10 | 门禁 | layering / duplicate / ratchet / test-catalog / no-legacy / docs --strict | 全绿 |

### 7.5 需要回写设计/决策文档的偏差

1. l10n 基数 1,439 → **1,481**（代码 `l()`）；代码引用 1,532（含 1 处注释共 1,533）。
2. “6 个 VM 有 errorMessage” → **7 个**；另有 4 个 `LoadPhase.failed(String)`。
3. “4 个 pending 容器” → 4 个容器 + `faceKwInitialRole` + 2 个 photo 字段 = **7 个一次性状态**。
4. Workspace 的 VM 清单需加 **control/gallery/similarity**（否则状态层只做一半）。
5. `SessionDraftCache` 上限 8 → 设计 capacity 6（需确认内存预算）。
6. 设计承诺的 `check-l10n.sh` / `check-preview-surface.sh` **当前不存在**，
   4b/4c 必须新建；`check-duplicate-symbols.sh` 已预留 RequestGate 规则（可直接用）。
7. `RootView` 迁 UI（D-017）需要新增 `RootShellDependencies`（§4.6），
   并在 `AppBootstrap.SceneState` 增加组装入口（现有 SceneState 已有
   `captureOneBridge`，可直接复用，消除 RootView 自建桥）。

---

## 8. 附录：证据与未验证项

### 8.1 关键证据索引（file:line）

- isActive：`CullingView.swift:147/262/271/374/380/1557/1562`、
  `GalleryView.swift:59/83/93/171/183/222/276/496`、
  `SimilarityView.swift:95/116/125/213`、`LibraryView.swift:22/30/35/89/118`、
  `PersonsView.swift:25/34/41/81/82/91`、
  `C1StatusCapsule.swift:143/151/157/165/170/180`、`RootView.swift:637/658/688/707`。
- SessionDraftCache：`RootView.swift:293-340`（声明）、`:379`（@State）、
  `:515`（prune）、`:679-681/735-808/814-841/893-940`（读写）。
- .id(languageVersion)：`RootView.swift:371/443/455`；另一处 `.id` 是
  `RootView.swift:716`（session-tab 重建守卫）。
- stored errorMessage：`CullingView.swift:133`、`FaceKeywordingView.swift:100`、
  `ExportView.swift:41`、`DuplicatesView.swift:121`、
  `SessionControlView.swift:34`、`SimilarityViewModel.swift:130`、
  `SettingsView.swift:117`。
- l10n 核心：`GatherLocalization.swift:251-293`（errorText/`{{param}}` 插值）、
  `:298-303`（`l()` 回退语义）、`:340-403`（job/status/progress 表）、
  `:411-438`（appLanguage/appLocale）。
- 静态中文表：`SettingsView.swift:36-100`（SettingField/Group/Slider），
  `:769-798` 等 `zhLabel/zhDesc`。
- 同步查库标题：`RootView.swift:987-994`。
- 双 C1 桥：`RootView.swift:430-434` vs `AppBootstrap.swift:37`。

### 8.2 未验证 / 需人工

- 未构建、未跑测试：所有编译期结论来自静态阅读；`#Preview` 宏在 SwiftPM
  库 target 的可用性需 4c-3 首次落地时验证。
- 未做 GUI/Preview 目视：拆分后的布局、切语言后的实际刷新、轮询是否真的停止，
  需人工冒烟（不得声称已完成）。
- “`SessionControlViewModel` 每次重建导致状态丢失”是静态结论
  （`SessionControlView.swift:359-365`），未用运行态复现。
- `isActive` 在 SwiftUI 条件构建下 `onDisappear` 是否触发，代码注释
  （`RootView.swift:524-526`、`GalleryView.swift:177-179`）与常见行为不一致；
  本审计只记录“多套机制并存”，不裁决运行时真相，4a 应以 `setVisible` 单点
  驱动并加单测，不再依赖 `onDisappear`。
- `SettingsView` 76 行中文静态表是否在 en 界面全部可见，未逐屏核对（静态推断
  为“是”，因为 `l()` 未包裹）。
