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

    /// en.lproj 的 key 是**中文原文**（errorText 的查表路径是
    /// errorMessages[code] → l(中文值)），所以按错误码写的 en 条目永远查不到。
    private var stringsFileURL: URL {
        URL(fileURLWithPath: #filePath)          // …/gather-app/Tests/GatherAppTests/x.swift
            .deletingLastPathComponent()          // …/Tests/GatherAppTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/gather-app
            .appendingPathComponent("Resources/en.lproj/Localizable.strings")
    }

    /// 极简 .strings 解析（够用即可：本仓条目都是单行 "key" = "value"; 形式）。
    private func parseStrings(_ url: URL) -> [String: String] {
        var table: [String: String] = [:]
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return table }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let separator = line.range(of: "\" = \"") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            var value = String(line[separator.upperBound...])
            if value.hasSuffix(";") { value.removeLast() }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasSuffix("\"") { value.removeLast() }
            table[key] = value
        }
        return table
    }

    @Test("英文文案表必须覆盖错误码文案的每个中文 key（否则英文界面显示中文）")
    func englishTableCoversEveryErrorMessage() {
        AppLanguageLock.withStableCopy {
            let table = parseStrings(stringsFileURL)
            #expect(!table.isEmpty, "读不到 en.lproj/Localizable.strings（路径假设失效，请更新本用例）")
            let missing = GatherLocalization.errorMessages.values
                .filter { table[$0] == nil }
                .sorted()
            #expect(missing.isEmpty, "以下错误文案缺英文条目（英文界面会显示中文）：\(missing.prefix(10))")
        }
    }

    @Test("英文文案的占位符序列必须与中文 key 一致（错位会让 String(format:) 取错参数）")
    func englishPlaceholdersMatchKeys() {
        let table = parseStrings(stringsFileURL)
        #expect(!table.isEmpty)
        // %% 是转义百分号，必须先整体吃掉，否则 "%% scroll" 会被误判成 %s。
        let pattern = #"%(?:%|(?:(d+)$)?[-+ #0]*[d*]*(?:.[d*]+)?(?:hh|h|ll|l|L|z|j|t|q)?([@dioufFeEgGxXscp]))"#
        let regex = try? NSRegularExpression(pattern: pattern)
        func specs(_ input: String) -> [String] {
            guard let regex else { return [] }
            let range = NSRange(input.startIndex..., in: input)
            return regex.matches(in: input, range: range).compactMap { match in
                guard let kind = Range(match.range(at: 2), in: input), !kind.isEmpty else { return nil }
                return String(input[kind])
            }
        }
        var mismatched: [String] = []
        for (key, value) in table where specs(key) != specs(value) {
            mismatched.append("\(key.prefix(30)) → \(specs(key)) vs \(specs(value))")
        }
        #expect(mismatched.isEmpty, "占位符序列不一致（会取错参数/崩溃）：\(mismatched.sorted().prefix(8))")
    }
}
