// desktop/native/gather-app/Sources/GatherApp/Support/JSONValueDecoding.swift
// 3.2/3.3 页面共享：JSONValue → 类型化模型的解码工具。
// 路由（SessionCommandRouter）返回的响应为 GatherCore.JSONValue；Live 侧
// provider 经 JSONEncoder/Decoder 往返解码为 Codable 值类型（JSONValue
// 的 Codable 合成 key 与 TS 序列化逐字一致，见 Protocol 契约层）。
import Foundation
import GatherCore

public extension GatherCore.JSONValue {
    /// JSONValue → 任意 Decodable（编码往返，等价 TS JSON.parse(json.stringify(v))）。
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

/// 路由异步命令的完成回调错误（error message 为 GatherErrorCode 字符串或
/// localizedDescription，与 renderer translateError 的输入一致）。
public struct RouterCommandError: LocalizedError, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
