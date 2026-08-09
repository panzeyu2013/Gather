// desktop/native/gather-core/Sources/GatherCore/Services/JobScheduler.swift
// TS 源: desktop/src/main/utils/heavy-task-scheduler.ts（重写，Actor 调度）
// 进程级 weight 预算准入控制：运行中任务认领 weight 单位的共享预算，排队任务
// 按 (priority, order) 序在预算有空位时准入。语义与 TS HeavyTaskScheduler 一致：
// - budget 默认 = max(1, max(2, min(6, cpus-1)))，显式传入时至少 1
// - units = max(1, floor(weight))（本 API 以 Int 承接，等价）
// - 排队期间由 releasePending 唤醒时记账（TS 注释 "already counted our units"）
// - 任务完成/抛错后释放预算并扫描唤醒可准入的排队任务
// 增强（相对 TS）：排队中的任务支持取消——被取消时从队列移除并以
// CancellationError 唤醒（TS 侧排队任务被杀会残留 pending 记账，此处更强）。
import Foundation

public actor JobScheduler {
    private struct PendingTask {
        let priority: Int
        let order: Int
        let weight: Int
        let start: (Error?) -> Void
    }

    private var activeWeight = 0
    private var order = 0
    private var pending: [PendingTask] = []
    private let budget: Int

    public init(budget: Int? = nil) {
        let cpus = ProcessInfo.processInfo.processorCount
        self.budget = max(1, budget ?? max(2, min(6, cpus - 1)))
    }

    /// 以 `priority` 优先、`weight` 单位预算运行 `task`。超预算时排队等待；
    /// 排队期间任务被取消则以 CancellationError 抛出（不记账、不泄漏预算）。
    public func run<T>(
        priority: Int = 1,
        weight: Int = 1,
        _ task: () async throws -> T
    ) async throws -> T {
        let units = max(1, weight)
        var accounted = false
        let queued = activeWeight + units > budget
        if queued {
            try await enqueue(priority: priority, units: units)
            // 唤醒即已记账（releasePending 内记账）。
            accounted = true
        } else {
            activeWeight += units
            accounted = true
        }
        defer {
            if accounted {
                activeWeight -= units
                releasePending()
            }
        }
        return try await task()
    }

    private func enqueue(priority: Int, units: Int) async throws {
        let myOrder = order
        order += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending.append(
                    PendingTask(priority: priority, order: myOrder, weight: units) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
                pending.sort { a, b in
                    a.priority < b.priority || (a.priority == b.priority && a.order < b.order)
                }
            }
        } onCancel: {
            Task { await self.cancelPending(order: myOrder) }
        }
    }

    /// 排队任务被取消：从队列移除并以 CancellationError 唤醒。
    /// 若已不在队列（已被准入/运行中），为 no-op——运行期取消由任务自身处理。
    private func cancelPending(order target: Int) {
        guard let index = pending.firstIndex(where: { $0.order == target }) else { return }
        pending[index].start(CancellationError())
        pending.remove(at: index)
    }

    private func releasePending() {
        guard !pending.isEmpty else { return }
        let queued = pending
        pending = []
        var available = budget - activeWeight
        for task in queued {
            if task.weight <= available {
                available -= task.weight
                activeWeight += task.weight
                task.start(nil)
            } else {
                pending.append(task)
            }
        }
    }
}

/// 进程级共享调度器实例（对应 TS 单例 heavyTaskScheduler）。
public let sharedJobScheduler = JobScheduler()
