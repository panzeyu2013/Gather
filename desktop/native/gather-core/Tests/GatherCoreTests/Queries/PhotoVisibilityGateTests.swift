// desktop/native/gather-core/Tests/GatherCoreTests/Queries/PhotoVisibilityGateTests.swift
// P2：archived_at 的可见性判定只能来自 PhotoVisibility（SQL 与 Swift 两侧）。
//
// 背景：可见性最初靠各查询/服务手写 "archived_at IS NULL" 或 "archivedAt == nil"，
// 新增读面漏一处就会把 _rejects 里的照片重新暴露出来（或让计数与网格不一致）。
// 本用例是静态门禁：core/app 两个 Sources 树里出现裸谓词即失败。
//
// 覆盖范围（比第一版宽）：
// - SQLite 的三种等价写法都算：IS [NOT] NULL、ISNULL、NOTNULL，以及 ISNULL(col) 形式；
// - 在**整段文本**上匹配（不是逐行），所以跨行书写的谓词也能抓到；行号按匹配起点换算；
// - 注释行（// / * / --）不算谓词：DDL 里的说明与文档注释不触发；
// - 只豁免 PhotoVisibility.swift 本身（唯一实现）。
//
// 不计入本门禁的形态（已知限制）：
// - 字符串拼接后的谓词（例如 "archived_at" + " IS NULL"）：静态正则看不到运行期字符串；
// - archivedAt 的非比较用法（.map / if let / 直接透传）：这类读法不构成可见性判定，
//   由行为测试（PhotoVisibilityTests + 各服务用例）兜底。

import Foundation
import Testing

@Suite("照片可见性谓词门禁")
struct PhotoVisibilityGateTests {
    @Test("全仓 Sources 不得手写 archived_at / archivedAt 可见性谓词")
    func rawPredicatesAreCentralized() throws {
        let sqlPatterns = [
            #"(?i)archived_at\s+(?:IS\s+(?:NOT\s+)?NULL|ISNULL|NOTNULL)"#,
            #"(?i)(?:ISNULL|NOTNULL)\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\.?archived_at\s*\)"#,
        ]
        let sqlPredicates = try sqlPatterns.map { try NSRegularExpression(pattern: $0) }
        let swiftPredicate = try NSRegularExpression(
            pattern: #"archivedAt\s*(==|!=)\s*nil"#)
        let allPredicates = sqlPredicates + [swiftPredicate]
        // 运行期拼接（"archived_at" + " IS NULL"）本身抓不到，但**引号里的片段**可以：
        // 只含 archived_at 片段、没有 SQL 动词的字面量（列清单不会带 IS/=/<>）说明
        // 谓词是拼出来的。SELECT 里的 "… archived_at FROM" 含动词，不会误报。
        let quotedFragment = try NSRegularExpression(
            pattern: #""([^"]*archived_at[^"]*)""#)
        let sqlVerb = try NSRegularExpression(
            pattern: #"(?i)\b(select|update|insert|delete|where|join|set)\b"#)
        let fragmentPredicate = try NSRegularExpression(
            pattern: #"(?i)archived_at\s*(is|not\s+null|isnull|notnull|=|<>|!=)"#)

        let testFile = URL(fileURLWithPath: #filePath)
        // Queries -> GatherCoreTests -> Tests -> gather-core
        let coreRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // 只拿 gather-core 的单包 checkout 没有兄弟 app 目录：跳过 app 面而不是判失败；
        // 兄弟包在但 Sources 缺失 = 路径写错，仍由 exists 检查报红。
        let appPackage = coreRoot.deletingLastPathComponent()
            .appendingPathComponent("gather-app")
        var roots = [coreRoot.appendingPathComponent("Sources")]
        if FileManager.default.fileExists(atPath: appPackage.path) {
            roots.append(appPackage.appendingPathComponent("Sources"))
        }
        var offenders: [String] = []
        var scanned = 0
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else {
                Issue.record("扫描根不存在：\(root.path)")
                continue
            }
            var scannedInRoot = 0
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                // 唯一实现文件本身当然会命中；除此之外不设白名单。
                if url.lastPathComponent == "PhotoVisibility.swift" { continue }
                let text: String
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    Issue.record("无法读取源码文件 \(url.path)：\(error)")
                    continue
                }
                scannedInRoot += 1
                let source = text as NSString
                let fullRange = NSRange(location: 0, length: source.length)
                // 拼接片段：引号里带 archived_at 且带比较运算符、但没有 SQL 动词。
                // SchemaCurrent* 的 expected-columns 列表本身就是裸列名（DDL 元数据），
                // 不算拼接谓词；该文件仍受上面的主规则约束。
                let isSchemaDDL = url.lastPathComponent.hasPrefix("SchemaCurrent")
                if !isSchemaDDL {
                quotedFragment.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                    guard let match, let literalRange = Range(match.range, in: text) else { return }
                    let literal = String(text[literalRange])
                    let literalRangeNS = NSRange(literal.startIndex..<literal.endIndex, in: literal)
                    // 命中两种拼接：裸列名（"archived_at" + " IS NULL"）与
                    // 自带比较但没有 SQL 动词的片段（"AND archived_at IS NULL"）。
                    let bareColumn = literal
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased() == "archived_at"
                    let fragment = fragmentPredicate.firstMatch(
                        in: literal, range: literalRangeNS) != nil
                        && sqlVerb.firstMatch(in: literal, range: literalRangeNS) == nil
                    guard bareColumn || fragment else { return }
                    let lineRange = source.lineRange(
                        for: NSRange(location: match.range.location, length: 0))
                    let trimmed = source.substring(with: lineRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"),
                          !trimmed.hasPrefix("--") else { return }
                    let lineNumber = source
                        .substring(to: match.range.location)
                        .components(separatedBy: "\n").count
                    offenders.append("\(url.path):\(lineNumber): 拼接谓词 \(literal)")
                }
                }
                for predicate in allPredicates {
                    predicate.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                        guard let match else { return }
                        let lineRange = source.lineRange(
                            for: NSRange(location: match.range.location, length: 0))
                        let line = source.substring(with: lineRange)
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        // 注释不是谓词：// 文档注释、* 续行、-- SQL 注释（DDL 说明）。
                        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"),
                              !trimmed.hasPrefix("--") else { return }
                        let lineNumber = source
                            .substring(to: match.range.location)
                            .components(separatedBy: "\n").count
                        let snippet = source.substring(with: match.range)
                            .components(separatedBy: .newlines).joined(separator: " ")
                        offenders.append("\(url.path):\(lineNumber): \(snippet)")
                    }
                }
            }
            // 单棵源树的空转检测：只断言总数时，新增第三棵树或某棵树路径失效都会静默漏扫。
            #expect(scannedInRoot >= 100,
                    "扫描根 \(root.lastPathComponent) 只扫到 \(scannedInRoot) 个 Swift 文件，门禁疑似空转")
            scanned += scannedInRoot
        }
        #expect(scanned >= 400,
                "只扫描到 \(scanned) 个 Swift 文件，门禁疑似空转（扫描根失效）")
        #expect(offenders.isEmpty,
                "裸 archived_at/archivedAt 谓词必须改走 PhotoVisibility：\(offenders.joined(separator: " | "))")
    }
}
