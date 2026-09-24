// desktop/native/gather-core/Sources/GatherCore/Runtime/Jobs/JobCheckpoint.swift
// R3：作业 checkpoint 的类型安全编解码。
//
// 存储格式不变：checkpoint_json 仍是 JSON 对象（Store 逐字读写），本类型只在
// 内存侧提供强类型读写：JSONValue 访问器 + Codable 往返 + 覆盖/合并两种写语义。
// 崩溃恢复：recoverStale/resumeInterrupted 不清 checkpoint 列，重启后的
// executor 经 JobRunnerContext.initialCheckpoint / loadCheckpoint() 读回上次值。

import Foundation

public struct JobCheckpoint: Equatable, Sendable {
    public private(set) var raw: [String: JSONValue]

    public init(raw: [String: JSONValue] = [:]) {
        self.raw = raw
    }

    public init(_ values: [String: JSONValue]) {
        self.raw = values
    }

    public var isEmpty: Bool { raw.isEmpty }

    /// 已排序键（稳定输出，便于日志/测试比较）。
    public var keys: [String] { raw.keys.sorted() }

    public subscript(key: String) -> JSONValue? {
        get { raw[key] }
        set { raw[key] = newValue }
    }

    // ── JSONValue 便捷读取（类型不符返回 nil，不抛错） ──

    public func string(_ key: String) -> String? { raw[key]?.stringValue }

    public func int(_ key: String) -> Int? {
        guard let number = raw[key]?.numberValue else { return nil }
        return Int(number)
    }

    public func double(_ key: String) -> Double? { raw[key]?.numberValue }

    public func bool(_ key: String) -> Bool? { raw[key]?.boolValue }

    public func object(_ key: String) -> [String: JSONValue]? { raw[key]?.objectValue }

    public func array(_ key: String) -> [JSONValue]? { raw[key]?.arrayElements }

    public func stringArray(_ key: String) -> [String]? {
        guard let items = raw[key]?.arrayElements else { return nil }
        return items.compactMap { $0.stringValue }
    }

    // ── Codable 往返（类型安全通道） ──

    /// 解码：缺键返回 nil；键存在但类型不符时抛 DecodingError。
    public func decode<T: Decodable>(_ type: T.Type = T.self, forKey key: String) throws -> T? {
        guard let value = raw[key] else { return nil }
        if let direct = value as? T { return direct }
        let data = Data(try JSONValue.stringify(value).utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 编码写回单个键（JSON 值往返；JSONValue 自身也走该路径，保证一致）。
    public mutating func encode<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        raw[key] = try JSONValue.parse(String(decoding: data, as: UTF8.self))
    }

    /// 编码为 JSONValue（构建 checkpoint 时用，如 JobCreateParams.checkpoint）。
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONValue.parse(String(decoding: data, as: UTF8.self))
    }

    // ── 合并/删除 ──

    /// 浅合并：patch 的键覆盖同键旧值，其余保留。
    public func merging(_ patch: JobCheckpoint) -> JobCheckpoint {
        var merged = raw
        for (key, value) in patch.raw {
            merged[key] = value
        }
        return JobCheckpoint(raw: merged)
    }

    public mutating func set(_ value: JSONValue, forKey key: String) {
        raw[key] = value
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        raw.removeValue(forKey: key)
    }
}
