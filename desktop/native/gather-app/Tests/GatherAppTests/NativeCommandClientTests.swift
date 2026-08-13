// NativeCommandClient 协议包装单测：对齐 tests/unit/renderer/api-client.test.ts
// 的 sendCommand 语义（成功返回 data / 失败响应抛错 / 取消/空响应归类）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("NativeCommandClient（对齐 api-client.test.ts）")
struct NativeCommandClientTests {
    @Test("execute 成功返回 data")
    func executeReturnsData() throws {
        let router = StubCommandRouter(responses: [
            "session.get": .object(["id": .string("s1")]),
        ])
        let client = NativeCommandClient(router: router)
        let value = try client.execute("session.get", params: ["sessionId": .string("s1")])
        #expect(value.objectValue?["id"]?.stringValue == "s1")
    }

    @Test("executeAsync 失败响应 → 抛 NativeCommandError.failed")
    func asyncFailureThrows() async {
        let router = FailingCommandRouter(error: "boom")
        let client = NativeCommandClient(router: router)
        do {
            _ = try await client.executeAsync("session.get")
            Issue.record("应抛出错误")
        } catch let error as NativeCommandError {
            #expect(error == .failed("boom"))
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test("executeAsync 空响应（ok 但无 data）→ 抛 NativeCommandError.emptyResponse")
    func asyncEmptyThrows() async {
        let router = EmptyDataCommandRouter()
        let client = NativeCommandClient(router: router)
        do {
            _ = try await client.executeAsync("jobs.list")
            Issue.record("应抛出错误")
        } catch let error as NativeCommandError {
            #expect(error == .emptyResponse("jobs.list"))
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test("message(for:) 已知码翻译 / 未知码回退通用文案")
    func messageTranslation() {
        #expect(NativeCommandClient.message(for: NativeCommandError.failed("SESSION_NOT_FOUND")) == "工作区不存在")
        // 未知码（含 emptyResponse 包装、裸 NSError）→ GatherLocalization 回退。
        #expect(NativeCommandClient.message(for: NativeCommandError.emptyResponse("x")) == "发生未知错误，请稍后重试")
        let unknown = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "自定义错误"])
        #expect(NativeCommandClient.message(for: unknown) == "发生未知错误，请稍后重试")
    }
}

/// ok=true 但 data 为 nil 的路由（对齐 TS 空响应语义）。
private final class EmptyDataCommandRouter: CommandRouter, @unchecked Sendable {
    func execute(
        _ command: String,
        params: [String: GatherCore.JSONValue]
    ) throws -> GatherCore.JSONValue {
        .null
    }

    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping (WebResponse) -> Void
    ) {
        completion(WebResponse(ok: true, data: nil))
    }
}

/// 固定返回失败响应的路由（executeAsync 走 ok:false 路径）。
private final class FailingCommandRouter: CommandRouter, @unchecked Sendable {
    let error: String

    init(error: String) {
        self.error = error
    }

    func execute(
        _ command: String,
        params: [String: GatherCore.JSONValue]
    ) throws -> GatherCore.JSONValue {
        throw NativeCommandError.failed(error)
    }

    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping (WebResponse) -> Void
    ) {
        completion(WebResponse(ok: false, error: error))
    }
}
