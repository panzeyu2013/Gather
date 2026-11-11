// desktop/native/gather-core/Tests/GatherCoreTests/Services/SemanticMultiSeedTests.swift
// Wave2 / task-14：多选种子的平均向量相似检索（选中 N 张找"这类照片"）。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

/// 内存语义存储（多选检索是纯计算 + 一次读，不碰库）。
private final class MultiSeedStore: PhotoSemanticsStore {
    var rows: [String: PhotoSemanticsRow] = [:]

    func upsert(_ inserts: [PhotoSemanticsInsert]) throws {}
    func load(photoId: String) throws -> PhotoSemanticsRow? { rows[photoId] }
    func loadRows(sessionId: String, limit: Int) throws -> [PhotoSemanticsRow] {
        rows.values.filter { $0.sessionId == sessionId }.sorted { $0.photoId < $1.photoId }
    }
    func loadRows(sessionId: String, photoIds: [String]) throws -> [PhotoSemanticsRow] {
        photoIds.compactMap { rows[$0] }.filter { $0.sessionId == sessionId }
    }
    func indexedPhotoIds(sessionId: String) throws -> Set<String> {
        Set(rows.values.filter { $0.sessionId == sessionId }.map(\.photoId))
    }
    func count(sessionId: String) throws -> Int {
        rows.values.filter { $0.sessionId == sessionId }.count
    }
    func deleteSession(_ sessionId: String) throws -> Int { 0 }
    func deleteAll() throws -> Int { 0 }
}

private func row(
    _ photoId: String, vector: [Float], sessionId: String = "s1"
) -> PhotoSemanticsRow {
    PhotoSemanticsRow(
        photoId: photoId, sessionId: sessionId,
        labelsJson: "[]",
        feature: SemanticFeatureCodec.encode(vector),
        featureDim: vector.count,
        modelVersion: "test",
        computedAt: "2026-11-11T00:00:00Z")
}

@Suite("多选平均向量检索")
struct SemanticMultiSeedTests {
    @Test("平均向量：L2 归一化后等权平均、空输入 nil、维数不一致只取首维那批")
    func averageVector() {
        #expect(SemanticIndex.averageVector([]) == nil)
        let mean = SemanticIndex.averageVector([[1, 0], [0, 1]])
        #expect(mean?[0] == 0.5 && mean?[1] == 0.5)
        #expect(SemanticIndex.averageVector([[0, 0], [0, 0]]) == nil, "全零向量没有方向")

        // P2 回归：两个种子范数不同（10 vs 1）时也必须等权——
        // 归一化后各贡献 (1,0) 与 (0,1)，均值方向 = (0.5, 0.5)。
        let unequalNorms = SemanticIndex.averageVector([[10, 0], [0, 1]])
        #expect(abs((unequalNorms?[0] ?? 0) - 0.5) < 1e-5)
        #expect(abs((unequalNorms?[1] ?? 0) - 0.5) < 1e-5)

        // 维数不一致：只保留首维那批（[1,2] 归一化后 = (0.4472, 0.8944)）。
        let mismatched = SemanticIndex.averageVector([[1, 2], [3, 4, 5]])
        #expect(abs((mismatched?[0] ?? 0) - 0.4472136) < 1e-5)
        #expect(abs((mismatched?[1] ?? 0) - 0.8944272) < 1e-5)
        #expect(mismatched?.count == 2)
    }

    @Test("多选检索：种子被排除、按与平均向量的余弦降序、阈值过滤")
    func multiSeedSimilar() throws {
        let store = MultiSeedStore()
        // 两个种子：一个偏 (1,0)，一个偏 (0,1) → 平均 (0.5,0.5)。
        store.rows["a"] = row("a", vector: [1, 0])
        store.rows["b"] = row("b", vector: [0, 1])
        store.rows["c"] = row("c", vector: [1, 1])       // 与平均向量完全同向
        store.rows["d"] = row("d", vector: [1, 0.2])     // 与平均向量夹角更小
        store.rows["e"] = row("e", vector: [0, -1])      // 逆向 → 被阈值过滤
        let index = SemanticIndex(store: store)

        let outcome = try index.similar(
            to: ["a", "b"], sessionId: "s1", limit: 10, minSimilarity: 0.9)
        #expect(outcome.method == .featurePrint)
        #expect(outcome.hits.map(\.photoId) == ["c"])
        #expect(outcome.hits.first?.similarity ?? 0 > 0.999)

        let loose = try index.similar(
            to: ["a", "b"], sessionId: "s1", limit: 10, minSimilarity: 0.5)
        #expect(!loose.hits.contains { $0.photoId == "a" || $0.photoId == "b" })
        #expect(loose.hits.first?.photoId == "c")
        #expect(loose.hits.contains { $0.photoId == "d" })
        #expect(!loose.hits.contains { $0.photoId == "e" })
    }

    @Test("种子没有向量时给 unavailableReason，不伪造命中")
    func noSeedVector() throws {
        let store = MultiSeedStore()
        store.rows["c"] = row("c", vector: [1, 1])
        let index = SemanticIndex(store: store)
        let outcome = try index.similar(to: ["missing"], sessionId: "s1")
        #expect(outcome.hits.isEmpty)
        #expect(outcome.unavailableReason != nil)
    }
}
