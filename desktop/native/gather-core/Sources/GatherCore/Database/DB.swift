// desktop/native/gather-core/Sources/GatherCore/Database/DB.swift
// 数据库层基座（1.2）：系统 SQLite3 C API 的薄包装，Linux/macOS 双平台可用。
// 决策（2026-08-09）：计划书原拟 SQLite.swift，但其全部版本携带 Apple 专属
// SQLCipher 二进制 target，Linux SwiftPM 无法解析，故改用 `import CSQLite` 自包装，
// 保持零外部依赖，API 语义对齐 better-sqlite3（TS 侧 db/database.ts 的对应物）。
import Foundation
import CSQLite

/// 绑定到语句的位置参数值。
public enum DBValue: Equatable, Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Int64) { self = .int(value) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }
    public init(_ value: Bool) { self = .int(value ? 1 : 0) }

    /// 取出时自动把 INTEGER 0/1 还原为 Bool。
    public var boolValue: Bool? {
        if case .int(let v) = self { return v != 0 }
        return nil
    }
}

/// 一次查询的一行（列序索引 → 值）。
public typealias DBRow = [DBValue]

public enum DBError: Error, Equatable {
    case message(String)
}

/// SQLite 连接（对应 TS 侧 better-sqlite3 Database）。
public final class DBConnection {
    private var handle: OpaquePointer?
    private let reopenPath: String?

    /// path 为 ":memory:" 时使用内存库（测试用）。
    public init(path: String) throws {
        reopenPath = path
        try open()
    }

    deinit { close() }

    /// 关闭后按原路径重新打开（迁移回滚流程需要：TS 侧关闭连接→文件恢复→下次访问
    /// 惰性重开，Swift 侧在 rollback 里显式重开以保持连接可用）。
    public func reopen() throws {
        guard reopenPath != nil else {
            throw DBError.message("无法重新打开数据库：该连接没有路径信息（内存库）")
        }
        close()
        try open()
    }

    private func open() throws {
        let path = reopenPath ?? ":memory:"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            throw DBError.message("无法打开数据库 \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
        handle = db
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
    }

    public func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    /// 供数据库层内部（如 sqlite3_backup 迁移备份）访问原始句柄。
    var rawHandle: OpaquePointer? { handle }

    public var lastInsertRowid: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// user_version pragma（迁移版本号）。
    public var userVersion: Int {
        get {
            guard let row = try? prepare("PRAGMA user_version").get() else { return 0 }
            return Int(row[0].intValue ?? 0)
        }
        set {
            _ = try? exec("PRAGMA user_version = \(newValue)")
        }
    }

    /// 执行无返回值的 SQL。
    @discardableResult
    public func exec(_ sql: String) throws -> Int {
        guard let handle else { throw DBError.message("数据库已关闭") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite3_exec 失败"
            sqlite3_free(err)
            throw DBError.message("\(msg)（SQL: \(sql.prefix(200))）")
        }
        return Int(sqlite3_changes(handle))
    }

    public func prepare(_ sql: String) throws -> DBStatement {
        guard let handle else { throw DBError.message("数据库已关闭") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.message("SQL 编译失败: \(String(cString: sqlite3_errmsg(handle)))")
        }
        return DBStatement(handle: stmt, owner: self)
    }

    // ── 事务 ──
    public func begin() throws { try exec("BEGIN") }
    public func commit() throws { try exec("COMMIT") }
    public func rollback() throws { try exec("ROLLBACK") }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try begin()
        do {
            let result = try body()
            try commit()
            return result
        } catch {
            try? rollback()
            throw error
        }
    }
}

/// 预编译语句（对应 better-sqlite3 Statement）。
public final class DBStatement {
    private let stmt: OpaquePointer
    private let owner: DBConnection

    fileprivate init(handle: OpaquePointer, owner: DBConnection) {
        self.stmt = handle
        self.owner = owner
    }

    deinit { sqlite3_finalize(stmt) }

    /// 按顺序绑定位置参数（1-based，对应 SQL 中的 `?`）。
    public func bind(_ index: Int, _ value: DBValue?) throws {
        let rc: Int32
        switch value ?? .null {
        case .null:
            rc = sqlite3_bind_null(stmt, Int32(index))
        case .int(let v):
            rc = sqlite3_bind_int64(stmt, Int32(index), v)
        case .real(let v):
            rc = sqlite3_bind_double(stmt, Int32(index), v)
        case .text(let v):
            rc = sqlite3_bind_text(stmt, Int32(index), v, -1, SQLITE_TRANSIENT_PTR)
        case .blob(let v):
            rc = v.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, Int32(index), buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_PTR)
            }
        }
        guard rc == SQLITE_OK else { throw DBError.message("绑定参数失败: \(sqlite3_errcode(stmt))") }
    }

    public func bind(_ values: [DBValue?]) throws {
        for (i, v) in values.enumerated() {
            try bind(i + 1, v)
        }
    }

    public func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// 执行并取回全部行。
    public func query(_ values: [DBValue?] = []) throws -> [DBRow] {
        try bind(values)
        defer { reset() }
        var rows: [DBRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(columns())
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.message("查询失败: \(String(cString: sqlite3_errmsg(ownerHandle)))")
            }
        }
        return rows
    }

    /// 执行并返回受影响行数。
    public func run(_ values: [DBValue?] = []) throws -> Int {
        try bind(values)
        defer { reset() }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.message("执行失败: \(String(cString: sqlite3_errmsg(ownerHandle)))")
        }
        return owner.changes
    }

    /// 取单行（无行返回 nil）。
    public func get(_ values: [DBValue?] = []) throws -> DBRow? {
        try bind(values)
        defer { reset() }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return columns() }
        if rc == SQLITE_DONE { return nil }
        throw DBError.message("查询失败: \(String(cString: sqlite3_errmsg(ownerHandle)))")
    }

    private func columns() -> DBRow {
        let count = Int(sqlite3_column_count(stmt))
        return (0..<count).map { col -> DBValue in
            switch sqlite3_column_type(stmt, Int32(col)) {
            case SQLITE_NULL:
                return .null
            case SQLITE_INTEGER:
                return .int(sqlite3_column_int64(stmt, Int32(col)))
            case SQLITE_FLOAT:
                return .real(sqlite3_column_double(stmt, Int32(col)))
            case SQLITE_TEXT:
                guard let c = sqlite3_column_text(stmt, Int32(col)) else { return .null }
                return .text(String(cString: c))
            case SQLITE_BLOB:
                guard let p = sqlite3_column_blob(stmt, Int32(col)) else { return .null }
                let n = Int(sqlite3_column_bytes(stmt, Int32(col)))
                return .blob(Data(bytes: p, count: n))
            default:
                return .null
            }
        }
    }

    private var ownerHandle: OpaquePointer {
        owner.handlePublic ?? stmt
    }
}

// SQLITE_TRANSIENT 是宏，模块映射不导出，用标准等价写法：
// 通知 SQLite 复制传入的字符串/字节（-1 值被安全转为 destructor 类型）。
private let SQLITE_TRANSIENT_PTR: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? =
    unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?.self)

extension DBConnection {
    /// 供 DBStatement 读取错误消息（内部使用）。
    fileprivate var handlePublic: OpaquePointer? { handle }
}

extension DBValue {
    /// 便捷取整数值。
    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var doubleValue: Double? {
        if case .real(let v) = self { return v }
        return nil
    }
}
