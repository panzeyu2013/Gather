// desktop/native/gather-core/Tests/GatherCoreTests/Services/TriageWritebackPlanTests.swift
// P1 / E：写回计划——三条产品红线（不动人工、rating 只写空值、关键词默认不写）。

import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

@Suite("triage 写回计划")
struct TriageWritebackPlanTests {
    @Test("keep/reject 映射 3/1 星；未评分才写")
    func ratingMapping() {
        let keep = TriageWritebackPlanner.plan(
            photoId: "p1", verdict: "keep", currentRating: 0,
            manuallyDecided: false, policy: .ratingOnlyWhenEmpty
        )
        #expect(keep?.rating == 3)
        #expect(keep?.keyword == nil, "默认不写关键词")
        #expect(keep?.namespaceValue == "keep")

        let reject = TriageWritebackPlanner.plan(
            photoId: "p2", verdict: "REJECT", currentRating: 0,
            manuallyDecided: false, policy: .ratingOnlyWhenEmpty
        )
        #expect(reject?.rating == 1)
        #expect(reject?.namespaceValue == "reject")
    }

    @Test("人工已决策或已有星级 → 不写 rating，但仍记录私有命名空间")
    func neverOverrideHuman() {
        let manual = TriageWritebackPlanner.plan(
            photoId: "p1", verdict: "keep", currentRating: 0,
            manuallyDecided: true, policy: .ratingOnlyWhenEmpty
        )
        #expect(manual?.rating == nil)
        #expect(manual?.namespaceValue == "keep")

        let rated = TriageWritebackPlanner.plan(
            photoId: "p2", verdict: "reject", currentRating: 5,
            manuallyDecided: false, policy: .ratingOnlyWhenEmpty
        )
        #expect(rated?.rating == nil)
    }

    @Test("关键词只在显式策略下写；off 策略整体不产出")
    func keywordPolicy() {
        let withKeyword = TriageWritebackPlanner.plan(
            photoId: "p1", verdict: "keep", currentRating: 0,
            manuallyDecided: false, policy: .ratingAndKeyword
        )
        #expect(withKeyword?.keyword == TriageWritebackPlanner.keywordKeep)

        let off = TriageWritebackPlanner.plan(
            photoId: "p1", verdict: "keep", currentRating: 0,
            manuallyDecided: false, policy: .off
        )
        #expect(off == nil)
    }

    @Test("未知 verdict 不产出决策；批量保持顺序")
    func unknownVerdictAndBatch() {
        #expect(TriageWritebackPlanner.plan(
            photoId: "p1", verdict: "maybe", currentRating: 0,
            manuallyDecided: false, policy: .ratingOnlyWhenEmpty
        ) == nil)

        let batch = TriageWritebackPlanner.planBatch(
            photos: [("p1", "keep", 0, false), ("p2", "maybe", 0, false), ("p3", "reject", 0, false)],
            policy: .ratingOnlyWhenEmpty
        )
        #expect(batch.map(\.photoId) == ["p1", "p3"])
    }

    @Test("API 输入层：非法 verdict / 重复 photoId / 超量 items 一律显式失败")
    func inputValidation() throws {
        // 大小写不敏感 + trim，归一到小写（planner 只认 keep/reject）。
        let item = try TriageWritebackItem(photoId: "p1", verdict: " Keep ")
        #expect(item.verdict == "keep")

        #expect(throws: GatherError.self) {
            _ = try TriageWritebackItem(photoId: "p1", verdict: "maybe")
        }
        #expect(throws: GatherError.self) {
            _ = try TriageWritebackItem(photoId: "  ", verdict: "keep")
        }
        #expect(throws: GatherError.self) {
            _ = try TriageWritebackInput(policy: .ratingOnlyWhenEmpty, items: [])
        }
        let duplicate = try TriageWritebackItem(photoId: "p1", verdict: "keep")
        #expect(throws: GatherError.self) {
            _ = try TriageWritebackInput(policy: .ratingOnlyWhenEmpty,
                                         items: [duplicate, duplicate])
        }
        // 上限 100k（覆盖大库全会话写回）：超过即显式失败。
        let overflow = try (0...100_000).map {
            try TriageWritebackItem(photoId: "p\($0)", verdict: "keep")
        }
        #expect(throws: GatherError.self) {
            _ = try TriageWritebackInput(policy: .ratingOnlyWhenEmpty, items: overflow)
        }
    }
}
