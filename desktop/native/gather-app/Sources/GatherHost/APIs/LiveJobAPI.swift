// desktop/native/gather-app/Sources/GatherHost/APIs/LiveJobAPI.swift
// Cut 1 / 阶段 B1：JobAPI 的 Live 实现（5 个方法）。
//
// 对应命令（5 条）：jobs.list / cancel / retry / clear_completed、index.scan
// （start 吸收“建 job”面）。校验归属：list 的 includeCheckpoint 缺省 true；
// 破坏性 clearCompleted 只接收 Confirmed<ClearCompletedInput>（D-011）。
//
// 事件源：GatherEventCenter 的 jobProgress / jobTerminal 通知（不再另建
// jobs:progress 第二通道）。progress 观察者跳过终态帧（终态帧同时发到两条通知，
// 只由 terminal 观察者 yield .finished），避免同一帧被消费两次。
// 流结束时（终态帧 / 取消 / 丢弃 handle）移除观察者；start 在注册后补一次
// 快照，覆盖“job 在观察者注册前就已终态”的竞态。
//
// WP4b：同步核心（listSync/cancelSync/…）已删除；协议方法直接调用 JobService。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
import GatherUI

public final class LiveJobAPI: JobAPI {
    private let jobService: JobService

    /// Sendable 由协议继承显式声明，且类为 final、唯一存储属性 jobService 是
    /// Sendable（其可变任务表由 JobService 自己的 NSLock 串行化），故无需
    /// @unchecked；此点由编译器检查。
    public init(jobService: JobService) {
        self.jobService = jobService
    }

    // MARK: - JobAPI

    public func list(_ filter: JobListFilter) async throws -> [AnalysisJobData] {
        try jobService.list(includeCheckpoint: filter.includeCheckpoint)
    }

    public func cancel(_ jobId: String) async throws -> Bool {
        let id = try requireNonBlank(jobId, field: "jobId", maxLength: 256)
        return try jobService.cancel(id)
    }

    public func retry(_ jobId: String) async throws -> Bool {
        let id = try requireNonBlank(jobId, field: "jobId", maxLength: 256)
        return try jobService.retry(id)
    }

    public func clearCompleted(_ input: Confirmed<ClearCompletedInput>) async throws -> Int {
        _ = input.value // 载荷当前无字段；Confirmed 是调用点标记，不是布尔门禁。
        return try jobService.clearCompleted()
    }

    public func start(_ request: JobRequest) async throws -> JobHandle {
        try validate(request)
        let job = try jobService.create(request)
        // GatherEventCenter 是 @MainActor（@Observable）；通知名是静态常量，
        // 在非隔离的 API 实现里经 MainActor 读取，避免把整个 API 类标成
        // MainActor（那样无法满足 Sendable 协议的 nonisolated 要求）。
        let names = await MainActor.run {
            (progress: GatherEventCenter.jobProgress, terminal: GatherEventCenter.jobTerminal)
        }
        let (stream, continuation) = AsyncStream<JobEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let observers = JobObserverBag()
        let progressToken = NotificationCenter.default.addObserver(
            forName: names.progress, object: nil, queue: nil
        ) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.id == job.id,
                  !event.isTerminal else { return }
            continuation.yield(.progress(event.update))
        }
        let terminalToken = NotificationCenter.default.addObserver(
            forName: names.terminal, object: nil, queue: nil
        ) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.id == job.id else { return }
            continuation.yield(.finished(event.job))
            continuation.finish()
        }
        observers.replace([progressToken, terminalToken])
        continuation.onTermination = { @Sendable _ in
            // 终态帧会走 finish() → onTermination；异步摘除观察者，避免在
            // NotificationCenter 的投递栈里同步重入（finish 可能正在 terminal
            // 回调内执行）。
            Task { observers.removeAll() }
        }
        // 竞态：极短任务可能在 addObserver 之前就完成。注册后补一次快照，
        // 已是终态则直接补发 finished 并关流。
        if let snapshot = try? jobService.list(includeCheckpoint: false)
            .first(where: { $0.id == job.id }),
           terminalAnalysisJobStatuses.contains(snapshot.status) {
            continuation.yield(.finished(snapshot))
            continuation.finish()
        }
        return JobHandle(id: job.id, events: stream)
    }

    // MARK: - 内部

    private func validate(_ request: JobRequest) throws {
        guard !request.scopeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: "scopeType", reason: "must not be blank")
        }
        guard !request.scopeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: "scopeId", reason: "must not be blank")
        }
        guard !request.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: "dedupeKey", reason: "must not be blank")
        }
    }

    private func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return value
    }
}

/// NotificationCenter 观察者集合：onTermination 与 start 的补发路径可能并发到达，
/// 用锁保证“只移除一次”。移除在 ARC 之外没有其他副作用，故 @unchecked Sendable。
private final class JobObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var removed = false

    func replace(_ newTokens: [NSObjectProtocol]) {
        lock.lock()
        if removed {
            lock.unlock()
            newTokens.forEach { NotificationCenter.default.removeObserver($0) }
            return
        }
        tokens = newTokens
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        guard !removed else {
            lock.unlock()
            return
        }
        removed = true
        let tokens = self.tokens
        self.tokens = []
        lock.unlock()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
