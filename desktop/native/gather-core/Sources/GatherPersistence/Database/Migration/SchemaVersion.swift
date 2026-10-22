// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaVersion.swift
// WP6a：schema 版本号（设计 §5.1）。PRAGMA user_version 是唯一权威，本类型只是它的
// 强类型包装，避免 Int 与字符串在日志/计划里互相漂移。
//
// 纪律：版本号必须线性递增（to == from + 1）。WP6a 只声明 v1/v2 两个常量，
// 不注册任何迁移、不改 SchemaSQL.currentSchemaVersion。
public struct SchemaVersion: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "v\(rawValue)" }

    public static let v1 = SchemaVersion(1)
    public static let v2 = SchemaVersion(2)
}
