# Cut 3 前置只读审计 v2：更新后的模块拆分映射（module split map v2）

> **状态**：**只读审计（docs-only）**。本任务的唯一产出是本文件；**未修改**任何源码、`Package.swift`、脚本、CI，未移动/删除文件，未做 git 提交。
> **快照时刻**：2026-10-22T05:0x+0800（`find` / `grep` 一次静态扫描，命令见附录 A）。
> **取代关系**：本文件**取代** [module-split-map.md](module-split-map.md) §0–§7 的数字与越界清单；v1 的 §1（目标图）、§5.1/5.2（资源归属）结论仍然有效，§2/§3/§6 的表已漂移，**不得再作为 3a/3b 的执行依据**。
> **依据**：[refactor-decisions.md](../../refactor-decisions.md) D-014（UI 不得依赖 Analysis）/D-015（GatherSchema 去留）/D-016（helper 退役）/D-017（RootView 归属）/D-018（测试 target）/D-029（ScanPath 归属）/D-093/D-094（Cut 2 关闭）、`desktop/native/gather-core/Package.swift`、`desktop/native/gather-app/Package.swift`、`scripts/*.sh`、`.github/workflows/ci.yml`、`desktop/native/build.sh`。
> **口径**：**【已确认】** = 有 `文件:行` 证据；**【疑似】** = 需构建/运行验证。所有行号取自本快照，引用前请重新 `read` 核对。

---

## 0. 快照：Cut 1/2 之后的真实数字

### 0.1 总量

| 项 | 旧快照（2026-10-21T23:38） | **本次（Cut 2 关闭后）** | Δ |
| --- | ---: | ---: | ---: |
| `.swift` 文件（含 2 个 `Package.swift`） | 306 | **364** | **+58** |
| 需归位的源/测试文件（不含清单） | 304 | **362** | +58 |
| 总行数 | 105,655 | **122,692** | +17,037 |
| 生产文件 | 184 | **212** | +28 |
| 测试文件 | 120 | **150** | +30 |

### 0.2 分块对账（每一格都可由附录 A 复现）

| 块 | 旧 | 新 | Δ | 行数（新） | Δ 归因 |
| --- | ---: | ---: | ---: | ---: | --- |
| `gather-core/Sources/GatherCore/**` | 136 | **145** | +9 | 41,794 | Cut 2 净增：`Database/` 22→30（+8：`Database.swift` 门面、`DeliveryRepo`、`DeliveryIntentRepo`、`DeliverySummaryQuery`、`DeliveryState`、`DeliveryError`、`SchemaV1`、`FileHasher`、`Queries/TableColumns`，−`Migrations`、−`SchemaV1Transition`）；`Protocol/` 18→19（+`PhotoFileTypes`，E-01 修复已落地） |
| `gather-core/Sources/{Helper,Benchmarks×2}` | 3 | **3** | 0 | 492 | — |
| `gather-core/Tests/GatherCoreTests/**` | 89 | **96** | +7 | 32,039 | Cut 1/2 新增 `DeliveryRepoTests`/`DeliveryIntentRepoTests`/`DatabaseFacadeTests`/`FileHasherTests`/`SchemaV1RowMappingTests`/`DeepReviewAcceptanceTests`/`DeliveryFaceSimilarityMirrorTests`/`MetadataParallelBatchTests` 等，删除 `MetadataSyncCoordinatorTests` 等 4 个（−1,983 行） |
| `gather-app/Sources/GatherApp/**` + 6 个根级功能目录 | 45 | **64** | +19 | 31,270 | **Cut 1 增量主力**：`Host/APIs/` 18 个 Live API + `AppComposition`/`AppRuntime`/`AppServices`/`ExecutorRegistry`/2 个 Bridge/`LivePhotoPathPolicy`；−3 个命令面文件（Router×2、NativeCommandClient） |
| `gather-app/Tests/GatherAppTests/**` | 31 | **54** | +23 | 16,919 | Cut 1 的 16 个 `API*Tests` + `AppCompositionTests`/`AppRuntimeTests`/`ExecutorRegistryTests`/`CullingSyncFlowTests` 等；−3 个命令面测试 |
| `Package.swift` ×2 | 2 | **2** | 0 | 178 | — |

### 0.3 与「306」的差异结论

+58 全部来自 **Cut 1 的 API/组合根落地**与 **Cut 2 的 Delivery/SchemaV1 收口**，**没有**任何「拆分预埋」文件。也就是说：**v1 映射表的 304 行基线上叠加了 58 个新文件，其中 22 个（Host/APIs 及其守卫）在 v1 里根本不存在** —— 这正是 v1 §0.2 那条「漂移提示」所预警的情况，且规模比预警更大（预警只提"Live 实现"，实际还包括 `AppComposition`/`AppRuntime`/`AppServices`/`ExecutorRegistry`/Bridge×2/`LivePhotoPathPolicy` 与 `AppServices.swift` 内的 `APIErrorPresentation`）。

> ⚠️ **v1 的最大失效点**：v1 §3.2 断言「Cut 1 已清除 UI→Host」，但 Cut 1 把 **22 个 Host 类型**放进了 `Sources/GatherApp/Host/`，而 UI 目录里仍有 **11 个文件**直接引用 Host 类型、**4 个文件**引用 Domain 类型（§2.4 E-16…E-19，去重后 **12 个文件**需改）。v1 的 E-06「已解决」是**基于文件删除**得出的，不是基于类型引用扫描。

---

## 1. 当前文件盘点 → 目标 target 分配

### 1.1 归位规则（唯一判据，按当前目录树）

| 目录 / 文件模式 | 目标 target | 与 v1 的差异 |
| --- | --- | --- |
| `Sources/GatherCore/API/**`（46） + `Protocol/**`（19） + `Logging/**`（1） | **GatherProtocol** | 无（`PhotoFileTypes.swift` 已在 Protocol 内） |
| `Sources/GatherCore/Database/**`（**全部 30**，含 `Schema.swift`/`SchemaV1.swift`） | **GatherPersistence** | **v1 把 Schema 拆给 GatherSchema 薄库；本次改为 DDL 留在 Persistence**（理由见 §6.5） |
| `Sources/GatherCore/{Face,Image,Concurrent,Similarity}/**`（18） | **GatherAnalysis** | 无 |
| `Sources/GatherCore/IPC/**`（3） | **删除**（D-016 审计结论，§4） | v1 是"过渡放 Analysis" |
| `Sources/GatherCore/Services/**`（28） | **GatherDomain** | 无 |
| 新建 `Sources/GatherSchema/main.swift` | **GatherSchema**（可执行） | D-015 落地；v1 是薄库 |
| `gather-app/Sources/GatherApp/Host/**`（27）+ `RootView.swift`（1） | **GatherHost** | 文件数 6→28（Live API 落地） |
| `gather-app/Sources/GatherApp/GatherApp.swift` | **GatherApp** | 需先剥离 310 行 bootstrap/import（§2.4 E-20） |
| `gather-app/Sources/GatherApp/**` 其余（29）+ 6 个根级功能目录（6） | **GatherUI** | 无 |
| `Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift` + `Support/AsyncGate.swift` | **GatherTestSupport** | 同 v1，但改用 `public` 而非 `package`（§5.2） |
| `Tests/GatherCoreTests/**` 其余（94） | **GatherCoreTests**（单 target，D-018） | v1 是 4 个 target |
| `Tests/GatherAppTests/**`（54） | **GatherAppTests**（单 target，内部分组） | 无 |

### 1.2 生产 target 分配（现状 212 文件 / 73,556 行）

| target | 文件 | 行数 | 占比 | 构成 |
| --- | ---: | ---: | ---: | --- |
| **GatherProtocol** | **66** | **7,401** | 10.1% | API 46/2,705 + Protocol 19/4,624 + Logging 1/72 |
| **GatherPersistence** | **30** | **10,303** | 14.0% | Database 30（Repositories 19/7,605、Queries/TableColumns 1/82、其余 10/2,616） |
| **GatherAnalysis** | **21** | **6,105** | 8.3% | Face 11/3,671 + Image 2/473 + Concurrent 2/139 + Similarity 3/1,563（含待删 IPC 3/259） |
| **GatherDomain** | **28** | **17,985** | 24.5% | `Services/**`（最大 4 个：CullingService 2,798、FaceKwService 2,241、SimilarityService 1,428、DeliveryCoordinator 1,399） |
| **GatherSchema** | 0 现有 → **1 新建** | ~60（新建） | — | `main.swift`：`dump`/`verify` 两个子命令 |
| **GatherUI** | **35** | **22,775** | 31.0% | Dashboard 2/1,841 + Gallery 3/2,426 + Library 2/1,748 + Persons 2/797 + Similarity 2/1,864 + Support 18/3,359 + 6 功能目录 6/10,740 |
| **GatherHost** | **28** | **8,088** | 11.0% | Host 9/3,029 + Host/APIs 18/4,009 + RootView 1/1,050 |
| **GatherApp** | **1** | **407** | 0.6% | `GatherApp.swift`（其中约 310 行应移 Host，见 E-20） |
| **GatherCoreHelper** | 1 | 30 | — | 建议删除（§4） |
| **GatherCoreBenchmarks** | 1 | 333 | — | 保持 |
| **GatherFaceBenchmarks** | 1 | 129 | — | 保持 |
| **CSQLite** | 0 | 0 | — | C target，保持 |
| **合计** | **212** | **73,556** | 100% | 拆分后 213（+GatherSchema main.swift，−Helper 若删则为 212） |

> 校验：`GatherProtocol 7,401 + Persistence 10,303 + Analysis 6,105 + Domain 17,985 + UI 22,775 + Host 8,088 + App 407 + 3 可执行 492 = 73,556` ✅

### 1.3 测试分配（现状 150 文件 / 48,958 行）

| 组 | 文件 | 行数 | 备注 |
| --- | ---: | ---: | --- |
| **GatherTestSupport**（移动 2） | 2 | 151 | `RepoTestSupport.swift` 108 + `AsyncGate.swift` 43 |
| **GatherCoreTests**（单 target，D-018） | 94 | 31,888 | 原 96 − 2 移出 |
| **GatherAppTests**（单 target） | 54 | 16,919 | 42 个用例文件 + 12 个 Support |
| **合计** | **150** | **48,958** | |

**若改四 target（延后到 Cut 6，D-018）**，切分如下（已按目录实测，可直接用）：

| test target | 文件 | 行 | 依赖 |
| --- | ---: | ---: | --- |
| `GatherProtocolTests` | 20 | 3,374 | Protocol（Protocol/ 18 + HelperMessageTests 38 + LoggerTests 57） |
| `GatherPersistenceTests` | 22 | 6,606 | Persistence, Protocol, **CSQLite**, GatherTestSupport（Database 8 + Repositories 14，DatabasePragmaTests 是唯一 `import CSQLite`） |
| `GatherAnalysisTests` | 24 | 6,497 | Analysis, Protocol, **Persistence**, GatherTestSupport（Face 12 + Reconciliation 7 + Concurrent 2 + Image 1 + Similarity 1 + IPC 1） |
| `GatherDomainTests` | 28 | 15,411 | Domain, Persistence, Analysis, Protocol, GatherTestSupport（Services 28） |

### 1.4 与「旧 306」的逐类处置

| 处置 | 文件数 | 明细 |
| --- | ---: | --- |
| **保持原位**（物理路径不变） | 4 + 2 清单 | 3 个可执行 `main.swift`、`GatherApp.swift`（先瘦身）；两个 `Package.swift` 原位重写 |
| **移动** | 296 | core 生产 145（Protocol 66 / Persistence 30 / Analysis 18 / Domain 28 / 3 可执行） + core 测试 92（94 − 2 保持） + app 生产 63 + app 测试 54 |
| **移动 + 改名** | 2 | `RepoTestSupport.swift → GatherTestSupport/DatabaseTestSupport.swift`；`Support/AsyncGate.swift → GatherTestSupport/AsyncGate.swift` |
| **新建** | 3 | `GatherSchema/main.swift`；`GatherUI/Support/ImageDecoderRegistry.swift`（§3）；`GatherHost/AppBootstrap.swift`（E-20 拆分产物） |
| **删除** | 6 | `IPC/HelperMessage.swift`(37)、`IPC/HelperProtocol.swift`(84)、`IPC/ImageCommands.swift`(138)、`Sources/GatherCoreHelper/main.swift`(30)、`Tests/.../IPC/HelperProtocolTests.swift`(270)、`Tests/.../HelperMessageTests.swift`(38) —— 共 **6 文件 / 597 行**（§4） |

> 校验：移动 296 + 保持 4 + 删除 6 = 306（含 2 清单）；清单不参与归位 → 304 个非清单文件 ✅

---

## 2. 依赖边：Cut 1/2 之后重新实测

### 2.1 Cut 1/2 新增的接缝（这些是新东西，v1 的边表里没有）

| 接缝 | 位置 | 类型 | 对拆分的影响 |
| --- | --- | --- | --- |
| **16 域 API 协议**（110 方法） | `Sources/GatherCore/API/*API.swift`（16 文件） | Protocol | ✅ 让 UI 只需 Protocol：**E-05 的 9 个 Service 持有点已消除** |
| **API Inputs/Outputs/Core/Errors** | `API/Inputs`(15)、`Outputs`(8)、`Core`(6)、`Errors`(1) | Protocol | ✅ 30 文件纯 DTO，无下层引用（实测 0） |
| **Live API 实现**（18 文件） | `gather-app/Sources/GatherApp/Host/APIs/` | Host | ⚠️ 4 个类型被 UI 反向引用（E-18） |
| **AppServices** | `Host/APIs/AppServices.swift`（334 行） | Host | ⚠️ 文件内 299–325 行的 `APIErrorPresentation` 是 **11 个 UI 文件的唯一错误文案出口**（E-16） |
| **AppComposition / AppRuntime** | `Host/AppComposition.swift`(363)、`Host/AppRuntime.swift`(226) | Host | ✅ 组合根与生命周期从 `GatherApp` 剥离（E-08 的一半） |
| **Delivery 四件套** | `Database/{DeliveryRepo 1,103, DeliveryIntentRepo 371, DeliverySummaryQuery 381, DeliveryState 153}` | Persistence | ✅ 纯 Persistence 内，Domain 经 Repo 使用 |
| **DeliveryError** | `Database/DeliveryError.swift`(126) | Persistence | ✅ 替代 `MetadataSyncError`；Domain 抛它（合法宽边） |
| **Database 门面** | `Database/Database.swift`(498) | Persistence | ✅ `Database.open(at:)` 是生产唯一建库入口；Host 调它 |
| **SchemaV1** | `Database/SchemaV1.swift`(768) | Persistence | ⚠️ 决定 GatherSchema 是"库"还是"可执行"（§6.5） |
| **PhotoFileTypes** | `Protocol/PhotoFileTypes.swift`(55) | Protocol | ✅ **E-01 已修复**：`AssetRepo:1178-1184`/`PhotoRepo:157` 只做转发，`RAWDecoder:197` 用 `PhotoFileTypes.isRAW` |
| **FileHasher** | `Database/FileHasher.swift`(51) | Persistence | ✅ **E-02 已修复**：`AssetRepo.swift:389` 用 `FileHasher.sha256File`；`IndexerService:199-201` 仅 deprecated 委托 |
| **ScanPath** | `Database/ScanPath.swift`(118) | Persistence | ✅ D-022/D-029：Domain 4+ 文件引用，Package 需声明 `Domain → Persistence` |

### 2.2 实测的跨目录引用矩阵

实测方式：对每个目标目录 grep 另一层的类型符号，剔除注释行。

| 边 | 实测 | 判定 |
| --- | --- | --- |
| **Protocol / API → 任何下层** | **0**（`DBConnection`/`AssetRepo`/`RAWDecoder`/`Service` 全 0） | ✅ I-03/E-13 守住 |
| **Analysis → Persistence** | **0**（`Image/` 对 `PhotoRepo`/`DBConnection`/`Database` 全 0） | ✅ **E-01 已修复** |
| **Analysis → CSQLite** | **0** | ✅ |
| **Persistence → Domain** | **0 代码引用**（`SchemaV1.swift:366/369/526` 三处只在 SQL 注释里提 `FaceKwService`/`SessionService`/`IndexerService`） | ✅ **E-02 已修复** |
| **Persistence → Protocol** | 18 个 Repo 返回 DTO | ✅ 合法（E-11） |
| **Domain → Persistence** | **18 文件 / 87 处**（CullingService 11、DeliveryCoordinator 11、SimilarityService 10、SessionService 8、IndexerService 8…） | ✅ 合法宽边（E-09），Cut 3 只声明 |
| **Domain → Analysis** | 7 文件（SimilarityService 5、ImagePreloadService 4、FaceKwService/DuplicateService/QualityService/ExportService/IndexerService 各 1） | ✅ 合法 |
| **Domain → CSQLite** | **0**（`import CSQLite` 仅 `DB.swift:8`、`DatabaseError.swift:15`） | ✅ E-15 结论仍成立 |
| **core → SwiftUI/AppKit** | **0** | ✅ E-14 守住 |
| **app → `import GatherCore`（伞）** | 生产 **53 文件** + 测试 **45 文件** = **98 处** | ❌ 拆分后全部变 `no such module`（I-01） |
| **UI → Host** | **11 文件**（§2.4） | ❌ 拆分即失败 |
| **UI → Domain** | **4 文件**（§2.4） | ❌ 拆分即失败 |
| **UI → Analysis** | **1 文件 / 3 调用点**（`PhotoThumbnailView`） | ❌ E-04（§3） |
| **Host → UI / Domain / Persistence / Analysis / Protocol** | 全有 | ✅ 组合根允许 |
| **GatherApp → Host + UI** | 有 | ⚠️ 还有 310 行业务逻辑（E-20） |

### 2.3 已消除（v1 的 A/B 类）

| v1 编号 | 结论 | 证据 |
| --- | --- | --- |
| E-01 Analysis→Persistence | **已修复** | `Protocol/PhotoFileTypes.swift:17`；`RAWDecoder.swift:197`；`AssetRepo.swift:1178`；`PhotoRepo.swift:157` |
| E-02 Persistence→Domain（环） | **已修复** | `Database/FileHasher.swift:28`；`AssetRepo.swift:389`；`IndexerService.swift:199-201`（deprecated 委托） |
| E-05 UI→Domain（9 文件持 Service） | **仅剩 4 文件 5 点**（原 9 文件已改 API 协议） | 见 E-19 |
| E-06 UI→Host（3 个 Router 类型） | **Router 已删除**，但**换成 4 个 Host 类型** | 见 E-16/E-17/E-18 |

### 2.4 仍存在的越界（拆分即编译失败，必须先修）

#### E-16 【A 类】**UI → Host：`APIErrorPresentation`（11 个 UI 文件）**

| 事实 | 证据 |
| --- | --- |
| 声明在 Host | `Host/APIs/AppServices.swift:299`（`public enum APIErrorPresentation`，294–325 行） |
| 被 **11 个** UI 文件调用 | `ControlCenter/SessionControlView.swift`(6)、`Culling/CullingView.swift:239`、`Duplicates/DuplicatesView.swift`(6)、`Export/ExportView.swift:578`、`FaceKeywording/FaceKeywordingView.swift`(9)、`Settings/SettingsView.swift`(8)、`Dashboard/DashboardViewModel.swift`、`Gallery/GalleryViewModel.swift:846/848`、`Library/LibraryViewModel.swift:773`、`Persons/PersonsViewModel.swift:258`、`Similarity/SimilarityViewModel.swift:908`（`grep -rln … | grep -v '/Host/'` 另命中 `GatherApp.swift`〔App target〕与 `Support/JSONValueDecoding.swift`〔类型声明〕，不计入） |
| **反向依赖**：Host 文件引用 UI 类型 | `AppServices.swift:312` 引用 `RouterCommandError`（声明在 `Support/JSONValueDecoding.swift:38`）；`AppServices.swift:302` 引用 `GatherLocalization`（UI） |
| 拆分后 | `GatherUI` 无法 import `GatherHost` → 11 文件全红；若把漏斗留 Host，`GatherHost → GatherUI` 与 `GatherUI → GatherHost` **成环**，SwiftPM 直接 `cyclic dependency` |
| **修法（推荐）** | 把 `APIErrorPresentation`（294–325，32 行）**移入 `GatherUI/Support/`**；把 `SessionServiceError`（`Services/SessionService.swift:13`）上移 `GatherProtocol/Errors/`（它是纯错误枚举，只依赖 `GatherErrorCode`）。移完 **11 个 UI 文件一行不改** |
| 附带清理 | `RouterCommandError`/`BridgeError`/`APIError` 是 Router 时代残留（仅被错误漏斗与测试使用，`APIError` 仍被 `LibraryViewModel` 10 处 `throw` 用于"非 Live 注入"的显式失败）→ 记 CL，Cut 6 处理，**本 Cut 不删** |

#### E-17 【A 类】**UI → Host：`CaptureOneBridge` / `C1PreflightStatus`（4 个 UI 文件）**

| 事实 | 证据 |
| --- | --- |
| 声明在 Host | `Host/CaptureOneBridge.swift:49`（`C1PreflightStatus`）、`:95`（`CaptureOneBridge`）、`:100`（`static var shared`） |
| UI 持有该类型 | `Culling/CullingView.swift:122 private let captureOne: CaptureOneBridge`、`:188 captureOne ?? CaptureOneBridge()`；`FaceKeywording/FaceKeywordingView.swift:87/147`；`Settings/SettingsView.swift:109/165/485`；`Similarity/SimilarityViewModel.swift:121/200` |
| UI 调用的成员 | `selectedPhotoPaths()`、`reloadMetadata(sessionId:)`（3 文件）、`checkHealth()`（Settings）、`CaptureOneBridge.documentProbeScript(appName:)`（Settings:485）、`C1PreflightStatus`（`DashboardViewModel.swift:272/293` 的 `C1PreflightResult.build(from:)`） |
| **额外风险** | UI 侧 `CaptureOneBridge()` 用默认闭包**自建实例**（`CullingView:188`、`SettingsView:165`、`SimilarityViewModel:200`）→ reload ack 被静默丢弃。这是**行为缺陷**，不只是分层问题 |
| **修法** | ① `C1PreflightStatus` + `CaptureOneBridgeError` 移 `GatherProtocol`（纯 DTO/错误枚举，0 依赖）；② `GatherProtocol` 声明 `public protocol CaptureOneBridging: Sendable`（5 个成员：`selectedPhotoPaths`/`reloadMetadata`/`checkHealth`/`preflight`/`static documentProbeScript`）；`CaptureOneBridge` 实现它；③ UI 改持 `any CaptureOneBridging`，**删掉 3 处默认自建**（改为必传参数），把"未注入"变成编译错误 |

#### E-18 【A 类】**UI → Host：4 个 `Live*API` 的同步核心（2 个 UI 文件 / 12 处）**

| 事实 | 证据 |
| --- | --- |
| `DashboardViewModel` 持有并构造 Live 类型 | `Dashboard/DashboardViewModel.swift:82-83`（`private let syncSessionAPI: LiveSessionAPI?`）、`:92-103`（`convenience init(sessionService:workspaceStatusService:jobService:)` 内 `LiveSessionAPI(...)`/`LiveJobAPI(jobService:)`）、`:118-126` |
| `LibraryViewModel` 靠 `as?` 下转 | `Library/LibraryViewModel.swift:223 as? LiveSessionAPI`、`:321-333 albumSyncAPI()/assetSyncAPI() as? LiveAlbumAPI/as? LiveAssetAPI` |
| 同步方法（UI 直调） | `LiveSessionAPI.listSync()`、`createSync(_:)`；`LiveAlbumAPI.listSync/createSync/updateSync/deleteSync`；`LiveAssetAPI.candidatesSync/acceptSync/rejectSync/volumesSync/relinkRootSync`；`LiveJobAPI` 的同步面 |
| 拆分后 | `GatherUI` → `GatherHost` 编译失败（12 处） |
| **修法 A（推荐，0.5 人日）** | 在 `GatherProtocol` 加 4 个"同步能力"协议（`SyncSessionAPI`/`SyncJobAPI`/`SyncAlbumAPI`/`SyncAssetAPI`，共 ~12 个方法），4 个 `Live*API` 声明 conformance（方法已存在，改可见性 + 签名即可），UI 的 `as?` 改成 `as? any SyncSessionAPI`。**不改业务代码** |
| 修法 B（更干净，2 人日） | 把 `LiveDashboardDataProvider`/`LiveLibraryDataProvider`/`LiveGalleryDataProvider` 三个类**整体移入 GatherHost**（它们本来就是"Live 装配"，名字都叫 Live），UI 只留 `*DataProvider` 协议 + VM；`DashboardViewModel:384 provider as? LiveDashboardDataProvider` 改成 `as? any SyncCapableDashboardProvider`（协议留在 UI）。推荐 Cut 4 做 |
| **裁决** | **3b 用 A**（机械、可回滚）；B 记入 Cut 4 的 UI 重构（D-017 的"Cut 4 再调"）。**不接受"允许 UI→Host"**——那会让 Host 与 UI 成环（E-16 同理） |

#### E-19 【B 类】**UI → Domain：4 文件 5 点**

| # | 位置 | 代码 | 修法 |
| --- | --- | --- | --- |
| 1 | `Support/GatherEventCenter.swift:94` | `public func wire(jobService: JobService)` | 改 `wire(jobs: any JobAPI)`，内部用 `JobAPI` 的进度流；`JobService.setProgressSink` 只在 Host 侧接一次（v1 E-07 未修，**已确认仍在**） |
| 2 | `Settings/SettingsView.swift:718` | `(SettingsService.getDefaults()[key] ?? "").isEmpty` | 把 `getDefaults()` 的 key→默认值表移 `GatherProtocol`（或让 `SettingsAPI` 暴露 `defaults()`）。`SettingsCatalogTests.swift:23/29` 依赖 `SettingsService.knownSettingKeys`，测试需改 import |
| 3 | `Dashboard/DashboardViewModel.swift:92-96` | `convenience init(sessionService:workspaceStatusService:jobService:)` | **删除**（D-019 #3 明确"仅测试"）。唯一调用方 `DashboardViewModelTests.swift:151-171` 改为 `AppServices.live(composition:)` |
| 4 | `Library/LibraryViewModel.swift:775` | `if let sessionError = error as? SessionServiceError` | 随 E-16 一起解决（`SessionServiceError` 上移 Protocol 后 UI 可引用） |

> E-19 的 #3 与 #4 会随 E-16 的方案自然消失；#1、#2 需要单独改（各 1–2 文件）。

#### E-20 【B 类】**GatherApp 不是"只有 @main"**

| 事实 | 证据 |
| --- | --- |
| `GatherApp.swift` 407 行 | `@main`+Scene 仅 `:13-97`（85 行）；`bootstrap()` `:100-229`（130 行）；`storedInterfaceLanguage` `:237-241`；`prepareNativeEmbeddingRerun` `:248-278`（31 行）；`importFiles` `:300-375`（76 行）；`scanScopeCheckpoint`/`isDirectory`/`defaultImportName` `:382-406` |
| 拆分后 | `GatherApp` 只依赖 `GatherHost`+`GatherUI` 时，这 310 行引用的 `Database/AppComposition/AppServices/CaptureOneBridge/SettingsRepo/ThumbnailDiskCache` 全部要跨 target |
| **修法** | 抽 `GatherHost/AppBootstrap.swift`（`bootstrap(completion:)` 或 `static func make() async throws -> BootstrapResult`）+ `GatherHost/AppImport.swift`（`importFiles`）。`GatherApp.swift` 收敛到 ~100 行。注意 `GatherApp.importFiles` 被 `GatherAppDelegateTests` 直调（注释 `:299`），迁移后测试改 `@testable import GatherHost` |

#### E-04 【A 类】**UI → Analysis：3 个调用点**（详见 §3）

#### RootView 归属（D-017 已裁决，非越界）

`RootView.swift`（1,050 行）持有 `let appServices: AppServices`（`:352/383`）与 `CaptureOneBridge`（`:409/421`）→ **必须留 GatherHost**（D-017）。Cut 3 的验收**不要求**它进 UI。`RootViewTests`/`LayoutBudgetTests` 因此归 Host 组。

### 2.5 拆 target 后的红点预算（谁改多少）

| 改动 | 文件数 | 行数 | 性质 |
| --- | ---: | ---: | --- |
| `import GatherCore` → 5 个新模块 | 生产 53 + 测试 45 = **98** | 98 行 | 机械（codemod 可做） |
| `@testable import GatherCore` → 按目录选模块 | **94** | 94 行 | 半机械（需按目录映射，附录 A-4） |
| E-16/E-17/E-18/E-19/E-20 边界修复 | **12 UI + 3 Host + 2 测试** | ~400 行 | 手写（有行为风险） |
| E-04 ImageDecoderPort | **1 UI + 1 Analysis + 1 Protocol + 1 Host + 1 测试** | ~150 行 | 手写 |
| 测试 target 结构（Support 抽取） | 2 移动 + 1 新建 | 151 行 | 机械 |

---

## 3. E-04 方案：`ImageDecoderPort`（D-014 裁决落地）

### 3.1 现状：3 个调用点（`Support/PhotoThumbnailView.swift`）

| # | 行 | 调用 | 返回类型 | UI 实际消费 |
| --- | ---: | --- | --- | --- |
| 1 | **538** | `try RAWDecoder.getPreview(path: path, maxDimension: size)` | `RAWDecodeResult` | 仅 `.buffer`（`:542`） |
| 2 | **540** | `try RAWDecoder.getThumbnail(path: path, size: size)` | `RAWDecodeResult` | 仅 `.buffer`（`:542`） |
| 3 | **628** | `try RAWDecoder.decodeRegion(path:normalizedRect:maxPixel:)` | `RAWRegionDecodeResult` | `PhotoDetailTileView` 只用 `.buffer` + `fullWidth/fullHeight`（`:704` 起）；`regionWidth/regionHeight` 未用 |

- 调用点 1/2 在 `PhotoThumbnailDecoder.decodeUncached(path:size:preview:)`（`:535-543`）内，是该 enum 的**唯一** RAW 依赖。
- 调用点 3 在 `PhotoThumbnailDecoder.decodeRegion(path:normalizedRect:maxPixel:)`（`:623-633`）内。
- 注意：UI 还依赖 `RAWDecodeResult`/`RAWRegionDecodeResult` **两个类型名**（`:536`、`:606`、`:627`），所以只"包一层函数"不够，**返回类型也必须离开 Analysis**。

### 3.2 端口定义（`Sources/GatherProtocol/Image/ImageDecoderPort.swift`，新建）

```swift
// GatherProtocol/Image/ImageDecoderPort.swift —— 新建（1 文件 ≈ 70 行）
import Foundation

/// 归一化矩形（左上原点，0...1）。**不引 CoreGraphics**：Protocol 保持 Foundation-only，
/// UI 侧用 CGRect→NormalizedRect 的一次换算（PhotoThumbnailView 内部 4 行）。
public struct NormalizedRect: Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { ... }
}

public struct DecodedImage: Equatable, Sendable {
    public let buffer: Data          // JPEG 字节
    public let format: String
    public let width: Int
    public let height: Int
}

public struct DecodedRegion: Equatable, Sendable {
    public let buffer: Data
    public let regionWidth: Int
    public let regionHeight: Int
    public let fullWidth: Int
    public let fullHeight: Int
}

public enum ImageDecoderError: Error, Equatable {
    case notInstalled            // Host 未注入（启动路径缺陷，必须响亮失败）
    case unsupportedExtension(String)
    case cannotOpenSource(String)
    case noImage(String)
    case dimensionsUnavailable(String)
    case encodeFailed(String)
}

/// UI 唯一的图像解码入口（D-014：UI 不 import GatherAnalysis）。
/// 实现由 GatherAnalysis 提供、GatherHost 注入（§3.4）。
public protocol ImageDecoderPort: Sendable {
    func thumbnail(path: String, size: Int, preview: Bool) throws -> DecodedImage
    func region(path: String, normalizedRect: NormalizedRect, maxPixel: Int) throws -> DecodedRegion
    var supportedExtensions: Set<String> { get }
}
```

> **为什么 `supportedExtensions` 也在端口里**：`GatherAppDelegate:55/85/469` 用 `RAWDecoder.supportedExtensions`（Host，合法），但 UI 侧拖放过滤将来要用它；放进端口避免再开一条 UI→Analysis 的边。当前 UI 未使用，可删（二选一，推荐保留）。

### 3.3 GatherAnalysis 实现（`Sources/GatherAnalysis/Image/RAWDecoderPort.swift`，新建）

```swift
// GatherAnalysis/Image/RAWDecoderPort.swift —— 新建（1 文件 ≈ 60 行）
import Foundation
import GatherProtocol

/// RAWDecoder 的端口适配（唯一允许知道 RAWDecoder 的地方）。
public struct RAWDecoderPort: ImageDecoderPort {
    public init() {}
    public var supportedExtensions: Set<String> { RAWDecoder.supportedExtensions }

    public func thumbnail(path: String, size: Int, preview: Bool) throws -> DecodedImage {
        let r = preview
            ? try RAWDecoder.getPreview(path: path, maxDimension: size)
            : try RAWDecoder.getThumbnail(path: path, size: size)
        return DecodedImage(buffer: r.buffer, format: r.format, width: r.width, height: r.height)
    }

    public func region(path: String, normalizedRect: NormalizedRect, maxPixel: Int) throws -> DecodedRegion {
        let r = try RAWDecoder.decodeRegion(
            path: path,
            normalizedRect: CGRect(x: normalizedRect.x, y: normalizedRect.y,
                                   width: normalizedRect.width, height: normalizedRect.height),
            maxPixel: maxPixel)
        return DecodedRegion(buffer: r.buffer, regionWidth: r.regionWidth, regionHeight: r.regionHeight,
                             fullWidth: r.fullWidth, fullHeight: r.fullHeight)
    }
}
```

- `RAWDecoder` / `RAWDecodeResult` / `RAWRegionDecodeResult` **留在 Analysis 不动**（Host 仍在用 `getDimensions`/`pixels9x8`/`supportedExtensions`：`LivePhotoAPI:99/114`、`AppComposition:206/255/271/295`、`GatherAppDelegate:55/85/469`）。
- 这样 Analysis 对 UI 的暴露面从 **3 类型 / 6 符号** 收敛为 **0**。

### 3.4 Host 注入（三个时机，缺一不可）

缩略图解码是**静态热路径**（`PhotoThumbnailDecoder` 是 `enum`，无实例），因此端口必须可静态取用。方案 = **注册表 + 测试注入**：

```swift
// GatherUI/Support/ImageDecoderRegistry.swift —— 新建（1 文件 ≈ 30 行）
public enum ImageDecoderRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: (any ImageDecoderPort)?
    public static func install(_ port: any ImageDecoderPort) { lock.lock(); installed = port; lock.unlock() }
    public static func current() -> (any ImageDecoderPort)? { lock.lock(); defer { lock.unlock() }; return installed }
    /// 测试/Preview 用：未注入时抛出而不是静默退化。
    static func require() throws -> any ImageDecoderPort {
        guard let port = current() else { throw ImageDecoderError.notInstalled }
        return port
    }
}
```

| 注入点 | 位置 | 时机 | 失败语义 |
| --- | --- | --- | --- |
| 生产 | `AppComposition.make(database:)` 末尾（`Host/AppComposition.swift`） | 早于任何视图渲染（`bootstrap` 在建 composition 后才 set `appServices`，`GatherApp.swift:215-221`） | 不注入 → 缩略图抛 `.notInstalled`，图库显示占位符 + 一条 error 日志（**不静默**） |
| 测试 | `GatherAppTests/Support/StubImageDecoder.swift`（新建，返回固定 JPEG 字节） | setUp 注入、tearDown 清空 | +1 测试支撑文件 |
| Preview | `#Preview` 内注入 `StubImageDecoder` | 不触发 CoreML（v1 R-10 的约束） | — |

> 备选（更纯但更贵）：把端口作为 `@Environment(\.imageDecoder)` 传入 `PhotoThumbnailView`，静态方法改成实例方法 → 要改 `GalleryView.swift:1262`、`PhotoThumbnailView:247/432/704` 与 3 个测试文件的调用点（约 8 处），且 `PhotoThumbnailDecoder` 的 `static` 语义（`:559-577` 的 gate 去重）要重构。**Cut 3 不推荐**；记 Cut 4 的 `ThumbnailLoader`（CL-07）一起做。

### 3.5 UI 侧替换签名（before → after）

| 位置 | before | after |
| --- | --- | --- |
| `:535-543` `decodeUncached` | `let decoded: RAWDecodeResult` + `RAWDecoder.getPreview/getThumbnail` | `let decoded: DecodedImage = try ImageDecoderRegistry.require().thumbnail(path: path, size: size, preview: preview)`（两个分支合一，**3 行 → 1 行**） |
| `:606` `decodeRegionAsync` 返回类型 | `RAWRegionDecodeResult` | `DecodedRegion` |
| `:623-633` `decodeRegion` | `RAWDecoder.decodeRegion(path:normalizedRect:maxPixel:)` | `ImageDecoderRegistry.require().region(path:normalizedRect: NormalizedRect(...), maxPixel:)` |
| `:704` `PhotoDetailTileView` | `decoded.buffer`（`RAWRegionDecodeResult`） | `decoded.buffer`（`DecodedRegion`，字段同名 → 0 改动） |
| 文件头注释 `:2/:4/:240` | "原生 RAWDecoder 的 SwiftUI 适配" | "图像解码端口（ImageDecoderPort）的 SwiftUI 适配" |

**净改动**：UI 1 文件（~10 行）+ Protocol 1 新建 + Analysis 1 新建 + Host 1 文件 2 行 + 测试 1 新建。
**回归风险**：`PhotoThumbnailDecoder.decode(path:size:preview:)`（`:531`，同步）与 `decodeRegionAsync` 的签名是 `public`，【已确认】调用方只有 `PhotoThumbnailView` 自身与 `GalleryView.swift:1262`（后者只调 `decodeAsync`，签名不变）；`ReviewFixTests.swift:886/899` 只用 `PhotoDecodeGate`（不受影响）。

### 3.6 为什么否决"允许 UI→Analysis 白名单"（v1 的推荐 (a)）

v1 §10 D-013 推荐 (a)：白名单放 `RAWDecoder`/`ImageDimensions`。**实测发现该白名单不成立**：

1. 白名单需要 **3 个符号**，不是 2 个（`RAWDecodeResult`、`RAWRegionDecodeResult` 都是 public 且出现在 UI 的 `public` 签名里）——`:606`/`:627` 的返回值类型写进了 UI 的公开 API。
2. 白名单是**符号级**约束，但 `--explicit-target-dependency-import-check` 是**模块级**；脚本无法区分"import 了 Analysis 但只用白名单符号"，只能事后 grep，**不是编译期门禁**（违反 I-04）。
3. D-014 已裁决走端口。本文件与 D-014 一致。

---

## 4. E-03：`GatherCoreHelper` / `IPC` 生产与测试调用审计

### 4.1 调用方矩阵（全仓，含脚本/CI/文档）

| 调用方 | 位置 | 类型 |
| --- | --- | --- |
| **唯一生产调用** | `Sources/GatherCoreHelper/main.swift:25`：`HelperProtocol.handleLine(line)` | 可执行自身 |
| 测试 | `Tests/GatherCoreTests/IPC/HelperProtocolTests.swift`（270 行，**15 个用例**：echo / 未知命令 / dimensions / thumbnail / preview / 空行 / 非法 JSON / session:mock） | 测试 |
| 测试 | `Tests/GatherCoreTests/HelperMessageTests.swift`（38 行，4 用例：`HelperWire` 编解码） | 测试 |
| app（Sources/Tests） | **0** | — |
| benchmarks | **0** | — |
| 脚本 / CI / build.sh | **0**（只有 `Package.swift:43` 声明 product） | — |
| 文档 | 仅 [module-split-map.md](module-split-map.md) 与 [refactor-decisions.md](../../refactor-decisions.md) D-016 | — |
| 外部工具 | **未知**（线协议无版本号、无握手、无 `--version`） | 【疑似】 |

### 4.2 为什么它现在"卡"在两个 target 之间

| 文件 | 依赖 | 拆分后归属 |
| --- | --- | --- |
| `IPC/HelperMessage.swift`(37) | 仅 Foundation（`HelperWire` 编解码） | 只有 Protocol 合理 |
| `IPC/HelperProtocol.swift`(84) | **`SessionData`**（Protocol，`mockSession:9-22`）+ `ImageCommands` | 若进 Protocol → Protocol 反向依赖 Analysis（非法） |
| `IPC/ImageCommands.swift`(138) | **`ImageDimensions`**（Analysis）+ **`RAWDecoder`**（Analysis） | 只能进 Analysis → helper 连带链接 **CoreML/Vision/CoreImage** |

即：**三个文件要拆成两个 target 才能各就各位**，而 D-015 只允许 7 个产品 target + 工具可执行。这是"为了一个零调用方的冒烟工具，付出一个额外 target 或一条越界边"的典型。

### 4.3 结论：**删除**（D-016 的"若无生产调用即删除"条件已满足）

**理由**

1. **生产调用方 = 0**：唯一调用者是 helper 自己的 `main.swift`；app、benchmarks、脚本、CI 全部 0。
2. **线协议无版本号、无握手、无 `--version`**：即使有外部调用者，也无法协商格式——留着它等于承诺一个无法演进的接口。
3. **它是 E-03 的唯一来源**：删掉后 `IPC/` 消失，Analysis 的 import 面收敛为 `GatherProtocol` + 系统框架，**I-03 从"grep 技巧"变成"结构事实"**。
4. **删除成本最低**：6 文件 / 597 行，其中 308 行是测试（`HelperProtocolTests` 的 15 个用例测的是"helper 自己"）。
5. **`session:mock` 只为冒烟**：它构造的 `SessionData` 是唯一让 HelperProtocol 依赖 Protocol 的东西，本身没有产品价值。

**反证（必须写进 PR 描述）**

- 若有仓库外工具调用 `gather-core-helper`，删除会破坏它。缓解：**3a 第一刀先加 `--version` 输出并在 `docs/DEVELOPMENT.md` 公告一个 Cut 周期**，3a 结束前删除；或按 §4.4 的 Plan B 保留。
- 该二进制**不在** app bundle 内、**不**被 `build.sh` 复制，因此删除**不影响发布产物**（【已确认】`build.sh` 只 cp `gather-app` 可执行 + 2 个 resource bundle）。

**删除清单（6 文件 / 597 行）**

| 文件 | 行 |
| --- | ---: |
| `Sources/GatherCore/IPC/HelperMessage.swift` | 37 |
| `Sources/GatherCore/IPC/HelperProtocol.swift` | 84 |
| `Sources/GatherCore/IPC/ImageCommands.swift` | 138 |
| `Sources/GatherCoreHelper/main.swift` | 30 |
| `Tests/GatherCoreTests/IPC/HelperProtocolTests.swift` | 270 |
| `Tests/GatherCoreTests/HelperMessageTests.swift` | 38 |
| **合计** | **597** |

连带：`Package.swift` 删 `gather-core-helper` product 与 `GatherCoreHelper` target（−8 行）；`Tests/.../IPC/` 目录消失；测试计数 **−19 用例**（15 + 4）。

### 4.4 若必须保留（Plan B，仅当外部调用者被证实存在）

- `IPC/` 整体进 **GatherAnalysis**（v1 方案），helper 依赖 `GatherProtocol + GatherAnalysis`；
- `HelperProtocol` 的 `mockSession` 改为在 `HelperMessage.swift`（Protocol）里用 JSON 字面量构造，**去掉对 `SessionData` 的构造依赖**；
- 代价：helper 链接 CoreML/Vision（二进制 +~2MB 代码 + 模型加载路径），且 E-03 从"消除"降级为"合法化"。
- **裁决：不采用**。D-016 的条件已满足，Plan B 只在"外部调用者被证实"时启用。

### 4.5 3a 的落位（排期结论）

E-03 与 E-01/E-02 不同：**E-01/E-02 已经修完**（§2.3），所以 3a 的"修边"工作只剩 E-03（删除）与 E-04（3b）。这是本次审计最重要的排期结论：**3a 比 v1 估计的轻**（v1 的 3a-1 = 2.0 人日，含 E-01/E-02/E-03；现在只剩 E-03 的删除 + 目录搬迁）。

---

## 5. 测试：`GatherTestSupport`、单 target vs 四 target、app 测试依赖

### 5.1 现状（实测）

| 事实 | 数字 | 证据 |
| --- | ---: | --- |
| core 测试文件 | 96 | `find gather-core/Tests -name '*.swift'` |
| `@testable import GatherCore` | **94** 文件 | 全仓唯一 import 形态（无 plain `import GatherCore`） |
| `makeMigratedDB()` 调用文件 | **39**（v1 记 27，**已涨 44%**） | Database/Repositories 14 + Face 3 + Services 22 |
| `insertSession`/`insertPhoto` 调用文件 | 27 | Database 12 + Face 3 + Services 12 |
| 共享 fixture 定义 | `Tests/.../Database/Repositories/RepoTestSupport.swift`（108 行 / 9 个函数：`makeMigratedDB`、`insertSession`、`insertPhoto`、`insertAsset`、`insertAssetFile`、`insertTrackedFile`、`makeTempDir`、`writeTempFile`、`rowCount`） | 只 `exec(SchemaV1.sql)` |
| 另一共享 helper | `Tests/.../Support/AsyncGate.swift`（43 行，3 个 Domain 测试使用） | |
| app 测试 | 54（42 用例 + 12 Support），45 文件 `import GatherCore`，43 文件 `@testable import GatherApp` | |
| app 侧 DB 夹具 | `Tests/GatherAppTests/Support/TestDatabase.swift:12 makeGatherTestDB()`（同样只 exec SchemaV1.sql） | 与 core 的 `makeMigratedDB` **重复实现** |

### 5.2 `GatherTestSupport` 方案（`Tests/GatherTestSupport/`，library target）

**为什么用 `public` 而不是 `package`**

- v1 §6.3 建议 `package` 访问级。**但 `package` 要求所有使用方在同一 package 且由同一 `-package-name` 构建**：core 的测试都在同一 package（可行），**但 `GatherAppTests` 在另一个 package（gather-app）**，若将来复用就得复制第三份。
- 更关键：`GatherTestSupport` 是**普通 library target**（不是 testTarget），它对 `@testable` 的依赖隐式绑定 `-enable-testing` 构建标志，属于隐性耦合。
- **裁决：用 `public` + `import GatherPersistence`（非 @testable）**。全部 fixture 只碰 `DBConnection`/`DBStatement` 的 public API（【已确认】`DB.swift:180 prepare`、`:324 run`、`:340 get` 都是 `public`），无需 `@testable`。

**文件清单（2 移动，1 改名）**

```text
Tests/GatherTestSupport/
├── DatabaseTestSupport.swift   # 原 Database/Repositories/RepoTestSupport.swift（108 行）
└── AsyncGate.swift             # 原 Support/AsyncGate.swift（43 行）
```

**API 清单（签名只改访问级 + 去 @testable）**

```swift
import Foundation
import GatherPersistence

public func makeTestDatabase() throws -> DBConnection      // = 原 makeMigratedDB（D-003 改名）
public func insertSession(_ db: DBConnection, _ id: String) throws
public func insertPhoto(_ db: DBConnection, id: String, sessionId: String,
                        filepath: String? = nil, checksum: String = "") throws
public func insertAsset(_ db: DBConnection, id: String, status: String = "active") throws
public func insertAssetFile(_ db: DBConnection, id: String, normalizedPath: String,
                            checksum: String = "", volumeId: String = "dev:1",
                            fileIdentity: String = "", fileSize: Int64 = 0,
                            fileMtimeMs: Double = 0) throws
public func insertTrackedFile(_ db: DBConnection, id: String, storedPath: String,
                              statPath: String, checksum: String = "") throws
public func makeTempDir() throws -> String
public func writeTempFile(in dir: String, name: String, content: Data) throws -> String
public func rowCount(_ db: DBConnection, _ sql: String, _ values: [DBValue?] = []) throws -> Int

public actor AsyncGate { ... }                            // 原样（+ public）
```

**迁移顺序（硬约束，R-08 的正确形式）**

1. 建 target 与 2 个文件，**现有 39 个调用点先加 `import GatherTestSupport`**（不改函数名）→ 编译绿；
2. 全局改函数名 `makeMigratedDB → makeTestDatabase`（39 文件，机械）；
3. 删除旧 `RepoTestSupport.swift` 与 `Support/AsyncGate.swift`，删各自的 `@testable import GatherCore`（若该文件仅用于 fixture，则改成对应模块 import）。

> 顺序不可颠倒：**先 Support + import，再改名**。v1 的 R-08 就是这个意思，但 v1 没写"先加 import"这一步，直接改名会同时红 39 文件。

### 5.3 单 target vs 四 target：**Cut 3 选单 target（D-018 确认）**

| 维度 | 单 target（推荐） | 四 target（v1 推荐，延后 Cut 6） |
| --- | --- | --- |
| 文件移动 | 2 | 94 |
| `@testable` 改行 | 94（必须改，因为伞没了） | 94（还要按模块拆，且**跨模块 internal 不可见**） |
| `makeMigratedDB` 共享 | Support 一处搞定 | Support 一处搞定（**同样**需要） |
| 跨模块断言风险 | 0 | **高**：Domain 测试若断言 Persistence 的 internal 行为，必须拆成两个用例或提升可见性 |
| 编译隔离收益 | 0 | 改 Domain 只跑 28 文件（15,411 行）——**Cut 4/5 才有价值** |
| 失败模式 | "漏改 import" 单一类 | "漏改 import" + "target 依赖写错" + "fixture 找不到" 三类混合 |

**结论**：Cut 3 的**真实目标**是"生产依赖边界由编译器强制"，这由 `--explicit-target-dependency-import-check error` + 生产 target 拆分**已经达成**；测试 target 拆分只买到编译速度。当前 `makeMigratedDB` 的跨模块面是 **39 文件（v1 时 27）**，一次拆 4 个 target 的回归面比 v1 评估时**更大**。**Cut 3 = 单 target + GatherTestSupport；四 target 延后到 Cut 6（D-018 已裁决，本审计确认该裁决在当前数据下更成立）。**

> 若 owner 坚持四 target：切分表已现成（§1.3），额外成本 ≈ 3 人日（94 文件的模块归属 + 跨模块 internal 断言修复），且必须与 3a 同 PR（不能先拆 target 后改 import）。

### 5.4 app 测试依赖

```swift
.testTarget(
    name: "GatherAppTests",
    dependencies: [
        "GatherUI", "GatherHost",
        .product(name: "GatherProtocol", package: "gather-core"),
        .product(name: "GatherAnalysis", package: "gather-core"),   // DecodedImage / RAW 类型断言
    ],
    path: "Tests/GatherAppTests",
    swiftSettings: swift6Settings
)
```

**内部分组（按实测引用，非 v1 的估计）**

| 组 | 文件 | import | 成员 |
| --- | ---: | --- | --- |
| **Host 组** | 27 | `@testable import GatherHost`（+UI） | `AppCompositionTests`、`AppRuntimeTests`、`ExecutorRegistryTests`、`GatherAppDelegateTests`、`SidecarXMPProviderTests`、`C1PreflightTests`、`CullingSyncFlowTests`、`LayoutBudgetTests`、`RootViewTests`、`APICullingTests`、`APIDuplicateQualityTests`、`APIExportMetadataTests`、`APIFaceSimilarityTests`、`APIFaceUITests`、`APIPersonTemplateTests`、`APIPhotoTests`、`APISessionTests`、`B6bExportMetadataUITests`、`CullingViewModelAPITests`、`DuplicatesControlCenterAPITests`、`FaceKeywordingViewModelTests`、`FaceReclusterConfirmTests`、`GalleryViewModelTests`、`LibraryViewModelTests`、`ReviewAcceptanceTests`、`ReviewFixTests`、`SimilarityViewModelTests` |
| **UI 组** | 15 | `@testable import GatherUI` | `APIErrorPresentationTests`、`APISimilarityUITests`、`C1StatusCapsuleTests`、`DashboardViewModelTests`、`DeepModelAcceptanceTests`、`ErrorLocalizationCoverageTests`、`GlobalInfraTests`、`InboxItemsTests`、`IndexHeaderCopyTests`、`JustifiedLayoutTests`、`PersonsViewModelTests`、`SettingsCatalogTests`、`SettingsSaveSemanticsTests`、`StartupLanguageTests`、`WorkspaceStageMarksTests` |
| **Support 组** | 12 | 无 / `import GatherProtocol` | `AppLanguageLock`、`AsyncGate`、`AsyncWait`、`LockedBox`、`TestDatabase`、`StubAPIs`、`StubCullingAPI`、`StubExportMetadataAPIs`、`StubFaceAPI`、`StubSessionAPI`、`StubSettingsAPI`、`StubSimilarityAPI` |

> 与 v1 §6.6 的差异：v1 把 `APICullingTests` 等归 UI 组，**实测它们直接构造 `CullingService`/`JobService`/`DeliveryRepo`**（`APICullingTests.swift:99/117`、`APIDuplicateQualityTests.swift:30-32/67`）→ 归 **Host 组**（Host 才 import Domain/Persistence）。UI 组缩到 15。
> `Support/StubCullingAPI.swift:14` 有 `@testable import GatherApp`（v1 声称"Support 组无 app import"**已失真**）→ 拆分后改 `@testable import GatherUI` 或 `import GatherProtocol`。

---

## 6. `Package.swift` 草案

> 两个清单**原位重写**（路径不变）。保留：Swift 6 语言模式、CLT SwiftTesting 探测、Liquid Glass linker flags、`defaultLocalization`、deployment target 14.0。

### 6.1 `desktop/native/gather-core/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription
import Foundation

let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
// …（CLT SwiftTesting 探测原样保留：当前 Package.swift L13–32）

let package = Package(
    name: "gather-core",
    platforms: [.macOS(.v14)],
    products: [
        // 5 个 core 库（GatherUI/GatherHost/GatherApp 在 app 包）
        .library(name: "GatherProtocol",    targets: ["GatherProtocol"]),
        .library(name: "GatherPersistence", targets: ["GatherPersistence"]),
        .library(name: "GatherAnalysis",    targets: ["GatherAnalysis"]),
        .library(name: "GatherDomain",      targets: ["GatherDomain"]),
        // 工具可执行
        .executable(name: "gather-schema",          targets: ["GatherSchema"]),        // D-015
        .executable(name: "gather-core-benchmarks", targets: ["GatherCoreBenchmarks"]),
        .executable(name: "gather-face-benchmarks", targets: ["GatherFaceBenchmarks"]),
        // D-016：gather-core-helper / GatherCoreHelper target 删除
    ],
    targets: [
        // 0 依赖：DTO / API 协议 / GatherError / PhotoFileTypes / ImageDecoderPort / Logging
        .target(name: "GatherProtocol", swiftSettings: swift6Settings),

        // D-015：可执行工具，依赖 Persistence（DDL 的唯一真相源在 Persistence）
        .executableTarget(name: "GatherSchema",
                          dependencies: ["GatherPersistence"],
                          path: "Sources/GatherSchema",
                          swiftSettings: swift6Settings),

        .target(name: "GatherPersistence",
                dependencies: ["GatherProtocol", "CSQLite"],
                swiftSettings: swift6Settings),

        .target(name: "GatherAnalysis",
                dependencies: ["GatherProtocol"],
                resources: [.copy("Resources/FaceModels")],
                swiftSettings: swift6Settings),

        .target(name: "GatherDomain",
                dependencies: ["GatherProtocol", "GatherPersistence", "GatherAnalysis"],
                swiftSettings: swift6Settings),

        .target(name: "CSQLite"),

        // 测试基建（非产品 target）
        .target(name: "GatherTestSupport",
                dependencies: ["GatherPersistence", "GatherProtocol"],
                path: "Tests/GatherTestSupport",
                swiftSettings: swift6Settings),

        .executableTarget(name: "GatherCoreBenchmarks",
                          dependencies: ["GatherProtocol", "GatherAnalysis"],
                          exclude: ["README.md"], swiftSettings: swift6Settings),
        .executableTarget(name: "GatherFaceBenchmarks",
                          dependencies: ["GatherProtocol", "GatherAnalysis"],
                          swiftSettings: swift6Settings),

        .testTarget(
            name: "GatherCoreTests",
            dependencies: ["GatherProtocol", "GatherPersistence", "GatherAnalysis",
                           "GatherDomain", "CSQLite", "GatherTestSupport"],
            path: "Tests/GatherCoreTests",
            exclude: ["Reconciliation/Fixtures", "Reconciliation/README.md"],
            swiftSettings: testSwiftSettings + swift6Settings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
```

### 6.2 `desktop/native/gather-app/Package.swift`

```swift
.target(
    name: "GatherUI",
    dependencies: [
        .product(name: "GatherProtocol", package: "gather-core"),
        // D-014 落地后**不需要** GatherAnalysis；若临时保留白名单才加
    ],
    path: "Sources/GatherUI",
    resources: [.process("Resources")],          // en.lproj / zh-Hans.lproj
    swiftSettings: swift6Settings
),
.target(
    name: "GatherHost",
    dependencies: [
        "GatherUI",
        .product(name: "GatherProtocol",    package: "gather-core"),
        .product(name: "GatherPersistence", package: "gather-core"),
        .product(name: "GatherAnalysis",    package: "gather-core"),
        .product(name: "GatherDomain",      package: "gather-core"),
    ],
    swiftSettings: swift6Settings
),
.executableTarget(
    name: "GatherApp",
    dependencies: ["GatherHost", "GatherUI"],
    path: "Sources/GatherApp",
    swiftSettings: swift6Settings,
    linkerSettings: liquidGlassLinkerSettings
),
.testTarget(
    name: "GatherAppTests",
    dependencies: ["GatherUI", "GatherHost",
                   .product(name: "GatherProtocol", package: "gather-core"),
                   .product(name: "GatherAnalysis", package: "gather-core")],
    path: "Tests/GatherAppTests",
    swiftSettings: swift6Settings
)
```

> `exclude: ["Tests","Resources/Info.plist"]` 与 `sources:[...]` 的显式列表在拆成 3 target 后不再需要（每 target 一个目录）；`Info.plist` 移 `Support/Info.plist` 后由 `build.sh` 单独 cp（§7.1）。`liquidGlassLinkerSettings` 只在最终可执行生效，放 `GatherApp` 即可。

### 6.3 target 属性表

| target | 类型 | 包 | 依赖 | 资源 | 备注 |
| --- | --- | --- | --- | --- | --- |
| GatherProtocol | lib | core | — | — | 0 依赖（Foundation-only） |
| GatherPersistence | lib | core | Protocol, CSQLite | — | 唯一 import CSQLite 的模块 |
| GatherAnalysis | lib | core | Protocol | `.copy("Resources/FaceModels")` | 唯一 CoreML/Vision/CoreImage 模块 |
| GatherDomain | lib | core | Protocol, Persistence, Analysis | — | |
| GatherUI | lib | app | Protocol | `.process("Resources")` | **不得** import Persistence/Domain/Host/Analysis |
| GatherHost | lib | app | UI + 4 core | — | 组合根，可 import 全部 |
| GatherApp | exec | app | Host, UI | — | 仅 `@main`+Scene |
| GatherSchema | exec | core | Persistence | — | `gather-schema dump|verify <db>` |
| GatherTestSupport | lib(test) | core | Persistence, Protocol | — | 非 product |
| GatherCoreHelper | **删除** | — | — | — | D-016 |

**7 个产品 target 的构成**（任务口径）：`GatherProtocol + GatherPersistence + GatherAnalysis + GatherDomain + GatherUI + GatherHost + GatherApp`；**工具可执行** = `GatherSchema` + 2 benchmarks。

### 6.4 `--explicit-target-dependency-import-check error`

- 语义（SE-0409）：target 只能 import 其**直接依赖**列出的模块；系统模块（Foundation/SwiftUI/CoreML…）不受限。
- 现状：**全仓 0 处**使用（`grep -rn 'explicit-target-dependency-import-check' scripts/ desktop/ .github/` = 0）。
- 接入点（4 处）：`build.sh:20`、`build.sh:21`、`ci.yml` 的 core 构建/测试、`ci.yml` 的 app 构建/测试。
- **分两步开**：**3a 结束 core 开 `error`**；**3b 结束 app 开 `error`**。理由：app 包在 3b 前仍是单 target，提前开 `error` 不会报错但会让"错误边界"延迟暴露；分两步可让两包红灯分离（core 的红是"分层写错"，app 的红是"UI 越界"）。

### 6.5 `GatherSchema` 落位：**与 v1 冲突，本次改判**

| 方案 | 做法 | 文件移动 | 问题 |
| --- | --- | --- | --- |
| v1（Schema 薄库） | `SchemaV1.swift`(768) + `Schema.swift`(19) 移 `Sources/GatherSchema/`；`Persistence → Schema` | **2 文件（787 行）** | 与 D-015 冲突（D-015 要求 Schema 是**可执行**） |
| 方案 X（库 + 第二个可执行） | Schema 薄库 + `GatherSchemaTool` | 2 移动 + 2 新建 | **8 个 target**，超出"7 个产品 target" |
| **本次（可执行，DDL 留 Persistence）** | 新建 `Sources/GatherSchema/main.swift`，依赖 `GatherPersistence`，提供 `dump`/`verify` | **0 移动 / 1 新建** | 无环；DDL 与 SQLite 同 target（可接受） |

**最终裁决**：`GatherSchema` = **可执行 target**（`Sources/GatherSchema/main.swift`），依赖 `GatherPersistence`，**不导出库**。这与 D-015 原文（"保留 GatherSchema 可执行 target…依赖 GatherPersistence"）完全一致，且不需要 `Persistence → Schema` 依赖，**无环**。DDL 的唯一真相源仍是 `GatherPersistence/Database/SchemaV1.swift`（768 行）与 `Schema.swift`（19 行）。

**代价**：`check-docs.sh` 的 `currentSchemaVersion` 入口路径变为 `Sources/GatherPersistence/Database/Schema.swift`（§7.2）；将来若写 `check-schema-v1.sh`，它必须扫 Persistence 而不是"不链接 SQLite 的独立 DDL 源"。

---

## 7. `build.sh` / CI / `scripts` 的硬编码路径清单与改法

### 7.1 `desktop/native/build.sh`（82 行）

| 行 | 现状 | Cut 3 后 | 动作 |
| ---: | --- | --- | --- |
| 20 | `swift build --package-path "$CORE_PACKAGE" -c "$CONFIGURATION"` | 追加 `--explicit-target-dependency-import-check error` | 改 1 行 |
| 21 | `swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION"` | 同上 | 改 1 行 |
| 37 | `cp "$APP_PACKAGE/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"` | `cp "$APP_PACKAGE/Support/Info.plist" …` | 改路径（Info.plist 必须移出 `Resources/`，否则 `.process("Resources")` 会把它塞进 SPM bundle） |
| 41 | `RESOURCE_BUNDLE="$BIN_DIR/gather-app_GatherApp.bundle"` | `gather-app_GatherUI.bundle`（**用 glob，见下**） | 改逻辑 |
| 42 | `CORE_RESOURCE_BUNDLE="$BIN_DIR/gather-core_GatherCore.bundle"` | `gather-core_GatherAnalysis.bundle`（glob） | 改逻辑 |
| 43-46 | assert `FaceModels/SFace.mlpackage` 存在（两种布局都查） | **不变**（相对路径不变） | — |
| 47-56 | `cp -R` 两个 bundle + 复制 `*.lproj` 到主 bundle | 不变（变量已改） | — |
| 58 | `echo "warning: SPM resource bundle not found…"` | `exit 1`（本地化缺失是发布阻断） | 改语义 |
| 新增 | — | assert `en.lproj/Localizable.strings` **与** `zh-Hans.lproj/Localizable.strings` 都存在 | +4 行 |

**glob 化（不写死 target 名，R-01 的对策）**

```bash
find_bundle() {   # $1 = 包名前缀
  local hits; hits=$(find "$BIN_DIR" -maxdepth 1 -type d -name "$1_*.bundle" | sort)
  local n; n=$(printf '%s\n' "$hits" | grep -c . || true)
  if [ "$n" -ne 1 ]; then
    echo "expected exactly 1 bundle matching $1_*.bundle, got $n" >&2; return 1
  fi
  printf '%s\n' "$hits"
}
RESOURCE_BUNDLE=$(find_bundle gather-app)          # gather-app_GatherUI.bundle
CORE_RESOURCE_BUNDLE=$(find_bundle gather-core)    # gather-core_GatherAnalysis.bundle
```

### 7.2 `scripts/`（9 个脚本，逐行实测）

| 脚本 | 行 | 现状 | Cut 3 后 | 动作 |
| --- | ---: | --- | --- | --- |
| `check-no-legacy.sh` | 77, 79 | `"$CORE/Sources/GatherCore/Services"` | `"$CORE/Sources/GatherDomain/Services"` | 改 2 处路径；规则不变 |
| `check-cleanup-ratchet.sh` | 7, 26, 27, 64-65, 93 | `$CORE_SRC/GatherCore/Services`；`APP_FEATURE_SRC` 六个根级目录（`:26`） | `$CORE_SRC/GatherDomain/Services`；功能页并入 `$APP_SRC/GatherUI`（**删 `APP_FEATURE_SRC` 变量**） | 改变量 + **重生成 `docs/cleanup-baseline.json`**（扫描面从"Sources + 6 目录"变成"Sources + GatherUI"，`unchecked_sendable`/`try_optional` 数值可能变，`services_prepare` 应不变=126）→ **须 owner 签字**（D-006 口径） |
| `check-docs.sh` | 22 | `Schema.swift` 在 `Sources/GatherCore/Database/` | `Sources/GatherPersistence/Database/Schema.swift` | 改路径 |
| `check-docs.sh` | 23 | `MIGRATION_FILE=…/Database/Migrations.swift` | **删除**（文件已不存在 → 当前是死路径） | 删 1 行 + 删 `:94-97` 的 fallback 分支 |
| `check-docs.sh` | 56-57 | `BASES` 含 `Sources/GatherCore` / `Sources/GatherApp` | 改为 5 个 core target 根 + `Sources/GatherUI`/`GatherHost` | 改数组（否则 ADR 里所有 `Sources/GatherCore/...` 路径都被判缺失，`--strict` 变红） |
| `check-layering.sh` | 19-22, 60-68 | 目录探测：`$APP_SRC/GatherUI`、`$CORE_SRC/{GatherAnalysis,GatherDomain,GatherPersistence}` | 路径**天然正确**（拆分后目录就绪即自动启用）；需**补 3 条规则**：① UI 禁 import Analysis（D-014 落地后）；② UI 禁 import Host；③ 所有 target 禁 import GatherCore | +8 行；白名单表见 §1.1 |
| `check-select-star.sh` | 25-28, 32 | `CORE_SRC/APP_SRC/CORE_TESTS/APP_TESTS` + `AnalysisJobRepoTests.swift` 白名单 | 路径不变（都是包级 `Sources`/`Tests`）；白名单文件仍在 `Tests/GatherCoreTests/Database/Repositories/` | **0 改动** |
| `check-test-catalog.sh` | 19-20 | `TEST_ROOTS` 两个 `Tests` 根 | 不变；需把 `Tests/GatherTestSupport` 加进 `TEST_ROOTS`（否则新文件不查文件头） | +1 行 |
| `check-duplicate-symbols.sh` | 35 | `find "$ROOT/desktop/native"` | 不变 | **0 改动** |
| `convert-face-model.py` | 23 | `…/Sources/GatherCore/Resources/FaceModels` | `…/Sources/GatherAnalysis/Resources/FaceModels` | 改 1 处 |

### 7.3 `.github/workflows/ci.yml`（80 行）

| 事实 | 证据 | 改法 |
| --- | --- | --- |
| **CI 只跑 `check-no-legacy.sh`** | `ci.yml:24` | **新增 `gates` job**：串 `check-layering.sh`、`check-cleanup-ratchet.sh`、`check-docs.sh --strict`、`check-test-catalog.sh`、`check-select-star.sh`、`check-duplicate-symbols.sh`。**本次审计发现的门禁空档：5 个脚本有实现但都不在 CI 里跑** |
| 包路径 | `ci.yml:43/45/63/65/77/79` | 不变 |
| 无 `--explicit-target-dependency-import-check` | 全仓 0 处 | core job（`:43/45/77`）3a 加；app job（`:63/65/79`）3b 加 |
| 缓存 key 只看 `Package.swift` | `ci.yml:40/60` | 拆分后 `Package.swift` 变化 → key 自动变；建议 key 追加 `hashFiles('desktop/native/gather-core/Tests/GatherTestSupport/**')`（可选） |
| 平台 | `macos-14` | `GatherAnalysis` 的 CoreML 单测需要 macOS 14+（现状已满足） |

> 本地沙箱构建/测试必须带 `--disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch`；**不要**把这三个 flag 写进 CI（避免掩盖 GitHub runner 上的 sandbox 错误）。

### 7.4 门禁接线总表（Cut 3 结束时）

| 门禁 | 本地 | CI | 判据 |
| --- | --- | --- | --- |
| `--explicit-target-dependency-import-check error` | `build.sh:20/21` | core 3 处 + app 3 处 | 任一越界 import → 编译失败 |
| `check-layering.sh` | ✅ | **新增** | UI 不得 import Persistence/Domain/Host/Analysis |
| `check-no-legacy.sh` | ✅ | ✅（已有） | 7 条 enforced = 0 |
| `check-cleanup-ratchet.sh` | ✅ | **新增** | 5 指标不高于 baseline |
| `check-docs.sh --strict` | ✅ | **新增** | ADR 路径存在 + schema 版本一致 |
| `check-select-star.sh` / `check-test-catalog.sh` / `check-duplicate-symbols.sh` | ✅ | **新增** | 0 / 文件头齐全 / 0 重复 |

---

## 8. 3a / 3b 分步计划（每步含验收命令与改动文件数）

### 8.1 3a（core）：6 步

| 步 | 内容 | 改动文件 | 验收命令 | 并行性 |
| --- | --- | ---: | --- | --- |
| **3a-0** | 删除 E-03：6 文件 / 597 行 + `Package.swift` 的 helper product/target | 8 | `swift build --package-path desktop/native/gather-core`；`grep -rn 'HelperProtocol\|HelperMessage\|ImageCommands' desktop/native/gather-core` = 0 | **必须先做**（后续 grep 基线依赖它） |
| **3a-1** | 建 5 个目录 + `git mv` 145 个生产文件（Protocol 66 / Persistence 30 / Analysis 18 / Domain 28 / 3 可执行原位） | 145 | `git status` 全 rename；`swift build` 暂红（预期） | 与 3a-2 **不可并行** |
| **3a-2** | 重写 core `Package.swift`（§6.1） | 1 | `swift build --target GatherProtocol` / `GatherPersistence` / `GatherAnalysis` / `GatherDomain` 逐个 exit 0 | **单人独占**（唯一全局冲突面） |
| **3a-3** | 修 core 内 `import`（94 个测试 `@testable` + 3 个可执行） | 97 | `grep -rn 'import GatherCore' desktop/native/gather-core` = 0 | 可与 3a-4 之外的工作并行 |
| **3a-4** | `GatherTestSupport`：建 target + 2 文件 + 39 个调用点加 import + 改名 | 2 新建 + 39 | `swift test --package-path … --filter Repo` | **不可与 3a-3 并行**（同 Test 树） |
| **3a-5** | FaceModels 随 Analysis + `import CSQLite` 只留 Persistence + 开 `error` | 1–3 | A-1/A-2/A-3（见下） | 收口步 |

**3a 退出条件（逐条可粘贴）**

```bash
cd desktop/native/gather-core
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch \
            --explicit-target-dependency-import-check error                      # A-1
for t in GatherProtocol GatherPersistence GatherAnalysis GatherDomain; do
  swift build --target $t --explicit-target-dependency-import-check error      # A-2
done
swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch \
           --explicit-target-dependency-import-check error                       # A-3
grep -rn 'import GatherCore' desktop/native = 0                                  # I-01
grep -rnE 'DBConnection|prepare\(|import CSQLite' \
     desktop/native/gather-core/Sources/GatherAnalysis = 0                       # I-03
ls -d .build/*/gather-core_*.bundle && \
  ls .build/*/gather-core_GatherAnalysis.bundle/FaceModels/SFace.mlpackage       # I-05
./scripts/check-no-legacy.sh && ./scripts/check-cleanup-ratchet.sh               # A-9
```

### 8.2 3b（app）：7 步

| 步 | 内容 | 改动文件 | 验收命令 | 并行性 |
| --- | --- | ---: | --- | --- |
| **3b-0** | E-16/E-17/E-19 的**类型搬家**（先搬类型，不改调用）：`APIErrorPresentation`→UI、`SessionServiceError`/`C1PreflightStatus`/`CaptureOneBridgeError`→Protocol、`CaptureOneBridging` 协议 + conformance | 2 core + 4 app | `swift build`（此时仍是单 target，绿是必须的） | 可与 3b-1 并行 |
| **3b-1** | E-20：`AppBootstrap.swift` + `AppImport.swift` 抽出，`GatherApp.swift` →`@main`+Scene | 1 拆 3 | `swift build`；`GatherAppDelegateTests` 改 `@testable import GatherHost` 后绿 | **高风险**（唯一启动路径） |
| **3b-2** | 建 `Sources/GatherUI`/`GatherHost`，`git mv` 27+29+6+1 文件 + `Resources/*.lproj`→UI + `Info.plist`→`Support/` | 64 | `swift build --target GatherUI` 单独过 | **不可并行**（清单 + 目录） |
| **3b-3** | 重写 app `Package.swift`（§6.2）+ UI 侧 12 文件的边界修复（E-16/E-17/E-18/E-19） | 1 + 12 | A-5：`swift build --target GatherUI --explicit-target-dependency-import-check error` | **单人独占** |
| **3b-4** | E-04：`ImageDecoderPort` + `RAWDecoderPort` + 注册表 + `PhotoThumbnailView` 3 点 | 5 | `grep -rn 'RAWDecoder' Sources/GatherUI` = 0 | 与 3b-3 后半段串行（同文件） |
| **3b-5** | `GatherAppTests` 改 import/path + 分组（§5.4） | 43 | `swift test --package-path desktop/native/gather-app --no-parallel` | 可与 3b-4 并行（不同树） |
| **3b-6** | `build.sh` glob + 硬断言、5 个 scripts 路径、CI 加 flag 与 5 个门禁 | 8 | A-10：`./desktop/native/build.sh` + `ls release/Gather.app/Contents/Resources/` | **单独 commit**（只回滚打包逻辑） |

**3b 退出条件**

```bash
cd desktop/native/gather-app
swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch \
            --target GatherUI --explicit-target-dependency-import-check error     # A-5
swift build --explicit-target-dependency-import-check error                       # A-4
swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
grep -rnE '^[[:space:]]*import[[:space:]]+(GatherPersistence|GatherDomain|GatherHost|GatherAnalysis)' \
     desktop/native/gather-app/Sources/GatherUI | wc -l                            # A-6 = 0
grep -rn 'RAWDecoder' desktop/native/gather-app/Sources/GatherUI | wc -l           # E-04 = 0
./desktop/native/build.sh                                                        # A-10
ls release/Gather.app/Contents/Resources/gather-core_GatherAnalysis.bundle/FaceModels/SFace.mlpackage
ls release/Gather.app/Contents/Resources/gather-app_GatherUI.bundle/{en,zh-Hans}.lproj/Localizable.strings
```

### 8.3 不可并行 / 高风险清单

| 步 | 类别 | 理由 |
| --- | --- | --- |
| 3a-2、3b-3 | **单人独占（Build owner）** | 两个 `Package.swift` 是唯一全局冲突面（v1 §7.3 已识别） |
| 3a-3 ↔ 3a-4 | **串行** | 94 文件改 import 与 39 文件加 import 重叠在同一 Test 树 |
| 3a-0 | **必须先做** | 删除 IPC/helper 会改变后续所有 grep 的基线（否则 `HelperProtocol` 会一直出现在越界扫描里） |
| 3b-1 | **高风险** | bootstrap 是唯一启动路径，失败表现是"启动停在初始化中…"，**无自动化覆盖** |
| 3b-4 | **中高风险** | 缩略图热路径 + 静态注册表（`nonisolated(unsafe)`），失败表现是"图库全占位符" |
| 3b-3 的 E-18 | **中风险** | 12 个 `as? Live*API` 下转改协议；失败表现是静默 `APIError.failed("…_NOT_SUPPORTED")` |
| 3b-6 | **单独 commit** | 便于出问题时只回滚打包逻辑（v1 §7.5 建议保留） |
| 3a-3 ↔ 3b-5 | 可并行 | 不同包、不同树 |

### 8.4 排期（1 人，按本次实测文件数）

| 阶段 | 人日 | 依据 |
| --- | ---: | --- |
| 3a-0（删 helper/IPC） | 0.3 | 6 文件删除 + 2 处清单 |
| 3a-1/3a-2（搬 145 文件 + 清单） | 1.0 | 机械 |
| 3a-3（97 文件 import） | 0.5 | codemod |
| 3a-4（TestSupport） | 0.7 | 39 文件 |
| 3a-5（资源 + error 收口） | 0.5 | |
| **3a 小计** | **3.0** | v1 估 5.5（含 E-01/E-02，已由 Cut 2 完成） |
| 3b-0（类型搬家） | 0.5 | |
| 3b-1（E-20 抽 bootstrap） | 1.0 | 310 行迁移 + 测试 |
| 3b-2（搬 64 文件） | 0.7 | |
| 3b-3（清单 + 12 文件边界） | 1.3 | E-18 是主要不确定性 |
| 3b-4（E-04 端口） | 0.7 | |
| 3b-5（43 测试 import） | 0.5 | |
| 3b-6（build/CI/scripts） | 0.8 | |
| **3b 小计** | **5.5** | v1 估 4.0（低估了 Cut 1 引入的 UI 侧 12 文件边界） |
| **合计** | **8.5** | v1 估 9.5 |

---

## 9. 风险

| ID | 风险 | 触发 | 影响 | 概率 | 检测 | 对策 |
| --- | --- | --- | --- | --- | --- | --- |
| **R-01（最大）** | **UI 侧 12 个文件的边界没修就开拆分**（11 个 UI→Host + 1 个 UI→Domain） | 3b-2/3b-3 顺序颠倒；或只修 `APIErrorPresentation` 就以为够了 | `GatherUI` 编译不过；`Host↔UI` 成环 → SwiftPM `cyclic dependency`，整个 app 包无法 `describe` | **高** | `swift build --target GatherUI`（A-5）、`swift package describe` | 3b-0 先做"类型搬家"（4 类），3b-3 再切目录；**E-18 的 12 处 `as? Live*API` 是最后一道**，必须 grep 到 0 才能开 app `error` |
| **R-02** | `makeMigratedDB` 跨 39 文件（v1 时 27）抽取顺序错 | 先拆测试目录后抽 Support；或先改名后加 import | 39 文件同时红，错误全是 "cannot find 'makeTestDatabase' in scope"，与 import 错误混淆 | 高 | `swift test` 逐 target | 固定顺序：**建 target → 39 文件加 import（不改名）→ 绿 → 改名 → 绿 → 删旧文件**（§5.2） |
| **R-03** | 资源 bundle 改名后运行时找不到模型/本地化 | `.copy`/`.process` 跟错 target，或 `build.sh` 变量没改 | 启动即崩（人脸模型）或界面全空（无本地化）；**单测全绿也发现不了** | 中 | A-10 + 手工启动 | `build.sh` 用 glob + `warning`→`exit 1`；`Bundle.module` 全仓只有 2 处（`EmbeddingModel.swift:554`、`GatherLocalization.swift:51`），**各自跟着 Face→Analysis、Support→UI 走**，不跨 target |
| R-04 | E-20 的 bootstrap 拆分回归 | 3b-1 | 启动停在"初始化中…"或 `appServices` 永不赋值；**无自动化覆盖** | 中高 | 手工启动 + `AppRuntimeTests`/`AppCompositionTests` | 抽离时保持 `bootstrap()` 的 `async`/`MainActor` 语义逐字不变，只换文件位置；单个 commit |
| R-05 | 清理 ratchet 基线漂移 | `check-cleanup-ratchet.sh` 路径改 + `cleanup-baseline.json` 未重生成 | 门禁误报，团队开始忽略 | 高 | 跑一次 | 路径与 baseline 在同一 PR；PR 描述附旧/新 5 指标（当前 53/242/126/0/0） |

---

## 10. 待决事项（3a 动工前需签字）

| ID | 事项 | 选项 | 建议 |
| --- | --- | --- | --- |
| **Q-1** | `GatherCoreHelper` 是否有仓库外调用者 | (a) 无 → 删；(b) 有 → 保留（Plan B） | **(a)**：仓库内 0 调用；若不确定，3a 先发一版带 `--version` 的公告，下一 Cut 删 |
| **Q-2** | `GatherSchema` 形态（D-015 vs v1 薄库） | (a) 可执行 + DDL 留 Persistence；(b) 薄库 + 第 8 个可执行 target | **(a)**：与 D-015 原文一致、无环、0 文件移动 |
| **Q-3** | 测试 target | (a) 单 target + TestSupport；(b) 四 target | **(a)**（D-018 已裁）；数据支撑见 §5.3（39 文件 fixture 面） |
| **Q-4** | E-18 修法 | (a) 4 个 `Sync*API` 协议（0.5 人日）；(b) 3 个 `Live*DataProvider` 移 Host（2 人日） | **3b 用 (a)**；(b) 记 Cut 4（与 D-017 的 RootView 调整同批） |
| **Q-5** | 清理 ratchet 路径变更的 owner 签字 | — | 需确认 `services_prepare` 口径从 `GatherCore/Services` 改为 `GatherDomain/Services` 后**数值不变**（126），仅路径变 |
| **Q-6** | `APIErrorPresentation` 的最终归属 | (a) GatherUI（推荐）；(b) GatherProtocol | **(a)**：它依赖 `GatherLocalization`（UI）；放 Protocol 会把本地化拖进 Protocol |

---

## 附录 A：复现命令（本次审计实际执行）

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather

# 1) 全量计数（排除 .build）
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print | wc -l      # 364
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print0 \
  | xargs -0 wc -l | tail -1                                                       # 122692

# 2) 按目录（§1.2 的数据源）
for d in API Protocol Logging Database Face Image Concurrent Similarity IPC Services; do
  n=$(find desktop/native/gather-core/Sources/GatherCore/$d -name '*.swift' | wc -l)
  l=$(find desktop/native/gather-core/Sources/GatherCore/$d -name '*.swift' -print0 \
      | xargs -0 wc -l | tail -1 | awk '{print $1}')
  echo "$d files=$n lines=$l"
done
for d in Sources/GatherApp Sources/GatherApp/Host Sources/GatherApp/Host/APIs \
         Sources/GatherApp/Support Culling Settings Export Duplicates FaceKeywording ControlCenter; do
  echo "$d files=$(find desktop/native/gather-app/$d -maxdepth 1 -name '*.swift' | wc -l)"
done

# 3) 越界证据（§2.4）
cd desktop/native/gather-app
grep -rn 'APIErrorPresentation' --include='*.swift' Sources Culling Settings Export Duplicates \
  FaceKeywording ControlCenter | grep -v '/Host/'                     # 11 文件
grep -rn 'CaptureOneBridge' --include='*.swift' Sources Culling Settings FaceKeywording | grep -v '/Host/'
grep -rn 'as? Live' --include='*.swift' Sources | grep -v '/Host/'
grep -rn 'RAWDecoder' --include='*.swift' Sources/GatherApp/Support/PhotoThumbnailView.swift   # 3 点
cd ../gather-core
grep -rn 'PhotoFileTypes\|FileHasher' --include='*.swift' Sources      # E-01/E-02 已修

# 4) import 改造面（§2.5 / §5）
grep -rl 'import GatherCore' --include='*.swift' gather-app/Sources gather-app/Culling \
  gather-app/Settings gather-app/Export gather-app/Duplicates gather-app/FaceKeywording \
  gather-app/ControlCenter | wc -l                                                  # 53
grep -rl 'import GatherCore' --include='*.swift' gather-app/Tests | wc -l            # 45
grep -rl '@testable import GatherCore' --include='*.swift' gather-core/Tests | wc -l # 94
grep -rln 'makeMigratedDB' --include='*.swift' gather-core/Tests | wc -l             # 39

# 5) helper / IPC 调用面（§4）
grep -rn 'HelperProtocol\|HelperMessage\|ImageCommands' --include='*.swift' desktop/native \
  | grep -v '/IPC/'                                                                 # 1 生产 + 2 测试

# 6) 资源与 bundle 名（§7）
grep -rn 'Bundle.module' --include='*.swift' desktop/native | grep -v '/.build/'     # 2 处
grep -n 'bundle\|Info.plist' desktop/native/build.sh

# 7) 门禁现状
grep -rn 'check-layering\|check-cleanup-ratchet\|check-docs\|check-test-catalog\|check-select-star' \
  .github/workflows/ci.yml                                                           # 0 命中 = 未接 CI
grep -rn 'explicit-target-dependency-import-check' scripts/ desktop/ .github/        # 0 命中
```

## 附录 B：证据索引（越界点 → `file:line`）

| 编号 | 位置 | 证据 |
| --- | --- | --- |
| E-04-① | `gather-app/Sources/GatherApp/Support/PhotoThumbnailView.swift:538` | `decoded = try RAWDecoder.getPreview(path: path, maxDimension: size)` |
| E-04-② | 同上 `:540` | `decoded = try RAWDecoder.getThumbnail(path: path, size: size)` |
| E-04-③ | 同上 `:628` | `return try RAWDecoder.decodeRegion(path:normalizedRect:maxPixel:)` |
| E-04 类型泄漏 | 同上 `:536` `:606` `:627` | `RAWDecodeResult` / `RAWRegionDecodeResult` 出现在 UI 的 public 签名 |
| E-16 | `gather-app/Sources/GatherApp/Host/APIs/AppServices.swift:299-325` | `public enum APIErrorPresentation`（含 `:302` GatherLocalization、`:312` RouterCommandError） |
| E-16 消费 | `ControlCenter/SessionControlView.swift`、`Culling/CullingView.swift:239`、`Settings/SettingsView.swift:180` 等 11 文件 | `APIErrorPresentation.message(for:)` |
| E-17 | `Host/CaptureOneBridge.swift:49`（C1PreflightStatus）、`:95`（class）、`:100`（static shared） | |
| E-17 消费 | `Culling/CullingView.swift:122/188`、`FaceKeywording/FaceKeywordingView.swift:87`、`Settings/SettingsView.swift:109/165/485`、`Similarity/SimilarityViewModel.swift:121/200` | |
| E-18 | `Dashboard/DashboardViewModel.swift:82-83/92-103/118-126`、`Library/LibraryViewModel.swift:223/321-333` | `LiveSessionAPI`/`LiveJobAPI`/`LiveAlbumAPI`/`LiveAssetAPI` |
| E-19-① | `Support/GatherEventCenter.swift:94` | `public func wire(jobService: JobService)` |
| E-19-② | `Settings/SettingsView.swift:718` | `(SettingsService.getDefaults()[key] ?? "").isEmpty` |
| E-19-③ | `Dashboard/DashboardViewModel.swift:92-104` | `convenience init(sessionService:workspaceStatusService:jobService:)` |
| E-19-④ | `Library/LibraryViewModel.swift:775` | `error as? SessionServiceError` |
| E-20 | `Sources/GatherApp/GatherApp.swift:100-229 / 248-278 / 300-375` | bootstrap / embedding rerun / importFiles（共 ~310 行） |
| E-01 已修 | `Protocol/PhotoFileTypes.swift:17`；`Image/RAWDecoder.swift:197`；`Database/Repositories/AssetRepo.swift:1178`；`PhotoRepo.swift:157` | |
| E-02 已修 | `Database/FileHasher.swift:28`；`AssetRepo.swift:389`；`Services/IndexerService.swift:199-201` | |
| E-03 | `GatherCoreHelper/main.swift:25`；`IPC/HelperProtocol.swift:9-22`；`IPC/ImageCommands.swift` | |
| 测试硬阻断 | `Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift:12`（`makeMigratedDB`，39 文件调用） | |
| 门禁空档 | `.github/workflows/ci.yml:24`（只跑 `check-no-legacy.sh`） | |
| 死路径 | `scripts/check-docs.sh:23`（`Database/Migrations.swift` 已删除） | |
| bundle 名 | `build.sh:41-42`；`gather-app/Package.swift:78-91`（`sources` 显式 6 目录） | |
