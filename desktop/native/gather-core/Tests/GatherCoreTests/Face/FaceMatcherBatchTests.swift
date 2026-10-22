// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceMatcherBatchTests.swift
// Cut 5 / 5c-1：FaceMatcher 批量 API 的**逐位一致**守门 + 边界用例。
//
// 批量路径（match(clusters:...) / bestScoresPerPerson(queries:)）的唯一授权优化是
// "库/范数/索引只准备一次"：库行顺序、逐项累加顺序、零向量短路、维度错误触发点
// 必须与逐条 FaceMatcher.bestScoresPerPerson(query:library:) 完全相同。本文件用
// 精确 Double 相等（Dictionary/Decision 的 ==）而不是容差，任何浮点顺序变化都会红。

import Foundation
import Testing

@testable import GatherProtocol
@testable import GatherAnalysis

// 确定性伪随机（跨平台一致；只用于构造非单位向量，不参与断言）。
private struct BatchLCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let bits = UInt32(truncatingIfNeeded: state >> 32)
        return Float(bits) / Float(UInt32.max) * 2 - 1
    }
    mutating func vector(count: Int) -> [Float] {
        (0..<count).map { _ in next() }
    }
}

/// 旧 FaceKwService 逐簇路径的冻结参照：逐 query 调 bestScoresPerPerson →
/// rejected 过滤 → 人物级中位数 → FaceIdentityPolicy.decide。批量 API 必须与它
/// **逐位**相同（本文件不复制判定规则，只复制聚合与调用顺序）。
private func legacyPerClusterDecisions(
    clusters: [FaceMatchCluster],
    library: [LibraryEmbedding],
    thresholds: [String: Double],
    defaultThreshold: Double,
    margin: Double
) throws -> [FaceMatchDecision] {
    var decisions: [FaceMatchDecision] = []
    for cluster in clusters {
        var scores: [String: [Double]] = [:]
        for query in cluster.embeddings {
            for (personId, score) in try FaceMatcher.bestScoresPerPerson(query: query, library: library)
                where !cluster.excludedPersonIds.contains(personId) {
                scores[personId, default: []].append(score)
            }
        }
        let aggregate = scores.mapValues { values -> Double in
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 0
                ? (sorted[middle - 1] + sorted[middle]) / 2
                : sorted[middle]
        }
        decisions.append(FaceMatchDecision(
            clusterId: cluster.clusterId,
            decision: FaceIdentityPolicy.decide(
                scores: aggregate,
                thresholds: thresholds,
                defaultThreshold: defaultThreshold,
                margin: max(0, margin))))
    }
    return decisions
}

struct FaceMatcherBatchTests {
    // 4 人物 × 3 行、7 维、非单位化；P3 的第二行是全零（范数 0 短路）。
    private static func makeLibrary() -> [LibraryEmbedding] {
        var rng = BatchLCG(state: 0x5EED_5EED)
        var library: [LibraryEmbedding] = []
        for person in 0..<4 {
            for row in 0..<3 {
                let embedding: [Float]
                if person == 3 && row == 1 {
                    embedding = [0, 0, 0, 0, 0, 0, 0]
                } else {
                    // 系数 0.25 起：非单位向量，norm 路径必须有实际数值。
                    embedding = rng.vector(count: 7).map { $0 * 0.25 + Float(person) * 0.1 }
                }
                library.append(LibraryEmbedding(personId: "P\(person)", embedding: embedding))
            }
        }
        return library
    }

    private static func makeQueries(library: [LibraryEmbedding]) -> [[Float]] {
        var rng = BatchLCG(state: 0xC0FFEE)
        var queries: [[Float]] = []
        // 命中库行（余弦恰 1.0）、非单位倍数（余弦仍 1.0）、零向量、随机向量。
        queries.append(library[0].embedding)
        queries.append(library[1].embedding.map { $0 * 5 })
        queries.append([Float](repeating: 0, count: 7))
        for _ in 0..<5 {
            queries.append(rng.vector(count: 7))
        }
        // 重复同一查询：批量 API 不得让查询之间互相影响。
        queries.append(library[4].embedding)
        queries.append(library[4].embedding)
        return queries
    }

    // 批量 per-person 最佳分 == 逐条 bestScoresPerPerson，精确 Double 相等。
    @Test func batchScoresAreBitIdenticalToPerQueryBestScores() throws {
        let library = Self.makeLibrary()
        let queries = Self.makeQueries(library: library)
        let matcher = FaceMatcher(library: library)
        let reference = try queries.map {
            try FaceMatcher.bestScoresPerPerson(query: $0, library: library)
        }

        let batch = try matcher.bestScoresPerPerson(queries: queries)
        #expect(batch == reference, "实例库批量得分必须与逐条 bestScoresPerPerson 逐位一致")

        let explicit = try matcher.bestScoresPerPerson(queries: queries, library: library)
        #expect(explicit == reference, "显式库快照批量得分必须与逐条 bestScoresPerPerson 逐位一致")
    }

    // 批量决策 == 旧逐簇路径（含 rejected 过滤 / 人物阈值 / margin），逐位相等。
    @Test func batchDecisionsAreBitIdenticalToLegacyPerClusterLoop() throws {
        let library = Self.makeLibrary()
        let queries = Self.makeQueries(library: library)
        let clusters = [
            FaceMatchCluster(clusterId: 11, embeddings: [queries[0], queries[1]]),
            FaceMatchCluster(clusterId: 12, embeddings: [queries[2], queries[3]]),
            FaceMatchCluster(clusterId: 13, embeddings: [queries[4]], excludedPersonIds: ["P0"]),
            FaceMatchCluster(clusterId: 14, embeddings: [queries[5], queries[6]], excludedPersonIds: ["P1", "P2"]),
            FaceMatchCluster(clusterId: 15, embeddings: []),
        ]
        let thresholds: [String: Double] = ["P0": 0.3, "P1": 0.9]
        let matcher = FaceMatcher(library: library)

        for margin in [0.0, 0.01, 0.5, -1.0] {
            for defaultThreshold in [0.65, 1.0 - 1e-9] {
                let batch = try matcher.match(
                    clusters: clusters,
                    thresholds: thresholds,
                    defaultThreshold: defaultThreshold,
                    margin: margin)
                let legacy = try legacyPerClusterDecisions(
                    clusters: clusters,
                    library: library,
                    thresholds: thresholds,
                    defaultThreshold: defaultThreshold,
                    margin: margin)
                #expect(
                    batch == legacy,
                    "margin=\(margin) defaultThreshold=\(defaultThreshold)：批量决策与逐簇路径必须逐位一致")
            }
        }
    }

    // Cut 5 / 5d-2：批量路径**不建 LSH**（lshMinPoints = 0 时旧实现会在
    // loadLibrary 里顺带建一次，纯浪费）；只有实例级 matchAgainstLibrary 建索引。
    // 且即使实例已建索引，批量仍按精确扫描累加：库行顺序/范数来源与逐条 API
    // 相同、不做候选收缩，结果逐位一致。
    @Test func batchDoesNotBuildLshIndexAndStaysExact() throws {
        let library = Self.makeLibrary()
        let queries = Self.makeQueries(library: library)
        let matcher = FaceMatcher(library: library, lshMinPoints: 0)
        #expect(!matcher.hasLSHIndex, "构造后不应有索引")

        let batchBefore = try matcher.bestScoresPerPerson(queries: queries)
        #expect(!matcher.hasLSHIndex, "批量路径不得构建 LSH 索引（唯一授权入口是 matchAgainstLibrary）")
        let reference = try queries.map {
            try FaceMatcher.bestScoresPerPerson(query: $0, library: library)
        }
        #expect(batchBefore == reference, "批量路径不得使用 LSH 候选子集（会对不上逐条精确扫描）")

        // 实例级逐查询 API 才建索引；此后的批量结果仍必须逐位不变。
        _ = try matcher.matchAgainstLibrary([queries[0]], threshold: 0.5)
        #expect(matcher.hasLSHIndex, "matchAgainstLibrary 在库 > lshMinPoints 时必须建 LSH")

        let batchAfter = try matcher.bestScoresPerPerson(queries: queries)
        #expect(batchAfter == reference, "实例建过索引后，批量路径仍不得使用 LSH 候选子集")
    }

    // 空库：每簇 unknown（与旧服务 guard 后不写任何匹配等价）。
    @Test func emptyLibraryReportsUnknownForEveryCluster() throws {
        let matcher = FaceMatcher(library: [])
        let clusters = [
            FaceMatchCluster(clusterId: 1, embeddings: [[1, 0, 0, 0]]),
            FaceMatchCluster(clusterId: 2, embeddings: [[0.5, 0.5, 0.5, 0.5], [1, 0, 0, 0]]),
        ]
        let decisions = try matcher.match(clusters: clusters, defaultThreshold: 0.65, margin: 0.01)
        #expect(decisions.count == 2)
        #expect(decisions.allSatisfy { $0.isUnknown })
        #expect(decisions.allSatisfy { $0.personId == nil && $0.confidence == nil })
        let scores = try matcher.bestScoresPerPerson(queries: [[1, 0, 0, 0]])
        #expect(scores == [[String: Double]()], "空库每个查询的 per-person 得分表必须为空")
    }

    // 单簇：与逐簇参照逐位一致，且 confidence 精确等于 1.0（阈值含等号边界）。
    @Test func singleClusterMatchesLegacyAndInclusiveThreshold() throws {
        let library = [
            LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0]),
            LibraryEmbedding(personId: "B", embedding: [0.5, 0.5, 0.5, 0.5]),
        ]
        let clusters = [FaceMatchCluster(clusterId: 7, embeddings: [[1, 0, 0, 0]])]
        let matcher = FaceMatcher(library: library)

        let accepted = try matcher.match(clusters: clusters, defaultThreshold: 1.0)
        let legacy = try legacyPerClusterDecisions(
            clusters: clusters, library: library, thresholds: [:],
            defaultThreshold: 1.0, margin: 0)
        #expect(accepted == legacy)
        #expect(accepted.count == 1)
        #expect(accepted[0].personId == "A")
        #expect(accepted[0].confidence == 1.0, "余弦恰为 1.0 时 confidence 必须精确为 1.0")

        let above = try matcher.match(clusters: clusters, defaultThreshold: 1.0 + 1e-6)
        #expect(above[0].isUnknown, "阈值高于余弦时不得命中（:166-172 边界的批量版）")
    }

    // excludedPersonIds：冠军被排除后落到亚军；亚军不达阈值则 unknown。
    @Test func excludedPersonFallsThroughToRunnerUp() throws {
        let library = [
            LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0]),
            LibraryEmbedding(personId: "B", embedding: [0.5, 0.5, 0.5, 0.5]),
        ]
        let matcher = FaceMatcher(library: library)
        let cluster = [FaceMatchCluster(
            clusterId: 3, embeddings: [[1, 0, 0, 0]], excludedPersonIds: ["A"])]

        let fallback = try matcher.match(clusters: cluster, defaultThreshold: 0.4)
        #expect(fallback[0].personId == "B")
        #expect(fallback[0].confidence == 0.5)

        let gated = try matcher.match(clusters: cluster, defaultThreshold: 0.9)
        #expect(gated[0].isUnknown)
    }

    // margin 语义与逐簇路径一致（含 >0 时歧义不猜）。
    @Test func batchMarginMatchesLegacyAmbiguity() throws {
        let library = [
            LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0]),
            LibraryEmbedding(personId: "B", embedding: [0.5, 0.5, 0.5, 0.5]),
        ]
        let clusters = [FaceMatchCluster(clusterId: 4, embeddings: [[1, 0, 0, 0]])]
        let matcher = FaceMatcher(library: library)
        let ambiguous = try matcher.match(clusters: clusters, defaultThreshold: 0.4, margin: 0.6)
        #expect(ambiguous[0].isAmbiguous)
        #expect(ambiguous[0].personId == nil)

        let legacy = try legacyPerClusterDecisions(
            clusters: clusters, library: library, thresholds: [:],
            defaultThreshold: 0.4, margin: 0.6)
        #expect(ambiguous == legacy)
    }

    // 维度不匹配：与静态 bestScoresPerPerson 同错误（expected=库行维度/触发点=行序）。
    @Test func batchRejectsVectorLengthMismatchLikePerQueryAPI() throws {
        let library = [LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0])]
        let matcher = FaceMatcher(library: library)
        #expect(throws: MatcherError.vectorLengthMismatch(expected: 4, received: 3)) {
            _ = try matcher.match(clusters: [
                FaceMatchCluster(clusterId: 1, embeddings: [[0.5, 0.5, 0.5]]),
            ])
        }
        #expect(throws: MatcherError.vectorLengthMismatch(expected: 4, received: 3)) {
            _ = try FaceMatcher.bestScoresPerPerson(query: [0.5, 0.5, 0.5], library: library)
        }
    }
}
