// desktop/native/gather-core/Tests/GatherCoreTests/Services/JobServiceTests.swift
// 单一执行器行为测试：准入预算/优先级（并入旧 JobScheduler 语义）、drain 执行、
// 取消（running/queued/宽限兜底）、心跳（租约丢失 vs SQL 抛错）、自动恢复策略、
// 清理口径、waitForResult 各路径、停机兜底。

import Testing
import Foundation
@testable import GatherCore

/// 进度帧收集盒（sink 在多个执行线程回调，锁保护 + 值拷贝）。
private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(jobId: String, update: JobProgressUpdate, status: AnalysisJobStatus)] = []

    func append(job: AnalysisJobData, update: JobProgressUpdate) {
        lock.lock()
        storage.append((job.id, update, job.status))
        lock.unlock()
    }

    var frames: [(jobId: String, update: JobProgressUpdate, status: AnalysisJobStatus)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 测试环境：内存 DB + 迁移 + repo + JobService（短心跳/预算/宽限注入）。
/// 线程安全说明（Swift 6 `Sendable`）：全部存储属性构造后不可变
/// （connection/repo/service/box），`defer { Task { await env.service.stop() } }`
/// 会按值捕获整个 env；DBConnection 自带连接锁、JobService 内部状态自有锁。
/// 类无锁、无写者，故标注 `@unchecked`（不可变性即此处承诺）。
private final class Env: @unchecked Sendable {
    let connection: DBConnection
    let repo: AnalysisJobRepo
    let service: JobService
    let box = FrameBox()

    init(
        heartbeatMs: Int64 = 1_000,
        budget: Int = 2,
        leaseMs: Int64 = 30_000,
        graceMs: Int64 = 15_000,
        stopMs: Int64 = 5_000,
        maxAutoResume: Int = 3
    ) throws {
        connection = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(connection)
        repo = AnalysisJobRepo(connection: connection)
        service = JobService(
            repo: repo,
            heartbeatIntervalMs: heartbeatMs,
            weightBudget: budget,
            leaseTimeoutMs: leaseMs,
            cancelGraceMs: graceMs,
            stopTimeoutMs: stopMs,
            maxAutoResumeAttempts: maxAutoResume)
        let box = self.box
        service.setProgressSink { job, update in box.append(job: job, update: update) }
    }

    func makeParams(
        type: AnalysisJobType,
        scopeId: String = "s1",
        priority: Int? = nil,
        dedupeKey: String? = nil
    ) -> JobCreateParams {
        JobCreateParams(
            type: type,
            scopeType: "session",
            scopeId: scopeId,
            dedupeKey: dedupeKey ?? "\(type.rawValue):\(scopeId)",
            priority: priority)
    }
}

/// 简单门（continuation 版）。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var openFlag = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if !parkLocked(continuation) {
                continuation.resume()
            }
        }
    }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    /// 返回 false = 门已开，调用方立即 resume（不挂起）。
    private func parkLocked(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !openFlag else { return false }
        continuations.append(continuation)
        return true
    }

    func open() {
        lock.lock()
        openFlag = true
        let waiting = continuations
        continuations = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

/// 可选 Bool 的线程安全盒子（executor 在后台任务里写、测试主流程读；
/// async 上下文不得直接 lock/unlock，临界区收进同步方法）。
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ newValue: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    var snapshot: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 任务启动顺序盒（同上：executor 后台写、测试读）。
private final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []

    func append(_ scopeId: String) {
        lock.lock()
        defer { lock.unlock() }
        order.append(scopeId)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return order.count
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }
}

/// 计数器（executor 并发峰值）。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    func enter() {
        lock.lock()
        current += 1
        if current > peak { peak = current }
        lock.unlock()
    }

    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var maxConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

/// 有界条件等待（可在非 Sendable 的 executor 闭包内使用）：满足即返回。
/// 轮询间隔 5ms 起步、×1.6 退避、50ms 封顶；超时不吞错，由调用方断言。
private func sleepUntil(timeoutMs: Int64, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    var intervalMs = 5.0
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(Int64(intervalMs)))
        intervalMs = min(intervalMs * 1.6, 50)
    }
}

struct JobServiceTests {
    /// 条件等待：满足即返回；轮询间隔 5ms 起步、指数退避到上限 50ms 封顶
    /// （原实现固定 30ms）。超时后不吞错——由调用方断言，语义不变。
    private func waitUntil(timeoutMs: Int64 = 4_000, _ condition: () -> Bool) async {
        await sleepUntil(timeoutMs: timeoutMs, condition)
    }

    /// 观察窗口：等待「不应发生」的条件被违反而快速失败（违反即返回），
    /// 否则等满窗口（用于反向断言，窗口时长与原先的固定 sleep 相同）。
    @discardableResult
    private func dwell(ms: Int64, until violating: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < deadline {
            if violating() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return violating()
    }

    // MARK: - 执行与准入

    @Test func createRunsViaDrainAndSucceeds() async throws {
        let env = try Env()
        env.service.registerExecutor(type: .metadataScan, weight: 1) { _, context in
            context.updateProgress(JobProgressUpdate(current: 1, total: 2, message: "scanning"))
            return "ok"
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .metadataScan))
        let result: String? = try await env.service.waitForResult(jobId: job.id)
        #expect(result == "ok")

        let persisted = try env.repo.get(job.id)
        #expect(persisted?.status == .succeeded)
        #expect(persisted?.progressCurrent == 1)
        #expect(persisted?.progressTotal == 2)
    }

    @Test func weightBudgetLimitsConcurrency() async throws {
        let env = try Env(heartbeatMs: 500, budget: 2)
        let gate = Gate()
        let counter = Counter()
        env.service.registerExecutor(type: .faceAnalyze, weight: 1) { _, _ in
            counter.enter()
            await gate.wait()
            counter.exit()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s3"))
        await waitUntil { counter.maxConcurrent >= 2 }
        #expect(counter.maxConcurrent == 2, "预算 2 时最多 2 个并发，实际 \(counter.maxConcurrent)")
        gate.open()
    }

    @Test func weightBelowOneClipsToUnit() async throws {
        let env = try Env(heartbeatMs: 500, budget: 1)
        let gate = Gate()
        let counter = Counter()
        env.service.registerExecutor(type: .faceAnalyze, weight: 0) { _, _ in
            counter.enter()
            await gate.wait()
            counter.exit()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        await waitUntil { counter.maxConcurrent >= 1 }
        // 反向断言：150ms 观察窗口内若出现并发 > 1 立即失败（原先固定睡满 150ms）。
        _ = await dwell(ms: 150) { counter.maxConcurrent > 1 }
        #expect(counter.maxConcurrent == 1, "weight=0 应钳制为 1，实际 \(counter.maxConcurrent)")
        gate.open()
    }

    @Test func queueAdmitsByAscendingPriorityThenFifo() async throws {
        let env = try Env(heartbeatMs: 500, budget: 1)
        let gate = Gate()
        let order = OrderBox()
        env.service.registerExecutor(type: .faceAnalyze, weight: 1) { job, _ in
            order.append(job.scopeId)
            await gate.wait()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        // 先占住唯一预算，再排队：低优先级(5) → 高优先级(-1) → 普通(0)。
        let low = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "low", priority: 5))
        await waitUntil { order.count == 1 }
        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "urgent", priority: -1))
        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "normal", priority: 0))

        gate.open()
        await waitUntil(timeoutMs: 2_000) { order.count == 3 }
        let observed = order.value
        #expect(observed == ["low", "urgent", "normal"], "priority 越小越先，同优先级 FIFO，实际 \(observed)")
    }

    @Test func failureReleasesBudgetAndRunsNextJob() async throws {
        let env = try Env(heartbeatMs: 500, budget: 1)
        struct Boom: Error {}
        env.service.registerExecutor(type: .duplicateScan, weight: 1) { job, _ in
            if job.scopeId == "bad" { throw Boom() }
            return "second-ok"
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let bad = try env.service.create(env.makeParams(type: .duplicateScan, scopeId: "bad"))
        let good = try env.service.create(env.makeParams(type: .duplicateScan, scopeId: "good"))
        await waitUntil {
            (try? env.repo.get(bad.id)?.status == .failed) ?? false &&
            (try? env.repo.get(good.id)?.status == .succeeded) ?? false
        }
        #expect(try env.repo.get(bad.id)?.status == .failed)
        #expect(try env.repo.get(good.id)?.status == .succeeded, "失败必须释放预算让后续任务运行")
        let result: String? = try await env.service.waitForResult(jobId: good.id)
        #expect(result == "second-ok")
    }

    @Test func survivesManyConcurrentJobs() async throws {
        let env = try Env(heartbeatMs: 500, budget: 2)
        env.service.registerExecutor(type: .checksumBackfill, weight: 1) { _, _ in
            try? await Task.sleep(for: .milliseconds(5))
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        var ids: [String] = []
        for index in 0..<20 {
            ids.append(try env.service.create(env.makeParams(type: .checksumBackfill, scopeId: "s\(index)")).id)
        }
        for id in ids {
            let _: Void? = try? await env.service.waitForResult(jobId: id, timeoutMs: 8_000)
        }
        let done = try ids.filter { (try? env.repo.get($0)?.status == .succeeded) ?? false }.count
        #expect(done == 20, "20 个任务应全部成功，实际 \(done)")
    }

    // MARK: - 取消

    @Test func cancelsRunningJob() async throws {
        let env = try Env(heartbeatMs: 100)
        let gate = Gate()
        env.service.registerExecutor(type: .similarityAnalyze, weight: 1) { _, _ in
            await gate.wait()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .similarityAnalyze))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }
        #expect(try env.repo.get(job.id)?.status == .running)

        #expect(try env.service.cancel(job.id))
        gate.open()

        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 2_000)
            Issue.record("应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }
        #expect(try env.repo.get(job.id)?.status == .cancelled)
    }

    @Test func cancelGraceForcesCancellingToCancelled() async throws {
        let env = try Env(heartbeatMs: 100, graceMs: 150)
        let gate = Gate()
        // 无视取消的执行器：走宽限兜底路径，cancelling 必须能离开。
        env.service.registerExecutor(type: .faceAnalyze, weight: 1) { _, _ in
            await gate.wait()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .faceAnalyze))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }
        #expect(try env.service.cancel(job.id))
        #expect(try env.repo.get(job.id)?.status == .cancelling)

        await waitUntil { (try? env.repo.get(job.id)?.status == .cancelled) ?? false }
        #expect(try env.repo.get(job.id)?.status == .cancelled, "宽限期到点必须强制收尾为 cancelled")
        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 1_000)
            Issue.record("应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }
        gate.open()
    }

    @Test func cancelsQueuedJobAndEmitsRealTerminalFrame() async throws {
        let env = try Env(heartbeatMs: 100, budget: 2)
        let gate = Gate()
        env.service.registerExecutor(type: .faceAnalyze, weight: 1) { _, _ in
            await gate.wait()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let first = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        let second = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        let third = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s3"))
        await waitUntil { (try? env.repo.get(third.id)?.status == .queued) ?? false }
        #expect(try env.repo.get(third.id)?.status == .queued, "预算占满时第三个任务应排队")

        #expect(try env.service.cancel(third.id))
        await waitUntil {
            env.box.frames.contains { $0.jobId == third.id && $0.status == .cancelled }
        }
        let terminal = env.box.frames.first { $0.jobId == third.id && $0.status == .cancelled }
        #expect(terminal != nil, "queued 取消应补发终态帧")
        #expect(terminal?.update.current == 0 && terminal?.update.total == 0,
                "终态帧进度必须来自真实行（不得伪造 1/1 100%）")

        gate.open()
        let _: Void? = try? await env.service.waitForResult(jobId: first.id, timeoutMs: 2_000)
        let _: Void? = try? await env.service.waitForResult(jobId: second.id, timeoutMs: 2_000)
        do {
            let _: String? = try await env.service.waitForResult(jobId: third.id, timeoutMs: 2_000)
            Issue.record("排队任务取消后 waitForResult 应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }
    }

    @Test func queuedCancelResultSurvivesDrainClaimFailure() async throws {
        let env = try Env()
        // 未 start：排队取消登记 JobCancelledError；随后 start 的 drain 不得用
        // 迟到的 leaseLost 覆盖等待者结果。
        let job = try env.service.create(env.makeParams(type: .duplicateScan))
        #expect(try env.service.cancel(job.id))
        env.service.start()
        defer { Task { await env.service.stop() } }
        // 等 drain 认领该行（原先固定睡 150ms）；超时则照旧走后续断言。
        await waitUntil(timeoutMs: 150) { (try? env.repo.get(job.id)?.status == .queued) == false }
        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 500)
            Issue.record("应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        } catch {
            Issue.record("错误类型漂移：\(error)")
        }
    }

    @Test func cancelledRunningJobReleasesBudget() async throws {
        let env = try Env(heartbeatMs: 100, budget: 1)
        let gate = Gate()
        env.service.registerExecutor(type: .faceAnalyze, weight: 1) { _, context in
            await gate.wait()
            try context.throwIfCancelled()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let first = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        await waitUntil { (try? env.repo.get(first.id)?.status == .running) ?? false }
        #expect(try env.service.cancel(first.id))
        gate.open()
        await waitUntil { (try? env.repo.get(first.id)?.status == .cancelled) ?? false }

        let second = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        let _: Void? = try? await env.service.waitForResult(jobId: second.id, timeoutMs: 2_000)
        #expect(try env.repo.get(second.id)?.status == .succeeded, "取消释放预算后新任务应能运行")
        _ = second
    }

    // MARK: - 心跳

    @Test func heartbeatLeaseLossAbortsRunButKeepsRowRunning() async throws {
        let env = try Env(heartbeatMs: 50, budget: 1)
        let gate = Gate()
        let observedAbort = BoolBox()
        env.service.registerExecutor(type: .duplicateScan, weight: 1) { _, context in
            await gate.wait()
            // 等心跳（0 行返回）把中止信号置位：最多 250ms（≈5 个心跳周期），
            // 置位即返回；未置位则窗口结束后照旧断言 aborted == true。
            await sleepUntil(timeoutMs: 250) { context.signal.aborted }
            observedAbort.set(context.signal.aborted)
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .duplicateScan))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }
        // 跨进程租约被夺：0 行返回 = 租约丢失。
        _ = try env.connection.prepare(
            "UPDATE analysis_jobs SET lease_owner = 'thief', updated_at = ? WHERE id = ?"
        ).run([.text(Date().ISO8601Format()), .text(job.id)])

        gate.open()
        await waitUntil(timeoutMs: 2_000) { observedAbort.snapshot != nil }
        let aborted = observedAbort.snapshot
        #expect(aborted == true, "心跳 0 行必须在执行器内传播中止")
        #expect(try env.repo.get(job.id)?.status == .running,
                "租约被夺时本执行器不得改写对端行状态")
    }

    @Test func heartbeatSqlErrorDoesNotAbortOrCancelJob() async throws {
        let env = try Env(heartbeatMs: 50, budget: 1)
        let gate = Gate()
        let observedAbort = BoolBox()
        env.service.registerExecutor(type: .duplicateScan, weight: 1) { _, context in
            await gate.wait()
            // 覆盖多个心跳周期（≥3 次抛错触发读回确认路径）。反向断言：
            // 400ms 窗口内一旦被置位立即失败，否则等满窗口。
            await sleepUntil(timeoutMs: 400) { context.signal.aborted }
            observedAbort.set(context.signal.aborted)
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .duplicateScan))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }

        // 模拟瞬时 DB 故障：heartbeat UPDATE 持续抛错（表被外部改名）。
        _ = try env.connection.prepare("ALTER TABLE analysis_jobs RENAME TO analysis_jobs_hidden").run()
        gate.open()
        await waitUntil(timeoutMs: 2_000) { observedAbort.snapshot != nil }
        let aborted = observedAbort.snapshot
        #expect(aborted == false, "SQL 抛错不得被当作取消/租约丢失")

        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 1_000)
            Issue.record("应抛 leaseLost（写库失败），而不是 JobCancelledError")
        } catch is JobCancelledError {
            Issue.record("SQL 抛错被误判为用户取消")
        } catch {
            // 预期：leaseLost / jobFailed
        }
    }

    // MARK: - 恢复

    @Test func interruptedResumableTypeAutoResumes() async throws {
        let env = try Env(heartbeatMs: 500, budget: 2)
        // 预置：running 行 + 过期心跳（模拟崩溃遗留）。
        let job = try env.service.create(env.makeParams(type: .metadataScan))
        _ = try env.repo.claim(id: job.id, leaseOwner: "dead-process")
        _ = try env.connection.prepare(
            "UPDATE analysis_jobs SET heartbeat_at = '2020-01-01T00:00:00.000Z' WHERE id = ?"
        ).run([.text(job.id)])

        env.service.registerExecutor(type: .metadataScan, weight: 1) { _, _ in "recovered" }
        env.service.start()
        defer { Task { await env.service.stop() } }

        await waitUntil { (try? env.repo.get(job.id)?.status == .succeeded) ?? false }
        let row = try env.repo.get(job.id)
        #expect(row?.status == .succeeded, "interrupted 的可恢复类型必须自动恢复")
        #expect(row?.attemptCount == 2, "自动恢复是一次新认领，attempt_count 递增")
    }

    @Test func nonResumableThumbnailStaysInterrupted() async throws {
        let env = try Env()
        let job = try env.service.create(env.makeParams(type: .thumbnailBuild))
        _ = try env.connection.prepare("UPDATE analysis_jobs SET status = 'interrupted' WHERE id = ?")
            .run([.text(job.id)])
        var executed = false
        env.service.registerExecutor(type: .thumbnailBuild) { _, _ in
            executed = true
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }
        // 反向断言：250ms 窗口内发生自动恢复即快速失败（原先固定睡满 250ms）。
        _ = await dwell(ms: 250) { executed }

        #expect(!executed, "缩略图预热在 nonAutoResumableTypes 内，不得自动恢复")
        #expect(try env.repo.get(job.id)?.status == .interrupted)
    }

    @Test func autoResumeStopsAtAttemptCap() async throws {
        let env = try Env(maxAutoResume: 3)
        let job = try env.service.create(env.makeParams(type: .metadataScan))
        _ = try env.connection.prepare(
            "UPDATE analysis_jobs SET status = 'interrupted', attempt_count = 5 WHERE id = ?"
        ).run([.text(job.id)])
        var executed = false
        env.service.registerExecutor(type: .metadataScan, weight: 1) { _, _ in
            executed = true
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }
        // 反向断言：250ms 窗口内发生自动恢复即快速失败（原先固定睡满 250ms）。
        _ = await dwell(ms: 250) { executed }

        #expect(!executed, "超过自动恢复尝试上限的任务不得再自动恢复")
        #expect(try env.repo.get(job.id)?.status == .interrupted)
    }

    // MARK: - 停机

    @Test func stopInterruptsUnfinishedRunningJob() async throws {
        let env = try Env(heartbeatMs: 100, stopMs: 300)
        let gate = Gate()
        env.service.registerExecutor(type: .similarityAnalyze, weight: 1) { _, _ in
            await gate.wait()
            return nil
        }
        env.service.start()
        let job = try env.service.create(env.makeParams(type: .similarityAnalyze))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }

        await env.service.stop()

        #expect(try env.repo.get(job.id)?.status == .interrupted,
                "停机超时兜底必须把 running 迁到 interrupted，不能留下 running")
        gate.open()
    }

    // MARK: - 清理与等待

    @Test func clearCompletedOnlyRemovesSucceededByDefault() throws {
        let env = try Env()
        let scan = try env.service.create(env.makeParams(type: .metadataScan, scopeId: "scan"))
        let export = try env.service.create(env.makeParams(type: .exportExecute, scopeId: "export"))
        let dup = try env.service.create(env.makeParams(type: .duplicateScan, scopeId: "dup"))
        let failed = try env.service.create(env.makeParams(type: .qualityScore, scopeId: "failed"))
        _ = try env.connection.prepare(
            "UPDATE analysis_jobs SET status = 'succeeded' WHERE scope_id IN ('scan', 'export', 'dup')"
        ).run()
        _ = try env.connection.prepare(
            "UPDATE analysis_jobs SET status = 'failed', error_message = 'keep-me' WHERE scope_id = 'failed'"
        ).run()

        let cleared = try env.service.clearCompleted()
        #expect(cleared == 1, "默认只清成功终态且保护阶段证据，实际 \(cleared)")
        #expect(try env.repo.get(scan.id) != nil)
        #expect(try env.repo.get(export.id) != nil)
        #expect(try env.repo.get(dup.id) == nil)
        #expect(try env.repo.get(failed.id)?.errorMessage == "keep-me", "失败原因不得被顺手删除")

        let clearedFailed = try env.service.clearCompleted(statuses: [.failed])
        #expect(clearedFailed == 1)
        #expect(try env.repo.get(failed.id) == nil, "显式点名失败终态才允许删除")
    }

    @Test func retryRequeuesFailedJob() async throws {
        let env = try Env()
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .duplicateScan))
        _ = try env.repo.claim(id: job.id, leaseOwner: env.service.leaseOwner)
        _ = try env.repo.finish(id: job.id, leaseOwner: env.service.leaseOwner, status: .failed, error: ("worker_error", "boom"))
        #expect(try env.repo.get(job.id)?.status == .failed)
        #expect(try env.service.retry(job.id))
        #expect(try env.repo.get(job.id)?.status == .queued)
    }

    @Test func waitForResultHandlesPersistedTerminalStates() async throws {
        let env = try Env()
        env.service.start()
        defer { Task { await env.service.stop() } }

        let failed = try env.service.create(env.makeParams(type: .qualityScore))
        _ = try env.repo.claim(id: failed.id, leaseOwner: env.service.leaseOwner)
        _ = try env.repo.finish(
            id: failed.id, leaseOwner: env.service.leaseOwner, status: .failed,
            error: ("SCAN_READ_FAILED", "boom"))
        do {
            let _: String? = try await env.service.waitForResult(jobId: failed.id, timeoutMs: 500)
            Issue.record("失败终态应抛错")
        } catch let JobServiceError.jobFailed(id, message) {
            #expect(id == failed.id)
            #expect(message.contains("boom"))
        }

        let interrupted = try env.service.create(env.makeParams(type: .qualityScore, scopeId: "s4"))
        _ = try env.connection.prepare("UPDATE analysis_jobs SET status = 'interrupted', error_message = 'worker_lost' WHERE id = ?")
            .run([.text(interrupted.id)])
        do {
            let _: String? = try await env.service.waitForResult(jobId: interrupted.id, timeoutMs: 500)
            Issue.record("中断终态应抛错")
        } catch let JobServiceError.jobFailed(id, message) {
            #expect(id == interrupted.id)
            #expect(message == "worker_lost")
        }

        let cancelled = try env.service.create(env.makeParams(type: .qualityScore, scopeId: "s2"))
        _ = try env.repo.claim(id: cancelled.id, leaseOwner: env.service.leaseOwner)
        _ = try env.repo.finish(id: cancelled.id, leaseOwner: env.service.leaseOwner, status: .cancelled)
        do {
            let _: String? = try await env.service.waitForResult(jobId: cancelled.id, timeoutMs: 500)
            Issue.record("取消终态应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }

        let done = try env.service.create(env.makeParams(type: .qualityScore, scopeId: "s3"))
        _ = try env.repo.claim(id: done.id, leaseOwner: env.service.leaseOwner)
        _ = try env.repo.finish(id: done.id, leaseOwner: env.service.leaseOwner, status: .succeeded)
        let value: String? = try await env.service.waitForResult(jobId: done.id, timeoutMs: 500)
        #expect(value == nil)

        do {
            let _: String? = try await env.service.waitForResult(jobId: "nope", timeoutMs: 500)
            Issue.record("不存在任务应抛错")
        } catch let JobServiceError.jobNotFound(id) {
            #expect(id == "nope")
        }
    }

    @Test func waitForResultTimesOutForPendingJob() async throws {
        let env = try Env()
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .thumbnailBuild))
        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 200)
            Issue.record("应超时")
        } catch let JobServiceError.waitForResultTimeout(id) {
            #expect(id == job.id)
        }
    }

    @Test func waitForResultReturnsImmediatelyForCompletedButUntakenResult() async throws {
        let env = try Env()
        env.service.registerExecutor(type: .duplicateScan, weight: 1) { _, _ in "early-result" }
        env.service.start()
        defer { Task { await env.service.stop() } }
        let job = try env.service.create(env.makeParams(type: .duplicateScan))
        await waitUntil { (try? env.repo.get(job.id)?.status == .succeeded) ?? false }

        // 结果已登记但尚未被取走：必须立即返回而非等到超时。
        let value: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 500)
        #expect(value == "early-result")
    }

    @Test func throttlesProgressAndFlushesCheckpoint() async throws {
        let env = try Env()
        env.service.registerExecutor(type: .thumbnailBuild, weight: 1) { _, context in
            for i in 1...5 {
                context.updateProgress(JobProgressUpdate(current: i, total: 10))
            }
            context.updateCheckpoint(["phase": .string("t1")])
            try context.throwIfCancelled()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .thumbnailBuild))
        let _: Void? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 2_000)

        let persisted = try env.repo.get(job.id)
        #expect(persisted?.progressCurrent == 5)
        #expect(persisted?.checkpoint["phase"] == .string("t1"))
        let frames = env.box.frames.filter { $0.jobId == job.id }
        #expect(frames.contains { $0.update.checkpoint?["phase"] == .string("t1") })
        #expect(frames.count <= 8, "250ms 节流窗口内应合并上报，实际 \(frames.count)")
    }

    @Test func stoppedServiceDoesNotDrain() async throws {
        let env = try Env()
        var executed = false
        env.service.registerExecutor(type: .checksumBackfill, weight: 1) { _, _ in
            executed = true
            return nil
        }
        let job = try env.service.create(env.makeParams(type: .checksumBackfill))
        // 反向断言：200ms 窗口内若发生 drain 立即失败（原先固定睡满 200ms）。
        _ = await dwell(ms: 200) { executed }
        #expect(!executed)
        #expect(try env.repo.get(job.id)?.status == .queued)
    }

    // MARK: - 默认 weight / 批量取消 / 幂等取消 / 跨进程取消 / 停机兜底

    /// 未显式给 weight 时，重计算类型（face/similarity/duplicate）按 defaultWeight
    /// 吃 2 个单位：预算 2 也只能跑 1 个。变异「defaultWeight 重计算 → 1」可杀。
    @Test func defaultHeavyWeightConsumesTwoBudgetUnits() async throws {
        let env = try Env(heartbeatMs: 500, budget: 2)
        let gate = Gate()
        let counter = Counter()
        env.service.registerExecutor(type: .faceAnalyze) { _, _ in
            counter.enter()
            await gate.wait()
            counter.exit()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "f1"))
        _ = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "f2"))
        await waitUntil { counter.maxConcurrent >= 1 }
        _ = await dwell(ms: 150) { counter.maxConcurrent > 1 }
        #expect(counter.maxConcurrent == 1, "faceAnalyze 默认 weight=2，预算 2 时不得并发两个，实际 \(counter.maxConcurrent)")
        gate.open()
    }

    /// 正向对照：轻任务默认 weight=1，预算 2 时可并发 2 —— 证明上面的观察窗口
    /// 真的能观察到并发（不是恒真断言）。
    @Test func defaultLightWeightAllowsTwoConcurrent() async throws {
        let env = try Env(heartbeatMs: 500, budget: 2)
        let gate = Gate()
        let counter = Counter()
        env.service.registerExecutor(type: .metadataScan) { _, _ in
            counter.enter()
            await gate.wait()
            counter.exit()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        _ = try env.service.create(env.makeParams(type: .metadataScan, scopeId: "m1"))
        _ = try env.service.create(env.makeParams(type: .metadataScan, scopeId: "m2"))
        await waitUntil { counter.maxConcurrent >= 2 }
        #expect(counter.maxConcurrent == 2, "metadataScan 默认 weight=1，预算 2 时应并发两个，实际 \(counter.maxConcurrent)")
        gate.open()
    }

    /// cancelScope 必须同时匹配 type 与 scopeId：变异「去掉 scopeId 比较」可杀。
    @Test func cancelScopeMatchesBothTypeAndScopeId() throws {
        let env = try Env()
        // 未 start：三行都停在 queued，取消路径无需执行器参与。
        let sameTypeSameScope = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        let sameTypeOtherScope = try env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        let otherTypeSameScope = try env.service.create(env.makeParams(type: .metadataScan, scopeId: "s1"))

        let cancelled = try env.service.cancelScope(type: .faceAnalyze, scopeId: "s1")

        #expect(cancelled == 1, "只应命中同类型同 scope 的一行，实际 \(cancelled)")
        #expect(try env.repo.get(sameTypeSameScope.id)?.status == .cancelled)
        #expect(try env.repo.get(sameTypeOtherScope.id)?.status == .queued, "同类型不同 scope 不得被取消")
        #expect(try env.repo.get(otherTypeSameScope.id)?.status == .queued, "不同类型同 scope 不得被取消")
    }

    /// cancelling 行的重复取消必须幂等返回 true，且宽限兜底仍会把它收尾为 cancelled。
    /// 变异「alreadyCancelling 分支返回 false」可杀。
    @Test func cancellingJobIsIdempotentlyCancellable() async throws {
        let env = try Env(heartbeatMs: 100, budget: 1, graceMs: 200)
        let gate = Gate()
        env.service.registerExecutor(type: .faceAnalyze, weight: 1) { _, _ in
            await gate.wait()
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .faceAnalyze))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }
        #expect(try env.service.cancel(job.id))
        #expect(try env.repo.get(job.id)?.status == .cancelling)
        #expect(try env.service.cancel(job.id), "cancelling 行的重复取消必须幂等受理")

        await waitUntil { (try? env.repo.get(job.id)?.status == .cancelled) ?? false }
        #expect(try env.repo.get(job.id)?.status == .cancelled, "重复取消后宽限期仍必须强制收尾")
        gate.open()
    }

    /// 跨进程取消（只改行、不置本地信号）：执行器成功返回也不得写 succeeded。
    /// 变异「settle 成功路径去掉 throwIfCancelled(forceDbCheck:)」可杀。
    @Test func databaseOnlyCancelRequestNeverSettlesAsSucceeded() async throws {
        let env = try Env(heartbeatMs: 100, budget: 1)
        let gate = Gate()
        env.service.registerExecutor(type: .duplicateScan, weight: 1) { _, _ in
            await gate.wait()
            return "late-ok"
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .duplicateScan))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }
        // 对端/第二实例只把行改成 cancelling，本进程的 AbortSignal 不会置位。
        _ = try env.connection.prepare(
            "UPDATE analysis_jobs SET status = 'cancelling' WHERE id = ?"
        ).run([.text(job.id)])

        gate.open()
        await waitUntil { (try? env.repo.get(job.id)?.status == .cancelled) ?? false }
        #expect(try env.repo.get(job.id)?.status == .cancelled,
                "行已 cancelling 时成功返回不得写 succeeded")
        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 1_000)
            Issue.record("跨进程取消应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }
    }

    /// 停机兜底按行真实状态迁移：cancelling → cancelled（用户取消意图优先），
    /// 不得落成 interrupted。变异「forceFinalizeAbandoned 的 cancelling 分支不存在」可杀。
    @Test func stopFinalizesCancellingRowAsCancelled() async throws {
        let env = try Env(heartbeatMs: 100, budget: 1, graceMs: 20_000, stopMs: 200)
        let gate = Gate()
        env.service.registerExecutor(type: .similarityAnalyze, weight: 1) { _, _ in
            await gate.wait()
            return nil
        }
        env.service.start()
        let job = try env.service.create(env.makeParams(type: .similarityAnalyze))
        await waitUntil { (try? env.repo.get(job.id)?.status == .running) ?? false }
        #expect(try env.service.cancel(job.id))
        #expect(try env.repo.get(job.id)?.status == .cancelling)

        // 宽限期 20s 远未到点：此时离开 cancelling 只能靠停机兜底。
        await env.service.stop()

        #expect(try env.repo.get(job.id)?.status == .cancelled,
                "停机兜底必须把 cancelling 收尾为 cancelled，而不是 interrupted")
        gate.open()
    }

    /// 进度节流是合并语义，不只是「上限不为零」：一个节流窗口内的 100 次上报
    /// 必须合并成极少数帧。变异「progressWriteIntervalMs 250 → 0」可杀。
    @Test func progressFloodIsCoalescedByThrottle() async throws {
        let env = try Env()
        env.service.registerExecutor(type: .thumbnailBuild, weight: 1) { _, context in
            for i in 1...100 {
                context.updateProgress(JobProgressUpdate(current: i, total: 200))
            }
            return nil
        }
        env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try env.service.create(env.makeParams(type: .thumbnailBuild))
        let _: Void? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 2_000)
        // 等终态帧落盒（completeResult 先唤醒等待者，emitTerminal 紧随其后）。
        _ = await dwell(ms: 100) { false }

        let frames = env.box.frames.filter { $0.jobId == job.id && $0.update.current != nil }
        #expect(frames.count <= 5, "同一节流窗口内 100 次上报必须合并成极少帧（≤5），实际 \(frames.count)")
        #expect(try env.repo.get(job.id)?.progressCurrent == 100, "合并后最新进度仍必须落库")
    }

    /// 注入的 leaseTimeoutMs 必须真的传到 recoverStale：租约 50ms 时，一个刚写过
    /// 心跳、但租约属于已死进程的 running 行，启动回收后也必须变 interrupted。
    /// 变异「recoverStale(leaseTimeoutMs:) 传常量/默认值」可杀。
    @Test func recoverStaleUsesInjectedLeaseTimeout() async throws {
        let env = try Env(leaseMs: 50)
        let job = try env.service.create(env.makeParams(type: .thumbnailBuild))
        _ = try env.repo.claim(id: job.id, leaseOwner: "dead-process")
        // claim 写入的 heartbeat_at = 当前时间；等过租约窗口再 start，
        // 让「新鲜心跳」也变成 stale。
        try? await Task.sleep(for: .milliseconds(200))

        env.service.start()
        defer { Task { await env.service.stop() } }

        await waitUntil(timeoutMs: 3_000) { (try? env.repo.get(job.id)?.status == .interrupted) ?? false }
        #expect(try env.repo.get(job.id)?.status == .interrupted,
                "leaseTimeoutMs=50ms 时必须回收心跳过期的 running 行")
    }
}
