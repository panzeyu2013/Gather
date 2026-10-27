// desktop/native/gather-core/Sources/GatherPersistence/Database/Database.swift
// Database facade（docs/refactor-decisions.md D-035）。
//
// 定位：**唯一**的库入口。职责只有三件事：
//   1. 打开即保证 schema 就绪：user_version == SchemaCurrent.userVersion（3）**且**
//      列形与指纹一致（44 表 / 384 列 / 72 显式索引 / 65 外键）；
//      0 且无表 → 建当前 schema；当前版本 → 直接打开；旧版本 / 更高版本 / 版本 0 有表 /
//      形态不符 / 非 SQLite 文件 → **默认 fail closed**（只抛错，不改名、不删文件）；
//      只有 Options.resetPolicy == .renameToIncompatible（开发重置）才把 db/-wal/-shm
//      改名 .incompatible-* 后重建；
//   2. 提供 read / write / async 三个作用域，让 Service 不再自己管连接与事务边界；
//   3. 把底层 `DBError.message` 收敛成类型化 `DatabaseError`（见 DatabaseError.swift）。
//
// 生产 GatherApp 只经 `Database.open(at:)` 打开库；测试工厂执行
// `SchemaCurrent.createSQL`。
//
// ── 锁纪律（@unchecked Sendable 的依据） ──
// 本类跨并发域传递，但锁纪律无法被编译器静态验证，故显式标注 @unchecked。四层保护：
//   * `stateLock`（NSRecursiveLock，本类持有）：保护 `closed`，并让 read/write/checkpoint/
//     async body 与 `close()` 互斥——close 会等正在执行的 body 结束，body 开始后不会再
//     撞上「句柄已释放」。可重入：write 里调 read、事务内再调 write 都不会自锁。
//   * `DBConnection.connectionLock`（DB.swift 持有，NSRecursiveLock）：每条 SQL、每个
//     BEGIN/COMMIT/SAVEPOINT 都在它下面执行。facade 从不直接碰 sqlite handle，全部经由
//     DBConnection 的公开 API，因此**不新增**第二条锁序（stateLock → connectionLock 单向）。
//   * `asyncQueue`（串行 DispatchQueue）：只保证 async 调用之间 FIFO；read/write 与 async
//     之间在 connectionLock 上串行，但不保证 FIFO（async body 也会取 stateLock）。
//   * `DBConnection.readPoolState`（DB.swift 持有，OSAllocatedUnfairLock）：只保护只读池的
//     懒建/关闭；ensureReadPool 不取写连接锁，因此不参与上述锁序；池内借还另用
//     ReadConnectionPool.lock。
//
// ── 读池（R6，D-035 #2 的落地） ──
// prepare 遇到「无事务的 SELECT」时从只读池借连接（默认 2 条；":memory:" 不建池；
// 池空回退写连接）。由此：
//   * 长写事务只阻塞写语句与非 SELECT 读，普通 SELECT 读最近提交快照、不再排队；
//   * 事务内/写语句/PRAGMA/WITH 仍走写连接，事务内读己写语义不变；
//   * read 作用域里的无事务 SELECT 可能落到另一条连接——不要把 read 当隔离边界，
//     也不要在 read 内依赖「随后 write 同连接」的隐式假设。
//
// ── 事务 ──
// write 复用 `DBConnection.transaction`：嵌套调用退化为 SAVEPOINT（`gather_tx_<depth>`），
// 内层失败只回滚到自己的 savepoint，外层可继续或整体回滚（与既有 Repo 语义一致）。
// schema 建库在 `connection.transaction` 内执行 DDL + user_version。
//
// ── 错误 ──
// read/write/async 只把 `DBError` 映射为 `DatabaseError`；body 抛出的其它错误原样上抛，
// 避免把领域错误吞成 `.sql`。close 之后的调用稳定抛 `.closed`（不静默成功）。
import Foundation
import GatherProtocol

/// 本地库门面（单写连接 + 作用域 API）。
public final class Database: @unchecked Sendable {

    /// 内存库路径（SQLite 约定）。生产路径禁止使用（draft §6.3）。
    public static let inMemoryPath = ":memory:"

    // MARK: - Options

    /// 连接级 PRAGMA 的 `synchronous` 取值（白名单，避免拼接任意字符串）。
    public enum SynchronousMode: String, Sendable, CaseIterable {
        case off, normal, full, extra
    }

    /// 库不兼容时的处理策略（设计 §4.5）。
    public enum ResetPolicy: Sendable, Equatable {
        /// 默认：只抛错，绝不改名/删除用户库（fail closed）。
        case failClosed
        /// 仅开发/测试显式开启：改名 .incompatible-* 后重建（沿用旧行为）。
        case renameToIncompatible

        var allowsReset: Bool { self == .renameToIncompatible }
    }

    /// open 选项。默认值与 D-035 / draft §6.4 一致（busy_timeout 5s、synchronous normal、64MB）。
    public struct Options: Sendable {
        /// `PRAGMA busy_timeout`（毫秒）。WAL 单写者下让短暂锁竞争排队而不是立刻 SQLITE_BUSY。
        public var busyTimeoutMilliseconds: Int
        /// `PRAGMA synchronous`。用户设置 `db_synchronous` 后续可由 Service 覆盖。
        public var synchronous: SynchronousMode
        /// `PRAGMA cache_size`（MB，钳制在 1...1024，与 DB.swift 的 settings 路径一致）。
        public var cacheSizeMB: Int
        /// 不兼容副本保留份数（按时间戳从旧到新淘汰；默认 3，与迁移备份同策略）。
        public var retainIncompatibleCopies: Int
        /// 不兼容库处理策略：默认 fail closed；开发重置显式传 .renameToIncompatible。
        public var resetPolicy: ResetPolicy
        /// R6：只读连接池大小（0 = 关闭；":memory:" 永远不建池）。
        public var readPoolSize: Int

        public init(
            busyTimeoutMilliseconds: Int = 5000,
            synchronous: SynchronousMode = .normal,
            cacheSizeMB: Int = 64,
            retainIncompatibleCopies: Int = 3,
            resetPolicy: ResetPolicy = .failClosed,
            readPoolSize: Int = 2
        ) {
            self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
            self.synchronous = synchronous
            self.cacheSizeMB = cacheSizeMB
            self.retainIncompatibleCopies = retainIncompatibleCopies
            self.resetPolicy = resetPolicy
            self.readPoolSize = max(0, readPoolSize)
        }

        public static let `default` = Options()
    }

    /// `checkpoint` 的 WAL 模式。
    public enum CheckpointMode: String, Sendable {
        case passive, full, restart, truncate
    }

    // MARK: - 状态

    /// 库路径（`:memory:` 表示内存库）。
    public let path: String
    public var isInMemory: Bool { path == Self.inMemoryPath }

    /// 底层单写连接（组合根据此构造 Repo/Service；调用方不得自行 close）。
    ///
    /// 暴露连接是过渡方案：Service 层仍以 DBConnection 为注入形状，
    /// 由 `Database` 统一承担 open/close/schema 不变量。
    public let connection: DBConnection
    /// 本次 open 的结果（创建/打开/迁移/开发重置）。
    public let outcome: OpenOutcome
    private let options: Options

    /// facade 级状态锁（见文件头「锁纪律」）：保护 `closed` + 串行化公开作用域与 close。
    private let stateLock = NSRecursiveLock()
    private var closed = false

    /// async 串行执行器（仅 async 之间 FIFO）。
    private let asyncQueue: DispatchQueue

    private init(
        path: String,
        connection: DBConnection,
        options: Options,
        outcome: OpenOutcome
    ) {
        self.path = path
        self.connection = connection
        self.options = options
        self.outcome = outcome
        self.asyncQueue = DispatchQueue(
            label: "com.gather.database.async.\(UUID().uuidString)",
            qos: .utility
        )
    }

    deinit {
        // 调用方漏 close 时兜底释放 sqlite 句柄（DBConnection.close 幂等）。
        connection.close()
    }

    // MARK: - open

    /// 打开（或新建）当前 schema 版本的库。
    ///
    /// 状态机（默认 resetPolicy = .failClosed）：
    ///   * current  → 校验版本 + 列形 + FK 自检后返回（.opened）；
    ///   * empty    → 单事务建当前 DDL（.created）；
    ///   * older    → 默认 fail closed（v3 起无迁移链；仅显式 resetPolicy 才归档重建）
    ///                + 形态校验（.migrated；失败回滚，库仍为旧版本，备份保留）；
    ///   * newer    → 抛 .versionUnsupported，文件不改（开发重置才改名）；
    ///   * corrupt  → 抛 .corrupt（非 SQLite / V0 有表 / 形态不符）；开发重置才改名；
    ///   * unreadableVersion → 抛 .corrupt；开发重置才改名。
    ///
    /// 开发重置是**显式选项**不是错误路径：日志 warn 一条 schema_reset_dev；
    /// 移动文件失败则显式抛 .io（绝不吞错，提示用户手动备份后重试）。
    /// 最多重置一次，二次不兼容直接抛错（防止无限循环）。
    public static func open(at path: String, options: Options = .default) throws -> Database {
        guard path != inMemoryPath else { return try openInMemory(options: options) }
        try ensureParentDirectory(for: path)

        var didReset = false
        var resetOutcome: OpenOutcome?
        while true {
            let connection: DBConnection
            do {
                connection = try makeConnection(at: path, options: options)
            } catch {
                let mapped = DatabaseError.map(error)
                guard mapped.indicatesNotDatabaseFile, !didReset, options.resetPolicy.allowsReset else {
                    throw mapped.indicatesNotDatabaseFile
                        ? DatabaseError.corrupt("不是 SQLite 文件：\(path)")
                        : mapped
                }
                let backup = try SchemaReset.reset(
                    at: path,
                    options: options,
                    reason: .notADatabase,
                    previousVersion: nil
                )
                resetOutcome = .reset(reason: .notADatabase, previousVersion: nil, backup: backup)
                didReset = true
                continue
            }

            do {
                switch try SchemaInspector.inspect(connection, path: path) {
                case .current:
                    try assertReady(connection, path: path)
                    return Database(
                        path: path,
                        connection: connection,
                        options: options,
                        outcome: resetOutcome ?? .opened(SchemaCurrent.userVersion)
                    )

                case .empty:
                    try createSchema(connection)
                    try assertReady(connection, path: path)
                    return Database(
                        path: path,
                        connection: connection,
                        options: options,
                        outcome: resetOutcome ?? .created(SchemaCurrent.userVersion)
                    )

                case .incompatible(let reason):
                    connection.close()
                    guard options.resetPolicy.allowsReset, !didReset else {
                        throw incompatibleError(reason, path: path)
                    }
                    let backup = try SchemaReset.reset(
                        at: path,
                        options: options,
                        reason: reason.resetReason,
                        previousVersion: reason.version
                    )
                    resetOutcome = .reset(
                        reason: reason.resetReason,
                        previousVersion: reason.version,
                        backup: backup
                    )
                    didReset = true
                    continue
                }
            } catch {
                connection.close()
                if let error = error as? DatabaseError { throw error }
                throw DatabaseError.map(error)
            }
        }
    }

    /// 内存库（测试/基准专用；D-003 的 `makeTestDatabase` 后续切到这里）。
    public static func openInMemory(options: Options = .default) throws -> Database {
        let connection: DBConnection
        do {
            connection = try makeConnection(at: inMemoryPath, options: options)
        } catch {
            throw DatabaseError.map(error)
        }
        do {
            try createSchema(connection)
            try assertReady(connection, path: inMemoryPath)
            return Database(
                path: inMemoryPath,
                connection: connection,
                options: options,
                outcome: .created(SchemaCurrent.userVersion)
            )
        } catch {
            connection.close()
            throw DatabaseError.map(error)
        }
    }

    // MARK: - 作用域

    /// 读作用域（无事务 SELECT 走只读池，见文件头「读池」）。
    public func read<T>(_ body: (DBConnection) throws -> T) throws -> T {
        try withOpenConnection(body)
    }

    /// 写作用域：单事务，嵌套调用退化为 SAVEPOINT。
    public func write<T>(_ body: (DBConnection) throws -> T) throws -> T {
        try withOpenConnection { connection in
            try connection.transaction { try body(connection) }
        }
    }

    /// 串行执行器：body 在专用串行队列上执行（async 调用之间 FIFO），
    /// 便于 Service 把同步 DB 工作从并发域里挪出去而不自己建队列。
    public func async<T: Sendable>(_ body: @escaping @Sendable (DBConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            asyncQueue.async { [self] in
                do {
                    continuation.resume(returning: try withOpenConnection(body))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// WAL checkpoint（批量分析/导出结束后调用；默认 TRUNCATE）。
    ///
    /// 返回 false 表示有读者/写者让 checkpoint 未完全完成（busy），不是错误。
    @discardableResult
    public func checkpoint(_ mode: CheckpointMode = .truncate) throws -> Bool {
        try read { connection in
            let row = try connection.prepare("PRAGMA wal_checkpoint(\(mode.rawValue));").get([])
            return (row?[0].intValue ?? 0) == 0
        }
    }

    /// 幂等关闭：标记 `.closed` 并释放连接；之后 read/write/async/checkpoint 稳定抛 `.closed`。
    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true
        connection.close()
    }

    /// facade 是否已关闭（含底层连接被外部关闭的情况）。
    public var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed || connection.isClosed
    }

    // MARK: - 内部：作用域与错误映射

    /// 公开作用域的统一入口：关闭检查 + 错误映射。持 stateLock 直到 body 结束，
    /// 保证 close() 不会在 body 执行中途释放句柄（嵌套调用靠 NSRecursiveLock 重入）。
    private func withOpenConnection<T>(_ body: (DBConnection) throws -> T) throws -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else {
            throw DatabaseError.closed("数据库已关闭：\(path)")
        }
        do {
            return try body(connection)
        } catch let error as DBError {
            throw DatabaseError(dbError: error)
        }
    }

    // MARK: - 内部：打开流程

    private static func makeConnection(at path: String, options: Options) throws -> DBConnection {
        let connection: DBConnection
        do {
            // DBConnection.open 已设置 journal_mode=WAL / foreign_keys=ON / busy_timeout。
            // R6：文件库附带只读池，池读连接继承同一份 busy/cache 预算（避免读路径行为分叉）。
            connection = try DBConnection(
                path: path,
                readPoolSize: path == Self.inMemoryPath ? 0 : options.readPoolSize,
                busyTimeoutMilliseconds: options.busyTimeoutMilliseconds,
                cacheSizeMB: options.cacheSizeMB
            )
        } catch {
            throw DatabaseError.map(error)
        }
        do {
            try apply(options: options, to: connection)
            return connection
        } catch {
            connection.close()
            throw DatabaseError.map(error)
        }
    }

    /// 覆盖连接级 PRAGMA（必须在事务外执行；foreign_keys 在事务内设置会被静默忽略）。
    private static func apply(options: Options, to connection: DBConnection) throws {
        try connection.exec("PRAGMA foreign_keys = ON;")
        try connection.exec("PRAGMA busy_timeout = \(max(0, options.busyTimeoutMilliseconds));")
        try connection.exec("PRAGMA synchronous = \(options.synchronous.rawValue);")
        let cacheMB = max(1, min(1024, options.cacheSizeMB))
        try connection.exec("PRAGMA cache_size = -\(cacheMB * 1024);")
        try connection.exec("PRAGMA temp_store = MEMORY;")
    }

    /// 建当前 schema：DDL 与 `PRAGMA user_version` 在同一事务内提交，
    /// 杜绝「表建好但版本还是 0」的半成品（下次启动会被当成不兼容库）。
    ///
    /// 注意 DDL 里的 `PRAGMA foreign_keys = ON` 在事务内是 no-op（SQLite 语义）；
    /// 连接级开关已由 DBConnection.open 在事务前打开，事务后还会再自检一次。
    private static func createSchema(_ connection: DBConnection) throws {
        do {
            _ = try connection.transaction {
                try connection.exec(SchemaCurrent.createSQL)
            }
            guard let version = try SchemaInspector.readUserVersion(connection) else {
                throw DatabaseError.schema("建库后读不到 user_version")
            }
            guard version == SchemaCurrent.userVersion else {
                throw DatabaseError.schema(
                    "建库后 user_version=\(version)，期望 \(SchemaCurrent.userVersion)"
                )
            }
        } catch let error as DBError {
            throw DatabaseError(dbError: error)
        }
    }

    /// 打开后的不变量自检（失败即抛，不降级）：版本、列形、foreign_keys、外键一致性。
    ///
    /// 列形校验是「同版本旧库」的最后一道门：user_version 只证明曾经按该版本建过库，
    /// 不能证明它有当前的全部列（Cut 5 加列未 bump）。文件库在 inspect 中已检查并
    /// 按 resetPolicy 处理；这里对新建库/迁移后的库再断言一次，防止 DDL 与快照漂移。
    private static func assertReady(_ connection: DBConnection, path: String) throws {
        do {
            guard let version = try SchemaInspector.readUserVersion(connection) else {
                throw DatabaseError.schema("读取 PRAGMA user_version 无结果：\(path)")
            }
            guard version == SchemaCurrent.userVersion else {
                throw DatabaseError.schema(
                    "schema 版本不是 \(SchemaCurrent.userVersion)（实际 \(version)）：\(path)"
                )
            }
            let issues = SchemaCurrent.shape.issues(against: try SchemaShapeReader.read(connection))
            guard issues.isEmpty else {
                throw DatabaseError.schema(
                    "\(SchemaCurrent.userVersion) 列形不符：\(issues.joined(separator: "；"))"
                )
            }
            guard let row = try connection.prepare("PRAGMA foreign_keys;").get([]),
                  row[0].intValue == 1
            else {
                throw DatabaseError.schema("连接未启用 foreign_keys（连接级 PRAGMA 必须在事务外设置）")
            }
            let violations = try connection.prepare("PRAGMA foreign_key_check;").query([])
            guard violations.isEmpty else {
                throw DatabaseError.schema("foreign_key_check 发现 \(violations.count) 条违规")
            }
        } catch let error as DBError {
            throw DatabaseError(dbError: error)
        }
    }

    private static func incompatibleError(_ reason: CorruptReason, path: String) -> DatabaseError {
        switch reason {
        case .newerVersion:
            return .versionUnsupported(reason.description + "：\(path)")
        case .notADatabase, .legacyPreV1, .oldVersion, .shapeMismatch, .unreadableVersion:
            return .corrupt("库不可用（\(reason)）：\(path)")
        }
    }

    private static func ensureParentDirectory(for path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard !directory.path.isEmpty else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DatabaseError.io(
                "无法创建数据库目录 \(directory.path)：\(error.localizedDescription)"
            )
        }
    }
}
