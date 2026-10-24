// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/ClusterReconciliationTests.swift
// dHash 聚类对账测试（Phase 1 任务 1.5「对账测试框架」第二批）。
// fixture 是冻结的 TS 参照（seed 固定、随仓库入库的静态 golden；生成器已随旧栈
// 删除），本测试逐 case 加载比对；变更 golden 必须人工签核并在评审里给依据。
// 自含 fixture 加载（经 #filePath 定位 Fixtures 目录），不依赖并行任务文件。

import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct ClusterReconciliationTests {

    private struct Fixture: Decodable {
        let seed: Int
        let cases: [ClusterCase]
        let multiCases: [MultiCase]

        struct ClusterCase: Decodable {
            let name: String
            let mode: String
            let threshold: Int
            let minGroupSize: Int
            let entries: [HashEntryValue]
            let expected: ClusterResultValue
        }

        struct MultiCase: Decodable {
            let name: String
            let mode: String
            let thresholds: [Int]
            let minGroupSize: Int
            let entries: [HashEntryValue]
            let expected: [ClusterResultValue]
        }

        struct HashEntryValue: Decodable {
            let photoId: String
            let hash: String
        }

        struct ClusterResultValue: Decodable {
            let groups: [[String]]
            let ungrouped: [String]
        }
    }

    private static func loadFixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("cluster-fixtures.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    private static func mode(from raw: String) -> HashGroupingMode {
        raw == "sequential" ? .sequential : .global
    }

    private static func entries(from values: [Fixture.HashEntryValue]) -> [HashEntry] {
        values.map { HashEntry(photoId: $0.photoId, hash: $0.hash) }
    }

    /// Cut 5 / 5b-2a：唯一实现 = ClusterGraphPipeline（global 单趟图 / sequential 相邻段）。
    private static func cluster(
        _ entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        mode: HashGroupingMode
    ) throws -> ClusterResult {
        try ClusterGraphPipeline.run(
            entries: entries,
            threshold: threshold,
            minGroupSize: minGroupSize,
            mode: mode
        ).result
    }

    // 单阈值：golden fixture（cluster-fixtures.json）逐组/逐成员/组序逐位一致。
    @Test func pipelineMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.cases {
            let result = try Self.cluster(
                Self.entries(from: c.entries),
                threshold: c.threshold,
                minGroupSize: c.minGroupSize,
                mode: Self.mode(from: c.mode))
            #expect(result.groups == c.expected.groups, "case \(c.name): groups")
            #expect(result.ungrouped == c.expected.ungrouped, "case \(c.name): ungrouped")
        }
    }

    // 多阈值：每层结果与 fixture 期望一致（global 走多档并集行）。
    @Test func pipelineTiersMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.multiCases {
            let results = try ClusterGraphPipeline.runTiers(
                entries: Self.entries(from: c.entries),
                thresholds: c.thresholds,
                minGroupSize: c.minGroupSize,
                mode: Self.mode(from: c.mode))
            #expect(results.count == c.expected.count, "case \(c.name): 层数")
            for (index, tier) in c.expected.enumerated() {
                #expect(results[index].groups == tier.groups, "case \(c.name) tier \(index): groups")
                #expect(results[index].ungrouped == tier.ungrouped, "case \(c.name) tier \(index): ungrouped")
            }
        }
    }

    // 超大规模回退（streaming 图，n > defaultMaxBitsetEntries 时启用）与位集图
    // 在同一阈值下必须给出相同分量与分组：用完整度数序列构造 streaming 图，
    // 逐组（含组序/组内序）比对。原用例比的是 recomputedBfs（已删）。
    @Test func streamingPathAgreesWithBitsetPath() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.cases where c.mode == "global" {
            let entries = Self.entries(from: c.entries)
            let table = try HashGraphTable(hashes: entries.map { $0.hash })
            let full = HashNeighborhoodGraph(table: table, threshold: c.threshold)
            let streaming = StreamingNeighborhoodGraph(
                table: table, threshold: c.threshold, degrees: full.degreeSequence)
            #expect(
                DegreeGatedBFS.components(of: streaming) == DegreeGatedBFS.components(of: full),
                "case \(c.name): streaming 与位集分量不一致")
            #expect(
                DegreeGatedBFS.groups(of: streaming, minGroupSize: c.minGroupSize)
                    == DegreeGatedBFS.groups(of: full, minGroupSize: c.minGroupSize),
                "case \(c.name): streaming 与位集分组不一致")
        }
    }
}
