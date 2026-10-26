// desktop/native/gather-core/Sources/GatherPersistence/Database/DatabaseError.swift
// Cut 2 / B-1：Database facade 的类型化错误（docs/refactor-decisions.md D-035）。
//
// 为什么需要它：DB.swift 的 `DBError` 只有一个 `.message(String)`，调用方无法区分
// 「库被锁（可重试）」「约束冲突（用户输入）」「库已关闭（编程错误）」
// 「schema 不兼容（必须重置/上报）」——所有分支都退化成字符串匹配，错误处理只能
// 在 Service 层重复实现。这里做**最小**映射：
//   1. 有 SQLite 结果码时优先按码分类（`init(sqliteCode:message:)`）；
//   2. 只有 `DBError.message` 时按 errmsg 关键字分类；
//   3. 无法分类一律 `.sql`（保留原文，绝不吞错、绝不瞎猜）。
//
// 边界：本类型只描述**数据库层**错误。Database.read/write 只把 `DBError` 转成
// `DatabaseError`；body 抛出的自定义/领域错误原样上抛（否则会被 `.sql` 吃掉语义）。
import Foundation
import CSQLite

/// Database facade 的类型化错误。
///
/// 与 `GatherError` 分层：`GatherError` 是 API/IPC 面向用户的错误契约（177 个
/// `GatherErrorCode`）；`DatabaseError` 是持久层内部错误，由 Service 决定映射成
/// 哪个 `GatherErrorCode`，因此不参与 `ErrorCodeContractTests` 的固定清单。
public enum DatabaseError: Error, Equatable, Sendable, LocalizedError {
    /// 库/表被其他连接或进程锁住（SQLITE_BUSY / SQLITE_LOCKED）；通常可重试。
    case busy(String)
    /// 违反 CHECK / UNIQUE / NOT NULL / FOREIGN KEY 约束（SQLITE_CONSTRAINT）。
    case constraint(String)
    /// 磁盘 I/O、只读、磁盘满、打不开文件等（SQLITE_IOERR / READONLY / FULL / CANTOPEN）。
    case io(String)
    /// 文件损坏或不是 SQLite 库（SQLITE_CORRUPT / NOTADB）。
    case corrupt(String)
    /// facade 已 close，或底层连接已关闭——调用方在错误的生命周期里访问库。
    case closed(String)
    /// schema 不兼容 / 缺表缺列 / 建库后版本不符（SQLITE_SCHEMA 与 SchemaCurrent 自检）。
    case schema(String)
    /// 迁移失败（事务已回滚；库仍停在旧版本，文件未被重置）。WP6a 框架引入。
    case migration(String)
    /// 库版本高于本构建（fail closed；默认不改写文件）。WP6a 框架引入。
    case versionUnsupported(String)
    /// SQLite API 误用（SQLITE_MISUSE，如绑定越界、语句顺序错误）。
    case misuse(String)
    /// 被 sqlite3_interrupt 中断（SQLITE_INTERRUPT）。
    case interrupted(String)
    /// 其余 SQL 执行/行映射错误（含类型不匹配、列名重复、无法分类的 errmsg）。
    case sql(String)

    /// 分类标签（日志/测试用；避免模式匹配里逐 case 展开）。
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case busy, constraint, io, corrupt, closed, schema, migration, versionUnsupported,
             misuse, interrupted, sql
    }

    /// 错误分类。
    public var kind: Kind {
        switch self {
        case .busy: return .busy
        case .constraint: return .constraint
        case .io: return .io
        case .corrupt: return .corrupt
        case .closed: return .closed
        case .schema: return .schema
        case .migration: return .migration
        case .versionUnsupported: return .versionUnsupported
        case .misuse: return .misuse
        case .interrupted: return .interrupted
        case .sql: return .sql
        }
    }

    /// 原始错误消息（SQLite errmsg 原文或本仓中文包装文案）。
    public var message: String {
        switch self {
        case .busy(let message), .constraint(let message), .io(let message),
             .corrupt(let message), .closed(let message), .schema(let message),
             .migration(let message), .versionUnsupported(let message),
             .misuse(let message), .interrupted(let message), .sql(let message):
            return message
        }
    }

    public var errorDescription: String? { "\(kind.rawValue): \(message)" }

    // MARK: - 构造 / 映射

    /// 按 SQLite 结果码分类；码不认识时回落到 errmsg 关键字分类（最后是 `.sql`）。
    ///
    /// 扩展码（如 `SQLITE_CONSTRAINT_UNIQUE`）的低 8 位是主结果码，故先 `& 0xFF`。
    public init(sqliteCode: Int32, message: String) {
        let primary = Int32(sqliteCode & 0xFF)
        switch primary {
        case SQLITE_BUSY, SQLITE_LOCKED:
            self = .busy(message)
        case SQLITE_CONSTRAINT:
            self = .constraint(message)
        case SQLITE_IOERR, SQLITE_READONLY, SQLITE_FULL, SQLITE_CANTOPEN:
            self = .io(message)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            self = .corrupt(message)
        case SQLITE_INTERRUPT:
            self = .interrupted(message)
        case SQLITE_SCHEMA:
            self = .schema(message)
        case SQLITE_MISUSE:
            self = .misuse(message)
        default:
            self = DatabaseError.classify(message)
        }
    }

    /// 从本仓唯一的底层错误 `DBError` 映射（DB.swift 只保留 message，无结果码）。
    public init(dbError: DBError) {
        switch dbError {
        case .message(let message):
            self = DatabaseError.classify(message)
        }
    }

    /// 任意 Error → DatabaseError。已是 DatabaseError 时原样返回；
    /// 非数据库层错误归 `.sql`（保留 `String(describing:)` 原文）。
    public static func map(_ error: Error) -> DatabaseError {
        if let databaseError = error as? DatabaseError { return databaseError }
        if let dbError = error as? DBError { return DatabaseError(dbError: dbError) }
        return .sql(String(describing: error))
    }

    /// errmsg 关键字分类（顺序即优先级）。
    ///
    /// 注意：DB.swift 的部分文案是中文（「数据库已关闭」「SQL 编译失败」），
    /// 因此中英文关键字都要覆盖；「已关闭」必须先于 SQLite 的通用词判断。
    static func classify(_ rawMessage: String) -> DatabaseError {
        let text = rawMessage.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { text.contains($0) }
        }

        if containsAny(["数据库已关闭", "database is closed", "connection is closed"]) {
            return .closed(rawMessage)
        }
        if containsAny(["interrupted", "interrupt"]) {
            return .interrupted(rawMessage)
        }
        if containsAny(["database is locked", "database table is locked", "database is busy", "sqlite_busy", "sqlite_locked", "locked"]) {
            return .busy(rawMessage)
        }
        if containsAny([
            "constraint failed", "constraint violation", "sqlite_constraint",
            "unique constraint", "not null constraint", "check constraint",
            "foreign key constraint", "constraint",
        ]) {
            return .constraint(rawMessage)
        }
        if containsAny(["not a database", "sqlite_notadb", "file is encrypted", "不是数据库"]) {
            return .corrupt(rawMessage)
        }
        if containsAny(["malformed", "sqlite_corrupt", "corrupt", "损坏"]) {
            return .corrupt(rawMessage)
        }
        if containsAny([
            "disk i/o error", "i/o error", "unable to open database", "database or disk is full",
            "readonly", "read-only", "sqlite_ioerr", "sqlite_readonly", "sqlite_full",
            "sqlite_cantopen", "无法打开数据库",
        ]) {
            return .io(rawMessage)
        }
        if containsAny([
            "no such table", "no such column", "no such index", "no such function",
            "already exists", "duplicate column", "unknown column", "schema",
        ]) || rawMessage.contains("编译失败") {
            return .schema(rawMessage)
        }
        if containsAny(["misuse", "out of sequence", "wrong number of bindings", "bindings", "index out of range", "sqlite_misuse"]) {
            return .misuse(rawMessage)
        }
        return .sql(rawMessage)
    }

    /// 文件根本不像 SQLite 库（打不开/加密）：Database.open 据此走「移到不兼容副本」重置，
    /// 而不是抛错（draft §6.1 default 分支的「非 SQLite 文件」）。
    var indicatesNotDatabaseFile: Bool {
        let text = message.lowercased()
        return text.contains("not a database")
            || text.contains("file is encrypted")
            || text.contains("sqlite_notadb")
            || message.contains("不是数据库")
    }
}
