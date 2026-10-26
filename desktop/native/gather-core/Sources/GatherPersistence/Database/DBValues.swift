// desktop/native/gather-core/Sources/GatherPersistence/Database/DBValues.swift
// 从 DB.swift 拆出的值类型（复审 E1：单文件 ≤800 行，纯移动，行为不变）。
// 覆盖 DBValue / DBRow / DBError / DBValueDecodable / NamedRow。
import Foundation

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

// MARK: - 命名行（Cut 2 / S4a，D-028 / R1-09）

/// 按列名解码一个 DBValue。类型不符时抛带列名的 DBError，绝不静默归零。
///
/// 覆盖 V1 行映射用到的标量类型；可选列用 `NamedRow.decodedIfPresent(by:)`。
public protocol DBValueDecodable {
    init(dbValue: DBValue, column: String) throws
}

extension String: DBValueDecodable {
    public init(dbValue: DBValue, column: String) throws {
        guard case .text(let value) = dbValue else {
            throw DBError.message("列 \(column) 类型不匹配: 期望 TEXT, 实际 \(dbValue.typeName)")
        }
        self = value
    }
}

extension Int: DBValueDecodable {
    public init(dbValue: DBValue, column: String) throws {
        guard case .int(let raw) = dbValue else {
            throw DBError.message("列 \(column) 类型不匹配: 期望 INTEGER, 实际 \(dbValue.typeName)")
        }
        guard let value = Int(exactly: raw) else {
            throw DBError.message("列 \(column) 超出 Int 范围: \(raw)")
        }
        self = value
    }
}

extension Int64: DBValueDecodable {
    public init(dbValue: DBValue, column: String) throws {
        guard case .int(let value) = dbValue else {
            throw DBError.message("列 \(column) 类型不匹配: 期望 INTEGER, 实际 \(dbValue.typeName)")
        }
        self = value
    }
}

extension Double: DBValueDecodable {
    public init(dbValue: DBValue, column: String) throws {
        guard case .real(let value) = dbValue else {
            throw DBError.message("列 \(column) 类型不匹配: 期望 REAL, 实际 \(dbValue.typeName)")
        }
        self = value
    }
}

extension Bool: DBValueDecodable {
    public init(dbValue: DBValue, column: String) throws {
        guard case .int(let raw) = dbValue else {
            throw DBError.message("列 \(column) 类型不匹配: 期望 INTEGER(0/1), 实际 \(dbValue.typeName)")
        }
        self = raw != 0
    }
}

extension Data: DBValueDecodable {
    public init(dbValue: DBValue, column: String) throws {
        guard case .blob(let value) = dbValue else {
            throw DBError.message("列 \(column) 类型不匹配: 期望 BLOB, 实际 \(dbValue.typeName)")
        }
        self = value
    }
}

/// 带列名的一行（列序无关）。
///
/// 用途（R1 根因）：旧 `DBRow` 只有位置，SELECT 列序一变就静默错列/越界；
/// 命名行让映射器按列名取值，缺列/重列/类型不符都会显式失败。
///
/// - `columns` 与 `values` 等长且同序；`index` 是列名 → 下标的缓存。
/// - 重复列名直接拒绝：JOIN 产生同名列时必须显式 `AS` 别名，否则按名取值有歧义。
/// - `valuesByColumn` / 下标提供 [String: DBValue] 视图，便于日志/调试。
public struct NamedRow: Sendable, Equatable {
    public let columns: [String]
    public let values: [DBValue]
    private let index: [String: Int]

    public init(columns: [String], values: [DBValue]) throws {
        guard columns.count == values.count else {
            throw DBError.message("列名与行宽不一致: \(columns.count) vs \(values.count)")
        }
        var index: [String: Int] = [:]
        for (position, name) in columns.enumerated() {
            guard index.updateValue(position, forKey: name) == nil else {
                throw DBError.message("结果集列名重复: \(name)")
            }
        }
        self.columns = columns
        self.values = values
        self.index = index
    }

    /// 字典构造（列名按字典序固定，便于测试与日志；行映射仍按名取值）。
    public init(_ valuesByColumn: [String: DBValue]) {
        let columns = valuesByColumn.keys.sorted()
        self.columns = columns
        self.values = columns.map { valuesByColumn[$0] ?? .null }
        var index: [String: Int] = [:]
        for (position, name) in columns.enumerated() { index[name] = position }
        self.index = index
    }

    /// [String: DBValue] 视图（列序丢失；仅用于展示/断言，映射请用 decoded(by:)）。
    public var valuesByColumn: [String: DBValue] {
        Dictionary(uniqueKeysWithValues: zip(columns, values))
    }

    public func contains(_ column: String) -> Bool { index[column] != nil }

    public subscript(column: String) -> DBValue? {
        guard let position = index[column] else { return nil }
        return values[position]
    }

    /// 按列名解码；缺列或类型不符显式抛错。
    public func decoded<T: DBValueDecodable>(by column: String) throws -> T {
        guard let position = index[column] else {
            throw DBError.message("缺失列: \(column)")
        }
        return try T(dbValue: values[position], column: column)
    }

    /// 按列名解码可选列：SQL NULL → nil；缺列或类型不符仍抛错（查询列清单漂移必须暴露）。
    public func decodedIfPresent<T: DBValueDecodable>(by column: String) throws -> T? {
        guard let position = index[column] else {
            throw DBError.message("缺失列: \(column)")
        }
        if case .null = values[position] { return nil }
        return try T(dbValue: values[position], column: column)
    }
}

/// SQLite 连接（对应 TS 侧 better-sqlite3 Database）。
///
/// 线程安全说明（Swift 6 `Sendable`）：对 sqlite handle 的一切访问都在内部的
/// `connectionLock`（NSRecursiveLock）之下——`withConnectionLock` 供语句执行期持有，
/// 公开 API 全部经由它。因此本类可安全跨并发域传递；锁纪律无法被编译器静态验证，
/// 故显式标注 `@unchecked`（这是本仓唯一的共享句柄）。
