// desktop/native/gather-app/Tests/GatherAppTests/APIErrorPresentationTests.swift
// APIErrorPresentation 错误漏斗单测（B8.4 从已删除的命令客户端测试迁移）。
//
// 覆盖：码 → 本地化文案 / 未知码回退通用文案的矩阵、VM 漏斗合并前后等价、
// Gallery 旧 NSError 漏斗丢码的修复有效性。字符串命令客户端本身已删除，
// 这里只测展示语义（不再涉及 execute/executeAsync 或响应信封）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

@Suite("APIErrorPresentation（错误展示唯一漏斗）")
struct APIErrorPresentationTests {
    @Test("message(for:) 已知码翻译 / 未知码回退通用文案")
    func messageTranslation() {
        // Cut 4 / 4b-1：漏斗改为显式传入 L10n；固定 zh 作期望，断言不随系统语言漂移。
        let l10n = L10n(language: .zhCN)
        #expect(APIErrorPresentation.message(for: APIError.failed("SESSION_NOT_FOUND"), with: l10n) == l10n.errorText("SESSION_NOT_FOUND"))
        #expect(APIErrorPresentation.message(for: APIError.emptyResponse("x"), with: l10n) == l10n.errorText("NOT_A_CODE"))
        let unknown = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "自定义错误"])
        #expect(APIErrorPresentation.message(for: unknown, with: l10n) == l10n.errorText("NOT_A_CODE"))
    }

    /// 码→文案矩阵（含 message(for:) 不认识的 SessionServiceError：不满足
    /// LocalizedError，NSError 桥接会丢码值，必须显式取 gatherCode）。
    @Test("userFacingMessage(for:) 码→本地化文案 / 未知码回退通用文案")
    func userFacingMessageMatrix() {
        // 语言在 AppLanguageLock 内保持稳定：文案断言与切语言的套件互斥。
        AppLanguageLock.withStableCopy {
        let l10n = L10n(language: .zhCN)
        // 每行「错误 → 应当作为码值处理的字符串」。
        let cases: [(label: String, error: Error, code: String)] = [
            ("APIError 已知码", APIError.failed("SESSION_NOT_FOUND"), "SESSION_NOT_FOUND"),
            ("APIError 未知码", APIError.failed("诊断信息"), "诊断信息"),
            ("APIError 空响应", APIError.emptyResponse("photo.list_page"), "EMPTY_RESPONSE:photo.list_page"),
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
                APIErrorPresentation.userFacingMessage(for: item.error, with: l10n) == l10n.errorText(item.code),
                Comment(rawValue: item.label)
            )
        }
        // SessionServiceError 分支的码值不能被 NSError 桥接吞掉；两个入口语义
        // 已合并为同一漏斗（B8.4 起 userFacingMessage 就是 message 的别名）。
        #expect(APIErrorPresentation.message(for: SessionServiceError.sessionNotFound, with: l10n)
            == APIErrorPresentation.userFacingMessage(for: SessionServiceError.sessionNotFound, with: l10n))
        #expect(APIErrorPresentation.message(for: SessionServiceError.sessionNotFound, with: l10n)
            == l10n.errorText("SESSION_NOT_FOUND"))
        }
    }

    /// Cut 4 / 4a-3b-2b 政策：码形错误沿用旧漏斗；散文（中英文）只进 diagnostic，
    /// 渲染期回退通用文案。矩阵同时覆盖 Gather/API/Router/Bridge/C1/NSError。
    @MainActor
    @Test("CommandError：码形错误按码翻译，散文只进 diagnostic")
    func commandErrorSeparatesCodeAndProse() {
        let generic = L10n(language: .zhCN).errorText("NOT_A_CODE")
        let matrix: [Error] = [
            APIError.failed("SESSION_NOT_FOUND"),
            APIError.failed("XMP_CONFIRM_OTHER_SESSION_PENDING: s1"),
            APIError.failed("FILTER_FIELD_UNKNOWN::rating"),
            APIError.failed("诊断信息"),
            APIError.failed(""),
            APIError.emptyResponse("photo.list_page"),
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
                let mapped = CommandError(error)
                let resolved = CommandErrorText.resolve(mapped, with: L10n(language: .zhCN))
                if let c1 = error as? CaptureOneBridgeError {
                    // CommandError 新增 C1 分支（旧漏斗只会回退通用文案）。
                    #expect(mapped.code == c1.description, label)
                    #expect(resolved == L10n(language: .zhCN).errorText(c1.description), label)
                    continue
                }
                if CommandError.isKnownErrorCode(mapped.code) {
                    #expect(resolved == APIErrorPresentation.message(for: error, with: L10n(language: .zhCN)), label)
                } else {
                    #expect(resolved == generic, label)
                    #expect(!mapped.diagnostic.isEmpty || String(describing: error).isEmpty, label)
                }
            }
        }
    }

    /// 修复有效性差分：Gallery 旧漏斗（NSError 桥接）对码型输入回退通用文案，
    /// 新漏斗保留码值 —— 证明新增断言能捕获旧实现（不是放宽断言）。
    /// Persons 的 message(_:) 是 private，其行为在 PersonsViewModelTests 里按 VM 断言。
    @MainActor
    @Test("Gallery 旧 NSError 漏斗丢码、新漏斗保留（修复有效性）")
    func legacyNSErrorOnlyFunnelLosesCode() {
        let l10n = L10n(language: .zhCN)
        let legacy: (Error) -> String = { error in
            let nsError = error as NSError
            let raw = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
            return l10n.errorText(raw)
        }
        let generic = l10n.errorText("NOT_A_CODE")
        let inputs: [Error] = [
            BridgeError.notFound("PERSON_NOT_FOUND"),
            APIError.failed("SESSION_NOT_FOUND"),
            SessionServiceError.sourceRootForbidden,
            APIError.failed("XMP_CONFIRM_OTHER_SESSION_PENDING: s1"),
        ]
        AppLanguageLock.withStableCopy {
            for error in inputs {
                let label = Comment(rawValue: String(describing: error))
                let mapped = APIErrorPresentation.userFacingMessage(for: error, with: l10n)
                #expect(mapped != generic, label)
                #expect(legacy(error) == generic, label)
                #expect(CommandErrorText.resolve(CommandError(error), with: l10n) == mapped, label)
            }
        }
    }
}

/// Cut 4 / 4a-3b-1：`CommandError` + 渲染期 `CommandErrorText.resolve` 与旧漏斗
/// `APIErrorPresentation.message` 在**码形错误**上逐点等价（固定 zh-CN 文案）。
///
/// 非码形中文散文不走这条等价（渲染期按本地化 key 上屏，属 Face 既有语义），
/// 已在 FaceKeywordingViewModelTests 单独覆盖。
@MainActor
@Test("CommandErrorText.resolve：码形错误的渲染结果与旧漏斗逐点一致")
func commandErrorResolveMatchesLegacyFunnel() {
    let matrix: [Error] = [
        APIError.failed("SESSION_NOT_FOUND"),
        APIError.failed("XMP_CONFIRM_OTHER_SESSION_PENDING: s1"),
        APIError.failed("FILTER_FIELD_UNKNOWN::rating"),
        APIError.failed(""),
        RouterCommandError(message: "PERSON_NOT_FOUND"),
        BridgeError.notFound("SESSION_NOT_FOUND"),
        BridgeError.notImplemented("dup.groups"),
        SessionServiceError.sessionNotFound,
        SessionServiceError.sourceRootForbidden,
        NSError(domain: "t", code: 1),
        NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "SESSION_NOT_FOUND"]),
        CaptureOneBridgeError.notRunning,
    ]
    let l10n = L10n(language: .zhCN)
    AppLanguageLock.withStableCopy {
        for error in matrix {
            let label = Comment(rawValue: String(describing: error))
            if let c1 = error as? CaptureOneBridgeError {
                #expect(
                    CommandErrorText.resolve(CommandError(error), with: l10n)
                        == l10n.errorText(c1.description),
                    label
                )
                continue
            }
            #expect(
                CommandErrorText.resolve(CommandError(error), with: l10n)
                    == APIErrorPresentation.message(for: error, with: l10n),
                label
            )
        }
    }
}
