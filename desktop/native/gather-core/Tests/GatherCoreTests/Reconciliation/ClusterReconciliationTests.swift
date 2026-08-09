// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/ClusterReconciliationTests.swift
// dHash 聚类对账测试（Phase 1 任务 1.5「对账测试框架」第二批）。
// fixture 由 scripts/reconciliation/generate-cluster-fixtures.mjs 生成
// （参照实现 = cluster-engine.ts 照抄核心循环），本测试逐 case 加载比对。
// 自含 fixture 加载（经 #filePath 定位 Fixtures 目录），不依赖并行任务文件。

import Foundation
import Testing
@testable import GatherCore

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

    // 单阈值：bitset 路径（默认 maxBitsetEntries）与 fixture 期望逐位一致
    @Test func clusterByHashMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.cases {
            let result = try ClusterEngine.clusterByHash(
                entries: Self.entries(from: c.entries),
                threshold: c.threshold,
                minGroupSize: c.minGroupSize,
                mode: Self.mode(from: c.mode))
            #expect(result.groups == c.expected.groups, "case \(c.name): groups")
            #expect(result.ungrouped == c.expected.ungrouped, "case \(c.name): ungrouped")
        }
    }

    // 多阈值：每层结果与 fixture 期望一致
    @Test func clusterByHashMultiMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.multiCases {
            let results = try ClusterEngine.clusterByHashMulti(
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

    // 重算路径（maxBitsetEntries 强制小输入走 recomputedBfs）与 bitset 路径
    // 的分组一致：fixture 用例不含「稀疏节点索引先于簇种子」的边角差异，
    // 两路径输出同一连通分量划分，仅组内顺序可能不同（stack BFS vs wave BFS），
    // 故按成员排序后比对。
    @Test func recomputedPathAgreesWithBitsetPath() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.cases where c.mode == "global" {
            let entries = Self.entries(from: c.entries)
            let expected = try ClusterEngine.clusterByHash(
                entries: entries,
                threshold: c.threshold,
                minGroupSize: c.minGroupSize,
                mode: .global)
            let recomputed = try ClusterEngine.clusterByHash(
                entries: entries,
                threshold: c.threshold,
                minGroupSize: c.minGroupSize,
                mode: .global,
                maxBitsetEntries: 2)
            #expect(recomputed.groups.count == expected.groups.count, "case \(c.name): 组数")
            for (index, group) in expected.groups.enumerated() {
                #expect(recomputed.groups[index].sorted() == group.sorted(), "case \(c.name): 组 \(index) 成员集合")
            }
            #expect(recomputed.ungrouped.sorted() == expected.ungrouped.sorted(), "case \(c.name): ungrouped 集合")
        }
    }
}
