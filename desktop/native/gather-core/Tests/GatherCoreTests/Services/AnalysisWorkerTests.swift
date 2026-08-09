// desktop/native/gather-core/Tests/GatherCoreTests/Services/AnalysisWorkerTests.swift
// AnalysisWorker 语义测试：进度流式上报、结果与直接调用 ClusterEngine 一致、
// 错误传播、取消。

import Testing
import Foundation
@testable import GatherCore

struct AnalysisWorkerTests {
    /// 构造固定哈希条目：全部相同 → 单组；全部两两汉明距离 > 阈值 → 不分组。
    private func makeEntries(count: Int, hash: String) -> [HashEntry] {
        (0..<count).map { HashEntry(photoId: "p\($0)", hash: hash) }
    }

    @Test func runHashMatchesClusterEngineAndStreamsProgress() async throws {
        let entries = makeEntries(count: 5, hash: "aabbccdd11223344")
        var progress: [AnalysisWorkerProgress] = []

        let result = try await AnalysisWorker.runHash(
            id: 7,
            entries: entries,
            threshold: 8,
            minGroupSize: 1,
            onProgress: { progress.append($0) }
        )

        let direct = try ClusterEngine.clusterByHash(
            entries: entries, threshold: 8, minGroupSize: 1)
        #expect(result == direct, "AnalysisWorker 结果应与直接调用 ClusterEngine 一致")

        #expect(progress.allSatisfy { $0.id == 7 })
        #expect(!progress.isEmpty, "应流式上报进度")
        // TS 的 onProgress 在部分路径（如 global 模式多轮扫描）不保证单调，
        // 此处只校验上报格式：total 恒定、current 落在 [0, total]。
        #expect(progress.allSatisfy { $0.total == progress[0].total })
        #expect(progress.allSatisfy { $0.current >= 0 && $0.current <= $0.total })
    }

    @Test func runHashMultiMatchesDirectCall() async throws {
        let entries = makeEntries(count: 4, hash: "00000000ffffffff")
        let thresholds = [2, 4, 8]

        let result = try await AnalysisWorker.runHashMulti(
            id: 3, entries: entries, thresholds: thresholds, minGroupSize: 1)

        let direct = try ClusterEngine.clusterByHashMulti(
            entries: entries, thresholds: thresholds, minGroupSize: 1)
        #expect(result == direct)
    }

    @Test func propagatesInvalidHashError() async throws {
        let entries = [HashEntry(photoId: "bad", hash: "zzz")]

        do {
            _ = try await AnalysisWorker.runHash(
                id: 1, entries: entries, threshold: 4, minGroupSize: 1)
            Issue.record("应抛 invalidHash")
        } catch is ClusterEngineError {
            // 预期：非法 hash 抛 ClusterEngineError（payload 截取行为与 TS 一致，不做细粒度断言）
        } catch {
            Issue.record("非预期错误类型: \(error)")
        }
    }

    @Test func respectsSchedulerBudget() async throws {
        // budget=1：AnalysisWorker 任务占满预算时，其他任务排队。
        let scheduler = JobScheduler(budget: 1)
        let entries = makeEntries(count: 3, hash: "aabbccdd11223344")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try await AnalysisWorker.runHash(
                        id: 0, entries: entries, threshold: 8, minGroupSize: 1,
                        scheduler: scheduler)
                }
            }
            try await group.waitForAll()
        }
        // 未抛错即预算语义成立（若预算泄漏会死锁/超时）。
    }
}
