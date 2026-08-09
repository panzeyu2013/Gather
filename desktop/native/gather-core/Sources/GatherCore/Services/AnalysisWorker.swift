// desktop/native/gather-core/Sources/GatherCore/Services/AnalysisWorker.swift
// TS 源: desktop/src/main/utils/analysis-worker.ts（重写）
// 分析 worker 语义：把聚类计算包进 JobScheduler 的预算准入内执行，进度经
// 回调流式上报，错误携带原始消息。TS 侧为 worker_threads 进程模型；Swift 侧
// 为同进程 actor 调度 + async 任务，语义对齐：请求 → 进度事件流 → 结果/错误。
//
// 进度回调按 TS parentPort.postMessage 顺序投递，序号自增；取消经 Task 取消
// 传播（计算开始前 checkCancellation，同步循环内不中断——与 TS 杀线程同级的
// 语义差异见下注）。
//
// 注：TS 的 face 分支（clusterEmbeddings）依赖 face-clusterer 移植
// （Face/Clusterer.swift，Phase 2.3 进行中），完成后在此接入。
import Foundation

public struct AnalysisWorkerProgress: Equatable, Sendable {
    public let id: Int
    public let current: Int
    public let total: Int

    public init(id: Int, current: Int, total: Int) {
        self.id = id
        self.current = current
        self.total = total
    }
}

public enum AnalysisWorkerError: Error, Equatable {
    case cancelled
    case failed(String)
}

public enum AnalysisWorker {
    /// 按 dHash 阈值聚类（对应 TS 'hash' 请求分支）。
    public static func runHash(
        id: Int,
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        mode: HashGroupingMode = .global,
        scheduler: JobScheduler = sharedJobScheduler,
        onProgress: ((AnalysisWorkerProgress) -> Void)? = nil
    ) async throws -> ClusterResult {
        try await scheduler.run(weight: 1) {
            try Task.checkCancellation()
            return try ClusterEngine.clusterByHash(
                entries: entries,
                threshold: threshold,
                minGroupSize: minGroupSize,
                mode: mode,
                onProgress: { current, total in
                    onProgress?(AnalysisWorkerProgress(id: id, current: current, total: total))
                })
        }
    }

    /// 多阈值聚类（对应 TS 'hash-multi' 请求分支），返回每个阈值的聚类结果。
    public static func runHashMulti(
        id: Int,
        entries: [HashEntry],
        thresholds: [Int],
        minGroupSize: Int,
        mode: HashGroupingMode = .global,
        scheduler: JobScheduler = sharedJobScheduler,
        onProgress: ((AnalysisWorkerProgress) -> Void)? = nil
    ) async throws -> [ClusterResult] {
        try await scheduler.run(weight: 1) {
            try Task.checkCancellation()
            return try ClusterEngine.clusterByHashMulti(
                entries: entries,
                thresholds: thresholds,
                minGroupSize: minGroupSize,
                mode: mode,
                onProgress: { current, total in
                    onProgress?(AnalysisWorkerProgress(id: id, current: current, total: total))
                })
        }
    }
}
