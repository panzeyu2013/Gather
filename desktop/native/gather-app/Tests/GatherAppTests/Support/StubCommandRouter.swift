// 测试共享：最小 CommandRouter 实现（execute 返回可配置的 JSONValue 表，
// executeAsync 直接回完成）。供 Culling/FaceKw 等 VM 单测注入。
import Foundation
import GatherCore
@testable import GatherApp

/// 空路由：所有命令返回 .null（模拟空库/空状态）；executeAsync 立即成功。
final class StubCommandRouter: CommandRouter, @unchecked Sendable {
    /// 命令名 → 返回值的映射（execute 读表，未命中返回 .null）。
    var responses: [String: GatherCore.JSONValue]
    /// executeAsync 与 execute 同表（页面异步命令测试用）。
    var asyncResponses: [String: GatherCore.JSONValue]?

    init(responses: [String: GatherCore.JSONValue] = [:]) {
        self.responses = responses
    }

    static func empty() -> StubCommandRouter { StubCommandRouter() }

    func execute(
        _ command: String,
        params: [String: GatherCore.JSONValue]
    ) throws -> GatherCore.JSONValue {
        responses[command] ?? .null
    }

    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping (WebResponse) -> Void
    ) {
        let table = asyncResponses ?? responses
        completion(WebResponse(id: command, ok: true, data: table[command] ?? .null))
    }
}
