// desktop/native/gather-core/Tests/GatherCoreTests/Concurrent/BatchRunnerTests.swift
// 共享 batchAsync 包装体的直接语义测试：并发上限、保序、错误传播（完成序 +
// 停发新号 + 取消在飞项）、调用方取消、空输入/非正并发。全部为小规模内存用例，
// 无文件/DB/真实 sleep 长路径（最长一次 sleep 20ms，其余用 continuation 门控）。
import Testing
import Foundation
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis

private enum BatchRunnerTestError: Error, Equatable {
    case slow
    case fast
}

/// 线程安全观察器（body 由多个 worker 并发执行）。
private final class BatchRunnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [Int] = []
    private var cancelled: [Int] = []
    private var live = 0
    private var peak = 0

    @discardableResult
    func enter(_ index: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        starts.append(index)
        live += 1
        peak = max(peak, live)
        return live
    }

    func leave() {
        lock.lock(); live -= 1; lock.unlock()
    }

    func markCancelled(_ index: Int) {
        lock.lock(); cancelled.append(index); lock.unlock()
    }

    var snapshot: (starts: [Int], cancelled: [Int], peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, cancelled, peak)
    }
}

/// 一次性门闩：把在飞 body 卡住，直到测试显式放行（用于确定性地构造并发/取消时序）。
private actor BatchRunnerGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isOpen { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

struct BatchRunnerTests {
    /// 并发上限：worker 数 = min(concurrency, count)，在飞 body 数从不超过该值，
    /// 且能真正跑满（滑动窗口，不是串行）；24 项不重不漏。
    @Test func concurrencyCapIsRespectedAndSaturated() async throws {
        let recorder = BatchRunnerRecorder()
        let results = try await batchAsync(Array(0..<24), concurrency: 4) { index -> Int in
            recorder.enter(index)
            try? await Task.sleep(nanoseconds: 20_000_000)
            recorder.leave()
            return index
        }
        #expect(results == Array(0..<24))
        let snap = recorder.snapshot
        #expect(snap.peak == 4)                     // 4 个 worker 全部入场（真并发）
        #expect(snap.peak <= 4)                     // 上限不被越过
        #expect(snap.starts.count == 24)            // 不重不漏
        #expect(Set(snap.starts) == Set(0..<24))
    }

    /// 保序：返回数组按输入索引，而非完成顺序（本用例完成序与输入序相反）。
    @Test func resultsPreserveInputOrderRegardlessOfCompletionOrder() async throws {
        let items = Array(0..<8)
        let results = try await batchAsync(items, concurrency: 8) { index -> Int in
            try? await Task.sleep(nanoseconds: UInt64((items.count - index) * 5_000_000))
            return index * 2
        }
        #expect(results == items.map { $0 * 2 })
    }

    /// 错误传播：1 号先抛 .fast、0 号在飞（睡 2s，只能被取消唤醒）时，抛出 .fast
    /// ——完成序第一个错误胜出，而非输入索引序；抛错后停发新号（2/3 永不启动），
    /// 且 group 取消剩余子任务 → 0 号观察到取消。
    @Test func firstErrorInCompletionOrderWinsAndStopsDispatch() async throws {
        let recorder = BatchRunnerRecorder()
        var thrown: BatchRunnerTestError?
        do {
            _ = try await batchAsync([0, 1, 2, 3], concurrency: 2) { index -> Int in
                recorder.enter(index)
                if index == 1 {
                    // 等慢项确实入场后再失败，保证“完成序 vs 输入索引序”可判定。
                    var spins = 0
                    while recorder.snapshot.starts.count < 2 && spins < 100_000 {
                        await Task.yield()
                        spins += 1
                    }
                    recorder.leave()
                    throw BatchRunnerTestError.fast
                }
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    recorder.markCancelled(index)
                    recorder.leave()
                    throw BatchRunnerTestError.slow
                }
                recorder.leave()
                return index
            }
        } catch let error as BatchRunnerTestError {
            thrown = error
        }
        #expect(thrown == .fast)
        let snap = recorder.snapshot
        #expect(Set(snap.starts) == Set([0, 1]))    // 停发：2/3 未启动
        #expect(snap.cancelled == [0])              // 兄弟任务被取消（在飞项收尾后才抛）
    }

    /// 调用方取消：两个 worker 各占一项后被门闩卡住，取消后放行——不再取新号，
    /// 返回已完成项的部分结果（body 不抛，故包装体不抛）。
    @Test func cancellingCallerStopsNewDispatch() async throws {
        let recorder = BatchRunnerRecorder()
        let gate = BatchRunnerGate()
        let task = Task { () -> [Int] in
            try await batchAsync(Array(0..<64), concurrency: 2) { index -> Int in
                recorder.enter(index)
                await gate.wait()
                recorder.leave()
                return index
            }
        }
        var spins = 0
        while recorder.snapshot.starts.count < 2 && spins < 100_000 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            spins += 1
        }
        #expect(recorder.snapshot.starts.count == 2)   // 并发上限：只启动 2 项
        task.cancel()
        await gate.open()
        let results = try await task.value
        #expect(results == [0, 1])                      // 取消后不再取号：停在第 2 项
        #expect(recorder.snapshot.starts.count == 2)
    }

    /// 边界：空输入不建 task group、body 零调用；concurrency <= 0 视为 1 且仍全部执行。
    @Test func emptyInputAndNonPositiveConcurrency() async throws {
        let recorder = BatchRunnerRecorder()
        let empty = try await batchAsync([Int](), concurrency: 4) { index -> Int in
            recorder.enter(index)
            return index
        }
        #expect(empty.isEmpty)
        #expect(recorder.snapshot.starts.isEmpty)
        #expect(try await batchAsync([5, 6, 7], concurrency: 0) { $0 * 2 } == [10, 12, 14])
        #expect(try await batchAsync([5, 6, 7], concurrency: -3) { $0 * 2 } == [10, 12, 14])
    }
}
