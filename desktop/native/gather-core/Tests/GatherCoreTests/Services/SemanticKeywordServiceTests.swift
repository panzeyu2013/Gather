// desktop/native/gather-core/Tests/GatherCoreTests/Services/SemanticKeywordServiceTests.swift
// Wave2 / task-14：场景标签 → 关键词的映射与计划（幂等：已有路径不重复加）。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherApplication

@Suite("场景标签写回关键词")
struct SemanticKeywordServiceTests {
    private func label(_ text: String, _ confidence: Double) -> SemanticLabel {
        SemanticLabel(label: text, confidence: confidence)
    }

    @Test("标签规范化：下划线换空格、压空白、拒绝空串、去掉层级分隔符、截断")
    func normalizeLabel() {
        #expect(SemanticKeywordService.normalizeLabel("Wedding_Ceremony") == "wedding ceremony")
        #expect(SemanticKeywordService.normalizeLabel("  beach  sunset ") == "beach sunset")
        #expect(SemanticKeywordService.normalizeLabel("   ") == nil)
        #expect(SemanticKeywordService.normalizeLabel("a|b") == "a b")
        let long = String(repeating: "x", count: 60)
        let normalized = SemanticKeywordService.normalizeLabel(long)
        #expect(normalized?.count == SemanticKeywordPath.maxLabelLength)
    }

    @Test("映射：按置信度降序取前 N、大小写去重、拼成 root||label")
    func keywordPaths() {
        let paths = SemanticKeywordService.keywordPaths(
            labels: [
                label("beach", 0.3),
                label("Wedding", 0.9),
                label("wedding", 0.8),
                label("outdoor", 0.5),
            ],
            root: "AI|场景",
            maxPerPhoto: 2)
        #expect(paths == ["AI|场景|wedding", "AI|场景|outdoor"])
        #expect(SemanticKeywordService.keywordPaths(labels: [], root: "AI|场景") == [])
        #expect(SemanticKeywordService.keywordPaths(
            labels: [label("beach", 0.9)], root: "", maxPerPhoto: 3) == [])
        #expect(SemanticKeywordService.keywordPaths(
            labels: [label("beach", 0.9)], root: "AI|场景", maxPerPhoto: 0) == [])
    }

    @Test("计划只包含缺失的关键词；同一张再跑一次 totalAdditions=0（幂等）")
    func buildPlanIsIdempotent() throws {
        let labels: [String: [SemanticLabel]] = [
            "p1": [label("beach", 0.9), label("sunset", 0.8)],
            "p2": [label("wedding", 0.9)],
            "p3": [],
        ]
        var current: [String: [String]] = [
            "p1": ["AI|场景|beach"],   // 已有一个：计划里只应出现 sunset
            "p2": [],
        ]
        let first = try SemanticKeywordService.buildPlan(
            sessionId: "s1", root: "AI|场景", scope: ["p1", "p2", "p3"],
            labelsByPhoto: labels,
            currentPaths: { current[$0] ?? [] },
            maxLabelsPerPhoto: 6,
            semanticsAvailable: true)

        #expect(first.photosWithLabels == 2)
        #expect(first.photosWithoutLabels == 1)
        #expect(first.totalAdditions == 2)
        let p1 = try #require(first.items.first { $0.photoId == "p1" })
        #expect(p1.keywords == ["AI|场景|sunset"])
        #expect(p1.alreadyPresent == false)

        // 模拟写回成功后索引已更新：第二次计划必须全空（不重复加词）。
        current["p1"] = ["AI|场景|beach", "AI|场景|sunset"]
        current["p2"] = ["AI|场景|wedding"]
        let second = try SemanticKeywordService.buildPlan(
            sessionId: "s1", root: "AI|场景", scope: ["p1", "p2", "p3"],
            labelsByPhoto: labels,
            currentPaths: { current[$0] ?? [] },
            maxLabelsPerPhoto: 6,
            semanticsAvailable: true)
        #expect(second.totalAdditions == 0)
        #expect(second.items.allSatisfy { $0.alreadyPresent })
    }

    @Test("计划明细按 maxItems 截断，计数仍是全量（Wave4b）")
    func buildPlanTruncatesItems() throws {
        let labels: [String: [SemanticLabel]] = [
            "p1": [label("beach", 0.9)],
            "p2": [label("wedding", 0.9)],
            "p3": [label("sunset", 0.9)],
        ]
        let scope = ["p1", "p2", "p3"]
        let full = try SemanticKeywordService.buildPlan(
            sessionId: "s1", root: "AI|场景", scope: scope,
            labelsByPhoto: labels,
            currentPaths: { _ in [] },
            maxLabelsPerPhoto: 6,
            maxItems: 0,
            semanticsAvailable: true)
        #expect(full.items.count == 3)
        #expect(full.itemsTruncated == false)

        let truncated = try SemanticKeywordService.buildPlan(
            sessionId: "s1", root: "AI|场景", scope: scope,
            labelsByPhoto: labels,
            currentPaths: { _ in [] },
            maxLabelsPerPhoto: 6,
            maxItems: 1,
            semanticsAvailable: true)
        #expect(truncated.items.count == 1, "明细上限生效")
        #expect(truncated.itemsTruncated, "截断必须显式标记（UI 提示明细不全）")
        #expect(truncated.totalAdditions == 3, "计数必须按全量算")
        #expect(truncated.photosWithLabels == 3)
        #expect(truncated.items.first?.photoId == "p1", "截断保留 scope 顺序")
    }

    @Test("语义索引缺失时计划带 unavailableReason（UI 显示原因，不当错误）")
    func planWithoutSemantics() {
        let plan = SemanticKeywordService.buildPlan(
            sessionId: "s1", root: "AI|场景", scope: ["p1"],
            labelsByPhoto: [:],
            currentPaths: { _ in [] },
            maxLabelsPerPhoto: 6,
            semanticsAvailable: false)
        #expect(plan.totalAdditions == 0)
        #expect(plan.unavailableReason != nil)
    }

    @Test("撤销范围只认 root 子树：前缀相同的兄弟命名空间不能被误删")
    func undoScope() {
        #expect(SemanticKeywordService.isUnder("AI|场景|beach", root: "AI|场景"))
        #expect(SemanticKeywordService.isUnder("AI|场景", root: "AI|场景"))
        #expect(!SemanticKeywordService.isUnder("AI|场景2|beach", root: "AI|场景"))
        #expect(!SemanticKeywordService.isUnder("AI|人物|张三", root: "AI|场景"))
        #expect(!SemanticKeywordService.isUnder("客户|场景|beach", root: "AI|场景"))
    }
}
