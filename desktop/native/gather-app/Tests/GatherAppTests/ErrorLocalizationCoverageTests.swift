import Foundation
import Testing
import GatherCore
@testable import GatherApp

/// 错误码 ↔ 本地化文案的**交叉契约**（core 枚举 ↔ app 文案表）。
///
/// 两个方向的脱节都会造成用户可见缺陷，而此前没有任何用例守着：
/// - **有码无文案** → `errorText` 落通用兜底，用户看到"发生未知错误，请稍后重试"；
/// - **有文案无码** → 生产者在枚举外自造裸字符串当码（绕过类型检查与契约测试）。
/// 实测：后者已抓到 2 例（`C1_SCRIPT_TIMEOUT` / `C1_NO_SELECTED_PHOTOS` 曾只存在于
/// 桥接层字符串里，已收进 `GatherErrorCode`）。
@Suite("错误码本地化交叉契约（core ↔ app）")
struct ErrorLocalizationCoverageTests {
    @Test("每个错误码都必须有本地化文案（否则 UI 只剩通用兜底）")
    func everyErrorCodeHasLocalizedMessage() {
        // 文案表断言与切语言的套件互斥（appLanguage 是进程级全局量）。
        AppLanguageLock.withStableCopy {
            let fallback = GatherLocalization.errorText("__NOT_A_REAL_CODE__")
            var missing: [String] = []
            for code in GatherErrorCode.allCases {
                let text = GatherLocalization.errorText(code.rawValue)
                if text.isEmpty || text == fallback { missing.append(code.rawValue) }
            }
            #expect(missing.isEmpty, "以下错误码缺少文案，UI 会显示通用兜底：\(missing)")
        }
    }

    @Test("文案表不得含枚举之外的码（防生产者自造裸码字符串）")
    func localizedMessageTableHasNoOrphanCodes() {
        AppLanguageLock.withStableCopy {
            let codes = Set(GatherErrorCode.allCases.map(\.rawValue))
            let orphans = GatherLocalization.errorMessages.keys.filter { !codes.contains($0) }.sorted()
            #expect(orphans.isEmpty, "文案表存在枚举之外的码（可能有裸字符串生产者）：\(orphans)")
        }
    }
}
