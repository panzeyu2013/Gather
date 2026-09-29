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
        // 与 errorText 同一漏斗（语言无关断言：文案随 appLanguage 变化）。
        #expect(NativeCommandClient.message(for: NativeCommandError.failed("SESSION_NOT_FOUND")) == GatherLocalization.errorText("SESSION_NOT_FOUND"))
        #expect(NativeCommandClient.message(for: NativeCommandError.emptyResponse("x")) == GatherLocalization.errorText("NOT_A_CODE"))
        let unknown = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "自定义错误"])
        #expect(NativeCommandClient.message(for: unknown) == GatherLocalization.errorText("NOT_A_CODE"))
    }

    /// 合并后的唯一漏斗 userFacingMessage(for:) 的码→文案矩阵
    /// （含 message(for:) 不认识的 SessionServiceError：不满足 LocalizedError，
    /// NSError 桥接会丢码值，必须显式取 gatherCode）。
    @Test("userFacingMessage(for:) 码→本地化文案 / 未知码回退通用文案")
    func userFacingMessageMatrix() {
        // 语言在 AppLanguageLock 内保持稳定：文案断言与切语言的套件互斥。
        AppLanguageLock.withStableCopy {
        // 每行「错误 → 应当作为码值处理的字符串」。
        let cases: [(label: String, error: Error, code: String)] = [
            ("NativeCommandError 已知码", NativeCommandError.failed("SESSION_NOT_FOUND"), "SESSION_NOT_FOUND"),
            ("NativeCommandError 未知码", NativeCommandError.failed("诊断信息"), "诊断信息"),
            ("NativeCommandError 空响应", NativeCommandError.emptyResponse("photo.list_page"), "EMPTY_RESPONSE:photo.list_page"),
            ("RouterCommandError 已知码", RouterCommandError(message: "PERSON_NOT_FOUND"), "PERSON_NOT_FOUND"),
            ("RouterCommandError 散文", RouterCommandError(message: "诊断信息"), "诊断信息"),
            ("BridgeError 已知码", BridgeError.notFound("SESSION_NOT_FOUND"), "SESSION_NOT_FOUND"),
            ("BridgeError 未实现", BridgeError.notImplemented("dup.groups"), "NOT_IMPLEMENTED: dup.groups"),
            ("SessionServiceError 已知码", SessionServiceError.sessionNotFound, "SESSION_NOT_FOUND"),
            ("SessionServiceError 根目录", SessionServiceError.sourceRootForbidden, "SESSION_SOURCE_ROOT_FORBIDDEN"),
            ("NSError 码值", NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "SESSION_NOT_FOUND"]), "SESSION_NOT_FOUND"),
            ("NSError 无描述", NSError(domain: "t", code: 1), "The operation couldn’t be completed. (t error 1.)"),
            ("DecodingError 诊断", DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), "The data couldn’t be read because it isn’t in the correct format."),
        ]
        for item in cases {
            #expect(
                NativeCommandClient.userFacingMessage(for: item.error) == GatherLocalization.errorText(item.code),
                Comment(rawValue: item.label)
            )
        }
        // SessionServiceError 分支的码值不能被 NSError 桥接吞掉。
        #expect(NativeCommandClient.message(for: SessionServiceError.sessionNotFound)
            != NativeCommandClient.userFacingMessage(for: SessionServiceError.sessionNotFound))
        }
    }

    /// 差分等价：合并前 Dashboard/Similarity 各自的 message(for:) 实现与本表
    /// 逐点一致（两个 VM 现在都委托 userFacingMessage(for:)）。
    @MainActor
    @Test("VM 错误漏斗合并前后在错误矩阵上逐点等价")
    func vmFunnelsMatchLegacyBodies() {
        let matrix: [Error] = [
            NativeCommandError.failed("SESSION_NOT_FOUND"),
            NativeCommandError.failed("XMP_CONFIRM_OTHER_SESSION_PENDING: s1"),
            NativeCommandError.failed("FILTER_FIELD_UNKNOWN::rating"),
            NativeCommandError.failed("诊断信息"),
            NativeCommandError.failed(""),
            NativeCommandError.emptyResponse("photo.list_page"),
            RouterCommandError(message: "PERSON_NOT_FOUND"),
            RouterCommandError(message: "诊断信息"),
            BridgeError.badParams("PERSON_NOT_FOUND"),
            BridgeError.notFound("SESSION_NOT_FOUND"),
            BridgeError.notImplemented("dup.groups"),
            SessionServiceError.sessionNotFound,
            SessionServiceError.sourceRootForbidden,
            SessionServiceError.sourceNotDir,
            SessionServiceError.deleteNotConfirmed,
            NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "SESSION_NOT_FOUND"]),
            NSError(domain: "t", code: 1),
            NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "发生未知错误"]),
            CaptureOneBridgeError.notRunning,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")),
        ]
        AppLanguageLock.withStableCopy {
            for error in matrix {
                let label = Comment(rawValue: String(describing: error))
                #expect(DashboardViewModel.message(for: error) == legacyDashboardMessage(for: error), label)
                #expect(SimilarityViewModel.message(for: error) == legacySimilarityMessage(for: error), label)
            }
        }
    }

    /// 修复有效性差分：Gallery 旧漏斗（NSError 桥接）对码型输入回退通用文案，
    /// 新漏斗保留码值 —— 证明新增断言能捕获旧实现（不是放宽断言）。
    /// Persons 的 message(_:) 是 private，其行为在 PersonsViewModelTests 里按 VM 断言。
    @MainActor
    @Test("Gallery 旧 NSError 漏斗丢码、新漏斗保留（修复有效性）")
    func legacyNSErrorOnlyFunnelLosesCode() {
        let legacy: (Error) -> String = { error in
            let nsError = error as NSError
            let raw = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
            return GatherLocalization.errorText(raw)
        }
        let generic = GatherLocalization.errorText("NOT_A_CODE")
        let inputs: [Error] = [
            BridgeError.notFound("PERSON_NOT_FOUND"),
            NativeCommandError.failed("SESSION_NOT_FOUND"),
            SessionServiceError.sourceRootForbidden,
            NativeCommandError.failed("XMP_CONFIRM_OTHER_SESSION_PENDING: s1"),
        ]
        AppLanguageLock.withStableCopy {
            for error in inputs {
                let label = Comment(rawValue: String(describing: error))
                let mapped = NativeCommandClient.userFacingMessage(for: error)
                #expect(mapped != generic, label)
                #expect(legacy(error) == generic, label)
                #expect(GalleryViewModel.message(for: error) == mapped, label)
            }
        }
    }
}

/// 合并前 DashboardViewModel.message(for:) 的实现（差分参照，勿复用于生产代码）。
@MainActor
private func legacyDashboardMessage(for error: Error) -> String {
    if let sessionError = error as? SessionServiceError {
        return GatherLocalization.errorText(sessionError.gatherCode.rawValue)
    }
    if let native = error as? NativeCommandError { return GatherLocalization.errorText(native.description) }
    if let router = error as? RouterCommandError { return GatherLocalization.errorText(router.message) }
    if let bridge = error as? BridgeError { return GatherLocalization.errorText(bridge.description) }
    return GatherLocalization.errorText((error as NSError).localizedDescription)
}

/// 合并前 SimilarityViewModel.message(for:) 的实现（差分参照，勿复用于生产代码）。
@MainActor
private func legacySimilarityMessage(for error: Error) -> String {
    if let sessionError = error as? SessionServiceError {
        return GatherLocalization.errorText(sessionError.gatherCode.rawValue)
    }
    if let router = error as? RouterCommandError { return GatherLocalization.errorText(router.message) }
    if let native = error as? NativeCommandError { return GatherLocalization.errorText(native.description) }
    if let bridge = error as? BridgeError { return GatherLocalization.errorText(bridge.description) }
    let nsError = error as NSError
    let raw = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    return GatherLocalization.errorText(raw)
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
        completion: @escaping @Sendable (WebResponse) -> Void
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
        completion: @escaping @Sendable (WebResponse) -> Void
    ) {
        completion(WebResponse(ok: false, error: error))
    }
}
