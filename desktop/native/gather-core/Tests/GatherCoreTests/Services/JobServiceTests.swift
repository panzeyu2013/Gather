// desktop/native/gather-core/Tests/GatherCoreTests/Services/JobServiceTests.swift
// JobService 行为测试：drain 执行、取消（运行/排队）、重试、clearCompleted
// 阶段证据保护、waitForResult 各路径、进度节流与 checkpoint、心跳失败中止、
// 并发上限、stopped 停止调度。语义对齐 job.service.ts。

import Testing
import Foundation
@testable import GatherCore

private func makeTempJobStore() async throws -> any JobStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "jobs")
    return SQLiteJobStore(database: database)
}


/// 测试环境：内存 DB + 迁移 + repo + JobService（短心跳注入）。
private final class Env {
    let connection: SQLiteDatabase
    let dbPath: String
    let jobStore: any JobStore
    let service: JobService
    var progressFrames: [(jobId: String, update: JobProgressUpdate)] = []

    init(heartbeatMs: Int64 = 1_000) async throws {
        // Store 连接与旧 DBConnection 各持一条连接：临时文件库（内存库不可共享）。
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-jobs-\(UUID().uuidString).sqlite").path
        connection = try await makeMigratedStore(path: dbPath)
        jobStore = try SQLiteJobStore(database: try SQLiteDatabase(path: dbPath))
        service = JobService(jobStore: jobStore, heartbeatIntervalMs: heartbeatMs)
    }

    func makeParams(type: AnalysisJobType, scopeId: String = "s1", priority: Int? = nil) -> JobCreateParams {
        JobCreateParams(
            type: type,
            scopeType: "session",
            scopeId: scopeId,
            dedupeKey: "\(type.rawValue):\(scopeId)",
            priority: priority)
    }
}

/// 简单门（continuation 版）。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var openFlag = false

    func wait() async {
        lock.lock()
        if openFlag {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            lock.unlock()
        }
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

struct JobServiceTests {
    /// 轮询等待条件（全量并发跑时 Task 调度延迟，固定 sleep 不可靠）。
    private func waitUntil(timeoutMs: Int64 = 4_000, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func createRunsViaDrainAndSucceeds() async throws {
        let env = try await Env()
        await env.service.registerExecutor(type: .metadataScan) { _, context in
            await context.updateProgress(JobProgressUpdate(current: 1, total: 2, message: "scanning"))
            return "ok"
        }
        await env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try await env.service.create(env.makeParams(type: .metadataScan))
        let result: String? = try await env.service.waitForResult(jobId: job.id)
        #expect(result == "ok")

        let persisted = try try await env.jobStore.get(job.id)
        #expect(persisted?.status == .succeeded)
        #expect(persisted?.progressCurrent == 1)
        #expect(persisted?.progressTotal == 2)
    }

    @Test func cancelsRunningJob() async throws {
        let env = try await Env(heartbeatMs: 100)
        let gate = Gate()
        await env.service.registerExecutor(type: .similarityAnalyze) { _, _ in
            await gate.wait()
            return nil
        }
        await env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try await env.service.create(env.makeParams(type: .similarityAnalyze))
        // 等任务进入运行态（Task 调度可能有延迟）。
        await waitUntil { (try? try await env.jobStore.get(job.id)?.status == .running) ?? false }
        #expect(try try await env.jobStore.get(job.id)?.status == .running)

        let cancelled = try await env.service.cancel(job.id)
        #expect(cancelled)
        gate.open()

        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 2_000)
            Issue.record("应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }
        #expect(try try await env.jobStore.get(job.id)?.status == .cancelled)
    }

    @Test func cancelsQueuedJobAndEmitsTerminalFrame() async throws {
        let env = try await Env(heartbeatMs: 100)
        let gate = Gate()
        // 前两个任务占满并发（上限 2），第三个排队。
        await env.service.registerExecutor(type: .faceAnalyze) { _, _ in
            await gate.wait()
            return nil
        }
        await env.service.start()
        defer { Task { await env.service.stop() } }

        let first = try await env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        let second = try await env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        let third = try await env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s3"))
        // 前两个任务占满并发（上限 2）后第三个排队。
        await waitUntil { (try? try await env.jobStore.get(third.id)?.status == .queued) ?? false }
        #expect(try try await env.jobStore.get(third.id)?.status == .queued, "并发上限 2：第三个任务应排队")

        env.service.setProgressSink { job, update in
            env.progressFrames.append((job.id, update))
        }
        let cancelled = try await env.service.cancel(third.id)
        #expect(cancelled)

        // queued 取消补发终态帧。
        try await Task.sleep(for: .milliseconds(100))
        let terminal = env.progressFrames.first { $0.jobId == third.id }
        #expect(terminal != nil, "queued 取消应补发终态进度帧")
        #expect(terminal?.update.message == "cancelled")

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

    @Test func retryRequeuesFailedJob() async throws {
        let env = try await Env()
        await env.service.start()
        defer { Task { await env.service.stop() } }

        // 无 executor → drain 不会拾取；先置为 failed 再 retry → queued。
        let job = try await env.service.create(env.makeParams(type: .duplicateScan))
        let claimed = try await env.jobStore.claim(id: job.id, leaseOwner: env.service.leaseOwner)
        #expect(claimed)
        _ = try await env.jobStore.finish(id: job.id, leaseOwner: env.service.leaseOwner, status: .failed, error: ("worker_error", "boom"))
        #expect(try try await env.jobStore.get(job.id)?.status == .failed)
        let retried = try await env.service.retry(job.id)
        #expect(retried)
        #expect(try try await env.jobStore.get(job.id)?.status == .queued)
    }

    @Test func clearCompletedKeepsStageEvidence() async throws {
        let env = try await Env()
        // 直接造终态行（claim + finish）：metadata.scan 与 export.execute 应被保留。
        let scan = try await env.service.create(env.makeParams(type: .metadataScan))
        _ = try await env.jobStore.claim(id: scan.id, leaseOwner: env.service.leaseOwner)
        _ = try await env.jobStore.finish(id: scan.id, leaseOwner: env.service.leaseOwner, status: .succeeded, error: nil)
        let export = try await env.service.create(env.makeParams(type: .exportExecute, scopeId: "s2"))
        _ = try await env.jobStore.claim(id: export.id, leaseOwner: env.service.leaseOwner)
        _ = try await env.jobStore.finish(id: export.id, leaseOwner: env.service.leaseOwner, status: .succeeded, error: nil)
        let dup = try await env.service.create(env.makeParams(type: .duplicateScan, scopeId: "s3"))
        _ = try await env.jobStore.claim(id: dup.id, leaseOwner: env.service.leaseOwner)
        _ = try await env.jobStore.finish(id: dup.id, leaseOwner: env.service.leaseOwner, status: .succeeded, error: nil)

        let cleared = try await env.service.clearCompleted()
        #expect(cleared == 1, "仅非阶段证据的终态行被清理，实际 \(cleared)")
        #expect(try try await env.jobStore.get(scan.id) != nil, "metadata.scan 阶段证据应保留")
        #expect(try try await env.jobStore.get(export.id) != nil, "export.execute 阶段证据应保留")
        #expect(try try await env.jobStore.get(dup.id) == nil)
    }

    @Test func waitForResultHandlesPersistedTerminalStates() async throws {
        let env = try await Env()
        await env.service.start()
        defer { Task { await env.service.stop() } }

        // 失败终态 → 抛错。
        let failed = try await env.service.create(env.makeParams(type: .qualityScore))
        _ = try await env.jobStore.claim(id: failed.id, leaseOwner: env.service.leaseOwner)
        _ = try await env.jobStore.finish(
            id: failed.id, leaseOwner: env.service.leaseOwner, status: .failed,
            error: ("SCAN_READ_FAILED", "boom"))
        do {
            let _: String? = try await env.service.waitForResult(jobId: failed.id, timeoutMs: 500)
            Issue.record("失败终态应抛错")
        } catch let JobServiceError.jobFailed(id, message) {
            #expect(id == failed.id)
            #expect(message.contains("boom"))
        }

        // 取消终态 → JobCancelledError。
        let cancelled = try await env.service.create(env.makeParams(type: .qualityScore, scopeId: "s2"))
        _ = try await env.jobStore.claim(id: cancelled.id, leaseOwner: env.service.leaseOwner)
        _ = try await env.jobStore.finish(id: cancelled.id, leaseOwner: env.service.leaseOwner, status: .cancelled, error: nil)
        do {
            let _: String? = try await env.service.waitForResult(jobId: cancelled.id, timeoutMs: 500)
            Issue.record("取消终态应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }

        // succeeded 且无内存结果 → nil。
        let done = try await env.service.create(env.makeParams(type: .qualityScore, scopeId: "s3"))
        _ = try await env.jobStore.claim(id: done.id, leaseOwner: env.service.leaseOwner)
        _ = try await env.jobStore.finish(id: done.id, leaseOwner: env.service.leaseOwner, status: .succeeded, error: nil)
        let value: String? = try await env.service.waitForResult(jobId: done.id, timeoutMs: 500)
        #expect(value == nil)

        // 不存在的 job → 抛错。
        do {
            let _: String? = try await env.service.waitForResult(jobId: "nope", timeoutMs: 500)
            Issue.record("不存在任务应抛错")
        } catch let JobServiceError.jobNotFound(id) {
            #expect(id == "nope")
        }
    }

    @Test func waitForResultTimesOutForPendingJob() async throws {
        let env = try await Env()
        await env.service.start()
        defer { Task { await env.service.stop() } }

        // 无 executor，job 一直 queued → waitForResult 超时。
        let job = try await env.service.create(env.makeParams(type: .thumbnailBuild))
        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 200)
            Issue.record("应超时")
        } catch let JobServiceError.waitForResultTimeout(id) {
            #expect(id == job.id)
        }
    }

    /// 第四轮审计 #1（HIGH）：waitForResult 注册竞态。
    /// 修复前「检查完成结果」与「注册 waiter」是两个临界区——任务在
    /// takeCompletedResult(nil) 与 appendWaiter 之间完成时，新等待者永不
    /// resume（挂满 60 分钟超时）。修复后检查与注册同一临界区，已登记结果
    /// 立即取回。此用例构造「任务已完成但结果未取」场景，waitForResult
    /// 必须立即返回而非等待超时。
    @Test func waitForResultReturnsImmediatelyForCompletedButUntakenResult() async throws {
        let env = try await Env()
        let job = try await env.service.create(env.makeParams(type: .duplicateScan))
        // 任务已完成（完成结果已登记、尚未被任何 waitForResult 取走）。
        env.service.completeResultForTesting(id: job.id, value: "early-result")

        let value: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 500)
        #expect(value == "early-result")
    }

    /// 第四轮审计 #2（MED）：排队取消结果被 drain 的 claim 失败分支覆盖。
    /// queued 任务取消时 completeResult(JobCancelledError) 已登记；若 drain
    /// 在 list 快照之后、claim 之前赶上（claim 失败分支无条件
    /// completeResult(.error(notClaimable))），等待者会收到错误类型漂移。
    /// 修复后已登记结果存在时跳过覆盖。此用例直接驱动该分支做确定性验证。
    @Test func claimFailureDoesNotOverwriteQueuedCancellationResult() async throws {
        let env = try await Env()
        await env.service.start()
        defer { Task { await env.service.stop() } }

        // 排队任务取消：cancel 同步登记 JobCancelledError。
        let job = try await env.service.create(env.makeParams(type: .duplicateScan))
        #expect(try await env.service.cancel(job.id))
        // drain 的 claim 失败分支：任务在 list 快照与 claim 之间被取消。
        env.service.handleClaimFailure(id: job.id, error: JobServiceError.notClaimable(job.id))

        do {
            let _: String? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 500)
            Issue.record("应抛 JobCancelledError 而非 notClaimable")
        } catch is JobCancelledError {
            // 预期
        } catch {
            Issue.record("错误类型漂移：收到 \(error)")
        }

        // 对照组：无已登记结果时 claim 失败照常分发 notClaimable。
        let other = try await env.service.create(env.makeParams(type: .duplicateScan, scopeId: "s2"))
        env.service.handleClaimFailure(id: other.id, error: JobServiceError.notClaimable(other.id))
        do {
            let _: String? = try await env.service.waitForResult(jobId: other.id, timeoutMs: 500)
            Issue.record("应抛 notClaimable")
        } catch let JobServiceError.notClaimable(id) {
            #expect(id == other.id)
        }
    }

    @Test func throttlesProgressAndFlushesCheckpoint() async throws {
        let env = try await Env()
        var updates: [JobProgressUpdate] = []
        env.service.setProgressSink { _, update in
            updates.append(update)
        }
        await env.service.registerExecutor(type: .thumbnailBuild) { _, context in
            // 快速连续 5 次更新：250ms 节流窗口内应合并（期间不落库）。
            for i in 1...5 {
                await context.updateProgress(JobProgressUpdate(current: i, total: 10))
            }
            // checkpoint：先 flush 再写再 flush。
            await context.updateCheckpoint(["phase": .string("t1")])
            try await context.throwIfCancelled()
            return nil
        }
        await env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try await env.service.create(env.makeParams(type: .thumbnailBuild))
        let _: Void? = try await env.service.waitForResult(jobId: job.id, timeoutMs: 2_000)

        let persisted = try try await env.jobStore.get(job.id)
        #expect(persisted?.progressCurrent == 5)
        #expect(persisted?.checkpoint["phase"] == .string("t1"))
        // 节流合并：sink 收到的更新应少于逐次上报数（5 次合并 + checkpoint 1 次 + 终态 1 次）。
        #expect(updates.count <= 7)
        // checkpoint 更新确实到达。
        #expect(updates.contains { $0.checkpoint?["phase"] == .string("t1") })
    }

    @Test func abortsWhenHeartbeatFails() async throws {
        let env = try await Env(heartbeatMs: 50)
        let gate = Gate()
        var observedAbort: Bool?
        let boxLock = NSLock()
        await env.service.registerExecutor(type: .duplicateScan) { _, context in
            await gate.wait()
            // 等心跳周期：lease 丢失后心跳失败 → abort 传播到 signal。
            try? await Task.sleep(for: .milliseconds(150))
            boxLock.lock()
            observedAbort = context.signal.aborted
            boxLock.unlock()
            return nil
        }
        await env.service.start()
        defer { Task { await env.service.stop() } }

        let job = try await env.service.create(env.makeParams(type: .duplicateScan))
        await waitUntil { (try? try await env.jobStore.get(job.id)?.status == .running) ?? false }
        #expect(try try await env.jobStore.get(job.id)?.status == .running)

        // 模拟跨进程租约丢失：另一进程直接改写 lease_owner（claim 只对
        // queued 生效，running 行无法再 claim——与 TS 行为一致）。
        let updated = try await env.connection.run("UPDATE analysis_jobs SET lease_owner = 'thief', updated_at = ? WHERE id = ?", [.text(Date().ISO8601Format()), .text(job.id)])
        #expect(updated == 1, "模拟租约被夺应成功")

        gate.open()
        // 心跳失败传播有调度延迟：轮询等待而非固定 sleep（工具链决议 #4）。
        await waitUntil(timeoutMs: 4_000) {
            boxLock.lock()
            defer { boxLock.unlock() }
            return observedAbort != nil
        }

        // 心跳失败必须把取消信号传播到执行上下文。
        boxLock.lock()
        let aborted = observedAbort
        boxLock.unlock()
        #expect(aborted == true, "心跳失败后 signal 应已 abort，实际 \(String(describing: aborted))")

        // TS 语义：租约丢失后 finish 写不进 DB（WHERE lease_owner 不匹配），
        // 行保持 running 直至 recoverStale（30s 租约超时）恢复 queued。
        let status = try try await env.jobStore.get(job.id)?.status
        #expect(status == .running, "租约丢失场景 DB 状态应保持 running（TS 语义），实际 \(status?.rawValue ?? "nil")")
    }

    @Test func enforcesConcurrencyLimit() async throws {
        let env = try await Env(heartbeatMs: 100)
        let gate = Gate()
        var running = 0
        let runningLock = NSLock()
        var maxRunning = 0
        await env.service.registerExecutor(type: .faceAnalyze) { _, _ in
            runningLock.lock()
            running += 1
            if running > maxRunning { maxRunning = running }
            runningLock.unlock()
            await gate.wait()
            runningLock.lock()
            running -= 1
            runningLock.unlock()
            return nil
        }
        await env.service.start()
        defer { Task { await env.service.stop() } }

        let j1 = try await env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s1"))
        let j2 = try await env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s2"))
        let j3 = try await env.service.create(env.makeParams(type: .faceAnalyze, scopeId: "s3"))
        // 等待两个 executor 进入（并发峰值达到上限）。
        await waitUntil { maxRunning >= 2 }

        gate.open()
        let _: Void? = try? await env.service.waitForResult(jobId: j1.id, timeoutMs: 4_000)
        let _: Void? = try? await env.service.waitForResult(jobId: j2.id, timeoutMs: 4_000)
        let _: Void? = try? await env.service.waitForResult(jobId: j3.id, timeoutMs: 4_000)

        #expect(maxRunning == 2, "并发上限应为 2，实际 \(maxRunning)")
    }

    @Test func stoppedServiceDoesNotDrain() async throws {
        let env = try await Env()
        var executed = false
        await env.service.registerExecutor(type: .checksumBackfill) { _, _ in
            executed = true
            return nil
        }
        // 未 start() → stopped，create 不触发 drain。
        let job = try await env.service.create(env.makeParams(type: .checksumBackfill))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!executed)
        #expect(try try await env.jobStore.get(job.id)?.status == .queued)
    }
}
