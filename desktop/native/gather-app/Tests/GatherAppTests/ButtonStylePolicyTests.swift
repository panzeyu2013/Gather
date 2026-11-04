// desktop/native/gather-app/Tests/GatherAppTests/ButtonStylePolicyTests.swift
// 按钮门禁：页面层只允许语义角色，不允许直接挑系统按钮样式。
// 例外：DesignSystem（角色实现/浮层组件）与 PreviewSupport（预览画布）。
//
// 2026-10-31 appearance 合并后补强（原实现只做反向扫描，正则写坏会静默全绿）：
// - 加正/负样本自检：门禁自己先红，避免"改了正则、门禁空转"；
// - 遮罩改为单遍词法（行注释 / 可嵌套块注释 / 字符串 / 多行字符串 / 原始字符串）：
//   旧实现用两条正则分别遮块注释与行注释，字符串里的 "https://…" 会把本行余下
//   代码一起抹掉，真违规反而漏检；
// - 裸 Button 计数排除 gatherButton( 子串（旧实现把 helper 调用也数成按钮）。
import Foundation
import Testing

@Suite("按钮样式门禁")
struct ButtonStylePolicyTests {
    /// 禁止的直接样式：bordered / borderedProminent / glass / glassProminent / link，
    /// 以及直接构造样式类型（.buttonStyle(BorderedProminentButtonStyle())）。
    private static let bannedStyle = #"(?m)\.buttonStyle\s*\(\s*\.?(borderedProminent|bordered|glassProminent|glass|link)\b|\.buttonStyle\s*\(\s*(BorderedProminentButtonStyle|BorderedButtonStyle|GlassProminentButtonStyle|GlassButtonStyle|LinkButtonStyle)\s*\("#

    /// 裸 Button( 的计数正则：排除标识符前缀，避免把 gatherButton( 数成按钮。
    private static let bareButton = #"(?<![A-Za-z0-9_])Button\("#

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test("页面不得直接使用 bordered / prominent / glass / link")
    func pagesUseSemanticButtons() throws {
        var offenders: [String] = []
        var scannedFiles = 0
        var buttonCount = 0
        let enumerator = FileManager.default.enumerator(
            at: Self.sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  !url.path.contains("/DesignSystem/"),
                  !url.path.contains("/PreviewSupport/"),
                  !url.path.contains("/GatherPreviewData/") else { continue }
            scannedFiles += 1
            let text = Self.masked(try String(contentsOf: url, encoding: .utf8))
            buttonCount += Self.matches(of: Self.bareButton, in: text).count
            offenders.append(contentsOf: try Self.violations(in: text, in: url.path))
        }
        #expect(scannedFiles > 200, "扫描文件数异常（\(scannedFiles)），路径假设可能失效")
        #expect(buttonCount > 250, "扫描到的裸 Button 数量异常（\(buttonCount)），门禁可能空转")
        if !offenders.isEmpty {
            print("按钮门禁命中：" + offenders.sorted().joined(separator: ", "))
        }
        #expect(offenders.isEmpty, "页面直接写了系统按钮样式，请改用 .gatherButton(...)")
    }

    @Test("门禁正则命中禁止写法，同时放过语义角色")
    func policyRegexKeepsBothSamples() throws {
        // 正样本：任何一条漏检都说明正则被改坏。
        let banned = [
            ".buttonStyle(.bordered)",
            ".buttonStyle(.borderedProminent)",
            ".buttonStyle( .glass )",
            ".buttonStyle(.link)",
            ".buttonStyle(BorderedProminentButtonStyle())",
            ".buttonStyle(\n    .bordered\n)",
        ]
        for sample in banned {
            let found = try Self.violations(in: Self.masked(sample), in: "sample")
            #expect(found.count == 1, "漏检禁止写法：\(sample)")
        }
        // 负样本：语义角色与允许的图标语法不得被误判。
        let allowed = [
            ".gatherButton(.primary)",
            ".gatherButton(.secondary, size: .small)",
            ".gatherIconButton()",
            ".gatherViewerButton()",
            ".buttonStyle(.borderless)",
            ".buttonStyle(.plain)",
            ".menuStyle(.borderlessButton)",
        ]
        for sample in allowed {
            let found = try Self.violations(in: Self.masked(sample), in: "sample")
            #expect(found.isEmpty, "误伤允许写法：\(sample) → \(found)")
        }
    }

    @Test("注释与字符串里的样式名不参与判定")
    func maskingIgnoresCommentsAndStrings() throws {
        // 用普通字面量拼，避免在测试里再嵌一层 """ """（Swift 不允许未转义嵌套）。
        let commented = [
            "// 页面不要写 .buttonStyle(.bordered)",
            "/* 也不要写 .buttonStyle(.borderedProminent)",
            "   嵌套 /* .buttonStyle(.glass) */ 同样不算 */",
            "let hint = \"这里写 .buttonStyle(.bordered) 只是文案\"",
            "let multiline = \"\"\"",
            "    文档里出现 .buttonStyle(.glassProminent) 也不算什么",
            "    \"\"\"",
        ].joined(separator: "\n")
        let found = try Self.violations(in: Self.masked(commented), in: "sample")
        #expect(found.isEmpty, "注释/字符串里的样式名被当成违规：\(found)")

        // 同一行里先有含 // 的字符串、后面才是真违规：字符串被抹掉，真违规必须留下。
        let mixed = #"let s = "https://x//y"; Button("a") {}.buttonStyle(.bordered)"#
        let mixedFound = try Self.violations(in: Self.masked(mixed), in: "sample")
        #expect(mixedFound.count == 1, "同一行字符串之后的真违规必须命中：\(mixedFound)")

        // 遮罩必须逐字符等长（行号来自字符偏移，长度一变行号就漂）。
        #expect(Self.masked(commented).count == commented.count)
    }

    // MARK: - 内部工具

    private static func violations(in text: String, in label: String) throws -> [String] {
        // 正则写坏属于门禁自身故障：显式抛错，不能静默当成 0 命中。
        let regex = try NSRegularExpression(pattern: bannedStyle)
        return matches(of: regex, in: text).map { range in
            let line = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
            return label + ":" + String(line)
        }
    }

    private static func matches(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return matches(of: regex, in: text)
    }

    private static func matches(of regex: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Range($0.range, in: text) }
    }

    /// 单遍词法遮罩：把注释与字符串内容替换成等长空格（保留换行），让正则只看真正的代码。
    static func masked(_ text: String) -> String {
        let chars = Array(text)
        var out = chars
        let n = chars.count
        var i = 0
        func blank(_ start: Int, _ end: Int) {
            guard start <= end, start < n else { return }
            for k in start...min(end, n - 1) where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = chars[i]
            // 多行字符串 """…"""：先查三连引号，否则会被当成空字符串。
            if c == "\"", i + 2 < n, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                var j = i + 3
                while j + 2 <= n - 1 {
                    if chars[j] == "\"", chars[j + 1] == "\"", chars[j + 2] == "\"" {
                        j += 3
                        break
                    }
                    j += 1
                }
                blank(i, j - 1)
                i = max(j, i + 3)
                continue
            }
            // 原始字符串 #"…"#
            if c == "#", i + 1 < n, chars[i + 1] == "\"" {
                var j = i + 2
                while j + 1 <= n - 1 {
                    if chars[j] == "\"", chars[j + 1] == "#" {
                        j += 2
                        break
                    }
                    j += 1
                }
                blank(i, j - 1)
                i = max(j, i + 2)
                continue
            }
            // 行注释
            if c == "/", i + 1 < n, chars[i + 1] == "/" {
                var j = i
                while j < n, chars[j] != "\n" { j += 1 }
                blank(i, j - 1)
                i = max(j, i + 1)
                continue
            }
            // 块注释（支持嵌套）
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var depth = 0
                var j = i
                while j < n {
                    if chars[j] == "/", j + 1 < n, chars[j + 1] == "*" {
                        depth += 1
                        j += 2
                        continue
                    }
                    if chars[j] == "*", j + 1 < n, chars[j + 1] == "/" {
                        depth -= 1
                        j += 2
                        if depth == 0 { break }
                        continue
                    }
                    j += 1
                }
                blank(i, j - 1)
                i = max(j, i + 1)
                continue
            }
            // 普通字符串
            if c == "\"" {
                var j = i + 1
                var escaped = false
                while j < n {
                    if escaped {
                        escaped = false
                        j += 1
                        continue
                    }
                    if chars[j] == "\\" {
                        escaped = true
                        j += 1
                        continue
                    }
                    if chars[j] == "\"" {
                        j += 1
                        break
                    }
                    if chars[j] == "\n" { break }
                    j += 1
                }
                blank(i, j - 1)
                i = max(j, i + 1)
                continue
            }
            i += 1
        }
        return String(out)
    }
}
