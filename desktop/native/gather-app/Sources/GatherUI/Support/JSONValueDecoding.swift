// desktop/native/gather-app/Sources/GatherUI/Support/JSONValueDecoding.swift
// 3.2/3.3 页面共享：JSONValue → 类型化模型的解码工具。
//
// Cut 1 / B8.4：字符串命令面与其客户端已删除；`decoded` 只保留给仍以
// JSONValue 为载荷的接缝与契约测试。
import Foundation
import GatherProtocol

/// 类型化 API 边界的错误载体：原始串为 GatherErrorCode（可含参数）或诊断文案，
/// 与错误展示漏斗（APIErrorPresentation / GatherLocalization）的输入一致。
///
/// B8.4：命令客户端文件已删除，本类型不再是字符串命令的响应信封，只保留给
/// LibraryDataProvider 的“不支持”默认实现与错误漏斗测试注入。
public enum APIError: Error, Equatable, CustomStringConvertible {
    case failed(String)
    case emptyResponse(String)

    public var description: String {
        switch self {
        case .failed(let message): return message
        case .emptyResponse(let command): return "EMPTY_RESPONSE:\(command)"
        }
    }
}

/// 旧异步命令的完成回调错误（message 为 GatherErrorCode 字符串或
/// localizedDescription，与 renderer translateError 的输入一致）。
///
/// B8.4：字符串命令面已删除，不再有生产抛出点；错误展示漏斗的兼容分支保留，
/// 供历史错误载荷（日志/持久化/测试）继续按码值翻译。
public struct RouterCommandError: LocalizedError, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 旧桥接错误载体（字符串命令边界的 NOT_IMPLEMENTED / badParams / notFound / 码值）。
///
/// B8.4：命令面删除后不再有生产抛出点；错误展示漏斗与测试仍按同一语义处理。
enum BridgeError: Error, CustomStringConvertible {
    case notImplemented(String)
    case badParams(String)
    case notFound(String)
    /// 结构化错误码（UI 侧按码取本地化文案；禁止用 badParams 传裸英文）
    case coded(GatherErrorCode)

    var description: String {
        switch self {
        case .notImplemented(let command): return "NOT_IMPLEMENTED: \(command)"
        case .badParams(let message): return message
        case .notFound(let code): return code
        case .coded(let code): return code.rawValue
        }
    }
}

public extension JSONValue {
    /// Encodable → JSONValue（checkpoint / 任务载荷的通用编码入口）。
    init<T: Encodable>(from value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
