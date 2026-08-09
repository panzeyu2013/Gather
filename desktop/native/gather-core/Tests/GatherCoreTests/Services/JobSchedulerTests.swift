// desktop/native/gather-core/Tests/GatherCoreTests/Services/JobSchedulerTests.swift
// JobScheduler 行为测试：预算准入、排队序、优先级、抛错释放、取消、并发安全。

import Testing
import Foundation
@testable import GatherCore

/// 并发运行数计数器（actor，测试并发准入用）。
private actor ConcurrencyCounter {
    private(set) var maxActive = 0
    private var current = 0

    func enter() async -> Int {
        current += 1
        if current > maxActive { maxActive = current }
        return current
    }

    func exit() {
        current -= 1
    }
}

/// 可手动放行的闸门。
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func openNow() {
        open = true
        let waiting = waiters
        waiters = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}

struct JobSchedulerTests {
    @Test func admitsTasksWithinBudget() async throws {
        let scheduler = JobScheduler(budget: 4)
        let counter = ConcurrencyCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try await scheduler.run(weight: 1) {
                        _ = await counter.enter()
                        try await Task.sleep(for: .milliseconds(50))
                        await counter.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        let maxActive = await counter.maxActive
        #expect(maxActive == 4, "预算=4 时 4 个任务应并发运行，实际最大并发 \(maxActive)")
    }

    @Test func queuesWhenOverBudget() async throws {
        let scheduler = JobScheduler(budget: 1)
        let counter = ConcurrencyCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try await scheduler.run(weight: 1) {
                        _ = await counter.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        await counter.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        let maxActive = await counter.maxActive
        #expect(maxActive == 1, "预算=1 时最多 1 个任务并发，实际最大并发 \(maxActive)")
    }

    @Test func runsHigherPriorityFirstWhenQueued() async throws {
        let scheduler = JobScheduler(budget: 1)
        let gate = Gate()

        // 任务 1 占据预算并阻塞等待放行。
        let first = Task {
            try await scheduler.run(priority: 1) {
                await gate.wait()
            }
        }
        try await Task.sleep(for: .milliseconds(30))

        // 排队：先提交低优先级，再提交高优先级。
        var executionOrder: [Int] = []
        let lock = NSLock()

        let low = Task {
            _ = try await scheduler.run(priority: 10) {
                lock.lock()
                executionOrder.append(10)
                lock.unlock()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let high = Task {
            _ = try await scheduler.run(priority: 1) {
                lock.lock()
                executionOrder.append(1)
                lock.unlock()
            }
        }
        try await Task.sleep(for: .milliseconds(30))

        await gate.openNow()
        _ = try await first.value
        _ = try await low.value
        _ = try await high.value

        #expect(executionOrder == [1, 10], "同序同预算时 priority 高者先执行，实际 \(executionOrder)")
    }

    @Test func releasesBudgetAfterTaskFailure() async throws {
        let scheduler = JobScheduler(budget: 1)

        struct Boom: Error {}

        do {
            _ = try await scheduler.run {
                throw Boom()
            }
            Issue.record("任务应抛错")
        } catch {
            // 预期路径
        }

        // 失败后预算释放：新任务应立即能运行（不阻塞）。
        let result = try await scheduler.run {
            42
        }
        #expect(result == 42)
    }

    @Test func weightClippedToAtLeastOne() async throws {
        let scheduler = JobScheduler(budget: 2)
        let counter = ConcurrencyCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = try await scheduler.run(weight: 0) {
                        _ = await counter.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        await counter.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        // weight=0 被钳制为 1：预算=2 时最多 2 个并发，第 3 个排队。
        let maxActive = await counter.maxActive
        #expect(maxActive == 2, "weight=0 应按 1 记账，最大并发应为 2，实际 \(maxActive)")
    }

    @Test func cancelledTaskDoesNotLeakBudget() async throws {
        let scheduler = JobScheduler(budget: 1)
        let gate = Gate()

        // 运行中的任务占满预算，等待放行；随后被取消 → checkCancellation 抛错 → 预算释放。
        let blocker = Task {
            try await scheduler.run {
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        blocker.cancel()

        // 排队中的任务被取消 → 从队列移除、不记账、以 CancellationError 返回。
        let queued = Task {
            try await scheduler.run { 42 }
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        do {
            _ = try await queued.value
            Issue.record("排队中被取消的任务应抛 CancellationError")
        } catch is CancellationError {
            // 预期
        } catch {
            Issue.record("非预期错误: \(error)")
        }

        // 放行 blocker；其抛错释放预算后，新任务应立即能运行。
        await gate.openNow()
        do {
            _ = try await blocker.value
        } catch is CancellationError {
            // 预期
        } catch {
            Issue.record("非预期错误: \(error)")
        }

        let value = try await scheduler.run { 1 }
        #expect(value == 1, "预算应无泄漏，新任务可立即运行")
    }

    @Test func survivesManyConcurrentTasks() async throws {
        let scheduler = JobScheduler(budget: 3)
        let counter = ConcurrencyCounter()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try await scheduler.run {
                        _ = await counter.enter()
                        try await Task.sleep(for: .milliseconds(1))
                        await counter.exit()
                        return i
                    }
                }
            }
            var sum = 0
            for try await value in group {
                sum += value
            }
            #expect(sum == (0..<100).reduce(0, +))
        }

        let maxActive = await counter.maxActive
        #expect(maxActive <= 3)
        #expect(maxActive >= 1)
    }
}
