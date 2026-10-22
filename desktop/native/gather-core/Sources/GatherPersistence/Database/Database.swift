// desktop/native/gather-core/Sources/GatherPersistence/Database/Database.swift
// Cut 2 / B-1：Database facade（docs/refactor-decisions.md D-035）。
//
// 定位：V1 之后**唯一**的库入口。职责只有三件事：
//   1. 打开即保证 schema 就绪：user_version == SchemaV1.userVersion（1）**且**列形
//      与当前 SchemaV1 一致（43 表 / 373 列 / 69 显式索引 / 62 外键 + 指纹）；
//      0（且无表）→ 建 SchemaV1；0 但有表 / 非 1 / 同版本但列形不符 / 非 SQLite
//      文件 → 整体重置（draft §6）；
//   2. 提供 read / write / async 三个作用域，让 Service 不再自己管连接与事务边界；
//   3. 把底层 `DBError.message` 收敛成类型化 `DatabaseError`（见 DatabaseError.swift）。
//
// 接线（Cut 2 / S5c-2b-3b-2b-3）：生产 GatherApp 只经 `Database.open(at:)` 打开库，
// 组合根用 `connection` 构造 Repo/Service（连接与建库只有 `Database.open(at:)` 单一入口）；
// 测试工厂只执行 `SchemaV1.sql`。
//
// ── 锁纪律（@unchecked Sendable 的依据） ──
// 本类跨并发域传递，但锁纪律无法被编译器静态验证，故显式标注 @unchecked。三层保护：
//   * `stateLock`（NSRecursiveLock，本类持有）：保护 `closed`，并让 read/write/checkpoint/
//     async body 与 `close()` 互斥——close 会等正在执行的 body 结束，body 开始后不会再
//     撞上「句柄已释放」。可重入：write 里调 read、事务内再调 write 都不会自锁。
//   * `DBConnection.connectionLock`（DB.swift 持有，NSRecursiveLock）：每条 SQL、每个
//     BEGIN/COMMIT/SAVEPOINT 都在它下面执行。facade 从不直接碰 sqlite handle，全部经由
//     DBConnection 的公开 API，因此**不新增**第二条锁序（stateLock → connectionLock 单向）。
//   * `asyncQueue`（串行 DispatchQueue）：只保证 async 调用之间 FIFO；read/write 与 async
//     之间在 connectionLock 上串行，但不保证 FIFO（async body 也会取 stateLock）。
//
// ── 读池延后（D-035 #2） ──
// B-1 的 read 与 write **共用同一个连接**：底层 DBConnection 已经是「单连接 + 递归锁」
// 语义（对齐 better-sqlite3），读池需要额外只读连接 + query_only + WAL 可见性管理，
// 留到 S5 之后单独做。因此：长 read 会阻塞写、write 事务内的 read 不是快照隔离
// （读到事务内未提交的数据），调用方不得把 read 当作隔离边界。
//
// ── 事务 ──
// write 复用 `DBConnection.transaction`：嵌套调用退化为 SAVEPOINT（`gather_tx_<depth>`），
// 内层失败只回滚到自己的 savepoint，外层可继续或整体回滚（与既有 Repo 语义一致）。
//
// ── 错误 ──
// read/write/async 只把 `DBError` 映射为 `DatabaseError`；body 抛出的其它错误原样上抛，
// 避免把领域错误吞成 `.sql`。close 之后的调用稳定抛 `.closed`（不静默成功）。
import Foundation
import GatherProtocol

/// V1 库门面（单写连接 + 作用域 API）。
public final class Database: @unchecked Sendable {

    /// 内存库路径（SQLite 约定）。生产路径禁止使用（draft §6.3）。
    public static let inMemoryPath = ":memory:"

    // MARK: - Options

    /// 连接级 PRAGMA 的 `synchronous` 取值（白名单，避免拼接任意字符串）。
    public enum SynchronousMode: String, Sendable, CaseIterable {
        case off, normal, full, extra
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

        public init(
            busyTimeoutMilliseconds: Int = 5000,
            synchronous: SynchronousMode = .normal,
            cacheSizeMB: Int = 64,
            retainIncompatibleCopies: Int = 3
        ) {
            self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
            self.synchronous = synchronous
            self.cacheSizeMB = cacheSizeMB
            self.retainIncompatibleCopies = retainIncompatibleCopies
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
    private let options: Options

    /// facade 级状态锁（见文件头「锁纪律」）：保护 `closed` + 串行化公开作用域与 close。
    private let stateLock = NSRecursiveLock()
    private var closed = false

    /// async 串行执行器（仅 async 之间 FIFO）。
    private let asyncQueue: DispatchQueue

    private init(path: String, connection: DBConnection, options: Options) {
        self.path = path
        self.connection = connection
        self.options = options
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

    /// 打开（或新建）V1 库。
    ///
    /// - `:memory:`：单连接内存库，直接建 SchemaV1（多连接会得到多份互不相干的数据）。
    /// - 文件：打开后读 `PRAGMA user_version`：
    ///   * 1 → 保留现有库（只做连接 PRAGMA + 自检）；
    ///   * 0 且无用户表 → 在同一事务内执行 SchemaV1.sql（含 `PRAGMA user_version = 1`）；
    ///   * 0 但有表 / 非 1 / 非 SQLite 文件 → 关闭连接，把 db/-wal/-shm 改名为
    ///     `<db>.incompatible-<yyyyMMdd-HHmmss>[-wal|-shm]`，新建空库后建 SchemaV1
    ///     （最多重置一次，防止无限递归）。
    ///
    /// 重置是**预期路径**不是错误（draft §6.1）：日志 warn 一条 `schema_reset`；
    /// 移动文件失败则显式抛 `.io`（绝不吞错，提示用户手动备份后重试）。
    public static func open(at path: String, options: Options = .default) throws -> Database {
        guard path != inMemoryPath else { return try openInMemory(options: options) }
        try ensureParentDirectory(for: path)

        var didReset = false
        while true {
            let connection: DBConnection
            do {
                connection = try makeConnection(at: path, options: options)
            } catch {
                let mapped = DatabaseError.map(error)
                // 「非 SQLite 文件」在 DBConnection.open 的 PRAGMA 阶段就会失败（还没机会读
                // user_version），按 draft §6.1 default 分支同样走重置；其余打开失败如实上抛。
                guard !didReset, mapped.indicatesNotDatabaseFile else { throw mapped }
                try resetIncompatibleFiles(at: path, options: options, detectedVersion: nil)
                didReset = true
                continue
            }

            do {
                switch try inspectSchema(connection, path: path) {
                case .current:
                    try assertReady(connection)
                    return Database(path: path, connection: connection, options: options)

                case .empty:
                    try createSchema(connection)
                    try assertReady(connection)
                    return Database(path: path, connection: connection, options: options)

                case .incompatible(let version):
                    connection.close()
                    guard !didReset else {
                        let detected = version.map(String.init) ?? "unreadable"
                        throw DatabaseError.schema(
                            "重置后仍不兼容：\(path)（user_version=\(detected)，期望 \(SchemaV1.userVersion)）"
                        )
                    }
                    try resetIncompatibleFiles(at: path, options: options, detectedVersion: version)
                    didReset = true
                    continue
                }
            } catch {
                connection.close()
                throw error
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
            if try readUserVersion(connection) == 0 {
                try createSchema(connection)
            }
            try assertReady(connection)
            return Database(path: inMemoryPath, connection: connection, options: options)
        } catch {
            connection.close()
            throw DatabaseError.map(error)
        }
    }

    // MARK: - 作用域

    /// 读作用域（当前与 write 共用同一连接，见文件头「读池延后」）。
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

    private enum SchemaState {
        /// user_version == SchemaV1.userVersion 且列形/指纹与当前 SchemaV1 一致。
        case current
        /// user_version == 0 且没有任何用户表。
        case empty
        /// 0 但有表 / 非 1 / 读不出 user_version（version == nil）。
        case incompatible(version: Int?)
    }

    private static func makeConnection(at path: String, options: Options) throws -> DBConnection {
        let connection: DBConnection
        do {
            // DBConnection.open 已设置 journal_mode=WAL / foreign_keys=ON / busy_timeout=5000。
            connection = try DBConnection(path: path)
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

    private static func inspectSchema(_ connection: DBConnection, path: String) throws -> SchemaState {
        do {
            let version = try readUserVersion(connection)
            switch version {
            case SchemaV1.userVersion:
                // user_version 相同不等于列形相同：Cut 5 在未 bump 版本时加过 3 列。
                // 列形不符按「版本 1 但不兼容」走既有重置，避免运行期 no such column。
                if let issue = try schemaShapeIssue(connection) {
                    GatherLogger.log(
                        "schema_shape_mismatch path=\(path) user_version=\(version) issue=\(issue)",
                        level: .warn
                    )
                    return .incompatible(version: version)
                }
                return .current
            case 0:
                // 0 但没有表 = 全新空库；0 且有表 = V1 之前的旧库（44 表迁移链），一律重置。
                return try userTableCount(connection) == 0 ? .empty : .incompatible(version: 0)
            default:
                return .incompatible(version: version)
            }
        } catch let error as DBError {
            let mapped = DatabaseError(dbError: error)
            if mapped.indicatesNotDatabaseFile { return .incompatible(version: nil) }
            // busy / io 等「暂时性」失败绝不能触发重置：那会挪走仍然有效的用户库。
            throw mapped
        }
    }

    private static func readUserVersion(_ connection: DBConnection) throws -> Int {
        guard let row = try connection.prepare("PRAGMA user_version;").get([]),
              let raw = row[0].intValue
        else {
            throw DatabaseError.schema("读取 PRAGMA user_version 无结果")
        }
        return Int(raw)
    }

    private static func userTableCount(_ connection: DBConnection) throws -> Int {
        guard let row = try connection.prepare("""
            SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """).get([]),
              let raw = row[0].intValue
        else {
            throw DatabaseError.schema("读取 sqlite_master 表数无结果")
        }
        return Int(raw)
    }

    // MARK: - 内部：列形校验（user_version=1 的「同版本旧库」识别）

    /// 当前库的规范化列形（open 自检与旧库识别共用）。
    private struct SchemaShape {
        let tableCount: Int
        let columnCount: Int
        let explicitIndexCount: Int
        let foreignKeyCount: Int
        let columnsByTable: [String: Set<String>]
        let fingerprint: String
    }

    /// 读取完整列形并计算规范化指纹。
    ///
    /// canonical 口径（与 SchemaV1.expectedShapeFingerprint 同源；改任何一段都必须重算期望值）：
    ///   table\t<name>
    ///   column\t<name>\t<type>\t<notnull>\t<dflt>\t<pk>
    ///   fk\t<ref table>\t<seq>\t<from>\t<to>\t<on_update>\t<on_delete>\t<match>
    ///   index\t<name>\t<sql>
    /// 表按名字、列按 cid、外键按 (id,seq)、显式索引按名字排序；排除 sqlite_* 内部表
    /// 与 sql 为 NULL 的自动索引。
    private static func readSchemaShape(_ connection: DBConnection) throws -> SchemaShape {
        let tableNames = try connection.prepare("""
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name
            """).query([]).compactMap { $0[0].textValue }

        var canonical = ""
        var columnsByTable: [String: Set<String>] = [:]
        var columnCount = 0
        var foreignKeyCount = 0

        for table in tableNames {
            canonical += "table\t\(table)\n"
            let quotedTable = quoteIdentifier(table)

            let columnRows = try connection
                .prepare("PRAGMA table_info(\(quotedTable));")
                .query([])
                .map { row -> (cid: Int, name: String, type: String, notNull: Int, defaultValue: String, pk: Int) in
                    (
                        cid: Int(row[0].intValue ?? 0),
                        name: row[1].textValue ?? "",
                        type: row[2].textValue ?? "",
                        notNull: Int(row[3].intValue ?? 0),
                        defaultValue: shapeText(row[4]),
                        pk: Int(row[5].intValue ?? 0)
                    )
                }
                .sorted { $0.cid < $1.cid }
            for column in columnRows {
                columnCount += 1
                columnsByTable[table, default: []].insert(column.name)
                canonical += "column\t\(column.name)\t\(column.type)\t\(column.notNull)"
                    + "\t\(column.defaultValue)\t\(column.pk)\n"
            }

            let foreignKeyRows = try connection
                .prepare("PRAGMA foreign_key_list(\(quotedTable));")
                .query([])
                .map { row -> (id: Int, seq: Int, table: String, from: String, to: String, onUpdate: String, onDelete: String, match: String) in
                    (
                        id: Int(row[0].intValue ?? 0),
                        seq: Int(row[1].intValue ?? 0),
                        table: row[2].textValue ?? "",
                        from: row[3].textValue ?? "",
                        to: row[4].textValue ?? "",
                        onUpdate: row[5].textValue ?? "",
                        onDelete: row[6].textValue ?? "",
                        match: row[7].textValue ?? ""
                    )
                }
                .sorted { ($0.id, $0.seq) < ($1.id, $1.seq) }
            foreignKeyCount += foreignKeyRows.count
            for foreignKey in foreignKeyRows {
                canonical += "fk\t\(foreignKey.table)\t\(foreignKey.seq)\t\(foreignKey.from)"
                    + "\t\(foreignKey.to)\t\(foreignKey.onUpdate)\t\(foreignKey.onDelete)"
                    + "\t\(foreignKey.match)\n"
            }
        }

        let indexRows = try connection.prepare("""
            SELECT name, sql FROM sqlite_master
             WHERE type = 'index' AND sql IS NOT NULL
             ORDER BY name
            """).query([])
        for row in indexRows {
            canonical += "index\t\(row[0].textValue ?? "")\t\(row[1].textValue ?? "")\n"
        }

        let fingerprint = SHA256.hash(Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return SchemaShape(
            tableCount: tableNames.count,
            columnCount: columnCount,
            explicitIndexCount: indexRows.count,
            foreignKeyCount: foreignKeyCount,
            columnsByTable: columnsByTable,
            fingerprint: fingerprint
        )
    }

    /// 返回列形不符的原因（nil = 与当前 SchemaV1 完全一致）。
    ///
    /// 计数用于可读报错；关键表列集合兜「少关键列」；指纹兜「列名/类型/默认值/外键/
    /// 索引变了但计数没变」。三者任一不符都意味着旧库或损坏库。
    private static func schemaShapeIssue(_ connection: DBConnection) throws -> String? {
        let shape = try readSchemaShape(connection)
        var issues: [String] = []

        if shape.tableCount != SchemaV1.expectedTableCount {
            issues.append("表数 \(shape.tableCount)，期望 \(SchemaV1.expectedTableCount)")
        }
        if shape.columnCount != SchemaV1.expectedColumnCount {
            issues.append("列数 \(shape.columnCount)，期望 \(SchemaV1.expectedColumnCount)")
        }
        if shape.explicitIndexCount != SchemaV1.expectedExplicitIndexCount {
            issues.append("显式索引 \(shape.explicitIndexCount)，期望 \(SchemaV1.expectedExplicitIndexCount)")
        }
        if shape.foreignKeyCount != SchemaV1.expectedForeignKeyCount {
            issues.append("外键 \(shape.foreignKeyCount)，期望 \(SchemaV1.expectedForeignKeyCount)")
        }
        for table in SchemaV1.requiredTableColumns.keys.sorted() {
            guard let actual = shape.columnsByTable[table] else {
                issues.append("缺表 \(table)")
                continue
            }
            let required = SchemaV1.requiredTableColumns[table] ?? []
            let missing = required.subtracting(actual).sorted()
            if !missing.isEmpty {
                issues.append("表 \(table) 缺列 [\(missing.joined(separator: ","))]")
            }
        }
        if shape.fingerprint != SchemaV1.expectedShapeFingerprint {
            issues.append(
                "列形指纹 \(shape.fingerprint)，期望 \(SchemaV1.expectedShapeFingerprint)"
            )
        }
        return issues.isEmpty ? nil : issues.joined(separator: "；")
    }

    private static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 把 PRAGMA 返回值规范化为稳定文本（NULL 与各存储类都显式区分）。
    private static func shapeText(_ value: DBValue?) -> String {
        switch value {
        case .none, .null:
            return "<null>"
        case .int(let value):
            return String(value)
        case .real(let value):
            return String(value)
        case .text(let value):
            return value
        case .blob(let data):
            return "blob:\(data.count)"
        }
    }

    /// 建 SchemaV1：DDL 与 `PRAGMA user_version = 1` 在同一事务内提交，
    /// 杜绝「表建好但版本还是 0」的半成品（下次启动会被当成不兼容库重置）。
    ///
    /// 注意 SchemaV1.sql 里的 `PRAGMA foreign_keys = ON` 在事务内是 no-op（SQLite 语义）；
    /// 连接级开关已由 DBConnection.open 在事务前打开，事务后还会再自检一次。
    private static func createSchema(_ connection: DBConnection) throws {
        do {
            _ = try connection.transaction {
                try connection.exec(SchemaV1.sql)
            }
            let version = try readUserVersion(connection)
            guard version == SchemaV1.userVersion else {
                throw DatabaseError.schema("建库后 user_version=\(version)，期望 \(SchemaV1.userVersion)")
            }
        } catch let error as DBError {
            throw DatabaseError(dbError: error)
        }
    }

    /// 打开后的不变量自检（失败即抛，不降级）：版本、列形、foreign_keys、外键一致性。
    ///
    /// 列形校验是「同版本旧库」的最后一道门：user_version=1 只证明曾经按 V1 建过库，
    /// 不能证明它有当前的全部 373 列（Cut 5 加列未 bump）。文件库在 inspectSchema 中
    /// 已检查并走重置；这里对新建库/内存库再断言一次，防止 DDL 与 expected* 漂移。
    private static func assertReady(_ connection: DBConnection) throws {
        do {
            let version = try readUserVersion(connection)
            guard version == SchemaV1.userVersion else {
                throw DatabaseError.schema("schema 版本不是 \(SchemaV1.userVersion)（实际 \(version)）")
            }
            if let issue = try schemaShapeIssue(connection) {
                throw DatabaseError.schema("SchemaV1 列形不符：\(issue)")
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

    // MARK: - 内部：旧库重置（draft §6.2）

    /// 把 db/-wal/-shm 一起移到 `<db>.incompatible-<ts>`。
    ///
    /// 顺序：`-shm` → `-wal` → 主库。
    ///   * 先移 sidecar：避免「新库 + 旧 WAL」被 SQLite 按同名前缀恢复出旧页
    ///     （这是 draft §6.2 专门警告的错位场景）。
    ///   * 最后移主库：中途失败时用户数据仍在原路径，可人工恢复。
    /// 任一移动失败都抛 `.io`（不吞），并提示手动备份后重试。
    private static func resetIncompatibleFiles(
        at path: String,
        options: Options,
        detectedVersion: Int?
    ) throws {
        let fileManager = FileManager.default
        let target = uniqueIncompatiblePath(for: path)

        for suffix in ["-shm", "-wal"] where fileManager.fileExists(atPath: path + suffix) {
            do {
                try fileManager.moveItem(atPath: path + suffix, toPath: target + suffix)
            } catch {
                throw DatabaseError.io(
                    "移走 \(path + suffix) 失败：\(error.localizedDescription)。请手动备份 \(path) 后重试"
                )
            }
        }
        if fileManager.fileExists(atPath: path) {
            do {
                try fileManager.moveItem(atPath: path, toPath: target)
            } catch {
                throw DatabaseError.io(
                    "移走 \(path) 失败：\(error.localizedDescription)。请手动备份 \(path) 后重试"
                )
            }
        }

        pruneIncompatibleCopies(for: path, retaining: options.retainIncompatibleCopies)
        let detected = detectedVersion.map(String.init) ?? "unreadable"
        GatherLogger.log(
            "schema_reset user_version=\(detected) expected=\(SchemaV1.userVersion) path=\(path) backup=\(target)",
            level: .warn
        )
    }

    /// `<db>.incompatible-<yyyyMMdd-HHmmss>`；同秒重复时追加 `-2`、`-3`…（不覆盖旧副本）。
    private static func uniqueIncompatiblePath(for path: String) -> String {
        let base = path + ".incompatible-" + incompatibleTimestamp()
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = base + "-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func incompatibleTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 最多保留 `limit` 套（主库 + 同套 -wal/-shm），按时间戳从旧到新淘汰；失败不致命。
    private static func pruneIncompatibleCopies(for path: String, retaining limit: Int) {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let baseName = URL(fileURLWithPath: path).lastPathComponent
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }

        let prefix = baseName + ".incompatible-"
        var keys = Set<String>()
        for name in names where name.hasPrefix(prefix) {
            var key = String(name.dropFirst(prefix.count))
            for suffix in ["-wal", "-shm"] where key.hasSuffix(suffix) {
                key = String(key.dropLast(suffix.count))
            }
            keys.insert(key)
        }
        let keep = max(0, limit)
        guard keys.count > keep else { return }
        for key in keys.sorted().dropLast(keep) {
            for name in [prefix + key, prefix + key + "-wal", prefix + key + "-shm"] {
                try? fileManager.removeItem(atPath: directory.appendingPathComponent(name).path)
            }
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