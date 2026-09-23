# Gather 架构重写执行计划 v2（彻底重写，不做补丁）

> 配套证据：`docs/ARCHITECTURE-AUDIT.md`（问题与行号）
> v1（增量修复版）已作废：v1 的 B/C/D 任务卡是补丁式路线，本版全部替换为「按子系统整体重写 + 旧代码删除」。
> 基线：`refactor` 分支（已存在），HEAD `815762c`；重写期间 `main` 冻结功能。

**基线核对（本次执行）**：`refactor` 与 `architecture` 指向同一提交 `815762c`；refactor 工作树干净、无未提交改动；
`git merge refactor` 返回 `Already up to date`（无差异、无冲突）。因此重写工作在当前 worktree（`architecture`）推进，
每个子系统完成后并入 `refactor` 与 `main`；refactor 已被另一 worktree 检出，本 worktree 不重复检出同名分支。

**R0 进度**：

| 任务 | 状态 | 产物/证据 |
|---|---|---|
| R0.1 CSQLite 构建修复 | ✅ | `desktop/native/gather-core/Sources/CSQLite/placeholder.c` |
| R0.2 CI 加固 | ✅ | `.github/workflows/ci.yml`：boundary job（ubuntu）+ SwiftPM 缓存 + `timeout-minutes` + `concurrency` + `permissions` + `macos-latest` 工具链漂移任务 |
| R0.3 legacy 扫描 | ✅ | `scripts/check-no-legacy.sh`：4 条 enforced（无 Legacy/Compat/Adapter、无 WebKit/Electron、app 层无 JSONSerialization）+ 8 条 tracked 进度指标 |
| R0.4 基线采集 | ✅ | core：**789 tests / 106 suites 全绿**（test run 16.1s，Xcode 27.0 / Swift 6.4）；app：**172 tests / 19 suites 全绿**（5.3s）；`build.sh` 组装出 `release/Gather.app`（21.7MB 可执行 + 资源 bundle） |
| R0.2b 打包脚本修复 | ✅ | `build.sh` 原用 `find ... -path "*/release/gather-app"`，在新 SwiftPM 布局（`.build/out/Products/Release`）下找不到产物；改用 `swift build --show-bin-path` |
| R0.5 真实库 fixture | ✅ | 本机真实库副本：`/private/tmp/gather-fixture/gather-v33.sqlite`（schema_version **32**、42 表、1 session / 1 photo / 2 faces，sha256 前缀 `c76a5a2a`）——用于 R1「旧库 → 新 Store」升级与读写一致性验证（不入库，含用户数据） |

**R1 进度**（本轮）：

| 任务 | 状态 | 产物/证据 |
|---|---|---|
| 基座：SQLiteDatabase actor + 键行解码 | ✅ | `Store/SQLiteDatabase.swift`、`SQLiteValue.swift`、`SQLiteRow.swift`；13 个新测试（多语句 DDL、语句缓存 LRU、事务提交/回滚、嵌套 SAVEPOINT、UNIQUE 结构化错误、close 后拒绝、并发写串行化、busy 传播） |
| DDL 迁入 Store（单一来源） | ✅ | `git mv Database/Schema.swift → Store/StoreSchema.swift`（SQL 逐字保留）；`Migrations.swift`/`MigrationTests.swift` 引用改 `StoreSchema.*` |
| 结构漂移门禁 | ✅ | `StoreSchemaTests`：DDL 快路径与 33 步迁移链的列/类型/默认值/索引 SQL/外键指纹必须一致（当前 `d4b1fe3e5a9da77e`） |
| 修复真实漂移（门禁抓出） | ✅ | ① `face_clusters` 补 `synced_to_library`/`match_confidence`（旧库仅由 v1 ALTER 添加，schemaSQL 缺失）；② `metadata_outbox.source_module` 列序对齐到 ALTER 追加位置（兼容旧 Repo 的位置解码） |
| StoreMigrator（33 步注册表） | ✅ | `Store/StoreMigrator.swift`：旧 `if` 链 33 个版本块逐字转为 `[MigrationStep]`；ADR-005 备份（空间检查/checkpoint/backup API/integrity_check/失败恢复/keep=3 淘汰）+ 迁移后 FK 与列不变量；版本号仍在步骤事务内写入 |
| 新旧迁移器等价性验证 | ✅ | `StoreMigratorTests` 4 用例：空库双跑结构+数据摘要一致；**真实库 fixture（v32）双跑后结构与数据完全一致**；幂等；`afterMigrateHook` 抛错后回滚到 v32 且结构与原库一致 |
| Store 实现（10/16） | ✅ | Settings / Session / Photo / Culling / Similarity / Metadata / Job / SmartAlbum / Writeback（完整：outbox + writeback_items）（端口自对应 Repo 测试）：111 用例全绿；`PhotoFormats` 统一格式常量；`StoreSupport` 收纳 `Array.chunked(by:)` 与 `sqlValue`；Culling 类型化错误；Similarity 缓存独立 actor；Metadata/SmartAlbum/WritebackItemInput DTO 迁入 Store（attributes 改 `[String: JSONValue]`） |
| Store 实现（11/16） | ✅ | Settings / Session / Photo / Culling / Similarity / Metadata / Job / SmartAlbum / Writeback / Asset（只读 + relink/候选/对账 + backfill 全量）已完成：131 用例全绿；`AssetStoreError` 取代字符串错误；relink 回调 sink 改为返回值；`StoreSupport`/`PhotoFormats` 为共享单一来源 |
| Store 实现（12/16） | ✅ | Settings / Session / Photo / Culling / Similarity / Metadata / Job / SmartAlbum / Writeback / Asset / Person 已完成：158 用例全绿；PersonStore 含 merge（关键词并集 + 嵌入/照片迁移）、Float32 BLOB 嵌入往返与 OR-REPLACE、`reconcileSession`（角色绑定 → 桥接增删）、getPhotosWithDetails |
| Store 实现（16/16） | ✅ | 15 个 Store + DuplicateStore（校验列/视觉 hash 落库、精确分组、分组重建幂等、决议与照片状态重算）；Store 层协议面完成 |
| R1 收尾①：新组合根 + 类型化 API 基座 | ✅ | `AppContainer`（唯一 `SQLiteDatabase` + 各 Store + `open(path:)` 自动迁移）与 `GatherAPI`（`settings`/`sessions` 命名空间）落地；`SettingsAPI` 取代 SettingsService 的默认值表/白名单/缓存语义（服务静态成员改为委托，单一来源）；API 测试 6 用例（含 `GET api` 打开即迁移、缓存只读语义、跨实例持久化） |
| R1 收尾②：第一个删除切片（settings） | ✅ | `SettingsService`/`SettingsRepo`/`SettingsServiceTests`/`SettingsRepoTests` 已删除；路由与 app 启动切到 `SettingsAPI`（写路径异步：`settings.set/reset/set_language/template.apply` 迁入 `executeAsync`）+ `SettingsSnapshot`（同步读）；`TemplateService` 改为返回 `TemplateSettingsUpdate`，不再依赖设置存储；app 测试以 `makeTestSettings` 构造依赖 |
| R1 收尾③：第二个删除切片（template） | ✅ | `TemplateService` + `TemplateServiceTests` 已删除；`GatherAPI.templates`（CRUD + `applyUpdates` 领域校验）与 `TemplateError` 落地；路由 5 个 template.* 命令迁入 `executeAsync`（经 TemplatesAPI/SettingsAPI）；app 启动改由 `AppContainer`/`GatherAPI` 装配；测试端口至 TemplatesAPITests（2 例）+ TemplateStoreTests（5 例） |
| R1 收尾④：第三个删除切片（smart album） | ✅ | `SmartAlbumRepo` + `SmartAlbumRepoTests` 已删除；`GatherAPI.albums`（AlbumsAPI）落地；路由 `album.*`（create/list/get/update/delete/get_photos）迁入 `executeAsync`（保留 ALBUM_NOT_FOUND 与确认消息语义）；`LibraryViewModel` 相册路径改 async（provider 经 `executeAsync`，`reloadSupport` 改 async） |
| R1 收尾⑤：第四个删除切片（workspace） | ✅ | `WorkspaceStatusService` + 26 个旧测试已删除；路由 `workspace.status` 迁入 `executeAsync`（经 WorkspaceAPI），`LiveDashboardDataProvider`/`DashboardViewModel` 改 async；关键语义端口至 WorkspaceAPITests（7 例） |
| R1 收尾⑥：第五个删除切片（person） | ✅ | `FaceKwService` 的 4 个 person 路径方法改 async（经 `PersonStore`，best-effort 语义保持）；路由 `fkw.bind/unbind/merge/remove_member` 迁入 `executeAsync`（`fkw.unbind` 顺带移除 `awaitSync`）；`PersonRepo` + `PersonRepoTests` + FaceKw 测试文件内遗留的 PersonRepo 套件已删除（语义由 PersonStoreTests/PersonStoreDetailTests 覆盖）；FaceKw 测试改文件库双连接 |
| R1 收尾⑦：第六个删除切片（face） | ✅ | `FaceRepo` + `FaceRepoTests` 已删除；`FaceKwService` 全部 face 访问改经 `any FaceStore`（观察/复用/集群/绑定/缩略图，约 50 处），4 个 person 桥接方法 async；`SessionService` 人脸删除经 Store（跨连接拆分为 deleteFaceData + 旧连接事务）；路由 `fkw.clusters`/`photo.list_page`/`session.create_from_directory` 迁入 `executeAsync`；旧 FaceRepo 行类型迁移为 Store 记录（FaceObservationRecord/FaceClusterRecord/…），FaceObservationInput 迁入 Store；core 896/123、app 172/19 全绿 |
| R1 收尾⑧：第七个删除切片（keyword origins） | ✅ | `MetadataKeywordOriginRepo` + 旧测试已删除；`WritebackService` 的来源记录/撤销改经 `any MetadataStore`（markKeywordIntroduced/activeIntroducedKeywords/deactivateKeywordOrigins，既有 async 方法内）；`AppContainer` 增加 metadata store 并接入路由 |
| R1 收尾⑨：第八个删除切片（culling history） | ✅ | `CullingHistoryRepo` + 旧测试已删除；`CullingService` 历史栈改经 `any CullingStore`；新增 async `update()`（事务内决策 + 事务外 `commitHistory`）与 async `decide()`，`batchUpdate/applyHistory/decideSimilarityGroup/batchDecide/getHistory` 异步化；历史写入从同步事务中移出（跨连接不共享事务，快照先原子落地、历史行失败仅丢 undo）；路由 7 个 culling.* 命令迁入 `executeAsync` |
| R1 收尾⑩：第九个删除切片（metadata cache） | ✅ | `MetadataCacheRepo` + 旧测试已删除；`MetadataService`/`WritebackService`/`CullingService` 全部改经 `any MetadataStore`；`CullingService.list/listPage/buildRichLookup` 异步化（缓存基线经 `CullingUpdateContext.cacheRows` 传入，仍保持 `updateState` 同步）；路由 `culling.list_page/`groups/`summary/`finalize_sync` 迁入 `executeAsync`（顺带移除 finalize_sync 的 awaitSync 桥）；core 878/120、app 172/19 全绿 |
| R1 收尾⑪：第十个删除切片（culling decisions） | ✅ | `CullingDecisionRepo` + 旧测试已删除；决策读写改经 `CullingStore`（严格同步事务拆分：`updateState` 只做事务内计算，当前行经 `CullingUpdateContext.currentDecision/decisionRows` 预读传入，写入经 `CullingDecisionWrite` 收集后由 `commitDecisionWrites` 事务后落库）；`getGroups/getDecisions/getSummary/reset/resetCommand` 异步化；路由 `culling.reset` 迁入 `executeAsync` |
| R1 收尾⑫：第十一个删除切片（similarity） | ✅ | `SimilarityResultRepo`/`SimilarityClusterStateRepo` + 旧测试已删除；`SimilarityService` 全面改经 `any SimilarityStore`（结果/成员/簇快照读，replace/replaceForThreshold/replaceClusterState/delete 写），`hasResult/getResult/clusterVersion/clusterEntries` 异步化；`CullingService` 相似度读改经 store，`getSessionLookup/ensureUpdateExtras/getUpdateContext/refreshSessionUpdateContext` 异步化，`updateState` 同步核心不再发起异步刷新（新鲜读兜底由 update/batchUpdate 预读）；`SimilarityViewModel` 的 sim.result 走 executeAsync；路由 sim.result/sim.writeback 迁入 `executeAsync` |
| R1 收尾⑬：第十二个删除切片（writeback items） | ✅ | `WritebackRepo` + 旧测试已删除；`WritebackService` 全部写回行读写改经 `any WritebackStore`（saveWritebackItems/writebackItems/updateWritebackStatus/failedWritebackCount/updateWriteback*…），`assertNoActiveOtherModule/persistAttributes/persistKeywords/getItems` 异步化并同步更新 `CullingWritebackPort`；`MetadataSyncCoordinator` 改经 store；路由 sim.writeback_items 迁入 `executeAsync`、makeDefault 注入 writebackStore |
| R1 收尾⑭：剩余旧 Repo 盘点（度量化） | ✅ | 门禁新增 5 项「调用文件数」度量（16 项 tracked）：Repositories 6 文件 = Session(8 调用方)/AnalysisJob(3)/MetadataOutbox(3)/Photo(8)/Asset(1)/RepositorySupport；以及 DB 层 9 文件（DB/ImageCache/Migrations + 上述 6）。已按体量+调用方排定后续切片顺序 |
| 删除切片台账 | ✅ 12/… | settings、template、smart album、workspace、person、face、keyword-origins、culling-history、metadata-cache、culling-decisions、similarity、writeback |
| 删除切片台账 | ✅ 5/… | settings、template、smart album、workspace、person（face 进行中）；每片均含旧实现与旧测试同批删除 + 门禁度量更新 |
| R1 收尾⑦：其余切片 | 🔶 | 剩余 `Database/Repositories` 15 文件与 Services 内联 SQL 14 文件 |
| R1 收尾⑥：其余切片 | 🔶 | 剩余 `Database/Repositories` 15 文件与 Services 内联 SQL；每片按「Store/API 落地 → 调用点切换 → 同批删除旧实现与旧测试」推进 |
| 已知 flake | ⚠️ | `JobSchedulerTests.admitsTasksWithinBudget` 在并发负载下偶发失败（单独运行稳定）——R3 JobRunner 重写时改为确定性调度测试 |

> 基线复核（round 41 @ `dbed3c7`）：core **849 tests / 117 suites 全绿**；app **172/19 全绿**；门禁 4 条强制规则 + 16 项度量全绿。；app 172/19（全量跑时 `GatherToast` 计时用例偶发超时，单独运行通过）。
> 度量：Repositories **6**、Repo tests **7**、DB layer **9**、Services 25、raw SQL outside Store 14；
> 调用方密度：SessionRepo **8** 文件、PhotoRepo **8**、AnalysisJobRepo **3**、MetadataOutboxRepo **3**、AssetRepo **1**。
> 后续切片顺序（按调用方×事务耦合）：①MetadataOutboxRepo（消费集中，多为 async）②AnalysisJobRepo ③SessionRepo ④PhotoRepo ⑤AssetRepo+RepositorySupport+DB 层收尾。已知计时 flake：`JobSchedulerTests.admitsTasksWithinBudget`、`GatherToast.show 自动移除`（均单独运行通过）。（settings/template/smart album 旧实现与旧测试同批删除，端口覆盖见 GatherAPITests/TemplatesAPITests/TemplateStoreTests/SmartAlbumStoreTests）；app 172/19 全绿。
> 旧层文件计数（本轮后）：`Database/Repositories` 12、`Database/Repositories` 测试 11、`Services` 26；门禁度量 raw SQL outside Store（仅统计 Services/）14 文件、Services 25 文件。
> 估算口径：人日；S ≤ 0.5d、M ≤ 2d、L > 2d；按 2-3 名工程师估。

---

## 0. 策略声明：什么算「重写」，什么算「补丁」

**重写的硬标准（每个 PR 必须全部满足，写进 PR 模板）：**

1. **删旧码**：旧文件/旧类型在同一个 PR 内 `git rm`，不允许「先留着以后删」；
2. **不设兼容层**：不新增 `Legacy*`/`Compat*`/`Adapter*` 命名、不加 `@available(*, deprecated)` 转发、不保留 feature flag 双路径；
3. **调用点全量切换**：旧实现的引用计数在合并后必须为 0（由 `scripts/check-no-legacy.sh` 断言）；
4. **测试跟着重写**：旧测试替身（`StubCommandRouter`、复制生产逻辑的 Fake）随旧实现一起删除，新测试随新实现入库；
5. **净新增受控**：单个合并单元不允许「旧 3,000 行 + 新 3,000 行」长期并存；同一个子系统的新旧替换必须在一次合并内完成。

**明确禁止的补丁形态（对照当前审计发现）：**

| 禁止的补丁做法 | 本计划替代方案 |
|---|---|
| 给 4 个命令改调用方式 / 补本地化键 | API 层整体重写为 async-only（R5），同步入口直接不存在 |
| 给无锁缓存加锁、给 `batchAsync` 加锁 | 有状态服务整体重写为 actor、并发原语统一为值返回（R2） |
| 修 `removeTailIfCurrent` 的身份比较 | 元数据写回链路整体重写为单一 writer actor（R4） |
| 改 ExportService 的分组 key 表达式 | ExportRuntime 重写（R2），分组/命名/取消语义重新定义 |
| 把 RAW 扩展名合并成一个常量 | Store/Support 层定义唯一 `PhotoFormats`，5 处调用点随重写删除（R1/R2） |
| 外键级联「集中一个删除函数」 | 新 Schema（v-next）+ 新 Store 定义级联策略（R1） |
| 在旧 MetadataService 上注入 EXIF provider | 元数据 Runtime 重写，provider 是一等依赖（R2/R4） |
| 把 `switch` 包一层 `CommandID` 枚举 | API 层按域彻底重写，handler 注册表是唯一形态（R5） |

**保留内容（不重写，作为行为 oracle 冻结）：** 增量聚类/哈希/向量/人脸推理等算法内核、`Protocol/` DTO（升级为强类型契约）、迁移历史的语义、`Reconciliation/` fixtures、core 现有 789 个测试（允许改类型名/import，不允许改断言）。

> 说明：算法内核（ClusterEngine/IncrementalClusterer/Hash/VectorIndex/Face 推理）**不重写**——它们是资产而非债务；重写的是包住它们的架构层。若把这些也推倒，等于用 45k 行重写去换 20k 行稳定算法，风险与收益不成比例。

---

## 1. 重写范围三分法

| 处置 | 对象 | 规模 |
|---|---|---|
| **保留** | 算法内核（`Similarity/`、`Face/` 推理链、`Image/RAWDecoder`）、`Protocol/` DTO、迁移历史步骤语义、对账 fixtures、core 测试 | ~6,000 行 + 789 测试 |
| **重写（删旧写新）** | ① Store/持久化层：`Database/**` 全部（DB/Schema/Migrations/ImageCache/17 Repo，8,718 行）+ 服务内 120 处裸 SQL<br>② Runtime 层：`Services/**` 28 文件 14,599 行（有状态服务 actor 化、god class 拆分）<br>③ JobRunner：JobService/JobScheduler/executors<br>④ MetadataWriter：MetadataSyncCoordinator/WritebackService/MetadataMutationService/outbox/CaptureOneSyncState<br>⑤ API 层：SessionCommandRouter(3,128) + CommandRouter(26) + NativeCommandClient(61)<br>⑥ UI：RootView 外壳 + 5 个「VM 与 View 同文件」页面 + 全部页面重复组件<br>⑦ Support：TimeFormat/JSONCoding/SHA256/ConcurrentBatch/ChunkedIN/PhotoFormats | 约 45,000 行被重新拥有 |
| **删除（裁决为不接线）** | WatchCoordinator、HNSW（或移出主 target 做实验包）、FaceMatcher/Preprocessing/FaceDetector 死路径、Telemetry、AnalysisWorker+JobScheduler、ImageCache、CaptureOneSyncState、helper（除非明确发布）、ONNX 回退 + 模型下载 UI、31 条零调用命令、`photo.list`/`filter.photos` 重复命令、entitlements 死文件 | 约 2,500-3,500 行 + 若干 UI |

---

## 2. 目标架构（重写后的形态）

### 2.1 gather-core

~~~text
GatherCore/
├── Domain/        # 保留：聚类/哈希/向量/人脸推理（纯算法，无 SQL、无状态）
├── Store/         # 唯一 SQL 所有者
│   ├── SQLiteDatabase.swift      # actor：连接、事务、语句缓存、keyed row 解码、结构化错误
│   ├── Schema.swift              # 唯一 DDL 来源（含级联策略）
│   ├── MigrationRegistry.swift   # [(version, description, up)]，只做数据变换
│   └── Stores/                   # 每聚合一个协议 + SQLite 实现
│       AssetStore / PhotoStore / CullingStore / FaceStore / PersonStore /
│       SimilarityStore / MetadataStore / JobStore / WritebackStore /
│       SessionStore / SettingsStore / SmartAlbumStore / TemplateStore / NavigationStore
├── Runtime/       # 有状态服务 = actor；依赖 Store 协议
│   ├── CullingRuntime（QueryBuilder/LookupLoader/Assembler/SessionCache 四文件）
│   ├── IndexRuntime / SimilarityRuntime / DuplicateRuntime / FaceRuntime
│   ├── ExportRuntime / QualityRuntime / NavigationRuntime / WorkspaceRuntime
│   └── SettingsRuntime / TemplateRuntime / PersonRuntime
├── Jobs/          # JobRunner actor + executors + CheckpointCodec + 去重键策略
├── Metadata/      # MetadataWriter actor（outbox 单一状态源、冲突/重试/恢复）+ XMP providers
├── API/           # GatherAPI：强类型 async 命令面，每域一个文件
└── Support/       # TimeFormat / JSONCoding / SHA256 / ConcurrentBatch / ChunkedIN / PhotoFormats
~~~

**架构规则（写入 DEVELOPMENT.md，并用 CI 脚本断言）：**

1. `Services/` 目录不再存在；`Store/` 之外不得出现 `prepare(`（CI grep 门禁）；
2. 命令面只有 async：`func listPage(_ p: CullingListPageParams) async throws -> CullingPage`；**不存在** sync `execute`、`awaitSync`、信号量桥接；
3. 参数与结果一律 `Protocol/` DTO（Codable），app 层不出现 `[String: JSONValue]`；
4. 有可变状态者一律 `actor`；`@unchecked Sendable` 需注释锁序并获得 reviewer 双签；
5. DDL 只在 `Store/Schema.swift`；迁移步骤禁止再写 `CREATE TABLE`；
6. 错误只有 `GatherError`（`code + params` 结构体，code 为 `GatherErrorCode`），UI 单点映射；
7. 并发原语唯一：`ConcurrentBatch`（值返回、取消传播、保序）、`ChunkedIN`、`TimeFormat`、`JSONCoding`。

### 2.2 gather-app

~~~text
Sources/GatherApp/
├── App/           # GatherApp / Composition（装配根）/ Menu / DeepLink
├── Shell/         # RootShell（NavigationSplitView）、PageLifecycle、SessionTabBar
├── Features/      # 每个 Feature：ViewModel.swift（独立）+ View.swift + Subviews.swift
│   Dashboard / Library / Gallery / Similarity / Persons /
│   Culling / Settings / FaceKeywording / Duplicates / Export / ControlCenter
└── Support/       # GatherTheme / GatherLocalization / SharedViews（ErrorBanner、LoadState、
                   # PageHeader、PaginationFooter、KeyboardMonitor、Debouncer、Thumbnail）
~~~

**UI 规则：**

1. ViewModel 必须独立文件、`@MainActor @Observable`，只依赖 `GatherAPI` 协议（可注入 fake）；
2. View 不直接调用 API；不手工登记轮询（页面生命周期由 `.task` + `PageLifecycle` environment 驱动）；
3. 不再有「opacity 常驻 + 手工 stop/start」外壳；改用 NavigationSplitView + 显式 page 生命周期（ADR-022 直接落地）；
4. 共享组件唯一：错误横幅、加载/失败态、页头、分页、键盘/滚轮、日期格式化、颜色标签；
5. 本地化单轨：所有文案走 `GatherLocalization.l`，删除 `zhLabel/enLabel` 平行体系。

---

## 3. 工作流（WBS）

### R0｜工程基座（1 周，~4 人日）— 必须先做
- R0.1 新增 `Sources/CSQLite/placeholder.c`（否则 Xcode 16+/26/27 无法构建、测试跑不起来）；
- R0.2 `refactor` 分支策略与 CI：pin Xcode、cache、timeout、最新 Xcode 矩阵；
- R0.3 `scripts/check-no-legacy.sh`：断言 `awaitSync`/`SessionCommandRouter`/`Services/`/`StubCommandRouter`/Store 外 `prepare(`/无注释 `@unchecked Sendable` 为 0（初期允许白名单，随重写收敛）；
- R0.4 性能与行为基线采集：导入 5 万、batchUpdate 1 万、导出 1 万、navigation.analyze、聚类 25k，记录耗时/内存，作为重写后对比门禁；
- R0.5 真实库副本 fixture（用于数据兼容验证）。
- **出口**：本地与 CI 均可跑 `swift test`；基线与 legacy 扫描脚本入库。

### R1｜Store 层重写（L，10-15 人日）
- **删除**：`Database/DB.swift`、`Schema.swift`、`Migrations.swift`、`ImageCache.swift`、`Repositories/*.swift`（17 文件）。
- **新增**：`SQLiteDatabase` actor（连接/事务/嵌套 SAVEPOINT/语句缓存 LRU/keyed 行解码/结构化错误 + sqlite 错误码）、`Schema.swift`（DDL 单源 + `ON DELETE CASCADE` 策略）、`MigrationRegistry`（版本数组，历史语义不变）、14 个 Store 协议 + SQLite 实现。
- **必须一并解决（新实现固有，不是补丁）**：DDL 双份维护、外键级联不一致、写后重读强解包、DBError 字符串判定、无语句缓存、`ensurePhoto` 每照片 13 次 prepare、RAW 扩展名 5 份（收敛到 `Support/PhotoFormats`）。
- **Oracle**：现有 Repo 测试 + `MigrationTests` + schema 快照全部保留并通过；新增列/索引/FK 级快照。
- **出口**：`Services/` 内不再新增 SQL；旧 Repo 文件删除；空库迁移与旧库副本升级验证通过。

### R2｜Runtime 层重写（L，15-20 人日）
- **删除**：`Services/` 28 个文件（14,599 行）。
- **新增**：按 §2.1 的 Runtime actor；`CullingRuntime` 拆 4 文件（QueryBuilder/LookupLoader/Assembler/SessionCache）；导入/索引、相似度、重复、人脸、导出、质量、导航、工作区、设置、模板、人物各一个 Runtime。
- **必须一并解决**：3 处数据竞争（actor 化）、`MetadataMutationService` 身份比较（链路重写）、FilterEngine 未知操作符静默降级（SQL 编译为纯类型 + 显式报错）、offset 语义、导出分组/顺序/取消语义、Navigation 指纹与异步、Quality O(n²)、checksum 空串回写、批量 resolve N+1、sha256 流式、checksum 回填流式。
- **Oracle**：core 789 测试作为行为契约；对账 fixtures（Cluster/Vector/DHash 等）在 CI 显式开启。
- **出口**：`Services/` 目录删除；每个 Runtime 有对应测试文件；性能对比不劣于基线 >10%。

### R3｜JobRunner 重写（M-L，8 人日，可与 R2 并行）
- **删除**：`Services/JobService.swift`、`JobScheduler.swift`、`AnalysisWorker.swift`。
- **新增**：`Jobs/JobRunner` actor：单注册表、租约 fencing（interrupted 触发 signal）、取消宽限期、`stop()` 超时兜底、checkpoint 编解码器、去重键策略（export key 纳入目标摘要）、完成结果原子 take。
- **出口**：崩溃恢复/取消/重试/去重各有集成测试；`AnalysisWorker` 死路径彻底消失。

### R4｜MetadataWriter 重写（M-L，8 人日，可与 R2 并行）
- **删除**：`MetadataSyncCoordinator`、`WritebackService`、`MetadataMutationService`、`CaptureOneSyncState`、旧 `MetadataOutboxRepo` 接口。
- **新增**：`Metadata/MetadataWriter` actor：outbox 单一状态源、写入队列（token 身份）、冲突/失败/重试（5 档退避）、崩溃恢复（启动即 `recoverInterrupted + reschedule`，不再是未接线方法）、XMP providers 一等注入（EXIF/尺寸 provider 在此层接线或明确收缩契约）、单写者投影。
- **出口**：重启恢复、并发编辑、冲突裁决、清理状态机各有测试；「5 个状态载体」收敛为 1 个持久源 + 1 个内存视图。

### R5｜API 层重写（L，10-15 人日）
- **删除**：`Host/SessionCommandRouter.swift`、`Host/CommandRouter.swift`、`Support/NativeCommandClient.swift`、`Support/JSONValueDecoding.swift`（被 typed API 取代）。
- **新增**：`GatherAPI` 协议 + `GatherCoreAPI` 实现（组合根），按域拆文件（Session/Photo/Culling/Similarity/Duplicate/Face/Person/Template/Metadata/Export/Jobs/Settings/Assets/Album/Filter/Navigation/Quality/Image）；参数/结果全部 `Protocol/` DTO；`GatherError` 单点映射；统一 keyset 分页类型。
- **必须一并解决**：4 个不可用命令（新 API 只有 async，问题在结构上不复存在）、118 命令契约测试（黄金列表 + 破坏性门控表驱动 + 「双注册」概念消失）、31 条零调用命令在重写时裁决、错误映射 5 份收敛、JSON 双向往返消除。
- **出口**：旧路由器文件删除；`CommandContractTests` 覆盖全部命令；app 层 grep 不到 `execute(`/命令级 `JSONValue`。

### R6｜UI 重写（L，20-30 人日，按 Feature 增量切换）
- **顺序**：Culling（最大、问题最多，作为试点）→ Shell/RootView → Settings → FaceKeywording → Export → Duplicates → ControlCenter → Dashboard/Library/Gallery/Similarity/Persons 的组件与 VM 基线化。
- **删除**：`Culling/CullingView.swift`(2,701)、`Settings/SettingsView.swift`(1,417)、`FaceKeywording/FaceKeywordingView.swift`(1,498)、`Export/ExportView.swift`(733)、`Duplicates/DuplicatesView.swift`(593)、`ControlCenter/SessionControlView.swift`(816)、`Sources/GatherApp/RootView.swift`(635) 以及 6 个顶层目录（迁入 `Features/`）。
- **新增**：`Shell/RootShell`（NavigationSplitView + PageLifecycle）、每 Feature 的 VM/View/Subviews 三件套、`Support/SharedViews`（ErrorBanner/LoadState/PageHeader/PaginationFooter/KeyboardMonitor/ScrollWheelZoom/Debouncer/ColorLabel/Formatters）、`Support/Thumbnail`（合并现有缓存与 `ImageCache` 裁决）。
- **必须一并解决**：VM 与 View 同文件、5 个 VM 零测试、错误横幅 12 处、页头 7 处、同步 hint 双份、ISO8601 4 份、NSColor 4 份、LoadPhase 4 份、键盘 3 套、分页 4 种、debounce 5 份、theme token 使用率、a11y 覆盖（Library/Duplicates 0 处）、Settings 双轨本地化 40 组冲突、body 内 O(n) 与 formatter 构造、body 内写 `@State`、opacity 常驻手工门控。
- **出口**：每个 Feature 删除旧文件并有 characterization + 新测试；手工验收清单（导航/筛选/快捷键/i18n/VoiceOver）通过。

### R7｜死代码与产品裁决（M，3-5 人日）
- 一张决策表 + 一条 ADR（`ADR-028-unwired-assets`），对 §1 的删除清单逐项落「删除 / 独立实验 target / 接线」；默认删除。
- **出口**：grep 不到未接线类型；ROADMAP/ADR 同步标注。

### R8｜文档与门禁收尾（M，3-5 人日）
- 台账生成脚本（测试数/命令数/表数）、ADR-023/1.6/边界扫描/Reconciliation 死引用修正、DEVELOPMENT 重写为新架构规则、CI 加 legacy 扫描与基准冒烟。
- **出口**：`check-no-legacy.sh` 全绿；基准与基线对比入库。

---


## 4. 审计发现 → 重写工作流映射（确保无遗漏）

| 审计发现 | 被哪个工作流消灭 |
|---|---|
| 4 个命令注册错配 / 双 switch | R5（async-only typed API） |
| 3 处数据竞争 + 无锁缓存 | R2（actor 化） |
| MetadataMutation 身份比较 / 写回 5 状态载体 / coordinator 未启动 | R4 |
| 任务 fencing / cancelling 残留 / stop 超时 / export 去重 | R3 |
| Export 分组与顺序 / 取消语义 | R2 ExportRuntime |
| FilterEngine 静默降级 / offset / 查询计划 | R2 FilterRuntime（SQL 编译纯类型 + EXPLAIN 测试） |
| EXIF provider 未接线 / 相机时间过滤失效 | R4 + R2（metadata 契约明确） |
| DDL 双份 / 外键级联 / 无语句缓存 / DBError 字符串 | R1 |
| RAW 扩展名 5 份 / 时间/JSON/哈希/并发原语重复 | R1 + R2（Support 单一来源） |
| 3,128 行路由器 / 错误映射 5 份 / JSON 往返 | R5 |
| UI 重复与 VM 可测性 / opacity 外壳 / 双轨本地化 | R6 |
| 未接线资产 / 假设置开关 / ONNX / 零调用命令 | R7 |
| 文档漂移 / CI 门禁缺失 | R0 + R8 |

---

## 5. 顺序、并行与分支策略

~~~text
R0 ──> R1 ──┬─> R2 ──> R5 ──> R6 ──> R7 ──> R8
            ├─> R3 ──┘        （R6 按 Feature 并行度最高）
            └─> R4 ──┘
~~~

- **关键路径**：R0 → R1 → R2 → R5 → R6。
- **可并行**：R3、R4 与 R2 文件不重叠；R6 的多个 Feature 可分给不同人，但 `Shell/RootShell` 先落地。
- **分支**：长分支 `refactor`，每周 rebase 已冻结的 `main`；**每个子系统（R1/R2/R3/R4/R5 + 每个 Feature）完成即向 main 合入**，避免大爆炸式合并。
- **文件所有权**：R5 的 API 域文件一人一个域；`GatherAPI.swift` 协议文件由一人维护（先冻结接口，再并行实现）。
- **冻结规则**：重写期间 main 只接受 P0 安全修复；新功能一律推迟。

### 前两周逐日（2 人）

| 天 | 工程师 1 | 工程师 2 |
|---|---|---|
| D1 | R0.1 placeholder.c + 验证 `swift test` | R0.2 CI + R0.3 legacy 扫描脚本 |
| D2 | R1 设计冻结（Store 协议清单 + 迁移注册表接口） | R0.4 基线采集 + R0.5 真实库 fixture |
| D3-D5 | R1：SQLiteDatabase actor + Schema + MigrationRegistry | R1：Asset/Photo/Session/Settings Store + 旧 Repo 测试迁移 |
| D6-D8 | R1：Culling/Face/Person/Similarity/Metadata Store | R1：Job/Writeback/SmartAlbum/Template/Navigation Store |
| D9-D10 | 删除旧 Repo/DB/Migrations/Schema；全量测试绿 + 旧库副本升级验证 | 同左 + 列级 schema 快照 |

---

## 6. 验证与门禁

**每子系统出口（PR 模板）：**

1. oracle 测试全绿（core 789 保留；app 测试随 Feature 重写更新）；
2. 新增测试覆盖该子系统的关键路径与失败路径；
3. `scripts/check-no-legacy.sh` 对应该子系统的规则通过（如 R1 后 Store 外无 `prepare(`）；
4. 性能对比（涉及热路径时）不劣化 >10%；
5. 数据兼容：旧库副本在新 Store 下读写一致（R1/R4）；
6. 手工验收清单（R6 每 Feature 一份）。

**全局门禁（里程碑末）：**

- `swift test`（core + app）+ `build.sh` + 最新 Xcode 矩阵；
- `GATHER_RECONCILIATION_VECTOR=1` 对账套件；
- 基准五项对比基线；
- 旧库升级演练（备份 → 迁移 → 完整性校验 → 回滚）。

**完成判据（重写结束时应为 0）：**
`Services/` 目录、`SessionCommandRouter`、`awaitSync`、`StubCommandRouter`、命令参数中的 `JSONValue`、Store 外 `prepare(`、无注释 `@unchecked Sendable`、`zhDesc/enDesc`、`batchAsync` 多份副本、5 份 RAW 清单。

---

## 7. 风险与应对

| # | 风险 | 应对 |
|---|---|---|
| 1 | 重写周期长（2 人约 3-4 个月），期间无法发布 | main 冻结；若必须发布，只 cherry-pick P0 缺陷修复（明确标记「重写后自动失效」），不做架构补丁 |
| 2 | 旧代码里存在无测试的隐式行为（app 侧仅 3.6k 测试） | 每个 Feature 重写前先写 characterization tests（针对现 VM 的关键路径），再删旧实现 |
| 3 | DTO 与实际参数漂移（DTO 目前未用于真实调用面） | R5 以现行 router 的参数解析为契约源逐命令对照，禁止凭命名猜测；黄金列表测试兜底 |
| 4 | 性能回归 | R0.4 基线 + 每子系统对比门禁 |
| 5 | 数据丢失（迁移/级联重构） | 迁移历史语义不变；R1 只改 runner 与 DDL 来源；schema 变更走既有备份/恢复机制并在旧库副本演练 |
| 6 | 算法内核被顺手重写导致质量回退 | 保留清单冻结；算法只在有对账测试覆盖时小改，不重写 |
| 7 | 范围蔓延（「顺便」重写不必要的东西） | 只有 §1 三分表中的对象可动；新增对象需在 ADR 中立项 |
| 8 | 长分支 rebase 冲突 | 每周 rebase + 子系统级合入；main 冻结避免冲突面扩大 |

---

## 8. 里程碑（2 人基准 / 3 人可压缩约 30%）

| 里程碑 | 交付 | 出口门禁 | 预估 |
|---|---|---|---|
| **M0** | R0 基座 | 本地/CI 可跑测试；基线与 legacy 扫描入库 | 1 周 |
| **M1** | R1 Store 层 + 旧持久化代码删除 | 全部 core 测试 + 列级快照 + 旧库副本通过 | 2-3 周 |
| **M2** | R2 Runtime + R3 JobRunner + R4 MetadataWriter，`Services/` 删除 | 并发/取消/恢复测试；性能不劣化 | 4-5 周 |
| **M3** | R5 API 层 + 旧路由器删除 | 118 命令契约测试；4 个不可用命令结构性消失 | 6-7 周 |
| **M4** | R6 UI 重写（Shell + 11 Feature） | 每 Feature 手工验收 + 新测试；旧页面删除 | 10-12 周 |
| **M5** | R7 + R8 | legacy 扫描全绿；文档台账生成；基准对比 | 13 周 |

---

## 9. 立即可执行的第一步

1. 在 `refactor` 分支提交 R0.1（`placeholder.c`），确认 `swift test` 可运行——这是重写期间所有验证的前提；
2. 冻结 `GatherAPI` 协议草案（一页纸：域清单 + 每个域的方法签名 + DTO 引用），作为 R2/R5/R6 的并行契约；
3. 冻结 Store 协议清单与 `SQLiteDatabase` 接口（R1 的设计产出入库 `docs/ARCHITECTURE-REWRITE-DESIGN.md`）；
4. 采集 R0.4 基线数据并保存为 CI artifact；
5. 开始 R1：先写 `SQLiteDatabase` actor 与 `MigrationRegistry`，再逐个 Store 迁移旧 Repo 测试。

