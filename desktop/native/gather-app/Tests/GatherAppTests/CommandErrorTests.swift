// desktop/native/gather-app/Tests/GatherAppTests/CommandErrorTests.swift
// Cut 4 / 4a-0：错误载体的映射与渲染期解析。
//
// 关键约束（审计 §2.4）：CommandError.init 只搬运码/参数/诊断，不查表、
// 不格式化；"CODE::p1::p2" 与 "CODE: 散文" 的双形态解析在 L10n 渲染时做。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("CommandError 错误载体")
struct CommandErrorTests {
    // MARK: - 映射（不查表）

    @Test("GatherError：保留码值与重试策略，不翻译成文案")
    func mapsGatherError() {
        let notFound = CommandError(GatherError(code: .SESSION_NOT_FOUND))
        #expect(notFound.code == "SESSION_NOT_FOUND")
        #expect(notFound.params.isEmpty)
        #expect(notFound.diagnostic.isEmpty)
        #expect(!notFound.retryable)
        // 不查表：码不得变成中文文案
        #expect(!notFound.code.contains("工作区"))

        let timeout = CommandError(GatherError(code: .C1_SCRIPT_TIMEOUT))
        #expect(timeout.code == "C1_SCRIPT_TIMEOUT")
        #expect(timeout.retryable)
    }

    @Test("GatherError：params 按模板占位符顺序稳定，underlying 进诊断")
    func mapsGatherErrorParams() {
        let error = GatherError(
            code: .CULLING_REVISION_CONFLICT,
            params: ["current": "5", "expected": "3"],
            underlying: "revision mismatch"
        )
        let mapped = CommandError(error)
        #expect(mapped.code == "CULLING_REVISION_CONFLICT")
        // 字典无序：expected 必须排在 current 前，否则插值串参数
        #expect(mapped.params == ["3", "5"])
        #expect(mapped.diagnostic == "revision mismatch")
        #expect(!mapped.retryable)
    }

    @Test("GatherError：Host 侧 expectedRevision/currentRevision 前缀键仍按占位符顺序")
    func ordersHostSideRevisionKeys() {
        // LiveCullingAPI 用「expectedRevision/currentRevision」键；渲染期插值必须
        // 期望在前、当前在后，否则两个版本号串位（旧漏斗不插值，这个错位不可见）。
        let error = GatherError(
            code: .CULLING_REVISION_CONFLICT,
            params: ["expectedRevision": "1", "currentRevision": "2"]
        )
        let mapped = CommandError(error)
        #expect(mapped.params == ["1", "2"])
        #expect(L10n(language: .zhCN).errorText(mapped) == "挑片版本冲突：期望 1，当前 2")
    }

    @Test("SessionServiceError：映射 gatherCode（不走 NSError 桥接）")
    func mapsSessionServiceError() {
        #expect(CommandError(SessionServiceError.sessionNotFound).code == "SESSION_NOT_FOUND")
        #expect(CommandError(SessionServiceError.sourceNotDir).code == "SESSION_SOURCE_NOT_DIR")
        #expect(!CommandError(SessionServiceError.deleteNotConfirmed).retryable)
    }

    @Test("APIError：已知码原样保留；未知码/散文只进 diagnostic（4a-3b-2b）")
    func mapsAPIError() {
        let coded = CommandError(APIError.failed("EXPORT_DIR_INVALID"))
        #expect(coded.code == "EXPORT_DIR_INVALID")
        #expect(coded.params.isEmpty)
        #expect(coded.diagnostic.isEmpty)
        #expect(coded.origin == .api)

        let parameterized = CommandError(APIError.failed("CULLING_REVISION_CONFLICT::3::5"))
        #expect(parameterized.code == "CULLING_REVISION_CONFLICT::3::5")
        #expect(parameterized.params.isEmpty)

        let unknown = CommandError(APIError.emptyResponse("status"))
        #expect(unknown.code.isEmpty)
        #expect(unknown.diagnostic == "EMPTY_RESPONSE:status")
    }

    @Test("RouterCommandError：message 原样进入 code")
    func mapsRouterError() {
        #expect(CommandError(RouterCommandError(message: "SESSION_NOT_FOUND")).code == "SESSION_NOT_FOUND")
    }

    @Test("NSError：散文只进 diagnostic，code 留空（不直接上屏）")
    func mapsNSError() {
        let error = NSError(
            domain: "GatherTestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "disk offline"]
        )
        let mapped = CommandError(error)
        #expect(mapped.code.isEmpty)
        #expect(mapped.diagnostic == "disk offline")
        #expect(mapped.params.isEmpty)
        #expect(!mapped.retryable)
    }

    @Test("自定义 init：四个字段原样保存")
    func customInit() {
        let error = CommandError(code: "X_CODE", params: ["1", "2"], diagnostic: "detail", retryable: true)
        #expect(error.code == "X_CODE")
        #expect(error.params == ["1", "2"])
        #expect(error.diagnostic == "detail")
        #expect(error.retryable)
        #expect(error.origin == .api, "直接构造默认按 API 诊断处理")

        let local = CommandError.localized("「%@」不能为空", params: ["名称"])
        #expect(local.origin == .localValidation)
    }

    @Test("相等性：code/params/diagnostic/retryable 全量比较")
    func equality() {
        #expect(CommandError(code: "A") == CommandError(code: "A"))
        #expect(CommandError(code: "A") != CommandError(code: "B"))
        #expect(CommandError(code: "A", params: ["1"]) != CommandError(code: "A", params: ["2"]))
        #expect(CommandError(code: "A", diagnostic: "d") != CommandError(code: "A"))
        #expect(CommandError(code: "A", retryable: true) != CommandError(code: "A"))
    }

    // MARK: - 渲染期解析（L10n 双形态）

    @Test("L10n：CODE::p1::p2 按模板占位符顺序插值")
    func doubleColonForm() {
        #expect(
            L10n(language: .zhCN).errorText("CULLING_REVISION_CONFLICT::3::5")
                == "挑片版本冲突：期望 3，当前 5"
        )
    }

    @Test("L10n：CODE: 散文 把冒号后的内容作为单参数")
    func singleColonForm() {
        let text = L10n(language: .zhCN).errorText("CULLING_REVISION_CONFLICT: 7")
        #expect(text.contains("期望 7"))
        #expect(text.hasPrefix("挑片版本冲突"))
    }

    @Test("L10n：未知码与散文回退通用文案（中英各自查表）")
    func unknownFallback() {
        #expect(L10n(language: .zhCN).errorText("NOT_A_REAL_CODE") == "发生未知错误，请稍后重试")
        #expect(
            L10n(language: .en).errorText("NOT_A_REAL_CODE")
                == "Something went wrong. Please try again later."
        )
        #expect(L10n(language: .zhCN).errorText("磁盘挂了") == "发生未知错误，请稍后重试")
        #expect(L10n(language: .zhCN).errorText("") == "发生未知错误，请稍后重试")
    }

    @Test("L10n：已知码按目标语言渲染，不读进程全局")
    func languageSpecific() {
        #expect(L10n(language: .zhCN).errorText("SESSION_NOT_FOUND") == "工作区不存在")
        #expect(L10n(language: .en).errorText("SESSION_NOT_FOUND") == "Workspace not found")
    }

    @Test("L10n：CommandError 的 params 参与插值，diagnostic 不上屏")
    func rendersCommandError() {
        let error = CommandError(
            code: "CULLING_REVISION_CONFLICT",
            params: ["3", "5"],
            diagnostic: "internal detail"
        )
        let text = L10n(language: .zhCN).errorText(error)
        #expect(text == "挑片版本冲突：期望 3，当前 5")
        #expect(!text.contains("internal detail"))
    }

    @Test("L10n：GatherError 全链路（码 + params → 当前语言文案）")
    func gatherErrorPipeline() {
        let error = GatherError(
            code: .CULLING_REVISION_CONFLICT,
            params: ["expected": "9", "current": "11"]
        )
        #expect(L10n(language: .zhCN).errorText(CommandError(error)) == "挑片版本冲突：期望 9，当前 11")
    }

    // MARK: - 渲染期入口（CommandErrorText，Cut 4 / 4a-3b-1）

    @Test("CommandErrorText：已知码走码表（含 {{param}} 插值）")
    func resolveKnownCode() {
        let error = CommandError(code: "CULLING_REVISION_CONFLICT", params: ["3", "5"])
        #expect(CommandErrorText.resolve(error, with: L10n(language: .zhCN)) == "挑片版本冲突：期望 3，当前 5")
        #expect(
            CommandErrorText.resolve(error, with: L10n(language: .en))
                == "Culling revision conflict: expected 3, current 5"
        )
    }

    @Test("CommandErrorText：界面本地文案按 key 本地化，并按顺序插入参数")
    func resolveLocalCopy() {
        // 观测到的 VM 本地校验文案：中文原文即本地化 key（含 %lld 占位）。
        let error = CommandError.localized(
            "请选择当前相似度组中 1 至 %lld 张照片",
            params: ["4"]
        )
        let zh = CommandErrorText.resolve(error, with: L10n(language: .zhCN))
        #expect(zh == "请选择当前相似度组中 1 至 4 张照片")
        // 未提供参数时占位符替换为空串（不崩溃、不泄漏 %lld）。
        let empty = CommandErrorText.resolve(
            CommandError.localized("请选择当前相似度组中 1 至 %lld 张照片"),
            with: L10n(language: .zhCN)
        )
        #expect(!empty.contains("%lld"))
        // 有 en 译文的 key 走译文（%@ 参数原样插入）。
        #expect(
            CommandErrorText.resolve(CommandError.localized("模型目录不可用"), with: L10n(language: .en))
                == "Model directory unavailable"
        )
    }

    @Test("CommandErrorText：未知码/英文诊断回退通用文案，中文可读原因上屏")
    func resolveFallback() {
        let zh = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(CommandError(code: "NOT_A_REAL_CODE"), with: zh) == zh.errorText("NOT_A_CODE"))
        #expect(
            CommandErrorText.resolve(
                CommandError(code: "", diagnostic: "Failed to load model at /tmp/x"),
                with: zh
            ) == zh.errorText("NOT_A_CODE")
        )
        // 4a-3b-2b 政策：API 的中文散文只进 diagnostic，不再上屏。
        let apiChinese = CommandError(APIError.failed("人脸嵌入模型不存在：/tmp/a.mlmodelc"))
        #expect(apiChinese.code.isEmpty)
        #expect(apiChinese.diagnostic.contains("人脸嵌入模型不存在"))
        #expect(CommandErrorText.resolve(apiChinese, with: zh) == zh.errorText("NOT_A_CODE"))
        // VM 本地校验（.localized）仍可上屏；带裸 '%' 时不进 String(format:)。
        #expect(
            CommandErrorText.resolve(CommandError.localized("人脸嵌入模型不存在：/tmp/a.mlmodelc"), with: zh)
                == "人脸嵌入模型不存在：/tmp/a.mlmodelc"
        )
        #expect(
            CommandErrorText.resolve(CommandError.localized("模型路径 100% 不存在"), with: zh)
                == "模型路径 100% 不存在"
        )
    }

    @Test("LocalizedText：构造只存 key/params，渲染时按语言查表并插值")
    func localizedTextResolvesAtRenderTime() {
        let notice = LocalizedText(
            "挑片版本冲突：期望 {{expected}}，当前 {{current}}",
            params: ["1", "2"]
        )
        #expect(notice.resolved(with: L10n(language: .zhCN)) == "挑片版本冲突：期望 1，当前 2")
        #expect(notice.resolved(with: L10n(language: .en)) == "Culling revision conflict: expected 1, current 2")

        #expect(LocalizedText("工作区不存在") == LocalizedText("工作区不存在"))
        #expect(LocalizedText("工作区不存在") != LocalizedText("发生未知错误，请稍后重试"))
        #expect(LocalizedText("a", params: ["1"]) != LocalizedText("a", params: ["2"]))
    }

    @Test("notice 渲染：%@ / %lld 模板随语言切换，未知 key 回退原文")
    func noticeTemplatesResolveAtRenderTime() {
        // 6 个 notice 的两种历史模板形态：%@（取消动作名）与 %lld（计数）。
        let cancelled = LocalizedText("已取消“%@”，未执行任何更改", params: ["删除照片"])
        #expect(cancelled.resolved(with: L10n(language: .zhCN)) == "已取消“删除照片”，未执行任何更改")
        #expect(cancelled.resolved(with: L10n(language: .en)) == "Cancelled “删除照片”; nothing was changed")

        let updated = LocalizedText("已更新 %lld 张照片", params: ["3"])
        #expect(updated.resolved(with: L10n(language: .zhCN)) == "已更新 3 张照片")
        #expect(updated.resolved(with: L10n(language: .en)) == "Updated 3 photos")

        // 未命中本地化表（诊断原文）→ 原样返回 key，不吞成通用错误。
        let raw = LocalizedText("Failed to load model at /tmp/x")
        #expect(raw.resolved(with: L10n(language: .en)) == "Failed to load model at /tmp/x")
        #expect(raw.resolved(with: L10n(language: .zhCN)) == "Failed to load model at /tmp/x")

        // 同一 LocalizedText 不缓存语言：切换 L10n 即换文案（渲染期解析）。
        let l10n = L10n(language: .zhCN)
        #expect(updated.resolved(with: l10n) == "已更新 3 张照片")
        #expect(updated.resolved(with: L10n(language: .en)) == "Updated 3 photos")
    }
}
