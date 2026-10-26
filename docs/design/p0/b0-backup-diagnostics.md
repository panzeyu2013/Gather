# B0 备份 / 恢复 / 诊断设计（P0）

> 状态：designing，待评审。只写本文件；未改代码/测试/其他文档；未跑构建/测试；未做网页调研。
> 基线：`docs/design/p0/README.md` D1–D10；契约草案 `docs/design/p0/x0-contracts.md`（只读）。

## 0. 结论先行

1. **备份**：用第二个 `DBConnection` 执行 `VACUUM INTO` 到 `.partial`，只读校验（`quick_check` + `user_version` + `SchemaShapeReader` 形状指纹）后原子改名，并写同名 `.json` sidecar；不占主连接，2GB 预算 27s。
2. **恢复**：不在进程内重建 16 域服务图（`AppRuntime` 一次性，`alreadyShutDown`）。`restore` 只校验并写 `restore-pending.json`；确认后退出（`runtime.shutdown()` 停 job、关库）；**下次启动**在 `Database.open` 前应用，失败回滚旧库。
3. **诊断**：给 `GatherLogger` 加文件 sink（5MB×5 轮转），导出 20MB 上限的脱敏 zip（默认不含绝对路径）；B0 不新增表；`MaintenanceAPI` 作为第 17 协议、4 个方法。

**三个关键决策**

- D-B1：备份走**独立连接**，不占 `Database.stateLock`，避免 2GB 期间 UI 读库冻结。
- D-B2：恢复**跨进程**；swap 在下次 `Database.open` 前完成；旧库 `gather.sqlite.pre-restore-<ts>` 保留。
- D-B3：备份记录用 **JSON sidecar + state.json**，不新增表；V3 仍只有 T0/F0 的两张表。

**非目标**：云备份、加密、增量/差异备份、DB 文件进诊断包、进程内热恢复、恢复不在 `Backups/` 的任意 SQLite 文件（P0 仅托管备份）。

## 1. 备份

### 1.1 类型与 sidecar

```swift
public enum BackupTrigger: String, Codable, Sendable, CaseIterable {
    case manual, autoLaunch, autoDaily, unknown
}
public struct BackupRecord: Codable, Sendable, Equatable, Identifiable {
    public let fileName: String
    public let createdAt: String          // ISO8601（nowISOString）
    public let sizeBytes: Int64
    public let schemaVersion: Int
    public let tableCount: Int
    public let trigger: BackupTrigger
    public let verified: Bool
    public let sha256: String?
    public var id: String { fileName }
}
```

文件名 `Gather-Backup-yyyyMMdd-HHmmss.sqlite`（同秒冲突追加 `-2`），sidecar 为同名 `.sqlite.json`：

```json
{"formatVersion":1,"createdAt":"2026-10-26T14:30:12Z","appVersion":"0.1.0",
 "schemaVersion":3,"tableCount":45,"sizeBytes":2147483648,"sha256":"…",
 "trigger":"manual","verified":true}
```

sidecar 用 `Data.write(options: .atomic)`；文件/sidecar/目录权限 `0600/0600/0700`。B0 不新增 DDL；V3 的 `triage_suggestions`、`face_cluster_constraints` 由 T0/F0 提供，B0 只读 `user_version` 与形状。

核心实现签名（可直接落地）：

```swift
public struct BackupVerification: Sendable, Equatable {
    public let schemaVersion: Int
    public let tableCount: Int
    public let sizeBytes: Int64
    public let sha256: String
}
public enum BackupVerifier {
    public static func verify(path: String, catalog: SchemaCatalog) throws -> BackupVerification
}

public enum RestoreApplyOutcome: Sendable, Equatable {
    case none
    case applied(RestoreApplied)
    case rolledBack(RestoreFailure)
}
public struct RestoreApplied: Sendable, Equatable {
    public let backupFileName: String
    public let preRestorePath: String
    public let schemaVersion: Int
}
public struct RestoreFailure: Sendable, Equatable {
    public let code: String
    public let message: String
}
public enum RestoreCoordinator {
    public static func hasPending(dbPath: String) -> Bool
    public static func applyPendingIfNeeded(dbPath: String, catalog: SchemaCatalog) throws -> RestoreApplyOutcome
    public static func finalizeOpened(dbPath: String) throws
    public static func rollbackToPrevious(dbPath: String) throws
}
/// AppBootstrap 在“apply → Database.open → finalize/rollback”全程持有；flock 随进程退出释放。
public final class RestoreLock {
    public static func acquire(at appDir: URL) throws -> RestoreLock
    public func release()
}

public enum MaintenanceError: Error, Equatable, Sendable {
    case backupBusy, backupVerifyFailed(String)
    case backupInsufficientSpace(needed: Int64, available: Int64)
    case backupPermissionDenied(String), backupFailed(String)
    case restoreBusy, restoreVerifyFailed(String)
    case restoreVersionUnsupported(backup: Int, current: Int)
    case restoreInsufficientSpace(needed: Int64, available: Int64)
    case restorePermissionDenied(String), restoreFailed(String)
    case diagnosticsExportFailed(String)
}

public struct MaintenanceState: Codable, Sendable, Equatable {
    public var autoPaused: Bool
    public var consecutiveFailures: Int
    public var lastAttemptAt: String?
    public var lastRestore: RestoreOutcome?
}
public struct MaintenanceStateStore {
    public let appDir: URL
    public init(appDir: URL)
    public func read() -> MaintenanceState
    public func write(_ state: MaintenanceState) throws
}
public struct BackupStore {
    public init(directory: URL)
    public func newURLs(now: Date) -> (partial: URL, final: URL, sidecar: URL)
    public func list() throws -> [BackupRecord]
    public func prune(keeping limit: Int, protecting: Set<String>) throws
}
public final class LogFileSink: @unchecked Sendable {
    public static func install(directory: URL, maxFileBytes: Int = 5_000_000,
                               maxFiles: Int = 5) -> LogFileSink
    public func enqueue(_ line: String)
}
public struct DiagnosticsCollector {
    public init(database: Database?, settings: SettingsService, state: MaintenanceStateStore)
    public func collect(destination: URL, includePaths: Bool) throws -> DiagnosticsExportResult
}
public final class MaintenanceService: @unchecked Sendable {
    public init(database: Database?, settings: SettingsService, state: MaintenanceStateStore,
                isOtherInstanceRunning: @escaping @Sendable () -> Bool)
    public func startScheduler()
    public func stopScheduler()
    public func waitForBackup(timeout: TimeInterval) async
    public func backup(trigger: BackupTrigger) async throws -> BackupRecord
    public func listBackups() throws -> MaintenanceInventory
    public func restore(_ input: RestoreBackupInput) async throws -> RestoreReceipt
    public func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult
}
```

上述 Codable 结构体按仓库惯例提供逐字段 `public init`（篇幅从略）；`RestoreBackupInput.init(fileName:)` 校验非空、长度 ≤255、不含 `/`/`\`/`..`。`database == nil` 只出现在裸连接测试夹具；此时维护命令抛 `BACKUP_FAILED`/`INVALID_PARAM`，生产路径恒非 nil。

### 1.2 流程（`MaintenanceService.backup`）

1. 目录：`backup_dir`（展开 `~`、必须绝对）否则 `appDir/Backups`；建目录 0700 + 写探针确认可写。
2. 预检可用空间 ≥ `dbSize × 1.15 + 64MB`；不足 → `BACKUP_INSUFFICIENT_SPACE`。
3. 分配 `.partial` / `.sqlite` / `.json` 路径。
4. 第二连接上 `PRAGMA wal_checkpoint(TRUNCATE)`（失败只 warn），然后：

```sql
VACUUM INTO '/…/Gather-Backup-20261026-143012.sqlite.partial';
```

路径字面量用 `''` 转义。第二个连接不持 `Database.stateLock`；`VACUUM INTO` 是单一读事务，备份是开始时的一致快照，不含备份期间新写入。`SQLITE_BUSY` 重试 3 次（每次 1s），仍失败 → `BACKUP_BUSY`。

5. 只读校验 `.partial`（`BackupVerifier`）：先断言 16 字节头 `SQLite format 3\0`，再执行：

```sql
PRAGMA quick_check;            -- 必须 "ok"
PRAGMA user_version;           -- 必须 1...catalog.current
SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';
```

再用 `SchemaShapeReader.read`（同 target 内部类型）与 `catalog.snapshot(version).shape.issues` 比对表/列/索引/外键/指纹；不符 → `BACKUP_VERIFY_FAILED`。

6. `FileHasher.sha256File(.partial)`（4MB 流式、CryptoKit）；写 sidecar → `rename(.partial, .sqlite)` → `chmod 0600` → prune。
7. 任一步失败：删 `.partial` 与 sidecar；绝不留下可被 `listBackups` 当成功的半成品。

**只读入口**：现有 `DBConnection(path:)` 打开即设 `journal_mode=WAL`（会改写备份文件头），且 `SchemaShapeReader` 只接受 `DBConnection`。新增 `DBConnection(path:readOnly:)`：`SQLITE_OPEN_READONLY`、跳过写 PRAGMA、`PRAGMA query_only=ON`；`reopen()` 对只读连接抛错。`BackupVerifier` 放 `GatherPersistence`。

### 1.3 性能预算（2GB，内置 SSD）

| 阶段 | 预算 | 依据 |
|---|---:|---|
| checkpoint | 1s | WAL 通常很小 |
| VACUUM INTO | 20s | 100–200MB/s |
| 只读校验 | 3s | quick_check + shape，不扫数据 |
| SHA-256 | 2s | `FileHasher` CryptoKit ~3.2GB/s |
| sidecar/rename | 1s | 原子写 |
| **合计** | **27s** | 外置慢盘允许超时，UI 只提示不失败 |

测量：分段 `backup_duration_ms` 日志 + `GATHER_BACKUP_PERF=1` 的 2GB 基准（不进默认 CI）。

## 2. 自动策略

| 设置键 | 默认 | 语义 |
|---|---|---|
| `backup_dir` | `""` | 空 = `appDir/Backups`；非空必须绝对、可写 |
| `backup_retention` | `"5"` | 1...20；只作用于当前目录的托管备份 |
| `backup_auto` | `"off"` | off/daily/launch |
| `diagnostics_include_paths` | `"0"` | 诊断包是否含绝对路径 |

- `AppBootstrap` 在 scene 发布后调用 `MaintenanceService.startScheduler()`；退出前 `stopScheduler()`（§3.4 的终止路径）。`backup_dir` 默认空串，需加入 `SettingsViewModel.clearableSettingKeys`；备份分组标题/字段/选项的 en 文案同 PR 补齐。
- `off` 不调度；`launch` 启动后 60s 检查一次；`daily` 另加每 6h 检查（应用运行期间）。
- 触发条件：最近一次 `verified` 备份超过 24h（或没有）、无备份进行中、无待恢复 journal、`autoPaused=false`。
- 失败：`appDir/maintenance-state.json` 记 `consecutiveFailures`/`lastAttemptAt`/`autoPaused`；连续 3 次置暂停，设置页显示“自动备份已暂停”，手动成功一次清零。
- 保留：成功后按 `createdAt` 保留最新 N 份；**保护**待恢复 journal 引用的文件；只删 `Gather-Backup-*` 与 sidecar，绝不碰 `gather.sqlite.pre-v*`。
- 与 `SchemaBackup` 的关系：迁移备份仍由 `Database.open` 写在 DB 同目录（`.pre-v<target>-*`，retention 3）；用户备份在 `Backups/`，两套命名/目录/保留完全隔离。恢复旧版备份后的迁移会再生成一份 `.pre-v*`，属预期。
- 目录锁：`Backups/.lock` 上 `flock(LOCK_EX)` 保护 create+prune；备份本身不加锁，多实例用唯一名。

## 3. 恢复状态机

### 3.1 类型与 journal

```swift
public struct RestoreBackupInput: Codable, Sendable, Equatable {
    public let fileName: String   // 仅文件名，不含 "/"、".."；服务内再校验前缀
}
public struct RestoreReceipt: Codable, Sendable, Equatable {
    public let backupFileName: String
    public let schemaVersion: Int
    public let requiresRestart: Bool   // P0 恒 true
    public let journalPath: String
    public let verifiedAt: String
}
public enum RestoreResult: String, Codable, Sendable { case applied, failed, rolledBack }
public struct RestoreOutcome: Codable, Sendable, Equatable {
    public let at: String
    public let backupFileName: String
    public let result: RestoreResult
    public let errorCode: String?
}
```

`appDir/restore-pending.json`（原子写）：

```json
{"journalVersion":1,"state":"prepared","createdAt":"…",
 "backupFileName":"Gather-Backup-….sqlite","backupPath":"…","backupSHA256":"…",
 "backupSchemaVersion":3,"dbPath":"…/gather.sqlite",
 "preRestorePath":"…/gather.sqlite.pre-restore-20261026-143512",
 "stagingPath":"…/gather.sqlite.restore-<uuid>.tmp","backupDir":"…/Backups"}
```

`state ∈ prepared|oldMoved|newInstalled|opened`；每次状态变更先写 journal，再做破坏性文件操作。

对应任务要求的顺序：**校验**（§3.4-2）→ **取消 job/关库**（§3.4-4，退出路径的 `JobService.stop` + `Database.close`）→ **替换**（§3.2，下次启动、`Database.open` 前）→ **重开**（§3.3 的 `Database.open`）。

### 3.2 状态 → 启动动作

| 状态 | 磁盘事实 | 下次启动动作 |
|---|---|---|
| prepared | db 存在，无 preRestore | 校验备份 → swap |
| prepared | db 缺失，preRestore 存在 | 回滚旧库，`failed` |
| prepared | db 与 preRestore 都存在 | 不 swap，保留 db，journal 改名 `.corrupt` |
| oldMoved | preRestore 存在，db 缺失/半成品 | 删 staging，回滚旧库，`failed` |
| oldMoved | db 与 preRestore 都存在 | 保守回滚旧库，`failed` |
| newInstalled | db 存在、preRestore 存在 | `Database.open`；成功 finalize；失败 rollback |
| newInstalled | db 缺失、preRestore 存在 | 回滚旧库，`failed` |
| newInstalled | db 与 preRestore 都缺失 | fatal（无库可开） |
| opened | db 存在 | 删 journal，正常启动 |
| opened | db 缺失 | fatal |

swap 顺序：journal `prepared` → 把 `gather.sqlite`、`-wal`、`-shm` 改名为 `preRestore*`（rename 不占空间）→ journal `oldMoved` → `copyItem(backup → staging)`（0600，fsync）→ `rename(staging → gather.sqlite)`、删残留 `-wal/-shm` → journal `newInstalled` → 返回 `.applied`，由 `AppBootstrap` 执行 `Database.open`。

### 3.3 启动接线（`AppBootstrap.makeScene`）

在 `Database.open(at:)` **之前**：

```swift
let lock = RestoreCoordinator.hasPending(dbPath: dbURL.path)
    ? try RestoreLock.acquire(at: appDir) : nil
defer { lock?.release() }
let restore = try RestoreCoordinator.applyPendingIfNeeded(
    dbPath: dbURL.path, catalog: .production)
let database = try Database.open(at: dbURL.path)
if case .applied(let applied) = restore {
    try RestoreCoordinator.finalizeOpened(dbPath: dbURL.path)
    // 成功后 toast：已从「X」恢复；旧库保留为 <preRestore>
}
```

- `Database.open` 抛错且 `restore == .applied`：`rollbackToPrevious` → 再 `Database.open` 旧库 → 失败 toast；回滚也失败则抛 fatal（文案给两个路径，不自动删数据）。
- 返回 `.rolledBack(failure)`：旧库正常打开 + 失败 toast。
- 启动时若 `RestoreCoordinator.hasPending`，`AppBootstrap` 先 `RestoreLock.acquire(at: appDir)`（`flock(LOCK_EX|LOCK_NB)`），并在 apply → `Database.open` → finalize/rollback **全程持有**，`defer` 释放；busy → `RESTORE_BUSY`，启动失败并提示“另一个 Gather 实例正在恢复，请退出后重试”（不打开库，避免双实例写旧 inode，也避免第二个实例看到 `newInstalled` 后再 swap）。
- 跨版本：`backupSchemaVersion > catalog.current` → 校验时 `RESTORE_VERSION_UNSUPPORTED`；`< current` 允许，`Database.open` 走既有迁移（迁移前 `SchemaBackup` 自动再备份）。
- 旧库保留：`preRestore` 三件套保留最近 2 套；finalize 后按时间戳 prune。
- 恢复期间没有活连接：swap 发生在进程启动、`Database.open` 之前；当前进程的“停 job/关库”由退出路径的 `AppRuntime.shutdown()` 完成（`JobService.stop` 15s 宽限 + `Database.close`）。
- journal 损坏或 `dbPath` 与本机不一致：改名 `.corrupt-<ts>`，不 swap，继续打开现有库；现有库也缺失才 fatal。

### 3.4 恢复 API 流程

1. UI 在托管列表选择 → `restore(Confirmed<RestoreBackupInput>)`。
2. 服务校验：文件名白名单（`Gather-Backup-` + `.sqlite`，无路径分隔）、文件存在、sidecar/`BackupVerifier` 通过、version ≤ current、`backupSize + 128MB` 可用空间、DB 目录可写、无备份进行中（否则 `RESTORE_BUSY`）、无其他实例。
3. 写 journal `prepared` 前先获取并**持有** `.restore.lock` 到进程退出（防止确认后新实例启动抢先 swap）；失败则 `RESTORE_BUSY`。返回 `RestoreReceipt(requiresRestart: true)`。若退出被取消，journal 保留、锁随进程继续持有，下次启动仍会恢复；UI 必须把这一点写进确认文案（已确认的操作不会静默撤销）。
4. UI 显示“正在退出并恢复…” → `NSApp.terminate(nil)`；`applicationShouldTerminate` → `onPrepareForTermination`（`maintenance.waitForBackup(timeout: 15s)` → `runtime.shutdown()`）→ 退出。
5. 下次启动按 §3.2 完成；结果写 `maintenance-state.json`，设置页显示“上次恢复：成功/失败”。

### 3.5 与 XMP / 写回队列的关系

恢复只还原 `gather.sqlite`，**不还原照片旁的 XMP**；备份之后写入的 XMP 可能比恢复后的 DB 新。若恢复后仍自动回放备份里的 pending intent，会覆盖较新的 XMP。P0 规则：

- `RestoreCoordinator` finalize 后写 `maintenance-state.json.lastRestore`；
- `AppBootstrap` 发现本次启动完成过恢复时，调用 `runtime.start(replayPendingDeliveries: false)`（`AppRuntime.start` 增可选参数，默认 true），本次不自动回放；
- toast/设置页提示“恢复只覆盖资料库与设置，照片旁的 XMP 未回滚；请重新索引并检查 XMP 冲突”；
- 用户经 `metadata.conflicts` 裁决或 `culling.retryFailedWriteback` 后再恢复自动回放。

## 4. 用户流程与文案

**设置页**：新增 `backup` 分组（`backup_dir`/`backup_retention`/`backup_auto`，复用 `SettingGroup` 与 `_dir` 文件夹选择），并在 `primaryGroups` 之后加“数据与恢复”Section（`SettingsView+MaintenanceSection.swift`）：

- 上次备份：`2026-10-26 14:30 · 2.1 GB · v3`（无则“尚未备份”）；
- 按钮：立即备份 / 恢复… / 导出诊断包…；
- 开关：诊断包包含绝对路径（默认关，开启时二次确认）；
- 自动暂停横幅 + “重试”。

**恢复 sheet**（`BackupRestoreSheet.swift`）：托管备份列表（文件名/时间/大小/版本/已验证），单选；固定警告：“恢复会覆盖当前资料库与设置；当前资料库会保留为 `.pre-restore` 副本。Gather 将退出，重新打开后完成恢复。” 主按钮 `恢复并退出`（destructive）；未验证项额外确认。恢复中禁用全部按钮，显示“正在校验…”。

**进度/错误**：`VACUUM INTO` 无进度回调，P0 显示不确定进度 + 已用秒数；错误用 `NativeBanner` + 错误码文案。关键文案（中文为源 key，en 同 PR 补齐）：`数据与恢复`、`上次备份`、`立即备份`、`备份目录`、`保留份数`、`自动备份`、`关闭/每天/每次启动`、`恢复…`、`导出诊断包…`、`包含绝对路径`、`恢复并退出`、`正在备份…（已 %d 秒）`、`恢复会覆盖当前资料库与设置；当前资料库将保留为备份副本。`

## 5. 诊断包

**文件日志 sink**（`GatherApplication/Logging/LogFileSink.swift`）：

- 安装时 tee 现有 `GatherLogger.output`（保留 stdout），幂等；`AppBootstrap` 在 `Database.open` 前安装到 `appDir/Logs`。
- 活动文件 `gather.log`；>5MB 轮转 `gather-<yyyyMMdd-HHmmss>.log`，保留 5 个；串行队列异步写；队列 >10k 丢弃并累计，下次写入补 `log dropped N`；轮转时 `synchronize`。
- 级别默认 `.info`；`GATHER_LOG_LEVEL=debug` 可临时提高。

**导出**（`DiagnosticsCollector`）：用户经 `NSSavePanel` 选 `.zip`；API 只接受绝对 `.zip`、父目录可写。staging 写完后用 `/usr/bin/ditto -c -k --norsrc --noextattr` 打包到 `.zip.partial`，再 rename；失败删 staging。

| 文件 | 内容 | 默认脱敏 |
|---|---|---|
| `manifest.json` | formatVersion、时间、app 版本/build、macOS/arch、schemaVersion、DB/WAL 大小、表数、job 计数、是否含路径 | 路径布尔 |
| `tables.json` | `photos/sessions/face_observations/analysis_jobs/deliveries` 行数（5s 预算） | 无路径 |
| `jobs.json` | 最近 50 个 job（id/type/status/progress/error code） | 不含 checkpoint/路径 |
| `settings.json` | `settings.all()` 全量；路径类键值替换为 `<path>` | includePaths=false 时 |
| `logs/` | 最新日志，≤15MB | 绝对路径 → `~`/`<volume>` |
| `README.txt` | 说明与隐私提示 | — |

不含 DB 文件、照片/缩略图/XMP 内容、人脸向量。总大小硬上限 20MB；超限先丢最旧日志，仍超限 → `DIAGNOSTICS_EXPORT_FAILED`。zip 0600。

## 6. API / 错误码（第 17 协议）

```swift
public protocol MaintenanceAPI: Sendable {
    func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord
    func listBackups() async throws -> MaintenanceInventory
    func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt
    func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult
}
public struct MaintenanceBackupInput: Codable, Sendable, Equatable {
    public let trigger: BackupTrigger
    public init(trigger: BackupTrigger = .manual) throws // 只允许 .manual
}
public struct MaintenanceInventory: Codable, Sendable, Equatable {
    public let backupDir: String
    public let backups: [BackupRecord]
    public let lastRestore: RestoreOutcome?
    public let autoPaused: Bool
}
public struct DiagnosticsExportInput: Codable, Sendable, Equatable {
    public let destinationPath: String
    public let includePaths: Bool? // nil = 读设置
    public init(destinationPath: String, includePaths: Bool? = nil) throws
}
public struct DiagnosticsExportResult: Codable, Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let logFileCount: Int
    public let redactedPaths: Bool
}
```

- 独立第 17 协议（与 X0 一致）；4 方法使总数 110→118（Culling +2、Metadata +1、Face +1、Maintenance +4）。
- 装配：`CompositionCore.maintenanceService` → `FeatureAPIs.makeMaintenance` → `AppServices.maintenance` → `AppServicesRoot`；`SettingsView`/`SettingsViewModel` 注入；`PreviewAPIs` 加 `PreviewMaintenanceAPI`；测试加 `StubMaintenanceAPI`。
- 错误码新增 12 个：`BACKUP_FAILED`、`BACKUP_VERIFY_FAILED`、`BACKUP_INSUFFICIENT_SPACE`、`BACKUP_PERMISSION_DENIED`、`BACKUP_BUSY`、`RESTORE_FAILED`、`RESTORE_VERIFY_FAILED`、`RESTORE_VERSION_UNSUPPORTED`、`RESTORE_INSUFFICIENT_SPACE`、`RESTORE_PERMISSION_DENIED`、`RESTORE_BUSY`、`DIAGNOSTICS_EXPORT_FAILED`。
- 映射：服务层 `MaintenanceError` → `GatherError(code:params:)`；`LiveMaintenanceAPI` 是唯一映射点。新增码需同步 `ErrorCodeContractTests.expected`（当前 173 项 + 12）、`GatherLocalization.errorMessages`、`en.lproj`。
- 基线：`docs/protocol-surface-baseline.json` 重写 + README 16→17 + `check-protocol-surface.sh --strict`。

## 7. 边界

| 场景 | 行为 |
|---|---|
| 权限失败 | 目录探针/`FileManager` 失败 → `BACKUP_PERMISSION_DENIED`/`RESTORE_PERMISSION_DENIED`；不动已有文件 |
| 磁盘满 | 预检不足即拒；运行中 `SQLITE_FULL`/`ENOSPC` → `*_INSUFFICIENT_SPACE`，删 `.partial`/staging |
| 备份损坏 | 头/`quick_check`/形状任一失败 → `BACKUP_VERIFY_FAILED`；恢复时 `RESTORE_VERIFY_FAILED`，绝不 swap |
| 恢复中断 | journal 四态 + 原子写；启动按 §3.2 回滚/完成；staging/.partial 清理 |
| 运行中写回 | 备份是一致快照，不冻结写；恢复只发生在下次启动（无活连接） |
| 只读卷 | 备份目录只读 → 备份权限错；DB 目录只读 → 恢复权限错；只读备份源可读即可恢复 |
| 多实例 | 恢复时 `AppBootstrap` 在 apply→open→finalize 全程持 `.restore.lock`，`MaintenanceService` 再查 `isOtherInstanceRunning`；busy → `RESTORE_BUSY`；备份用唯一名 + 目录锁 |
| 退出时备份中 | `waitForBackup(15s)`；未完成则继续退出，`.partial` 下次清理 |
| 外部卷拔出 | 映射 `io` → `BACKUP_FAILED`；连续 3 次暂停自动备份 |
| 非法备份目录 | 相对路径/不可写 → `INVALID_PARAM`/`BACKUP_PERMISSION_DENIED`；不回落静默 | 
| 已有待恢复 journal | 再备份/再恢复 → `RESTORE_BUSY`；避免覆盖 journal |
| XMP 未回滚 | 恢复后禁用一次自动回放；提示重新索引/裁决（§3.5） |

## 8. 测试矩阵

| 用例 | 做法 | 期望 |
|---|---|---|
| 2GB <30s | `GATHER_BACKUP_PERF=1` 生成合法 2GB 库；分段计时 | VACUUM+verify+hash <27s |
| 损坏备份 | 截头、改字节、坏 quick_check、表数不符 | 对应 verify 码，不 swap |
| 跨版本 | V1/V2 备份 → V3 构建；V3 备份 → V2 catalog | 前者迁移成功，后者 `RESTORE_VERSION_UNSUPPORTED` |
| 权限 | `chmod 0500` 备份/DB 目录 | 权限码，旧库不动 |
| 恢复中断 | 在 prepared/oldMoved/newInstalled 注入故障后模拟重启 | 按状态表回滚/完成，旧库可开 |
| 并发 job | 备份期间跑 analysis，结束后核对 | 快照一致；job 正常完成 |
| 并发备份 | 同时两次 `backup` | 第二次 `BACKUP_BUSY`；只留一个文件 |
| 磁盘满 | 小容量 sparse image | 预检码；无残留 |
| 保留/保护 | 超过 N 份 + 有待恢复引用 | 只删最旧托管备份，保护引用 |
| 多实例 | 两进程持锁 | 第二个 `RESTORE_BUSY`；不写库 |
| 诊断包 | 路径开关、20MB 上限、ditto 失败 | 脱敏正确、超限报错、staging 清理 |
| 日志轮转 | 写 >5MB×6 | 只留 5 个，活动文件可写 |
| 契约 | `ErrorCodeContractTests`、L10n、`SettingsCatalogTests` | 全绿 |

## 9. 任务拆解（B0-1..B0-7，合计 17 PD）

| ID | 任务 | 文件 | PD | 验收 |
|---|---|---|---:|---|
| B0-1 | 备份核心：第二连接 VACUUM、只读校验、sidecar、原子改名、磁盘预检 | `GatherPersistence/Database/DB.swift`（readOnly）、`Database/Backup/{BackupVerifier,RestoreJournal}.swift`、`GatherApplication/Services/Maintenance/{MaintenanceService,BackupStore}.swift` | 2.5 | 2GB <30s；损坏备份拒绝；无残留 |
| B0-2 | 自动策略：4 个设置键/默认表、scheduler、state.json、保留/暂停 | `SettingsService.swift`、`MaintenanceService+Scheduler.swift`、`Backup/MaintenanceStateStore.swift` | 2.0 | launch/daily 触发；3 次失败暂停；保留正确 |
| B0-3 | 恢复：journal 状态机、swap/rollback、锁、AppBootstrap 接线、跨版本、恢复后禁用一次回放 | `Database/Backup/{RestoreCoordinator,RestoreLock,MaintenanceStateStore}.swift`、`AppBootstrap.swift`、`AppRuntime.swift`（start 参数） | 4.0 | 四态中断恢复；旧库保留；版本规则；XMP 不被旧 intent 覆盖 |
| B0-4 | 诊断：文件 sink、轮转、采集器、脱敏、ditto、20MB | `GatherApplication/Logging/LogFileSink.swift`、`Services/Maintenance/{DiagnosticsCollector,PathRedactor}.swift`、`AppBootstrap.swift` | 3.0 | 包可打开；默认无路径；上限生效 |
| B0-5 | API：协议/输入输出、Live、组合根、错误码、基线 | `GatherProtocol/API/MaintenanceAPI.swift`、`Inputs|Outputs/Maintenance*.swift`、`GatherHost/APIs/LiveMaintenanceAPI.swift`、`AppServices.swift`、`FeatureAPIs.swift`、`Root.swift`、`Core.swift` | 1.5 | 17 协议；strict 门禁 |
| B0-6 | UI：设置分组/数据与恢复、恢复 sheet、诊断保存、进度/错误、preview/stub | `SettingsView.swift`、`SettingsView+MaintenanceSection.swift`、`SettingsViewModel+Maintenance.swift`、`BackupRestoreSheet.swift`、`GatherApp.swift`、`PreviewAPIs/Factory` | 2.0 | 全流程可点；取消无副作用 |
| B0-7 | 测试：单测/集成/性能/手动矩阵 | `GatherCoreTests/Maintenance/*`、`GatherAppTests/SettingsMaintenanceTests.swift`、`StubMaintenanceAPI.swift` | 2.0 | §8 全过 |

## 10. 未决问题与推荐

| # | 问题 | 推荐 | 备注 |
|---|---|---|---|
| 1 | 进程内恢复还是跨进程？ | **跨进程**（P0） | `AppRuntime` 不可复活；重建 16 域图风险高 |
| 2 | 4 方法够吗（无取消待恢复/字节进度）？ | 先 4；若要取消，加第 5 个 `cancelPendingRestore` | 改 X0/README，P0 不阻塞 |
| 3 | 是否允许恢复任意外部 SQLite？ | **仅托管备份**（P0） | 防路径注入；P1 加导入校验 |
| 4 | 诊断包是否含 DB 副本？ | **不含** | 隐私 + 20MB 上限 |
| 5 | 备份扩展名 | `.sqlite` + `Gather-Backup-` 前缀 | 用户可双击检查 |
| 6 | 自动备份时机 | 启动后 60s；daily 每 6h | 避开启动竞态 |
| 7 | pre-restore 保留几份 | 2 份 | 2GB×2 磁盘成本 |
| 8 | 是否新增只读 `DBConnection` | **是** | 校验收缩到只读、不改备份 |
| 9 | 校验深度 | quick_check + shape；FK check 仅 restore 预算内 | 2GB <30s |
| 10 | 日志脱敏是否连文件名 | 去目录、留文件名 | 更严格会牺牲可诊断性 |

## 11. 与 `x0-contracts.md` 的冲突

| X0 草案 | 本设计 | 建议 |
|---|---|---|
| MaintenanceAPI 4 方法、第 17 协议 | 一致 | 无需改；补入参/出参类型 |
| `backup` 无入参 | `backup(_: MaintenanceBackupInput)` | 更新 X0 §1 |
| 错误码仅 `BACKUP_VERIFY_FAILED`/`RESTORE_VERSION_UNSUPPORTED`/`RESTORE_FAILED` | 需 12 个（含空间/权限/busy/诊断） | 更新 X0 §4 |
| 未提恢复跨进程 | 设计为跨进程 + journal | 写入 X0 §6 与 ADR-033 |
| 未提只读 `DBConnection` / 日志 sink | 实现细节，无契约冲突 | 记入 ADR-033/实现说明 |
| V3 只增 2 表 | 一致（B0 不加表） | 无需改 |
| settings 4 键 | 一致 | 无需改 |
| 110→约 118 | 一致（+2/+1/+1/+4） | 无需改 |

> `docs/design/p0/x0-contracts.md` 未修改；以上为提交给 X0 的同步清单。
