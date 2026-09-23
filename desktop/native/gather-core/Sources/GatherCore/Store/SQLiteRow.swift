// Store/SQLiteRow.swift
// R1 新持久化层：按列名（而非位置下标）取值的行模型 + Decodable 解码。
//
// 旧 Repo 用 DBRow = [DBValue] + 位置下标（加列即静默错位）；新层统一 keyed，
// 并支持 TEXT/BLOB 中 JSON 的复合字段解码（photo_metadata_cache.keywords 等）。
import Foundation

/// 一行结果：列名 → 值，另保留列顺序供诊断。
public struct SQLiteRow: Equatable, Sendable {
    public let values: [String: SQLiteValue]
    public let columnOrder: [String]

    public init(values: [String: SQLiteValue], columnOrder: [String]) {
        self.values = values
        self.columnOrder = columnOrder
    }

    public subscript(column: String) -> SQLiteValue? { values[column] }
}

public extension SQLiteRow {
    func text(_ column: String) -> String? { values[column]?.textValue }
    func int(_ column: String) -> Int64? { values[column]?.intValue }
    func int(_ column: String, default fallback: Int64) -> Int64 { values[column]?.intValue ?? fallback }
    func double(_ column: String) -> Double? { values[column]?.doubleValue }
    func bool(_ column: String) -> Bool? { values[column]?.boolValue }
    func blob(_ column: String) -> Data? { values[column]?.blobValue }
    func isNull(_ column: String) -> Bool { (values[column] ?? .null).isNull }

    /// 由某个非空列推导必填值；缺失或 NULL 时抛 SQLiteDecodingError.missingColumn。
    func requiredText(_ column: String) throws -> String {
        guard let value = values[column]?.textValue else {
            throw SQLiteDecodingError.missingColumn(column)
        }
        return value
    }

    func requiredInt(_ column: String) throws -> Int64 {
        guard let value = values[column]?.intValue else {
            throw SQLiteDecodingError.missingColumn(column)
        }
        return value
    }

    /// 键行解码（属性名 = 列名）。复合字段（数组/字典）支持 TEXT/BLOB 中的 JSON。
    func decode<T: Decodable>(_ type: T.Type, decoder: SQLiteDecoder = SQLiteDecoder()) throws -> T {
        try decoder.decode(type, from: self)
    }
}

public struct SQLiteDecodingError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public static func missingColumn(_ name: String) -> SQLiteDecodingError {
        SQLiteDecodingError(message: "missing or NULL column: \(name)")
    }
    public var description: String { message }
    public init(message: String) { self.message = message }
}

// MARK: - Decoder

public struct SQLiteDecoder {
    public var userInfo: [CodingUserInfoKey: Any] = [:]
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from row: SQLiteRow) throws -> T {
        try T(from: _RowDecoder(row: row, codingPath: [], userInfo: userInfo))
    }
}

func _decodeValue<T: Decodable>(_ value: SQLiteValue, _ type: T.Type, codingPath: [CodingKey]) throws -> T {
    if let decoded = _decodeScalar(value, type) { return decoded }
    // 复合类型：列内 JSON（TEXT/BLOB）。
    let data: Data?
    switch value {
    case .text(let text): data = text.data(using: .utf8)
    case .blob(let blob): data = blob
    default: data = nil
    }
    if let data, let decoded = try? JSONDecoder().decode(T.self, from: data) {
        return decoded
    }
    throw DecodingError.typeMismatch(T.self, DecodingError.Context(
        codingPath: codingPath,
        debugDescription: "cannot decode \(T.self) from \(value)"
    ))
}

private func _decodeScalar<T: Decodable>(_ value: SQLiteValue, _ type: T.Type) -> T? {
    switch type {
    case is String.Type:
        guard case .text(let v) = value else { return nil }
        return v as? T
    case is Bool.Type:
        return value.boolValue as? T
    case is Int.Type:
        guard let v = value.intValue, let i = Int(exactly: v) else { return nil }
        return i as? T
    case is Int64.Type:
        return value.intValue as? T
    case is Double.Type:
        return value.doubleValue as? T
    case is Float.Type:
        return value.doubleValue.map(Float.init) as? T
    case is Data.Type:
        guard case .blob(let v) = value else { return nil }
        return v as? T
    default:
        return nil
    }
}

private struct _RowDecoder: Decoder {
    let row: SQLiteRow
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_RowKeyedContainer<Key>(row: row, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, DecodingError.Context(
            codingPath: codingPath, debugDescription: "row is not an unkeyed container"))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        _RowSingleValueContainer(row: row, codingPath: codingPath)
    }
}

private struct _RowKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: SQLiteRow
    let codingPath: [CodingKey]

    var allKeys: [Key] { row.columnOrder.compactMap { Key(stringValue: $0) } }
    func contains(_ key: Key) -> Bool { row.values[key.stringValue] != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = row.values[key.stringValue] else { return true }
        return value.isNull
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        guard let value = row.values[key.stringValue], !value.isNull else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath, debugDescription: "missing column: \(key.stringValue)"))
        }
        return try _decodeValue(value, type, codingPath: codingPath + [key])
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let value = row.values[key.stringValue], !value.isNull else { return nil }
        return try _decodeValue(value, type, codingPath: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch([String: Any].self, DecodingError.Context(
            codingPath: codingPath + [key], debugDescription: "nested keyed container is not supported"))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, DecodingError.Context(
            codingPath: codingPath + [key], debugDescription: "nested unkeyed container is not supported"))
    }

    func superDecoder() throws -> Decoder { _RowDecoder(row: row, codingPath: codingPath, userInfo: [:]) }
    func superDecoder(forKey key: Key) throws -> Decoder {
        _RowDecoder(row: SQLiteRow(values: [key.stringValue: row.values[key.stringValue] ?? .null], columnOrder: [key.stringValue]),
                    codingPath: codingPath + [key], userInfo: [:])
    }
}

private struct _RowSingleValueContainer: SingleValueDecodingContainer {
    let row: SQLiteRow
    let codingPath: [CodingKey]

    func decodeNil() -> Bool {
        guard let first = row.columnOrder.first else { return true }
        return (row.values[first] ?? .null).isNull
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let first = row.columnOrder.first, let value = row.values[first], !value.isNull else {
            throw SQLiteDecodingError.missingColumn(row.columnOrder.first ?? "<empty>")
        }
        return try _decodeValue(value, type, codingPath: codingPath)
    }
}
