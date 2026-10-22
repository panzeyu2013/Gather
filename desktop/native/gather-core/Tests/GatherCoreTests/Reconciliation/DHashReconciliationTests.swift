// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/DHashReconciliationTests.swift
// dHash 双向对账测试（Phase 1 任务 1.5 首批函数）。
//
// fixture 由 scripts/reconciliation/generate-hash-fixtures.mjs 产出并入库
// （seed=42, 50 cases，含全零/全一/重复行/边界值/相邻等值/随机网格），
// 本测试加载同一 JSON，逐 case 以 DHash.compute 重算并与 TS 期望 hex 比对。
// 扩展新函数：见同目录 README.md。

import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct DHashReconciliationTests {
    @Test func fixtureMatchesTSGeneratorOutput() throws {
        let data = try FixtureLoader.loadJSON(named: "dhash-fixtures.json")
        let fixture = try JSONDecoder().decode(DHashFixture.self, from: data)

        #expect(fixture.seed == 42)
        #expect(fixture.cases.count == 50)

        for (index, case_) in fixture.cases.enumerated() {
            #expect(case_.pixels.count == 72, "case \(index) 像素数 != 72")
            #expect(case_.expected.count == 16, "case \(index) hex 长度 != 16")
            let actual = DHash.compute(pixels9x8: case_.pixels)
            #expect(
                actual == case_.expected,
                "case \(index) 漂移：Swift \(actual) != TS \(case_.expected)",
            )
        }
    }

    // 说明（2026-09 测试精简）：原先的「全零网格」「全一网格」两条手工边界用例
    // 已删除——fixture 的 case 0（全零像素）/ case 1（全 255 像素）与它们输入
    // 完全相同、期望 hex 同为 "0000000000000000"，且 fixture 用例额外断言
    // 像素数 == 72 与 hex 长度 == 16（覆盖严格更强）。
    // 承接覆盖：fixtureMatchesTSGeneratorOutput 的 case 0 / case 1。
}
