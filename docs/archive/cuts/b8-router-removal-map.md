# B8 前置审计：Router 删除映射（只读）

> 审计时间：2026-10-22 01:06 +08:00（Asia/Shanghai）；行号复核：01:12（B6b 仍在改，引用前先 grep）
> 仓库：/Users/panzeyu2013/Desktop/code/develop/Gather
> 基线：工作区未提交（大量 M/?? 文件），**不是**干净 HEAD；本文行号以该快照为准。
> 并发提示：B6b 正在收尾，本轮内 `CullingView.swift`(01:05:51)、`LibraryViewModel.swift`(01:05:17)、`ExportView.swift`(01:04:54) 已被改动。执行 B8 前必须用本文的命令重新 grep；文中行号可能已漂移。
> 口径：只读审计；未改源码/测试/Package；未运行 build/test（只运行了只读门禁脚本，结果见 §1.2）。

> **状态（2026-10-22）**：历史执行映射，B8.0–B8.5 已完成。
> `SessionCommandRouter` / `CommandRouter` / `NativeCommandClient` /
> `CommandSurfaceRuntimeTests` / `StubCommandRouter` / `check-command-surface.sh`
> 已删除；文中路径、行号与命令仅用于追溯，勿按本文复现删除动作。

## 0. 结论摘要

| 指标 | 数值 | 证据 |
| --- | --- | --- |
| Router 注册命令 | **118** | `SessionCommandRouter.swift` 118 个 `case "x.y"`；3297 行 |
| **生产 UI/宿主仍在执行的字符串命令** | **15 条 / 19 处** | §2；B6b 已把 export/metadata 字符串入口移出生产 |
| **仅测试/旧构造器适配器** | **45 条** | §3；6 个适配器块（7 个类型） |
| **无调用方（仅黄金清单）** | **58 条** | §4；含 4 条真删除、4 组合并 |
| 引用 Router/Client 类型的源码文件 | 20 个（不含 Router 自身） | §10 复现命令；代码级引用（非注释） |
| 引用 Router 的测试文件 | 19 个（含 `Support/StubCommandRouter.swift`） | 见 §3.4 |
| `C1StatusCapsuleHost(router:)` 调用点 | 7 个页面 | §7 |
| Router 暴露给 AppServices 的依赖 | 22 个（17 个 B1-B7 临时放宽 + 5 个 public） | §6 |
| 无 typed API 的生产/测试命令 | 0（15+45 全部有对应协议方法） | §2/§3 |
| 需 AppServices 增字段 | 2 类：runtime（JobService/生命周期）、sessionRepo/reloadAck | §6.4 |

**一句话**：B8 的“字符串命令”已从 Cut 0 记账的 113 处降到 **19 处 / 15 条**；剩余工作不在协议层，而在 **组合根/运行时（JobService 启动、executor 注册、停机、reload ack）**、**同步 UI/provider 接缝** 和 **以 CommandRouter/JSONValue 为骨架的测试**。Router 文件本身 3297 行、118 个 case，仍必须最后整体删除。

---

## 1. 现状与门禁

### 1.1 Router 结构（当前快照）

| 区段 | 行号 | 说明 |
| --- | --- | --- |
| 24 个依赖字段 | 71-137 | 5 public + 17 internal（B1-B7 临时放宽）+ 2 private |
| `init` | 139-190 | 赋值后 `registerExecutors()` |
| `recordCaptureOneReloadAck` | 194-199 | 用 `SessionRepo(connection: db)` 写 reload ack |
| `prepareForTermination` | 204-208 | `jobService.stop()` → coordinator shutdown → `db.close()` |
| `makeDefault` | 217-418 | 单 DB 构造全部 24 个服务/Repo（含 XMP provider、executor 依赖） |
| `registerExecutors` | 423-698 | 8 个 executor：similarityAnalyze/duplicateScan/faceAnalyze/qualityScore/metadataScan/checksumBackfill/thumbnailBuild/exportExecute（8 个 type） |
| 同步 switch `execute` | 713-1678 | 82 条 |
| 异步 switch `executeAsync` | 1680-2578 附近 | 36 条，未特化命令回落 `execute` |
| 命令 case 行 | 717-2570 | 118 条，无重复 |

### 1.2 门禁现状（只读执行）

```text
$ ./scripts/check-command-surface.sh        # exit 1
命令面：注册 118 个 case 标签 / 118 个唯一命令；UI 字面量提到 118 个
· 无 UI 字面量提及（需裁决：死命令 or 变量拼接）：0 个
· 异步注册 36 条 / UI 同步 execute 调用 42 条
✗ UI 用同步 execute 调用仅在 async 注册的命令（会 NOT_IMPLEMENTED）：
    navigation.analyze
· 确认载荷硬编码处数：10 / confirmed: true 实参处数：68
```

两个**不能当 B8 验收信号**的事实（已确认）：

1. **自计数假信号**：`UI_DIRS` 包含 `Sources/GatherApp`，而 `SessionCommandRouter.swift` 就在其中；118 个 `case` 标签被当成“UI 字面量”，所以“UI 提到 118 / uncalled 0”没有意义。
2. **现有失败**：`RouterNavigationAPI.analyze` 用同步 `client.execute("navigation.analyze")`（CullingView.swift:1635），而该命令只在 async switch 注册；脚本报的 `navigation.analyze` 是真问题（测试适配器路径），不是误报。B8 删除适配器后该失败自然消失，但**在删除前不要用它做“必须绿”的门禁**。

```text
$ ./scripts/check-no-legacy.sh              # exit 0
meter[tracked ] SessionCommandRouter (R5)   32 file(s)
meter[tracked ] StubCommandRouter (R5)      14 file(s)
```

B8 应把这两条 tracked meter 改为 enforced 0（见 §8.4）。

---

## 2. 生产 UI/宿主仍在执行的字符串命令（15 条 / 19 处）

> “生产”判定：该调用位于 `GatherApp`/RootView 实际装配的代码路径，或页面在正常启动后必定执行的 load/refresh 路径；不含只有 `settingsAPI == nil` 或 `router:` 旧构造器才会进入的兼容分支（后者见 §3/§7）。

| # | 命令 | 域 | 文件:行 | 形式 | 对应 typed API | 旧构造器/适配器 | 迁移注意 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | session.get | session | Export/ExportView.swift:140 | execute | `SessionAPI.get` | `ExportViewModel(sessionId:export:router:)`(:75) 的 `NativeCommandClient` | `loadSessionName()` 是同步方法；typed 只有 async。改成 async 或在 view `.task` 调用 |
| 2 | session.get | session | ControlCenter/SessionControlView.swift:62 | execute | `SessionAPI.get` | `SessionControlViewModel(router:)`(:46) | `load()` 同步；需 async 化 |
| 3 | session.list | session | Settings/SettingsView.swift:630 | execute | `SessionAPI.list` | `SettingsViewModel(router:)`(:148/154) 的 `client` | `refreshSyncState()` 同步；需 async 化 |
| 4 | settings.get | settings | Sources/GatherApp/Gallery/GalleryViewModel.swift:197 | execute | `SettingsAPI.get` | `LiveGalleryDataProvider(router:)`(:131) | `thumbnailSize()` 同步；`performLoad()` 已 async，可改 async |
| 5 | settings.set | settings | Sources/GatherApp/GatherApp.swift:279 | execute | `SettingsAPI.set` | `GatherApp.prepareNativeEmbeddingRerun(router:)`(:272) | bootstrap 同步；改成 async 或直接 `SettingsService` 只此一处 |
| 6 | workspace.status | session(workspace) | Gallery/GalleryViewModel.swift:213 | executeAsync | `SessionAPI.status` | `LiveGalleryDataProvider(router:)` | 已是 async，直接替换 |
| 7 | workspace.status | session(workspace) | ControlCenter/SessionControlView.swift:65 | execute | `SessionAPI.status` | `SessionControlViewModel(router:)` | 与 #2 同一次 `load()` |
| 8 | culling.sync_status | culling | Sources/GatherApp/Support/C1StatusCapsule.swift:101 | execute | `CullingAPI.syncStatus` → `CullingSyncStatus` | `C1StatusService.setRouter`(:64) / `C1StatusCapsuleHost(router:)`(:123) | `refresh(sessionId:)` 已 async；7 个页面宿主都要传 `culling` |
| 9 | culling.sync_status | culling | Settings/SettingsView.swift:640 | execute | `CullingAPI.syncStatus` | SettingsViewModel 的 `client`（本页没有胶囊宿主） | 与 #3 同一 `refreshSyncState()` |
| 10 | culling.sync_status | culling | ControlCenter/SessionControlView.swift:68 | execute | `CullingAPI.syncStatus` | `SessionControlViewModel(router:)` | 与 #2/#7 同一次 load |
| 11 | jobs.list | jobs | Culling/CullingView.swift:397 | execute | `JobAPI.list` | `CullingViewModel` 的 `commandClient`(:185) | 500ms 轮询内同步调用；`LiveJobAPI.listSync` 存在，但协议只有 async |
| 12 | jobs.cancel | jobs | Culling/CullingView.swift:426 | execute | `JobAPI.cancel` | 同上 | `cancelQualityAnalysis()` 同步；改 async 或 Task |
| 13 | index.scan | jobs | Gallery/GalleryViewModel.swift:221 | executeAsync | `JobAPI.start(JobCreateParams(type:.metadataScan, ...))` | `LiveGalleryDataProvider(router:)` | **无专用 typed 方法**；必须复制 `dedupeKey:"metadata.scan:<id>"` 与 checkpoint 语义（Router:2116-2121） |
| 14 | quality.analyze | quality | Culling/CullingView.swift:384 | executeAsync | `QualityAPI.analyze` | `CullingViewModel` 的 `commandClient` | 返回 `AnalysisJobData`；`analyzeQuality()` 已是 async |
| 15 | person.list | person | Sources/GatherApp/Persons/PersonsViewModel.swift:24 | execute | `PersonAPI.list` | `LivePersonsDataProvider(router:)`(:16) | `PersonsDataProvider` 是同步协议；需 async 化或加 sync 核心 |
| 16 | person.get | person | Persons/PersonsViewModel.swift:28 | execute | `PersonAPI.get` | 同上 | 同上 |
| 17 | person.create | person | Persons/PersonsViewModel.swift:32 | execute | `PersonAPI.create` | 同上 | 同上；空响应 `PERSON_CREATE_EMPTY_RESPONSE` 需保留 |
| 18 | person.update | person | Persons/PersonsViewModel.swift:40 | execute | `PersonAPI.update` | 同上 | 同上 |
| 19 | person.delete | person | Persons/PersonsViewModel.swift:48 | execute | `PersonAPI.delete(Confirmed<PersonDeleteInput>)` | 同上 | 同步 `confirmed: Bool` 需在确认分支构造 `Confirmed` |

**15 条命令**：session.get/list、settings.get/set、workspace.status、culling.sync_status、jobs.list/cancel、index.scan、quality.analyze、person.list/get/create/update/delete。

**19 处分布**：Export 1、ControlCenter 3、Settings 2、Gallery 3、GatherApp 1、C1StatusCapsule 1、Culling 3、Persons 5。

> B6b 边界：`export.preview/execute/cancel/report` 与 `metadata.orphans/resolve_orphan/conflicts/resolve_conflict` 的字符串入口已从生产路径移除（ExportView 已用 `exportAPI`；Culling 已用 `metadataAPI`；Library 已用 `metadataAPI`）。它们现在属于 §4 的“无调用方”，不是生产项。

---

## 3. 仅测试/旧构造器适配器（45 条）

### 3.1 适配器块

| 适配器 | 文件:行范围 | 覆盖命令（文件内行号） | 使用方 | 替代 |
| --- | --- | --- | --- | --- |
| `RouterCullingAPI` | Culling/CullingView.swift:1461-1600 | culling.list_page:1483、history:1487、apply_history:1494、update:1503、batch_update:1512、decide_group:1520、groups:1528、summary:1533、reset:1553、writeback:1558、flush:1566、retry_sync:1571、retry_failed_writeback:1576、cleanup:1583、finalize_sync:1590、confirm_sync:1597（16 条；sync_status:1539 归生产 #8） | `CullingViewModel(sessionId:router:)`:191；LayoutBudgetTests:48/139/289、CullingSyncFlowTests:105 | `StubCullingAPI`（CullingViewModelAPITests 已有）+ `LiveCullingAPI` |
| `RouterNavigationAPI` | Culling/CullingView.swift:1603-1638 | navigation.list:1611、split:1616、merge:1624、analyze:1635 | 同上（legacy init；APITests 用 StubNavigationAPI） | `StubNavigationAPI`（CullingViewModelAPITests 已有）+ `LiveNavigationAPI` |
| `RouterMetadataAPI` | Culling/CullingView.swift:1646-1700 | metadata.conflicts:1654、resolve_conflict:1666（其余 5 方法 throw `METADATA_LEGACY_INIT_UNSUPPORTED`） | 同上（legacy init；APITests 用 B6bMetadataAPIStub） | `StubMetadataAPI` + `LiveMetadataAPI` |
| `RouterFaceAPI` | FaceKeywording/FaceKeywordingView.swift:2223-2346 | fkw.clusters:2333、bind:2237、merge:2246、remove_member:2254、analyze:2267、recluster:2275、cancel_analysis:2279、unbind:2285、preview:2298、writeback:2304、confirm_sync:2313、cleanup:2319；face.models_status:2344（13 条） | `FaceKeywordingViewModel(sessionId:router:)`:180；FaceKeywordingViewModelTests:13/176/185/203/218/232/240/292/309/334/350、FaceReclusterConfirmTests:34、ReviewFixTests:608、LayoutBudgetTests:181/204 | `StubFaceAPI` + `LiveFaceAPI` |
| `RouterFaceJobAPI` | FaceKeywording/FaceKeywordingView.swift:2349-2384 | jobs.list:2357（该命令本身是生产 #11，适配器只服务旧构造器） | 同上 | `B5bJobAPIStub` / `LiveJobAPI` |
| `LegacySimilarityAPIAdapter` | Sources/GatherApp/Similarity/SimilarityViewModel.swift:1153-1231 | sim.result:88、analyze:109、cancel_analysis:120、recluster:131、preview_writeback:167、writeback:186、retry_failed_writeback:199、confirm_sync:217、cleanup:229、writeback_items:245（10 条） | `SimilarityViewModel(sessionId:provider:)`:430-445；SimilarityViewModelTests:288/654/666/682、LayoutBudgetTests:237 | `LiveSimilarityAPI` + `B5bJobAPIStub` |
| `LegacySimilarityJobAPI` | SimilarityViewModel.swift:1234-1265 | 无命令（只实现 `list`，委托 provider） | 同上 | `B5bJobAPIStub` / `LiveJobAPI` |
| `LiveSimilarityDataProvider` | SimilarityViewModel.swift:80-248 | 上述 sim 10 条命令的宿主；**生产 `GatherApp.swift:222` 构造但 RootView 从未读取 `similarityProvider`**（只声明/赋值，grep 无第二处使用） | GatherApp:222（死路径）、Similarity tests、LayoutBudget:237 | 删除；生产已用 `appServices.similarity/job` |
| `LiveLibraryDataProvider.init(router:)` | Library/LibraryViewModel.swift:208-230 | 不自带命令（B2/B6b 已 typed）；只用于测试装配 | LayoutBudgetTests:245、LibraryViewModelTests:202 | 删除 convenience init；测试用显式 Live API |
| `LiveGalleryDataProvider.init(router:)` | Gallery/GalleryViewModel.swift:131-141 | 不自带命令；但 `getSession` 用 `router.sessionService`(:149) | LayoutBudgetTests:233、GalleryViewModelTests:173 | 删除；改显式 `SessionAPI/PhotoAPI` |
| `LivePersonsDataProvider` | Persons/PersonsViewModel.swift:16-53 | person.list/get/create/update/delete（生产 5 条 #15-19） | GatherApp:223（生产）、tests 用 stub provider | 改 `LivePersonAPI` + async provider；这是 UI 迁移项，不在“测试适配器”步 |
| `LiveDashboardDataProvider(sessionService:...)` | Dashboard/DashboardViewModel.swift:92-104 | 无命令；旧 services 构造器仅测试 | DashboardViewModelTests.makeLiveProvider | 删除（D-039 已记录 B8 删除） |
| `CaptureOneBridge(router:)` | Host/CaptureOneBridge.swift:111-116 | 无命令；只把 `recordCaptureOneReloadAck` 包成闭包 | 生产 7 处：GatherApp:224、RootView:414/754/951、Culling:186、Settings:156、Face legacy:190；测试 LayoutBudget:243 | 改为 `CaptureOneBridge(recordReloadAck:)`；由组合根注入 `SessionRepo(connection: db)` 闭包 |
| `C1StatusCapsuleHost(router:)` | Support/C1StatusCapsule.swift:123-156 | culling.sync_status（生产 #8-10） | 7 页面：Duplicates:577、Export:805、Similarity:189、Gallery:272、Face:1256、Culling:1894、ControlCenter:467 | `C1StatusCapsuleHost(sessionId:culling:onOpenSettings:)`；`C1StatusService.setCullingAPI` |
| `C1StatusService.setRouter` | Support/C1StatusCapsule.swift:64-67 | 无命令（只创建 client） | Host:132 | 同上；单例只注入一次 |
| `AppServices.live(router:)` 重载 | Host/APIs/AppServices.swift:101/111/122/140/162/190 | 无命令；组合缝 | GatherApp:186（十域入口） | 收敛为 `live(core:)`（§8.3） |

### 3.2 测试文件清单（19 个）

| 文件 | 关键行 | 现状 | B8 处理 |
| --- | --- | --- | --- |
| `CommandSurfaceRuntimeTests.swift` | 全文件 295 行 | 118 条黄金清单 + NOT_IMPLEMENTED 断言 | **整文件删除** |
| `NativeCommandClientTests.swift` | 全文件 223 行 | JSON envelope / message 漏斗 | 删除；错误漏斗测试迁到 `APIErrorPresentation` |
| `Support/StubCommandRouter.swift` | 1-38 | `responses:[String:JSONValue]` + executed 记录 | 删除；用 typed stubs |
| `FaceKeywordingViewModelTests.swift` | 13、171、187、198、217、231、239、329、345、367、400 | 12 处 Router/Recording/Failing | 改 `StubFaceAPI` + spy；同步 `load()` 假设改 await |
| `LayoutBudgetTests.swift` | 48/50、131、139、177、181/196、204、231、235/239/245/246、291 | 页面用 router 构造；4 个 live provider | 改为 typed stubs + `AppServices` 测试装配 |
| `ReviewFixTests.swift` | 44、143、336、365、377、406、608 | SessionControl/Export/Face | 改 typed stubs；`syncStatusText` 抽纯函数 |
| `CullingSyncFlowTests.swift` | 105 | `CullingViewModel(sessionId:router:)` | 改三 API 构造 |
| `CullingViewModelAPITests.swift` | 267、287+、315+、350+、397+、434+、480+、503+、527+、546+ | 已用 typed API，但仍塞 `router: makeRouter()` 给 metadata/quality/jobs | 删 router 参数；`metadata.conflicts` stub 改 typed |
| `SettingsSaveSemanticsTests.swift` | 17-20、32、50、77、96、128、159 | `SettingsViewModel(router:)` + `executed` | 改 `SettingsAPI` spy；断言 `SettingsSetInput` |
| `SimilarityViewModelTests.swift` | 288、293-299、654、666、682 | `LiveSimilarityDataProvider` + `makeDefault` | 改 `LiveSimilarityAPI` + `B5bJobAPIStub` |
| `LibraryViewModelTests.swift` | 223-225、615/645/670/686 | `LiveLibraryDataProvider(router:)` | 改显式 `Session/Photo/Asset/Album/Metadata` API |
| `GalleryViewModelTests.swift` | 171-173、587-592、604/635/663 | `LiveGalleryDataProvider(router:)` | 改显式 `Photo/Session/Settings/Job` API |
| `GatherAppDelegateTests.swift` | 88、103 | `SessionCommandRouter.makeDefault` + 同步 `importFiles` | 改 `AppComposition` + async import |
| `DuplicatesControlCenterAPITests.swift` | 66-71、137、207、339、351 | SessionControl 用 router | 改 `SessionAPI/Workspace/Culling` stubs |
| `InboxItemsTests.swift` | 48 | RootView/VM 装配 | 改 typed 装配 |
| `IndexHeaderCopyTests.swift` | 50 | 同上 | 同上 |
| `WorkspaceStageMarksTests.swift` | 20 | 同上 | 同上 |
| `FaceReclusterConfirmTests.swift` | 31-34 | Face router | 改 `StubFaceAPI` |
| `APIFaceUITests.swift` | 287-291 | `CaptureOneBridge()` + Face VM | 保持；删 legacy 相关注释 |

> 另有 `DashboardViewModelTests.swift:151` 的 `LiveDashboardDataProvider(sessionService:workspaceStatusService:jobService:)` 不引用 Router，但属于同一批“B8 删除的旧 services 构造器”；同步改 typed Live API。

### 3.3 测试命令的 typed 映射（按域，逐条对应）

| 域 | 命令 → typed API（括号内为适配器文件:行） |
| --- | --- |
| culling（16） | list_page→`CullingAPI.page`(1483)、history→`history`(1487)、apply_history→`applyHistory`(1494)、update→`update`(1503)、batch_update→`batchUpdate`(1512)、decide_group→`decideGroup`(1520)、groups→`groups`(1528)、summary→`summary`(1533)、reset→`reset`(1553)、writeback→`writeback`(1558)、flush→`flush`(1566)、retry_sync→`retrySync`(1571)、retry_failed_writeback→`retryFailedWriteback`(1576)、cleanup→`cleanup`(1583)、finalize_sync→`finalizeSync`(1590)、confirm_sync→`confirmSync`(1597) |
| navigation（4） | list→`NavigationAPI.list`(1611)、split→`split`(1616)、merge→`merge`(1624)、analyze→`analyze`(1635) |
| metadata（2） | conflicts→`MetadataAPI.conflicts`(1654)、resolve_conflict→`resolveConflict`(1666) |
| fkw/face（13） | clusters→`FaceAPI.clusters`(2333)、bind→`bind`(2237)、merge→`merge`(2246)、remove_member→`removeMember`(2254)、analyze→`analyze`(2267)、recluster→`recluster`(2275)、cancel_analysis→`cancelAnalysis`(2279)、unbind→`unbind`(2285)、preview→`preview`(2298)、writeback→`writeback`(2304)、confirm_sync→`confirmSync`(2313)、cleanup→`cleanup`(2319)、face.models_status→`modelsStatus`(2344) |
| sim（10） | result→`SimilarityAPI.result`(88)、analyze→`analyze`(109)、cancel_analysis→`cancelAnalysis`(120)、recluster→`recluster`(131)、preview_writeback→`previewWriteback`(167)、writeback→`writeback`(186)、retry_failed_writeback→`retryFailedWriteback`(199)、confirm_sync→`confirmSync`(217)、cleanup→`cleanup`(229)、writeback_items→`writebackItems`(245) |

> 全部 45 条均有协议方法；无“无 typed API 的测试命令”。括号行号是适配器内执行点（同一文件），不是 Router case 行。

---

## 4. 无调用方（58 条，仅黄金清单/已删行为）

> 判定：`grep` 在 Sources/UI/Tests（除 `CommandSurfaceRuntimeTests` 黄金清单）中无任何 `execute("x.y")` 调用；其中 4 条按 R1-R4 **真删除**，5 条按 M1-M4 **合并**，其余已有 typed 方法但字符串入口已死。

| 域 | 命令（58） | 说明 |
| --- | --- | --- |
| session（6） | create、create_from_directory、delete、delete_many、update、add_photos | Dashboard 已走 `SessionAPI`；create_from_directory/delete_many 为 M1/M2 合并 |
| photo（2） | photo.list、photo.list_page | `photo.list` 真删除（R1）；`list_page` 被 `PhotoAPI.page` 取代 |
| filter（3） | filter.photos、filter.photos_global、filter.suggest | M3 合并到 `PhotoAPI.search`；suggest 有方法无 UI |
| image（4） | prioritize_thumbnail、preload_thumbnails、preload_previews、get_dimensions | `PhotoAPI` 四个方法；无 UI 调用 |
| culling（2） | culling.decide、culling.batch_decide | 真删除（R2/R3），行为由 update/batchUpdate 覆盖 |
| fkw（1） | fkw.confirm_cleanup | M4 合并到 `FaceAPI.cleanup` |
| duplicate（4） | dup.scan、dup.groups、dup.resolve、dup.resolve_member | 生产已走 `DuplicateAPI`；字符串入口仅黄金清单 |
| export（4） | export.preview、export.execute、export.cancel、export.report | **B6b 已迁 typed**；字符串入口无调用方 |
| metadata（5） | get、set、batch_set、orphans、resolve_orphan | get/set/batch_set 无 UI；orphans/resolve_orphan 已由 Library 走 `MetadataAPI` |
| person（3） | person.merge、person.remove_photo、person.search_photos | `PersonAPI` 有方法；UI 未接 |
| album（6） | create、list、get、update、delete、get_photos | 全部 `AlbumAPI`；`album.get` 真删除（R4） |
| jobs（2） | jobs.retry、jobs.clear_completed | UI 已走 `JobAPI`；clear_completed 无 UI |
| assets（5） | candidates、volumes、accept_candidate、reject_candidate、relink_root | 全部 `AssetAPI` |
| template（6） | create、list、get、update、delete、apply | 全部 `TemplateAPI`；0 UI（D-008） |
| quality（1） | quality.get | `QualityAPI.results`；无 UI 读取方 |
| settings（4） | get_all、reset、set_language、get_ml_status | 仅 `SettingsViewModel(router:)` 的兼容分支（生产正常传 `settingsAPI`，不执行）；测试只覆盖 `settings.set` |

**合并/删除记账**：
- 真删除 4：photo.list、culling.decide、culling.batch_decide、album.get。
- 合并 5 条命令：session.create_from_directory→create、session.delete_many→delete、filter.photos/filter.photos_global→search、fkw.confirm_cleanup→cleanup。
- 其余 N 命令都有同名/近似 typed 方法；B8 删除的是字符串入口，不是行为。

---

## 5. 按域汇总（118 = 15 + 45 + 58）

| 域 | 总数 | 生产 | 仅测试/适配器 | 无调用方 | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| session | 8 | 2 | 0 | 6 | list/get 生产；CRUD 字符串无调用 |
| workspace | 1 | 1 | 0 | 0 | `workspace.status` 2 处生产 |
| photo | 2 | 0 | 0 | 2 | list 真删除；list_page 已 typed |
| filter | 3 | 0 | 0 | 3 | M3 合并 |
| image | 4 | 0 | 0 | 4 | 无 UI |
| culling | 19 | 1 | 16 | 2 | sync_status 生产；16 适配器；decide/batch_decide 真删除 |
| fkw/face | 14 | 0 | 13 | 1 | 13 适配器；confirm_cleanup 合并 |
| sim | 10 | 0 | 10 | 0 | LiveSimilarityDataProvider（生产构造但无调用） |
| duplicate | 4 | 0 | 0 | 4 | 已 typed |
| export | 4 | 0 | 0 | 4 | B6b 已 typed，字符串入口死 |
| metadata | 7 | 0 | 2 | 5 | conflicts/resolve_conflict 适配器；其余无调用 |
| person | 8 | 5 | 0 | 3 | 5 条生产；merge/remove/search 无 UI |
| album | 6 | 0 | 0 | 6 | 已 typed；album.get 真删除 |
| navigation | 4 | 0 | 4 | 0 | 适配器 |
| jobs | 5 | 3 | 0 | 2 | list/cancel/index.scan 生产；retry/clear 无 UI |
| settings | 6 | 2 | 0 | 4 | get/set 生产；4 条仅兼容分支 |
| assets | 5 | 0 | 0 | 5 | 已 typed |
| template | 6 | 0 | 0 | 6 | 0 UI |
| quality | 2 | 1 | 0 | 1 | analyze 生产；get 无 UI |
| **合计** | **118** | **15** | **45** | **58** | |

---

## 6. SessionCommandRouter 暴露给 AppServices 的依赖与 B8 删除顺序

### 6.1 22 个被 AppServices 读取的依赖

| # | 字段 | 行 | 访问级 | B 标签 | AppServices 使用 | B8 去向 |
| --- | --- | ---: | --- | --- | --- | --- |
| 1 | sessionService | 71 | public | 3.1 预存 | :203 | core bundle |
| 2 | workspaceStatusService | 72 | public | 3.1 预存 | :204 | core bundle |
| 3 | jobService | 73 | public | 3.1 预存 | :205/207/259/270/280/289/298 | runtime + core bundle |
| 4 | settingsService | 79 | public | B1 | :208/215/260/271 | core bundle |
| 5 | exportService | 136 | public | 预存 | :297 | core bundle |
| 6 | photoRepo | 76 | internal | **B2** | :210 | core bundle |
| 7 | filterEngine | 80 | internal | **B2** | :213/221 | core bundle |
| 8 | navigationService | 81 | internal | **B2** | :223 | core bundle |
| 9 | assetRepo | 92 | internal | **B2** | :211/218 | core bundle |
| 10 | faceKwService | 99 | internal | **B2** | :212/258 | core bundle |
| 11 | smartAlbumRepo | 131 | internal | **B2** | :220 | core bundle |
| 12 | imagePreloadService | 137 | internal | **B2** | :214 | core bundle |
| 13 | db | 97 | internal | **B3** | :250（`SessionRepo(connection:)`） | core bundle 的 db/SessionRepo |
| 14 | cullingService | 135 | internal | **B3** | :249 | core bundle |
| 15 | similarityService | 86 | internal | **B4a** | :268 | core bundle |
| 16 | writebackService | 130 | internal | **B4a** | :269 | core bundle |
| 17 | duplicateService | 91 | internal | **B5a** | :279 | core bundle |
| 18 | qualityService | 114 | internal | **B5a** | :288 | core bundle |
| 19 | metadataService | 120 | internal | **B6a** | :306 | core bundle |
| 20 | metadataSyncCoordinator | 125 | internal | **B6a** | :307 | core bundle |
| 21 | personRepo | 105 | internal | **B7a** | :315 | core bundle |
| 22 | templateService | 109 | internal | **B7a** | :322 | core bundle |

**17 个临时放宽** = #6-12（B2，7 个）+ #13-14（B3，2 个）+ #15-16（B4a，2 个）+ #17-18（B5a，2 个）+ #19-20（B6a，2 个）+ #21-22（B7a，2 个）。

**2 个 private、不暴露**：`indexerService`(:115)、`metadataMutationService`(:126)。B8 必须把它们和 executor 一起搬进组合根，否则 `metadata.scan` 执行器无处注册。

### 6.2 暴露的 public 方法/行为

| 方法 | 行 | 调用方 | 替代 |
| --- | ---: | --- | --- |
| `recordCaptureOneReloadAck(sessionId:)` | 194-199 | `CaptureOneBridge(router:)`:113-115 | `CaptureOneBridge(recordReloadAck:)` + 组合根 `SessionRepo(connection: db)` |
| `prepareForTermination()` | 204-208 | GatherApp:246 | `AppRuntime.shutdown()`（JobService.stop + coordinator.shutdown + db.close） |
| `makeDefault(db:...)` | 217-418 | GatherApp:128；tests 88/173/206/225/231/295 | `AppComposition.make(db:...)` |
| `registerExecutors()` | 423-698 | init:189 | `JobExecutors.register(on:core)` |
| `applyStoredInterfaceLanguage()` | 705-709 | GatherApp:200 | `SettingsAPI.get("ui_language")`（async）或 runtime |
| `execute/executeAsync` | 713/1680 | NativeCommandClient / adapters / tests | 删除 |
| `jobService.start()` / `GatherEventCenter.wire` | GatherApp:201/203 | 宿主 | `AppRuntime.start()`（JobService 由 core bundle 暴露） |

### 6.3 B8 删除顺序（针对上述 accessors）

1. **先切组合缝**：新增 `AppCoreServices`（或 `AppComposition`）持有 24 个服务/Repo + db；`AppServices.live(core:)` 成为唯一装配入口；`AppServices.live(router:)` 六个重载（101/111/122/140/162/190）删除。
2. **B2 组（7）**：`photoRepo/filterEngine/navigationService/assetRepo/faceKwService/smartAlbumRepo/imagePreloadService` 改为 core 字段；`makeCulling/...` 不再从 Router 取。
3. **B3 组（2）**：`db`、`cullingService` 改由 core 构造；`LiveCullingAPI(sessionRepo: SessionRepo(connection: core.db))`。
4. **B4a/B5a/B6a/B7a 组（8 + exportService）**：`similarityService/writebackService/duplicateService/qualityService/metadataService/metadataSyncCoordinator/personRepo/templateService` 改为 core 字段；`exportService` 一并进 core。
5. **收口**：22 个 accessor 先降为 `private`（仅供 Router 自己的 switch/executor），确认无外部引用后随 Router 文件删除；`sessionService/workspaceStatusService/jobService/settingsService/exportService` 不再经 Router 暴露，改由 runtime/core 提供。

### 6.4 需要 AppServices 增字段（阻塞）

| 字段 | 为什么要 | 建议形态 |
| --- | --- | --- |
| `runtime`（或 `jobRuntime`） | AppServices 只有 `any JobAPI`，没有 `JobService.start/stop/registerExecutor`；GatherApp 的 `jobService.start()`、`GatherEventCenter.wire`、`prepareForTermination`、executor 注册都依赖具体 `JobService` | `public let runtime: AppRuntime`（内部持 JobService、MetadataSyncCoordinator、DBConnection，暴露 `start()/shutdown()`） |
| `sessionRepo`（或 `reloadAck` 闭包） | `CaptureOneBridge` 的 `recordReloadAck` 与 `LiveCullingAPI.syncStatus` 的 `reloadAckedAt` 都需要 `SessionRepo`；AppServices 当前只暴露 `any SessionAPI`，没有该读/写面 | `public let sessionRepo: SessionRepo` 或 `recordReloadAck: @Sendable (String) throws -> Void` |

> 不建议把 `db` 直接公开成 AppServices 字段；用 `AppCoreServices` 包住 24 个依赖，AppServices 只拿协议 + runtime + sessionRepo，避免出现第二个 DB 连接/第二份缓存。

---

## 7. 旧构造器/适配器清单（补充）

| 符号 | 文件:行 | 使用方 | 替代方案 | 删除阶段 |
| --- | --- | --- | --- | --- |
| `RouterCullingAPI` | Culling/CullingView.swift:1461-1600 | CullingViewModel legacy init:191；LayoutBudget:48/139/289、CullingSyncFlow:105 | `StubCullingAPI` / `LiveCullingAPI` | B8.1 |
| `RouterNavigationAPI` | CullingView.swift:1603-1638 | 同上 | `StubNavigationAPI` / `LiveNavigationAPI` | B8.1 |
| `RouterMetadataAPI` | CullingView.swift:1646-1699 | 同上 | `StubMetadataAPI` / `LiveMetadataAPI` | B8.1 |
| `RouterFaceAPI` | FaceKeywordingView.swift:2223-2346 | FaceKeywordingViewModel legacy init:180；Face tests/LayoutBudget | `StubFaceAPI` / `LiveFaceAPI` | B8.1 |
| `RouterFaceJobAPI` | FaceKeywordingView.swift:2349-2384 | 同上 | `B5bJobAPIStub` / `LiveJobAPI` | B8.1 |
| `LegacySimilarityAPIAdapter` | SimilarityViewModel.swift:1153-1231 | SimilarityViewModel(provider:):430；tests/LayoutBudget | `LiveSimilarityAPI` + stubs | B8.1 |
| `LegacySimilarityJobAPI` | SimilarityViewModel.swift:1234-1265 | 同上 | `B5bJobAPIStub` / `LiveJobAPI` | B8.1 |
| `LiveSimilarityDataProvider` | SimilarityViewModel.swift:80-248 | GatherApp:222（构造但不用）、tests、LayoutBudget:237 | 删除；生产用 `appServices.similarity/job` | B8.1 |
| `LiveLibraryDataProvider(router:)` | LibraryViewModel.swift:208-230 | tests/LayoutBudget:245 | 显式 Live API 构造 | B8.1 |
| `LiveGalleryDataProvider(router:)` | GalleryViewModel.swift:131-141 | tests/LayoutBudget:233 | 显式 Live API 构造 | B8.1 |
| `LiveDashboardDataProvider(sessionService:...)` | DashboardViewModel.swift:92-104 | tests | 删除 | B8.1 |
| `CullingViewModel(sessionId:router:)` | CullingView.swift:191-199 | tests/LayoutBudget | 三 API 构造 | B8.1 |
| `CullingView(sessionId:router:)` | CullingView.swift:1748-1766 | tests/LayoutBudget | 注入 VM + typed 依赖 | B8.1 |
| `FaceKeywordingViewModel(sessionId:router:)` | FaceKeywordingView.swift:180-194 | tests/LayoutBudget | `FaceAPI + JobAPI + CaptureOneBridge` | B8.1 |
| `SimilarityViewModel(sessionId:provider:)` | SimilarityViewModel.swift:430-445 | tests/LayoutBudget | `SimilarityAPI + JobAPI` | B8.1 |
| `LivePersonsDataProvider` | PersonsViewModel.swift:16-53 | GatherApp:223；tests | `LivePersonAPI` + async provider | B8.2 |
| `CaptureOneBridge(router:)` | CaptureOneBridge.swift:111-116 | 7 生产点 + LayoutBudget:243 | `CaptureOneBridge(recordReloadAck:)` | B8.2 |
| `C1StatusCapsuleHost(router:)` | C1StatusCapsule.swift:123-156 | 7 页面 | `C1StatusCapsuleHost(sessionId:culling:...)` | B8.2 |
| `C1StatusService.setRouter` | C1StatusCapsule.swift:64-67 | Host:132 | `setCullingAPI` | B8.2 |
| `SettingsViewModel(router:)` | SettingsView.swift:148-158 | GatherApp:87 回退、SettingsSaveSemantics:19 | `SettingsViewModel(settingsAPI:)`（去 optional） | B8.2 |
| `SettingsView(router:)` | SettingsView.swift:1248-1257 | GatherApp:87 回退 | 只保留 `(settingsAPI:)` | B8.2 |
| `ExportViewModel(sessionId:export:router:)` | ExportView.swift:75-79 | RootView:732；ReviewFix:336/365/377/406 | 去 router，`session.get` 改 async | B8.2 |
| `ExportView(router:)` | ExportView.swift:661/686 | RootView:914 | 去 router | B8.2 |
| `RootView(router:...)` | RootView.swift:350-420 | GatherApp:37-45 | 去 router；页面只拿 typed API | B8.2 |
| `GatherApp.@State router` | GatherApp.swift:16、128、186-255 | 宿主 | 只保留 `appServices/runtime` | B8.2/8.3 |
| `CommandRouter / WebResponse` | Host/CommandRouter.swift:7-35 | NativeCommandClient/adapters | 删除 | B8.3 |
| `NativeCommandClient` | Support/NativeCommandClient.swift:25-56 | 页面/APIErrorPresentation:372 | 删除；漏斗迁 APIErrorPresentation | B8.3 |
| `StubCommandRouter` | Tests/Support/StubCommandRouter.swift:1-38 | 14 个测试文件 | typed stubs | B8.1 |
| `CommandSurfaceRuntimeTests` | Tests/CommandSurfaceRuntimeTests.swift:1-295 | 黄金清单 | 删除 | B8.1 |

> **provider init 的边界**：`GalleryViewModel(sessionId:provider:)`、`LibraryViewModel(provider:)`、`PersonsViewModel(provider:)`、`SimilarityViewModel(sessionId:provider:)`、`DashboardViewModel(provider:)` 本身是通用测试接缝，不必然删除；B8 要删的是它们的 **Router-backed Live 实现**（`LiveGalleryDataProvider`、`LiveLibraryDataProvider`、`LivePersonsDataProvider`、`LiveSimilarityDataProvider`）以及 `router:` 参数。保留 provider 协议可继续给 ViewModel 单测注入 typed stub，但 provider 内部不得再发字符串命令。

---

## 8. B8 分步删除计划

> 顺序遵循任务要求：**先测试适配器 → 再 UI → 最后 Router/SessionCommandRouter/命令面**。
> 每步都先跑 build/test，再跑 grep 验收；grep 的期望值均是“0”或文中指定值。

### B8.0 基线冻结（0.25 天）

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
date '+%Y-%m-%dT%H:%M:%S%z'
git status --short > /tmp/b8-baseline-status.txt
cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
cd ../gather-core
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
```

**验收**：记录两包 build/test 结果、测试数、`git status`；记录 `./scripts/check-command-surface.sh` 当前 exit 1（navigation.analyze）与 `check-no-legacy.sh` 的 R5 meter。**不要求此步门禁绿**，只要求基线可复现。

### B8.1 删除测试适配器与旧测试接缝（0.5-1 天）

1. 新增 `Tests/GatherAppTests/Support/StubDomainAPIs.swift`：`StubSessionAPI`、`StubCullingAPI`、`StubNavigationAPI`、`StubMetadataAPI`、`StubFaceAPI`、`StubExportAPI`、`StubPersonAPI`、`StubSettingsAPI`、`StubSimilarityAPI`（可复用 `CullingViewModelAPITests` 里已有的 private stub，提升为共享）。
2. 重写 §3.2 的测试文件（19 个；重点 12 个，其余 7 个只改装配）；重点：
   - `FaceKeywordingViewModelTests`：`RecordingCommandRouter`→`FaceAPISpy`；`load()` 改 await；不再断言“命令名”，改断言 API 入参。
   - `LayoutBudgetTests`：`CullingView/FaceKeywordingView/Gallery/Library/Persons/Similarity` 全部改 typed 构造；可用一个 `TestAppServices` 工厂。
   - `ReviewFixTests`：`SessionControlViewModel` 用 `StubSessionAPI/StubWorkspaceStatus`；`syncStatusText` 抽成纯函数，避免为测文案构造整页。
   - `SettingsSaveSemanticsTests`：`SettingsAPI` spy，断言 `SettingsSetInput.key/value`。
3. 删除 7 个适配器类型与旧构造器：
   - `RouterCullingAPI`、`RouterNavigationAPI`、`RouterMetadataAPI`、`CullingViewModel(sessionId:router:)`、`CullingView(sessionId:router:)`；
   - `RouterFaceAPI`、`RouterFaceJobAPI`、`FaceLegacySyncLoading`、`FaceKeywordingViewModel(sessionId:router:)`；
   - `LegacySimilarityAPIAdapter`、`LegacySimilarityJobAPI`、`SimilarityViewModel(sessionId:provider:)`、`LiveSimilarityDataProvider`；
   - `LiveLibraryDataProvider(router:)`、`LiveGalleryDataProvider(router:)`、`LiveDashboardDataProvider(sessionService:...)`。
4. 删除 `CommandSurfaceRuntimeTests.swift`、`NativeCommandClientTests.swift`、`Support/StubCommandRouter.swift`；把错误漏斗断言迁到新的 `APIErrorPresentationTests.swift`（`RouterCommandError` 可保留在 `JSONValueDecoding.swift`，只作为错误载体）。
5. **本步不动**：`ExportViewModel(router:)`、`SettingsViewModel(router:)`、`CullingViewModel` 的 quality/jobs 命令、`LivePersonsDataProvider`、`CaptureOneBridge(router:)`、`C1StatusCapsuleHost(router:)`——它们仍是生产路径。

```bash
cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch   --filter 'Culling|Face|Similarity|Layout|SettingsSave|ReviewFix|Library|Gallery|Persons|Duplicate'
grep -rnE 'RouterCullingAPI|RouterNavigationAPI|RouterMetadataAPI|RouterFaceAPI|RouterFaceJobAPI|LegacySimilarity|FaceLegacySyncLoading|StubCommandRouter' . --include='*.swift' | wc -l   # 期望 0
grep -rn 'SessionCommandRouter.makeDefault' Tests --include='*.swift' | wc -l   # 期望 0（GatherAppDelegate 除外，B8.2 处理）
```

### B8.2 UI 与生产 provider 迁移（1-1.5 天）

按域拆 5 个小步，每步单独 build/test：

**B8.2a session/workspace/settings（5 条命令、7 处）**
- ExportView:140 `session.get` → `SessionAPI.get`；`loadSessionName()` 改 async，调用点放 `.task`。
- SessionControlView:62/65/68 `session.get/workspace.status/culling.sync_status` → `SessionAPI.get/status` + `CullingAPI.syncStatus`；`load()` 改 async。
- SettingsView:630/640 `session.list/culling.sync_status` → `SessionAPI.list` + `CullingAPI.syncStatus`；`refreshSyncState()` 改 async，保留 12s 轮询/事件两条路径。
- GalleryViewModel:197/213 `settings.get/workspace.status` → `SettingsAPI.get` + `SessionAPI.status`；`thumbnailSize()` 改 async（`performLoad` 已 async）。
- GatherApp:279 `settings.set` → `SettingsAPI.set`（bootstrap 内 await）。
- 同时删除 SettingsView 的 `settingsAPI == nil` 兼容分支与 `NativeCommandClient` 字段（4 条 settings N 命令随之消失）。

**B8.2b jobs/index（3 条命令、3 处）**
- Gallery:221 `index.scan` → `JobAPI.start(JobCreateParams(type:.metadataScan, scopeType:"session", scopeId:, dedupeKey:"metadata.scan:\(id)"))`；复制旧 checkpoint/去重语义。
- Culling:397/426 `jobs.list/jobs.cancel` → `JobAPI.list/cancel`；500ms 轮询改 await `jobAPI.list`，取消改 `Task { await jobAPI.cancel(...) }`。
- 注入 `jobAPI/qualityAPI` 到 `CullingViewModel`，删除 `commandClient`。

**B8.2c quality（1 条）**
- Culling:384 `quality.analyze` → `QualityAPI.analyze(QualityAnalyzeInput)`；保留 job 轮询/取消文案。

**B8.2d persons（5 条）**
- `PersonsDataProvider` 改 async（或直接让 VM 持 `any PersonAPI`），`LivePersonsDataProvider` 删除；`person.delete` 的 `confirmed: Bool` 只在确认分支构造 `Confirmed<PersonDeleteInput>`。
- 保留 `PERSON_CREATE_EMPTY_RESPONSE` 的可见错误语义（改用 `GatherError.invalidParameter` 或专用码）。

**B8.2e C1 胶囊 + CaptureOneBridge（culling.sync_status 3 处）**
- `C1StatusService` 改持 `any CullingAPI`；`refresh(sessionId:)` 用 `syncStatus`，把 `CullingSyncStatus.summary/reloadAckedAt` 映射到现有 `SessionState`。
- `C1StatusCapsuleHost` 参数 `router:`→`culling:`；7 个页面从 `appServices.culling` 传入。
- `CaptureOneBridge(router:)`→`CaptureOneBridge(recordReloadAck:)`；组合根用 `SessionRepo(connection: db).setReloadAckedAt(sessionId:iso:)` 构造闭包；更新 7 个生产调用点。
- 删除 `SessionCommandRouter.recordCaptureOneReloadAck`（194-199）。

**B8.2f RootView/GatherApp 收口**
- `RootView(router:)` 删除；页面只接收 `AppServices` 的域协议。
- `GatherApp` 的 `@State router`、`SettingsView(router:)` 回退、`CaptureOneBridge(router:)`、`importFiles(router:)`、`prepareNativeEmbeddingRerun(router:)` 全部改 typed/runtime。
- `importFiles` 改 async（或内部 `Task` + completion），`GatherAppDelegateTests` 同步改 await。

```bash
cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
# 生产 UI 不应再有字符串派发（Router 文件/Client 定义除外）
grep -rnE 'execute(Async)?\( *"(session|settings|workspace|culling|jobs|index|quality|person)\.' \
  Sources/GatherApp Culling Settings Export Duplicates FaceKeywording ControlCenter --include='*.swift' | wc -l   # 期望 0
grep -rn 'NativeCommandClient' Sources/GatherApp Culling Settings Export Duplicates FaceKeywording ControlCenter --include='*.swift' | wc -l   # 期望 0（先迁错误漏斗）
grep -rn 'C1StatusCapsuleHost(.*router:' Sources/GatherApp Culling Settings Export Duplicates FaceKeywording ControlCenter --include='*.swift' | wc -l   # 期望 0
```

### B8.3 组合根/运行时抽取（0.75 天）

1. 新建 `Host/AppComposition.swift`（或 `Host/AppCoreServices.swift`）：
   - 从 `SessionCommandRouter.makeDefault`（217-418）搬出 24 个服务/Repo 的构造；
   - 新增 `AppRuntime`：持 `JobService`、`MetadataSyncCoordinator`、`DBConnection`，提供 `start()`（`jobService.start()` + `GatherEventCenter.wire` + `metadataSyncCoordinator.start(eventSink:)`）与 `shutdown()`（`jobService.stop` + `coordinator.shutdown` + `db.close`）。
2. 把 `registerExecutors`（423-698）搬成 `JobExecutors.register(on:core)`；依赖的 `indexerService/metadataMutationService` 由 core 持有。
3. `AppServices.live(core:)` 替代六个 `live(router:)` 重载；AppServices 增 `runtime` 与 `sessionRepo`（或 `reloadAck` 闭包）字段。
4. `GatherApp.bootstrap` 改为：`AppComposition.make(db:)` → `AppServices.live(core:)` → `runtime.start()`；`onPrepareForTermination` → `runtime.shutdown()`。
5. 删除 `GatherApp.prepareNativeEmbeddingRerun(router:)` 的 `settings.set`，改 `SettingsAPI.set`；`importFiles` 改 `SessionAPI/JobAPI`。

**验收**：
```bash
grep -rn 'live(router:' desktop/native/gather-app --include='*.swift' | wc -l   # 0
grep -rnE 'router\.jobService|router\.prepareForTermination|router\.applyStoredInterfaceLanguage' desktop/native/gather-app --include='*.swift' | wc -l  # 0

cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
cd ../gather-core
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
```

### B8.4 删除 Router/命令面（0.5 天）

1. 删除文件：
   - `Sources/GatherApp/Host/SessionCommandRouter.swift`（3297 行）
   - `Sources/GatherApp/Host/CommandRouter.swift`（51 行）
   - `Sources/GatherApp/Support/NativeCommandClient.swift`（77 行）
   - `Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift`（295 行）
   - `Tests/GatherAppTests/NativeCommandClientTests.swift`（223 行）
   - `Tests/GatherAppTests/Support/StubCommandRouter.swift`（38 行）
   - `scripts/check-command-surface.sh`（109 行）
2. 把 `NativeCommandClient.message/userFacingMessage` 的兜底逻辑（SessionServiceError / BridgeError / RouterCommandError / NSError）迁进 `APIErrorPresentation`（AppServices.swift:367-374 先改，再删文件）；`GatherLocalization.message(for:)` 的 `RouterCommandError` 分支可保留。
3. 更新门禁：`scripts/check-no-legacy.sh:72/74` 的 R5 tracked 改为 enforced 0（或删除这两行）；保留 `SessionCommandRouter` 的“0 file”断言，防止回潮。
4. 清理注释/文档中的 `SessionCommandRouter` 字样（至少 Sources/Tests；docs 可留历史说明）。

**验收**：
```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
test ! -e desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
test ! -e desktop/native/gather-app/Sources/GatherApp/Host/CommandRouter.swift
test ! -e desktop/native/gather-app/Sources/GatherApp/Support/NativeCommandClient.swift
test ! -e desktop/native/gather-app/Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift
test ! -e desktop/native/gather-app/Tests/GatherAppTests/NativeCommandClientTests.swift
test ! -e desktop/native/gather-app/Tests/GatherAppTests/Support/StubCommandRouter.swift
test ! -e scripts/check-command-surface.sh

grep -rnE 'SessionCommandRouter|CommandRouter|NativeCommandClient|WebResponse|StubCommandRouter' \
  desktop/native/gather-app desktop/native/gather-core --include='*.swift' | wc -l   # 期望 0
grep -rn 'execute("' desktop/native/gather-app --include='*.swift' | wc -l            # 期望 0
./scripts/check-no-legacy.sh                                                          # R5 meter 0，exit 0

cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
cd ../gather-core
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
```

### B8.5 收尾（0.25 天）

- 更新 `docs/refactor-progress.md`（Cut 1 行：B8 完成，0 字符串命令）。
- 更新 `docs/cleanup-backlog.md` CL-01/CL-02 的删除行数与符号数。
- 更新 `docs/api-migration-map.md` §5 的“仅测试引用”状态（已被 B8 删除）。
- 人工启动 smoke：新建/导入/索引/挑片/人脸/相似度/导出（**不得**在无 GUI 自动化时声称已验收，只能记为待人工）。

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
./scripts/check-cleanup-ratchet.sh
./scripts/check-layering.sh
./scripts/check-duplicate-symbols.sh
./scripts/check-docs.sh

grep -rn 'execute("' desktop/native/gather-app --include='*.swift' | wc -l   # 0
grep -rnE 'SessionCommandRouter|CommandRouter|NativeCommandClient|WebResponse|StubCommandRouter' \
  desktop/native/gather-app desktop/native/gather-core --include='*.swift' | wc -l   # 0

cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
cd ../gather-core
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
```

---

## 9. 阻塞项（按优先级）

| # | 级别 | 阻塞 | 证据 | 影响/缓解 |
| --- | --- | --- | --- | --- |
| B8-1 | **P0** | **JobService 运行时/组合根仍在 Router** | `makeDefault` 217-418、`registerExecutors` 423-698、`prepareForTermination` 204-208、`jobService.start()`/wire GatherApp:201/203、`db.close` 207 | 不先抽 `AppComposition/AppRuntime`，删 Router 会导致任务不执行、退出不排空、executor 丢失。这是 B8 的头号阻塞，必须先做 B8.3 |
| B8-2 | **P0** | **同步 UI/provider 与 async typed API 的接缝** | `PersonsDataProvider` 同步（PersonsViewModel:24-52）、`GalleryDataProvider.thumbnailSize/workspaceStatus/retryIndex`（GalleryViewModel:197/213/221）、`SessionControlViewModel.load()`（:58-81）、`SettingsViewModel.refreshSyncState()`（:628-652）、`ExportViewModel.loadSessionName()`（:138-142）、`GatherApp.importFiles`（:321-396） | 直接替换会阻塞主线程或编译失败。需要 6 处 async 化，或给 Session/Settings/Person API 增加同步核心（目前只有 `LiveSessionAPI.listSync/getSync`、`LiveJobAPI.listSync`） |
| B8-3 | **P1** | **19 个测试文件以 CommandRouter/JSONValue 为骨架** | §3.2；`StubCommandRouter.responses:[String:JSONValue]`、`RecordingCommandRouter`、`FaceLegacySyncLoading` 的同步假设 | 不是“改几行”，而是重写约 6 个大型套件（FaceKeywording ~1200 行、LayoutBudget、ReviewFix、SettingsSaveSemantics、Similarity/Library/Gallery live provider）。工作量约占 B8 的 40% |
| B8-4 | **P1** | **C1 胶囊 7 处页面 plumbing** | `C1StatusCapsuleHost(router:)` 7 处（§7），`appServices.culling` 已存在但 7 个页面都未接收（Culling 的 VM 有 culling，胶囊仍走 router） | 需要改 7 个 View 的 init 与 RootView 传参；`C1StatusService` 是单例，注入必须幂等 |
| B8-5 | **P1** | **CaptureOne reload ack 无 API 面** | `CaptureOneBridge(router:)`:111-116 → `recordCaptureOneReloadAck`:194-199 → `SessionRepo(connection: db)` | AppServices 没有 DB/SessionRepo；需增 `sessionRepo` 或 `reloadAck` 闭包字段。否则只能保留 Router 类型，B8 无法收口 |
| B8-6 | **P1** | **错误漏斗反向依赖 NativeCommandClient** | `APIErrorPresentation.message`:367-374 → `NativeCommandClient.userFacingMessage`:372 | 删 Client 前必须先把 SessionServiceError/BridgeError/NSError 兜底搬进 `APIErrorPresentation`；`GatherApp:260`、`Persons:198`、`Dashboard:879`、`Gallery:841`、`Culling:262` 仍直接调用 |
| B8-7 | **P2** | **index.scan 无专用 typed 方法** | Gallery:221；Router 分支 2116-2121 使用 `dedupeKey:"metadata.scan:<id>"` | 只能 `JobAPI.start(JobCreateParams(...))`；漏 dedupe 会导致重复扫描，必须在 `LiveJobAPI` 或 Gallery 固定契约 |
| B8-8 | **P2** | **门禁假信号/半成品树** | `check-command-surface.sh` 自计数 118；当前 exit 1 on navigation.analyze；B6b 刚改 3 文件 | B8.0 只记录基线，不能把该脚本当 exit criteria；删 Router 后脚本必须删除而不是修 |
| B8-9 | **P2** | **Confirmed 门禁语义弱化** | Router 用 `confirmed:Bool` + `*_CONFIRM_REQUIRED` 码（export.execute:2362、metadata.resolve_conflict:2185、person.delete:1140 等）；typed API 只用 `Confirmed<T>` 标记 | UI 必须保证 `Confirmed` 只在确认分支构造；否则“未确认”会变成可编译的普通调用。现有测试（尤其 Export/Review）要补“未确认不发 API”断言 |
| B8-10 | **P2** | **当前工作区是 B6b 中间态** | `git status` 大量 M；Culling/Export/Library 在 01:04-01:05 被改 | 本文行号/计数是 01:06 快照；执行前用 `grep` 复核。B8.0 必须重新记录基线 |

**“无 typed API 的命令”结论**：15 条生产 + 45 条测试命令全部有协议方法；不需要新增协议。4 条真删除（photo.list、culling.decide、culling.batch_decide、album.get）和 5 条合并（create_from_directory/delete_many/filter.*/confirm_cleanup）需要在 B8 文档中显式记账，避免被当成“漏迁”。

**“需要 AppServices 增字段”结论**：至少 `runtime`（JobService/生命周期）与 `sessionRepo`（reload ack / culling syncStatus）两类；`culling`、`metadata`、`job`、`settings`、`person` 已存在，不需要新增协议字段。

---

## 10. 附：复现命令

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather

# 118 条命令
grep -cE '^[[:space:]]*case "[a-z_]+\.[a-z_]+"' \
  desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift

# 生产字符串派发点（B8.2 后应为 0；当前 19）
grep -rnE 'execute(Async)?\( *"[a-z_]+\.[a-z_]+"' \
  desktop/native/gather-app/Sources/GatherApp \
  desktop/native/gather-app/Culling desktop/native/gather-app/Settings \
  desktop/native/gather-app/Export desktop/native/gather-app/Duplicates \
  desktop/native/gather-app/FaceKeywording desktop/native/gather-app/ControlCenter \
  --include='*.swift' | grep -v 'SessionCommandRouter.swift' | grep -v 'NativeCommandClient.swift'

# 适配器/旧构造器
grep -rnE 'RouterCullingAPI|RouterNavigationAPI|RouterMetadataAPI|RouterFaceAPI|RouterFaceJobAPI|LegacySimilarity|LiveSimilarityDataProvider' \
  desktop/native/gather-app --include='*.swift'

# Router 依赖字段
sed -n '68,140p' desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift

# C1 胶囊宿主
grep -rn 'C1StatusCapsuleHost(' desktop/native/gather-app --include='*.swift'

# CaptureOneBridge(router:)
grep -rn 'CaptureOneBridge(router:' desktop/native/gather-app --include='*.swift'
```

> 行号漂移声明：本文所有行号均在 2026-10-22 01:06 的脏工作区快照上核对；B6b/B7b 若继续改文件，先重跑上面的 grep，再按文件:行定位。
