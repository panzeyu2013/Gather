
# Gather 破坏性重构方案（开发期 · 2026-10-21）

> 前提（按你的指示）：
> 1. 项目处于开发阶段，**本地数据库可丢弃**，不需要兼容旧 schema / 旧数据。
> 2. 118 条命令面是**内部实现**，没有外部消费者，不需要 JSON 兼容层。
> 3. 不需要“旧路径 + 新路径”双跑、特性开关、伞形 target、迁移链、兼容测试。
> 4. 目标是一次性切到目标架构；允许大 PR，但要求每个 Cut 结束可编译、可启动、可回归。
>
> 与上一版《重构设计方案》的关系：上一版是“可上线产品的绞杀者方案”（183 人日 / 18-21 周）；本版是**开发期直接切换方案**（约 124 人日 / 11-13 周），删除兼容层、迁移链、双路径与影子测试。

---

## 0. 两版方案的核心差异

| 维度 | 保守版（已废弃） | 破坏性版（本方案） |
| --- | --- | --- |
| 命令面 | 保留 118 条 JSON 命令 + 生成目录 + 双 switch 过渡 | **删除 Router / JSON envelope / CommandID / 生成器**，UI 直接调用类型化 API |
| 模块 | GatherCore 伞 + @_exported 渐进拆分 | **不建伞**，一次性拆 7 个 target，直接改 import |
| 迁移 | 35 个版本 + registry + v34 fixture + 快照 v2 | **单份 SchemaV1**，版本不匹配即移走旧库重建；无迁移链 |
| 交付一致性 | 保留 outbox + writeback 两表 + intent + 双状态机 | **统一 delivery 模型**（deliveries / delivery_sessions / delivery_items / delivery_intents） |
| 任务状态 | 迁移期清洗 + CHECK/触发器二选一 | **SchemaV1 直接带 CHECK**，无清洗、无 12-step rebuild |
| 本地化 | 保留 .id 的回退方案 | **LanguageStore + Environment 一次切换**，删除 .id |
| 算法 | 新旧并存 + 开关 + 对账后删 | **同一 Cut 删旧实现**，保留测试断言，不留运行时开关 |
| 测试 | 118 命令黄金清单、旧 errorMessage oracle、迁移 fixture | **API 行为测试 + 新 schema 测试**；兼容测试直接删除 |
| 工作量 | 183 人日 / 18-21 周 | **约 124 人日 / 11-13 周**（3 人） |

---

### 0.5 Cut 0 实测校准（以 docs/cleanup-backlog.md 与 docs/test-audit.md 为准）

| 计划值 | 实测 | 处理 |
| --- | --- | --- |
| l10n 直调 1,497 | 1,439 | 以实测为准；Cut 4 codemod 目标 1,439 |
| Router 依赖 24 | 20 个 private let | AppServices 分组装配按实际 20 个服务 |
| 度门控 BFS 4 份 | 5 份 + 1 回退（SimilarityService:763） | Cut 5 删除 5 份与回退路径 |
| errorMessage VM 6 个 | 7 个 | Cut 4 覆盖 7 个 |
| app 测试 298 | 运行时 298 / 源码 @Test 301 | CI 验收用运行时数；清理审计用源码数 |
| v34 fixture | 不存在 | D-003 的 fixture 部分取消 |
| CommandID | 不存在（新建） | Cut 1 新建 |
| #if DEBUG 路由 | 0 处 | CL-20 的该项取消 |
| ADR schema 34/43 | 实际 35/44 | Cut 6 修正 ADR-006/029 |
| Protocol Params 99 个 | 零外部引用，但字段与 Router 手工解析高度重合 | 不盲删；API 输入优先复用，形状不符再新建（D-007） |
| 错误码 177 项 | D-010 后 179 项（INVALID_PARAM / PHOTO_NOT_FOUND） | 冻结断言已更新；文案与 en 表已补 |
| 44 表 / 391 列 / 62 索引 / 63 FK | 43 表 / 370 列 / 69 索引 / 62 FK（schema-v1-draft） | Cut 2 以 schema-v1-draft 为准；assets.status 保留 |
| deliveries 以 xmp_path 为 TEXT 主键 | id 代理主键 + xmp_path UNIQUE；增 photo_path、去 source_module | 见 D-013 |
| smart_albums / workflow_templates | UI 0 调用，仅 Router 可达 | 暂保留（Template 在 ROADMAP 4.2；Album 预留），只做 typed API（D-008） |

## 1. 直接删除的代码与契约

| 对象 | 位置/规模 | 处置 |
| --- | --- | --- |
| SessionCommandRouter | 3,258 行 + 20 依赖 | **删除**，逻辑下沉到 Domain 的 API 实现 |
| CommandRouter / WebResponse / NativeCommandClient | 约 250 行 | **删除**，不再有 JSON 命令边界 |
| 118 条命令的字符串 switch | 82 sync + 36 async | **删除**，改为按域的类型化 async 方法 |
| CommandSurfaceRuntimeTests / StubCommandRouter / check-command-surface.sh | 约 400 行 + 脚本 | **删除**，由 API 契约测试与 layer 门禁替代 |
| Migrations.swift（35 版） | 1,628 行 | **删除**，替换为单份 SchemaV1.swift |
| MigrationTests / schema.snapshot.json / v34 fixture | 约 600 行 | **删除**，替换为 fresh-schema 测试 |
| metadata_outbox / metadata_outbox_sessions / writeback_items | 3 张表 + 2 套状态机 | **合并**为 delivery 模型（见 §4.3） |
| CommandExecuting / errorMessage / LoadPhase 旧桥 | 7 个 VM（errorMessage）+ 11 个 VM（LoadPhase） | **删除**，统一 GatherError + ViewState |
| isActive / SessionDraftCache / pending 容器 | RootView 约 150 行 | **删除**，统一 SessionStore/WorkspaceIntent |
| .id(languageVersion) / GatherLocalization.l 直调 | 1,439 处 | **删除/替换**为 Environment L10n |
| CosineHnswIndex / HnswConfig / benchHnsw | 约 420 行 | **删除**，保留 VectorNeighborIndex 协议 + LSH |
| 5 份度门控 BFS + 1 回退 + 双聚类实现 | 7 处 | **删除**，统一 ClusterGraph/ClusterPipeline |
| GatherCore 伞 / @_exported / 兼容文件名 | — | **不创建**；一次性拆分 |
| 177 项错误码冻结测试 | ErrorCodeContractTests | **保留枚举、删除“冻结数量”断言**；后续可精简 |

预计净删除 **6,000-8,000 行**（含测试与迁移），新增约 4,000-5,000 行（新 API、统一状态机、新 UI 基础设施）。

---

## 2. 目标架构（无伞、单向依赖）

```text
gather-core/Sources/
├── GatherProtocol/       DTO、GatherError、API 协议、PhotoFileTypes、Logging
├── GatherPersistence/   Database、SchemaV1、Repositories
├── GatherAnalysis/      Face / Similarity / Image / Concurrent
└── GatherDomain/        Services、JobService、Delivery、Session

gather-app/Sources/
├── GatherUI/            Shell、Features、Support、Localization、Resources
├── GatherHost/          AppServices（组合根）、RootView、CaptureOneBridge、Delegate
└── GatherApp/           仅 @main
```

依赖图（编译器强制，**无 GatherCore 伞**）：

```text
GatherProtocol
  ├── GatherPersistence（+ CSQLite）
  ├── GatherAnalysis
  └── GatherUI
GatherDomain → Protocol + Persistence + Analysis
GatherHost   → UI + Domain + Persistence + Analysis + Protocol
GatherApp    → Host + UI（仅 @main/Scene）
```

- 构建即启用 **--explicit-target-dependency-import-check error**，越界 import 直接失败。
- UI 只 import GatherProtocol；它看不到 SQLite、Repo、Service。
- Host 是唯一组合根；它实现 API 协议并注入 UI。
- 不再有 import GatherCore，不再有 umbrella target。

---

## 3. 核心 API：用类型化 async 方法替代 118 条命令

### 3.1 按域定义协议（GatherProtocol）

```swift
public protocol SessionAPI: Sendable {
    func list() async throws -> [SessionData]
    func get(_ id: String) async throws -> SessionData
    func create(_ input: SessionCreateInput) async throws -> SessionData
    func delete(_ id: String) async throws
    func addPhotos(_ input: AddPhotosInput) async throws -> AddPhotosResult
}

public protocol CullingAPI: Sendable {
    func page(_ query: CullingPageQuery) async throws -> CullingPage
    func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult
    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> CullingBatchResult
    func decideGroup(_ input: DecideGroupInput) async throws -> [CullingUpdateResult]
    func summary(_ sessionId: String) async throws -> CullingSummary
    func syncStatus(_ sessionId: String) async throws -> CullingSyncStatus
    func writeback(_ input: CullingWritebackInput) async throws -> WritebackResult
    func confirmSync(_ sessionId: String) async throws
    func cleanup(_ sessionId: String) async throws -> CleanupResult
}

public protocol ExportAPI: Sendable {
    func preview(_ input: ExportInput) async throws -> ExportPreview
    func execute(_ input: ExportInput) async throws -> ExportResult
    func cancel(_ jobId: String) async throws
    func report(_ jobId: String) async throws -> ExportReport
}
```

约 15 个域协议、约 110 个方法；每个方法对应今天的 1-3 条命令（合并同一用例的同步/异步入口）。所有方法 async throws，没有 sync/async 双入口。

### 3.2 Job 用 AsyncStream，不用回调

```swift
public struct JobHandle: Sendable {
    public let id: String
    public let events: AsyncStream<JobEvent>
}

public protocol JobAPI: Sendable {
    func start(_ request: JobRequest) async throws -> JobHandle
    func cancel(_ id: String) async throws
    func retry(_ id: String) async throws
    func list(_ filter: JobFilter) async throws -> [JobData]
}
```

UI 用 for await event in handle.events 更新进度；不再有 executeAsync(completion:)，不再有 NotificationCenter 的 jobs:progress 双通道（事件中心只保留领域变更）。

### 3.3 错误只有一个类型

```swift
public struct GatherError: Error, Sendable, Equatable {
    public let code: GatherErrorCode
    public let params: [String: String]
    public let underlying: String?      // 仅日志，不上屏
    public var retryable: Bool { ... }  // code 驱动
}
```

- 服务内部可以继续用各自枚举，但在 API 边界统一转成 GatherError；不再有 WebResponse.error: String、CODE::param、errorMessage 的 20 分支 if-let。
- 删除 BridgeError 与所有“英文散文当错误码”的路径；无码错误归到 GatherErrorCode.unspecified，日志保留原文。
- 保留 177 个码（避免全量重写），但删除“数量冻结”测试；后续按域精简。

### 3.4 UI 调用形态

```swift
@MainActor @Observable
final class CullingViewModel {
    private let api: any CullingAPI
    private(set) var state: ViewState<CullingPage> = .idle

    func reload() async {
        state = .loading(previous: state.value)
        do { state = .loaded(try await api.page(query)) }
        catch let error as GatherError { state = .failed(error) }
        catch { state = .failed(GatherError(code: .unspecified, underlying: String(describing: error))) }
    }
}
```

没有字符串命令、没有参数字典、没有 decoded(as:)。VM 的依赖是窄协议，测试直接给 fake。

### 3.5 API 实现放 GatherDomain

```swift
public struct LiveCullingAPI: CullingAPI {
    let service: CullingService
    let delivery: DeliveryCoordinator
    public func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult {
        try await service.updateState(input)   // 服务改为 async 或经 Database.async 包装
    }
}
```

- 今天 Router 里的参数校验、路径授权、confirmed 门禁，**下沉到输入类型的 init(from:) 或 API 实现**：
  - 路径授权：PhotoPathPolicy.validate(_:)（Protocol）；
  - 破坏性操作：输入类型必须是 Confirmed<T>，构造该类型只能经 UI 的确认弹窗；API 不再接收裸 confirmed: Bool。
- 删除 makeDefault 的 24 参数构造，改 AppServices.live(database:) 的分组装配（SessionServices、MediaServices、DeliveryServices、AnalysisServices）。

```swift
public struct Confirmed<Value: Sendable>: Sendable {
    public let value: Value
    init(_ value: Value) { self.value = value }   // internal：只有确认弹窗模块能构造
}
```

---

## 4. 持久化与 schema：单份 SchemaV1

### 4.1 删除迁移链

- 删除 Migrations.swift（35 版、1,628 行）、MigrationRunner、迁移测试与 fixture。
- 新增 GatherPersistence/Schema/SchemaV1.swift：当前 44 张表的最终形态（先做一次“死表审计”，能删的删）。
- Database.open：
  1. 打开文件，读 PRAGMA user_version；
  2. 若为 0：执行 SchemaV1.create，写 user_version = 1；
  3. 若 ≠ 1：关闭连接 → 把库改名为 gather.sqlite.incompatible-<ts> → 新建空库 → 记录一条醒目日志/首次启动提示；
  4. 不做任何 ALTER、不做数据搬运、不做 down migration。
- 开发期约定写进 README：**换 schema 即重置本地库**；照片与 XMP 文件不受影响，只丢会话/决策/缓存。

### 4.2 SchemaV1 直接带约束

- 所有状态列加 CHECK：sessions.status、photos.status、analysis_jobs.status、deliveries.status、delivery_items.status、duplicate_groups.status、face_clusters.status 等。
- 所有枚举集合由 Swift enum 生成 SQL 片段，测试断言“enum.allCases == CHECK 集合”。
- 外键默认 ON DELETE CASCADE（除需要保留审计的），删除顺序不再靠服务层手写。
- 关键唯一约束直接建：person_photos(person_id, photo_id)、delivery_items(delivery_id, photo_id, module)。
- 每张表必须有 created_at；可变表必须有 updated_at（默认值 + 仓储写入）。

### 4.3 统一 delivery 模型（替代 outbox + writeback）

```sql
CREATE TABLE deliveries (
  xmp_path TEXT PRIMARY KEY,
  source_module TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN
    ('pending','writing','written','synced','failed','conflict','cleaned')),
  revision INTEGER NOT NULL DEFAULT 0,
  base_fingerprint TEXT NOT NULL DEFAULT '',
  base_values_json TEXT NOT NULL DEFAULT '{}',
  backup_path TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  lease_owner TEXT NOT NULL DEFAULT '',
  heartbeat_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE delivery_sessions (
  xmp_path TEXT NOT NULL REFERENCES deliveries(xmp_path) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  confirmed_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (xmp_path, session_id)
);

CREATE TABLE delivery_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  xmp_path TEXT NOT NULL REFERENCES deliveries(xmp_path) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  module TEXT NOT NULL,
  attributes_json TEXT NOT NULL DEFAULT '{}',
  keywords TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK (status IN ('pending','written','synced','failed')),
  error_message TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (xmp_path, photo_id, module)
);

CREATE TABLE delivery_intents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('cleanup','write')),
  xmp_path TEXT NOT NULL,
  phase TEXT NOT NULL CHECK (phase IN ('prepared','fileDone','applied')),
  payload_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

- **一个状态机**：DeliveryStatus 的合法转移只在 Swift 中定义，DB 只做 CHECK 兜底。
- confirm：一个事务更新 deliveries + delivery_items + sessions.writeback_status，不再有“两次独立提交”。
- cleanup：文件恢复前写 delivery_intents(prepared)；恢复成功后写 fileDone；DB 删除与 intent 完成同一事务；启动时 replay() 只补做 DB 段，不重放文件。
- 页面需要“照片粒度”时查 delivery_items，不再维护第二套 writeback_items。

### 4.4 Database：1 writer + N readers

```swift
public final class Database: @unchecked Sendable {
    public static func open(at url: URL, options: Options = .default) throws -> Database

    public func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T
    public func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T
    public func async<T: Sendable>(_ body: @Sendable @escaping (SQLiteConnection) throws -> T) async throws -> T
    public func checkpoint(_ mode: CheckpointMode) throws
    public func interrupt()
}
```

- writer：READWRITE|CREATE|FULLMUTEX + WAL、busy_timeout=5000、foreign_keys=ON、cache_size=-64MB。
- readers：READONLY|FULLMUTEX + query_only=ON + cache_size=-16MB；只读连接不设 journal_mode。
- 同步服务在 async 执行器上跑；UI 永远 await，不再有主线程同步 SQL。
- 事务预算 2,000 行；>250ms 记 warn；事务闭包禁止 await。
- :memory: 走单连接，测试仍可用。

---

## 5. UI：一次性切到新状态模型

### 5.1 目录

```text
Sources/GatherUI/
├── Shell/{RootView,RootSidebar,RootDestination,SessionStore}.swift
├── Workspace/{SessionWorkspace,WorkspaceIntent}.swift
├── Features/{Culling,Duplicates,Export,FaceKeywording,Settings,ControlCenter,
│             Library,Gallery,Similarity,Persons,Dashboard}/{View,ViewModel,Models}.swift
├── Support/{ViewState,RequestGate,GatherErrorBanner,Theme,Toast,Thumbnail}.swift
├── Localization/{LanguageStore,L10n,Environment+Language}.swift
└── Resources/{en,zh-Hans}.lproj
```

### 5.2 状态模型（删除旧机制）

```swift
@MainActor @Observable
final class SessionStore {
    private(set) var activeSessionId: String?
    private var workspaces: [String: SessionWorkspace]
    func workspace(for id: String) -> SessionWorkspace
    func activate(_ id: String?)
}

@MainActor @Observable
final class SessionWorkspace {
    let sessionId: String
    let culling: CullingViewModel
    let duplicates: DuplicatesViewModel
    let export: ExportViewModel
    let face: FaceKeywordingViewModel
    private(set) var isVisible: Bool
    func setVisible(_ visible: Bool)   // 直接启停轮询，没有 isActive 参数
}
```

- 删除 SessionDraftCache、4 个 pending 容器、faceKwInitialRole；统一 WorkspaceIntent + take-and-clear。
- 删除 isActive 参数；页面从 Environment 读取 isVisible。
- 删除 LoadPhase 旧桥；统一 ViewState<V> + RequestGate。
- 每个 VM 依赖窄协议（CullingAPI 等），不依赖具体服务/DB。

### 5.3 本地化：一次切换

```swift
@MainActor @Observable
final class LanguageStore {
    enum Language: String { case zhHans = "zh-CN", en }
    private(set) var language: Language
    var l10n: L10n { L10n(language: language) }
    func set(_ language: Language)
}
```

- 删除 .id(languageVersion)；删除 GatherLocalization 的全局锁盒（菜单/Delegate 保留一个只读入口）。
- 用 codemod 把 1,439 处 GatherLocalization.l( 改为 l10n(；String(format:) 改为 l10n.format。
- 模型/静态串改 (L10n) -> String，编译期强制传值。
- 迁移完成后删除 allowlist 与旧 API；CI 断言 GatherLocalization.l( = 0（菜单除外）。
- 不使用“保留 .id 的回退”。语言切换必须保留页面状态。

### 5.4 巨型 View 一次拆完

| 文件 | 目标 |
| --- | --- |
| CullingView 3,525 行 | CullingViewModel + CullingView + ActionController + Views/{Workbench,Toolbar,Inspector,InfoBar,Filmstrip,Viewer,ConflictPanel,Shortcuts} |
| SettingsView 1,756 行 | SettingsView + General/Appearance/Face/Storage |
| FaceKeywordingView 2,098 行 | FaceKeywordingViewModel + ClusterList + Detail + WritebackSheet |
| SessionControlView 1,073 行 | SessionControlView + StageTimeline + ActionList + DiagnosticsCard |
| ExportView 1,139 行 | ExportViewModel + SetupForm + ProgressView |

- 快捷键抽 CullingShortcutMap，可单测。
- 每个拆出的 View 必须有 #Preview，用 fake API；目标 ≥12。
- 单文件上限 600 行；RootView ≤300 行。

---

## 6. 算法：同一 Cut 删除旧实现

- **相似度**：新建 ClusterGraph（NeighborhoodSource + DegreeGatedBFS + 位集 workspace）与 ClusterPipeline（单趟 + ClusterStateDiff）；**删除** ClusterEngine/IncrementalClusterer 中的 4 份 BFS 与第二次 buildState→ComponentGraph。保留 Parity 测试，但测试与删除在同一 PR。
- **持久化**：SchemaV1 的 similarity_cluster_meta 直接含 algorithm_version / input_signature / state_digest；apply(diff) 行级 upsert，不再 DELETE 全表。
- **ANN**：删除 CosineHnswIndex/HnswConfig/benchHnsw；保留 VectorNeighborIndex 协议 + CosineLshIndex；FaceMatcher 改单实例 + 批量 match(queries:)，扫描移出簇循环。
- **人脸**：分析三段式直接从第一天启用（短事务写观测 → 锁外聚类 → 分片提交）；删除旧“单事务包聚类”路径；模型加载 single-flight。
- 不设 similarity_cluster_diff_write / face_cluster_write_shards 等开关；只保留 face_inference_concurrency 作为性能参数。

---

## 7. 构建、CI 与测试

### 7.1 构建

- 删除 umbrella 与全部兼容 import；直接 import GatherProtocol/Persistence/...。
- --explicit-target-dependency-import-check error 从第一个 Cut 起启用。
- build.sh 重写为 scripts/lib/build-lib.sh 函数 + 测试；bundle 用 glob 查找，不写死名字；支持 arm64/x86_64 + lipo。
- 资源：本地化随 GatherUI，模型随 GatherAnalysis；bundle 改名后由 assert_bundle 硬失败。

### 7.2 测试策略

- **删除**：CommandSurfaceRuntimeTests、MigrationTests、schema.snapshot 旧快照、v34 fixture、errorMessage oracle、StubCommandRouter。
- **保留/改写**：Domain 服务行为测试（用内存 DB）、算法对账测试、VM 测试（fake API）、UI 逻辑测试（RequestGate/ViewState）。
- **新增**：SchemaV1Tests（表/列/索引/CHECK 与 Swift enum 一一对应）、APIEnvironmentTests（每个 API 方法最小 happy path + 一个错误路径）、DeliveryStateMachineTests（合法/非法转移、confirm 单事务、cleanup 崩溃回放）、SessionStoreTests（LRU、可见性、意图 take-and-clear）、L10nParityTests（en 表逐键）、LayerBoundaryTests（编译期 import check + 脚本）。
- 目标：core ≥700（从 994 降，因为删除迁移/命令测试），app ≥250；不是“越多越好”，而是每个用例对应一条行为。

### 7.3 门禁

```bash
./scripts/check-layering.sh          # import 规则 + 无 umbrella
./scripts/check-schema-v1.sh         # 新库 schema 与 Swift enum 一致
./scripts/check-db-boundary.sh       # Services 0 处 prepare(
./scripts/check-l10n.sh              # GatherLocalization.l( = 0（菜单除外）
./scripts/check-preview-surface.sh   # #Preview >= 12
./scripts/check-no-legacy.sh         # 保留，删除迁移/命令相关规则
```

---

## 8. 清理计划（旧代码 / 无用测试 / 重复逻辑）

> 清理不是最后一个阶段的“打扫”，而是每个 Cut 的退出条件。原则：**替代实现与删除旧实现发生在同一个 Cut**；git 历史就是备份；禁止“先注释、先保留、以后再说”的伪清理。

### 8.1 清理原则

1. 每个 Cut 的验收必须包含“旧实现已删除、旧测试已删除或改写、无新旧并存”。
2. 删除前必须有替代实现与对等测试；删除与替代在同一 PR/同一 Cut。
3. 不确定是否在用的代码，先做引用扫描 + 运行时日志/基准确认，再删；不做“看起来没人用”的猜测删除。
4. 每个 Cut 报告清理账：删除/新增行数、删除文件数、删除 public 符号数、删除表/列/索引数。
5. 清理量与功能量分开统计，避免“重构顺便删了但没人知道”。

### 8.2 清理清单（按类别与目标 Cut）

| ID | 对象 | 证据/位置 | 处置 | Cut |
| --- | --- | --- | --- | --- |
| CL-01 | Router / JSON 命令面 / CommandID / 生成器 | SessionCommandRouter 3,258 行、118 case | 删除；API 替代 | 1 |
| CL-02 | 35 版迁移链、旧 Schema、快照、v34 fixture | Migrations.swift 1,628 行、MigrationTests | 删除；SchemaV1 替代 | 2 |
| CL-03 | outbox + writeback 双状态机 | 3 张表、confirm/cleanup 两段提交 | 合并为 delivery 模型 | 2 |
| CL-04 | 4 套 stale 守卫 | Gallery fetchGeneration、Library latestRequestID、Similarity tierRequestID、Culling pageVersion | 统一 RequestGate | 4 |
| CL-05 | 4 份度门控 BFS + 双聚类实现 | ClusterEngine:512/587、IncrementalClusterer:346/432、SimilarityService:763/772 | 统一 ClusterGraph / ClusterPipeline | 5 |
| CL-06 | HNSW 死代码 | CosineHnswIndex / HnswConfig / benchHnsw 仅 benchmark 引用 | 删除；保留 VectorNeighborIndex + LSH | 5 |
| CL-07 | 两套缩略图 loader / 两套 @State | PhotoThumbnailView:164-169/289-293、:222/415 | 合并为一个 loader + 一个缓存键 | 4 |
| CL-08 | 6 个 VM 的 errorMessage/notice 字符串 | Culling/Settings/Export/Duplicates/ControlCenter/FaceKw | GatherError + ViewState | 4 |
| CL-09 | SessionDraftCache / pending 容器 / isActive | RootView:283-345、617/639/665/684 | SessionStore / WorkspaceIntent / isVisible | 4 |
| CL-10 | .id(languageVersion) 与 1,439 处 l( 直调 | RootView:423；全 UI | LanguageStore + Environment | 4 |
| CL-11 | 兼容测试 | CommandSurfaceRuntimeTests、StubCommandRouter、MigrationTests、errorMessage oracle | 删除；API 行为测试替代 | 1/2 |
| CL-12 | 测试 helper 重复 | LockedBox ×3、ResponseBox、AsyncGate、JobEventSink | 收进 Tests/Support 一份 | 6 |
| CL-13 | 未接线/死 API | FaceEncoder.embeddingDim 未用、ClusteringImpact 无 UI 入口、ImageCache 残留工具 | 删除或接线；不保留“以后可能用” | 5/6 |
| CL-14 | 死表/死列/死索引 | 44 张表审计；镜像列、历史列、未用索引 | SchemaV1 不建；Repo 同步删 | 2 |
| CL-15 | 构建垃圾 | desktop/native/swbuild.tmp.*、.DS_Store、旧临时脚本 | 删除 + .gitignore | 0 |
| CL-16 | 历史文档/ADR 漂移 | docs/reviews 20+ 篇、ADR-006/029 的 34/43 数字 | 归档到 docs/archive；当前文档修正 | 6 |
| CL-17 | 重复常量/清单 | rawExtensions 双入口、轮询间隔散落、C1 状态文案 | 单一来源 + 引用 | 4/5 |
| CL-18 | 吞错/弱类型残留 | try? 吞恢复错误、@unchecked Sendable 无锁依据 | 逐个消除或登记豁免 | 6 |
| CL-19 | 旧回归测试与重复覆盖 | ReviewFixTests / ReviewAcceptanceTests / DeepModelAcceptanceTests | 保留行为断言；删除测已删代码的用例 | 6 |
| CL-20 | 未用资源/调试开关 | 旧模型、旧 lproj 键、DEBUG-only 路由 | 删除或移入 DEBUG | 5/6 |

### 8.3 无用测试判定规则

- 测试对象已删除（命令面、迁移链、旧 Router）→ 直接删。
- 两个测试覆盖同一行为且无额外边界 → 合并为 @Test(arguments:)，保留输入矩阵。
- 只验证实现细节（私有函数、字符串常量、内部排序）且行为测试已覆盖 → 删或改写为行为断言。
- @Test(.disabled) / withKnownIssue 无到期说明 → 修复或删除；保留必须写“到期条件”。
- 依赖真实 home / 网络 / 系统状态的测试 → 改为临时目录/注入；不能改则删。
- 历史 bug 回归测试：bug 所在代码仍存在 → 保留；代码已删除 → 删。

### 8.4 重复逻辑判定规则

- 同一算法/状态机出现 >1 份 → 抽一份，加 parity 测试后删旧。
- 同一守卫/超时/轮询模式出现 >2 份 → 抽组件（RequestGate、PollingPolicy）。
- 同一错误映射/文案路径出现 >1 份 → 单一出口（GatherError → L10n.errorText）。
- 测试 helper 重复 → Tests/Support 一份。
- 常量/清单重复（扩展名、阈值、超时、默认值）→ 单一来源，其他位置只引用。

### 8.5 执行方式

- **Cut 0**：建立 docs/cleanup-backlog.md（上表 + baseline 计数）；删除 CL-15；记录“删除/新增行数、重复实现数、skip 测试数”基线。
- **每个 Cut**：PR 模板增加“删除了什么”必填项；验收必须附清理账；CI ratchet 只降不升。
- **Cut 6（新增）**：3-5 天集中清扫——死符号、测试目录、重复 helper、文档归档、门禁落地；产出“清理报告”。
- **工具**：可选 periphery 作为本地开发工具（不是包依赖，不进 Package.swift），用于未使用声明扫描；无网络/无工具时用 scripts/find-unused-symbols.swift（grep + 引用计数 + allowlist）兜底。

### 8.6 防复发门禁

| 门禁 | 判据 |
| --- | --- |
| check-cleanup-ratchet.sh | @unchecked Sendable、try?、Services 的 prepare(、TODO/FIXME、withKnownIssue 计数不得超过 baseline |
| check-test-catalog.sh | 每个测试文件有 owner/目的头；skip 必须带到期条件；不得 import 已删除模块 |
| check-duplicate-symbols.sh | 禁止 func batchAsync 副本、LockedBox/ResponseBox 出现在 Tests/Support 之外、同名 RequestGate 副本 |
| check-docs.sh | ADR 中 native 路径存在；历史 review 在 docs/archive；schema 数字与 SchemaV1 一致 |
| check-death-list.sh | docs/cleanup-backlog.md 中 CL-01..CL-20 状态必须为 done/blocked，不允许长期 in-progress |

### 8.7 清理验收指标

- 净删除 6,000-8,000 行；删除文件 ≥25；删除 public 符号 ≥120（118 命令 + helper）。
- 重复实现：CL-04/05/06/07/12/17 对应类别为 0。
- 死表/死列/死索引：审计清单为 0（SchemaV1 不建）。
- 测试：core 994 → 约 700、app 298 → 约 250；skip 0 或全部带到期条件；每个保留测试能指出保护的行为。
- 文档：20+ 篇历史 review 归档；ADR 数字与 SchemaV1 一致；README/DEVELOPMENT 不再引用已删除模块。
- 门禁：cleanup ratchet baseline 记录且连续 3 个 Cut 不增长。

---

## 9. 执行计划：6 个 Cut（3 人并行约 11-13 周）

> 原则：每个 Cut 是一个长分支（1-3 周），结束即合并主干；合并前必须两包构建 + 启动 + 核心回归。不做长期双轨。

### Cut 0：冻结与准备（2-3 天）

- 建 refactor/breaking-2026-10 分支；冻结功能开发。
- 用脚本盘点：118 命令 → API 方法映射表、1,439 处 l10n 调用、128 处 SQL、44 张表使用情况。
- 生成“删除清单”与“死表/死代码”清单；确认本地库可清空。
- 验收：映射表评审通过；CI baseline 绿。

### Cut 1：核心 API，删除命令面（约 2-3 周）

- 在 GatherProtocol 定义 15 个域协议与输入/输出类型；在 GatherDomain 实现 LiveXxxAPI。
- 把 Router 中的参数校验、路径授权、确认门禁下沉到输入类型/API。
- 删除 SessionCommandRouter、CommandRouter、WebResponse、NativeCommandClient、StubCommandRouter、CommandSurfaceRuntimeTests、check-command-surface.sh。
- 更新 12 个 UI 文件、约 78 处调用为 typed API。
- 验收：0 字符串命令、0 JSON envelope；118 条行为由 API 测试覆盖；UI 可构建启动；core/app 测试绿。

### Cut 2：SchemaV1 + Database + Delivery（约 3-4 周）

- 新建 SchemaV1（含 CHECK、统一 delivery 表、任务状态约束）；删除 Migrations/Schema 旧文件。
- 新建 Database（1W+NR、read/write、typed error）；18 个 Repo 重写/迁移到新 API。
- Services 去掉 128 处 SQL 与 15 个 connection 字段；长任务改为“读快照 → 计算 → 分片写”。
- 实现 DeliveryCoordinator（confirm 单事务、cleanup intent 回放）；删除 outbox/writeback 双状态机。
- 验收：空库启动建表；旧库被安全移走；所有功能在 fresh DB 上跑通；事务预算/慢查询日志生效。

### Cut 3：模块拆分（约 1-2 周）

- 一次性建 7 个 target；移动文件；改 import；不建伞。
- 启用 explicit import check；UI 不能再 import Persistence/Domain。
- build.sh/CI 重写；资源 bundle 断言。
- 验收：7 个 target 编译；UI 独立构建；Preview 可跑；无循环依赖。

### Cut 4：UI 重构 + 本地化（约 2-3 周）

- SessionStore/SessionWorkspace/ViewState/RequestGate；删除 SessionDraftCache/isActive/pending 容器。
- 6 个巨型 View 拆分；12 个 Preview。
- LanguageStore + Environment；codemod 1,439 处；删除 .id。
- 验收：RootView ≤300；切语言状态保留；0 存储型 errorMessage；0 处 isActive；#Preview ≥12。

### Cut 5：算法与收尾（约 1-2 周）

- ClusterGraph/ClusterPipeline；删除 4 份 BFS 与双算；SchemaV1 簇 meta。
- 删除 HNSW；FaceMatcher 批量；人脸三段式；模型 single-flight。
- 删除死代码、旧测试、旧文档；更新 ADR/DEVELOPMENT/README。
- 验收：单趟聚类、10k 基准达标、无旧实现引用；全部门禁绿。

### Cut 6：清扫与防腐（约 3-5 天）

- 执行 §8.5 的集中清扫：死符号、重复 helper、无用测试、文档归档、门禁落地。
- 产出 docs/cleanup-report.md：删除/新增行数、删除文件、删除符号、重复实现归零证明。
- 验收：§8.7 全部指标达标；cleanup ratchet baseline 建立；连续 3 个 Cut 不增长。

### 总工作量（人日）

| Cut | 内容 | 人日 |
| --- | --- | --- |
| 0 | 盘点/映射/冻结 | 3 |
| 1 | 核心 API + 删 Router | 15 |
| 2 | SchemaV1 + DB + Delivery | 30 |
| 3 | 模块拆分 | 12 |
| 4 | UI + l10n | 25 |
| 5 | 算法 + 收尾 | 15 |
| 6 | 清扫与防腐 | 4 |
| 缓冲 | 20% | 20 |
| **合计** |  | **约 124** |

3 人并行约 **11-13 周**；4 人约 **9-10 周**。关键路径：Cut 1 → Cut 2 → Cut 3 → Cut 4 → Cut 6；Cut 5 可在 Cut 2 后并行。

---

## 10. 风险与对策（破坏性版特有）

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 大分支合并冲突 | 高 | 冻结功能；每个 Cut ≤3 周；每日 rebase；Cut 1/2 按文件所有权分工 |
| 本地库重置丢决策 | 中 | 开发期接受；启动时移走旧库并提示；照片/XMP 不动；需要时先导出 |
| 测试重写不足 | 高 | 每个 API 方法至少 1 happy + 1 error；Domain 行为测试保留；UI 只测纯逻辑 |
| Router 里隐藏的授权/确认逻辑丢失 | 高 | Cut 0 生成“每条命令的校验清单”；Cut 1 逐条迁移并配对测试（路径穿越、未确认、越权） |
| 1,439 处 l10n codemod 误改 | 中 | AST/正则 + allowlist + 编译；每页一个 commit；en 表 parity 测试 |
| 模块拆分 import 风暴 | 中 | 一次性机械改 + explicit check；先拆 Protocol/Persistence，再 UI/Host |
| 算法删旧实现后回归 | 中 | Parity 测试与删除同 PR；10k/100k 基准；保留旧实现到分支合并前最后一刻 |
| schema 一次成型遗漏列 | 中 | 用旧库做“列清单审计”；新 schema 与所有 Repo SQL 对照；fresh DB 全功能回归 |

---

## 11. 需要确认的两个默认决定

1. **本地库直接重置**：SchemaV1 不匹配时把旧库改名为 .incompatible-<ts>，新建空库；不提供导入工具。若你希望保留开发库，我可以在 Cut 2 前加一个一次性“导出 JSON → 新库导入”脚本（约 2 人日）。
2. **错误码保留 177 项**：本方案保留枚举与本地化表，只删除“数量冻结”测试；如果希望顺带精简到约 60 项，需要额外 3-5 人日做全量映射与文案。

---

*本方案替代 2026-10-21 的保守版《重构设计方案》；保守版保留作历史记录。*
