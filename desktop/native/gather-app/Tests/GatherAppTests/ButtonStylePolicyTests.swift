// desktop/native/gather-app/Tests/GatherAppTests/ButtonStylePolicyTests.swift
// 按钮门禁：页面层只允许语义角色，不允许直接挑系统按钮样式。
// 例外：DesignSystem（角色实现/浮层组件）与 PreviewSupport（预览画布）。
import Foundation
import Testing

@Suite("按钮样式门禁")
struct ButtonStylePolicyTests {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test("页面不得直接使用 bordered / prominent / glass / link")
    func pagesUseSemanticButtons() throws {
        let pattern = try NSRegularExpression(
            pattern: #"\.buttonStyle\s*\(\s*\.(bordered|borderedProminent|glass|glassProminent|link)\b"#
        )
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
                  !url.path.contains("/PreviewSupport/") else { continue }
            scannedFiles += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let stripped = try Self.maskingComments(text)
            buttonCount += max(0, stripped.components(separatedBy: "Button(").count - 1)
            let ns = stripped as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            for match in pattern.matches(in: stripped, range: fullRange) {
                guard let range = Range(match.range, in: stripped) else { continue }
                let line = stripped[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append(url.path + ":" + String(line))
            }
        }
        #expect(scannedFiles > 200, "扫描文件数异常（\(scannedFiles)），路径假设可能失效")
        #expect(buttonCount > 500, "扫描到的 Button 数量异常（\(buttonCount)），门禁可能空转")
        if !offenders.isEmpty {
            print("按钮门禁命中：" + offenders.sorted().joined(separator: ", "))
        }
        #expect(offenders.isEmpty, "页面直接写了系统按钮样式，请改用 .gatherButton(...)")
    }

    /// 用等长空白遮盖注释，保留换行与字符偏移，避免行号漂移。
    private static func maskingComments(_ text: String) throws -> String {
        var result = text
        let block = try NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
        let blockRanges = block.matches(
            in: result,
            range: NSRange(location: 0, length: (result as NSString).length)
        )
        for match in blockRanges.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let blank = String(result[range].map { $0 == "\n" ? "\n" : " " })
            result.replaceSubrange(range, with: blank)
        }
        let line = try NSRegularExpression(pattern: #"(?m)(?<!:)//.*$"#)
        let lineRanges = line.matches(
            in: result,
            range: NSRange(location: 0, length: (result as NSString).length)
        )
        for match in lineRanges.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let blank = String(repeating: " ", count: result[range].count)
            result.replaceSubrange(range, with: blank)
        }
        return result
    }
}
