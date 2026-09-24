// UI 对齐（§十一 11.9-1）：同进程事件总线。
// 对齐 TS 三条推送通道中的 jobs:progress：
// - 宿主启动时把 JobRunner.setProgressSink 接到本中心（Task 已切 MainActor）；
// - 每次 flushProgress 与终态帧（emitTerminal）都广播 NotificationCenter 通知；
// - 页面用 .onReceive 订阅，替代「打开时快照 + 手动刷新」。
// 终态判定：双通道——(a) 终态帧 update.message == job.status.rawValue
// （JobRunner emitTerminal 语义）；(b) 按 jobId 记忆上次状态，job 从
// 非终态转移进终态（succeeded/failed/cancelled/interrupted）即判定终态，
// 弥补 (a) 在 message 缺失/不匹配帧（如 flushProgress 最后一帧 message
// 为 index.done 而 status 已被 finish 写为 succeeded）时漏判、权威计数
// 最多滞后 30s 兜底轮询的问题。
import Foundation
import GatherCore

public struct GatherJobEvent {
    public let job: AnalysisJobData
    public let update: JobProgressUpdate

    public var isTerminal: Bool {
        update.message == job.status.rawValue &&
            [.succeeded, .failed, .cancelled, .interrupted].contains(job.status)
    }
}

@MainActor
@Observable
public final class GatherEventCenter {
    public static let shared = GatherEventCenter()

    public static let jobProgress = Notification.Name("gather.events.job-progress")
    public static let jobTerminal = Notification.Name("gather.events.job-terminal")
    public static let c1SyncStatus = Notification.Name("gather.events.c1-sync-status")

    /// 终态状态集（对齐 TS jobs:progress 终态分支与 clearCompleted 语义）。
    private static let terminalStatuses: Set<AnalysisJobStatus> = [
        .succeeded, .failed, .cancelled, .interrupted,
    ]

    public private(set) var wired = false

    /// 每 jobId 上次见到的状态（终态转移判定；同进程串行更新，无需锁）。
    private var lastSeenStatus: [String: AnalysisJobStatus] = [:]

    private init() {}

    /// 测试接缝（@testable 专用）：直接注入一帧进度/终态帧，走与
    /// JobRunner progressSink 相同的 emit 路径（含终态转移判定）。
    internal func post(job: AnalysisJobData, update: JobProgressUpdate) {
        emit(job: job, update: update)
    }

    /// 宿主启动装配调用一次：接 JobRunner 进度/终态帧。
    public func wire(jobRunner: JobRunner) async {
        guard !wired else { return }
        wired = true
        await jobRunner.setProgressSink { [weak self] job, update in
            Task { @MainActor in
                self?.emit(job: job, update: update)
            }
        }
    }

    /// Capture One 写回协调器 emitSummary 后的状态变化提示（页面拉取视图）。
    public func postC1SyncStatusChange(sessionId: String) {
        NotificationCenter.default.post(name: Self.c1SyncStatus, object: sessionId)
    }

    private func emit(job: AnalysisJobData, update: JobProgressUpdate) {
        let event = GatherJobEvent(job: job, update: update)
        NotificationCenter.default.post(name: Self.jobProgress, object: event)
        let previous = lastSeenStatus[job.id]
        lastSeenStatus[job.id] = job.status
        if event.isTerminal || isTerminalTransition(from: previous, to: job.status) {
            NotificationCenter.default.post(name: Self.jobTerminal, object: event)
        }
    }

    /// 状态机判定：status 为终态且与上次所见不同（含首次见到即终态）→ 转移。
    /// 与 message 启发式互补：终态帧 message 缺失/不匹配时不漏判。
    private func isTerminalTransition(from previous: AnalysisJobStatus?, to status: AnalysisJobStatus) -> Bool {
        guard Self.terminalStatuses.contains(status) else { return false }
        return previous != status
    }
}
