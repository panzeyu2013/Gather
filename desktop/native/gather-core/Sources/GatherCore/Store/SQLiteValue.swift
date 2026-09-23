// Store/SQLiteValue.swift
// R1 新持久化层：SQLite 值模型。
//
// 与旧 Database/DB.swift 的 DBValue 并存属于 R1 迁移期；R1 合并单元结束时
// 旧文件（DB.swift/Repositories/Schema/Migrations）会被删除。
import Foundation
import CSQLite

/// 绑定参数 / 结果列的单一值模型。
public enum SQLiteValue: Equatable, Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

// MARK: - 便捷构造与读取

public extension SQLiteValue {
    init(_ value: Int) { self = .int(Int64(value)) }
    init(_ value: Int64) { self = .int(value) }
    init(_ value: Double) { self = .real(value) }
    init(_ value: Float) { self = .real(Double(value)) }
    init(_ value: String) { self = .text(value) }
    init(_ value: Data) { self = .blob(value) }
    init(_ value: Bool) { self = .int(value ? 1 : 0) }

    var isNull: Bool { if case .null = self { return true }; return false }

    var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .real(let v): return Int64(exactly: v.rounded()) ?? Int64(v)
        case .text(let v): return Int64(v)
        case .blob, .null: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .real(let v): return v
        case .text(let v): return Double(v)
        case .blob, .null: return nil
        }
    }

    var textValue: String? {
        switch self {
        case .text(let v): return v
        case .int(let v): return String(v)
        case .real(let v): return String(v)
        case .blob, .null: return nil
        }
    }

    var blobValue: Data? {
        switch self {
        case .blob(let v): return v
        case .text(let v): return v.data(using: .utf8)
        case .int, .real, .null: return nil
        }
    }

    /// INTEGER 0/1 → Bool（旧 DBValue.boolValue 同语义）；TEXT 兼容 true/false。
    var boolValue: Bool? {
        switch self {
        case .int(let v): return v != 0
        case .real(let v): return v != 0
        case .text(let v):
            switch v.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        case .blob, .null: return nil
        }
    }
}

// MARK: - 字面量支持（便于测试与调用点书写）

extension SQLiteValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension SQLiteValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

extension SQLiteValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension SQLiteValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .real(value) }
}

extension SQLiteValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .int(value ? 1 : 0) }
}
