// Store/SQLiteDatabase.swift
// R1 新持久化层的唯一连接/事务/语句入口。
//
// 设计要点（对应审计 P1）：
// - actor 串行化全部 SQL（替代旧 DBConnection 的 NSRecursiveLock + @unchecked Sendable）；
// - 事务嵌套退化为 SAVEPOINT，与旧行为一致，但不再跨线程共享可变 handle；
// - 预编译语句 LRU 缓存（旧层每次 prepare，热点循环每行编译）；
// - 失败统一为 SQLiteFailure（含 phase/code/extended/message/sql），替代字符串判定。
import Foundation
import CSQLite

/// SQLITE_TRANSIENT 等价物：告知 SQLite 复制传入的字符串/字节。
private let sqliteTransient: sqlite3_destructor_type = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)

public struct SQLiteFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Phase: String, Sendable {
        case open, prepare, bind, step, close, pragma, other
    }

    public let phase: Phase
    public let code: Int32
    public let extended: Int32
    public let message: String
    public let sql: String?

    public init(phase: Phase, code: Int32, extended: Int32, message: String, sql: String? = nil) {
        self.phase = phase
        self.code = code
        self.extended = extended
        self.message = message
        self.sql = sql
    }

    public var description: String {
        var text = "SQLiteFailure(\(phase.rawValue) code=\(code) extended=\(extended)): \(message)"
        if let sql { text += " [sql: \(sql.prefix(200))]" }
        return text
    }

    public var isConstraintViolation: Bool { (code & 0xFF) == SQLITE_CONSTRAINT }
    /// 扩展码宏未导出，按 sqlite3.h 的位定义手算：
    /// SQLITE_CONSTRAINT_PRIMARYKEY = SQLITE_CONSTRAINT | (6<<8)，UNIQUE = | (8<<8)。
    public var isUniqueViolation: Bool {
        extended == (SQLITE_CONSTRAINT | (6 << 8)) || extended == (SQLITE_CONSTRAINT | (8 << 8))
    }
    public var isBusy: Bool { (code & 0xFF) == SQLITE_BUSY }
    /// SQLITE_MISUSE（21）：连接已关闭或 API 误用。
    public var isMisuse: Bool { (code & 0xFF) == 21 }
    public var isMissingTable: Bool { extended == SQLITE_ERROR && message.contains("no such table") }
}

// MARK: -

public actor SQLiteDatabase {
    public struct Configuration: Sendable {
        public enum Synchronous: String, Sendable {
            case off = "OFF"
            case normal = "NORMAL"
            case full = "FULL"
        }

        public var busyTimeoutMs: Int32
        public var journalMode: String
        public var foreignKeys: Bool
        /// 默认 FULL：保持旧层（WAL 默认）的提交持久性，不静默改变语义。
        public var synchronous: Synchronous
        public var statementCacheCapacity: Int
        public var readOnly: Bool

        public init(
            busyTimeoutMs: Int32 = 5_000,
            journalMode: String = "WAL",
            foreignKeys: Bool = true,
            synchronous: Synchronous = .full,
            statementCacheCapacity: Int = 256,
            readOnly: Bool = false
        ) {
            self.busyTimeoutMs = busyTimeoutMs
            self.journalMode = journalMode
            self.foreignKeys = foreignKeys
            self.synchronous = synchronous
            self.statementCacheCapacity = statementCacheCapacity
            self.readOnly = readOnly
        }
    }

    public let path: String
    private let configuration: Configuration
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var statementLRU: [String] = []
    private var transactionDepth = 0
    private var closed = false

    public init(path: String, configuration: Configuration = Configuration()) throws {
        self.path = path
        self.configuration = configuration

        self.handle = try Self.openHandle(path: path, configuration: configuration)
    }

    /// 关闭后用同一路径/配置重新打开（迁移失败恢复备份后使用）。
    public func reopen() throws {
        close()
        handle = try Self.openHandle(path: path, configuration: configuration)
        closed = false
    }

    private static func openHandle(path: String, configuration: Configuration) throws -> OpaquePointer {
        var handle: OpaquePointer?
        var flags = configuration.readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteFailure(phase: .open, code: rc, extended: rc, message: message)
        }

        sqlite3_busy_timeout(opened, configuration.busyTimeoutMs)
        do {
            if !configuration.readOnly {
                try execRaw(opened, "PRAGMA journal_mode = \(configuration.journalMode)")
            }
            try execRaw(opened, "PRAGMA foreign_keys = \(configuration.foreignKeys ? "ON" : "OFF")")
            if !configuration.readOnly {
                try execRaw(opened, "PRAGMA synchronous = \(configuration.synchronous.rawValue)")
            }
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
        return opened
    }

    /// WAL 截断检查点（迁移备份前调用）。
    public func checkpointTruncate() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// SQLite backup API（非直接复制活动库），对应旧 DBConnection backup 语义。
    public func backup(to destinationPath: String) throws {
        guard !closed, let handle else {
            throw SQLiteFailure(phase: .other, code: SQLITE_MISUSE, extended: SQLITE_MISUSE, message: "database is closed")
        }
        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(destinationPath, &destination, flags, nil) == SQLITE_OK, let destination else {
            throw SQLiteFailure(phase: .other, code: SQLITE_CANTOPEN, extended: SQLITE_CANTOPEN, message: "无法创建迁移备份目标 \(destinationPath)")
        }
        defer { sqlite3_close_v2(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else {
            throw SQLiteFailure(phase: .other, code: SQLITE_ERROR, extended: SQLITE_ERROR, message: "sqlite3_backup_init 失败: \(String(cString: sqlite3_errmsg(destination)))")
        }
        defer { sqlite3_backup_finish(backup) }

        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 100)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                Thread.sleep(forTimeInterval: 0.1)
            }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        guard rc == SQLITE_DONE else {
            throw SQLiteFailure(phase: .other, code: rc, extended: rc, message: "数据库备份失败: \(String(cString: sqlite3_errstr(rc)))")
        }
    }

    deinit {
        for (_, statement) in statements { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - 生命周期

    public var isOpen: Bool { !closed && handle != nil }

    /// 缓存中的预编译语句数（测试观察用）。
    public var cachedStatementCount: Int { statements.count }

    public func close() {
        guard !closed else { return }
        for (_, statement) in statements { sqlite3_finalize(statement) }
        statements.removeAll()
        statementLRU.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
        closed = true
    }

    public var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    // MARK: - 执行

    /// 无返回值的 DDL/PRAGMA（不允许外部值拼接）。
    /// 走 sqlite3_exec：支持多语句脚本（StoreSchema.ddl 是整段 DDL），
    /// 且不进入语句缓存（DDL 不是热点，也不该被绑定参数复用）。
    @discardableResult
    public func execute(_ sql: String) throws -> Int {
        guard !closed, let handle else {
            throw SQLiteFailure(phase: .other, code: SQLITE_MISUSE, extended: SQLITE_MISUSE, message: "database is closed", sql: sql)
        }
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite3_exec failed"
            sqlite3_free(error)
            throw SQLiteFailure(
                phase: .step,
                code: rc,
                extended: sqlite3_extended_errcode(handle),
                message: message,
                sql: sql
            )
        }
        return Int(sqlite3_changes(handle))
    }

    @discardableResult
    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        let statement = try acquire(sql)
        defer { releaseAfterUse(statement, sql: sql) }
        try bind(statement, values, sql: sql)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw failure(.step, rc, sql) }
        return changes
    }

    public func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try acquire(sql)
        defer { releaseAfterUse(statement, sql: sql) }
        try bind(statement, values, sql: sql)
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                rows.append(try readRow(statement))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw failure(.step, rc, sql)
            }
        }
        return rows
    }

    public func queryOne(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteRow? {
        let statement = try acquire(sql)
        defer { releaseAfterUse(statement, sql: sql) }
        try bind(statement, values, sql: sql)
        let rc = sqlite3_step(statement)
        if rc == SQLITE_ROW { return try readRow(statement) }
        if rc == SQLITE_DONE { return nil }
        throw failure(.step, rc, sql)
    }

    public func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        guard let row = try queryOne(sql, values), let first = row.columnOrder.first else { return nil }
        return row.int(first)
    }

    // MARK: - 事务

    /// 事务体在 actor 隔离内同步执行；嵌套调用退化为 SAVEPOINT。
    public func transaction<T>(_ body: (isolated SQLiteDatabase) throws -> T) throws -> T {
        guard !closed else { throw SQLiteFailure(phase: .other, code: SQLITE_MISUSE, extended: SQLITE_MISUSE, message: "database is closed") }
        transactionDepth += 1
        let depth = transactionDepth
        let savepoint = "gather_tx_\(depth)"
        do {
            if depth > 1 {
                try execute("SAVEPOINT \(savepoint)")
            } else {
                try execute("BEGIN IMMEDIATE")
            }
            let result = try body(self)
            if depth > 1 {
                try execute("RELEASE SAVEPOINT \(savepoint)")
            } else {
                try execute("COMMIT")
            }
            transactionDepth -= 1
            return result
        } catch {
            if depth > 1 {
                _ = try? execute("ROLLBACK TO SAVEPOINT \(savepoint)")
                _ = try? execute("RELEASE SAVEPOINT \(savepoint)")
            } else {
                _ = try? execute("ROLLBACK")
            }
            transactionDepth -= 1
            throw error
        }
    }

    /// 当前事务嵌套深度（测试观察用）。
    public var currentTransactionDepth: Int { transactionDepth }

    // MARK: - 语句缓存

    private func acquire(_ sql: String) throws -> OpaquePointer {
        guard !closed, let handle else {
            throw SQLiteFailure(phase: .other, code: SQLITE_MISUSE, extended: SQLITE_MISUSE, message: "database is closed", sql: sql)
        }
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            touch(sql)
            return cached
        }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let prepared = statement else {
            throw failure(.prepare, rc, sql)
        }
        statements[sql] = prepared
        statementLRU.append(sql)
        evictIfNeeded()
        return prepared
    }

    private func touch(_ sql: String) {
        if let index = statementLRU.firstIndex(of: sql) {
            statementLRU.remove(at: index)
        }
        statementLRU.append(sql)
    }

    private func evictIfNeeded() {
        let capacity = max(1, configuration.statementCacheCapacity)
        while statementLRU.count > capacity, let oldest = statementLRU.first {
            statementLRU.removeFirst()
            if let statement = statements.removeValue(forKey: oldest) {
                sqlite3_finalize(statement)
            }
        }
    }

    private func releaseAfterUse(_ statement: OpaquePointer, sql: String) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: - 绑定 / 读取 / 错误

    private func bind(_ statement: OpaquePointer, _ values: [SQLiteValue], sql: String) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .int(let v):
                rc = sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                rc = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                rc = sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            guard rc == SQLITE_OK else { throw failure(.bind, rc, sql) }
        }
    }

    private func readRow(_ statement: OpaquePointer) throws -> SQLiteRow {
        let count = Int(sqlite3_column_count(statement))
        var values: [String: SQLiteValue] = [:]
        var order: [String] = []
        order.reserveCapacity(count)
        for index in 0..<count {
            let columnIndex = Int32(index)
            let name = sqlite3_column_name(statement, columnIndex).map { String(cString: $0) } ?? "column\(index)"
            order.append(name)
            switch sqlite3_column_type(statement, columnIndex) {
            case SQLITE_NULL:
                values[name] = .null
            case SQLITE_INTEGER:
                values[name] = .int(sqlite3_column_int64(statement, columnIndex))
            case SQLITE_FLOAT:
                values[name] = .real(sqlite3_column_double(statement, columnIndex))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, columnIndex) {
                    values[name] = .text(String(cString: text))
                } else {
                    values[name] = .null
                }
            case SQLITE_BLOB:
                if let pointer = sqlite3_column_blob(statement, columnIndex) {
                    let length = Int(sqlite3_column_bytes(statement, columnIndex))
                    values[name] = .blob(Data(bytes: pointer, count: length))
                } else {
                    values[name] = .null
                }
            default:
                values[name] = .null
            }
        }
        return SQLiteRow(values: values, columnOrder: order)
    }

    private func failure(_ phase: SQLiteFailure.Phase, _ code: Int32, _ sql: String) -> SQLiteFailure {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        let extended = handle.map { sqlite3_extended_errcode($0) } ?? code
        return SQLiteFailure(phase: phase, code: code, extended: extended, message: message, sql: sql)
    }

    private static func execRaw(_ handle: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite3_exec failed"
            sqlite3_free(error)
            throw SQLiteFailure(phase: .pragma, code: rc, extended: rc, message: message, sql: sql)
        }
    }
}
