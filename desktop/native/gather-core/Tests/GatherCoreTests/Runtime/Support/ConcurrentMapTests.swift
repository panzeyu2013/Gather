// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Support/ConcurrentMapTests.swift
// W2a 前置：ConcurrentMap / IndexCursor 行为测试。
// 覆盖：空输入、保序（完成序无关）、滑动窗口 runner 上限（恰满窗口且常驻）、
// 首错停止调度与错误原样传播、取消传播（可取消 body 抛错 / 不可取消 body 返回
// 有序部分结果）、concurrency <= 0 归一化、IndexCursor 取号不重不漏与 markFailed 幂等。
// 无数据库、无 NSLock（探针全部 actor 化）。

import Testing
import Foundation
@testable import GatherCore

// MARK: - 测试支撑

/// 并发窗口探针：记录累计启动/完成数与同时在飞峰值（actor 隔离，无锁）。
private actor WindowProbe {
    private var startedCount = 0
    private var finishedCount = 0
    private var activeCount = 0
    private var maxActiveCount = 0

    var started: Int { startedCount }
    var finished: Int { finishedCount }
    var active: Int { activeCount }
    var maxActive: Int { maxActiveCount }

    func enter() {
        startedCount += 1
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
        finishedCount += 1
    }
}

/// 会合点：恰 expected 个 runner 到达后一起放行；forceOpen 兜底，保证用例不挂死。
private actor Rendezvous {
    private let expected: Int
    private var arrived = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() async {
        if released { return }
        arrived += 1
        if arrived >= expected {
            release()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func forceOpen() {
        release()
    }

    private func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// 完成顺序记录（保序断言用）。
private actor CompletionOrder {
    private var order: [Int] = []

    func record(_ value: Int) { order.append(value) }

    var values: [Int] { order }
}

private struct WaitTimeout: Error {}

/// 在 timeout 内轮询条件；超时抛错（避免实现偏差时用例挂死）。
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw WaitTimeout()
}

private struct Boom: Error, Equatable {
    let index: Int
}

// MARK: - ConcurrentMap.run

struct ConcurrentMapTests {

    @Test func emptyInputReturnsEmptyWithoutCallingBody() async throws {
        let results = try await ConcurrentMap.run([Int](), concurrency: 4) { value -> Int in
            Issue.record("空输入不得调用 body")
            return value
        }
        #expect(results.isEmpty)
    }

    @Test func resultsPreserveInputOrderDespiteOutOfOrderCompletion() async throws {
        let items = Array(0..<64)
        let completion = CompletionOrder()
        let results = try await ConcurrentMap.run(items, concurrency: 8) { value -> Int in
            // 第 0 项故意最慢：完成序被打乱，保序断言才有意义。
            try await Task.sleep(for: .milliseconds(value == 0 ? 150 : 0))
            await completion.record(value)
            return value * 2
        }
        #expect(results == items.map { $0 * 2 })
        let order = await completion.values
        #expect(order.count == items.count)
        #expect(order.last == 0, "第 0 项应最后完成（完成序被打乱），实测完成序末位=\(String(describing: order.last))")
    }

    @Test func windowKeepsExactlyConcurrencyRunnersResident() async throws {
        let limit = 4
        let total = 24
        let probe = WindowProbe()
        let rendezvous = Rendezvous(expected: limit)
        // 兜底：实现若未开满窗口，5s 后放行，让断言失败而不是用例挂死。
        let fallback = Task {
            try? await Task.sleep(for: .seconds(5))
            await rendezvous.forceOpen()
        }
        let results = try await ConcurrentMap.run(Array(0..<total), concurrency: limit) { value -> Int in
            await probe.enter()
            await rendezvous.arrive()
            try await Task.sleep(for: .milliseconds(2))
            await probe.leave()
            return value
        }
        fallback.cancel()
        #expect(results == Array(0..<total))
        let maxActive = await probe.maxActive
        let started = await probe.started
        let finished = await probe.finished
        #expect(maxActive == limit, "滑动窗口应恰好常驻 \(limit) 个 runner，实测峰值 \(maxActive)")
        #expect(started == total)
        #expect(finished == total)
    }

    @Test func nonPositiveConcurrencyRunsSerially() async throws {
        let zeroProbe = WindowProbe()
        let zeroResults = try await ConcurrentMap.run([10, 20, 30], concurrency: 0) { value -> Int in
            await zeroProbe.enter()
            try await Task.sleep(for: .milliseconds(2))
            await zeroProbe.leave()
            return value
        }
        #expect(zeroResults == [10, 20, 30])
        let zeroMax = await zeroProbe.maxActive
        #expect(zeroMax == 1, "concurrency <= 0 应按 1 处理，实测峰值 \(zeroMax)")

        let negativeProbe = WindowProbe()
        let negativeResults = try await ConcurrentMap.run([1, 2], concurrency: -7) { value -> Int in
            await negativeProbe.enter()
            try await Task.sleep(for: .milliseconds(2))
            await negativeProbe.leave()
            return value
        }
        #expect(negativeResults == [1, 2])
        let negativeMax = await negativeProbe.maxActive
        #expect(negativeMax == 1)
    }

    @Test func firstErrorStopsSchedulingAndPropagatesOriginalError() async throws {
        let total = 50
        let limit = 4
        let failingIndex = 5
        let probe = WindowProbe()
        var caught: Error?
        do {
            _ = try await ConcurrentMap.run(Array(0..<total), concurrency: limit) { value -> Int in
                await probe.enter()
                try await Task.sleep(for: .milliseconds(5))
                if value == failingIndex { throw Boom(index: value) }
                await probe.leave()
                return value
            }
            Issue.record("body 抛错时必须抛出")
        } catch {
            caught = error
        }
        let boom = caught as? Boom
        #expect(boom == Boom(index: failingIndex), "首个失败应原样传播，不得包装：\(String(describing: caught))")

        // 取号按序：失败项及其之前必须都已启动；首错后仅允许在飞项再取一两个号
        // （markFailed 是 actor 投递，与旧实现的锁获取同样不与「抛错」原子）。
        let startedAtThrow = await probe.started
        #expect(startedAtThrow >= failingIndex + 1)
        #expect(startedAtThrow < total, "首错必须停止调度，不得跑完全部输入：\(startedAtThrow)/\(total)")
        #expect(startedAtThrow <= failingIndex + 2 * limit, "首错后只允许少量在飞项继续取号，实测 \(startedAtThrow)")

        try await Task.sleep(for: .milliseconds(100))
        let settled = await probe.started
        #expect(settled == startedAtThrow, "首错后不得再调度新项：\(startedAtThrow) -> \(settled)")
    }

    @Test func cancellationPropagatesToRunnersAndThrows() async throws {
        let total = 100
        let limit = 4
        let probe = WindowProbe()
        let task = Task { () -> [Int] in
            try await ConcurrentMap.run(Array(0..<total), concurrency: limit) { value -> Int in
                await probe.enter()
                try await Task.sleep(for: .seconds(30))
                await probe.leave()
                return value
            }
        }
        try await waitUntil { await probe.started >= limit }
        task.cancel()
        let result = await task.result
        switch result {
        case .success(let values):
            Issue.record("可取消 body 在取消后应抛 CancellationError，实际返回 \(values.count) 项")
        case .failure(let error):
            #expect(error is CancellationError, "取消应传播为 CancellationError，实际 \(error)")
        }
        let startedAtReturn = await probe.started
        #expect(startedAtReturn <= limit + 1, "取消后不得继续取号：\(startedAtReturn)")
        try await Task.sleep(for: .milliseconds(50))
        let settled = await probe.started
        #expect(settled == startedAtReturn)
    }

    @Test func cancellationWithUncooperativeBodyReturnsOrderedPartialResults() async throws {
        let total = 50
        let limit = 3
        let probe = WindowProbe()
        let task = Task { () -> [Int] in
            try await ConcurrentMap.run(Array(0..<total), concurrency: limit) { value -> Int in
                await probe.enter()
                // 不可取消等待：取消信号无法中断已完成取号的项。
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        continuation.resume()
                    }
                }
                await probe.leave()
                return value
            }
        }
        try await waitUntil { await probe.started >= limit }
        task.cancel()
        let result = await task.result
        switch result {
        case .success(let values):
            #expect(values.count < total, "取消后不得跑完全部输入")
            #expect(values == Array(0..<values.count), "部分结果必须是按序前缀：\(values)")
        case .failure(let error):
            Issue.record("不可取消 body 不应把取消变成抛错（旧实现语义），实际 \(error)")
        }
        let started = await probe.started
        #expect(started <= limit + 1, "取消后不得继续取号：\(started)")
    }
}

// MARK: - IndexCursor

struct IndexCursorTests {

    @Test func handsOutEachIndexExactlyOnceUnderConcurrency() async {
        let count = 500
        let cursor = IndexCursor(count: count)
        let chunks = await withTaskGroup(of: [Int].self) { group -> [[Int]] in
            for _ in 0..<8 {
                group.addTask {
                    var local: [Int] = []
                    while let index = await cursor.nextIndex() { local.append(index) }
                    return local
                }
            }
            var all: [[Int]] = []
            for await chunk in group { all.append(chunk) }
            return all
        }
        let flattened = chunks.flatMap { $0 }
        #expect(flattened.sorted() == Array(0..<count), "取号必须不重不漏")
    }

    @Test func stopsAfterFailureAndIsIdempotent() async {
        let cursor = IndexCursor(count: 3)
        let first = await cursor.nextIndex()
        let second = await cursor.nextIndex()
        #expect(first == 0)
        #expect(second == 1)
        await cursor.markFailed()
        let afterFailure = await cursor.nextIndex()
        #expect(afterFailure == nil)
        await cursor.markFailed()
        let stillNil = await cursor.nextIndex()
        #expect(stillNil == nil)
    }

    @Test func zeroOrNegativeCountReturnsNil() async {
        let zero = IndexCursor(count: 0)
        let zeroIndex = await zero.nextIndex()
        #expect(zeroIndex == nil)
        let negative = IndexCursor(count: -3)
        let negativeIndex = await negative.nextIndex()
        #expect(negativeIndex == nil)
    }
}
