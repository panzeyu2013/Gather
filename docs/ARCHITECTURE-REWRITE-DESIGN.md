# Gather 重写设计冻结稿（R1：Store 层）

> 配套：docs/ARCHITECTURE-REFACTOR-PLAN.md v2（R0-R8）、docs/ARCHITECTURE-AUDIT.md（问题证据）
> 状态：R1 设计冻结。本稿定义新持久化层的接口与规则，实现按本稿落地。
> 硬约束：R1 合并单元内必须删除旧持久化实现，不保留兼容层。

---

## 1. 目标与边界

R1 交付 Store 层：GatherCore 中唯一允许出现 SQL 的层。

- 旧实现（R1 结束时删除）：Database/DB.swift、Schema.swift、Migrations.swift、ImageCache.swift、Repositories/*.swift（17 文件，5,612 行）。
- 新实现：Sources/GatherCore/Store/。
- 上层（Services/Runtime、app）不再直接持有 SQL 或连接；只依赖 Store 协议。

已完成（本稿冻结的实现）：SQLiteDatabase actor、SQLiteValue、SQLiteRow + 键行解码（11 个单测全绿）。

---

## 2. 分层与依赖

~~~text
Runtime (R2, actor)  ──依赖──>  Store 协议 (Sendable)  ──实现──>  SQLiteStore 结构体
                                                                    │
                                                              SQLiteDatabase (actor)
                                                                    │
                                                              CSQLite / sqlite3
~~~

规则：

1. Store/ 之外不得出现 prepare(/exec(/SQL 字符串（CI scripts/check-no-legacy.sh 在 R1 收尾时把 tracked 规则转为 enforced）；
2. Store 实现是无状态 struct（持有 SQLiteDatabase 引用），协议标注 Sendable；
3. 记录类型（Record）是 Sendable + Equatable + Decodable 的值类型，无业务方法；
4. 事务边界由 Store 提供，业务编排在 Runtime 层用 database.transaction { ... } 组合多个 Store 调用。

---

## 3. 已冻结 API

### 3.1 SQLiteDatabase（actor）

~~~swift
public actor SQLiteDatabase {
    public init(path: String, configuration: Configuration = .init()) throws
    public func close()
    public var isOpen: Bool
    public var cachedStatementCount: Int          // 测试观察
    public var currentTransactionDepth: Int       // 测试观察
    public var lastInsertRowID: Int64
    public var changes: Int

    @discardableResult public func execute(_ sql: String) throws -> Int
    @discardableResult public func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int
    public func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow]
    public func queryOne(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteRow?
    public func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64?
    public func transaction<T>(_ body: (isolated SQLiteDatabase) throws -> T) throws -> T
}
~~~

配置默认值：busyTimeoutMs=5000、journalMode=WAL、foreignKeys=ON、synchronous=FULL（保持旧层默认，不静默降低持久性）、statementCacheCapacity=256、readOnly=false。

错误模型：

~~~swift
public struct SQLiteFailure: Error, Equatable, Sendable {
    public enum Phase: String { case open, prepare, bind, step, close, pragma, other }
    public let phase: Phase
    public let code: Int32          // sqlite3 主码
    public let extended: Int32      // 扩展码
    public let message: String
    public let sql: String?
    public var isConstraintViolation: Bool
    public var isUniqueViolation: Bool
    public var isBusy: Bool
    public var isMisuse: Bool
}
~~~

### 3.2 SQLiteValue / SQLiteRow

- SQLiteValue：.null/.int(Int64)/.real(Double)/.text(String)/.blob(Data)，支持字面量（字符串、整数、浮点、布尔、nil）。
- SQLiteRow：values: [String: SQLiteValue] + columnOrder；取值按列名；提供 requiredText/requiredInt 与 decode<T: Decodable>(_:)。
- 解码约定：属性名 = 列名（snake_case 用 CodingKeys 映射）；复合字段（数组/字典）从 TEXT/BLOB 中的 JSON 解码；Data 走 BLOB。

### 3.3 迁移（R1 后续实现，接口先冻结）

~~~swift
public struct MigrationStep: Sendable {
    public let version: Int
    public let description: String
    public let up: @Sendable (isolated SQLiteDatabase) throws -> Void
}

public enum StoreSchema {
    public static let currentVersion = 33
    public static let ddl: [String]          // 唯一 DDL 来源（CREATE TABLE / INDEX）
    public static let steps: [MigrationStep] // 历史迁移，只做数据变换
}

public struct StoreMigrator: Sendable {
    public init(databasePath: String, backupDirectory: String?)
    public func migrate(_ database: SQLiteDatabase) async throws
}
~~~

- 历史语义不变：空库 = ddl + 全部 steps；已有库 = 按 version 递增执行 steps；
- ADR-005 语义保留：磁盘空间检查 → wal_checkpoint(TRUNCATE) → SQLite backup API → 完整性校验 → 失败恢复 → 迁移后 foreign_key_check + 列不变量 + 版本校验；
- StoreSchema.ddl 是唯一 DDL 来源，steps 不再写 CREATE TABLE（旧层两处 DDL 漂移问题在此消除）；
- 新增列级 schema 快照测试（表/列/类型/默认值/索引/FK）。

---

## 4. Store 清单与表归属（43 表 → 16 Store）

| Store | 表 | 旧 Repo 对应 |
|---|---|---|
| SessionStore | sessions, session_assets | SessionRepo |
| PhotoStore | photos | PhotoRepo |
| AssetStore | assets, asset_files, asset_members, asset_link_candidates, asset_backfill_state, asset_file_metadata, sidecar_bindings, sidecar_binding_files, sidecar_metadata_state | AssetRepo |
| CullingStore | culling_decisions, culling_history | CullingDecisionRepo, CullingHistoryRepo |
| FaceStore | face_observations, face_clusters, face_cluster_members, face_cluster_state, face_analysis_state, role_bindings | FaceRepo |
| PersonStore | persons, person_photos, person_embeddings | PersonRepo |
| SimilarityStore | similarity_hashes, similarity_results, similarity_result_members, similarity_cluster_state, similarity_cluster_meta | SimilarityResultRepo, SimilarityClusterStateRepo |
| DuplicateStore | duplicate_groups, duplicate_group_members | （旧为 DuplicateService 内联 SQL） |
| MetadataStore | photo_metadata_cache, metadata_keyword_origins | MetadataCacheRepo, MetadataKeywordOriginRepo |
| WritebackStore | metadata_outbox, metadata_outbox_sessions, writeback_items | MetadataOutboxRepo, WritebackRepo |
| JobStore | analysis_jobs, analysis_runs, asset_analysis | AnalysisJobRepo（+ 内联 analysis_runs/asset_analysis SQL） |
| SettingsStore | app_settings | SettingsRepo |
| SmartAlbumStore | smart_albums | SmartAlbumRepo |
| TemplateStore | workflow_templates | （旧为 TemplateService 内联 SQL） |
| NavigationStore | navigation_groups | （旧为 NavigationService 内联 SQL） |
| SchemaVersionStore | schema_version | 旧 Migrations 内建 |

协议样例（以 PhotoStore 为例，其余同构）：

~~~swift
public protocol PhotoStore: Sendable {
    func insert(_ photos: [PhotoInsert]) async throws
    func get(id: String) async throws -> PhotoRecord?
    func page(sessionId: String, afterRowId: Int64?, limit: Int) async throws -> [PhotoPageRecord]
    func preferredVariantKeys(sessionId: String) async throws -> [String: String]
    func countLogicalAssets(sessionId: String) async throws -> Int
    func updateChecksum(id: String, checksum: String, fileSize: Int64, mtimeMs: Double) async throws
    func delete(ids: [String]) async throws
}
~~~

约束：

- 分页一律 keyset（afterRowId），不再新增 LIMIT/OFFSET；
- 逻辑资产分组统一用 COALESCE(NULLIF(asset_id,''),id)（由 Store 生成，调用方不写表达式）；
- 删除级联由 StoreSchema.ddl 的 ON DELETE CASCADE 定义，不再靠调用顺序；
- 需要跨表原子性的操作在 Runtime 层用 database.transaction 组合。

---

## 5. R1 实施顺序（每步保持 789 oracle 测试全绿）

1. ✅ 基座：SQLiteValue / SQLiteRow / SQLiteDatabase + 单测（11 tests，含多语句 DDL 修复）；
2. ✅ StoreSchema：Schema.swift 以 git mv 迁入 Store（SQL 逐字保留）+ 结构漂移门禁（DDL 路径 vs 33 步迁移链，指纹一致）；
   - 门禁抓出并修复两处真实漂移：face_clusters 缺 synced_to_library/match_confidence；metadata_outbox.source_module 列序与 ALTER 追加位置不一致；
3. ✅ StoreMigrator：Migrations.swift 的 33 步迁为 [MigrationStep]（历史 SQL 逐字保留，只改承载方式）+ 备份/恢复/不变量；
   - 双跑等价性：空库与真实库 fixture（v32）在新旧执行器下结构指纹 + 数据摘要完全一致；hook 抛错后回滚到原版本；
   - 旧 MigrationRunner 仍在生产路径上（app 尚未切到 SQLiteDatabase），R1 收尾时一并删除。
4. Store 逐个实现（顺序：Settings → Session → Photo → Asset → Culling → Similarity → Metadata → Writeback → Job → Face → Person → Duplicate → SmartAlbum → Template → Navigation），每个 Store 迁移旧 Repo 测试为 Store 测试；
   - 进度：Settings / Session / Photo / Culling / Similarity / Metadata / Job / SmartAlbum / Writeback（含 writeback_items）已完成（111 个测试全绿）；AssetStore 已完整（只读 + relink/候选/对账 + backfill/ensurePhoto）；PersonStore 已完整（CRUD/计数/照片桥接/merge/嵌入/reconcileSession/明细查询）；FaceStore 已完整（观察/分析状态/复用/聚类/绑定）；TemplateStore 已从 TemplateService 抽出（CRUD + config JSON，服务保留 apply 编排）；NavigationStore 已抽出（组 CRUD/自动组替换 + 拍摄行查询，分组算法留服务层）；DuplicateStore 已抽出（校验列/视觉 hash 落库、精确分组、分组重建、决议与状态重算，聚类与评分留服务层）——16/16 Store 完成；API 基座（AppContainer + GatherAPI.settings/sessions）已落地；R1 首个删除切片完成：SettingsService/SettingsRepo 及其旧测试删除，路由改经 SettingsAPI（异步写）+ SettingsSnapshot（同步读），TemplateService 已删除，模板 CRUD 与 apply 校验收敛到 GatherAPI.templates（TemplateError）；路由 template.* 与 settings 写路径均为异步入口；WorkspaceStatusService 已删除，工作区状态聚合与 TTL 缓存收敛到 WorkspaceAPI（路由与 Dashboard 均已切换）；PersonsAPI 已落地（person.* 全部异步化，app persons 层改 async），PersonRepo 与 FaceRepo 均已删除（FaceKwService 全面改经 PersonStore/FaceStore，SessionService 人脸删除改经 Store，fkw.*/photo.list_page/session.create_from_directory 异步化）；PhotoFormats 已收敛为格式常量单一来源；StoreSupport 收纳 Array.chunked(by:) 与 sqlValue 绑定助手；CullingStore 用 CullingStoreError 取代旧字符串错误；SimilarityStore 把成员映射缓存移到独立 actor（Store 本身保持无状态 Sendable）；MetadataCacheInput 已迁入 Store；
5. 调用点迁移：Services 从旧 Repo/DBConnection 切到 Store 协议（此步不改变 Service 的并发模型）；
6. 删除：Database/DB.swift、Schema.swift、Migrations.swift、ImageCache.swift、Repositories/**；check-no-legacy.sh 的 raw-SQL 规则转 enforced；
7. 验证：core 全量测试 + v32 真实库升级/读写一致性 + build.sh。

---

## 6. 验证矩阵

| 验证 | 命令/方式 |
|---|---|
| 基座单测 | swift test --filter SQLiteDatabaseTests |
| oracle 回归 | swift test --package-path desktop/native/gather-core（789+ 全绿） |
| 数据兼容 | /private/tmp/gather-fixture/gather-v33.sqlite（真实库，schema v32）→ 迁移到 v33 后逐表校验 + 关键表行数一致 |
| 结构一致 | 列级 schema 快照（PRAGMA table_info/index_list/foreign_key_list 归一化） |
| legacy 边界 | scripts/check-no-legacy.sh（raw SQL 规则转 enforced） |
| 构建 | ./desktop/native/build.sh |

---

## 7. 开放决策（需要产品/负责人确认）

1. 审计历史（culling_history）保留策略：旧实现无限增长；R1 是否加保留上限/归档（影响 Store API）。
2. asset_id='' 的规范化：迁移 v-next 是否把空串统一为 NULL（与 ExportService 分组缺陷同源）。
3. synchronous 默认值：保持 FULL（本稿默认）还是切 NORMAL（性能/持久性取舍）。
4. ImageCache 去留：旧磁盘缩略图缓存无生产调用；R1 删除还是由 Store 重新承载（对应 R7 裁决）。

## R2 服务 → async Store 迁移模板（由 R1 五个删除切片固化）

每个子系统按同一顺序推进，保证「同一合并单元内删除旧实现」：

1. **Store 落地**：新 `Store/XxxStore.swift`（actor/无状态 Sendable struct + SQLiteDatabase），
   从旧 Repo/Service 抽出 SQL，记录类型用 Decodable + snake_case CodingKeys；
   旧 Repo 中仍被外部引用的纯 DTO 迁入 Store（单一来源）。
2. **API 投影**：在 `API/GatherAPI.swift` 增加命名空间（如 `templates/albums/persons/workspace`），
   把旧 Service 的领域编排与 Protocol DTO 投影搬进 API 层；错误类型随之迁入（如 TemplateError）。
3. **调用点异步化**：
   - 同步世界（router 的 `execute`、旧 Service 注入的闭包）改为 async；
   - SessionCommandRouter：把命令 case 迁入 `executeAsync`，保留参数校验与错误映射；
   - 顺带移除 `awaitSync` 桥（度量递减）。
4. **同批删除**：旧 Repo/Service 与其旧测试在同一提交删除；若旧测试覆盖的语义未被端口测试覆盖，
   先把等价断言补进新测试再删。若旧测试文件里混有别的子系统的遗留套件，一并按覆盖情况裁决。
5. **度量与文档**：运行 `scripts/check-no-legacy.sh`，更新本文件与
   `docs/ARCHITECTURE-REFACTOR-PLAN.md`（进度表 + 旧层文件计数）。

已完成切片：settings、template、smart album、workspace、person（以及 face 正在推进）。


## R1 收尾：MetadataOutboxRepo → WritebackStore（迁移简报，round 41 盘点）

**目标**：删除 `Database/Repositories/MetadataOutboxRepo.swift`（451 行）+ `MetadataOutboxRepoTests`，outbox 行读写全部收敛到 `SQLiteWritebackStore` 的 outbox 半边（`mergeOutboxPatch` / `claimOutbox` / `markOutboxWritten` / `recoverableOutbox` / `orphanOutbox` / `markSessionSynced` / `discardModulePending` …，共 87 个方法中含完整 outbox 面）。

**调用点盘点（`outboxRepo.` / `metadataOutboxRepo.`）**

| 文件 | 调用数 | 备注 |
| --- | --- | --- |
| `Services/MetadataSyncCoordinator.swift` | 38 | 跨 17 个函数；**6 个同步函数是阻塞点**：`start` / `getSummary` / `listOrphans` / `confirmSync` / `clearReloadAckForXmpPath` / `emitPathSummaries`（其余 11 个已 async：processRow/cleanup/finalizeSession/resolveOrphan/resolveConflict/retrySession/processUntilCurrent/ensureBaseline/getConflicts/flushSession/waitForIdle） |
| `Services/CullingService.swift` | 3 | 已在 async 方法内 |
| `Services/WritebackService.swift` | 2 | 已在 async 方法内 |
| `Services/MetadataMutationService.swift` | 2 | 已是 async 端口 |

**执行顺序（建议）**
1. 先换协调器 11 个 async 路径（纯 `try` → `try await + store 方法名` 映射）。
2. 再处理 6 个同步函数：改为 async，并把路由 `metadata.*` / `culling.*` 对应 case 迁入 `executeAsync`（沿用既有 Task+completion 模板）。
3. CullingService/WritebackService/MetadataMutationService 的 7 处收尾。
4. 删除 Repo 与旧测试，同步 `makeDefault` 装配与测试 harness（文件库双连接），跑 core+app 全量 + 门禁。

**风险提示**：协调器的 `drain()/withSlot` 结构与 `start()` 同步初始化强耦合，第 2 步需保证 `start()` 的调用方（`SessionCommandRouter.makeDefault` 内）也在 async 上下文；建议把 `start()` 改为 `startAsync()` 或在其内部用 Task 启动，不引入 awaitSync 桥。

**round 43 实测结论（执行方式修正）**：对协调器做「全局正则替换 + 统一补 await」不可行——该文件存在嵌套闭包/局部函数（`nextIndex`/`markFailed`/`release` 等），
按行号推断函数边界不可靠，且同步/异步调用点交错，一次替换会同时踩中 6 个同步函数。**正确做法**：按函数名逐个替换（每次替换后单独 build），顺序为
`processRow → cleanup → finalizeSession → resolveOrphan → resolveConflict → retrySession → processUntilCurrent → ensureBaseline → getConflicts → flushSession → waitForIdle`，
再处理 `start/getSummary/listOrphans/confirmSync/clearReloadAckForXmpPath/emitPathSummaries`（同步 → async + 路由迁 `executeAsync`），最后删 Repo。
