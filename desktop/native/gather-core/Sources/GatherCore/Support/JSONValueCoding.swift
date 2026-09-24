// Sources/GatherCore/Support/JSONValueCoding.swift
// R5 支撑：Encodable → JSONValue 往返（作业 checkpoint / 命令载荷桥接）。
// 原定义在 app 宿主路由层；路由层删除后成为 core 单一来源。
import Foundation

public extension JSONValue {
    /// Encodable → JSONValue（编码往返，等价 TS JSON.parse(JSON.stringify(v))）。
    init<T: Encodable>(from value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
