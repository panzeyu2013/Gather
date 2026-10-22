// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/VectorIndexReconciliationTests.swift
// 角度 LSH 对账测试（Phase 2 任务 2.3「向量移植」）。
// fixture 由 scripts/reconciliation/generate-vector-fixtures.mjs 生成（参照实现 =
// lsh-index.ts 全类照抄），本测试加载同一 JSON 逐 case 比对：
//   - LSH：Swift 侧重建索引并复算 eps 邻域召回（口径照抄
//     face-clusterer-lsh.test.ts measureNeighborRecall），断言 >= fixture 的
//     TS 召回（弱桶另设 > 0.4 门限，同 face-clusterer-lsh.test.ts:348-353）。
//   - 边界：空索引、配置校验错误、LSH_MIN_POINTS 常量。
//
// Cut 5 / 5b-2a：HNSW（CosineHnswIndex）已删除，本文件的 HNSW 对账段、
// 维度/配置校验的 HNSW 断言与 fixture 的 HnswSection 解码一并删除；套件从
// “默认跳过（GATHER_RECONCILIATION_VECTOR=1）”改为默认运行——LSH 对账是
// 毫秒级，不再需要 gate。
// Cut 5 / 5d-1：fixture JSON 的 hnsw 段（2,418 行）与生成器里的 HNSW 参照实现
// 已删除，生成脚本只产 LSH 段（--check 与入库 fixture 逐字节一致）；解码器
// 不再有 HnswSection，fixture 也不再有 hnsw 键。
//
// LSH 召回容差 0.005：Swift 与 TS 的 libm（exp/log/cos）理论上可有 1 ulp
// 级差异，导致个别近零超平面投影翻转哈希位——候选集只会收缩、实测差异为 0，
// 容差仅为防御性。

import Foundation
import Testing
@testable import GatherDomain
@testable import GatherProtocol
@testable import GatherAnalysis

struct VectorIndexReconciliationTests {

    private struct Fixture: Decodable {
        let dim: Int
        let numRows: Int
        let numQueries: Int
        let rows: [Float]
        let queries: [Float]
        let lsh: LshSection

        struct LshSection: Decodable {
            let config: LshConfigValue
            let eps: Double
            let sampleSize: Int
            let recall: RecallValue
        }

        struct LshConfigValue: Decodable {
            let bits: Int
            let tables: Int
            let probeRadius: Int
            let seed: UInt32
            let unitVectors: Bool
        }

        struct RecallValue: Decodable {
            let total: Double
            let perBucket: [BucketValue]
        }

        struct BucketValue: Decodable {
            let range: String
            let recall: Double
            let pairs: Int
        }
    }

    private static func loadFixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("vector-fixtures.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    // MARK: LSH 对账

    @Test func lshRecallAtEpsMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        let lsh = try CosineLshIndex(
            dim: fixture.dim,
            config: LshConfig(
                bits: fixture.lsh.config.bits,
                tables: fixture.lsh.config.tables,
                probeRadius: fixture.lsh.config.probeRadius,
                seed: fixture.lsh.config.seed,
                unitVectors: fixture.lsh.config.unitVectors))
        #expect(lsh.size == 0)
        try lsh.build(rows: fixture.rows, count: fixture.numRows)
        #expect(lsh.size == fixture.numRows, "LSH size 应等于 build 行数")

        let measured = try Self.measureNeighborRecall(lsh: lsh, fixture: fixture)
        // 总召回：>= fixture 的 TS 召回（另满足 >= 0.95 门限中的 0.5 兜底，
        // 同 face-clusterer-lsh.test.ts:342-343 的 > 0.5 门）。
        #expect(
            measured.total >= fixture.lsh.recall.total - 0.005,
            "LSH 总召回应不低于 TS 参照（fixture=\(fixture.lsh.recall.total), Swift=\(measured.total)）")
        #expect(measured.total >= 0.5, "LSH 总召回门限")
        for (index, bucket) in fixture.lsh.recall.perBucket.enumerated() where bucket.pairs > 0 {
            #expect(
                measured.buckets[index] >= bucket.recall - 0.02,
                "bucket \(bucket.range): Swift=\(measured.buckets[index]) 低于 fixture=\(bucket.recall)")
        }
    }

    // face-clusterer-lsh.test.ts:227-272 的 measureNeighborRecall（Swift 侧复算）
    private static func measureNeighborRecall(
        lsh: CosineLshIndex,
        fixture: Fixture
    ) throws -> (total: Double, buckets: [Double]) {
        let n = fixture.numRows
        let dim = fixture.dim
        let eps = fixture.lsh.eps
        let sampleSize = fixture.lsh.sampleSize
        var stats: [(min: Double, max: Double, recalled: Int, total: Int)] = [
            (eps, 0.65, 0, 0),
            (0.65, 0.7, 0, 0),
            (0.7, 0.8, 0, 0),
            (0.8, 0.9, 0, 0),
            (0.9, 1.01, 0, 0),
        ]
        var recallTotal = 0
        var pairsTotal = 0
        for s in 0..<sampleSize {
            let pointIndex = (s * 7919) % n
            let exact = exactNeighbors(rows: fixture.rows, n: n, dim: dim, pointIndex: pointIndex, eps: eps)
            let hits = try lsh.neighbors(query: fixture.rows, queryOffset: pointIndex * dim, threshold: eps)
            var lshSet = Set<Int>()
            for h in 0..<hits.count where hits.indices[h] != pointIndex {
                lshSet.insert(hits.indices[h])
            }
            for neighbor in exact {
                guard let bucket = stats.firstIndex(where: {
                    neighbor.score >= $0.min && neighbor.score < $0.max
                }) else { continue }
                stats[bucket].total += 1
                if lshSet.contains(neighbor.index) {
                    stats[bucket].recalled += 1
                    recallTotal += 1
                }
                pairsTotal += 1
            }
        }
        let buckets = stats.map { $0.total > 0 ? Double($0.recalled) / Double($0.total) : 1 }
        let total = pairsTotal > 0 ? Double(recallTotal) / Double(pairsTotal) : 1
        return (total, buckets)
    }

    // face-clusterer-lsh.test.ts:200-225（精确邻域扫描）
    private static func exactNeighbors(
        rows: [Float],
        n: Int,
        dim: Int,
        pointIndex: Int,
        eps: Double
    ) -> [(index: Int, score: Double)] {
        var result: [(index: Int, score: Double)] = []
        let pointOffset = pointIndex * dim
        for i in 0..<n where i != pointIndex {
            let dot = dot(rows, pointOffset, i * dim, dim)
            if dot >= eps { result.append((i, dot)) }
        }
        return result
    }

    // 与 TS exactNeighbors/verifyCandidates 同序的浮点点积
    //（Float32 读入、Double 累加、每 4 维一组展开）
    private static func dot(_ rows: [Float], _ aOffset: Int, _ bOffset: Int, _ dim: Int) -> Double {
        dot(rows, aOffset, rows, bOffset, dim)
    }

    private static func dot(_ a: [Float], _ aOffset: Int, _ b: [Float], _ bOffset: Int, _ dim: Int) -> Double {
        var dot = 0.0
        var k = 0
        while k + 4 <= dim {
            dot += Double(a[aOffset + k]) * Double(b[bOffset + k])
                 + Double(a[aOffset + k + 1]) * Double(b[bOffset + k + 1])
                 + Double(a[aOffset + k + 2]) * Double(b[bOffset + k + 2])
                 + Double(a[aOffset + k + 3]) * Double(b[bOffset + k + 3])
            k += 4
        }
        while k < dim {
            dot += Double(a[aOffset + k]) * Double(b[bOffset + k])
            k += 1
        }
        return dot
    }

    // MARK: 边界与校验

    @Test func rejectsInvalidConfigurations() throws {
        // LSH（lsh-index.ts:133-144 同口径）
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
        // 空 LSH：build(0) 后邻居查询返回空（lsh-index.ts:230-233 先判 count）
        let lsh = try CosineLshIndex(dim: 8)
        try lsh.build(rows: [], count: 0)
        let lshHits = try lsh.neighbors(query: [Float](repeating: 0, count: 8), threshold: 0.6)
        #expect(lshHits.count == 0)
        #expect(lsh.size == 0)

        // 常量对账（lsh-index.ts:49）
        #expect(CosineLshIndex.lshMinPoints == 20_000)
    }
}
