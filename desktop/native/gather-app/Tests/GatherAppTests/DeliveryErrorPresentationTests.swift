// desktop/native/gather-app/Tests/GatherAppTests/DeliveryErrorPresentationTests.swift
// Delivery P2：11 个新增错误码的 UI 映射契约。
//
// 覆盖：
// 1. 每个码在 zh/en 都有独立文案（英文不回落中文）；
// 2. 备份路径类 9 码都标记为「需先修复备份」，原样重试不会自愈；
// 3. finalize incompleteItems 指向对应模块，重试不会跳过；
// 4. replay claim 是瞬态跳过，可稍后重试；
// 5. CommandError / APIErrorPresentation 保留码值、映射文案并暴露恢复动作；
// 6. 带参数形态不把路径/模块名带上屏（模板无占位符）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("Delivery P2 错误码展示（备份路径 / 收尾 / replay claim）")
struct DeliveryErrorPresentationTests {
    private let zh = L10n(language: .zhCN)
    private let en = L10n(language: .en)

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }

    @Test("11 个新码都有独立中英文文案，英文不回落中文")
    func everyCodeHasDedicatedMessageInBothLanguages() {
        let zhFallback = zh.errorText("__NOT_A_DELIVERY_CODE__")
        let enFallback = en.errorText("__NOT_A_DELIVERY_CODE__")
        #expect(DeliveryErrorPresentation.allCodes.count == 11)
        for code in DeliveryErrorPresentation.allCodes {
            let zhText = zh.errorText(code)
            let enText = en.errorText(code)
            #expect(zhText != zhFallback, "\(code) 缺中文文案")
            #expect(enText != enFallback, "\(code) 缺英文文案")
            #expect(!containsCJK(enText), "\(code) 的英文文案回落中文：\(enText)")
            #expect(enText != zhText, "\(code) 的英文文案与中文相同")
        }
    }

    @Test("备份路径类 9 码：说明需先修复备份，原样重试不会自愈")
    func backupPathCodesRequireRepair() {
        let codes = DeliveryErrorPresentation.allCodes.filter { $0.contains("BACKUP_PATH") }
        #expect(codes.count == 9)
        for code in codes {
            guard let info = DeliveryErrorPresentation.info(for: code) else {
                Issue.record("\(code) 未登记")
                continue
            }
            #expect(info.recovery == .repairBackup, "\(code) 的恢复动作")
            #expect(info.retryableAsIs == false, "\(code) 不应被当作可原样重试")
            let text = zh.errorText(code)
            #expect(text.contains("备份") || text.contains("XMP 路径"), "\(code) 文案未说明对象")
            #expect(
                text.contains("重试") || text.contains("修复") || text.contains("再试")
                    || text.contains("恢复"),
                "\(code) 文案未给出下一步")
        }
    }

    @Test("finalize incompleteItems：指向对应模块，重试不会跳过")
    func incompleteItemsPointsToOwningModule() {
        let code = "XMP_FINALIZE_INCOMPLETE_ITEMS"
        guard let info = DeliveryErrorPresentation.info(for: code) else {
            Issue.record("\(code) 未登记")
            return
        }
        #expect(info.recovery == .resolveItems)
        #expect(info.retryableAsIs == false)
        let text = zh.errorText(code)
        #expect(text.contains("未完成"))
        #expect(text.contains("对应模块"))
        #expect(text.contains("不会跳过"))
    }

    @Test("replay claim：跳过是瞬态，可稍后重试")
    func replayClaimedIsTransient() {
        let code = "XMP_CLEANUP_REPLAY_CLAIMED"
        guard let info = DeliveryErrorPresentation.info(for: code) else {
            Issue.record("\(code) 未登记")
            return
        }
        #expect(info.recovery == .waitForOtherReplay)
        #expect(info.retryableAsIs)
        let text = zh.errorText(code)
        #expect(text.contains("跳过"))
        #expect(text.contains("稍后刷新"))
    }

    @Test("恢复动作标题在 zh/en 都可解析")
    func recoveryTitlesAreLocalized() {
        for recovery in DeliveryErrorRecovery.allCases {
            let zhTitle = recovery.title(with: zh)
            let enTitle = recovery.title(with: en)
            #expect(!zhTitle.isEmpty, "\(recovery) 缺中文标题")
            #expect(!containsCJK(enTitle), "\(recovery) 的英文标题回落中文：\(enTitle)")
        }
    }

    @Test("CommandError / APIErrorPresentation 保留新码并暴露恢复动作")
    func commandAndAPIErrorSurfaceRecovery() {
        let raw = "XMP_CLEANUP_BACKUP_PATH_INVALID: /Users/x/IMG_1.xmp reason=XMP_BACKUP_PATH_TRAVERSAL"
        #expect(CommandError.isKnownErrorCode(raw))

        let command = CommandError(apiText: raw)
        #expect(command.code == raw)
        #expect(command.recoveryAction == .repairBackup)
        #expect(command.retryable == false)
        #expect(CommandErrorText.resolve(command, with: zh)
            == zh.errorText("XMP_CLEANUP_BACKUP_PATH_INVALID"))

        let api = APIError.failed(raw)
        #expect(APIErrorPresentation.message(for: api, with: zh)
            == zh.errorText("XMP_CLEANUP_BACKUP_PATH_INVALID"))
        #expect(APIErrorPresentation.recovery(for: api) == .repairBackup)
        #expect(APIErrorPresentation.recoveryTitle(for: api, with: zh) == zh("检查并修复备份"))

        let replay = CommandError(apiText: "XMP_CLEANUP_REPLAY_CLAIMED: #3")
        #expect(replay.code == "XMP_CLEANUP_REPLAY_CLAIMED: #3")
        #expect(replay.retryable)
        #expect(replay.recoveryAction == .waitForOtherReplay)
    }

    @Test("带参数的新码只显示模板，不把路径/模块串上屏")
    func parameterizedRawDoesNotLeakDetails() {
        let raw = "XMP_FINALIZE_INCOMPLETE_ITEMS: metadata:pending"
        let text = zh.errorText(raw)
        #expect(text == zh.errorText("XMP_FINALIZE_INCOMPLETE_ITEMS"))
        #expect(!text.contains("metadata"))
        #expect(!text.contains("pending"))
    }
}
