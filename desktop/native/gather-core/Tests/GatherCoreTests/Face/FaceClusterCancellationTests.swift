// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceClusterCancellationTests.swift
// Cut 5 / 5c-2：FaceClusterer 的取消注入（B 阶段移出 DB 锁后，长聚类必须可中断）。
//
// 只验证"检查点真的进了 DBSCAN / 增量扫描"，不复制聚类数学；取消错误由调用方
// （FaceKwService）注入，Analysis 层不依赖 JobCancelledError。
import Testing
@testable import GatherAnalysis

private struct InjectedCancellation: Error {}

struct FaceClusterCancellationTests {
    private func entries(count: Int, dim: Int = 8) -> [EmbeddingEntry] {
        (0..<count).map { index in
            let vector = (0..<dim).map { k in Float((index * 7 + k * 13) % 29) / 29.0 }
            return EmbeddingEntry(
                observationId: index + 1, photoId: "p\(index)",
                embedding: vector, quality: 1)
        }
    }

    @Test func clusterEmbeddingsStopsAtInjectedCancellationInsideDbscan() {
        let items = entries(count: 64)
        var checks = 0
        var result: FaceClusterResult?
        #expect(throws: InjectedCancellation.self) {
            result = try FaceClusterer.clusterEmbeddings(
                entries: items,
                eps: 0,
                minPts: 2,
                isCancelled: {
                    checks += 1
                    if checks >= 8 { throw InjectedCancellation() }
                })
        }
        #expect(result == nil)
        #expect(checks >= 8, "取消检查必须进入 DBSCAN 的种子点/BFS，而不是只在入口查一次")
    }

    @Test func assignIncrementallyStopsDuringCentroidScan() {
        let existing = entries(count: 4)
        let newEntries = entries(count: 512)
        var checks = 0
        #expect(throws: InjectedCancellation.self) {
            _ = try FaceClusterer.assignIncrementally(
                existingClusters: [(clusterId: 1, entries: existing)],
                newEntries: newEntries,
                eps: 0.5,
                minPts: 2,
                isCancelled: {
                    checks += 1
                    if checks >= 3 { throw InjectedCancellation() }
                })
        }
        #expect(checks >= 3, "增量入口的质心扫描也必须响应取消")
    }
}
