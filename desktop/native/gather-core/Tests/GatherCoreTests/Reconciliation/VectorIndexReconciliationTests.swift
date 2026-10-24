// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/VectorIndexReconciliationTests.swift
// 角度 LSH 的默认套件行为测试。
//
// 质量/召回基线（原 1000 行 × 100 查询、TS 参照召回 >= 0.5）已迁到
// gather-core-benchmarks；默认套件不再承担“近似算法有多准”的评估，只验证：
//   · 非法配置明确报错；
//   · 空索引查询返回空；
//   · 小索引对自身行做候选查询能稳定自召回（索引接线正确）。
// exact/暴力对照与召回率由 benchmark 的 lsh phase 负责。

import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct VectorIndexReconciliationTests {
    @Test func rejectsInvalidConfigurations() throws {
        #expect(throws: VectorIndexError.invalidDimension(0)) {
            _ = try CosineLshIndex(dim: 0)
        }
        #expect(throws: VectorIndexError.invalidBits(4)) {
            _ = try CosineLshIndex(dim: 128, config: LshConfig(bits: 4))
        }
        #expect(throws: VectorIndexError.invalidTables(0)) {
            _ = try CosineLshIndex(dim: 128, config: LshConfig(tables: 0))
        }
        #expect(throws: VectorIndexError.invalidProbeRadius(3)) {
            _ = try CosineLshIndex(dim: 128, config: LshConfig(probeRadius: 3))
        }
    }

    @Test func emptyIndexBehaviors() throws {
        let lsh = try CosineLshIndex(dim: 8)
        try lsh.build(rows: [], count: 0)
        let hits = try lsh.neighbors(
            query: [Float](repeating: 0, count: 8), threshold: 0.6)
        #expect(hits.count == 0)
        #expect(lsh.size == 0)
        #expect(CosineLshIndex.lshMinPoints == 20_000)
    }

    @Test func smallIndexReturnsEachRowAsItsOwnCandidate() throws {
        let dim = 8
        let count = 4
        var rows = [Float](repeating: 0, count: count * dim)
        for index in 0..<count { rows[index * dim + index] = 1 }

        let lsh = try CosineLshIndex(
            dim: dim,
            config: LshConfig(
                bits: 16, tables: 8, probeRadius: 2, seed: 42, unitVectors: true))
        try lsh.build(rows: rows, count: count)
        #expect(lsh.size == count)

        // 自召回是确定性的：同一向量必然落回同一桶；不在这里测“近邻召回率”。
        for index in 0..<count {
            let hits = try lsh.neighbors(
                query: rows, queryOffset: index * dim, threshold: 0.9)
            #expect(hits.indices.contains(index), "row \(index) 必须被自身查询召回")
        }
    }
}
