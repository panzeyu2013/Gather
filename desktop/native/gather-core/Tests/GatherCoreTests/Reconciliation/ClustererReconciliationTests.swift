// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/ClustererReconciliationTests.swift
// Face Clusterer（face-clusterer.ts）对账测试：加载 TS 生成器产出的 fixture，
// Swift 移植逐 case 比对（簇成员集合、噪声集合）；另有边界单元测试。

import Testing
import Foundation
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

private struct ClustererFixture: Decodable {
    struct Entry: Decodable {
        let observationId: Int
        let photoId: String
        let embedding: [Float]
    }

    struct Case: Decodable {
        let name: String
        let eps: Double
        let minPts: Int
        let entries: [Entry]
        let expectedClusters: [[Int]]
        let expectedNoise: [Int]
    }

    let seed: Int
    let cases: [Case]
}

struct ClustererReconciliationTests {
    private static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/clusterer-fixtures.json")
        .path

    private static func loadFixture() throws -> ClustererFixture {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        return try JSONDecoder().decode(ClustererFixture.self, from: data)
    }

    private static func toEntries(_ entries: [ClustererFixture.Entry]) -> [EmbeddingEntry] {
        entries.map {
            EmbeddingEntry(observationId: $0.observationId, photoId: $0.photoId, embedding: $0.embedding)
        }
    }

    @Test func matchesTSFixtureCaseByCase() async throws {
        let fixture = try Self.loadFixture()
        #expect(fixture.seed == 20260809)

        for testCase in fixture.cases {
            let result = try FaceClusterer.clusterEmbeddings(
                entries: Self.toEntries(testCase.entries),
                eps: testCase.eps,
                minPts: testCase.minPts)

            let actualClusters = result.clusters.map { cluster in
                Set(cluster.map { $0.observationId })
            }
            let expectedClusters = testCase.expectedClusters.map { Set($0) }
            let actualNoise = Set(result.noise.map { $0.observationId })
            let expectedNoise = Set(testCase.expectedNoise)

            #expect(
                actualClusters.count == expectedClusters.count,
                "case \(testCase.name): 簇数不一致 \(actualClusters.count) vs \(expectedClusters.count)")
            for cluster in expectedClusters {
                #expect(
                    actualClusters.contains(cluster),
                    "case \(testCase.name): 缺少期望簇 \(cluster.sorted())；实际 \(actualClusters.map { $0.sorted() })")
            }
            #expect(
                actualNoise == expectedNoise,
                "case \(testCase.name): 噪声集合不一致 \(actualNoise.sorted()) vs \(expectedNoise.sorted())")
        }
    }

    @Test func lshPathAgreesWithExactPath() throws {
        // LSH 路径（n > minPoints）只收缩候选集，recall 门内结果应与 exact 一致。
        // 构造 24 行小语料、minPoints=8 强制走 LSH 分支，与 exact 结果比对。
        var entries: [EmbeddingEntry] = []
        let base = [1.0, 0, 0, 0, 0, 0, 0, 0]
        for c in 0..<3 {
            let axis = base.map { $0 * Double(c == 0 ? 1 : (c == 1 ? 0 : 0)) }
            for p in 0..<8 {
                var e = axis
                if c == 1 { e = [0, 1, 0, 0, 0, 0, 0, 0] }
                if c == 2 { e = [0, 0, 1, 0, 0, 0, 0, 0] }
                entries.append(
                    EmbeddingEntry(
                        observationId: c * 8 + p + 1,
                        photoId: "c\(c)p\(p)",
                        embedding: e.map { Float($0) }))
            }
        }

        let exactOptions = ClusterLshOptions(enabled: false, minPoints: 0, config: .default)
        let lshOptions = ClusterLshOptions(
            enabled: true,
            minPoints: 8,
            config: LshConfig(bits: 10, tables: 8, probeRadius: 2, seed: 42, unitVectors: true))

        let exact = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.95, minPts: 2, lshOptions: exactOptions)
        let lsh = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.95, minPts: 2, lshOptions: lshOptions)

        let exactSets = Set(exact.clusters.map { Set($0.map { $0.observationId }) })
        let lshSets = Set(lsh.clusters.map { Set($0.map { $0.observationId }) })
        #expect(exactSets == lshSets, "LSH 路径结果应与 exact 一致")
        #expect(lsh.noise.map { $0.observationId } == exact.noise.map { $0.observationId })
    }

    @Test func dimensionMismatchThrows() {
        let entries = [
            EmbeddingEntry(observationId: 1, photoId: "a", embedding: [1, 0, 0, 0]),
            EmbeddingEntry(observationId: 2, photoId: "b", embedding: [1, 0]),
        ]
        #expect(throws: ClustererError.self) {
            _ = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 2)
        }
    }

    @Test func reportsProgress() throws {
        let entries = (0..<10).map {
            EmbeddingEntry(observationId: $0 + 1, photoId: "p\($0)", embedding: [1, 0, 0, 0])
        }
        var progress: [(Int, Int)] = []
        _ = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2,
            onProgress: { current, total in progress.append((current, total)) })

        #expect(!progress.isEmpty)
        #expect(progress.allSatisfy { $0.1 == 10 })
        #expect(progress.last?.0 == 10, "结束时进度应到达总数")
    }
}
