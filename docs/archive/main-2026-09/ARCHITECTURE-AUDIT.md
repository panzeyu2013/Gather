# Gather 架构审计报告（重构与优化目标）

> 审计对象：`Gather` 仓库（worktree 分支 `architecture`，HEAD `815762c`）
> 审计范围：`desktop/native/gather-core`（Swift 核心库）、`desktop/native/gather-app`（SwiftUI 宿主）、构建/CI/打包/文档
> 审计方式：只读静态审计 + 交叉验证（除本报告外未新增/修改仓库文件）
> 口径声明：行号/数量为静态统计值；测试用例数为 `@Test` 声明数（不含参数展开）；标注「已验证」的条目经独立命令或代码路径复核

---

## 一、结论摘要

Gather 是一次**从 Electron/TypeScript 到 Swift/SwiftUI 的整仓重写**（Electron 已于 `bf936d4` 移除）。
迁移后的代码在**功能完成度、文档化程度、算法对账门禁**上质量较高（0 个 TODO/FIXME、错误码集中登记、
迁移/备份/回滚有 ADR 约束、增量聚类有对账矩阵），但**架构债务集中在「跨语言移植的残留假设」**：
TypeScript 单线程事件循环时代的调用约定（同步阻塞、共享可变 Map、字符串错误码、无类型 JSON 边界）
被原样搬到了 Swift 并发/多线程运行时之上，产生了若干**功能性缺陷与并发风险**，而 app 侧 2.2 万行
代码仅有 3.6 千行测试，无法兜住这些缺陷。

按影响排序，最值得投入的六个方向：

| # | 方向 | 一句话结论 |
|---|---|---|
| 1 | **修复命令注册错配（4 个命令不可用）** | `metadata.resolve_conflict` 落 `NOT_IMPLEMENTED`；`metadata.conflicts`/`culling.confirm_sync`/`culling.finalize_sync` 被 `awaitSync` 主线程防御拦截；全部无测试覆盖 |
| 2 | **消除 3 处确凿的并发数据竞争** | `CullingService` 无锁 TTL 缓存、`MetadataService.batchAsync` 闭包内写共享字典/计数器、`WritebackService.execute` 并发闭包内 append 共享数组 |
| 3 | **修复「静默失效 / 静默错误结果」链路** | EXIF/尺寸 provider 未接线 → 时间/相机/GPS 过滤与连拍分组恒空；`MetadataSyncCoordinator.start()` 未调用 → 崩溃后写回不恢复；`ExportService` 空 `asset_id` 分组合并 → 整会话可能只导出 1 张且不报错；`FilterEngine` 未知操作符降级为「匹配全部照片」 |
| 4 | **重写命令边界为类型化注册表** | 3,128 行路由器中 1,844 行是两个巨型 `switch`；118 个命令靠 133 次 `requiredString`、86 次 JSON 往返和 47 处裸错误码字符串粘合 |
| 5 | **补 app 命令面测试 + 消除重复基础设施** | 118 个命令中 31 个零调用、只有 4 个出现在测试中；6 份 `batchAsync`、6 份 `BatchCursor`、**5 套互相矛盾的 RAW 扩展名**、24/43 张表 DDL 双份维护 |
| 6 | **裁决「假开关 / 未接线资产」** | 40 个 settings key 中 15 个无消费者；WatchCoordinator/HNSW/FaceMatcher/Telemetry/ImageCache/AnalysisWorker 等约 2,500 行已实现但生产零引用 |

---

## 二、项目解剖

### 2.1 规模与分层

| 模块 | 文件数 | 行数 | 说明 |
|---|---|---|---|
| `gather-core/Protocol` | 18 | 4,431 | 命令/DTO/JSONValue/错误码（跨端契约层） |
| `gather-core/Services` | 28 | 14,599 | 业务服务（Culling/Face/Similarity/Indexer/Metadata/Job…） |
| `gather-core/Database` | 21 | 8,718 | DB 基座 + 迁移 + 17 个 Repository（其中 Repos 5,612 行） |
| `gather-core/Face` | 8 | 2,048 | Vision 检测/编码 + HNSW/LSH 向量索引 |
| `gather-core/Similarity` | 3 | 1,393 | 聚类引擎 + 增量聚类 |
| `gather-core/{Watch,Image,IPC,Logging}` | 8 | 1,190 | FSEvents、RAW、helper 线协议、日志 |
| **core 源码合计** | **88** | **32,690** | |
| `gather-app` 源码 | 32 | 21,931 | Host 4,353（其中路由器 3,128）/ Support 1,880 / 页面 ≈15.7k |
| **测试** | 85 | **23,276** | core 19,639 / app 3,637 |

测试/源码 LOC 比：**core 0.60，app 0.166**。core 有 789 个 `@Test`，app 有 172 个。

### 2.2 依赖方向

```
SwiftUI 页面 ──┬─→ SessionCommandRouter（118 命令）──→ GatherCore 服务 ──→ SQLite/Vision/文件
               └─→ 部分页面/Dashboard 直接调用 router 暴露的 Core 服务 ← 边界不一致（见 P1-6）
```

- 没有循环依赖，core 不依赖 SwiftUI/AppKit，也不依赖第三方包（仅系统框架 + 自写 CSQLite shim）。
- core 的 public 声明约 2,997 个（占 79%），封装面偏大（`Database` 872 个 public）。
- 存在**三条并行的数据访问路径**：`router.execute`（同步）、`router.executeAsync`（异步）、
  以及通过 `router.sessionService`/`jobService` 等 **public 属性直连服务**（Dashboard、GatherApp.importFiles、Gallery/Library 的会话列表）。
  README/DEVELOPMENT 声称「路由器是唯一命令边界」，与实现不符。

---

## 三、已确认问题（按严重度）

### P0-1 同步/异步双注册错配：4 个 Culling 命令从 UI 必然失败

**证据链**：
- `SessionCommandRouter.awaitSync`（`Sources/GatherApp/Host/SessionCommandRouter.swift:2711-2724`）在
  `Thread.isMainThread` 时抛 `BridgeError.badParams("AWAIT_SYNC_ON_MAIN_THREAD")`。
- 同步 switch 中 **19 个命令**走 `awaitSync`（fkw.*、metadata.get/set/batch_set/conflicts、
  sim.preview_writeback/writeback/retry_failed_writeback/confirm_sync/cleanup、
  culling.finalize_sync/retry_failed_writeback/confirm_sync/cleanup）。
- `CullingViewModel` 是 `@MainActor @Observable`（`Culling/CullingView.swift:6-8`）；
  `confirmSync()`（`:1047-1055`）由按钮直接调用（`:1740`），`finalizeSync() async`（`:1057-1068`）
  由 `Task { await viewModel.finalizeSync() }`（`:1749`）在 MainActor 上执行，二者都同步调用
  `client.execute("culling.confirm_sync"/"culling.finalize_sync")`。
- 这两个命令**没有 async 版本**（不在 12 个双注册名单内），因此没有可用替代路径。
- app 测试中对 `culling.confirm_sync` / `culling.finalize_sync` 的引用为 **0**。

**影响**：Capture One 同步工作流的「已在 C1 加载」「保留 XMP 并结束」两个收尾动作点击即报错，
同步状态机无法闭环。**动作**：改用 `client.executeAsync`（或把这两个命令注册为异步），
并补路由级测试；**成本 S**。

**第 4 个受害者：`metadata.resolve_conflict`（注册在异步侧，却被同步调用）。**
- 该命令**只存在于 `executeAsync`**（`:2199`），同步 switch（103 个 case）没有它；
  `CullingViewModel.resolve(_:choices:)`（`Culling/CullingView.swift:1096-1105`）在 @MainActor 上
  用 `client.execute("metadata.resolve_conflict", ...)`（`:1101`）→ 命中 `execute` 的 `default`（`:1708-1709`）
  → **永远返回 `NOT_IMPLEMENTED: metadata.resolve_conflict`**，XMP 冲突裁决功能完全不可用。
- 代码注释本身自证这是已知缺口：`SessionCommandRouter.swift:2030-2032` 写着
  「审计 P0-2 修复：页面走 executeAsync 的 5 个命令此前落入 NOT_IMPLEMENTED」——同类问题只修了一部分。

**同一缺陷的第三个受害者：`metadata.conflicts`。**
- `CullingViewModel.loadPage(reset:)`（实例方法，@MainActor）在 `:685` 同步调用 `metadata.conflicts`；
  该命令同样走 `awaitSync`（`:1176-1182`）→ **必抛** `AWAIT_SYNC_ON_MAIN_THREAD`。
- 后果：`conflicts = []`（`:689`）清空冲突面板，并把兜底文案写入 `lastSyncError`，
  在 infoBar（`:1721-1731`）常驻红色错误条；而同一命令在后台路径
  `fetchSnapshot`（`:591`，`nonisolated static` + `Task.detached` `:491`）是**成功**的，
  造成「刚决策完能看到冲突、一切筛选就消失」的行为分裂。
- `loadPage` 的其余 5 条命令（`culling.list_page/summary/groups/sync_status/history`）不会抛错，
  但同样在 **@MainActor 主线程串行执行**（limit 500 + 100 条历史），由 6 个筛选控件
  （`:1351-1396`）每切换一次触发一次 → 主线程卡顿（详见 UI 层专项）。

### P0-2 「TS 单线程假设」残留：无锁可变缓存被多线程并发访问

迁移注释仍写着单线程前提，例如 `CullingService.swift:25-27`：

> 「Swift 侧服务实例同样按会话单线程使用，Map 无需加锁（与 SimilarityResultRepo 的
> photoGroupMapCache 同款决策）」

而实际调用模型是：`CullingViewModel`（MainActor）同步调用 `culling.update/batch_update`；
同时 `refreshSilently` 用 `Task.detached` 调用 `culling.list_page/groups/summary`，
**同一 `CullingService` 实例在两个线程上读写同一批字典**：

| 位置 | 可变状态 | 同步手段 |
|---|---|---|
| `Services/CullingService.swift:331,333` | `sessionLookupCache` / `sessionUpdateCache`（值为可变 class，:2286/:2332） | 无 |
| `Services/CullingService.swift:227-233` | `CullingHistorySink.entries`（标了 `@unchecked Sendable`） | 无 |
| `Database/Repositories/SimilarityResultRepo.swift:43,45` | `photoGroupMapCache` / `photoGroupMapCacheOrder` | 无 |
| `Services/CaptureOneSyncState.swift:82` | `observedStates` | 无 |
| `Similarity/IncrementalClusterer.swift:211` | `graphCache` | 无 |
| `Watch/Coordinator.swift:86-88` | `watchers/timers/pendingPaths` | 有私有串行队列（需保持不变量） |

**影响**：Swift `Dictionary` 并发读写属未定义行为，可导致崩溃或缓存损坏，且非确定性难以复现。
**动作**：把这些服务改为 `actor`（或统一加锁 + 值类型条目），并删除「单线程」注释假设；
**成本 M**。

> 需要区分：`DBConnection` 本身是**有并发防护的**（`SQLITE_OPEN_FULLMUTEX` + `NSRecursiveLock` 串行化全部
> SQL 与嵌套事务 SAVEPOINT，`DB.swift:62-91,169-203`，注释显示此前审计已处理过 DB 级竞争）。
> 风险恰好在 DB 之上的服务层缓存：它们在连接锁之外、以 TS 单线程假设编写。

### P1-3 命令边界是巨型 `switch` + 字符串 JSON，类型化 DTO 层被绕过

- `SessionCommandRouter.swift` 3,128 行；`execute` 占 `:551-1712`（1,162 行），
  `executeAsync` 占 `:1713-2394`（682 行）——**两个 switch 合计 1,844 行，占全文件 59%**。
- 130 个 case 标签 / 118 个唯一命令，12 个命令在同步与异步两处重复实现。
- 手工粘合代码量：`requiredString` 133 次、`optionalString` 40 次、`optionalNumber` 24 次、
  `guard let` 94 次、`completion(WebResponse(...))` 105 次、`MISSING_PARAM:` 35 次、
  `Task { }` 25 次、`JSONValue(from:)` 86 次。
- `Protocol/` 已有完整 Codable DTO（4,431 行），但命令入口接收 `[String: JSONValue]`、
  出口把 DTO 序列化成 `JSONValue`；app 侧再用
  `JSONValue.decoded(as:)`（`Support/JSONValueDecoding.swift:11-13`）
  **先 `JSONEncoder().encode` 再 `JSONDecoder().decode`** 转回同一类型。
- 该往返在热路径上执行：`GalleryViewModel.swift:141`（`[GalleryPhotoData]`）、
  `LibraryViewModel.swift:203/224`（`[GlobalPhotoResult]`）、分页 `CullingPage`、`[AnalysisJobData]` 等，
  app 共 **74 处**。
- 路由器依赖注入 **23 个服务 + DBConnection**（`:102-127`），是事实上的 god object / 组合根。

**影响**：每个新命令都要复制 20-40 行样板；参数名/类型错误只能运行期发现；大分页载荷双倍 JSON 序列化。
**动作**：引入类型化命令注册表（`Command<Params: Decodable, Result: Encodable>` + 表驱动分发），
让 DTO 直接承接参数与结果；短期先加 `JSONValue` 直解 Decoder 消除 round-trip。
**成本 L（注册表）/ S（直解）。**

### P1-4 错误码名义上类型化，实际全部是裸字符串

- `GatherErrorCode`（`Protocol/Core.swift:324-495`）有 **156** 个 case，但全仓 `GatherErrorCode.` 成员访问仅 1 处（core）/ 0 处（app）。
- app 源码中有 **180** 个形如 `XXX_YYY` 的字符串字面量，其中 156 个恰好是枚举 case（说明枚举被当作「登记表」而非「API」）；
  **24 个不在枚举内**（`C1_NOT_CONFIGURED`、`C1_NO_SELECTED_PHOTOS`、`C1_SCRIPT_TIMEOUT`、
  `SIM_ANALYZE_FAILED`、`SIM_RECLUSTER_FAILED`、`AWAIT_SYNC_INTERNAL`、`PHOTO_NOT_FOUND`…），
  其中 **19 个没有本地化映射**（`GatherLocalization.errorText` 只能回退通用文案）。
- 反向漂移：`errorMessages` 有 159 个键，多出 3 个孤儿键。
- 进一步核对：156 个 case 中有 **42 个从未以标识符形式被引用**，但**全部 42 个都以字符串字面量形式在使用**
  （0 个真正死码）——即枚举纯粹是「登记表」，没有任何类型约束力。
- core 侧还有 8 个码值不在枚举内（`EXPORT_SOURCE_MISSING`、`IMAGE_PATH_INVALID` 等）。
- SessionCommandRouter 内联 47 处 `error: "CODE"`。

**影响**：ADR-016/017「核心层只抛错误码、界面层统一映射」的边界靠约定维持；
新增码值三处（枚举/抛出点/映射表）靠人肉同步，已出现缺口。
**动作**：命令返回值统一为 `GatherErrorCode`（或 `CommandError`），把 app 专属码并入共享枚举，
并加一条「所有抛出码必须登记」的测试；**成本 M**。

### P1-5 app 命令面与功能页测试覆盖不足

- 118 个命令名中，只有 **4 个**出现在 app 测试源码里；**113 个**在 app+core 全部测试中从未被提及。
- 36 处 `guard confirmed(params)`（破坏性确认双兜底）无直测。
- `Tests/GatherAppTests/Support/StubCommandRouter.swift` 让多数 ViewModel 测试**绕开真实路由器**；
  只有 4 个测试文件用 `SessionCommandRouter.makeDefault(db:)`。
- 6 个功能页共 **7,758 行**无专属测试文件：CullingView 2,701、FaceKeywordingView 1,498、
  SettingsView 1,417、SessionControlView 816、ExportView 733、DuplicatesView 593（其内嵌 ViewModel 同样无直测）。
- app 测试/源码 LOC 比 0.166；core 为 0.60。

**影响**：P0-1 这类「命令不可用」缺陷没有任何自动化信号；路由与参数契约重构风险极高。
**动作**：表驱动契约测试（命令名全集断言、未知命令、缺参、`confirmed` 门控、双注册一致性）；
对 6 个功能页的 ViewModel 补状态机测试；**成本 L**。

### P1-6 数据访问路径三套并存

- `DashboardDataProvider`（`Dashboard/DashboardViewModel.swift:86-160`）直接调用
  `sessionService.listSessions()`、`workspaceStatusService.getStatus()`、`jobService.list()`；
  `DashboardViewModel` 是 `@MainActor`（`:263-265`），`startAutoRefresh`（`:560-571`）
  每 2s 在主线程同步执行 SQLite 查询。
- `GatherApp.importFiles`（`GatherApp.swift:206-215`）也直接调用 `router.sessionService.createSession/addPhotos`。
- Culling 走「后台 detached + 同步 execute」，Library/Gallery/Similarity 走 `executeAsync`。

**影响**：同一边界三种语义（阻塞线程、回到哪个线程、错误包装方式都不同），
测试与性能分析困难，且主线程有 N+1 查询风险。**动作**：统一为「异步命令 + 后台执行」单一路径，
把 provider 改成 async，路由器移除或收敛 public 服务直连；**成本 M-L**。

### P1-7 重复基础设施与双份真相源

| 重复项 | 证据 | 风险 |
|---|---|---|
| `BatchCursor` 三份**逐字相同**实现 | `Services/MetadataSyncCoordinator.swift:914`、`Services/DuplicateService.swift:682`、`Services/WritebackService.swift:708` | 修一处漏两处 |
| 有界并行 map 辅助重复 | `Services/MetadataService.swift:593` 与 `Services/WritebackService.swift:684`（24 个重复窗口） | 并发语义漂移 |
| 分析控制器脚手架重复 | `Services/SimilarityService.swift:128-151` 与 `Services/FaceKwService.swift:463-486`（32 个重复窗口） | cancel/重入语义不一致 |
| RAW 扩展名两份清单不一致 | `Database/Repositories/PhotoRepo.swift:161-163`（10 个）vs `Services/PhotoAssets.swift:10-14`（22 个）；均注释「TS: RAW_EXTENSIONS」 | **SQL 首选变体（ADR-008）与内存 collapse 可能选出不同主变体**（.nrw/.x3f 等），分页与列表口径分裂 |
| Schema DDL 双份 | `Database/Schema.swift`（当前全量 DDL）与 `Database/Migrations.swift`（历史迁移内嵌 DDL）共 48 个重复窗口 | 新增表/列须两处同步，漏一处则新库与迁移库结构漂移 |
| 页面加载/错误/空态样板 | GalleryView/LibraryView 的 `content` switch 等 9 个重复窗口 | UI 行为不一致 |

**动作**：抽出 `Concurrency/Cursor`、`ParallelMap`、`AnalysisControllerRegistry`、单一 `RawExtensions` 常量；
让 Schema.swift 成为唯一 DDL 真相源（新库直接执行 + 迁移只做数据变换）；
**成本 M**。

### P1-8 巨型服务与迁移函数，SQL 绕过 Repository

- 最长函数：`Migrations.runMigrationsUnsafe` `:136-963`（828 行，33 个版本步骤内联）；
  `SessionCommandRouter.execute/executeAsync`（1,162/682 行）；`FaceKwService.analyze` ≈339 行；
  `IndexerService.scanSession` ≈417 行（闭包内嵌套函数使静态统计偏大，但确为长过程）。
- 16 个 Service 直接持有 `DBConnection` 执行 SQL：`prepare(` 调用 `IndexerService` 27 处、
  `DuplicateService` 21 处、`CullingService` 12 处、`NavigationService` 9 处…共 120+ 处。
- Repository 层有 17 个文件 / 5,612 行，但并非 SQL 的唯一归属：表结构变化会同时波及 services 与 repos。

**动作**：迁移拆成「每个版本一个 `MigrationStep` 类型 + 数组驱动」；
把 Service 内联 SQL 下沉到 Repo（或明确「Repo 只做单表 CRUD、跨表查询归 Service」并在文档中固定）；
**成本 L**。

### P2-9 构建工具链前向兼容：当前 Xcode 27 / Swift 6.4 下无法构建（已验证，含修复验证）

- 在审计环境执行 `swift test --package-path desktop/native/gather-core` 失败：
  `error: Build input file cannot be found: .../CSQLite.o`（libtool 链接 `libGatherCore.a`）。
- 根因：`Sources/CSQLite` 只有 `include/module.modulemap` 与 `shim.h`，**没有任何 C 源文件**，
  新版 SwiftPM 构建系统仍为它生成链接输入。
- **修复验证**：把包复制到临时目录并添加一个空的 `Sources/CSQLite/placeholder.c` 后，
  `swift build` 输出 `Build complete! (51.78秒)`（原目录未做任何修改）。
- CI 固定在 `macos-14`（旧工具链）因而掩盖了该问题；本地用 Xcode 16+/26/27 的开发者会直接卡在构建。

**动作**：加占位 C 源文件（或把 CSQLite 改为 `.systemLibrary` / `.target(..., publicHeadersPath:)` 方案），
CI 增加一个「最新 Xcode」矩阵任务；**成本 S**。

### P2-10 产品面/死代码残留

- **ONNX 模型下载功能与 Vision-only 管线脱节**：Settings 页有「自动下载模型」按钮
  （`Settings/SettingsView.swift:1156` → `startModelDownload()` `:543-566` → `ModelInstaller` `:820+`，
  下载 InsightFace `buffalo_l.zip` 并落盘 `face_detector.onnx`/`face_encoder.onnx`），
  但 `FaceKwService` 硬编码 `fallbackToOnnxEnabled: false`（`FaceKwService.swift:698`），
  ADR-026 也说明 ONNX 管线已删除。用户会白下载约 300MB 资产。
- 31 个命令从未被 app 任何代码调用（`session.create`、`metadata.set/batch_set`、`template.*`、
  `person.*`、`image.*`、`quality.get`、`photo.list`、`filter.suggest` 等），属 TS 时代命令面残留。
- `GatherCoreHelper`（30 行）与 `GatherCoreBenchmarks`（281 行）无仓库内消费者、CI 不执行。
- `desktop/resources/entitlements.mac.plist` 全仓 0 引用，且内容为 `app-sandbox=true`（与任意目录扫描冲突）；
  `build.sh:58-62` 的 codesign 未传 `--entitlements`。
- `try!` 3 处（`FilterEngine.swift:366`、`NavigationService.swift:483,543`）；
  `JobService.swift:636,706` 直接 `print` 绕过 Logger/Telemetry；`ImageCache.swift:624` `fatalError`。
- 31 个命令、模型下载、helper/benchmarks 是否保留应做一次产品裁决，建议按「保留/接线/删除」三分类处理。

### P2-11 本地化机制两套并存 + 少量硬编码

- `GatherLocalization.l("中文 key")` 有 **1,104** 个调用点；`en.lproj` 905 键；
  仅 3 个 key 缺英文翻译（`分析进度`、`初始化失败`、一处带引号长句）——质量整体很好。
- 但 `SettingsView` 另有 `PageCopy` + `zhDesc/enDesc` 成对机制（28+28 处），
  与 key 机制并行，新增设置项需维护两套写法。
- 未走本地化层的汉字段落：`C1StatusCapsule.swift` 8 处、`SettingsView.swift` 41 处、`PersonsView.swift` 1 处；
  日期格式 `"yyyy年M月d日"` 硬编码（`SettingsView.swift:528`、`PersonsView.swift:413`），
  不受 `appLocale` 控制。

### P2-12 文档与实现漂移（抽查确认）

| 文档 | 声明 | 实际 |
|---|---|---|
| `docs/ADR.md` ADR-023 | 「暂缓：GatherAppDelegate 无 jobService 引用、退出直接终止、无拦截」 | **已实现**：`GatherAppDelegate.swift:350-357` `applicationShouldTerminate` + `onPrepareForTermination` 已在 `GatherApp.swift:123-126` 装配 |
| `docs/DEVELOPMENT.md:184` | core 765 / app 92（2026-08-12） | 静态实测 core 789 / app 172 |
| `docs/DEVELOPMENT.md:229` vs `docs/ROADMAP.md:84` | 异步 22 vs 33/18 双注册 | 实测异步 27 / 双注册 12 / 并集 118 |
| `docs/ROADMAP.md:113` | schema 快照 41 表 | 快照与 `Schema.swift` 均 43 表 |
| `docs/ROADMAP.md:122` 与 `:150/:153` | 1.6 对账矩阵「未建」与「已完成」并存 | 自相矛盾（代码已实现 `Reconciliation/`） |
| `docs/DEVELOPMENT.md:213-217` 边界扫描命令 | `rg --files desktop/src packages/shared tests scripts` 必须为空 | 四个路径均不存在，`rg` 报错 → 输出空 → 断言恒真，**门禁空转** |
| `docs/Reconciliation/README` 引用 `scripts/reconciliation/`、`docs/NATIVE-DEVELOPMENT-ANALYSIS.md` | 双跑对账 | 文件已删除，现为单边自洽断言 |

### P2-13 UI 外壳的「opacity 常驻 + 手工可见性门控」

`RootView.swift:200-330` 让页面以 `.opacity` 常驻、用 `isActive/isVisible` 手工启停轮询，
并在 `onChange(of: destination)` 中对每个页面单独写停止/恢复逻辑（ADR-022 记录了 NavigationSplitView 迁移暂缓的理由）。
现状是**每个新增页面都必须记得实现门控**，漏一处就会后台空转或状态不刷新；
`nonFocusable()`、`.accessibilityHidden` 等也需逐页复制。

---

## 四、UI 层专项发现（gather-app）

> 本节来自 SwiftUI 层专项审计，均已按 `文件:行` 复核；P0 级缺陷已并入第三节 P0-1。

### 4.1 「VM 与 View 同文件」与测试黑洞

10 个 ViewModel 中有 5 个定义在 View 文件内部：
`CullingView.swift:8`（VM 占 6-1126 行）、`SettingsView.swift:115`（27-921 行，单文件还含 4 个数据模型 +
AppleScript 探针 `C1ProbeGate:792` + 模型安装器 `ModelInstaller:820`）、`ExportView.swift:10`、
`DuplicatesView.swift:43`、`SessionControlView.swift:16`；另外 5 个（Dashboard/Gallery/Library/
Similarity/Persons）则是 VM 独立文件 + `XxxDataProvider` 协议注入的规范做法。

**直接后果**：这 5 个文件对应的 ViewModel 中 4 个零测试——`SettingsViewModel`、`ExportViewModel`、
`DuplicatesViewModel`、`SessionControlViewModel` 无任何测试文件；`CullingViewModel` 只有
`CullingSyncFlowTests`（15 个 @Test，仅覆盖 `syncFlowState()` 纯函数）。测试 target 必须先编译
2,701 行的视图文件才能触达 VM，是事实上的耦合。

### 4.2 重复 UI 主题（每项都有明确收敛落点）

| 主题 | 重复证据 | 建议落点 |
|---|---|---|
| 错误横幅 | `NativeBanner(操作失败：%@)` 逐字出现在 8 个文件（Culling:1168、FaceKeywording:629、SessionControl:230、Settings:933、Similarity:53、Persons:48、Export:394、Duplicates:319），另有 3 处散装变体（Gallery:50、Library:25、Dashboard:29） | `Support/GatherCommonViews` 的 `GatherErrorBanner` |
| 加载/失败态 | Gallery:329-337 与 Library:465-473 **字节级相同**；Dashboard:42-50 同构 | `LoadStateView(phase:retry:)` |
| 页面头部 | 返回按钮 5 处、`C1StatusCapsuleHost` 7 处、`.largeTitle` 13 处（Culling/FaceKw/Export/Duplicates/SessionControl/Gallery/Similarity） | `SessionPageHeader` |
| 同步三档提示 | Culling View（:1784-1807）与 SimilarityViewModel（:888-917）9 条文案逐字重复 | 共享 `SyncControlHints` 值类型 |
| 日期解析 | ISO8601 双 formatter 块 4 份逐字拷贝（Settings:513、Dashboard:572、Persons:421、Duplicates:266） | `GatherDate.parseISO8601` |
| hex 颜色 | `NSColor(hex:)` 4 份（GatherTheme:101、C1StatusCapsule:244、LibraryView:655、GatherBadge:125）；动态色内联闭包 6 份，而 `GatherTheme.dynamic` 被 private 挡住 | 公开 `GatherTheme.dynamic`，只留一份 hex 解析 |
| 颜色标签 | 8 个 hex + 7 个中文名在 Culling:2021-2046 与 LibraryView:614-642 各一份 | `CaptureOneColorLabel.displayColor/displayName` |
| `LoadPhase` | Gallery:209 / Library:306 / Persons:57 / Dashboard:267 四份等价枚举 | 共享 `LoadPhase` |
| 键盘/滚轮 | `NSEvent.addLocalMonitor` keyDown 2 套（Culling:1961-2013、Gallery:755-779）+ 滚轮捕获 2 套（Culling:2613-2639、Gallery:826-864）+ `keyboardShortcut` 若干 | `WindowKeyMonitor` + `ScrollWheelZoomModifier` |
| 分页交互 | 触底（Culling:1837）/ 哨兵 onAppear（Gallery:362）/ 显式按钮（Duplicates:340）/ 页码（Library:507）四种 | `PaginationFooter(mode:)` |
| debounce | 5 份独立实现（Gallery/Library/Similarity VM + Library/Dashboard View，300ms/1s 不一） | `Debouncer` |

### 4.3 性能（除 P0-1 主线程查询外）

- **body 内 O(n) 重算**：`CullingView.currentIndex`（:1869 `firstIndex`）、`currentGroupAssets`（:1876 filter + Set）、
  `undoRedoButtons`（:1455/1462 两次 `first(where:)`）、`CullingWorkbenchViewer`（:2333/2539-2564 重建网格数组）、
  `SimilarityView.buildGroupRows`（:686 在 GeometryReader 内重建全部行）、`FaceKeywordingView.visibleClusters`（:1003-1011）。
- **Formatter 在 body 路径反复构造**：`DashboardView.dateText`（每卡 1×DateFormatter + 2×ISO8601）、
  `C1StatusCapsule.formatTime`、`PersonsView.dateText`、`ExportView` 的 ByteCountFormatter——应提为 `static let` 或预格式化。
- **body 内写 @State**：`GalleryView.layoutCache` 在 `layoutRows`（:378-389, 386）内于视图求值期间赋值，
  会触发额外失效轮次并可能产生 “Modifying state during view update” 告警。
- `PhotoThumbnailView` 本身设计良好（NSCache 512MB + 并发闸门 + detached 解码），但
  `cacheKey`（:109-111）**不含 mtime/size**，外部改图不失效；查看器大图用 `.interpolation(.medium)` 偏糊。

### 4.4 本地化：SettingsView 双轨且译文冲突（P1）

- SettingsView 自带 `zhLabel/enLabel`、`zhDesc/enDesc` 平行体系（`SettingsView.swift:27-111`）；
  其中 **40 个 key 同时存在于 `en.lproj`，且 40/40 英文译文不一致**（例：`检测敏感度` 内联
  “Detection confidence” vs lproj “Detection Sensitivity”）。`GatherLocalization.l()` 对这些 key 调用次数为 0，
  即 lproj 里约 70 条 Settings 译文永远不会被读到。
- 其它页面本地化健康：1,090 个 `l()` 调用、804 个唯一 key；en 表有 101 条零引用（其中约 70-85 条为上述死翻译）；
  仅 2-3 个 key 缺英文。建议统一到 `l(zhLabel)` 单轨（或反向删除 lproj 条目），并加 CI 校验。

### 4.5 无障碍与主题

- `accessibility*` 覆盖极不均衡：Gallery 9 / Culling 9 / Root 8 / Export 8 / Similarity 7 / FaceKw 6，
  但 **LibraryView 0（666 行、22 个按钮）**、**DuplicatesView 0（593 行、12 个按钮）**、
  SessionControlView 1、PersonsView 2、SettingsView 2。
- 主题令牌使用率低：`GatherTheme.Radius/Spacing` 仅 25 处，而 `cornerRadius:` 字面量 **80 处**（10/8/6 三档为主）；
  `.font(.system(size:))` 字面量 10 处；查看器文字/阴影多处硬编码。`gatherCard()`（25 处使用）是唯一成功收敛的样式抽象，
  可照此补 `gatherToolbar()/gatherSectionTitle()/gatherIconButton()`。


## 五、宿主/路由层专项发现（gather-app/Host）

> 本节来自命令边界专项审计；P0 级问题已并入第三节 P0-1。

### 5.1 路由器解剖（3,128 行）

| 区间 | 内容 | 行数 |
|---|---|---|
| 71-152 | 存储属性 + 23 参数 init | 82 |
| 173-364 | `makeDefault` 组合根（构造约 20 个服务） | 192 |
| 366-547 | `registerExecutors`（7 个 job executor） | 182 |
| 549-1711 | `execute` 同步 switch（103 case） | 1,163 |
| 1713-2394 | `executeAsync` 异步 switch（27 case） | 682 |
| 2396-2917 | 参数读取/装配/解析 helper | 522 |
| 2919-3128 | decode、错误映射、SyncAwaitBox、BridgeError | 210 |

同步 case 平均 11.2 行，异步 case 平均 24.0 行；`catch { completion(WebResponse(ok:false, error: Self.errorMessage(error))) }`
逐字重复 29 次，`guard let sessionId = try? requiredString(...)` 25 次，`["done": .bool(true)]` 14 次。

### 5.2 错误映射有 5 份且语义互相冲突

| 实现 | 位置 | 未知码行为 |
|---|---|---|
| `NativeCommandClient.message(for:)` | `Support/NativeCommandClient.swift:55-60` | 通用文案 |
| `GatherLocalization.message(for:)` | `Support/GatherLocalization.swift:215-226` | **原样返回原文** |
| Dashboard 自己的包装 | `Dashboard/DashboardViewModel.swift:688-695` | 裸 NSError 文案 |
| SimilarityViewModel | `Similarity/SimilarityViewModel.swift:945-952` | 返回**未翻译的错误码** |
| FaceKeywordingView | `FaceKeywording/FaceKeywordingView.swift:552-557` | 返回裸码 |

同一错误在不同页面可能显示中文、原始英文或裸码。**动作**：只保留
`GatherLocalization.message(for:)` 一个出口，其余转发；**成本 M**。

### 5.3 错误码本地化缺口（与 P1-4 互补）

- `GatherErrorCode` 156/156 在 `errorMessages` 中有映射，但表多出 3 键；
- **8 个「会被生产但不在表中」的码**：`GATHER_BOOTSTRAPPING`（`GatherAppDelegate.swift:311`，
  注释期望提示「正在初始化，请稍后再试」，实际显示通用错误）、`AWAIT_SYNC_ON_MAIN_THREAD`
  （正是 P0-1 的用户可见文案）、`PHOTO_NOT_FOUND`、`INVALID_PARAMS`、`AWAIT_SYNC_INTERNAL`、
  `EXPORT_SOURCE_MISSING`、`WRITEBACK_PROVIDER_NOT_INJECTED`、`IMAGE_PATH_INVALID`/`IMAGE_PRELOAD_UNSUPPORTED`。
- 另有 30 处英文散文化错误（如 `"limit must be an integer between 1 and 2000"`、
  `"Invalid decision: must be keep, reject, or pending"`）经映射后统一变成「发生未知错误」，用户无法区分参数错与崩溃。
- 参数化码用 `CODE::a::b` 字符串拼接（`FILTER_FIELD_UNKNOWN::field`、`CULLING_REVISION_CONFLICT::e::c`），
  无结构体字段；`FILTER_SCHEMA_UNSUPPORTED` 带 `{{version}}` 模板却从不传参，渲染成残缺文案（且被测试固化）。

### 5.4 执行线程模型未显式化

- `SessionCommandRouter` 是非隔离、非 `Sendable` 的 class，却被 `CullingView.swift:491` 的
  `Task.detached` 跨线程捕获；`StubCommandRouter`/`CaptureOneBridge`/`FaceKwWritebackBridge` 则标了
  `@unchecked Sendable`——同一接缝两套假设。
- `executeAsync` 有**三条执行路径**：`Task {}`（25 处，落全局协作池）、**在调用线程直接同步执行**
  （`index.scan` `:2125`、`quality.analyze` `:2143`、`session.create_from_directory` `:2172`）、
  以及 default 分支的 `DispatchQueue.global(qos: .userInitiated)`（`:2385-2392`）。
  从 MainActor 调用时，第二条路径等同于主线程写库。
- 疑似：`DBConnection.close()`（`Database/DB.swift:93-98`）与 `open()` 未持连接锁写 `handle`，
  与其它线程的 `prepare/exec` 读存在竞争（需 TSan 验证）；`CaptureOneBridge.shared` 是可变的无同步全局。

### 5.5 命令层与页面直连服务并存（与 P1-6 同源）

- `GalleryViewModel.swift:125`、`LibraryViewModel.swift:187`、`SimilarityViewModel.swift:133` 直接调用
  `router.sessionService/jobService`；`GatherApp.swift:206-221` 直接 `sessionService.createSession/addPhotos`。
- `GatherApp.importFiles`（`:190-243`）把 `session.create` + `session.add_photos` 的语义**复制了一遍**且绕过命令边界。
- `CaptureOneBridge.init` 对 `CommandRouter` 协议做 `as? SessionCommandRouter` 下转型，失败时**静默不记 ack**
  （`CaptureOneBridge.swift:83-88`），协议注入形同虚设。

### 5.6 JSON 形状与命令面重复

- 同一张 photos 表存在**三种序列化策略**：`photo.list`（手写 snake_case，`:625-639`）、
  `photo.list_page`（手写 camelCase，`:2556-2586`）、`filter.photos_global`（Codable `GlobalPhotoResult`）。
- 两条读命令 `photo.list`/`filter.photos` 与页面实际使用的 `photo.list_page`/`filter.photos_global`
  功能重复（前者零调用），长期并存必然漂移。
- `JSONEncoder().encode → JSONDecoder().decode` 往返实现 4 份（`:3123-3128`、`:2920-2922`、
  `Support/JSONValueDecoding.swift:11-13`、`:2503-2518`）。
- `parseJSONObject`/`parseKeywordsJSON` 解析失败静默回退 `{}`/`[]`；异步分支大量
  `try? optionalNumber` 与同步分支的强校验并存，同参数两套严格度。
- 正面：app 层零 `JSONSerialization`，统一走 `JSONValue`/Codable。

### 5.7 测试守护缺失（与 P1-5 互补）

`StubCommandRouter`（35 行）**从不校验参数、未知命令也返回成功**——与真实路由语义相反，
所以本轮发现的 4 个注册错配在这套测试下必然全绿。建议至少让 stub 对未知命令抛
`NOT_IMPLEMENTED`，并补命令黄金列表测试（118 条 + 12 双注册）。

## 六、核心服务层专项发现（gather-core/Services，28 文件 / 14,599 行）

> 本节来自工作流服务专项审计；P0 级并发问题已并入第三节 P0-2 并在下节细化。

### 6.1 三处确凿的并发数据竞争（P0）

| # | 位置 | 共享状态 | 并发方式 |
|---|---|---|---|
| 1 | `Services/CullingService.swift:331,333`（条目为可变 class :2286/:2332） | `sessionLookupCache` / `sessionUpdateCache` | MainActor 同步写 vs `Task.detached` 读（`CullingView.swift:491/552`） |
| 2 | `Services/MetadataService.swift:265-270, 286-288, 351-352, 385-386, 389` | `fingerprints` 字典、`result` 字典、`pendingUpserts` 数组 | `batchAsync(concurrency: 16/10)` 真并发闭包内写入（`withThrowingTaskGroup`，`:594-612`） |
| 3 | `Services/WritebackService.swift:322, 336-340, 373-386` | `prepared`/`errors`/`failedItems` 数组与 `failed` 计数 | `batchAsync(concurrency: 4)` 并发 body 内 append（`:676-706`） |
| 4 | `Services/MetadataService.swift:444-511` | `success`/`failed`/`errors` | `batchSet` 的 `batchAsync(concurrency: 4)` 闭包内自增/append |

**共同根因**：`batchAsync` 的 body 签名是普通 `@escaping (T) async throws -> R`（非 `@Sendable`），编译器不做并发检查；
「并发原语复制了 6 份」（见 6.5 D1）意味着**只有部分副本被修过**。
**动作**：把 body 改为返回值、由父任务归并（`MetadataSyncCoordinator` 版已是正确样板），或统一收进 actor；
同时给 `batchAsync` 加 `@Sendable` 约束让编译器兜底；**成本 M**。

### 6.2 静默失效的功能链路（P1，用户可见）

- **EXIF/尺寸 provider 未接线**：组合根只给 `MetadataService` 注入 `metadataCacheRepo/xmp/connection/mutations/assetResolver`（`SessionCommandRouter.swift:242-248`），
  没有 `ExifProvider`/`ImageDimensionsProvider`（协议定义在 `Services/MetadataProviders.swift:131-140`）⇒
  `photo_metadata_cache` 的 EXIF 列（`date_taken`/`camera_make`/`camera_model`/`gps`/`width`/`height`）**全仓无生产者**（所有写点只写 rating/label/keywords：
  `MetadataCacheRepo.swift:132-179`、`CullingService.swift:532/535/823/826`、`MetadataService.swift:396/437/541`、`MetadataSyncCoordinator.swift:795-810`）
  ⇒ `FilterEngine` 的 16 个 metadataFields 过滤（`FilterEngine.swift:56-60`）与 `NavigationService` 的 `captured_at` 分组（`NavigationService.swift:250`）**生产恒空/恒退化**。
- **`MetadataSyncCoordinator.start()` 从未被调用**（`MetadataSyncCoordinator.swift:145-157`）：全仓 `.start(` 只有 `jobService.start()`；
  崩溃/退出遗留的 `status='writing'` 行不会被复位为 pending、pending 行也不会在启动时自动排程——ADR-015 声称的重启重推导只在用户再次触发时才发生。
- **`AssetRepo.metadataRelocationSink` 无生产注册者**（`AssetRepo.swift:155/161`，唯一注册在测试 `AssetRepoTests.swift:327`）⇒ 资产迁移后的 outbox 路径重定位通知无人接收。
- **`PhotoAssetResolver` 批量与单项语义分裂**：`resolveMany` 静默丢弃（`:87-90`）vs `resolve` 抛错（`:55-62`）。
- **无效 SQL**：`DuplicateService.swift:339` 执行 `PRAGMA group_concat_limit = 0`——SQLite 无此 pragma，静默忽略，注释声称的 O(n²) 缓解从未发生。
- **设置项无写入路径**：`import_concurrency` 被 `SessionService.swift:194` 读取但不在 `SettingsService.getDefaults()`（`:19-75`）中，
  `settings.set` 会抛 unknownKey，且 `:202-213` 是串行 for 循环（注释的「分批」不改变行为）。

### 6.3 `MetadataMutationService` 身份比较缺陷（P1）

`removeTailIfCurrent`（`Services/MetadataMutationService.swift:180-189`）用
`task as AnyObject === current.task as AnyObject` 判断队尾身份。`Task` 是 struct，`as AnyObject` 每次都会产生**新的桥接盒子**，
比较恒为 false ⇒ 队列项永不被移除：
- `mutationQueues` 随 xmpPath 数量单调增长（内存泄漏）；
- 更严重的是链尾保留后，`previous?.value` 会在后续任务中被重抛（`:118/127`），
  **一次失败可让该照片的元数据写路径在进程内永久失败**。
**动作**：改用 token/UUID 或让链尾任务自行清理；补「失败后下一回合仍可写」测试；**成本 S**。

### 6.4 服务层没有存储边界：120 处裸 SQL

16 个服务直接 `connection.prepare(...)`：`IndexerService` 27 处、`DuplicateService` 21、`CullingService` 12、
`NavigationService` 9、`SimilarityService` 8、`WorkspaceStatusService` 7、`SessionService` 7、`TemplateService` 6、
`QualityService` 6、`MetadataSyncCoordinator` 5、`FilterEngine` 5、`ExportService` 4…
Repository 层（17 文件 / 5,612 行）并未成为唯一入口，表结构变更会同时波及 services 与 repos，也是「测试必须起真库」的根因。

**CullingService（2,361 行）由 5 类职责构成**（拆分建议）：

| 职责 | 行范围 | 建议去向 |
|---|---|---|
| 错误契约（27 case，含 IPC 校验错误） | 33-93 | `CullingValidationError` + `CullingDomainError` |
| 端口/扩展 | 100-136 | 保留 |
| DTO（含 3 个 init 重载） | 141-261 | `CullingModels.swift` |
| 写核心：updateState/batchUpdate/applyHistory | 393-888 | `CullingService`（保留编排） |
| 读/命令面 | 338-387, 943-1192 | 保留 |
| **分页与 SQL 构造器** | 1203-1449 | `CullingQueryBuilder`（纯函数，可脱库单测） |
| **富查询批量加载器** | 1454-1731 | `CullingLookupLoader` / 下沉 Repo |
| 装配/过滤（与 SQL 谓词两份语义） | 1734-1861 | `CullingAssetAssembler`（与 `buildFilteredWhere` 收敛为同一谓词） |
| TTL 缓存 + 可变条目 | 1868-2037, 2267-2361 | `CullingSessionCache`（改 actor，顺带修 P0-2） |

### 6.5 重复逻辑清单（横向一致性修复需要乘 N）

| # | 主题 | 重复量 |
|---|---|---|
| D1 | `batchAsync`/`mapConcurrent` 并发原语 | **6 份**（DuplicateService:708、MetadataService:585、WritebackService:676、MetadataSyncCoordinator:881、QualityService:587、IndexerService:1080） |
| D2 | `BatchCursor` 游标类 | **6 份**（另有 3 份逐字相同的测试副本，且丢失生产版竞态修复 → 可永久挂起） |
| D3 | IN 分块 + 占位符 | 66 处，6 种 chunk 大小（400/800…）各写各的 |
| D4 | RAW 扩展名 | 10 项（PhotoRepo:161）vs 23 项（PhotoAssets:10）→ 主变体判定分叉 |
| D5 | `nowISO`/日期解析 | 私有 `nowISO()` **6 份** + `nowISOString()` + NavigationService 版；每次调用新建 formatter |
| D6 | JSON 编解码 | 服务层内联 `JSONEncoder/Decoder` 14 处 + `JSONValue.parse` 18 处 + `JSONSerialization` 一套 |
| D7 | 进度上报 | 服务 `onProgress` 40 处 + Job 层 9 处，两套节流语义 |
| D8 | 错误码映射 | 三种形状（非可选/可选/仅 description）+ 路由层 20+ 分支 |
| D9 | 过滤语义 | SQL 下推 `buildFilteredWhere` vs Swift 安全网 `matchesFilters`（6 维逐条重写，`metadataConflictOnly` 只在一侧） |
| D10 | 分页策略 | keyset（culling/photo）vs offset（FilterEngine） |
| D11 | sha256→hex | 5 份 |
| D12 | 路径/缩略图解析 | `TSPath.xmpSidecarPath` 23 处使用，但 ExportService:499-503 又用 URL 方式重写一份 |
| D13 | 状态计数归约 | 3 份（WorkspaceStatusService:282、MetadataSyncCoordinator:192、CaptureOneSyncState:39） |
| D14 | 「损坏 sidecar 空读守卫」 | 逐字两份（MetadataService:243 vs MetadataSyncCoordinator:777） |

### 6.6 性能热点（确认）

- **N+1 写路径**：元数据写回逐照片 `PhotoAssetResolver.resolve`（单照片 5 路 JOIN + 读 setting）：
  `MetadataMutationService.swift:75/112`、`WritebackService.swift:127/176`、`MetadataService.swift:488`；
  现成批量 `resolveMany`（`PhotoAssetResolver.swift:67`）只在 3 处使用 ⇒ `batchUpdate` 上限 1 万张 = 1 万次单行 JOIN。
  `MetadataService.batchSet` 预载后又逐项调用 `setMetadata`（`:449-477 → :504`），预载形同虚设。
- **一次性加载**：`IndexerService.loadPendingBackfill` 跨页累积**整个会话**待回填照片（`:702-725`，pageSize 只限单次查询）；
  `DuplicateService` 同时持有 6 个全量结构；`QualityService.get` 无条件全量投影。
- **整文件读入内存**：`IndexerService.sha256File`（`:140-143`，`Data(contentsOf:)`，并发 4-6）与
  `DuplicateService`（`:262`）、`MetadataFingerprint`（`:19-22`）——注释自称「流式」，实现不是；RAW 50-100MB/张时峰值数百 MB。
- **循环内重复解析/构造**：`NavigationService.group` 每行 2 次 `parseISODate`（每次 new 2 个 formatter，`:336/522-533`）；
  `ExportService.generateReport` 用 `content += "\(...)` 逐行拼接（`:296-298/312-315`）；`ExportService.preview` 每文件 1 次 stat。
- **语句不缓存**：`DBConnection.prepare` 每次重新 `sqlite3_prepare_v2`（`DB.swift:146-156`），120 个站点全部每次编译。
- **日志风暴**：`PhotoAssetResolver.buildResolved` 在 `resolveMany` 逐行循环内逐照片打 dual-read 警告（`:123-132`），
  而 `GatherLogger.log` 持全局递归锁同步输出（`Logger.swift:20/28-34`）。

### 6.7 错误处理与可测试性

- 服务层 `try?` **111 处**（MetadataSyncCoordinator 24、JobService 16、MetadataService 11、WritebackService 11、CullingService 9、SimilarityService 7、ExportService 7）。
  后果明确者：`CullingService.loadSessionPhotos` 吞 DB 错误返回空数组（`:1943-1945`）→ 上层误报 `photoNotInSession`；
  `SettingsService.loadCache` 静默回默认值（`:97-103`）；`DuplicateService.computeVisualHashes` 用 `try?` 包住整个 batchAsync（`:74`）把取消吞成「无 hash」。
- 自动重试只在 `MetadataSyncCoordinator`（5 档退避 `:79/625-627`）实现，其余服务失败即终态、靠手动 retry。
- 测试：核心 IO 大多有 provider 接缝（好），但 `DBConnection` 是具体类 ⇒ 服务测试必须起真库（22 处 `:memory:` + 约 50 处 `makeMigratedDB()`）；
  测试替身复制生产逻辑（`StubMutationPort` 复刻 `queuePhotoValues` 47 行、`FakeFSXMPProvider` 重实现 XMP 语义、dirty-field 过滤 3 份逐字相同）；
  **零测试实现 1,606 行**（MetadataService 638、MetadataMutationService 240、CaptureOneSyncState 176、MetadataProviders 140、MetadataContract 125、MetadataConflictFields 116、ImagePreloadService 82、PhotoAssets 47、MetadataFingerprint 42）；
  WritebackService 791 行仅 2 个用例；分页测试从未跨默认 limit=200。

### 6.8 补充：核心服务终版审计新增的高严重度项

> 以下条目在第一轮摘要之后补入，均已按 `文件:行` 复核。

| 级别 | 问题 | 证据 | 影响 |
|---|---|---|---|
| **P0（条件触发）** | `ExportService.filteredPhotos` 用 `photo.assetId ?? photo.id` 分资产组，而全库约定是 `COALESCE(NULLIF(asset_id,''),id)` | `ExportService.swift:406` vs `PhotoRepo.swift:250`、`Schema.swift:544`、`Migrations.swift:896-906`、`FilterEngine.swift:121/127` | 若库中存在 `asset_id=''`（空串而非 NULL）的行，这些照片会被合并成同一组 ⇒ `.preferred/.raw/.jpeg` 策略下**整会话只导出 1 张**，静默丢数据 |
| **P1** | ExportService 折叠顺序不确定（`Dictionary.values` 迭代序跨进程不同，无 `order` 数组） | `ExportService.swift:405-416` vs 保序实现 `PhotoAssets.swift:24-37`、`CullingService.swift:1804-1806` | `{counter}` 命名与导出顺序每次不同 |
| **P1** | ExportService：`execute` 开头 `setCancelled(false)` 会丢掉先到的取消；全部文件失败仍返回成功结果，JobService 记 succeeded，WorkspaceStatus 把 succeeded 当「已导出」 | `ExportService.swift:168, 252-271`；`SessionCommandRouter.swift:521-522`；`JobService.swift:530-533`；`WorkspaceStatusService.swift:198-202` | 取消无效；目标盘满/源全缺失时 UI 显示「已导出」 |
| **P1** | ExportService 两个错误码从不抛出（`sourceMissing`、`cancelled`）→ 对应 catch 是死分支，源缺失退化为 NSError 英文文案 | `ExportService.swift:84/89/111/116/250/254` | UI 的 `EXPORT_SOURCE_MISSING` 分支永不触发 |
| **P1** | DuplicateService 用空串回写不可读文件的历史 checksum（无条件 UPDATE 全部照片） | `DuplicateService.swift:303-317`（配 `:226-238/243-249`） | 数据损坏 + 下次全量重算；与 ADR-010 的「只填空值」方向约束相反 |
| **P1** | DuplicateService：公开注入点 `clusterProvider` 的返回被强制解包；视觉 hash 阶段 `(try? await batchAsync) ?? []` 吞掉取消，且调用侧只查自定义 `signal.aborted`、从不查 `Task.isCancelled` | `DuplicateService.swift:439, 74, 296` | 异常 provider 直接 fatal error；取消通道不交 |
| **P1** | FilterEngine 未知操作符静默降级：keywords 的 default 生成 `1=1`（匹配全部照片）、has_face/person 同型 | `FilterEngine.swift:378-380, 397-399, 436-440` | 返回错误结果集（比报错更危险） |
| **P1** | FilterEngine offset 语义不一致：`filterGlobally` 丢弃只有 offset 的请求；`filterPhotos` 只传 offset 时生成裸 `OFFSET` → SQLite 语法错误 | `FilterEngine.swift:147-154, 95-102` | 分页重复或直接报错 |
| **P1** | NavigationService 分组指纹字段不全（缺 cameraModel/filepath/filename/status）→ 改名、换目录、元数据回填后仍复用旧组 | `NavigationService.swift:468-485` vs `:336-345` | 陈旧分组结果 |
| **P1** | NavigationService.analyze 在 `executeAsync` 内同步内联执行（全量扫描+分组+写库），无取消、无进度，调用方为 @MainActor | `SessionCommandRouter.swift:1713-1740`；`NavigationService.swift:91-121` | UI 冻结数秒至数十秒 |
| **P1** | QualityService 相对排名 O(n²)（每个成员 `results.firstIndex(where:)`），analyze 与 get 每次都跑 | `QualityService.swift:513-521` | 大 session 排名爆炸 |
| **P1** | QualityService 错误文案用 `String(describing: NSError)`，与「必须等于 TS error.message」的文件头契约矛盾 | `QualityService.swift:306` + `:126-144` | 用户看到系统英文错误 |
| **P1** | 40 个 settings key 中 **15 个无运行时消费者**（c1_timeout_ms/thumbnail_concurrency/db_*/cache_*/onnx_threads/metadata_write_mode…），而 `import_concurrency` 被读取却不在默认键表 ⇒ `settings.set` 抛 unknownKey | `SettingsService.swift:19-75`；`SessionService.swift:194`；消费点缺失见各服务 | 用户在 UI 改设置无效（假开关） |
| **P2** | RAW 扩展名实为 **5 份副本**：PhotoAssets 22 项 / PhotoRepo 10 项 / ExportService 内联 21 项 / IndexerService.supportedExtensions / RAWDecoder.supportedExtensions；ExportService 把 `.gpr/.raw/.rwl/.sr2` 当 RAW 却在 RAWDecoder 不支持 → `EXPORT_RAW_CONVERT_UNSUPPORTED` | `PhotoAssets.swift:10-14`；`PhotoRepo.swift:161-163`；`ExportService.swift:403, 515-522`；`IndexerService.swift:53-59`；`Image/RAWDecoder.swift:53-60` | 主变体判定分叉 + 导出失败 |
| **P2** | FilterEngine 查询计划（EXPLAIN 实测）：`filterGlobally` 每结果行 2 个相关 GROUP_CONCAT 子查询走全索引扫描；`filterPhotos` 因 `SELECT DISTINCT` + 非结果列 ORDER BY 产生**两个 TEMP B-TREE** 并物化含大文本列的整个结果集后才 LIMIT | `FilterEngine.swift:119-142, 81-104` | 大库筛选首屏代价高 |
| **P2** | `ImageCache.swift`（782 行）确认生产零实例化，仅被自身测试使用；ADR-007 声称的磁盘缩略图缓存实际走 `PhotoThumbnailView` 的 NSCache | `ImageCache.swift:42`；`ImageCacheTests.swift`；`PhotoThumbnailView.swift:74-99` | 整块未接线资产 |

## 七、任务/写回/人脸专项发现（gather-core 基础设施）

> 本节来自任务调度、元数据写回、人脸/相似度基础设施专项审计。

### 7.1 任务状态机（JobService / JobScheduler / AnalysisJobRepo）

**正向**：claim 仅 `queued` 且 CAS（`AnalysisJobRepo.swift:185-193`）；心跳 5s / 看门狗 5s / 租约 30s；
heartbeat/progress/finish 都带 `lease_owner` 谓词；dedupe 有部分唯一索引兜底（`Schema.swift:559-561`）；
`JobScheduler` actor 设计良好。

**问题（P1）**：
1. **租约丢失无 fencing**：`recoverStale` 只改状态不通知执行器（`AnalysisJobRepo.swift:159-168`），
   `JobRunContext.throwIfCancelled` 不识别 `interrupted`（`JobService.swift:127-129`）⇒
   执行器被线程池/DB 锁饿死 >30s 时，看门狗把仍在运行的任务判死，而它继续写库；成功路径随后抛 `leaseLost`、失败路径 `try? finish` 吞掉（`:530-531/555-558`）。
2. **`cancelling` 永久残留**：heartbeat 允许 `cancelling` 续租（`AnalysisJobRepo.swift:195-200`），
   执行器不主动检查取消时看门狗永不接管；且 JobService 从不 `Task.cancel`（`:212/286/718/740` 无调用），
   `Inference.swift:67` 的 `Task.checkCancellation` 实际不可达。
3. **`stop()` 无超时等待**：abort 后 `await run.value`（`JobService.swift:263-269`），执行器忽略 abort 会让
   `prepareForTermination()`（`SessionCommandRouter.swift:167-171`）永久挂起、退出卡死。
4. **export 结果/断点复用**：dedupeKey 只有 `export.execute:<sessionId>`（`SessionCommandRouter.swift:2365`）而执行器从 checkpoint 读
   options/destinations/completedPhotoIds（`:505-512`）；复活 job 不刷新 checkpoint（`AnalysisJobRepo.swift:100-106`）；
   `JobService.create` 不清 `completedResults` 且 `takeCompletedResult` 读后不删（`:314-319/440-444`，TTL 5 分钟）
   ⇒ **5 分钟内重复导出同会话会静默返回上一次结果；换目标导出会跳过已完成照片**。
5. **无 executor 的 job 类型永久 queued**（`JobService.swift:675` 直接 continue，无告警）；
   `sharedJobScheduler` 权重预算机制只被死代码 `AnalysisWorker` 使用，实际未生效；
   `checkpoint` 的 `merge` 语义（非空即覆盖，`:156-163`）与 executor 回传旧 checkpoint 的模式存在覆盖陷阱。

### 7.2 写回链路（MetadataSyncCoordinator / WritebackService / outbox）

- **5 个状态载体**并存：`metadata_outbox.status`、`metadata_outbox_sessions.confirmed_at`、
  `sessions.reload_acked_at`、`writeback_items.xmp_status`（UI 投影）、`CaptureOneSyncState.observedStates`（内存），
  且投影有 2 个写入者（`WritebackService` 与 `MetadataSyncCoordinator.resolveConflict` `:270`）⇒ 只能事后对账。
- **【P1】`markStatus` 无 revision 守卫**（`MetadataOutboxRepo.swift:298-304`，WHERE 仅 xmp_path）：
  `processRow` 在 await 之后用它写 conflict/failed（`MetadataSyncCoordinator.swift:592/623`），
  会覆盖并发 `mergePatch` 产生的新 revision ⇒ **用户新编辑被打成冲突/失败**。
- **【P1】`MetadataSyncCoordinator.start()` 从未调用**（见 6.2）。
- 【P2】`removeOwnedFaceKeywords` 只写 outbox、不建 writeback 行（`WritebackService.swift:492-497`）⇒ 两表长期分叉；
  `WritebackRepo.updateStatus` 成功路径也 `attempt_count+1`（`WritebackRepo.swift:123-128`）；
  `shutdown()` 无界 20ms 轮询（`MetadataSyncCoordinator.swift:462-472`）；
  模块隔离用字面量清单（`MetadataOutboxRepo.swift:140`）且另有一条排除 culling 的兜底规则（`WritebackService.swift:103-110`）。
  正向：`mergePatch` 全事务、claim 带 expectedRevision、`markWritten` CASE revision 守卫、`runPath` 单飞、5 档退避。

### 7.3 人脸与向量

- **【P1】聚类替换非原子**：`getBindingsBySession → deleteClustersBySession（同事务删除 role_bindings）→ saveClusters` 三步各自提交
  （`FaceKwService.swift:1142-1144`；`FaceRepo.swift:761-768/543-571`）⇒ 中途失败丢失用户角色绑定。修法：包单事务（SAVEPOINT 已支持），成本 S。
- **【P1】早退判据不含观测版本**：`signatureMatches && hasClusters` 即返回缓存（`:679-687`），而签名只在聚类成功后写（`:839`）
  ⇒ 「推理成功 → 聚类失败」后，下次直接早退，**新观测与旧集群长期不一致**。
- **【P1】`recluster` 无并发守卫**（`:860-873`），IPC 侧是裸 `Task`（`SessionCommandRouter.swift:1896-1906`）⇒ 与 analyze 交错可产生两组集群/幽灵绑定。
- **【P1】向量内存往返**：Encoder 输出 `[Double]` → 落库前 map 成 `[Float]`（`FaceKwService.swift:198/735`）→ 读回再转；
  768 维 ×10 万脸时 Double 中转使峰值翻倍；`normalizedFlat` 因 COW 必然整块复制（`Clusterer.swift:55-72/138`），峰值约 3 份嵌入。
- **【P1】LSH 每查询 O(n) 初始化**：`visited = [Bool](repeating: false, count: n)` + `reserveCapacity(n)` + 全量 `sort`（`VectorIndex.swift:774-776/795`），
  n>2 万才启用 LSH（`Clusterer.swift:141-144`）⇒ ANN 收益被字节级 O(n²) 抵消。
- 【P2】`CosineHnswIndex` 生产零引用（仅 benchmark），且实现有 无删除/无锁非 Sendable/m=1 时 `mL=+inf` 层级退化/邻居数组越界无防御 等问题；
  `encodingFailures` 恒 0（`Inference.swift:33/76` 后无人累加）⇒ IPC 契约字段失真；
  `FaceInferenceConfig` 的 nms/input size 四字段写而不读；
  `IncrementalClusterer.graphCache` 键不一致导致最坏 2×O(k²)（`:211-262`）、复用旧组零校验、seed 缺失静默丢组。

### 7.4 「已实现但未接线」清单（grep 验证）

| 模块 | 证据 | 规模 |
|---|---|---|
| `Watch/Coordinator.swift`（FSEvents 监控） | 生产 0 实例化（ROADMAP:59/92 声称已接线）；且缺 `kFSEventStreamCreateFlagWatchRoot` 使 RootChanged 分支不可达（`:253-255/307-313`） | 374 行 |
| `CosineHnswIndex` 等 | 生产仅 benchmark | ~550 行 |
| `FaceMatcher`/`LibraryEmbedding`/`PersonRepo.getAllEmbeddings` | 生产 0 调用 ⇒「跨 session 重识别」链路缺失 | ~240 行 |
| `Face/Preprocessing.swift`、`FaceDetector.detectFaces` | 生产 0 调用（Encoder 自建 Vision 请求） | 322 行 |
| `CaptureOneSyncState`/`C1BridgeProvider` | 0 实例化，只有两个纯函数被用 | ~130 行 |
| `Telemetry` 全模块 | 生产 0 调用 | 158 行 |
| `AnalysisWorker` + `sharedJobScheduler` | 仅自引用/测试 | ~184 行 |
| `gather-core-helper` | 不随 app 打包、仓内 0 spawn | ~70 行 |
| `fallbackToOnnxEnabled` | 恒 false 且无实现 | 哑开关 |
| `MetadataContract` 4 函数、`populateCache`、`metadataRelocationSink`、`image.*` 命令 | 0 调用/0 发送方 | ~300 行 |

> 其中 `populateCache`（`MetadataService.swift:517-546`）是**未爆炸的雷**：它用只含 width/height/fileSize 的
> `MetadataCacheInput` 调 `MetadataCacheRepo.upsert`，而该 upsert 用 `excluded.*` 覆盖全部列
> （`rating ?? 0`、label/keywords 置 NULL/[]，`MetadataCacheRepo.swift:169`）——一旦接线会把用户星级/标签/关键词清零。

### 7.5 日志与遥测

`GatherLogger` 无脱敏钩子，调用方直接拼绝对路径/实体 id（`FaceKwService.swift:724/756/792/806`、
`MetadataService.swift:388`、`Migrations.swift:1032-1035` 等；正面样板：`PhotoAssetResolver.swift:125-129` 用 path digest）；
`minimumLevel`/`output` 是全局可变 `static var`；无 off 级别、无轮转、无 OSLog；默认 stdout 与 helper 的 JSON 行协议互斥（`JobService.swift:636/706` 还有裸 `print`）。

## 八、持久化层专项发现（gather-core/Database + Repositories，8,718 行）

> 本节来自持久化层专项审计（含在 sqlite3 3.54 上按 `Schema.swift` 重建库后的 EXPLAIN QUERY PLAN 实测）。

### 8.1 正向结论（先说不该改的）

- **无 SQL 注入**：483 处 `connection.prepare` 全部参数绑定，动态标识符有白名单（`FilterEngine.resolveField` `:458-466`、排序仅 ASC/DESC、SET 片段来自固定字段表）。
- **连接并发防护成立**：`FULLMUTEX` + `journal_mode=WAL` + `foreign_keys=ON` + `busy_timeout=5000` + `NSRecursiveLock` 串行化全部 SQL 与事务，嵌套事务降级 SAVEPOINT（`DB.swift:62-91, 169-203`）。
- **迁移可靠性是本层最好的部分**：磁盘空间检查 → `wal_checkpoint(TRUNCATE)` → SQLite backup API → 备份 `integrity_check` → 失败恢复 → `foreign_key_check` + 列不变量 + 版本校验（`Migrations.swift:41-61, 1164-1342`），并保留 keep=3 备份。
- **已有 keyset 分页正例**：`PhotoRepo.getBySessionPage`（`:190-202`）、`getAssetPage`（`:215-246`）、`IndexerService.loadPendingBackfill`（`:702-726`），EXPLAIN 确认走 `idx_photos_session(session_id,rowid>?)`。

### 8.2 确认的问题

| 级别 | 问题 | 证据 | 影响 | 成本 |
|---|---|---|---|---|
| **P0** | `SimilarityResultRepo` 无锁可变缓存被并发读写（写入/失效来自 `SimilarityService`，读来自 `CullingService`） | `Database/Repositories/SimilarityResultRepo.swift:39-45,153-180`；`SimilarityService.swift:388,886`；`CullingService.swift:951,1961` | Swift COW 字典并发写 = UB/崩溃 | S |
| P1 | 事务内做文件 IO，持锁期间阻塞所有读 | `AssetRepo.swift:211-227`（`backfillSession` 事务内逐张 `tsStat/tsExists`，`:1013/1025/1072`） | 慢盘/网络卷上 UI、心跳全部排队 | M |
| P1 | 心跳（5s）与写事务共用同一连接，长事务可让看门狗把存活任务判死并自行 abort | `JobService.swift:196-197,253-255,502-517`；`AnalysisJobRepo.swift:159-167` | 任务假 interrupted/自中止 | M |
| P1 | 5 处「写后重读」强制解包，非原子 | `MetadataOutboxRepo.swift:255`；`AnalysisJobRepo.swift:107,111`；`SessionRepo.swift:61`；`SmartAlbumRepo.swift:107` | 并发删除/清理即崩溃 | S |
| P1 | `IndexerService` 缓存清扫直接 `DELETE FROM photos`，未清理由 NO ACTION 依赖行；已用 sqlite3 实测 FK 语义报错 | `IndexerService.swift:206-233`（尤其 `:209`）；`Schema.swift:213,383` | 扫描/清扫任务报 `FOREIGN KEY constraint failed` | S-M |
| P1 | `AnalysisJobRepo.create` 的 UNIQUE 恢复路径 UPDATE 无 status 守卫 | `AnalysisJobRepo.swift:100-107` | 可把 running 任务重置为 queued 并清空 lease | S |
| P1 | 无预编译语句缓存 + 热点循环逐行 prepare | `AssetRepo.swift:3-4,641,889,1033-1153`（`ensurePhoto` 每张照片约 13 次 prepare）；`FaceRepo.swift:369-375` | 大库导入/回填 CPU 与耗时显著 | M |
| P1 | 43 张表中 **24 张表 DDL 在 `Schema.swift` 与 `Migrations.swift` 各写一遍**，已出现「仅靠后续 ALTER 补齐」的列分叉（`face_clusters.synced_to_library/match_confidence` 只在 v1 ALTER） | `Schema.swift:6-531` vs `Migrations.swift:530-561` 等 | 新库/升级库形态分叉，回归难发现 | M |
| P1 | 外键级联不一致，删除顺序靠人工维护；`SessionService` 必须按序手工清理 | `Schema.swift:213,250,255-263,278,359-383`；`SessionService.swift:159-174` | 新删除路径必然踩 FK | M |
| P1 | `DBError.message(String)` 无错误码，靠字符串判定 | `DB.swift:35-37,140`；`AnalysisJobRepo.swift:86`（`contains("UNIQUE")`）；`Migrations.swift:74` | 磁盘满/FK 失败/库损坏在 UI 上不可区分 | M |
| P1 | EXPLAIN 实测：`reconcileRawJpegLinks` 候选对账近似 O(n²)（OR 子查询只按 status 收窄）；`filterGlobally` 以 `SCAN pmc` 驱动并对每行做 GROUP_CONCAT 相关子查询 | `AssetRepo.swift:582-591`；`FilterEngine.swift:109-175` | 大库筛选/合并慢 | M-L |
| P2 | `WritebackRepo.deleteItemsByIds` 用 `ids.count` 预编译占位符却按 400 分块绑定（当前靠「未绑定=NULL」侥幸正确，>32,766 时 prepare 失败） | `WritebackRepo.swift:152-168` | 潜在报错 + 可读性 | S |
| P2 | 7 处未分块 IN 子句（大数组变量数风险），而项目已有 `chunked(by:800)` 惯例 | `AssetRepo.swift:251-259,394-399`；`FaceRepo.swift:267-273`；`PersonRepo.swift:387,507`… | 变量数上限 | S |
| P2 | 7 份 `nowISO/newUUID` 私有副本 + 约 30 份位置索引行映射（与 `SELECT *` 列序强耦合，加列即静默错位）；`DBValue` 缺 `blobValue` | `PhotoRepo:331`、`PersonRepo:581`…；`FaceRepo.swift:22-38,850-858`；`PersonRepo.swift:557-562` | 维护/漂移 | M |
| P2 | God object：AssetRepo 1,175 / Migrations 1,363 / FaceRepo 859 / PersonRepo 589；拆分边界见下 | — | 可读性/持续膨胀 | M-L |
| P2 | 快照测试弱：只校验版本号、43 个表名与 3 个索引名，无列/类型/默认值/FK 清单 | `MigrationTests.swift:66-84`；`docs/fixtures/schema.snapshot.json` | 迁移回归漏检 | M |
| P2 | `ImageCache.swift`（782 行，独立 SQLite 元数据库 + 淘汰/对账）**生产零实例化**，唯一使用者是其测试；app 缩略图走 `PhotoThumbnailView` 的 NSCache | `ImageCacheTests.swift`（21 @Test）；`Support/PhotoThumbnailView.swift:74-99` | 净维护成本 + 双 SQLite 文件 | S-M |
| P2 | `PRAGMA group_concat_limit = 0` 非法（SQLite 无此 pragma，静默忽略） | `DuplicateService.swift:339` | 注释承诺的优化不存在 | S |
| P2 | 未分块 IN、OFFSET 分页、无 `ANALYZE/optimize`、主库未设 `synchronous`、WAL 无上限 | `FilterEngine.swift:95-102,147-153`；`DB.swift:62-77` | 深翻页退化、planner 选择差、WAL 增长 | S-M |
| P2 | Database 测试 0 个并发用例（无 Task/DispatchQueue），事务/嵌套/close-reopen 无单测；`SimilarityClusterStateRepo` 无独立单测 | `Tests/GatherCoreTests/Database/**` | 本节并发结论无回归保护 | M |

**God object 拆分边界（建议）**：
- `AssetRepo` → AssetBackfill / AssetLinkCandidate / AssetRelink / AssetMembership（+ Rows 文件）；
- `Migrations` → `[(version, description, up)]` 顺序数组 + Backup / Invariants / FaceThumbnail / FaceClusterMembers 四文件；
- `FaceRepo` → Observation / Cluster / Binding / ThumbnailStore；`PersonRepo` → Person / PersonPhoto / PersonEmbedding。

**注释漂移**：`AssetRepo.swift:911-913` 称「DB 层不支持嵌套事务，故扁平化」，与 `DB.swift:163-168` 的 SAVEPOINT 实现矛盾；
`Migrations.swift:134` 写「逐级 0→31」、`MigrationTests.swift:3` 写「0→32」，而实际 `currentSchemaVersion = 33`。

## 九、重构/优化路线图（建议）

### 阶段 0：止血（1-3 天，全部 S 成本、无需架构决策）

| # | 动作 | 证据 |
|---|---|---|
| 0.1 | 修复 4 个 Culling 命令：`metadata.resolve_conflict` 改 `executeAsync`；`metadata.conflicts`/`culling.confirm_sync`/`culling.finalize_sync` 改 async 或移出 MainActor | P0-1 |
| 0.2 | 修 4 处数据竞争：`CullingService` 缓存加锁/actor、`MetadataService.batchAsync` 闭包改返回值归并、`WritebackService.execute` 改归并、`SimilarityResultRepo` 缓存加锁 | P0-2 / 6.1 / 8.2 |
| 0.3 | 新增 `Sources/CSQLite/placeholder.c` 修复 Xcode 16+/26/27 构建（已验证有效） | P2-9 |
| 0.4 | `MetadataMutationService.removeTailIfCurrent` 身份比较改为 token/UUID | 6.3 |
| 0.5 | 5 处「写后重读强解包」改 guard/throw；`AnalysisJobRepo.create` 恢复路径加 status 守卫 | 8.2 |
| 0.6 | 人脸聚类替换（delete+save）包进单个事务；`recluster` 复用时序 | 7.3 |
| 0.7 | `MetadataSyncCoordinator.start()` 接入组合根 | 6.2 |
| 0.8 | 统一 RAW 扩展名清单（以 `PhotoAssets.rawExtensions` 为单一来源，SQL 片段由它派生） | P1-7 |
| 0.9 | `JobService` 的 `print` → `GatherLogger`；补 `AWAIT_SYNC_ON_MAIN_THREAD`/`GATHER_BOOTSTRAPPING` 等 8 个错误码译文 | P2-10 / 5.3 |

### 阶段 1：把隐性约束变成显式契约（1-2 周，M）

- **命令注册表**：`CommandID: String, CaseIterable` + `[CommandID: Handler(.sync/.async)]`，
  单一注册点服务 `execute`/`executeAsync`，async-only 命令在同步入口显式返回 NOT_IMPLEMENTED；
  先按域拆成 `Host/Commands/*.swift` 也可作为过渡（P1-3 / 5.1）。
- **错误码收敛**：命令返回值统一 `GatherErrorCode`；5 份「错误→文案」映射只留
  `GatherLocalization.message(for:)`；加 `for c in GatherErrorCode.allCases` 穷尽映射测试（P1-4 / 5.2 / 5.3）。
- **并发模型显式化**：`batchAsync` body 加 `@Sendable`；服务缓存统一 `actor` 或加锁；
  路由/协议标注隔离；`DBConnection.close()` 纳入连接锁（6.1 / 5.4）。
- **任务状态机硬化**：租约丢失触发 signal、取消宽限期 + 强制终态、`stop()` 加超时、
  export dedupeKey 纳入 options/目标摘要、create 清完成缓存（7.1）。
- **测试护栏**：`StubCommandRouter` 未知命令抛 NOT_IMPLEMENTED；
  命令黄金列表（118 条 + 12 双注册）；`confirmed` 门控表驱动用例（5.7 / P1-5）。

### 阶段 2：消除重复与静默失效（2-6 周，M/L）

- **接线或删除**（需一次 ADR 决策）：WatchCoordinator（补 `kFSEventStreamCreateFlagWatchRoot`）、
  HNSW、FaceMatcher/Preprocessing/Detector、CaptureOneSyncState、AnalysisWorker+JobScheduler、
  Telemetry、helper、`fallbackToOnnxEnabled`、31 个零调用命令、`ImageCache`、ONNX 下载 UI（6.2 / 7.4 / 8.2）。
- **补上 EXIF/尺寸 provider**，或把契约收缩为「仅 XMP 三字段」并同步修改 FilterEngine/NavigationService 与 UI（6.2）。
- **抽公共基础设施**：`BatchRunner`（含取消传播与保序）、`Cursor`、`JSONColumn`、`TimeFormat`、
  `SHA256.hex`、`PaginationFooter`、`GatherErrorBanner`、`LoadStateView`、`WindowKeyMonitor`、
  `Debouncer`、`CaptureOneColorLabel`（6.5 / 4.2）。
- **Schema 单源化**：迁移文件只保留转换逻辑，表 DDL 统一引用 `SchemaSQL`；
  快照测试升级为列/类型/默认值/FK/索引级（8.2）。
- **查询性能**：候选对账预聚合 + 双索引；`filterGlobally` 避免 `SCAN pmc`；
  `DBStatement` LRU 缓存；事务内移除文件 IO；`sha256` 改流式（8.2 / 6.6）。
- **文档台账**：用脚本生成测试数/命令数/表数，修正 ADR-023 状态、1.6 自相矛盾、
  边界扫描命令与 `Reconciliation/README` 死引用（P2-12）。

### 阶段 3：结构调整（1-2 个月，L）

- 拆分 `SessionCommandRouter`（按域 extension）与 `CullingService`（QueryBuilder/LookupLoader/
  Assembler/SessionCache/Service）、`AssetRepo`、`Migrations`、`FaceRepo`、`PersonRepo`（6.4 / 8.2）。
- Service 内联 SQL（120 处）下沉 Repository，明确并文档化持久化边界（6.4）。
- app 目录统一到 `Sources/GatherApp/Features/`，`Package.swift` sources 改默认发现 + 脚本校验（P2-13 配套）。
- Dashboard 等直连服务的路径改走异步命令，收敛为单一路径（P1-6 / 5.5）。
- 引入 swift-format/SwiftLint 与 CI 门禁、固定 Xcode、CI 增加 benchmarks/helper 冒烟（P2-9 配套）。

---

## 十、验证记录（本次审计实际执行）

| 动作 | 结果 |
|---|---|
| `swift test --package-path desktop/native/gather-core`（Xcode 27.0 / Swift 6.4） | 失败：SwiftPM manifest sandbox 不可用；`--disable-sandbox` 后失败于 `CSQLite.o` 缺失 |
| 临时副本 + `Sources/CSQLite/placeholder.c` 后 `swift build` | **Build complete! (51.78 秒)**（已清除临时目录与 `.build`，仓库无改动） |
| 静态重复块扫描（10/12 行窗口归一化） | 580 组跨文件重复窗口，Top 组见 P1-7 |
| 命令/错误码/本地化覆盖率脚本 | 118 命令 / 156 错误码 / 905 en 键 / 1,104 `l()` 调用点 |
| 路由器 case 跨度与函数边界 | `execute` 551-1712、`executeAsync` 1713-2394（含行号证据） |
| sqlite3 3.54 重建 `SchemaSQL` + EXPLAIN QUERY PLAN | 确认候选对账 O(n²)、`filterGlobally` SCAN pmc + 相关子查询、`filterPhotos` 双 TEMP B-TREE 等计划问题 |
| Swift 6.4 语义复刻 | 确认 `Task as AnyObject` 身份比较恒 false |
| 全仓引用计数扫描（grep） | 未接线模块/死代码/零调用命令清单（P2-10 / 7.4 / 8.2） |

> 未执行：完整测试套件（环境工具链阻断）、真实照片端到端、人脸推理质量评估——同 README 的「范围外」声明。
