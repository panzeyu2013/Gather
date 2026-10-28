// desktop/native/gather-core/Tests/GatherCoreTests/Queries/PhotoVisibilityGateTests.swift
// P2：archived_at 的可见性判定只能来自 PhotoVisibility（SQL 与 Swift 两侧）。
//
// 背景：可见性最初靠各查询/服务手写 "archived_at IS NULL" 或 "archivedAt == nil"，
// 新增读面漏一处就会把 _rejects 里的照片重新暴露出来（或让计数与网格不一致）。
// 本用例是静态门禁：core/app 两个 Sources 树里出现裸谓词即失败。
//
// 排除项：
// - PhotoVisibility.swift 本身是唯一实现；
// - SchemaCurrent* 的 DDL 注释（-- 开头）是文档，不是查询谓词。

import Foundation
import Testing

@Suite("照片可见性谓词门禁")
struct PhotoVisibilityGateTests {
    @Test("全仓 Sources 不得手写 archived_at / archivedAt 可见性谓词")
    func rawPredicatesAreCentralized() throws {
        let sqlPredicate = try NSRegularExpression(
            pattern: #"(?i)archived_at\s+IS\s+(NOT\s+)?NULL"#)
        let swiftPredicate = try NSRegularExpression(
            pattern: #"archivedAt\s*(==|!=)\s*nil"#)
        let testFile = URL(fileURLWithPath: #filePath)
        // Queries → GatherCoreTests → Tests → gather-core
        let coreRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            coreRoot.appendingPathComponent("Sources"),
            coreRoot.deletingLastPathComponent()
                .appendingPathComponent("gather-app/Sources"),
        ]
        var offenders: [String] = []
        var scanned = 0
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else {
                Issue.record("扫描根不存在：\(root.path)")
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let name = url.lastPathComponent
                if name == "PhotoVisibility.swift" || name.hasPrefix("SchemaCurrent") {
                    continue
                }
                let text: String
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    Issue.record("无法读取源码文件 \(url.path)：\(error)")
                    continue
                }
                scanned += 1
                for (index, line) in text.split(
                    separator: "\n", omittingEmptySubsequences: false
                ).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                    let text = String(line)
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    guard sqlPredicate.firstMatch(in: text, range: range) != nil
                        || swiftPredicate.firstMatch(in: text, range: range) != nil
                    else { continue }
                    offenders.append("\(url.path):\(index + 1): \(trimmed)")
                }
            }
        }
        #expect(scanned >= 400,
                "只扫描到 \(scanned) 个 Swift 文件，门禁疑似空转（扫描根失效）")
        #expect(offenders.isEmpty,
                "裸 archived_at/archivedAt 谓词必须改走 PhotoVisibility：\(offenders.joined(separator: " | "))")
    }
}
