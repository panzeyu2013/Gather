
> **已被取代（2026-10-21）**：项目处于开发阶段，确定采用破坏性变更。本文件保留作历史记录；
> 以 [破坏性重构方案](../../reviews/refactor-design-breaking-2026-10-21.md) 为准。

# Gather 重构设计方案（2026-10-21）

> 输入：[架构评审](../../reviews/architecture-review-2026-10-21.md) 的 P0/P1/P2 清单 + 六路专项设计（命令面 / 持久化与并发 / 表现层 / 模块与工程 / 一致性与状态机 / 算法规模）。
> 目标：给出**可直接拆成 PR 的代码级方案**。所有签名、目录、DDL、测试名均可落地；行号以 HEAD 82603e0 为准。
> 约束：Swift 6 / macOS 14+ / 零第三方依赖 / 不破坏 GatherErrorCode 177 项 / 118 条命令语义不变 / 每个 PR 可编译、可独立回滚。

---

## 0. 执行摘要

### 0.1 重构目标（按优先级）

1. **一条类型化调用链**：UI → 类型化 Command → 注册表 → 服务，取代“字符串 + 字典 + 两个 switch”。
2. **一个持久化边界**：Services 不再写 SQL；事务 API 表达读写意图；长任务先算后写。
3. **一个状态所有权**：SessionWorkspaceStore 持有页面状态，RootView 只做导航；可见性/语言/错误有单一来源。
4. **一套一致性语义**：confirm/cleanup 有明确事务与补偿；任务状态、人物合并、元数据缓存不再靠注释约定。
5. **一组可强制的模块边界**：Protocol / Persistence / Analysis / Domain / UI / Host，由 Package.swift 与门禁强制。

### 0.2 不做的事

- 不重写 UI 视觉与交互；不改产品行为与命令语义。
- 不引入第三方依赖、ORM、响应式框架。
- 不在本阶段改算法精度目标（只改接线、内存与持久化）。
- 不做网络同步、插件市场、Windows 支持。
- 不做一次性大迁移；所有改造走“绞杀者”路径，旧路径在切换前始终可用。

### 0.3 六个工作流

| 工作流 | 内容 | 人日 | 关键依赖 |
| --- | --- | --- | --- |
| A | 类型化命令 + Router 拆分 | 29 | B-1、C-2 |
| B | 持久化边界 + 读写分离 | 38 | 无 |
| C | 表现层状态所有权 + VM + 本地化 | 29 | A、B |
| D | SwiftPM 模块拆分 + 工程化 | 35 | A、B |
| E | 一致性与状态机 | 32 | 迁移号协调 |
| F | 相似度/人脸规模化 | 20 | 迁移号协调 |
| **合计** |  | **183**（含 20% 缓冲 ≈ **220**） |  |

按 3 人并行、80% 有效投入，约 **18-21 周**；Wave 0 止血项可在 **1 周**内独立上线。

### 0.4 三个需要提前裁决的冲突点

| # | 冲突 | 裁决 |
| --- | --- | --- |
| 1 | 目标命名：B 提 GatherContracts/GatherStore，D 提 GatherProtocol/GatherPersistence | 采用 D 的最终图：**GatherProtocol / GatherPersistence / GatherAnalysis / GatherDomain / GatherCore（过渡伞）/ GatherUI / GatherHost / GatherApp**；Logging/RawFormat/CommandRouter 放 GatherProtocol；B 的 GatherStore 即 GatherPersistence |
| 2 | 迁移号：E 的 v36/v37、B 的 v36、F 的 v38 | 单一序列：**v36 = 交付/缓存列 + person 去重**；**v37 = 状态 CHECK**；**v38 = 聚类 meta**；docs/migration-reservations.md 锁定 owner |
| 3 | 状态约束：E 用 CHECK（12-step rebuild），B 用触发器避开重建 | 首选 **CHECK**（DB 层强约束）；若 rebuild 实测风险高，回退 **BEFORE INSERT/UPDATE 触发器**，语义由 JobStateMachine 测试锁定 |

---

## 1. 目标架构

### 1.1 分层与依赖（编译器强制）

```
GatherProtocol
  ├── GatherPersistence（+ CSQLite）
  ├── GatherAnalysis
  └── GatherUI
GatherDomain → Protocol + Persistence + Analysis
GatherHost   → UI + Domain + Persistence + Analysis + Protocol
GatherApp    → Host + UI（仅 @main/Scene）
```

- **GatherProtocol**：DTO、错误码、CommandID、CommandRouter 端口、WebResponse、Logging、RawFormat/PhotoFileTypes、IPC 线协议。只依赖 Foundation。
- **GatherPersistence**：SQLite、迁移、18 个 Repository、schema introspection。唯一能发 SQL 的模块。
- **GatherAnalysis**：Face / Similarity / Image / Concurrent；只依赖 Protocol，不碰 DB（现状已满足）。
- **GatherDomain**：Services、JobService、写回、outbox、一致性协调；依赖 Protocol + Persistence + Analysis。
- **GatherUI**：SwiftUI 页面、ViewModel、设计系统、本地化资源；只依赖 Protocol（值契约 + CommandRouter 端口 + 错误码），拿不到 SQLite/Persistence/Domain。
- **GatherHost**：Router、RootView、Bridge、Delegate、Live providers、AppBootstrap；依赖 UI + Domain + Persistence + Analysis。
- **GatherApp**：仅 @main/Scene，依赖 Host + UI。

规则（由 `--explicit-target-dependency-import-check error` + `scripts/check-module-boundaries.sh` 双重强制）：

1. Protocol 只 import Foundation；不出现 SQLite/SwiftUI。
2. Persistence 不得 import Analysis/Domain/UI；SQLite 只在此层出现。
3. Analysis 不得 import Persistence/Domain；不碰 DB。
4. Domain 不得 import SwiftUI；不得出现 `prepare(`（SQL 只能在 Persistence）。
5. UI 不得 import Persistence/Domain；只依赖 Protocol。
6. Host 是唯一同时 import UI 与 Domain 的 target；App 只做装配。

### 1.2 命令面：从 stringly 到类型化

```
View / ViewModel
   │  try await executor.execute(SessionList.self, .init())
   ▼
CommandExecutor（GatherProtocol 端口）
   ▼
CommandRegistry（GatherHost 实现：按 CommandID 找 handler）
   ▼
SessionHandlers.list → SessionService.listSessions()
```

- **单一真相源**：`docs/command-surface.json` 记录 118 条命令的 id / type / execution / effect / confirmCode；生成 `CommandID` 与 `CommandCatalog`。
- **编译期保证**：Catalog 直接引用 handler 类型；handler 不存在 → 编译失败；`CommandID.allCases` 与 Catalog 数量由测试锁定。
- **旧 JSON 面保留**：`SessionCommandRouter` 继续实现 `CommandRouter` 协议，内部改为查注册表；UI 迁移完成后可删除该协议。
- **错误**：`WebResponse` 增加 `errorCode: String?`（保持 `error: String` 逐字不变），UI 逐步改用 `errorCode`。
- **target 归属**（与工作流 D 对齐）：`CommandID` / `Command` / `CommandExecutor` 生成到 **GatherProtocol**；`CommandCatalog` 引用具体 handler 类型，生成到 **GatherHost**（handler 依赖服务）；A 的 PR 先在当前 app target 落地，D-7 时整体迁入 GatherHost。

### 1.3 持久化：表达意图的 API

```
Database (Sendable facade)
  ├── read { }            // WAL 快照读；已在写作用域内则复用 writer
  ├── write { }           // BEGIN IMMEDIATE + 单写者锁；内层自动 SAVEPOINT
  ├── checkpoint(_:)      // passive / truncate
  ├── interrupt()         // 取消路径
  └── isClosed
```

- 1 writer + N readers（默认 max(2, min(4, cores/2))）；`:memory:` 回退单连接（保住 994 条内存库测试）。
- Repository 只接收 `Database`；`prepare` 为 Persistence 模块 internal。
- 长任务拆成：读快照 → 内存计算 → 分片写事务；事务有行预算（2000）与 250ms 慢事务告警。
- DB 错误类型化：`busy / constraint / io / corrupt / closed / schema / misuse / interrupted`。

### 1.4 表现层：状态所有权

```
RootView（导航壳，≤300 行）
  └── SessionWorkspaceStore（@MainActor @Observable）
        └── SessionWorkspace（每 session 一个，capacity 6 + pinned）
              ├── CullingViewModel
              ├── DuplicatesViewModel
              ├── ExportViewModel
              └── FaceKeywordingViewModel
```

- 页面通过 `@Environment(SessionWorkspaceStore.self)` 取当前 workspace；不再手工构造/淘汰 VM。
- 可见性由 `isViewActive` 环境值提供；删除 `isActive: true` 死通道。
- 本地化：`LanguageStore` 经 Environment 注入；删除 `.id(languageVersion)`；1497 处 `l(` 按文件迁移，允许清单 + parity 测试兜底。
- VM 统一 `ViewState + RequestGate + CommandError`；错误码不再在客户端被翻译成字符串。

### 1.5 工程结构

```
gather-core/Sources/
├── GatherProtocol/{Contracts,IPC,Command,Errors,Support}/
├── GatherPersistence/{DB.swift,Schema/,Migrations/,Repositories/,Introspection/}
├── GatherAnalysis/{Face/,Similarity/,Image/,Resources/FaceModels/}
├── GatherDomain/{Services/,Support/}
├── GatherCore/Exports.swift              # 过渡伞，PR-8 删除
├── CSQLite/ GatherCoreHelper/ GatherCoreBenchmarks/ GatherFaceBenchmarks/ GatherSchema/
gather-app/Sources/
├── GatherUI/{Navigation,Workspace,Features,Support,Preview,Resources/{en,zh-Hans}.lproj}
├── GatherHost/{SessionCommandRouter,RootView,CaptureOneBridge,SidecarXMPProvider,
│              GatherAppDelegate,GatherAppCommands,LiveProviders,AppBootstrap}
└── GatherApp/GatherApp.swift             # 仅 @main/Scene
```

命名沿用 `Gather*` / `*Service` / `*Repo` / `*Port`；新注释按“// 决策：…（ADR-0xx）”记录理由。`sources:` 手工枚举删除，target 目录即边界。

---

## 2. 设计原则

1. **行为冻结优先**：重构 PR 不夹带行为变更；必须先有 oracle 测试（旧实现输出）再切路径。
2. **绞杀者**：新旧路径并存，按域切换；开关只用于写路径，默认关。
3. **类型优先于约定**：能用编译器表达的（命令、参数、错误、依赖方向）不用脚本或注释。
4. **先测量再优化**：读连接池规模、ANN 接线、分片大小都由基准决定，不做“看起来更快”的改造。
5. **事务短、副作用外置**：事务里只允许 SQL；文件 IO / 网络 / 事件发布在事务提交后。
6. **迁移可回滚**：数据迁移必须带备份、特性开关与回滚脚本；DDL 重建单独 PR。

---

## 3. 工作流 A：类型化命令 + Router 拆分（29 人日）

### 3.1 目标结构

```
docs/command-surface.json                    # 118 条命令元数据（单一真相）
scripts/gen-command-surface.swift            # 生成器（Foundation only）
gather-app/Sources/GatherApp/（D-7 后迁入 GatherHost/Commands）
├── Commands/
│   ├── Core/{Command,AnyCommandHandler,CommandRegistry,CommandFailure,
│   │         CommandErrorMapper,CommandSurface.generated}.swift
│   ├── Session/SessionCommands.swift
│   ├── Culling/CullingCommands.swift
│   └── …（每域一文件，一文件多命令）
└── Host/
    ├── AppEnvironment.swift                 # makeDefault（178-379）迁入
    ├── JobExecutors.swift                   # registerExecutors（384-665）迁出
    └── SessionCommandRouter.swift           # 门面（兼容期保留，≤200 行）
```

### 3.2 核心协议

```swift
public enum CommandExecution: String, Sendable, Codable {
    case sync, async, job
}
public enum CommandEffect: String, Sendable, Codable { case read, write, destructive }

public enum CommandGuard: Sendable, Equatable {
    case none
    case confirmation(String)   // 如 "CULLING_RESET_CONFIRM_REQUIRED"
}

public protocol Command: Sendable {
    associatedtype Params: Decodable, Sendable
    associatedtype Result: Encodable, Sendable
    static var id: CommandID { get }
    static var execution: CommandExecution { get }
    static var effect: CommandEffect { get }
    static var guardRule: CommandGuard { get }
    static var paramsErrorCode: String { get }
    init()
    func run(_ params: Params, _ ctx: CommandContext) async throws -> Result
}

public struct CommandContext: Sendable {
    public let env: AppEnvironment
}
```

类型擦除只在注册表内部：

```swift
public struct AnyCommandHandler: Sendable {
    public let id: CommandID
    public let execution: CommandExecution
    public let effect: CommandEffect
    public let guardRule: CommandGuard
    private let runJSON: @Sendable (JSONValue?, CommandContext) async throws -> JSONValue

    public init<C: Command>(_ type: C.Type) {
        id = C.id; execution = C.execution; effect = C.effect; guardRule = C.guardRule
        runJSON = { raw, ctx in
            let params: C.Params
            do { params = try Self.decode(C.Params.self, from: raw) }
            catch let failure as CommandFailure { throw failure }
            catch { throw CommandFailure(code: C.paramsErrorCode) }
            return try JSONValue(from: try await C().run(params, ctx))
        }
    }
    public func run(_ raw: JSONValue?, _ ctx: CommandContext) async throws -> JSONValue {
        try await runJSON(raw, ctx)
    }
    private static func decode<P: Decodable>(_ type: P.Type, from raw: JSONValue?) throws -> P {
        let value = (raw ?? .object([:]))
        let normalized: JSONValue = (value == .null) ? .object([:]) : value
        return try JSONDecoder().decode(P.self, from: JSONEncoder().encode(normalized))
    }
}
```

注册表与分发矩阵（逐条照抄旧语义）：

```swift
public struct CommandRegistry: Sendable {
    private let handlers: [CommandID: AnyCommandHandler]
    private let context: CommandContext

    public init(_ all: [AnyCommandHandler], context: CommandContext) {
        var table: [CommandID: AnyCommandHandler] = [:]
        for handler in all {
            guard table.updateValue(handler, forKey: handler.id) == nil else {
                fatalError("命令重复注册：(handler.id.rawValue)（P0-1 类）")
            }
        }
        precondition(Set(table.keys) == Set(CommandID.allCases), "命令面未全覆盖")
        self.handlers = table; self.context = context
    }

    public func dispatch(_ id: CommandID, _ raw: JSONValue?,
                         mode: CommandExecution) async throws -> JSONValue {
        guard let handler = handlers[id] else {
            throw CommandFailure(code: "NOT_IMPLEMENTED: (id.rawValue)")
        }
        if case .confirmation(let code) = handler.guardRule, !Self.isConfirmed(raw) {
            throw CommandFailure(code: code)
        }
        switch (mode, handler.execution) {
        case (.sync, .sync), (.async, _):
            return try await handler.run(raw, context)
        case (.sync, .async), (.sync, .job):
            throw CommandFailure(code: "NOT_IMPLEMENTED: (id.rawValue)")
        }
    }
}
```

### 3.3 单一真相与生成器

`docs/command-surface.json` 片段：

```json
{
  "schema": 1,
  "commands": [
    { "id": "session.list",    "type": "SessionList",    "execution": "sync", "effect": "read" },
    { "id": "culling.update",  "type": "CullingUpdate",  "execution": "sync", "effect": "write" },
    { "id": "sim.analyze",     "type": "SimAnalyze",     "execution": "job",  "effect": "write" },
    { "id": "culling.reset",   "type": "CullingReset",   "execution": "sync", "effect": "destructive",
      "confirmCode": "CULLING_RESET_CONFIRM_REQUIRED" },
    { "id": "export.execute",  "type": "ExportExecute",  "execution": "job",  "effect": "destructive",
      "confirmCode": "EXPORT_CONFIRMATION_REQUIRED", "paramsErrorCode": "EXPORT_PARAMS_INVALID" }
  ]
}
```

生成器 `scripts/gen-command-surface.swift` 的不变量：id/type/caseName 唯一；execution/effect 枚举合法；destructive 必须带 confirmCode；生成 `CommandID`、`CommandCatalog.all`（引用具体 handler 类型）、`CommandCatalog.descriptors`；`--check` 对比磁盘与 spec，漂移 exit 1（**必须进 CI**）；`--list` 输出 tab 分隔的 id/execution/effect 供 shell 门禁消费。

### 3.4 兼容门面与线程语义

`SessionCommandRouter` 保留两个方法，内部查注册表；**线程语义逐条照抄旧实现**：

- `execute`：只接受 `.sync` handler；其他返回 `NOT_IMPLEMENTED: <id>`。
- `executeAsync`：sync handler 仍走 `DispatchQueue.global(qos: .userInitiated)`（不改 Task）；async/job 走 `Task { }`。
- 旧 JSON 面留在 `Host/` 两个文件；**不新建** `*Compat*` / `*Adapter*` / `Legacy*` 文件（`check-no-legacy.sh:63-70` 是 enforced 规则）。

### 3.5 错误返回

```swift
public struct WebResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let data: JSONValue?
    public let error: String?       // 逐字不变（127 处 UI 调用点零改动）
    public let errorCode: String?   // 新增：仅当 error 是 GatherErrorCode 才非 nil
}

public struct CommandFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String          // 与今天 error 字符串逐字相同（可含 ::detail）
    public let detail: [String]
    public var errorCode: GatherErrorCode? { GatherErrorCode(rawValue: code) }
    public var description: String { ([code] + detail).joined(separator: "::") }
}
```

core 侧只加无侵入协议，把 20 个 if-let 收成 1 个：

```swift
public protocol CommandCodeDescribing: Error {
    var commandCode: String { get }
    var commandDetail: [String] { get }
}
```

散文型错误（`CullingServiceError.ratingOutOfRange`、`SettingsError.unknownKey`）不强行归一，`errorCode` 保持 nil，UI 文案不变。

### 3.6 三段完整示例

```swift
// 同步读
struct SessionList: Command {
    static let id: CommandID = .sessionList
    static let execution: CommandExecution = .sync
    static let effect: CommandEffect = .read
    struct Params: Decodable, Sendable {}
    func run(_ params: Params, _ ctx: CommandContext) async throws -> [SessionData] {
        try ctx.env.sessionService.listSessions()
    }
}

// 异步 job + destructive
struct ExportExecute: Command {
    static let id: CommandID = .exportExecute
    static let execution: CommandExecution = .job
    static let effect: CommandEffect = .destructive
    static let guardRule: CommandGuard = .confirmation("EXPORT_CONFIRMATION_REQUIRED")
    static let paramsErrorCode = "EXPORT_PARAMS_INVALID"
    struct Params: Decodable, Sendable { let sessionId: String; let options: ExportOptions }
    func run(_ params: Params, _ ctx: CommandContext) async throws -> ExportResult {
        let env = ctx.env
        env.jobService.start()
        let fingerprint = try env.exportService.deliveryFingerprint(
            sessionId: params.sessionId, options: params.options)
        let job = try env.jobService.create(JobCreateParams(
            type: .exportExecute, scopeType: "session", scopeId: params.sessionId,
            dedupeKey: "export.execute:(params.sessionId):(fingerprint)",
            checkpoint: ["options": try JSONValue(from: params.options),
                         "deliveryFingerprint": .string(fingerprint)]))
        guard let result: ExportResult = try await env.jobService.waitForResult(jobId: job.id) else {
            throw JobServiceError.jobFailed(job.id, "empty export.execute result")
        }
        return result
    }
}

// destructive 同步：确认码由注册表裁决，命令内无 guard
struct CullingReset: Command {
    static let id: CommandID = .cullingReset
    static let execution: CommandExecution = .sync
    static let effect: CommandEffect = .destructive
    static let guardRule: CommandGuard = .confirmation("CULLING_RESET_CONFIRM_REQUIRED")
    struct Params: Decodable, Sendable { let sessionId: String; let groupId: String? }
    func run(_ params: Params, _ ctx: CommandContext) async throws -> Bool {
        try ctx.env.cullingService.resetCommand(
            sessionId: params.sessionId, groupId: params.groupId, confirmed: true)
        return true
    }
}
```

### 3.7 PR 序列

| PR | 改动范围 | 切换/验收 | 人日 |
| --- | --- | --- | --- |
| A-1 | spec 118 行 + 生成器 + CommandID/descriptors + parity 测试 + `--check` 进 CI | 仅新增；82/36 与旧黄金清单集合相等 | 2 |
| A-2 | `AppEnvironment` 抽 makeDefault；`JobExecutors` 抽 registerExecutors；Router 保留转发 | 纯搬移，994+298 全绿 | 3 |
| A-3 | `CommandFailure/CommandCodeDescribing/CommandErrorMapper` + `WebResponse.errorCode` | 旧 errorMessage 作 oracle，字符串 diff 为空 | 2.5 |
| A-4 | 注册表 + 8 条只读 sync 命令；Router 先查注册表再回落旧 switch；门禁取并集 | 读路径开始切 | 3 |
| A-5 | 读命令全量（session/photo/filter/navigation/person/template/album/quality/settings/jobs/image/assets/dup） | 每批删本批 case；0 NOT_IMPLEMENTED | 4 |
| A-6 | 写（非 destructive）+ culling 同步面 | 写路径切换；只对读命令做 shadow 双跑 | 3.5 |
| A-7 | 36 条 async/job（navigation.analyze … export.execute） | 写路径切换完成；取消/恢复回归 | 5 |
| A-8 | 删两个旧 switch；门禁加「Router 禁止 case」enforced | Router ≤200 行；118/118 注册表派发 | 1.5 |
| A-9 | 兼容收尾（1-2 版本后） | 独立 PR，可延后 | 1.5 |
| 缓冲 | 评审/回归 |  | 3 |
| **合计** |  |  | **≈29** |

关键路径 A-1 → A-4 → A-7 → A-8（13.5 人日）。门禁改造要点：`check-command-surface.sh` 的 ①②⑥ 三处判据依赖 Router 的 `case "x.y"` 文本，A-4 起必须改为「旧 case ∪ `gen --list`」，A-8 后改为注册表单一数据源，否则会静默变成空集门禁。

### 3.8 风险

1. **生成器成新单点**：spec 与生成物同 PR + `--check` 门禁 + 黄金清单交叉校验。
2. **类型擦除逃逸**：`AnyCommandHandler` 只允许出现在 Commands/Core 与生成物；门禁禁止业务文件直接拼 JSON。
3. **错误码漂移是最大回归面**：`error` 字符串冻结 + oracle 测试；散文型错误不强行归一。
4. **线程语义被顺手优化**：executeAsync 对 sync 继续 GCD、job 继续 waitForResult，禁止在本轮改 Task。

---

## 4. 工作流 B：持久化边界 + 读写分离（38 人日）

### 4.1 目标结构

```
GatherPersistence/
├── Database/
│   ├── Database.swift            # Database、ReaderPool、TxScope、Checkpoint
│   ├── Connection.swift          # 原 DB.swift，DBConnection 降为 internal
│   ├── DBError+Typed.swift       # busy/constraint/io/corrupt/closed/schema/misuse/interrupted
│   ├── DatabaseMetrics.swift     # 锁等待、事务时长、慢查询
│   └── Migrations/
├── Queries/                      # 查询对象（值类型，无 SQL 外泄）
└── Repositories/                 # 18 个 Repo 平移，具体类不抽协议
```

### 4.2 关键接口

```swift
public final class Database: @unchecked Sendable {
    public struct Options: Sendable {
        public var readers: Int          // 默认 max(2, min(4, cores/2))
        public var busyTimeoutMs: Int32  // 5000
        public var readerCacheKB: Int32  // 16 * 1024
        public var synchronous: String
        public static let `default`: Options
    }
    public static func open(at path: String, options: Options = .default) throws -> Database

    /// WAL 快照：闭包内所有 SELECT 同一快照；已在写作用域内则复用 writer。
    public func read<T>(_ body: () throws -> T) throws -> T
    /// BEGIN IMMEDIATE + 单写者锁；嵌套降级 SAVEPOINT（与现 transaction 语义一致）。
    public func write<T>(retry: DBRetryPolicy = .none, _ body: () throws -> T) throws -> T
    public func checkpoint(_ mode: CheckpointMode) throws
    public func interrupt()
    public var isClosed: Bool { get }

    // internal：只有 Repo 能取连接
    func prepare(_ sql: String) throws -> DBStatement
}
```

错误在 DB 层解析一次，上层不看文案：

```swift
public enum DBError: Error, Equatable, Sendable {
    case busy(retryAfterMs: Int, operation: String)
    case constraint(DBConstraint, table: String?, column: String?)
    case io(DBIOFailure, path: String?)
    case corrupt(code: Int32, detail: String)
    case closed
    case schema(String)
    case misuse(String)
    case interrupted
}
extension DBError { public var retry: DBRetryDirective { get } }
```

- 重试只在 `busy`：读作用域内建 3 次退避（20/50/100ms，叠加 SQLite busy_timeout）；写只在调用方显式 `retry: .onBusy` 且闭包幂等时重试。
- `constraint` 不重试，由 Repo 映射到既有域内码；`io/corrupt` 立即停写并走备份恢复；`closed/misuse` 是编程错误，DEBUG 断言。
- **不新增 GatherErrorCode**：DB 故障有域内码则透传，否则落通用码，UI 行为与今天一致。

### 4.3 连接与事务

- writer：`READWRITE|CREATE|FULLMUTEX` + WAL、busy_timeout=5000、wal_autocheckpoint=1000、foreign_keys=ON、cache_size=-64MB。
- reader：`READONLY|FULLMUTEX` + `query_only=ON`、cache_size=-16MB；**不设 journal_mode**（只读连接会失败）。
- `:memory:` 回退单连接（读=写），保住全部内存库测试。
- 当前事务经线程本地上下文暴露给同线程 Repo；**事务闭包禁止 async/await**，否则跨挂起点会串事务。
- 事务行预算 2000：`write` 内执行数超限抛 `.misuse("transactionTooLarge")`；>250ms 事务记 warn 并带首条 SQL。

### 4.4 边界收紧

| 现状 | 目标 | 手段 |
| --- | --- | --- |
| Services 128 处 `prepare()`、38 处 `transaction`、15 个 `connection` 字段 | 0 | `check-db-boundary.sh` 预算只降不升；每服务一个 PR |
| `SessionService.deleteSessionDependencies` 手写 8 条 DELETE | `SessionRepo.deleteCascade(sessionId:)` | 仓储封装 |
| `RAWDecoder` → `PhotoRepo.rawExtensions` | `GatherProtocol/FileFormats.swift` | 常量下沉 |
| `IPC/HelperProtocol` → `SessionData` | helper 自己的 DTO 或 GatherProtocol | 去 mock 业务模型依赖 |
| 全列覆盖 upsert | `applyPatch(photoId:sessionId:patch:)` | 只 SET 出现的列；全量 upsert 更名 replaceAll |
| 字符串匹配 `"UNIQUE"` / `"no such table"` | typed `DBError` | 扩展错误码映射 |

### 4.5 长任务：先算后写

```swift
// CullingService.batchUpdate
let plan = try store.read { try cullingRepo.updatePlan(sessionId: sessionId, photoIds: ids, patch: patch) }
if plan.rows.count <= Self.atomicLimit {          // 2000：UI 全选上限，原子语义不变
    return try store.write { try cullingRepo.apply(plan) }
}
return try commitChunked(plan, size: 1_000)       // >2000：分片，片间 signal.throwIfCancelled()

// FaceKwService.analyze
let snapshot = try store.read { try faceRepo.analysisSnapshot(sessionId) }
let computed = try await FacePipeline.compute(snapshot, embedder, signal, onProgress)
for chunk in computed.observations.chunked(by: 100) {
    try store.write { try faceRepo.commitObservations(chunk, expectedIndexSeq: snapshot.indexSeq) }
}
try store.write { try faceRepo.publishClusters(computed.partition, expectedIndexSeq: snapshot.indexSeq) }
```

### 4.6 PR 序列

| PR | 内容 | 可编译/回滚 | 切换点 | 人日 |
| --- | --- | --- | --- | --- |
| B-1 | `Database/ReaderPool/DBError`；旧 API 保留；迁移仍单连接 | 纯新增，删文件即回 | 不切 | 3 |
| B-2 | 1W+N R；bootstrap 改 `Database.open`；`:memory:` 单连接 | 开关 `GATHER_DB_POOL=0` | **切读路径** | 4 |
| B-3 | typed error：UNIQUE 匹配、12 处业务裸码、50 处诊断 | 逐 Repo 可回退 | 不切 | 3 |
| B-4a/b/c | SQL 下沉：Duplicate/Indexer/Culling，再 9+8+7+7+7，再 6+6+5+5+4+2+1 | 每服务单 revert；预算门禁 | **切写路径** | 12 |
| B-5 | 长任务先算后写（face/sim/culling） | 开关 `long_task_chunked` | **切长任务** | 8 |
| B-6 | v36 迁移 + 一致性修补（与 E 合并） | 含备份 | — | 6 |
| B-7 | 门禁收紧 + ADR-032 + 快照 36 | 文档/脚本 | — | 2 |
| **合计** |  |  |  | **38** |

### 4.7 风险

1. **不选 DB actor**：82 条同步命令与 execute 是同步签名，actor 会强制全链路 async、触碰路由契约且无法分 PR；用“连接池 + 同步作用域 + 线程本地事务上下文”，代价是锁纪律靠断言。
2. **分片破坏原子性**：≤2000 保持单事务；>2000 明确为兼容层，人脸观测是派生数据可重算，culling 大选择集返回已提交数。
3. **读池内存**：4×16MB + 64MB 需与缩略图缓存同预算；`:memory:` 路径用临时文件库补测。
4. **事务内禁 I/O 无编译期保证**：靠“闭包无 async”+ DEBUG 断言 + 慢事务日志 + 审查兜底。

---

## 5. 工作流 C：表现层重构（29 人日）

### 5.1 目标结构

```
Sources/GatherApp/（D-7 后整体迁入 Sources/GatherUI/）
├─ Navigation/   RootView(≤300)、RootNavigation(不动)、RootSidebar、RootDestination
├─ Workspace/    SessionWorkspaceStore、SessionWorkspace、WorkspaceIntent
├─ Support/      ViewState、CommandError、RequestGate、LanguageStore、LocalizedText
├─ Localization/ L10n、EnvironmentValues+Language
├─ Culling/      CullingViewModel、CullingView(≤200)、CullingActionController、Views/*
├─ Duplicates/ Export/ FaceKeywording/ Settings/ ControlCenter/   # 同构
└─ Preview/      PreviewFixtures、PreviewGallery        # #if DEBUG
```

### 5.2 会话态所有权

```swift
@MainActor @Observable
final class SessionWorkspaceStore {
    init(capacity: Int = 6, make: @escaping (String) -> SessionWorkspace)
    private(set) var pinnedSessionId: String?
    func workspace(for id: String) -> SessionWorkspace   // 命中提序；超限淘汰最久未用且非 pinned
    func pin(_ id: String?)                              // 旧 pinned 自动 suspend
    func evict(_ id: String)                             // close()：取消 Task、释放大数组
}

@MainActor @Observable
final class SessionWorkspace {
    enum Lifecycle { case active, suspended }
    let sessionId: String
    let culling: CullingViewModel; let duplicates: DuplicatesViewModel
    let export: ExportViewModel;   let face: FaceKeywordingViewModel
    private(set) var lifecycle: Lifecycle
    func enqueue(_ intent: WorkspaceIntent)
    func take(_ kind: WorkspaceIntent.Kind) -> WorkspaceIntent?   // 取出即清
    func activate(); func suspend(); func close()
}

enum WorkspaceIntent: Equatable, Sendable {   // 取代 4 个 pending* 容器、faceKwInitialRole、pendingGalleryPhoto*
    case galleryFilter(GalleryFilter), galleryPhoto(id: String?, path: String?)
    case cullingConflicts, faceAnalyze, faceRole(String), exportRange(ExportRangeIntent)
    enum Kind { case galleryFilter, galleryPhoto, cullingConflicts, faceAnalyze, faceRole, exportRange }
}
```

生命周期由 store 显式驱动，**不依赖 onDisappear**（页面按目的地条件构建，销毁时不保证触发，RootView.swift:504 已记录）。suspend 取消 gate 与轮询、保留已载数据；activate 恢复并按 pending 补刷；close 供 LRU 淘汰。

### 5.3 VM 统一契约

```swift
enum ViewState<V: Equatable & Sendable>: Equatable, Sendable {
    case idle, loading(previous: V?), loaded(V), failed(CommandError), cancelled
    var phase: LoadPhase { get }                 // 过渡桥：既有 phase 断言不改
}

struct CommandError: Error, Equatable, Sendable {
    let code: String; let params: [String]; let diagnostic: String; let retryable: Bool
    init(_ error: any Error)                     // Native/Router/SessionService 三种错误统一取码
}

@MainActor final class RequestGate {
    private(set) var generation = 0
    @discardableResult func begin() -> Int
    func isCurrent(_ issued: Int) -> Bool
    func run(_ body: @escaping @MainActor (Int) async -> Void)
    func cancel()
}

protocol CommandExecuting: Sendable {            // VM 唯一外部依赖；Preview/测试用替身
    func execute(_ c: String, params: [String: JSONValue]) throws -> JSONValue
    func executeAsync(_ c: String, params: [String: JSONValue]) async throws -> JSONValue
}
```

- 4 套 stale 守卫（Gallery fetchGeneration、Library latestRequestID、Similarity tierRequestID、Culling pageVersion）统一为 `RequestGate`。
- 6 个 VM 的 `errorMessage: String?` 改为 `actionError: CommandError?`；View 只在边界翻译。
- `CommandExecuting` 是 A 落地前的过渡缝；A 的 `CommandExecutor` 实现同一协议后，VM 无需再改。

### 5.4 View 拆分与 Preview

| 文件 | 现状 | 拆分为 |
| --- | --- | --- |
| CullingView.swift 3,525 行 | VM 1-1388 + 单 struct 1,342 行 | CullingViewModel、CullingView、CullingActionController、Views/{Workbench,Toolbar,Inspector,InfoBar,Filmstrip,Viewer,ConflictPanel,Shortcuts} |
| SettingsView.swift 1,756 行 | 单 body | SettingsView + General/Appearance/Face/Storage 四个 Section View |
| FaceKeywordingView.swift 2,098 行 | VM + 2 body | FaceKeywordingViewModel、ClusterListView、DetailView、WritebackSheet |
| SessionControlView.swift 1,073 行 | 单 struct | SessionControlView、StageTimeline、ActionList、DiagnosticsCard |
| ExportView.swift 1,139 行 | VM + View | ExportViewModel、ExportSetupForm、ExportProgressView |

快捷键抽成 `enum CullingShortcut` + `CullingShortcutMap`，Viewer 只做映射，可单测。目标 `#Preview` ≥12，单文件 ≤600 行（CullingView ≤200）。

### 5.5 本地化：LanguageStore + Environment

```swift
@MainActor @Observable
final class LanguageStore {
    enum Language: String, Sendable { case zhHans = "zh-CN", en }
    private(set) var language: Language
    private(set) var switchCount = 0            // 菜单/Commands 无 Observation，仍靠版本号重建
    func set(_ l: Language)                     // 同步 GatherLocalization.setAppLanguage
    var l10n: L10n { L10n(language: language) }
}
struct L10n: Sendable {
    func callAsFunction(_ key: String) -> String
    func errorText(_ e: CommandError) -> String
    func format(_ key: String, _ args: CVarArg...) -> String
}
```

- 注入：`.environment(store)`（GatherApp.swift 两处）；视图 `@Environment(LanguageStore.self)`；预览注入 `LanguageStore.preview`。
- 迁移 1497 处 `GatherLocalization.l(`：视图内改 `l10n(`；`String(format:)` 改 `l10n.format`；模型/静态串改 `(L10n) -> String`，编译期强制传值。
- 允许清单 `docs/i18n-migration.lst` + `check-localization-surface.sh`：清单内文件计数必须为 0，回滚即删清单行；`GatherLocalization.l` 永久保留给菜单/AppDelegate。
- 删除 `.id(languageVersion)`；ADR-025 现状更正。
- **回退方案**：若 C-7..C-9 排期不足，保留 `.id`，仅完成 WorkspaceStore 状态所有权（C-1..C-6）；语言重建不丢持久状态，但纯视图状态仍丢。该回退必须写入 ADR。

### 5.6 错误呈现

```swift
struct GatherErrorBanner: View {
    let error: CommandError
    let actions: [ErrorAction]
    let onAction: (ErrorAction) -> Void
}
```

`ErrorActions.actions(for:)` 表驱动：C1_NOT_AUTHORIZED → 打开隐私设置；C1_NOT_RUNNING/NO_DOCUMENT → openSettings；EXPORT_DIR_* → 聚焦导出目录；XMP_* → 控制中心 + 重试；retryable → 重试；其余 dismiss。VM 不再存上屏字符串。

### 5.7 PR 序列

| PR | 改动 | 可编译/回滚 | 人日 |
| --- | --- | --- | --- |
| C-1 | 6 个根页先就地归入 Sources/GatherApp/<Feature>/（**与 D-7 合并执行**，避免二次移动）；门禁 UI_DIRS 更新 | 纯路径，revert 即回 | 0.5 |
| C-2 | ViewState/CommandError/RequestGate/LanguageStore/L10n + 单测，零调用点 | 新增文件 | 2 |
| C-3 | 4 个会话 VM 接 RequestGate/CommandError；errorMessage 留计算属性 | 逐 VM 合并 | 3 |
| C-4 | SessionWorkspace(Store) + RootView 改壳；draftCache 删除；isActive → isViewActive；syncViewModels 删除 | 意图读写同 PR 切换 | 4 |
| C-5 | Culling VM 纯迁 + View 拆 7 块 + 12 Preview | 逐块替换 | 5.5 |
| C-6 | 其余 5 页同构拆分 | 单页一 commit | 4 |
| C-7 | LanguageStore/L10n 接线、删 .id、外壳/侧栏/页签迁移；ADR-025 更正 | 每文件独立 | 2.5 |
| C-8 | 6 页 l10n（Culling 255 / Face 181 / ControlCenter 108 / Settings 101 / Export 96 / Duplicates 69） | 每页一 commit | 3 |
| C-9 | Sources 页与 VM l10n（Library/Similarity/Dashboard/Gallery/Persons/Support，≈690 处） | 同上 | 3 |
| C-10 | 删兼容属性、门禁、文档 | 收尾 | 1.5 |
| **合计** |  |  | **≈29** |

C-4 是唯一同时改 RootView 与 6 个页签装配的步骤，冲突面最大，建议单独冻结评审。

### 5.8 测试

SessionWorkspaceStoreTests（LRU、pinned 不淘汰、evict 取消、take 取出即清）、RequestGateTests（交错起代只认末代、cancel 不落 failed）、ViewStateTests、CommandErrorTests（`CODE::p1::p2`、散文回退）、ErrorActionsTests（遍历 GatherErrorCode 动作非空）、CullingShortcutTests、LocalizationParityTests（en 键逐键等于 L10n(.en)）、RootShellTests（切语言后 destination 与 VM ObjectIdentifier 不变）。改写 ReviewFixTests 的 pendingGalleryPhoto 断言。

---

## 6. 工作流 D：模块拆分与工程化（35 人日）

> 本节采用专项设计的最终目标图：**GatherProtocol / GatherPersistence / GatherAnalysis / GatherDomain / GatherCore（过渡伞）/ GatherUI / GatherHost / GatherApp**。多一个 GatherHost 是为了修复“测试 target 依赖可执行 target”，让 Router/RootView/Bridge/DB 装配都在可测库中，GatherApp 只剩 @main。

### 6.1 依赖图

```text
GatherProtocol
  ├── GatherPersistence（+ CSQLite）
  ├── GatherAnalysis
  └── GatherUI
GatherDomain → Protocol + Persistence + Analysis
GatherHost   → UI + Domain + Persistence + Analysis + Protocol
GatherApp    → Host + UI（仅 @main/Scene）
```

- GatherAnalysis 只依赖 Protocol（Face/Similarity/Image 内 0 个 DB 符号，已核实）。
- GatherUI 只依赖 Protocol（值契约 + CommandRouter 端口 + 错误码），因此拿不到 SQLite/Persistence/Domain。
- 多一个 GatherHost 是为了修复“测试 target 依赖可执行 target”。

### 6.2 目录树

```text
gather-core/Sources/
├─ GatherProtocol/{Contracts,IPC,Command,Errors,Support}/
├─ GatherPersistence/{DB.swift,Schema/,Migrations/,Repositories/,Introspection/}
├─ GatherAnalysis/{Face/,Similarity/,Image/,Resources/FaceModels/}
├─ GatherDomain/{Services/,Support/}
├─ GatherCore/Exports.swift              # 兼容伞，PR-8 删
├─ CSQLite/ GatherCoreHelper/ GatherCoreBenchmarks/ GatherFaceBenchmarks/ GatherSchema/
gather-app/Sources/
├─ GatherUI/{7 个页面目录,Feature 目录,Support/,Preview/,Resources/{en,zh-Hans}.lproj}
├─ GatherHost/{SessionCommandRouter,RootView,CaptureOneBridge,SidecarXMPProvider,
│              GatherAppDelegate,GatherAppCommands,LiveProviders,AppBootstrap}
└─ GatherApp/GatherApp.swift
```

### 6.3 Package.swift

```swift
// gather-core
.target(name: "GatherProtocol", swiftSettings: swift6Settings),
.target(name: "GatherPersistence",
        dependencies: ["GatherProtocol", "CSQLite"], swiftSettings: swift6Settings),
.target(name: "GatherAnalysis", dependencies: ["GatherProtocol"],
        resources: [.copy("Resources/FaceModels")], swiftSettings: swift6Settings),
.target(name: "GatherDomain",
        dependencies: ["GatherProtocol", "GatherPersistence", "GatherAnalysis"], swiftSettings: swift6Settings),
.target(name: "GatherCore",        // 兼容伞：public import 四层
        dependencies: ["GatherProtocol", "GatherPersistence", "GatherAnalysis", "GatherDomain"]),
.executableTarget(name: "GatherCoreHelper", dependencies: ["GatherProtocol"]),
.executableTarget(name: "GatherCoreBenchmarks", dependencies: ["GatherAnalysis"]),
.executableTarget(name: "GatherFaceBenchmarks", dependencies: ["GatherAnalysis"]),
.executableTarget(name: "GatherSchema", dependencies: ["GatherPersistence"]),
.testTarget(name: "GatherCoreTests", dependencies:
    ["GatherCore", "GatherProtocol", "GatherPersistence", "GatherAnalysis", "GatherDomain"])
```

```swift
// gather-app
.target(name: "GatherUI",
        dependencies: [.product(name: "GatherProtocol", package: "gather-core")],
        path: "Sources/GatherUI", resources: [.process("Resources")]),
.target(name: "GatherHost",
        dependencies: ["GatherUI",
          .product(name: "GatherProtocol", package: "gather-core"),
          .product(name: "GatherPersistence", package: "gather-core"),
          .product(name: "GatherAnalysis", package: "gather-core"),
          .product(name: "GatherDomain", package: "gather-core")],
        path: "Sources/GatherHost"),
.executableTarget(name: "GatherApp", dependencies: ["GatherHost", "GatherUI"],
                  path: "Sources/GatherApp", linkerSettings: liquidGlassLinkerSettings),
.testTarget(name: "GatherAppTests", dependencies: ["GatherUI", "GatherHost"])
```

去掉 `sources:` 列表；target 目录即边界。

### 6.4 关键接口

```swift
// GatherProtocol/Command/CommandRouter.swift
public protocol CommandRouter: Sendable {
    func execute(_ command: String, params: [String: JSONValue]) throws -> JSONValue
    func executeAsync(_ command: String, params: [String: JSONValue],
                      completion: @escaping @Sendable (WebResponse) -> Void)
}
public struct WebResponse: Codable, Equatable, Sendable {
    public let ok: Bool; public let data: JSONValue?; public let error: String?
}
public protocol GatherCommandDiagnostic: Error, Sendable { var commandMessage: String { get } }

// GatherProtocol/FileFormats.swift
public enum PhotoFileTypes {
    public static let rawExtensions: Set<String>
    public static let rawPairingExtensions: Set<String>
    public static func isRAW(_ extWithDot: String) -> Bool
}
```

```swift
// GatherPersistence/Migrations/MigrationStep.swift
public protocol MigrationStep: Sendable {
    static var version: Int { get }
    func apply(_ db: DBConnection) throws
}
public enum MigrationRegistry { public static let steps: [any MigrationStep] } // V001…V038

// GatherPersistence/Introspection/SchemaSnapshot.swift
public struct SchemaSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var tables: [String: Table]
    public struct Table: Codable, Equatable, Sendable {
        public var columns: [Column]; public var foreignKeys: [ForeignKey]
        public var indexes: [Index]; public var ddl: String   // 归一化 DDL，覆盖 CHECK
    }
}
```

### 6.5 侵蚀点处理

| 现状 | 处理 |
| --- | --- |
| `RAWDecoder` → `PhotoRepo.rawExtensions`（RAWDecoder.swift:194） | 常量下沉 `GatherProtocol/FileFormats.swift`；旧属性保留 `@available(*, deprecated, renamed:)` 转发 |
| `HelperProtocol` → `SessionData`（HelperProtocol.swift:9） | IPC 与 Protocol 同 target：线协议信封本来就是契约；helper 只依赖 Protocol |
| `GatherLogger` 被 Persistence/Domain 共用 | 放 Protocol/Support（Foundation-only）；`BatchRunner` 留 Domain |
| `SHA256` 在 Database 但 Domain 在用 | 留 Persistence，不为一个工具函数再拆 target |

### 6.6 分步迁移计划

兼容机制：`Sources/GatherCore/Exports.swift` 用 `public import`（Swift 6；不支持则 `@_exported import`）转发四层。app 的 `import GatherCore` 与命令代码不改；测试逐文件补 `@testable import`（内部符号不会被伞转发）。伞只转发、不新增符号，PR-8 删除。

| PR | 改什么 | 可编译/回滚 | 切换点 | 人日 |
| --- | --- | --- | --- | --- |
| D-1 地基 | build.sh 拆 `scripts/lib/build-lib.sh` + 测试；CI 换缓存键/矩阵/加 explicit import check；module/doc/preview 门禁骨架 | 不动源码；revert 仅回脚本 | — | 3 |
| D-2 Protocol | 移 Protocol/IPC/Logging；新增 Command/（Router、WebResponse、NativeCommandClient）、Errors/、Support/PhotoFileTypes；BridgeError conform `GatherCommandDiagnostic`；全 core 补 import | 伞已建；import 补全机械 commit | RAW 常量切 Protocol | 6 |
| D-3 Persistence | 移 Database/（Migrations 暂整文件）；Domain/Host 补 import；测试去 import CSQLite | 公共 API 不变；单 PR revert | — | 4 |
| D-4 Analysis | 移 Face/Similarity/Image + Resources/FaceModels；benchmarks 依赖 Analysis | Bundle.module 指向 `gather-core_GatherAnalysis.bundle`；build.sh 已 glob | 资源 bundle 切换 | 3 |
| D-5 Domain | 移 Services/、Concurrent/；伞补齐四层 | 纯移动 | — | 2 |
| D-6 迁移工程化 | MigrationRunner 改 registry + 38 个 V0NN*.swift + Support/；快照 v2；GatherSchema dump/verify；重生成 schema.snapshot.json；v34 fixture；降级 guard；ADR-037 并改 ADR-006/029 | Runner 外观不变；现有迁移测试全绿 | 迁移执行切 registry；guard 放在 SchemaSQL 之前 | 6 |
| D-7 app 拆分 | 建 GatherUI 与 GatherHost；GatherApp 只留 @main；构造器改 `any CommandRouter`；C1 改端口；8 个 #Preview + DEBUG PreviewRouter | GatherAppTests 改依赖两库；CommandSurfaceRuntimeTests 原样搬 Host | Live provider 读写路径切 Host；UI 资源切 `gather-app_GatherUI.bundle` | 9 |
| D-8 收尾 | 删伞；全仓直接 import；删 `sources:`；更新 README/DEVELOPMENT/ADR 路径与门禁路径 | 删前 `import GatherCore` 已清零 | 全量直接 import | 2 |
| D-9 可选 SPI | `DBConnection.prepare/exec` 加 `@_spi(Store)`；Domain SQL 收敛后编译期强制 | 按文件渐进 | Services 不得 prepare 硬闸门 | 8-10 |
| **合计** |  |  |  | **35** |

关键路径 D-1 → D-2 → D-3 → D-4 → D-5 → D-7 → D-8。D-6 与 D-4/D-5 无文件冲突，可并行。

### 6.7 构建、CI 与迁移工程化

- 编译期：`swift build|test --explicit-target-dependency-import-check error`；未声明的 import（UI→Persistence、Analysis→Persistence、Domain→CSQLite）直接 error。
- 脚本门禁：`check-module-boundaries.sh`（dump-package 校验边 + UI 越界 import 0 + Domain prepare 基线只降不升）、`check-preview-surface.sh`（#Preview ≥8、仅 DEBUG）、`check-doc-paths.sh`（ADR 路径存在）。
- build.sh 拆 `scripts/lib/build-lib.sh`：`spm_bin_dir / find_bundle / copy_localizations / assert_bundle / sign_bundle`；逐 arch 构建 → lipo → 签 plugin 再签 app；`GATHER_BUILD_LIB_ONLY=1` 支持 10 条无依赖断言。
- CI：`boundary`（5 门禁）、`core`（explicit check + vector reconciliation）、`app`（tests + build.sh）、`universal`（lipo + codesign verify）、`previews`（debug build + preview gate）、`toolchain`（最新工具链）。
- 迁移：registry 必须严格 1…38 稠密；拆分前 dump 旧 schema，拆分后逐字节比对；v34 fixture 在拆分前生成；降级 guard 放在 `SchemaSQL.schemaSQL` 之前（现状会先执行 DDL 再抛错，Migrations.swift:130）。
- 资源：bundle 改名后 build.sh 用 glob + `assert_bundle` 硬失败；GatherLocalization 保留一个版本旧名探测；UI 加 bundle 测试。

### 6.8 风险

1. **伞形兼容掩盖依赖方向**：`import GatherCore` 仍能看见四层；用 explicit check + 伞“只转发不新增”+ PR-8 删除期限兜底。不一次性大爆炸，因为 89 个 core 测试文件的 `@testable` 内部访问会同时断。
2. **SwiftPM 传递 import**：Package 边不能阻止 `import CSQLite`（同一 build 目录）；explicit check 进 CI 与本地脚本，Xcode/Preview 构建不传该 flag，属已知盲区。
3. **资源 bundle 改名**：本地化/模型可能静默丢失；glob + assert_bundle 硬失败 + 旧名探测 + 测试。
4. **迁移拆文件改变顺序/事务粒度**：registry 稠密性测试；拆分前后逐字节比对；fixture 先于新代码生成。
5. **UI 纯化移动 Live provider/错误枚举/C1 端口**：行为漂移风险最高；118 条 CommandSurfaceRuntimeTests + WebResponse 不变 + 原 VM 测试全量迁移对冲。

---

## 7. 工作流 E：一致性与状态机（32 人日）

### 7.1 交付一致性：保留两表，主从 + intent

`metadata_outbox` 是文件/sidecar 真相源（xmp_path 键、revision CAS、多会话确认门）；`writeback_items` 是照片粒度的 UI 投影。二者是主从而非同构重复，**不合并**。原子性分两层：DB 层同库单事务；文件层（`xmp.restore` 不可回滚）用 `delivery_intents` 前滚。

```swift
public enum DeliveryPhase: String, Sendable { case prepared, fileRestored, applied }
public protocol DeliveryLedgerPort: Sendable {
    func prepare(_ intent: DeliveryIntent) throws -> Int64
    func advance(_ id: Int64, to phase: DeliveryPhase) throws
    func finish(_ id: Int64, error: String?) throws
    func replayAll() throws -> Int
}
```

confirm（全程无 await，可整段入事务）：

```swift
try store.write {
    guard try writebackRepo.getFailedCount(sessionId: sessionId, module: module) == 0
    else { throw WritebackServiceError.failuresPending }
    let s = try metadataSync.summaryLocked(sessionId: sessionId)
    guard s.pending == 0, s.writing == 0, s.failed == 0, s.conflict == 0
    else { throw MetadataSyncError.confirmIncomplete }
    try outboxRepo.markSessionSynced(sessionId: sessionId, sourceModule: source)
    try writebackRepo.markWrittenAsSynced(sessionId: sessionId, module: module)
    try sessionRepo.updateWritebackStatus(id: sessionId, status: DeliveryState.derive(...))
}
```

cleanup（文件阶段前置，DB 段独立事务）：

```swift
let id = try ledger.prepare(.init(kind: .cleanup, sessionId: sessionId, module: module))
let restored = try await metadataSync.restoreAndDelete(...)   // 幂等 restore
try ledger.advance(id, to: .fileRestored)
try store.write {
    try writebackRepo.deleteItemsByIds(...)
    try sessionRepo.updateWritebackStatus(...)
}
try ledger.finish(id, error: nil)
```

崩溃语义：`fileRestored` 后崩溃 → `replayAll()` 只重做删行，不重放 restore；confirm 重入幂等。

### 7.2 任务状态机

```swift
public enum AnalysisJobStatus: String, CaseIterable, Sendable {
    case queued, running, cancelling, interrupted, succeeded, failed, cancelled
    case unknown
    public var occupiesDedupeSlot: Bool { self == .queued || self == .running || self == .cancelling }
    public func canTransition(to next: Self) -> Bool { /* 唯一转移表 */ }
}
```

- 活跃常量由 enum 派生，SQL 字面量保持 `'queued', 'running', 'cancelling'`；测试逐字断言。
- `interrupted` 不占 dedupe 槽、可恢复终态、投影仍算 running（新增 `interruptedJobCount` 供 UI）。
- unknown → 不占槽、`error_code=JOB_STATUS_UNKNOWN`；迁移期先清洗再上 CHECK。

### 7.3 人物合并（幂等、按 photo 去重）

```sql
UPDATE person_photos SET person_id = :tgt
 WHERE person_id = :src
   AND NOT EXISTS (SELECT 1 FROM person_photos t
                    WHERE t.person_id = :tgt AND t.photo_id = person_photos.photo_id);
-- 冲突行按 plan 覆盖（仅 replaceTargetWith 的少数行）
UPDATE person_photos SET face_bbox = ?, confidence = ?, created_at = ?
 WHERE person_id = :tgt AND photo_id = ?;
DELETE FROM person_photos WHERE person_id = :src;
```

`PersonMergePlanner` 纯函数：confidence 高者胜；差 <0.05 取 bbox 面积大者；仍相等取 target。关键词并集排序去重；缩略图置空；向量不重算。

### 7.4 元数据缓存分字段 patch

```swift
public struct MetadataCachePatch: Sendable {
    public var sessionId: String?
    public var values: [MetadataCacheField: DBValue]
    public var degraded: Bool
}
```

富元数据列 `COALESCE(excluded.x, photo_metadata_cache.x)`；用户态列（rating/label/keywords）仍 `excluded`；新增 `degraded` 与 `metadata_source` 两列区分“真没有”和“降级没读到”。

### 7.5 读一致性

`SimilarityClusterStateRepo.load` 改单语句 CTE；通用规则：任何“两读一写/读后写”同步段必须包 `read`；含 await 的段落拆到 ledger phase。

### 7.6 PR 与工作量

| PR | 内容 | 人日 |
| --- | --- | --- |
| E-1 | v36：`delivery_intents` + `photo_metadata_cache.degraded/metadata_source` + person 去重（与 B 合并） | 4 |
| E-2 | `AnalysisJobStatus` + 状态机 + unknown 容错 + `interruptedJobCount` | 2 |
| E-3 | `MetadataCachePatch.apply` + shim | 4 |
| E-4 | `PersonMergePlanner` + 三步 SQL + 缩略图/关键词 | 4 |
| E-5 | `DeliveryCoordinator` + confirm 单事务 + cleanup ledger | 5 |
| E-6 | `load` 改 CTE + 读事务规则 | 2 |
| E-7 | v37：状态 CHECK（12-step rebuild，失败回退触发器） | 5 |
| E-8 | ADR-034 + 门禁 + 旧路径删除 | 2 |
| 缓冲 |  | 4 |
| **合计** |  | **32** |

关键测试：触发器注入三表零变更、`fileRestored` 崩溃回放、合影合并二次 no-op、降级 patch 保留 EXIF、CTE 读一致性、CHECK 迁移。

---

## 8. 工作流 F：相似度/人脸规模化（20 人日）

### 8.1 单一聚类实现

```swift
public protocol NeighborhoodSource {
    var count: Int { get }
    func neighbors(of index: Int, into buffer: inout [Int]) -> Int
}
public struct BFSWorkspace { var visited: BitSet; var clustered: BitSet; var queue: [Int] }
public enum DegreeGatedBFS {
    public static func groups(source: some NeighborhoodSource, minGroupSize: Int,
                              workspace: inout BFSWorkspace,
                              onGroup: (ArraySlice<Int>) -> Void)
}
```

4 处重复 BFS（ClusterEngine:512/587、IncrementalClusterer:346/432）退化为构造 source + 调该函数；`ClusterGraphParityTests` 逐位对账后删旧实现。

### 8.2 单趟管线 + diff 持久化

```swift
public struct ClusterParams: Sendable {
    public let threshold: Double
    public let minGroupSize: Int
    public let mode: GroupingMode
    public static let algorithmVersion = 2
    public func inputSignature(hashes: [String: String]) -> UInt64
}
public struct ClusterStateDiff: Sendable {
    public var upserts: [ClusterStateRow]
    public var deletes: [String]
    public var meta: ClusterMeta
    public var fullReplace: Bool
}
public enum ClusterPipeline {
    public static func run(state: ClusterState, hashes: [String: String],
                           params: ClusterParams,
                           onProgress: (Int, Int) -> Void) -> (result: ClusterResult, diff: ClusterStateDiff)
}
```

- `SimilarityService` 删除第二次 buildState→ComponentGraph（当前 :763/:772 双跑）。
- `SimilarityClusterStateRepo.apply(sessionId:meta:diff:)`：DELETE IN(500) + UPSERT + meta；`fullReplace` 保留给重编号 >30%。
- v38 迁移：`similarity_cluster_meta` 加 `algorithm_version / input_signature / state_digest`；DEBUG 落库后断言 digest；release 抽样校验。

### 8.3 ANN 与匹配热路径

- `CosineHnswIndex` 生产零引用：删除类 + 配置 + benchmark；新增 `VectorNeighborIndex` 协议（insert/searchTopK/save/load），`CosineLshIndex` 实现。
- 真正的热路径修复：`FaceMatcher` 改造为单实例 + `match(queries:threshold:)` 批量；扫描移出“每簇 × 每向量”循环。
- 索引持久化：`.gather/ann/<space>-<signature>.idx`，DB 只登记 `(path,dim,count,algorithm_version,signature)`；重启条件写入 ADR-036（库 >50k 且 LSH recall <0.9）。

### 8.4 人脸分析三段式

```
事务 A（短）：写入 prepared observations + analysis_state
事务外：聚类（每 512 张检查 abort）
事务 B（分片）：簇成员/簇/签名，每 500 行提交，generation CAS
```

推理 `flushBatch` 改 TaskGroup，并发 `face_inference_concurrency`（默认 2，上限 4，1=旧行为）；`EmbeddingModel.Cache` 改 `[Key: Task<Provider, Error>]` single-flight，stat 指纹与编译移出锁。

### 8.5 PR 与预算

| PR | 内容 | 人日 |
| --- | --- | --- |
| F-1 | `ClusterGraph` + Parity 测试 | 2.5 |
| F-2 | `ClusterPipeline` + diff | 3 |
| F-3 | Repo `apply(diff)` + v38 meta | 2 |
| F-4 | 人脸三段式 + 分片 | 3 |
| F-5 | 删 HNSW + `VectorNeighborIndex` | 2 |
| F-6 | FaceMatcher 批量 | 2 |
| F-7 | 推理并发 + 模型 single-flight | 2 |
| F-8 | 内存/位集/基准 | 2 |
| F-9 | 文档与门禁 | 1.5 |
| **合计** |  | **20** |

预算（目标，非现状）：10k dHash 全量 ≤900ms、增量 1% ≤120ms、diff 落库 ≤80ms；10k×512 人脸 ≤6s、≤400MB。

---

## 9. 统一 PR 路线

### 9.1 波次

| 波次 | 周 | 内容 | 可独立发布 |
| --- | --- | --- | --- |
| W0 止血 | 0-1 | 停机上 deadline；navigation.analyze/batch 移出主线程；Culling 缓存加锁；参数 clamp；person merge 去重 | 是（hotfix） |
| W1 地基 | 1-6 | B-1/B-2 + A-1/A-2 + C-2 + D-1 + E-1/E-2 | 是（内部结构） |
| W2 切换 | 6-11 | B-3/B-4 + A-3..A-5 + C-3..C-5 + D-2/D-3 + E-3..E-5 | 是 |
| W3 结构 | 11-16 | A-6..A-8 + C-6..C-8 + D-4..D-7 + E-6/E-7 + F-1..F-4 | 是 |
| W4 收尾 | 16-21 | B-5..B-7 + C-9/C-10 + D-8 + F-5..F-9 + 文档 | 是 |

C-1（根页物理移动）与 D-7（app target 拆分）合并，避免同一批文件被移动两次；C 的其余 PR 直接在当前 target 内落地，D-7 时整体迁入 GatherUI。

### 9.2 依赖与并行

- 关键路径：D-1 → D-2 → D-3 → D-4 → D-5 → D-7 → D-8；B-1 → A-2 → A-4..A-6 → A-7；C-2 → C-4 → C-5。
- 可并行：E 全流程（除迁移号）、F-1..F-3、B-4（SQL 下沉）、C-2（基础设施）。
- 迁移号：v36 = E-1 + B-6 的 person 去重/缓存列；v37 = E-7（CHECK）；v38 = F-3（簇 meta）。`docs/migration-reservations.md` 记录 owner/周次；CI 校验 `CURRENT_SCHEMA_VERSION`。
- 冲突面：A 的 Router、C 的 RootView、B 的 Repo 迁移、D 的 Package.swift 是四大热点文件，按“同一周只允许一个工作流改”排期。

### 9.3 里程碑验收

| 里程碑 | 指标 |
| --- | --- |
| M1（W1 末） | 主线程无 >100ms 同步 DB；退出 ≤5s；Services 0 处 `prepare` 完成 50%；Protocol/Persistence target 空壳可编译 |
| M2（W2 末） | 命令面 60% 类型化；RootView <600 行；切语言不丢导出/选择；confirm 单事务；GatherUI 可独立编译 |
| M3（W3 末） | 118/118 类型化；8 个 target 编译边界生效；CHECK v37 上线；聚类单趟；#Preview ≥8 |
| M4（W4 末） | 0 裸命令字符串；0 死门控；10k 批量 <2s；全部门禁绿；ADR-031..037 完成 |

---

## 10. 验收指标与门禁

### 10.1 性能

| 场景 | 目标 |
| --- | --- |
| 主线程单次阻塞 | P99 < 50ms（Instruments signpost） |
| 1 万张批量挑片 | < 2s，UI 不冻 |
| 退出（含卡死 writer） | ≤ 5s |
| 索引/分析期间 UI 查询 | P95 < 50ms |
| 300ms 写事务期间 8 读线程 | P99 < 20ms（B 的池测试） |
| 10k dHash 全量 | ≤ 900ms |
| 10k×512 人脸分析 | ≤ 6s / ≤ 400MB |

### 10.2 结构

- `SessionCommandRouter` ≤ 200 行；0 个 `case "..."`。
- Services 层 0 处 `prepare(`；UI 0 处 `import GatherPersistence`。
- RootView ≤ 300 行；单 View 文件 ≤ 600 行（例外需注释）。
- 11 个 VM 均有单测；0 处 `isActive: true`；0 处存储型 `errorMessage`。
- 8 个 target（Protocol/Persistence/Analysis/Domain/Core/UI/Host/App）+ 依赖门禁。

### 10.3 测试

- core：994 → ≥1,150；app：298 → ≥360。
- 新增：CommandSurfaceParity、CommandRegistry、CommandErrorMapperParity、DBErrorMapping、DatabasePool、RepositorySnapshot、DeliveryCoordinator、PersonMergePlanner、MetadataCachePartial、ClusterGraphParity、ClusterStateDiff、SchemaUpgradeFixture、SessionWorkspaceStore、RequestGate、LocalizationParity、MigrationRegistry、SchemaSnapshot。
- 所有新增测试必须在沙箱命令下通过；环境性用例用 `withKnownIssue` 或临时目录。

### 10.4 门禁

```bash
./scripts/check-no-legacy.sh
./scripts/check-command-surface.sh      # spec ↔ 生成物 ↔ 注册表
./scripts/check-layering.sh             # import 规则
./scripts/check-module-boundaries.sh    # dump-package + 越界 import + prepare 基线
./scripts/check-schema-snapshot.sh      # 快照逐字节
./scripts/check-db-boundary.sh          # SQL 预算 ratchet
./scripts/check-localization-surface.sh # 允许清单
./scripts/check-preview-surface.sh      # #Preview ≥8
```

---

## 11. 风险登记与回滚

| # | 风险 | 概率 | 影响 | 缓解 |
| --- | --- | --- | --- | --- |
| R1 | 命令迁移夹带行为变化 | 中 | 高 | oracle 测试；execute/executeAsync 语义冻结；按域切换 |
| R2 | 目标拆分裂环（RAW 常量/SessionData/Logging） | 中 | 中 | 先下沉常量；伞过渡；explicit import check 编译失败即发现 |
| R3 | 读池引入快照不一致 | 低 | 高 | 默认开关可回退；read 作用域；池测试 + 对照测试 |
| R4 | CHECK 迁移失败 | 低 | 高 | 单独 PR；pre-v37 备份；12-step rebuild 演练；触发器回退 |
| R5 | WorkspaceStore 生命周期回归 | 中 | 中 | 先行为等价再删旧路径；VM 单测覆盖五态 |
| R6 | 本地化迁移漏刷/冲突面大 | 高 | 中 | 允许清单 + parity 测试 + 按文件切换；可回退到保留 .id |
| R7 | 聚类 diff 与全量分叉 | 中 | 高 | digest 断言 + 抽样校验 + 强制全量回退开关 |
| R8 | 团队并行冲突（迁移号/Router/RootView/Repo/Package） | 高 | 中 | 迁移预约表；热点文件单周独占；每日 rebase |
| R9 | 伞形兼容掩盖依赖方向 | 中 | 中 | 伞“只转发不新增”；explicit check 进 CI；D-8 强制删除期限 |
| R10 | 资源 bundle 改名导致本地化/模型丢失 | 中 | 高 | build.sh glob + assert_bundle；旧名探测一个版本；bundle 测试 |

回滚原则：每个 PR 独立可 revert；DDL 只前进但保留备份；写路径开关默认旧行为；删除旧代码必须晚于新路径全绿一个发布周期。

---

## 12. 与现有 ADR 的关系

- **ADR-031**：类型化命令面与命令注册表（取代“字符串 switch + 文本门禁”）。
- **ADR-032**：持久化边界与数据库读写分离（Services 无 SQL；read/write 作用域）。
- **ADR-033**：表现层状态所有权（WorkspaceStore/SessionWorkspace；语言重建取舍修订）。
- **ADR-034**：交付一致性（outbox/writeback 主从 + delivery_intents 前滚）。
- **ADR-035**：模块拆分与依赖规则（target graph + 门禁）。
- **ADR-036**：聚类管线与 ANN 策略（单一 BFS、diff 持久化、HNSW 删除/接线条件）。
- **ADR-037**：迁移工程化（registry、快照 v2、vN-1 fixture、只前进）。
- 修订 **ADR-006/029**（schema 版本/表数）、**ADR-025**（语言重建现状）、**ADR-027**（增量语义）、**ADR-030**（ANN 重启条件）。

---

## 附录：关键文件清单（新增/改造）

| 工作流 | 新增 | 改造 |
| --- | --- | --- |
| A | docs/command-surface.json、scripts/gen-command-surface.swift、Command.swift、CommandID.swift、CommandSurface.generated.swift、CommandRegistry.swift、*Handlers.swift、CommandErrorMapper.swift、AppEnvironment.swift | SessionCommandRouter.swift（缩为门面）、CommandRouter.swift、NativeCommandClient.swift、12 个 UI 文件 |
| B | Database.swift、Connection.swift、DBError+Typed.swift、DatabaseMetrics.swift、check-db-boundary.sh | DB.swift、18 个 Repo、Services（去 SQL）、SessionService、RAWDecoder、HelperProtocol |
| C | SessionWorkspaceStore.swift、SessionWorkspace.swift、WorkspaceIntent.swift、ViewState.swift、RequestGate.swift、CommandError.swift、LanguageStore.swift、L10n.swift、Features/* | RootView.swift、6 个 View/VM 文件、GatherLocalization 边界、GatherEventCenter |
| D | Sources/Gather{Protocol,Persistence,Analysis,Domain,Core,UI,Host}/、scripts/lib/build-lib.sh、GatherSchema、Exports.swift | Package.swift ×2、build.sh、.github/workflows/ci.yml、迁移目录、schema.snapshot.json |
| E | DeliveryLedgerRepo.swift、DeliveryState.swift、DeliveryCoordinator.swift、JobStateMachine.swift、PersonMergePlanner.swift | WritebackService、CullingService、MetadataSyncCoordinator、PersonRepo、MetadataCacheRepo、AnalysisJobRepo、SessionRepo、Schema/Migrations |
| F | ClusterGraph.swift、ClusterPipeline.swift、ClusterStateDiff.swift、VectorNeighborIndex.swift | ClusterEngine、IncrementalClusterer、SimilarityService、FaceKwService、FaceMatcher、EmbeddingModel、SimilarityClusterStateRepo |

---

*设计版本：2026-10-21 · 与架构评审配套 · 行号以 HEAD 82603e0 为准*
