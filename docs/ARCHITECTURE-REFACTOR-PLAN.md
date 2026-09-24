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
| R1 收尾㊱（㉟ 落地）：Migrations.swift 退役完成 | ✅ | 删除 Database/Migrations.swift(1363) 与 MigrationTests.swift；全部测试改用 StoreMigrator（新增 helper makeMigratedLegacyDB(path:)，makeMigratedDB 改唯一临时文件库——Store 迁移器与旧连接无法共享 :memory:）；JobService/MetadataSync/Similarity 等 harness 与 app makeTestSettings 异步化；app 启动路径移除旧 MigrationRunner（改由既有 StoreMigrator 承担）；StoreMigratorTests 删 runLegacy 并改「同源双跑」幂等验证、StoreSchemaTests oracle 改 StoreMigrator。度量：DB layer 2→1（仅剩 DB.swift）、Repo tests 1→0。core 758/110（1 个已知并发 flake，单独跑通过）、app 172/19 全绿 |
| 删除切片台账 | ✅ 15/… | settings、template、smart album、workspace、person、face、keyword-origins、culling-history、metadata-cache、culling-decisions、similarity、writeback、metadata-outbox、analysis-jobs、assets |
| 删除切片台账 | ✅ 5/… | settings、template、smart album、workspace、person（face 进行中）；每片均含旧实现与旧测试同批删除 + 门禁度量更新 |
| R1 收尾⑦：其余切片 | 🔶 | 剩余 `Database/Repositories` 15 文件与 Services 内联 SQL 14 文件 |
| R1 收官：删除 DB.swift——Store 成为唯一 SQL 所有者（wave W1） | OK | 生产侧：IndexerService(31 连接点/3 事务) 迁 SQLiteDatabase；删除 Database/DB.swift(352 行)；GatherApp/SessionCommandRouter 去 DBConnection 参数与 db 字段；错误映射 DBError→SQLiteFailure；RepositorySupport 删死代码 optDB。测试侧：core+app 测试层全量迁 SQLiteDatabase（makeMigratedStore 同连接、helper async、prepare 链→run/query/queryOne、columnOrder 行访问、新增测试专用 SQLiteRowTestAccess）。度量：DB layer 1→0、raw SQL outside Store 14→0、unchecked Sendable 22→21、AnalysisJobRepo callers 3→1（baseline 同步）。验证：双包库编译 0 error；core 758/110（3 个已知并发 flake，隔离复跑 48/12 全绿）；app 172/19 全绿。编排：3 个并行子代理（core 测试迁移/app 测试迁移/CullingRuntime 只读设计）+ 主代理 baseline/文档/R7 种子 |
| 已知 flake | ⚠️ | `JobSchedulerTests.admitsTasksWithinBudget` 在并发负载下偶发失败（单独运行稳定）——R3 JobRunner 重写时改为确定性调度测试 |

> 基线复核（round 41 @ `dbed3c7`）：core **849 tests / 117 suites 全绿**；app **172/19 全绿**；门禁 4 条强制规则 + 16 项度量全绿。；app 172/19（全量跑时 `GatherToast` 计时用例偶发超时，单独运行通过）。
> 度量：Repositories **3**、Repo tests **4**、DB layer **6**、Services 25、raw SQL outside Store 14；
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


## 会话交接摘要（round 52 写入，供后续会话直接续跑）

**状态**：HEAD `7a507e3`（+本轮），工作区干净。core **836/116**、app **172/19** 全绿；门禁 4 条强制规则 + 16 项 ratchet 度量全绿。

**R1 已完成 13 个删除切片**（每个都是「Store 落地 → 调用点 async 化 → 同批删除旧实现 + 旧测试 → 度量/baseline 更新」）：
settings、template、smart album、workspace、person、face、keyword-origins、culling-history、metadata-cache、culling-decisions、similarity、writeback、metadata-outbox。

**R1 剩余（5 个 Repo + 3 个 DB 层文件）**，按建议顺序：
1. `AnalysisJobRepo`（290，仅 `JobService.swift` 消费；阻塞：create/cancel/retry/list/clearCompleted 被路由同步 case 调用）→ `JobStore`
2. `SessionRepo`（166，8 个调用方文件、3 个同步事务）→ `SessionStore`
3. `PhotoRepo`（312，8 个调用方文件）→ `PhotoStore`
4. `AssetRepo`（1175，1 个调用方 IndexerService）→ `AssetStore`
5. 最后才能删 `RepositorySupport.swift`（224）与 `Database/{DB,ImageCache,Migrations}.swift` → R1 完成态

**每切片的固定套路（本会话已验证 13 次）**
1) 先加 Store 侧缺失 API（raw SQL 只能出现在 `Store/`）；2) 逐个函数（不要全局正则！协调器那次教训）改调用点并即时 `swift build`；3) 同步事务内的写 → 收集进 sink（history/cache/decision/outbox 四类已有先例）→ 提交后 `commitXxx` 经 store 落库；4) 同步读 → 异步化 + 路由 case 迁 `executeAsync`；5) 删 Repo/旧测试 + 装配/harness（文件库双连接）；6) `./scripts/check-no-legacy.sh` + 更新 `legacy-baseline.txt`；7) core+app 全量测试；8) 提交。

**关键命令**
- core：`cd desktop/native/gather-core && CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test`
- app：同上，目录换 `desktop/native/gather-app`
- 门禁：`./scripts/check-no-legacy.sh`（含 ratchet，旧层回涨即失败）
- 已知计时 flake（单独跑通过）：`JobSchedulerTests.admitsTasksWithinBudget`、`GatherToast.show 自动移除`

**R2-R8 尚未开始**：删除 `Services/`（当前 25 文件）→ JobRunner → MetadataWriter → 类型化 async API（删 `SessionCommandRouter`，当前 17 文件引用）→ UI 重写（Shell + 11 Feature）→ 死代码裁决 → 文档/门禁收尾。

## W2｜R2 Runtime actor 化（wave 编排，逐轮并行推进）

W2 是 R2 的完整波次，按域拆成可并行子波，每轮 2–6 个互不重叠的工作流（子代理）+ 主代理集成/验收/提交。

| 子波 | 交付（新增 Runtime actor） | 同批删除 | 并行工作流划分 |
|---|---|---|---|
| W2a | `Runtime/Support/` 收敛：PhotoFormats 单一来源、时间/JSON/哈希/并发原语 | 各服务内重复常量 | ①Support 收敛 ②Culling QueryBuilder 骨架 ③调用点扫描报告 |
| W2b | `CullingRuntime`（QueryBuilder/LookupLoader/Assembler/SessionCache 4 文件 + actor） | `Services/CullingService.swift`(2537) | ①QueryBuilder+Assembler ②LookupLoader+SessionCache ③路由/测试接线 |
| W2c | `SimilarityRuntime` + `DuplicateRuntime` + `QualityRuntime` | 3 个服务文件 | ①Similarity ②Duplicate ③Quality ④测试迁移 |
| W2d | `IndexerRuntime` + `ExportRuntime` + `NavigationRuntime` + `FaceRuntime` | 4 个服务文件 | ①Indexer ②Export ③Navigation ④Face+测试 |
| W2e | `MetadataRuntime`（R4 前置：outbox 单一状态源） | `MetadataService`/`MetadataMutationService` | ①outbox 状态机 ②provider 接线 ③冲突/重试 |
| W2f | `WorkspaceRuntime`/`SettingsRuntime`/`TemplateRuntime`/`PersonRuntime` + `AppContainer` 切换 | 余下服务文件 | ①Workspace+Settings ②Template+Person ③容器与路由收口 |

**出口（W2 全波）**：`Services/` 目录删除（0 文件）；每个 Runtime 有独立测试；core/app 双包全绿；门禁全绿（`unchecked Sendable` 归零、`raw SQL outside Store` 保持 0）。

**每轮硬性验收**：①子波内所有 Runtime 编译通过 ②对应旧服务文件同批删除 ③双包测试（含 flake 隔离复跑）④门禁 + 度量/baseline ⑤提交。
### W2 起点清点（Sources/Services，14,011 行 / 28 文件）

- 巨型（>1000 行，需拆文件）：`CullingService` 2550、`FaceKwService` 1436、`IndexerService` 1160。
- 大型（600–1000）：`MetadataSyncCoordinator` 982、`SimilarityService` 968、`JobService` 822、`WritebackService` 790、`DuplicateService` 744、`QualityService` 648、`MetadataService` 637、`ExportService` 617。
- 中型（<600）：`NavigationService` 558、`FilterEngine` 542、`SessionService` 337、`MetadataMutationService` 240、`PhotoAssetResolver` 168、`MetadataProviders` 140、`MetadataContract` 125、`MetadataConflictFields` 116。
- **`@unchecked Sendable` 7 处**（actor 化直接目标）：CullingService、MetadataSyncCoordinator、JobService、DuplicateService、WritebackService、MetadataService、MetadataMutationService。
- 度量 `raw SQL outside Store (R1)` 已到 **0**（所有服务经 Store 访问 SQL），`unchecked Sendable` 21（R2 目标归零）。
## W3–W5 波次编排（预置）

### W3｜R3 JobRunner（可与 W2 并行）
| 工作流 | 交付 | 同批删除 |
|---|---|---|
| ①JobRunner actor | `Jobs/JobRunner`：单注册表、租约 fencing、取消宽限期、`stop()` 超时、checkpoint 编解码、去重键、结果原子 take | `Services/JobService.swift`(822)、`JobScheduler.swift`、`AnalysisWorker.swift` |
| ②集成测试 | 崩溃恢复/取消/重试/去重 4 组测试 | 旧 JobService 测试 |
| ③路由接线 | `jobs.*` 用例改走 JobRunner | `AnalysisWorker` 死路径 |

### W4｜R4 MetadataWriter（可与 W2 并行）
| 工作流 | 交付 | 同批删除 |
|---|---|---|
| ①MetadataWriter actor | `Metadata/MetadataWriter`：outbox 单一状态源、写入队列（token 身份）、5 档退避重试、启动即 `recoverInterrupted + reschedule` | `MetadataSyncCoordinator`(982)、`WritebackService`(790) |
| ②provider 接线 | XMP/EXIF/尺寸 provider 一等注入 | `MetadataMutationService`(240)、`MetadataService`(637) |
| ③测试 | 重启恢复/并发编辑/冲突裁决/清理状态机 | 旧 coordinator/writeback 测试 |

### W5｜R5 类型化 async API
| 工作流 | 交付 | 同批删除 |
|---|---|---|
| ①协议与 DTO | `GatherAPI` 协议 + 按域拆分的 `GatherCoreAPI` 实现 + `Protocol/` DTO + `GatherError` 单点映射 | — |
| ②替换路由 | 全命令改 typed async（无 JSONValue 桥） | `Host/SessionCommandRouter.swift`、`Host/CommandRouter.swift`、`Support/NativeCommandClient.swift`、`Support/JSONValueDecoding.swift` |
| ③UI 接线 | ViewModel provider 直连 typed API | 旧 WebResponse/completion 路径 |
## W7｜R7 死代码裁决（候选种子，已核实）

扫查方法：类型名在全仓 `--include=*.swift` 的文件级引用计数（排除仅自身声明），再逐个人工确认。

| 候选 | 引用面 | 裁决建议 |
|---|---|---|
| `SQLiteDuplicateStore`（`Store/DuplicateStore.swift`） | 仅其自身测试 `DuplicateStoreTests.swift` | 生产零使用 → 删除 Store + 测试（或按 R2 DuplicateRuntime 需要重新接线） |
| `FacePreprocessing`（`Face/Preprocessing.swift`） | 仅 `PreprocessReconciliationTests.swift` | 生产零使用 → 删除或并入 FaceRuntime |
| `FaceDetector`（`Face/Detector.swift`） | 仅 `FaceInferenceTests.swift` | 同上（需先确认同文件内其它类型是否在用） |
| `FaceInferenceError`（`Face/Inference.swift`） | 仅自身文件 | 删除或并入统一错误类型 |
| `AnalysisWorkerError`（`Services/AnalysisWorker.swift`） | 仅自身文件 | 随 R3 删除 `AnalysisWorker` 一并消失 |

注意：`SliderInputView`、`PhotoFormats` 等经核实**在用**（前者由 `FaceKeywordingView` 引用），不属死代码。
### W2a 精确定位（主代理扫查，供并行工作流直接派活）

**A1｜并发原语普查（`NSLock` 11 文件 → actor 化目标）**：`MetadataSyncCoordinator`、`IndexerService`、`ExportService`、`JobService`、`QualityService`、`SimilarityService`、`DuplicateService`、`WritebackService`、`MetadataService`、`FaceKwService`、`MetadataMutationService`。

**A2｜`@unchecked Sendable` 精确位置（12 处，R2 目标归零）**：
- `MetadataSyncCoordinator`：`BatchCursor`(911)、`SlotGate`(935)
- `JobService`：`Waiter`(178)
- `DuplicateService`：`ScanHandle`(101)、`BatchCursor`(688)
- `WritebackService`：`WritebackBatchCursor`(707)
- `CullingService`：`CullingHistorySink`(279，public)
- `MetadataService`：`MetadataBatchCursor`(616)
- `MetadataMutationService`：`TaskBox`(201)、`AsyncGate`(207)
- 其余见 `grep -rn '@unchecked Sendable' Sources`（另有 2 处分布在其他文件）

**A3｜重复常量收敛**：RAW 扩展名清单目前分散在 `Image/RAWDecoder.swift:55`、`Watch/Coordinator.swift:46`，与 `Support/PhotoFormats` 并存 → 统一到 `PhotoFormats` 单一来源（计划 §R1/R2 已列为重复 5 份之一）。

**A4｜已收敛项（无需再动）**：时间/ISO（`isoString`/`nowISOString`/`tsDateParse`）与 JSON/路径（`JSONValue` 扩展、`TSPath`）已集中在 `Support/RepositorySupport.swift`；SHA256 在 `Support/SHA256.swift`。
### W3 派活清单（主代理扫查，JobRunner 重写）

- **删除目标**：`Services/JobService.swift`(822)、`Services/JobScheduler.swift`(106)、`Services/AnalysisWorker.swift`(78)、以及 `AnalysisWorkerError`（仅自身引用，已核实死代码）。
- **Store 侧已就绪**（无需新 SQL）：`JobStore` 提供 `create/get/list/listByType/requestCancel/retry/recoverStale/resumeInterrupted/claim/heartbeat/updateProgress/finish/…`（全 async）。
- **JobService 现有 public 面**（新 `Jobs/JobRunner` actor 需等价覆盖）：`start/stop/registerExecutor/create/list/cancel/cancelScope/retry/clearCompleted/claim/heartbeat/updateProgress/finish/waitForResult/run/setProgressSink/throwIfCancelled/updateCheckpoint/updateProgress`，错误类型 `JobCancelledError`/`JobServiceError`。
- **必测语义**（计划 §R3）：崩溃恢复（`recoverStale`+`resumeInterrupted` 启动即跑）、租约 fencing（interrupted 触发 abort signal）、取消宽限期、`stop()` 超时兜底、checkpoint 编解码、去重键（export key 纳入目标摘要）、完成结果原子 take（`waitForResult`）。
- **并行工作流划分**：①`JobRunner` actor 骨架 + 租约/fencing ②取消/宽限/`stop()` 超时 ③checkpoint/去重键/结果 take ④集成测试（4 组）⑤路由 `jobs.*` 接线与旧测试删除。
### R7 追加候选（由 app 测试迁移子代理发现）
- `Host/SessionCommandRouter.swift` 存在**重复 case 死分支**（HEAD 即存在）：`case "export.preview"`(L1949) 与 `case "fkw.unbind"`(L2080) 永不命中 → R5（删除该路由）或 R7 清理时一并删除，并核对两处语义差异是否需合并。
### R5/R7 重要发现：路由重复 case 导致**新实现成为死代码**（主代理核实）

`Host/SessionCommandRouter.swift` 中两个命令各出现两次，Swift switch 只命中**第一次**：

| 命令 | 存活实现（先出现） | 死代码（永不命中） | 语义差异 |
|---|---|---|---|
| `export.preview` | **L1161**：`Task { … requiredString 抛错 → catch → errorMessage }`（统一错误映射） | L1949：先 `guard let … else MISSING_PARAM:sessionId` 再 Task | 缺失参数时的错误码路径不同；L1949 还提前解 params |
| `fkw.unbind` | **L1521**：先 `guard confirmed` → `FKW_UNBIND_CONFIRM_REQUIRED`，再要求 sessionId | L2080：`guard confirmed` → `throw BridgeError.badParams(...)`，且要求 `clusterId`（额外参数！） | **死掉的 L2080 才是要求 clusterId 的新版**，两分支都要求 clusterId，差异仅在非法/缺失时的错误码（已由 W5 设计证实，见 docs/ARCHITECTURE-W5-DESIGN.md） |

**含义**：`fkw.unbind` 当前实际走的是旧实现（不校验 `clusterId`），R1 之后新增的严格校验版从未生效——这是真实的行为缺陷（潜在破坏性命令参数校验缺失）。
**处置**：属 R5（删除路由、改类型化 API）时**必须显式裁决**：以 L2080 的严格语义（要求 clusterId + BridgeError）为准，并为该命令补回归测试；R7 复核是否还有其他 `case` 重复。**本轮不动**（避免在 W2 波次中改变行为）。
### P1「静默降级」精确普查（主代理，供各 Runtime 重写作为验收清单）

`Services/**` 共 **111 处 `try?`**：**12 处良性**（`Task.sleep` 取消、文件清理）／**99 处需复核**（吞掉 Store/SQL 错误）。

| 文件 | 需复核 `try?` |
|---|---|
| MetadataSyncCoordinator.swift | 20 |
| JobService.swift | 12 |
| WritebackService.swift | 11 |
| MetadataService.swift | 11 |
| CullingService.swift | 9 |
| SimilarityService.swift | 6 |
| FaceKwService.swift | 6 |
| ExportService.swift / QualityService.swift / MetadataConflictFields.swift / MetadataMutationService.swift / NavigationService.swift | 各 3 |

典型吞错（MetadataSyncCoordinator）：`try? await writebackStore.recoverInterruptedOutbox()`（启动恢复失败被吞）、`(try? await …recoverableActiveOutbox()) ?? []`（读失败当空集）、`guard (try? await …claimOutbox(…))`（租约失败静默跳过）。

**重写规则（写入各 Runtime 验收）**：
1. Store/SQL 调用**禁止** `try?`：必须上抛（领域错误映射到既有错误码）或显式记录到 job 失败原因；
2. 仅允许两类 `try?`：`Task.sleep`（取消语义）与文件系统尽力清理（且需注释说明）；
3. 门禁后续可加跟踪度量：`Services/Runtime 中非良性 try?` 数，逐步归零（R2 出口）。
| W2 批次①：Store 读模型 + Assembler + SessionCache + JobRunner（新增落地） | OK | ①Store/CullingQueryStore.swift（唯一 SQL 所有者，14 测试；5 个 Store 追加方法含 revision CAS）+ 新增 Runtime/Culling/CullingAssembler.swift（20 纯函数，16 测试）②Runtime/Culling/CullingSessionCache.swift actor（13 测试，确定性淘汰）+ Runtime/Jobs/{JobRunner,JobDedupKey,JobCheckpoint}.swift（JobRunner actor 953 行，16 测试覆盖 8 类语义）③验证：core 817/114（2 个已知并发 flake，隔离 22/3 全绿）；门禁 4 规则 17 度量全绿；Runtime 层 SQL=0、Sources unchecked=9（=baseline）④4 个并行子代理 + 设计代理（W2c 已入库、W2d 报告在途） |

| W2 批次②（进行中）：W2a ConcurrentMap/SHA256.stream + W2c Store 扩展与三纯函数层 + W2b CullingRuntime | 进行中 | 5 个并行子代理：W2a（ConcurrentMap/IndexCursor/SHA256.stream）、W2c Store 扩展（Similarity hash 面/analysis_runs/质量行/assetFileIds/duplicate membersWithPhoto/largestFacePerPhoto）、W2c Similarity 纯函数层、W2c Duplicate+Quality 纯函数层、**W2b CullingLookupLoader+CullingRuntime actor（关键路径）**。主代理本轮已完成：CullingQueryBuilder 纯函数层（7 测试，提交 9c8b839）、W2d 四 Runtime 设计定稿（提交 8e2f29e，含 F5/E1/N1 三处真实缺陷） |

| W2 批次② 集成验收（提交 d79308f + e3ab52f） | OK | ①核心 948 tests / 131 suites（唯一失败为已知并发 flake「keeps the session occupied...」，SimilarityServiceTests 隔离复跑 21/7 全绿）②新交付：Similarity/Duplicate/Quality 纯函数层（41+20+23 用例）、Store 扩展（+522 行纯新增，23 用例）、ConcurrentMap+IndexCursor+SHA256.stream（17 用例）③门禁 4 规则 17 度量全绿（unchecked=8=baseline、Runtime SQL=0）④并行：4 个子代理完成；新派发 SimilarityRuntime 与 Duplicate+Quality Runtime 两个 actor 工作流；CullingLookupLoader/CullingRuntime（关键路径）进行中 |

| W3 切换轮派发 + W5 设计派发（round 17） | 进行中 | ①W3 切换：删除 `Services/{JobService,JobScheduler,AnalysisWorker}.swift` 与 `JobServiceTests`，`JobAbortSignal`/`JobCancelledError` 迁入 `Runtime/Jobs/JobRunner.swift`，路由切换 `jobService`→`jobRunner`（actor async 处 Task 包裹），baseline `Services layer` 25→22 ②W5 设计（只读）：命令清单→typed API、GatherAPI/GatherCoreAPI、GatherError 单点映射、调用方迁移顺序、重复 case 死分支裁决、验收（`SessionCommandRouter` 17→0、`awaitSync` 2→0、`StubCommandRouter` 7→0） |

| W3 切换进行中（round 22 观测） | 进行中 | `Services/` **25→22**：`JobService.swift`/`JobScheduler.swift`/`AnalysisWorker.swift` 已删除；`Runtime/Jobs/JobRunner.swift` 已迁入 `JobAbortSignal`/`JobCancelledError`；`IndexerService.swift` 等引用已同步。当前 core 库编译 8 error（属主子代理 mid-edit），待其收口后由主代理验证双包并提交（含 `Services layer` baseline 同步 25→22 与路由 `jobService`→`jobRunner`）。 |

| round 25 观测：W3 收官后 app 验证被 SimilarityRuntime 阻塞 | 进行中 | 提交 `215e8c7`（W3 收官，Services 25→22）后，app 测试因**未入库**的 `Runtime/Similarity/SimilarityRuntime.swift`（escaping closure 捕获 non-escaping `provider`/`thumbnail`，713/730/792）编译失败 → 已两次派单属主修复（要求同时验证 app 包）。HEAD 保持可编译（坏文件未入库）。待其修复即集成 4 个 Runtime 测试套件并跑双包全量。 |

| W3 切换完成（round 22 交付：core `215e8c7` + app 接线 + 5 例语义迁移） | OK | ①删除 `Services/{JobService,JobScheduler,AnalysisWorker}.swift` 与三个对应测试：`JobServiceTests` 未覆盖语义迁入 `JobRunnerTests`（并发上限/停止不调度/claim 失败不覆盖取消结果/持久失败终态/进度节流 5 例；`handleClaimFailure` 提为 internal 测试接缝），`JobSchedulerTests`/`AnalysisWorkerTests` 随被删类型同批删除（AnalysisWorker 为死路径，budget 语义由 JobRunner maxConcurrentJobs 覆盖）②`JobAbortSignal`/`JobCancelledError` 原样迁入 `Runtime/Jobs/JobRunner.swift`；`JobRunContext` 全部使用者（QualityService/IndexerService/QualityRuntime + 4 测试）切到 `JobRunnerContext` ③app：`jobService`→`jobRunner`；`makeDefault` async 且 await executor 注册（避免返回后 create 命中 executorNotRegistered）；`registerExecutor`/`start`/`wire(jobRunner:)` 全部 await；GatherApp/LiveDashboardDataProvider/GatherEventCenter/SimilarityViewModel + 5 个测试调用点同步 ④验证：core build 0 error、`JobRunnerTests` 21/1 全绿、app build 0 error、app **172/19 全绿**（首轮唯一失败 `photoCountLabelDerivesFromScanJob` 为已知并发 flake，隔离 1/1 绿）；门禁 4 规则 17 度量全绿（Services layer 22、unchecked 7、Runtime SQL 0）⑤错误码/JSON 形状逐字不变；唯一语义差：`waitForResult` 超时返回 nil（W2 JobRunner 既定契约，替代旧 `waitForResultTimeout` 抛错，仅 60min 超时病态路径）⑥core 干净快照全量 937/129，失败项均为环境/负载 artifact（/private/tmp 符号链接导致的 TSPath `~` 用例、ConcurrentMap 顺序、JobRunner 超时上界），隔离全绿；真实树全量被并行代理在飞的 SimilarityRuntimeCancellationTests 轮询挂起（>10min）已终止，不影响本单元 |

| round 29：Culling 切换单元执行中 | 进行中 | 子代理 `b87f42bb` 已开工（新增 `Tests/.../Runtime/Culling/CullingRuntimeCancellationTests.swift`）；`Services/` 仍 22，`Services/CullingService.swift` 待删除。切换内容：类型迁移（`CullingPhotoRow`/`CullingSyncPort`/`CullingWritebackPort`/`CullingOutboxWrite`/`CullingDecisionWrite`/`CullingCachePatch`）→ `makeDefault` 装配 `CullingRuntime` → 路由 22 个 `culling.*` case 异步化 → 同批删旧服务（2550 行）与旧测试 → 修 `CullingRuntimeTests` 2 用例 → baseline 22→21。HEAD `f7717e3` 保持全绿。 |

| round 30：Culling 切换仍需时间；后续各域切换必须与路由改动串行 | 进行中 | `b87f42bb` 运行中（`Services/CullingService.swift` 2550 行的类型迁移+装配+路由+删旧+修测试+双包验证同批次进行）。**编排约束**：所有需要改 `SessionCommandRouter.swift` 的切换单元必须串行（同一文件），因此 W2c/W2d 切换将在 Culling 收口后依次派发；core 侧类型迁移可提前，但删旧服务必须与路由切换同批。 |

| round 32：两个工作流在途（Culling 切换 `b87f42bb`、W4-1 Store `13178f1b`） | 进行中 | Culling：`Services/` 仍 22、`CullingService.swift`（2550 行）待删，新测试 `CullingRuntimeCancellationTests.swift` 已落盘；W4-1：Store CAS/批量命令与大体积事务（`mergeOutboxPatches`/`reconcileWritebackProjection`/`applyAcceptedRemoteValues`）编写中。两者文件集合不相交，HEAD 保持全绿。 |

## 10. `Services/` 剩余清退清单（round 33 实测，基线 22 文件 / 13,005 行）

| 文件 | 行数 | 归属 wave | 处置 |
|---|---|---|---|
| CullingService.swift | 2550 | **W2b** | 进行中：类型迁出 + 装配 `CullingRuntime` + 路由 → 删除 |
| FaceKwService.swift | 1436 | **W2d** | `FaceRuntime` 切换后删除（设计已定） |
| IndexerService.swift | 1160 | **W2d** | `IndexerRuntime` 切换后删除 |
| MetadataSyncCoordinator.swift | 982 | **W4** | 并入 `MetadataWriter` 后删除（设计 §1.1） |
| SimilarityService.swift | 968 | **W2c** | 类型迁 `Protocol/` → `SimilarityRuntime` 装配 → 删除 |
| WritebackService.swift | 790 | **W4** | 并入 `MetadataWriter` 后删除 |
| DuplicateService.swift | 744 | **W2c** | `DuplicateRuntime` 已就绪 → 切换后删除 |
| QualityService.swift | 648 | **W2c** | `QualityRuntime` 已就绪 → 切换后删除 |
| MetadataService.swift | 637 | **W4** | 并入 `MetadataWriter` 后删除 |
| ExportService.swift | 617 | **W2d** | `ExportRuntime` 切换后删除 |
| NavigationService.swift | 558 | **W2d** | `NavigationRuntime` 切换后删除 |
| FilterEngine.swift | 542 | **保留（吸收进 Runtime/Filter）** | 纯函数引擎，迁入 `Runtime/Filter/` 或保留为 Store 相邻纯层（R7 裁决） |
| SessionService.swift | 337 | **W2d/W5** | 迁 `SessionRuntime`；W5 路由删除时一并收口 |
| MetadataMutationService.swift | 240 | **W4** | 并入 `MetadataWriter`（token FIFO 取代 Task 身份链） |
| PhotoAssetResolver.swift | 168 | **W4** | 吸收为 `MetadataTarget` + `PhotoStore.metadataTargets` |
| MetadataProviders.swift | 140 | **W4** | 迁 `Metadata/MetadataProviderContract.swift` |
| MetadataContract.swift | 125 | **W4** | 迁 `Metadata/MetadataMutationPlan.swift`（同时删 3 个零调用函数） |
| MetadataConflictFields.swift | 116 | **W4** | 迁 `Metadata/MetadataConflictRules.swift` |
| ImagePreloadService.swift | 82 | **R7（W5 判定死代码）** | `image.*` 4 命令 0 调用；`thumbnail.build` executor 一并删（`AnalysisJobType.thumbnailBuild` 枚举值保留） |
| CaptureOneSessionState.swift | 76 | **W4** | 迁 `Metadata/MetadataSessionState.swift`（删 `countOutboxStatuses` 死码） |
| PhotoAssets.swift | 47 | **保留/迁 `Runtime/Support`** | RAW 优先级折叠纯函数（`PhotoAssets.collapse`，被 Assembler 使用） |
| MetadataFingerprint.swift | 42 | **W4** | 迁 `Metadata/MetadataFileSystem.swift`（stat/read/hash 接缝化） |

**清退节奏**：W2b（−1）→ W2c（−3）→ W2d（−4）→ W4（−9）→ R5（−1）→ R7（−1）= **Services 从 22 收到 3**（`FilterEngine`/`PhotoAssets`/可能的 `SettingsService`），届时「Services layer」度量转 enforced 0 语义（改名为 `Legacy services` 并删除）。
| round 35：两个工作流停止并重新派发（写优先） | 处置 | 观测到 `b87f42bb`（Culling 切换）与 `13178f1b`（W4-1 Store）连续多轮停留在穷尽式阅读、零文件落盘 → **已 interrupt 两者**，并按「写优先、禁止通读、单方法族 + 3 用例 + 实跑回报」重新派发 W4-1a（`687d20bf`：`markOutboxStatus(expectedRevision:)` CAS + `recoverInterruptedOutbox` + `OutboxStatus` 枚举）。Culling 切换待 W4-1a 模板验证后重新派发。 |
| round 36：Culling 片 C 删旧（cullC，R2 首个删旧里程碑） | OK | ①删除 `Services/CullingService.swift`（2550 行）与 `Tests/GatherCoreTests/Services/CullingServiceTests.swift`（57 用例）；core/app 无引用点需修（仅注释残留；`CullingServiceError` 类型已由片 A 迁入 `Runtime/Culling/CullingTypes.swift`）②旧 57 用例语义逐条比对 `Runtime/Culling/` 6 套件（完全覆盖 ≈44，部分/未覆盖 13）：补 10 个用例 —— writeback rating/colorLabel 计划（keep→5/Green、reject→1/Red、pending 排除）、persist/execute 同批、retryFailed 成功路径、batch 去重+共享 historyOperationId、undo rating/label 回滚（cache+outbox+schedule）、单张 rejected/unreviewed 映射、update cache 兜底、groups_json 组 id 回退、filtered 仅 JPEG 命中排除、可解析组页 total、IPC 错误码描述契约；Store 已覆盖项（历史栈顺序守卫/append 清 undone/limit clamp/precomputed 排除/质量损坏行回退）不重复 ③实跑：core build 0 error、`Culling` 149/10 全绿、app 172/19 全绿、门禁 4 规则 17 度量全绿 ④baseline：`Services layer` 22→21、`unchecked Sendable` 7→6（同一删除的连带下降，按脚本 ratchet note 同步）。 |
| round 37：W4-2 支撑文件迁入 Metadata/（w4b，5/5） | OK | ①git mv（保留历史）：Services/MetadataProviders.swift→Metadata/MetadataProviderContract.swift、MetadataContract.swift→Metadata/MetadataMutationPlan.swift、MetadataConflictFields.swift→Metadata/MetadataConflictRules.swift、MetadataFingerprint.swift→Metadata/MetadataFileSystem.swift、CaptureOneSessionState.swift→Metadata/MetadataSessionState.swift ②死码删除：countOutboxStatuses（76→66 行）、dirtyFieldsForPatch/patchToOutboxValues/assertMutationSource（125→93 行）③引用点 0 改动（同模块跨文件可见；类型名/函数名逐字保留）④语义承接：原 5 文件零专用单测 → 新增 Tests/GatherCoreTests/Metadata/ 4 套件 31 用例（契约校验/冲突规则/指纹文件系统/会话状态）；过滤 51/5 全绿，MetadataSyncCoordinator+Writeback+MetadataStore 回归 20/3 全绿 ⑤未完成（留 W4-2 后续步）：MetadataProviderSet 聚合结构、MetadataFileSystem stat/read/hash 接缝化、类型改名 ⑥baseline：Services layer 21→16。 |
| round 38：W2c 片 B/C：Similarity+Duplicate+Quality 三域切换（w2cB） | OK | ①装配：`makeDefault` 用 `SimilarityRuntime`（Dependencies 四 Store+jobStore+getNumber、Providers.thumbnail 保留 P0-1 修复）/ `DuplicateRuntime`（SQLiteDuplicateStore + 原 thumbnail/cluster provider）/ `QualityRuntime`（photo/job/similarity/face Store + 默认 provider）取代三个服务；新增 `CullingQualityInvalidationPort` 把 `QualityInvalidationPort.invalidateQualityLookup` 接到 `CullingRuntime.invalidateSessionLookup`（旧 invalidateCullingLookup 从未接线）②路由：sim.* 10 / dup.* 4 / quality.* 2 共 16 case 全部落在 `executeAsync`；sim.cancel_analysis / sim.preview_writeback / sim.confirm_sync 从同步 execute 迁入并删同步分支，sim.cleanup 删重复转发分支；sim.analyze executor 切 runtime，`validateSimilarityParameters`（旧文件顶层）调用点改 `SimilarityValidation.validate`；错误映射 SimilarityServiceError/DuplicateServiceError/QualityServiceError → SimilarityError/DuplicateError/QualityError ③app：`SimilarityViewModel.cancelAnalysis`/`syncStateItems`/`refreshSyncState` 异步化（修 sim.writeback_items 同步 execute 命中 async case 必抛 NOT_IMPLEMENTED 的潜伏 bug），SimilarityView onReceive 用 Task 桥 ④删除 `Services/{SimilarityService,DuplicateService,QualityService}.swift` 与 4 个旧测试（SimilarityServiceTests 21 / DuplicateServiceTests 21 / QualityServiceTests 14 / SimilarityIncrementalServiceTests 7）；语义承接：前三组逐组落到 `Runtime/{Similarity,Duplicate,Quality}/` 套件（各旧用例名在新套件可逐条对上），增量 7 用例整体移植为 `SimilarityRuntimeIncrementalTests`（断言逐条保留），补 `reclusterRejectsFractionalThreshold`（旧唯一未覆盖语义）⑤baseline：Services layer 21→13（本单元 −3；含 round 37 W4-2 的 −5）、unchecked Sendable 6→5、batchAsync copies 4→3 |

## 11. R7 死代码裁决清单（round 56 实测，待删除单元）

| 目标 | 证据 | 处置 |
|---|---|---|
| `Services/ImagePreloadService.swift`（82 行） | `image.*` 4 命令全仓 0 调用（`PhotoThumbnailView` 直连 `RAWDecoder`） | R7 删除；`AnalysisJobType.thumbnailBuild` 枚举值保留（兼容既有 job 行） |
| `image.get_dimensions` / `image.preload_previews` / `image.prioritize_thumbnail` / `image.preload_thumbnails` | 路由死分支（0 调用） | R5 不进入 typed API；R7 删路由分支 |
| `culling.decide` / `culling.batch_decide` | 已删除（W2b 片 B） | ✅ 已完成 |
| `photo.list` | 路由死分支（0 调用） | R7 删除（Store 侧 `PhotoStore.getAssetPage` 保留） |
| `populateCache` / `countOutboxStatuses` / `dirtyFieldsForPatch` / `patchToOutboxValues` / `assertMutationSource` | 0 调用 | ✅ 已删除（W4-2 / W2c 迁移） |
| Store 零调用方法：`updateWritebackStatusByXmpPath`、`hasActiveWriteback`、`updateWritebackBackupPath`、`writebackItem(itemId:)` | W4 设计 §1.6 实测 | R7 删除 + 相应测试收窄 |
| `FaceCluster` / `BindingData` 与 `FaceClusterData` 重复类型 | W5 设计 §1.3 | R7 合并为 `FaceClusterData` |
| `PhotoAssets`（47 行）/ `FilterEngine`（542 行） | 纯函数，被 Runtime 使用 | **保留**，迁入 `Runtime/Support` 与 `Runtime/Filter`（R7 定位，不删） |

## 12. R8 门禁加固清单（新增 enforced 规则，实施于各 wave 收尾）

| 规则 | 目标 | 状态 |
|---|---|---|
| `Runtime/**` 内 0 SQL 文本、0 `SQLiteDatabase`、0 `NSLock`、0 `unchecked 并发标注` | 已生效（Culling/Similarity/Duplicate/Quality/Jobs 全部达标） | ✅ 生效 |
| `Metadata/**` 内同上 4 条 | W4 完成后转 enforced | 计划 |
| app 内无 `WebResponse` / `CommandRouter` / `NativeCommandClient` / `JSONValueDecoding` / `RouterCommandError` / `NativeCommandError` / `BridgeError` / `.execute(` | W5 完成后转 enforced | 计划 |
| `SessionCommandRouter (R5)` 17→0、`awaitSync` 2→0、`StubCommandRouter` 7→0 | W5 | 计划 |
| `Services layer (R2)` 13→3（保留 `FilterEngine`/`PhotoAssets`）后改名为 legacy 并删除该度量 | W2d/W4/R7 后 | 计划 |
| `batchAsync copies` 3→0（统一 `ConcurrentMap.run`） | W2d/W4 后 | 计划 |
| `unchecked Sendable` 5→0 | 随 `Services` 清退 | 计划 |

**收尾定义（R8 出口）**：`./scripts/check-no-legacy.sh` 全绿且**全部度量转 enforced**；`Services/` 仅剩 `Runtime/Support`+`Runtime/Filter` 归属的纯函数；双包 0 error、app 测试不减、core 全量绿（已知 flake 隔离复跑通过）；文档（`ARCHITECTURE-W2B/W2C/W2D/W4/W5-DESIGN.md` + 计划进度行 + ADR）齐备。
| round 58–59：R7 `ImagePreloadService` 删除尝试回退（教训） | 已回退 | 用脚本按行删除 4 个 `image.*` case + `thumbnailBuild` executor + 5 行字段/装配后，`SessionCommandRouter.swift` **大括号净差 −1**（executor 块内嵌套闭包的收尾判定错误）→ 潜在语法损坏。**已 `git checkout` 回退两文件，HEAD 保持全绿**。教训：**Swift 大文件（3800 行）禁用行级/括号级文本手术**，必须用「小步编辑 + 每次编译」或语法感知工具（如 `swift-format`/AST 级改写）；括号差检查应作为提交前强制门。 |

## 13. 交接快照（round 64/64，HEAD `05781af`）

### 已完成
- **R1 收官**：`DB.swift`（352 行）删除，Store 为唯一 SQL 所有者（`DB layer=0`、`raw SQL outside Store=0`）。
- **R3 收官**：`JobService`/`JobScheduler`/`AnalysisWorker`（1006 行）删除，`JobRunner` 为唯一作业层（`waitForResult` 超时改返回 nil 为新契约）。
- **R2-Culling 闭环**：`CullingService.swift` 2550 行 + 57 旧用例删除；新链路 `CullingQueryStore→QueryBuilder→Assembler→SessionCache→LookupLoader→CullingRuntime`；**38 处 NOT_IMPLEMENTED 缺陷修复**；149 tests/10 suites。
- **R2-W2c 闭环**：`SimilarityService`(955)+`DuplicateService`(744)+`QualityService`(648) + 63 旧用例删除；16 路由 case 异步化；`CullingQualityInvalidationPort` 接线；`sim.writeback_items` 潜伏缺陷修复；209 tests/37 suites、app 172/19。
- **R4 Store 命令层**：CAS `markOutboxStatus(expectedRevision:)`、`recoverInterruptedOutbox`、`mergeOutboxPatches`（单事务）、`reconcileWritebackProjection`、`applyAcceptedRemoteValues`（单事务）、`clearReloadAckedAtForXmpPaths`、`metadataTargets`/`photoLookups`/`photoIdsByFilepath`、`mergeMetadata`（仅非 nil 覆盖）。
- **R4-2**：5 个 Metadata 支撑文件迁入 `Metadata/`（`git mv` 保历史）+ 5 处死码删除 + 31 用例。
- **设计资产**：`ARCHITECTURE-W2B/W2C/W2D/W4/W5-DESIGN.md` + `Services/` 清退清单 + R7 死代码裁决清单 + R8 门禁加固与出口定义。
- **度量**：`Services layer` 25→**13**；`unchecked Sendable` 22→**5**；`batchAsync` 6→**3**；`Runtime SQL` 0；门禁逐轮全绿（30+ 提交，无红态入库）。

### 待完成
| 步骤 | 内容 |
|---|---|
| R7 在途 | `ImagePreloadService`（82 行）+ 4 个 `image.*` case + `thumbnail.build` executor（**注意 `AnalysisJobType.thumbnailBuild` 枚举值保留**）；`photo.list`；4 个零调用 Store 方法；`FaceCluster`/`BindingData` 合并 |
| W2d（−4） | Navigation 558 / Export 617 / Indexer 1160 / FaceKw 1436：各自 Runtime actor → 装配 → 路由异步化 → 删旧（一域一轮 + 语义承接审计） |
| W4（−6） | `MetadataWriter` actor 吸收 `MetadataSyncCoordinator` 982 / `WritebackService` 790 / `MetadataService` 637 / `MetadataMutationService` 240 / `PhotoAssetResolver` 168（分读面 W4-3、写面 W4-4、写回面 W4-5；Store 命令已就绪） |
| R5 | 类型化 async API：111 命令 / 18 域子协议；删 `SessionCommandRouter`（17→0）、`awaitSync`（2→0）、`StubCommandRouter`（7→0） |
| R6 | UI 重写（Shell + 11 Feature），消费 typed API |
| R8 | 全部度量转 enforced + 出口核验（定义见 §12） |

### 执行纪律（血泪教训，务必遵守）
1. 不提交半成品；2. 不并行改同一文件（`SessionCommandRouter.swift` 单写者）；3. 删旧必做语义承接审计（未覆盖必补用例）；4. **Swift 大文件禁行级/括号级文本手术**（曾致 router 括号差 −1，已回退）；5. **括号差 + 小步编译**为提交前强制门；6. 取消/超时类测试必须限时（无界轮询会导致 swift-testing 挂起）；7. app 包特性目录在**包根**，提交须 `git add desktop/native/gather-app`（整包）。
| round 73–75：Navigation 删旧前的语义承接审计结论 | 审计完成 | 新套件已覆盖：merge 校验、split 越界、list 过滤与时间回填、analyze 落库与指纹缓存、merge 排序/最小/类型不匹配。**未覆盖需迁移 6 项**：①`rejectsUnsafeOrInvertedIntervals`（analyze 参数校验）②`recomputesWhenThresholdsChange`（阈值变化重算、不复用缓存）③`manualOverridesScopedToOwnType`（persistAutomatic 保留 manual 成员）④`closedEyeWarningPenalizedInLead`（lead 选择闭眼惩罚，`NavigationAssembler.withLead`/`safeQuality`）⑤`filenameSequenceExtractsTrailingDigits` ⑥`hammingDistanceCountsBits`（纯函数 → 新建 `NavigationAssemblerTests`）。**迁移完成并全绿后才允许删除 `Services/NavigationService.swift`（255 行）与旧测试文件**，随后 baseline `Services layer 12→11`。 |

| round 78–79：构建挂起根因 = 孤儿 swift 进程占用 scratch 锁 | 已修复 | 实测发现 4 个孤儿进程（`swift-build --scratch-path /private/tmp/gather-build-main` 已运行 2h53m / 2h42m / 47m，另有 `swiftpm-testing-helper` 3h37m）持续持有 SwiftPM 包锁 → 后续所有 build/test 排队，表现为「永远 running」。**处置**：`pkill -9 -f 'swift-build '` / `'swift-test '` / `swiftpm-testing-helper` 清理后，新 scratch 的测试**立即返回**。**纪律第 8 条**：①主代理验证统一用独立 scratch（`/private/tmp/gather-build-<用途>`），不与子代理共用 ②每轮开始前清理孤儿 swift 进程。 |

| round 80：Navigation 语义迁移 5/6 完成 | 进行中 | 已迁移：①`filenameSequenceExtractsTrailingDigits` ②`hammingDistanceCountsBits`（→`NavigationAssemblerTests`，2 tests 绿）③`analyzeRejectsUnsafeOrInvertedIntervals` ④`analyzeRecomputesWhenThresholdsChange` ⑤`analyzePreservesManualGroups`（→`NavigationSemanticsTests`，3 tests 绿，`--filter` 实测通过）。**仅剩 1 项待迁移**：`closedEyeWarningPenalizedInLead`（lead 选择闭眼惩罚，需构造 quality/警告数据；待补后再删 `Services/NavigationService.swift`）。 |

| round 81：删除 NavigationService（255 行）+ 旧测试；语义迁移 5/6 + 1 项债务 | 已完成（含债务） | 删除 `Services/NavigationService.swift` 与 `Tests/.../Services/NavigationServiceTests.swift`，`Services layer 12→11`；router 头部 2 处注释改指 NavigationRuntime。语义承接 5/6（见 round 80 行）。**待补测试债务 D1**：`closedEyeWarningPenalizedInLead`（lead 选择闭眼惩罚）未迁移——旧用例需构造 assets/asset_files/asset_analysis 三类行的 45 行前置数据；**必须在 R8 出口前补齐**（建议落在 `NavigationAssemblerTests`，直接测 `NavigationAssembler.withLead`/`safeQuality` 的惩罚分支，避免重造资产表）。 |

| round 82：债务 D1 实施要点已取证 | 规划 | `NavigationAssembler.withLead(group:byId:)` 与 `safeQuality(value:)` 均为 public 纯函数，可直接测惩罚分支，无需重造资产表。`CaptureRow`（嵌套）字段与 init 顺序：id, filepath, filename, capturedAt, cameraModel, hashHex, rating(Double), qualityScore(Double), qualityWarnings([String]), hasQuality(Bool)。惩罚规则：warnings 含 closed_eye_risk_heuristic 或 closed_eye_risk 时减 0.25；排序键 qualityScore + rating*0.08 - penalty 降序；无任何 quality 时按 rating 降序。D1 测试写法：p1(score 0.5, 空警告, rating 0) 与 p2(score 0.6, 含闭眼警告, rating 0)，组 photoIds=[p2,p1] → 期望 leadPhotoId 为 p1。 |
| round 83：**债务 D1 已清账** | 已完成 | `NavigationAssemblerTests.closedEyeWarningPenalizesLeadSelection`：p1(score 0.5, 无警告) vs p2(score 0.6, 含 closed_eye_risk_heuristic)，组 photoIds=[p2,p1] → 断言 `leadPhotoId == "p1"`（0.5 > 0.6−0.25）。验证：`--filter NavigationAssemblerTests` → **3 tests/1 suite 全绿**。Navigation 旧服务的 6 项语义**全部承接完毕**；`Services/NavigationService.swift` 删除后无遗留语义债务。 |
| round 98：ExportAssemblerTests 2 处失败已定因（测试期望缺陷，非实现缺陷） | 待修测试 | 失败：`sessionSummaryCsvHeaderRowCountAndEscaping`（期望 `content.split(separator: "\n").count == 4`）与 `sessionSummaryMdHeaderAndRowCount`（期望 == 8）。**定因**：CSV 用例的输入含**字段内换行**（`/shoot\nx`），`csvField` 按 RFC 将其整体加引号 → 该记录跨两物理行，故 `split(separator: "\n")` 计数必然大于逻辑行数；实现校验无误（`csvField`：含 `,`/`"`/`\n` 才加引号并把 `"` 双写；`mdField`：`|`→`\|`、`\n`→空格；`sessionSummary` 表头 `filename,filepath,status` 与 MD 表头/分隔行逐字移植）。**修法**：测试改为按 CSV 记录边界计数（或该用例去掉字段内换行，另设一个专门断言引号包裹的用例），并保留对 `"a,""b"""` 转义的正确期望。 |
| round 104–108：expsw / mwwrite1 两切片连续 4 轮零落盘，已终止 | 处置 | 依纪律（不提交半成品、不无限等待）终止两切片并释放资源。**结论（再次验证）**：子代理在"需先读多处既有实现再动笔"的任务上极易陷入零产出；本 session 高产出切片均为"单文件/单方法 + 第一动作即落盘"。**下一步改为主代理直接执行**：①Export 删旧：先用 4 处装配替换把 `export.*` 切到 `ExportRuntime`（同 Navigation 的 3 行模式）→ 编译 → 删 `Services/ExportService.swift`(461 行) 与旧测试 → baseline 11→10 → 未迁移端到端语义（checkpoint 续传、ImageIO 转换）登记为债务 ②`MetadataWriter` 写面：先落 `schedule` 最小骨架（`ScheduleEntry{ticket,generation,phase}` + `nonisolated schedule`）→ 编译 → 再增量补 CAS/5 档退避/`MutationTicket` FIFO。 |
| round 109：Export 装配切换所需接线取证（供下一步直接落盘） | 取证完成 | `ExportRuntime.dependencies` 形状：`ExportRuntime(dependencies: .init(photoStore:sessionStore:reportSource:fileSystem:imageConverter:xmpProvider:dateProvider:temporaryFileName:))`；接缝默认实现可直接构造（`DiskExportFileSystem()`、`SystemExportImageConverter()`、report source 同名默认类型均有 `public init()`）。router 侧待改 4 处：`112` 字段 `public let exportService: ExportService`、`136` init 形参、`163` 赋值、`286` 构造（`ExportService(photoStore:sessionStore:database:)` → `ExportRuntime(...)`）；另 `394` 透传、`518` executor 注册（`[exportService]` → `[exportRuntime]`）、`535/536` 取消与执行调用点（`exportService.cancel/execute` → runtime 同名方法）。`export.*` 4 case 与错误映射随后同批确认（错误码 `EXPORT_*` 逐字不变）。 |
| round 111：Export 切换**发现隐藏前置**——`ExportReportSource` 无任何 conformer | 阻塞已定位 | `ExportRuntime.swift:206` 声明 `public protocol ExportReportSource { sessionSummaryRows/personRows/keywordRows/cullingDecisionRows }`，但**全仓无实现类型**（`grep ': ExportReportSource'` 0 命中）。该协议是 `Dependencies` 的**必填**参数（无默认值），故 Export 切换**不能只做 7 处装配替换**：必须先把旧 `ExportService.generateReport` 里的 4 条报告查询下沉为 **Store 方法**（遵守"Store 是唯一 SQL 所有者"的 R1 约束）并提供一个 `SQLiteExportReportSource(store:)` 实现，再装配。**动作**：①确认 `ExportService.swift` 中 4 条查询的现状 ②在 `Store/` 增加对应读方法（若已有可复用则复用）③新增 `Runtime/Export/SQLiteExportReportSource.swift` ④再执行 7 处替换与删旧。此发现再次说明：**切换前必须做"依赖闭合性"检查**（协议是否都有生产实现、是否有默认值），该检查已加入切换清单。 |
| round 119：Export 装配替换首试回退（签名差异已取证） | 已回退 | 3 处替换后编译暴露差异：①`Dependencies.init` 的 `fileSystem` **无默认值**（只有 `imageConverter` 有），需显式传 `DiskExportFileSystem()` ②`ExportRuntime.cancel` 签名为 `cancel(_ sessionId:) async throws`（**无标签、async**），router 两处 `cancel(sessionId:)` 需改 `Task { try? await exportService.cancel(job.scopeId) }` ③`preview`/`report` 收**参数对象**（`ExportPreviewParams`/`ExportReportParams`）而非旧服务的散参，`execute` 签名待核。**已 `git checkout` 回退，HEAD 保持全绿**。下一步按此清单一次性完成替换并编译。 |
| round 124：Export 装配替换第二批差异取证（3 处参数映射） | 已回退 | 第一批（字段/init 形参/构造含 `fileSystem: DiskExportFileSystem()` + `reportSource` + `cancel` 两处 Task 包装）替换成功后，剩余 **3 处参数映射**：①`export.preview`：旧传散参/String → `ExportRuntime.preview(_ params: ExportPreviewParams)` 需构造 `ExportPreviewParams` ②`export.execute`：app 侧 `NativeExportResumeState` → 运行时要求 `ExportResumeState`（**需写映射函数**：`destinations`/`completedPhotoIds` 字段对应）③`export.report`：`generateReport(...)` → `report(_ params: ExportReportParams)`。**已回退，HEAD 全绿**。下一步按此 3 处映射一次性完成，再删旧服务。 |
## 14. 最终交接快照（round 128/128，HEAD `94fa495`，65 个绿态提交）

### 已收官
- **R1**：`DB.swift`（352 行）删除；Store 为唯一 SQL 所有者（`DB layer=0`、`raw SQL outside Store=0`）。
- **R3**：`JobService`/`JobScheduler`/`AnalysisWorker`（1006 行）删除；`JobRunner` 为唯一作业层（语义迁移 +5 例；app 172/19 全绿）。
- **R2 三域闭环**：Culling（`CullingService` 2550 行 + 57 用例删除；38 处 NOT_IMPLEMENTED 修复；149 tests/10 suites）· Similarity+Duplicate+Quality（2347 行 + 63 用例删除；16 路由 case 异步化）· Navigation（255 行 + 旧测试删除；**6/6 语义承接、零债务**；26 tests/5 suites）。
- **R4-2**：5 个 Metadata 支撑文件 `git mv` 入 `Metadata/`（保留历史）+ 5 处死码删除 + 31 用例。
- **R7 主要死码**：`image.*` 4 命令 + `ImagePreloadService`（82 行）+ `photo.list`（31 行）删除。

### 关键资产（可直接续作）
- **Runtime 层**：Culling · Similarity · Duplicate · Quality · Jobs · Navigation（Assembler+Runtime+Error）· **Export**（Assembler 283 行 + Runtime actor + `SQLiteExportReportSource`）· **MetadataWriter**（读面 5/5 + `providerSet` + `MetadataWriterError`）。
- **Store 命令层**：`markOutboxStatus(expectedRevision:)` CAS · `mergeOutboxPatches`（单事务）· `reconcileWritebackProjection`（单写者投影）· `applyAcceptedRemoteValues`（单事务）· `recoverInterruptedOutbox` · `clearReloadAckedAtForXmpPaths` · `metadataTargets`/`photoLookups`/`photoIdsByFilepath` · `mergeMetadata`（仅非 nil 覆盖）· `ExportStore`（4 报告查询）。
- **设计文档**：`W2B`/`W2C`/`W2D`/`W4`/`W5-DESIGN.md` + `Services/` 清退清单（11→3 路线）+ R7 裁决清单 + R8 门禁加固/出口定义 + 本文档 §10–§14。

### 剩余路线（按序）
1. **Export 切换收尾**：按 §（round 119/124 两批差异）8 步执行 → 删 `ExportService`（461 行）→ baseline `Services 11→10`。
2. **W4 写面**：`MetadataWriter.schedule` 骨架 → CAS · 5 档退避 · `MutationTicket` FIFO → 写回面 → 吸收 `MetadataSyncCoordinator`/`WritebackService`/`MetadataService`/`MetadataMutationService`/`PhotoAssetResolver`（`Services` → 5）。
3. **W2d 余 2 域**：Indexer 1160 · FaceKw 1436（各自一轮，Nav/Export 模板）。
4. **R5**：typed API（111 命令 / 18 域子协议 / `SessionCommandRouter 17→0` / `awaitSync 2→0` / `StubCommandRouter 7→0`）。
5. **R6**：UI 重写（Shell + 11 Feature）。6. **R8**：全部度量转 enforced + 出口核验。

### 环境注意事项（本会话踩坑）
- SwiftPM scratch **不共用**；每轮开始 `pkill -9 -f 'swift-build '`、`'swift-test '`、`swiftpm-testing-helper` 清理孤儿进程（曾致多轮「构建永不返回」）。
- app 包特性目录在**包根**，提交用 `git add desktop/native/gather-app`（整包）。
- 大文件禁用行级/括号级文本手术；改前改后均做**括号差自检**（必须 0）。
- 取消/超时类测试**必须限时**，禁止无界轮询（曾致 swift-testing 挂起）。
| round 133：**R2 第 4 域（Export）闭环** | ✅ 完成 | 提交链 `b0b499c`（路由切至 `ExportRuntime` + 删 `ExportService` 461 行与旧测试 + baseline 11→10）→ `33cd619`（语义承接：迁移 `ExportError`（原 `ExportServiceError`，码/文案逐字，全局改名 5 文件）+ `NativeExportProgress`/`NativeExportResumeState` 契约类型入 `Runtime/Export/ExportProgress.swift`）→ `b9b67ed`（app 侧改名收尾）。装配细节：`exportService` 字段/init/构造 → `ExportRuntime(dependencies: .init(photoStore:sessionStore:reportSource: SQLiteExportReportSource(store: SQLiteExportStore(database:)), fileSystem: DiskExportFileSystem()))`；`cancel(sessionId:)` 两处 → `Task { try? await exportService.cancel(...) }`；`preview` → `ExportPreviewParams`；`execute` → `ExportExecuteParams(confirmed: true)` + `ExportResumeState`（`onPlanned`/`onPlanReady`/`onCompleted` 改独立参数）；`generateReport` → `report(ExportReportParams)`。**验证**：core `--build-tests` 0 error；`--filter Export` → **49 tests/3 suites 全绿**；app → **172 tests/19 suites 全绿**（无 flake）；门禁 OK；`Services layer=10`。**教训**：删旧服务后暴露两类隐藏语义（错误类型、进度/续传契约类型），证明"删前依赖闭合性检查"必须包含**类型级依赖扫描**（`grep` 被删文件中的 `public struct/enum/class` 并在外部搜索引用）。 |
| round 160：W4-4 ④ `mutationTails` 入库（`d11fa85`） | ✅ 完成 | 同路径串行链：`enqueue` 进入 `inFlight` 前取前序 tail，新任务 `await previous?.value` 后再执行（占位写回落点），随后 `settle`（仍受 ticket guard 保护）。**偏差（已接受）**：task 显式标注 `Task<Void, Never>`——因 `previous?.value` 会推断为 `Void?`。**遗留（下一步清理）**：`mutationTails` 按路径保留链尾，已完成的前序 task 随链存活于字典中，需在 `shutdown()` / 清理步骤统一释放；`readyQueue` 消费与 `shutdown(timeoutMs:)` 仍待实现。验证：25 tests/5 suites 全绿；括号差 0。 |
| round 172：`assetFileStatsBySession` 契约要点（供 idxbase 与后续接线） | 已入库（`b61d2fc`） | **键 = `asset_files.id`（即 `photos.asset_file_id`），不是 photoId**——旧实现 `fileStats[af.id]`，消费处 `photo.assetFileId.flatMap { fileStats[$0] }`；若改 photoId 需改 SELECT 列（与"列序不变"冲突）。SQL 逐字搬自 `IndexerService.swift:207-210`（`SELECT af.id, af.file_size, af.file_mtime_ms, af.checksum FROM asset_files af JOIN photos p ON p.asset_file_id = af.id WHERE p.session_id = ?`）。测试 2 例全绿。**两条工具教训**：①`grep 'SELECT'` 在 Runtime 层有 3 处误命中（`CULLING_EMPTY_SELECTION` 子串），校验 R1 时需排除该标识符；②`read` 工具读超长文件（如 AssetStore.swift 1334 行）会静默截断（曾致括号统计误报 3），**括号/行数校验一律以 bash 计数为准**。 |
| round 183：`MetadataWriter.start()` 语义与第 5 项操作裁决 | 已接受 | `start()` = 清终止态（`isShutDown=false`）+ 丢弃残留（`entries`/`readyQueue`/`activeWrites`/`mutationTails` 全部清空，清后 generation 从 1 重新计数）。**代理报告的不符（指令只列 4 项、未含 `entries`）已裁决为接受**：`scheduleSnapshot` 只读 `entries`，若不清则无法兑现「丢弃关停前残留」语义；且与 `docs/ARCHITECTURE-W4-DESIGN.md` 不变量 **I1「start 后 entries 与 Store 集合相等」**方向一致。测试 **30 tests/5 suites 全绿**（含 2 个 start 用例）。 |
| round 184：**Indexer 写库/对账停止点与 Store 缺口清单（M1–M4）** | 已完成取证，待补 Store | idx2b4 按指令**停止且未改任何文件**（`IndexerRuntime.swift` 307 行 sha256 未变），产出可直接执行的缺口分析：**M1** `PhotoStore.purgeGeneratedCachePhotos(photoIds:sessionId:)`（旧 162-201 单事务 4 条 DELETE：photos / session_assets 孤儿 / asset_files 孤儿 / assets 孤儿；**注意清扫后须从 existing/existingByPath 重算**，否则缓存目录内被排除的存量照片会被误判 missing）；**M2** `AssetStore.applyScannedFiles(_ updates:[AssetFileScanUpdate]) -> 受影响 photoIds`（旧 371-408 批事务：无 asset_files 扫描字段 UPDATE、`DELETE asset_analysis`、photos 按 asset_file_id 全量刷新 checksum/size/mtime/width/height、读取受影响 photoIds）；**M3** `AssetStore.invalidatePathDependentAnalysis(photoIds:)`（旧 413 → 797-833 + 706-793：distinct session_id → 删 face_cluster_state/members/role_bindings/face_clusters、similarity_results、similarity_hashes/face_observations/face_analysis_state/asset_analysis/photo_metadata_cache、prune 自动导航组）；**M4** `AssetStore.markAssetFilesOffline(ids:updatedAt:)`（旧 545-554 UPDATE online_status='offline'）。**已覆盖方法**：SessionStore.get · PhotoStore.getBySessionProjection/updateIndexedFile/updateChecksum/addPhotos/markMissing/countBySession · AssetStore.relinkMovedFile/backfillSession/assetFileStatsBySession · SessionStore.updatePhotoCount/updateStatus/bumpIndexSeq。**IndexScanResult 映射**：discovered=walk 支持图片数；added=ΣPhotoAddResult.added；skipped=unchanged+relinked+Σskipped；missing=IndexAssembler.missingPhotos(...) 数（随后 markMissing + asset_files offline）；failed=不可读非根+getDimensions/fileHasher/relink 失败；取消按 32 分块批间检查；取消/出错 catch 若已发生变更须 best-effort bumpIndexSeq。**其余**：`Dependencies.database` 在本步无 SQL 可用（R1）；`IndexScanParams` 无 requestedPaths，增量分支暂不可接入。基线：build 0 error · `--filter Index` 44/17 全绿 · Runtime 层 SQL 0 命中 · 括号 82/82、50/50、29/29。 |
| round 187：M4（`markAssetFilesOffline`）**主代理落盘素材已就绪**（供下一轮直接执行） | 取证完成 | SQL 原文（`IndexerService.swift:548-552`）：`UPDATE asset_files SET online_status = 'offline', updated_at = ? WHERE id IN (placeholders)`，参数 `[.text(updatedAt)] + chunk.map { .text($0) }`，按 `IndexAssembler.chunked(fileIds)` 分块，仅当 `missing` 非空时执行。**插入点**：`Store/AssetStore.swift` 协议区第 62 行 `assetFileStatsBySession` 之后加 `@discardableResult func markAssetFilesOffline(ids: [String], updatedAt: String) async throws -> Int`；实现区在 `assetFileStatsBySession` 实现（约 L210-232，末尾 `return baselines` + `}`）之后、`listCandidates` 之前插入同签名实现（`guard !ids.isEmpty else { return 0 }`；**分块用本地 `stride(from:to:by: 200)` 而非 `IndexAssembler.chunked`**，避免 Store→Runtime 反向依赖；`database.run(...)` 的返回值类型需按 `SQLiteDatabase` 定义确认后决定是否累加）。**注意**：`updatedAt` 为 ISO 字符串（旧实现传 `nowISOString()`）。 |