// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel+ErrorText.swift
// Cut 4 / 4c-2j：从 LibraryViewModel.swift 移出错误码文案（原 771-795 行）。
// 纯搬移：码形门槛、参数化码判定、未知码日志与通用文案回退逐字未动。
import Foundation
import GatherProtocol

extension LibraryViewModel {

    // MARK: 错误文案（Cut 4 / 4a-3b-2b）

    /// 错误码（全大写 ASCII + _ . : -）→ errorText 表；其它一律记日志 + 通用文案。
    static func userFacingText(for raw: String, with l10n: L10n) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return l10n(L10n.unknownErrorKey) }
        let code = trimmed.components(separatedBy: "::")[0]
        let looksLikeCode = !code.isEmpty
            && code.allSatisfy { $0.isUppercase || $0.isNumber || "_.:-".contains($0) }
        // 码形门槛只认大写 ASCII：Core 侧「已知码: 参数」（如
        // XMP_CONFIRM_OTHER_SESSION_PENDING: s1）会被误判成散文而丢掉 {{param}}
        // 插值，故补一条「首冒号前段命中错误表」的判定（与 errorText 同构）。
        // 未知码/散文仍不猜（负例见 LibraryViewModelTests 的两个参数化用例）。
        let parameterizedCode = CommandError.isParameterizedErrorCode(trimmed)
        guard looksLikeCode || parameterizedCode else {
            GatherLogger.log("library error is not an error code: \(trimmed)", level: .warn)
            return l10n(L10n.unknownErrorKey)
        }
        let generic = l10n(L10n.unknownErrorKey)
        let text = l10n.errorText(trimmed)
        if text == generic {
            GatherLogger.log("library error code not mapped: \(trimmed)", level: .warn)
        }
        return text
    }
}
