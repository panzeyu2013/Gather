// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/VectorIndexReconciliationTests.swift
// 向量索引对账测试（Phase 2 任务 2.3「向量移植」）。
// fixture 由 scripts/reconciliation/generate-vector-fixtures.mjs 生成（参照
// 实现 = hnsw-index.ts / lsh-index.ts 全类照抄，语料构造 = hnsw-recall.test.ts
// 照抄），本测试加载同一 JSON 逐 case 比对：
//   - HNSW：逐查询 topK 索引列表与 fixture 完全一致；各节点层级（PRNG 流）
//     与 fixture 一致；searchByThreshold 对暴力精确点积抽查。
//   - LSH：Swift 侧重建索引并复算 eps 邻域召回（口径照抄
//     face-clusterer-lsh.test.ts measureNeighborRecall），断言 >= fixture 的
//     TS 召回（弱桶另设 > 0.4 门限，同 face-clusterer-lsh.test.ts:348-353）。
//   - 边界：空索引、维度/配置校验错误、LSH_MIN_POINTS 常量。
//
// 并列说明：fixture 生成器已断言每条查询的 topK 得分严格递减（随机实数
// 语料下并列概率为零，种子漂移时生成器即失败），故逐索引相等是良定义的口径。
// LSH 召回容差 0.005：Swift 与 TS 的 libm（exp/log/cos）理论上可有 1 ulp
// 级差异，导致个别近零超平面投影翻转哈希位——候选集只会收缩、实测差异为 0，
// 容差仅为防御性。

import Foundation
import Testing
@testable import GatherCore

struct VectorIndexReconciliationTests {

    private struct Fixture: Decodable {
        let dim: Int
        let numRows: Int
        let numQueries: Int
        let rows: [Float]
        let queries: [Float]
        let hnsw: HnswSection
        let lsh: LshSection

        struct HnswSection: Decodable {
            let config: HnswConfigValue
            let topK: Int
            let levels: [Int]
            let queriesTopK: [[Int]]
            let queriesTopKScores: [[Float]]
            let recallTop1: Double
        }

        struct HnswConfigValue: Decodable {
            let dim: Int
            let m: Int
            let mMax0: Int
            let efConstruction: Int
            let efSearch: Int
            let seed: UInt32
        }

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

    private static func hnswConfig(from value: Fixture.HnswConfigValue) -> HnswConfig {
        HnswConfig(
            dim: value.dim,
            m: value.m,
            mMax0: value.mMax0,
            efConstruction: value.efConstruction,
            efSearch: value.efSearch,
            seed: value.seed)
    }

    private static func makeHnswIndex(_ fixture: Fixture) throws -> CosineHnswIndex {
        try CosineHnswIndex(config: hnswConfig(from: fixture.hnsw.config))
    }

    private static func insertRows(_ fixture: Fixture, into index: CosineHnswIndex) throws {
        for i in 0..<fixture.numRows {
            let start = i * fixture.dim
            _ = try index.insert(Array(fixture.rows[start..<(start + fixture.dim)]))
        }
    }

    // MARK: HNSW 对账

    @Test func hnswTopKMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        let index = try Self.makeHnswIndex(fixture)
        try Self.insertRows(fixture, into: index)
        #expect(index.size == fixture.numRows, "size 应等于插入行数")
        // fixture 语料有效性门（同 hnsw-recall.test.ts:142-151 保留集召回门）
        #expect(fixture.hnsw.recallTop1 >= 0.9, "fixture HNSW recall@1 门限")

        for q in 0..<fixture.numQueries {
            let start = q * fixture.dim
            let query = Array(fixture.queries[start..<(start + fixture.dim)])
            let hits = try index.searchTopK(query: query, k: fixture.hnsw.topK)
            let expected = fixture.hnsw.queriesTopK[q]
            #expect(hits.indices == expected, "query \(q): topK 索引与 TS 不一致")
            #expect(hits.count == expected.count, "query \(q): 命中条数不一致")
            for s in 0..<hits.count {
                let deviation = abs(hits.scores[s] - fixture.hnsw.queriesTopKScores[q][s])
                #expect(deviation < 1e-4, "query \(q) hit \(s): 得分偏差 \(deviation) >= 1e-4")
            }
        }
    }

    // PRNG 流对账：层级分配来自固定种子 mulberry32，Swift 与 TS 必须一致
    //（任何 UInt32 复刻偏差都会在此暴露）。
    @Test func hnswLevelsMatchFixture() throws {
        let fixture = try Self.loadFixture()
        let index = try Self.makeHnswIndex(fixture)
        try Self.insertRows(fixture, into: index)
        #expect(index.debugLevels == fixture.hnsw.levels, "各节点层级与 TS（PRNG 流）不一致")
    }

    // searchByThreshold 抽查：同 hnsw-recall.test.ts:153-177 口径（>= 阈值、
    // 降序、逐条与暴力点积比对）。
    @Test func searchByThresholdMatchesBruteForce() throws {
        let fixture = try Self.loadFixture()
        let index = try Self.makeHnswIndex(fixture)
        try Self.insertRows(fixture, into: index)

        let query = Array(fixture.queries[0..<fixture.dim])
        let hits = try index.searchByThreshold(query: query, threshold: 0.7)
        #expect(hits.count > 0, "同簇查询应命中 0.7 阈值")
        var previous = Float.infinity
        for s in 0..<hits.count {
            #expect(hits.scores[s] >= 0.7, "hit \(s): 得分低于阈值")
            #expect(hits.scores[s] <= previous, "hit \(s): 得分未降序")
            previous = hits.scores[s]
            let id = hits.indices[s]
            let dot = Self.dot(fixture.queries, 0, fixture.rows, id * fixture.dim, fixture.dim)
            #expect(abs(hits.scores[s] - Float(dot)) < 1e-4, "hit \(s): 与暴力点积偏差过大")
        }
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

    // 同 hnsw-recall.test.ts:208-218（维度不匹配必须显式失败而非越界/NaN）
    @Test func rejectsDimensionMismatches() throws {
        let index = try CosineHnswIndex(config: HnswConfig(dim: 128))
        #expect(throws: VectorIndexError.dimensionMismatch(expected: 128, received: 127)) {
            _ = try index.insert([Float](repeating: 0, count: 127))
        }
        _ = try index.insert([Float](repeating: 0, count: 128))
        #expect(throws: VectorIndexError.queryShapeMismatch(expected: 128, received: 127)) {
            _ = try index.searchByThreshold(query: [Float](repeating: 0, count: 127), threshold: 0.9)
        }
        #expect(throws: VectorIndexError.queryShapeMismatch(expected: 128, received: 127)) {
            _ = try index.searchTopK(query: [Float](repeating: 0, count: 127), k: 1)
        }
    }

    @Test func rejectsInvalidConfigurations() throws {
        // HNSW（hnsw-index.ts:106-116 同口径）
        #expect(throws: VectorIndexError.invalidDimension(0)) {
            _ = try CosineHnswIndex(config: HnswConfig(dim: 0))
        }
        #expect(throws: VectorIndexError.invalidNeighborCounts(m: 0, mMax0: 64)) {
            _ = try CosineHnswIndex(config: HnswConfig(m: 0))
        }
        #expect(throws: VectorIndexError.invalidEF(efConstruction: 8, efSearch: 32)) {
            _ = try CosineHnswIndex(config: HnswConfig(efConstruction: 8))
        }
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
        // 空 HNSW：查询返回空结果（hnsw-index.ts:242 先判 entryPoint）
        let index = try CosineHnswIndex(config: HnswConfig(dim: 8))
        let hits = try index.searchTopK(query: [Float](repeating: 0, count: 8), k: 3)
        #expect(hits.count == 0)
        #expect(index.size == 0)

        // 空 LSH：build(0) 后邻居查询返回空（lsh-index.ts:230-233 先判 count）
        let lsh = try CosineLshIndex(dim: 8)
        try lsh.build(rows: [], count: 0)
        let lshHits = try lsh.neighbors(query: [Float](repeating: 0, count: 8), threshold: 0.6)
        #expect(lshHits.count == 0)
        #expect(lsh.size == 0)

        // 常量对账（lsh-index.ts:49）
        #expect(CosineLshIndex.lshMinPoints == 20_000)
    }

    // FaceVector 基础 API 抽查（点积/余弦与 fixture 数据一致）
    @Test func faceVectorDotAndCosine() throws {
        let fixture = try Self.loadFixture()
        let a = FaceVector(values: Array(fixture.rows[0..<fixture.dim]))
        let b = FaceVector(values: Array(fixture.rows[fixture.dim..<(2 * fixture.dim)]))
        let expectedDot = Self.dot(fixture.rows, 0, fixture.dim, fixture.dim)
        #expect(abs(a.dot(b) - expectedDot) < 1e-9, "点积与参照不一致")
        // 余弦 = dot / (sqrt(magQ) * sqrt(magR))（TS lsh-index.ts:337 同式）
        var magA = 0.0
        var magB = 0.0
        for k in 0..<fixture.dim {
            magA += Double(fixture.rows[k]) * Double(fixture.rows[k])
            magB += Double(fixture.rows[fixture.dim + k]) * Double(fixture.rows[fixture.dim + k])
        }
        let expectedCosine = expectedDot / (sqrt(magA) * sqrt(magB))
        #expect(abs(a.cosineSimilarity(to: b) - expectedCosine) < 1e-9, "余弦与参照不一致")
        // 语料行均为单位向量（float32 归一化误差量级 ~1e-7）：余弦 ≈ 点积
        #expect(abs(a.cosineSimilarity(to: b) - a.dot(b)) < 1e-5, "单位向量下余弦应约等于点积")
    }
}
