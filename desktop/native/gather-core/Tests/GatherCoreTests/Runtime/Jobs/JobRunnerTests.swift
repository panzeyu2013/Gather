// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Jobs/JobRunnerTests.swift
// R3：JobRunner actor 行为测试（真实迁移库 + SQLiteJobStore）。覆盖计划 §R3
// 必测语义：①单注册表 ②租约 fencing（heartbeat 失败/interrupted 触发 signal）
// ③取消宽限期 ④stop() 超时兜底 ⑤checkpoint 编解码 ⑥去重键（含 export 目标
// 摘要）⑦完成结果原子 take ⑧崩溃恢复（recoverStale + resumeInterrupted）。
// 所有等待走轮询（waitUntil），总时长 < 10s。

import Testing
import Foundation
@testable import GatherCore

// MARK: - 测试替身

/// 可开合门（actor：无锁，不使用 unchecked Sendable 标注）。
private actor TestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

/// 单值盒（把 executor 内部观察搬出闭包）。
private actor TestBox<Value: Sendable> {
    private var value: Value?

    func set(_ newValue: Value) { value = newValue }
    func get() -> Value? { value }
}

private actor CounterActor {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

/// 并发峰值探针（executor 进入/退出计数）。
private actor ConcurrencyProbe {
    private var running = 0
    private var peak = 0

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func exit() { running -= 1 }
    func maxRunning() -> Int { peak }
}

/// 进度帧收集（含 checkpoint；sink 是同步闭包，经 Task 投递到 actor）。
private actor UpdateLog {
    private var updates: [JobProgressUpdate] = []

    func append(_ update: JobProgressUpdate) { updates.append(update) }
    func count() -> Int { updates.count }
    func containsCheckpointPhase(_ phase: String) -> Bool {
        updates.contains { $0.checkpoint?["phase"] == .string(phase) }
    }
}

/// 进度帧收集（sink 是同步闭包，经 Task 投递到 actor）。
private actor FrameLog {
    private var frames: [(jobId: String, message: String)] = []

    func append(jobId: String, message: String) { frames.append((jobId, message)) }

    func contains(jobId: String, message: String) -> Bool {
        frames.contains { $0.jobId == jobId && $0.message == message }
    }
}

/// 崩溃恢复用例里按作业 id 记录 executor 读到的 checkpoint。
private actor CheckpointLog {
    private var values: [String: JobCheckpoint] = [:]

    func record(jobId: String, checkpoint: JobCheckpoint) { values[jobId] = checkpoint }
    func checkpoint(for jobId: String) -> JobCheckpoint? { values[jobId] }
}

private struct NamedCheckpointPayload: Codable, Equatable {
    var phase: String
    var done: Int
    var flags: [String]
}

private struct FakeExportTarget: Encodable, Equatable {
    var destination: String
    var format: String
    var includeXmp: Bool
}

// MARK: - 测试环境

private struct JobRunnerEnv {
    let path: String
    let database: SQLiteDatabase
    let store: SQLiteJobStore
    let runner: JobRunner
}

private func makeEnv(
    heartbeatMs: Int64 = 1_000,
    watchdogMs: Int64 = 5_000,
    cancelGraceMs: Int64 = 5_000,
    stopTimeoutMs: Int64 = 5_000,
    progressWriteMs: Int64 = 20,
    resultTtlMs: Int64 = 5 * 60_000,
    maxConcurrent: Int = JobRunner.maxConcurrentJobs,
    leaseOwner: String = "test-owner"
) async throws -> JobRunnerEnv {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-jobrunner-\(UUID().uuidString).sqlite").path
    let database = try await makeMigratedStore(path: path)
    let store = SQLiteJobStore(database: database)
    let runner = JobRunner(
        jobStore: store,
        leaseOwner: leaseOwner,
        heartbeatIntervalMs: heartbeatMs,
        watchdogIntervalMs: watchdogMs,
        cancelGracePeriodMs: cancelGraceMs,
        stopTimeoutMs: stopTimeoutMs,
        progressWriteIntervalMs: progressWriteMs,
        completedResultTtlMs: resultTtlMs,
        maxConcurrentJobs: maxConcurrent)
    return JobRunnerEnv(path: path, database: database, store: store, runner: runner)
}

private func makeParams(
    type: AnalysisJobType,
    scopeId: String = "s1",
    dedupeKey: String? = nil,
    priority: Int? = nil,
    checkpoint: [String: JSONValue]? = nil
) -> JobCreateParams {
    JobCreateParams(
        type: type,
        scopeType: "session",
        scopeId: scopeId,
        dedupeKey: dedupeKey ?? "\(type.rawValue):\(scopeId)",
        priority: priority,
        checkpoint: checkpoint)
}

/// 轮询等待条件（固定 sleep 在并发跑时不可靠）。
@discardableResult
private func waitUntil(timeoutMs: Int64 = 3_000, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - 测试

struct JobRunnerTests {
    // ── ① 单注册表 ──

    @Test func createRunsRegisteredExecutorAndPersistsProgressAndCheckpoint() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        await runner.registerExecutor(type: .metadataScan) { _, context in
            await context.updateProgress(JobProgressUpdate(current: 2, total: 2, message: "scanning"))
            try await context.setCheckpointValue("indexing", forKey: "phase")
            return "ok"
        }
        _ = await runner.start()

        let job = try await runner.create(makeParams(type: .metadataScan))
        let result: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 3_000)
        #expect(result == "ok")

        let persisted = try await env.store.get(job.id)
        #expect(persisted?.status == .succeeded)
        #expect(persisted?.progressCurrent == 2)
        #expect(persisted?.progressTotal == 2)
        #expect(persisted?.checkpoint["phase"] == .string("indexing"))
        await runner.stop()
    }

    @Test func createThrowsExecutorNotRegistered() async throws {
        let env = try await makeEnv()
        do {
            _ = try await env.runner.create(makeParams(type: .qualityScore))
            Issue.record("未注册类型应抛 executorNotRegistered")
        } catch let error as JobRunnerError {
            #expect(error == .executorNotRegistered(.qualityScore))
            #expect(error.code == "JOB_EXECUTOR_NOT_REGISTERED")
        }
    }

    // ── ② 租约 fencing ──

    @Test func runRequiresSuccessfulClaim() async throws {
        let env = try await makeEnv()
        await env.runner.registerExecutor(type: .qualityScore) { _, _ in nil }
        let job = try await env.store.create(makeParams(type: .qualityScore))
        // 另一租约方已抢到（claim 只对 queued 生效）。
        _ = try await env.store.claim(id: job.id, leaseOwner: "other-worker")

        do {
            _ = try await env.runner.run(job: job, leaseOwner: "test-owner") { _ in "nope" }
            Issue.record("claim 失败应抛 notClaimable")
        } catch let error as JobRunnerError {
            #expect(error == .notClaimable(job.id))
        }
    }

    @Test func heartbeatLeaseLossAbortsSignalAndThrowsLeaseLost() async throws {
        let env = try await makeEnv(heartbeatMs: 30, watchdogMs: 10_000)
        let runner = env.runner
        let sawAbort = TestBox<Bool>()
        await runner.registerExecutor(type: .faceAnalyze) { _, context in
            let deadline = Date().addingTimeInterval(3)
            while !context.signal.aborted, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await sawAbort.set(context.signal.aborted)
            return nil
        }
        _ = await runner.start()
        let job = try await runner.create(makeParams(type: .faceAnalyze))
        let running = await waitUntil { (try? await env.store.get(job.id))?.status == .running }
        #expect(running)

        // 模拟跨进程租约被夺（running 行改写 lease_owner）。
        let updates = try await env.database.run(
            "UPDATE analysis_jobs SET lease_owner = ?, updated_at = ? WHERE id = ?",
            [.text("thief"), .text(nowISOString()), .text(job.id)])
        #expect(updates == 1)

        let aborted = await waitUntil { await sawAbort.get() == true }
        #expect(aborted, "心跳失败必须 abort 该作业的取消信号")

        do {
            let _: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 3_000)
            Issue.record("租约丢失应抛 leaseLost")
        } catch let error as JobRunnerError {
            #expect(error == .leaseLost(job.id))
        }
        let status = try await env.store.get(job.id)?.status
        #expect(status == .running, "租约丢失不得覆写持久行（由 recoverStale 接管）")
        await runner.stop()
    }

    @Test func interruptedStatusFencesRunAndAbortsSignal() async throws {
        let env = try await makeEnv(heartbeatMs: 10_000, watchdogMs: 20)
        let runner = env.runner
        let sawAbort = TestBox<Bool>()
        await runner.registerExecutor(type: .checksumBackfill) { _, context in
            let deadline = Date().addingTimeInterval(3)
            while !context.signal.aborted, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await sawAbort.set(context.signal.aborted)
            return nil
        }
        _ = await runner.start()
        let job = try await runner.create(makeParams(type: .checksumBackfill))
        let running = await waitUntil { (try? await env.store.get(job.id))?.status == .running }
        #expect(running)

        // 外部（recoverStale/另一进程）把 running 行判成 interrupted。
        let updates = try await env.database.run(
            """
            UPDATE analysis_jobs SET status = 'interrupted', error_code = 'worker_lost',
              error_message = 'Worker heartbeat expired', updated_at = ? WHERE id = ?
            """,
            [.text(nowISOString()), .text(job.id)])
        #expect(updates == 1)

        let aborted = await waitUntil { await sawAbort.get() == true }
        #expect(aborted, "interrupted 行必须触发该作业的取消信号")
        let status = try await env.store.get(job.id)?.status
        #expect(status == .interrupted, "看门狗不得覆写 interrupted 终态")
        await runner.stop()
    }

    // ── ③ 取消宽限期 ──

    @Test func cancelUsesGracePeriodThenForcesTerminalState() async throws {
        let env = try await makeEnv(heartbeatMs: 10_000, watchdogMs: 10_000, cancelGraceMs: 120)
        let runner = env.runner
        let gate = TestGate()
        let signalBox = TestBox<Bool>()
        await runner.registerExecutor(type: .duplicateScan) { _, context in
            await gate.wait()
            await signalBox.set(context.signal.aborted)
            return "late"
        }
        _ = await runner.start()
        let job = try await runner.create(makeParams(type: .duplicateScan))
        let running = await waitUntil { (try? await env.store.get(job.id))?.status == .running }
        #expect(running)

        let cancelled = try await runner.cancel(job.id)
        #expect(cancelled)
        let graceStatus = try await env.store.get(job.id)?.status
        #expect(graceStatus == .cancelling, "宽限期内保持 cancelling，让 executor 自行退出")

        let forced = await waitUntil(timeoutMs: 2_000) {
            (try? await env.store.get(job.id))?.status == .cancelled
        }
        #expect(forced, "宽限期超时必须强制定终态 cancelled")

        do {
            let _: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 2_000)
            Issue.record("取消后应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }

        await gate.open()
        await runner.stop()
        let observed = await signalBox.get()
        #expect(observed == true, "executor 必须能观察到 abort 信号")
    }

    @Test func cancellingQueuedJobEmitsTerminalFrameAndCancellationResult() async throws {
        let env = try await makeEnv(heartbeatMs: 10_000, watchdogMs: 10_000, maxConcurrent: 1)
        let runner = env.runner
        let gate = TestGate()
        await runner.registerExecutor(type: .faceAnalyze) { _, _ in
            await gate.wait()
            return nil
        }
        let frames = FrameLog()
        await runner.setProgressSink { job, update in
            Task { await frames.append(jobId: job.id, message: update.message ?? "") }
        }
        _ = await runner.start()

        let hold = try await runner.create(makeParams(type: .faceAnalyze, scopeId: "hold"))
        let holding = await waitUntil { (try? await env.store.get(hold.id))?.status == .running }
        #expect(holding)
        let queued = try await runner.create(makeParams(type: .faceAnalyze, scopeId: "queued"))
        let queuedStatus = try await env.store.get(queued.id)?.status
        #expect(queuedStatus == .queued, "并发上限 1：第二个作业应排队")

        let cancelled = try await runner.cancel(queued.id)
        #expect(cancelled)
        let frameEmitted = await waitUntil {
            await frames.contains(jobId: queued.id, message: "cancelled")
        }
        #expect(frameEmitted, "queued 取消应补发终态进度帧")

        do {
            let _: String? = try await runner.waitForResult(jobId: queued.id, timeoutMs: 2_000)
            Issue.record("排队任务取消后 waitForResult 应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }

        await gate.open()
        let _: Void? = try? await runner.waitForResult(jobId: hold.id, timeoutMs: 3_000)
        await runner.stop()
    }

    // ── ④ stop() 超时兜底 ──

    @Test func stopReturnsAfterTimeoutWhenExecutorIgnoresAbort() async throws {
        let env = try await makeEnv(heartbeatMs: 10_000, watchdogMs: 10_000, stopTimeoutMs: 150)
        let runner = env.runner
        let gate = TestGate()
        await runner.registerExecutor(type: .thumbnailBuild) { _, _ in
            await gate.wait()
            return nil
        }
        _ = await runner.start()
        let job = try await runner.create(makeParams(type: .thumbnailBuild))
        let running = await waitUntil { (try? await env.store.get(job.id))?.status == .running }
        #expect(running)

        let started = Date()
        await runner.stop()
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.0, "stop() 必须在超时后返回（不得挂死），实际 \(elapsed)s")

        // 放行后作业按关机语义落 interrupted 终态。
        await gate.open()
        let settled = await waitUntil { (try? await env.store.get(job.id))?.status == .interrupted }
        #expect(settled, "stop 后 executor 退出应落 interrupted")
    }

    // ── ⑤ checkpoint 编解码 ──

    @Test func checkpointRoundTripsTypedValues() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        let payload = NamedCheckpointPayload(phase: "ranking", done: 3, flags: ["a", "b"])
        await runner.registerExecutor(type: .qualityScore) { _, context in
            try await context.setCheckpointValue(payload, forKey: "payload")
            await context.mergeCheckpoint(JobCheckpoint(["nested": .object(["x": .number(1)])]))
            return nil
        }
        _ = await runner.start()
        let job = try await runner.create(makeParams(type: .qualityScore))
        let _: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 3_000)

        let stored = try await runner.checkpoint(jobId: job.id)
        #expect(stored?.string("phase") == nil)
        let decoded: NamedCheckpointPayload? = try stored?.decode(NamedCheckpointPayload.self, forKey: "payload")
        #expect(decoded == payload)
        #expect(stored?.object("nested")?["x"]?.numberValue == 1)

        let persistedValue = try await env.store.get(job.id)?.checkpoint["payload"]
        #expect(persistedValue != nil)
        await runner.stop()
    }

    // ── ⑥ 去重键 ──

    @Test func dedupeKeySharesInFlightJobAndRejectsDifferentKeyWithBusy() async throws {
        let env = try await makeEnv(heartbeatMs: 10_000, watchdogMs: 10_000)
        let runner = env.runner
        let gate = TestGate()
        await runner.registerExecutor(type: .similarityAnalyze) { _, _ in
            await gate.wait()
            return "shared"
        }
        _ = await runner.start()

        let key = "similarity.analyze:s1:10:2:global"
        let first = try await runner.create(makeParams(type: .similarityAnalyze, dedupeKey: key))
        let running = await waitUntil { (try? await env.store.get(first.id))?.status == .running }
        #expect(running)

        // 同 key：复用同一在飞作业行。
        let shared = try await runner.create(makeParams(type: .similarityAnalyze, dedupeKey: key))
        #expect(shared.id == first.id, "同 key 必须共享在飞作业")

        // 共享在飞结果：两个等待者都拿到同一结果。
        let takeA = Task { try await runner.waitForResult(jobId: first.id, timeoutMs: 3_000) as String? }
        let takeB = Task { try await runner.waitForResult(jobId: first.id, timeoutMs: 3_000) as String? }
        let registered = await waitUntil { await runner.waiterCount(jobId: first.id) == 2 }
        #expect(registered, "共享在飞结果的等待者应登记在同一作业上")

        // 同资源不同 key：busy（首作业仍在飞）。
        do {
            _ = try await runner.create(makeParams(
                type: .similarityAnalyze, dedupeKey: "similarity.analyze:s1:12:2:global"))
            Issue.record("同资源不同 key 应抛 busy")
        } catch let error as JobRunnerError {
            #expect(error.code == "JOB_BUSY")
            if case .busy(let resource, let existingKey) = error {
                #expect(resource.scopeId == "s1")
                #expect(existingKey == key)
            } else {
                Issue.record("busy 载荷错误：\(error)")
            }
        }

        await gate.open()
        let valueA = try await takeA.value
        let valueB = try await takeB.value
        #expect([valueA, valueB].allSatisfy { $0 == "shared" }, "共享在飞结果：两个等待者都拿到结果")

        // 首作业终态后，不同 key 可再次入队（不复用旧行/旧结果）。
        let second = try await runner.create(makeParams(
            type: .similarityAnalyze, dedupeKey: "similarity.analyze:s1:12:2:global"))
        #expect(second.id != first.id)
        await runner.stop()
    }

    @Test func exportTargetChangeCreatesNewJobInsteadOfReusingResult() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        let runs = CounterActor()
        await runner.registerExecutor(type: .exportExecute) { job, _ in
            await runs.increment()
            return job.checkpoint["destination"]?.stringValue ?? ""
        }
        _ = await runner.start()

        let keyA = JobDedupKey.export(sessionId: "s1", targetSummary: "dest-a")
        let keyB = JobDedupKey.export(sessionId: "s1", targetSummary: "dest-b")
        let first = try await runner.create(makeParams(
            type: .exportExecute, scopeId: "s1", dedupeKey: keyA.rawValue,
            checkpoint: ["destination": .string("dest-a")]))
        let resultA: String? = try await runner.waitForResult(jobId: first.id, timeoutMs: 3_000)
        #expect(resultA == "dest-a")

        // 换目标：新 key → 新作业行（旧实现同 key 会在 5 分钟内静默复用旧结果）。
        let second = try await runner.create(makeParams(
            type: .exportExecute, scopeId: "s1", dedupeKey: keyB.rawValue,
            checkpoint: ["destination": .string("dest-b")]))
        #expect(second.id != first.id, "换目标必须产生新作业行")
        let resultB: String? = try await runner.waitForResult(jobId: second.id, timeoutMs: 3_000)
        #expect(resultB == "dest-b")
        let executions = await runs.value()
        #expect(executions == 2, "两个目标各执行一次（不得复用旧结果）")
        await runner.stop()
    }

    @Test func exportDedupeKeyIncludesTargetSummary() throws {
        let summaryA = try JobDedupKey.exportTargetSummary(
            FakeExportTarget(destination: "/tmp/a", format: "jpeg", includeXmp: false))
        let summaryB = try JobDedupKey.exportTargetSummary(
            FakeExportTarget(destination: "/tmp/b", format: "jpeg", includeXmp: false))
        #expect(summaryA != summaryB)
        #expect(summaryA.count == 64)

        let keyA = JobDedupKey.export(sessionId: "s1", targetSummary: summaryA)
        let keyB = JobDedupKey.export(sessionId: "s1", targetSummary: summaryB)
        #expect(keyA.rawValue != keyB.rawValue)
        #expect(keyA.rawValue == "export.execute:s1:\(summaryA)")
        #expect(keyA.resource == JobResource(type: .exportExecute, scopeType: "session", scopeId: "s1"))
        #expect(JobDedupKey.export(sessionId: "s1", targetSummary: summaryA) == keyA)

        // 字典键序不影响摘要（规范化 JSON 键排序）。
        let dictA: [String: JSONValue] = ["b": .number(2), "a": .number(1)]
        let dictB: [String: JSONValue] = ["a": .number(1), "b": .number(2)]
        let digestA = try JobDedupKey.exportTargetSummary(dictA)
        let digestB = try JobDedupKey.exportTargetSummary(dictB)
        #expect(digestA == digestB)
    }

    // ── ⑦ 完成结果原子 take ──

    @Test func waitForResultTakesCompletedResultExactlyOnce() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        await runner.registerExecutor(type: .metadataScan) { _, _ in "once" }
        _ = await runner.start()
        let job = try await runner.create(makeParams(type: .metadataScan))
        let registered = await waitUntil { await runner.hasCompletedResult(id: job.id) }
        #expect(registered)

        // 并发 take：恰一个拿到结果，另一个落到持久行（succeeded → nil）。
        let takeA = Task { try await runner.waitForResult(jobId: job.id, timeoutMs: 2_000) as String? }
        let takeB = Task { try await runner.waitForResult(jobId: job.id, timeoutMs: 2_000) as String? }
        let valueA = try await takeA.value
        let valueB = try await takeB.value
        let values = [valueA, valueB]
        #expect(values.filter { $0 == "once" }.count == 1, "并发 take 只能有一个拿到结果")
        #expect(values.filter { $0 == nil }.count == 1)

        // 顺序第二次：结果已取走 → nil。
        let third: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 1_000)
        #expect(third == nil)
        await runner.stop()
    }

    @Test func waitForResultReturnsNilOnTimeoutAndThrowsForUnknownJob() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        await runner.registerExecutor(type: .faceAnalyze) { _, _ in nil }
        // 不 start()：作业保持 queued，永不完成。
        let job = try await runner.create(makeParams(type: .faceAnalyze))
        let started = Date()
        let value: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 80)
        #expect(value == nil, "超时应返回 nil")
        // 上界只用于区分「按 80ms 超时返回」与「挂满默认 1h 超时」；
        // 全量并行跑时 Task 调度可能被拖慢，故放宽到 10s。
        #expect(Date().timeIntervalSince(started) < 10.0)

        do {
            let _: String? = try await runner.waitForResult(jobId: "missing", timeoutMs: 50)
            Issue.record("未知作业应抛 jobNotFound")
        } catch let error as JobRunnerError {
            #expect(error == .jobNotFound("missing"))
            #expect(error.code == "JOB_NOT_FOUND")
        }
        await runner.stop()
    }

    // ── ⑧ 崩溃恢复 ──

    @Test func startRecoversStaleAndResumesInterruptedWithCheckpoint() async throws {
        let env = try await makeEnv()
        // 崩溃行：已 claim、心跳停在空串（recoverStale 判过期）且带 checkpoint。
        let crashed = try await env.store.create(makeParams(
            type: .metadataScan, scopeId: "s-crash",
            checkpoint: ["phase": .string("indexing"), "cursor": .number(42)]))
        _ = try await env.store.claim(id: crashed.id, leaseOwner: "dead-worker")
        _ = try await env.database.run(
            "UPDATE analysis_jobs SET heartbeat_at = '' WHERE id = ?", [.text(crashed.id)])

        // 另一行：外部已判 interrupted。
        let interrupted = try await env.store.create(makeParams(type: .metadataScan, scopeId: "s-interrupted"))
        _ = try await env.database.run(
            """
            UPDATE analysis_jobs SET status = 'interrupted', error_code = 'worker_lost',
              error_message = 'Worker heartbeat expired' WHERE id = ?
            """,
            [.text(interrupted.id)])

        // 新 runner（崩溃重启）：start() 必须真正执行 recoverStale + resumeInterrupted。
        let runner = JobRunner(jobStore: env.store, leaseOwner: "new-worker")
        let log = CheckpointLog()
        await runner.registerExecutor(type: .metadataScan) { job, context in
            await log.record(jobId: job.id, checkpoint: context.initialCheckpoint)
            try await context.throwIfCancelled(forceDbCheck: true)
            return "resumed"
        }
        let report = await runner.start()
        #expect(report.recoveredStale >= 1, "start() 必须执行 recoverStale")
        #expect(report.resumedInterrupted == 2, "start() 必须执行 resumeInterrupted")

        let first: String? = try await runner.waitForResult(jobId: crashed.id, timeoutMs: 3_000)
        #expect(first == "resumed")
        let resumedCheckpoint = await log.checkpoint(for: crashed.id)
        #expect(resumedCheckpoint?.string("phase") == "indexing", "恢复后的 executor 必须读到上次 checkpoint")
        #expect(resumedCheckpoint?.int("cursor") == 42)
        await runner.stop()
    }

    // ── 旧 public 面等价（retry / clearCompleted 阶段证据） ──

    @Test func retryAndClearCompletedKeepStageEvidence() async throws {
        let env = try await makeEnv()
        let runner = env.runner

        let failed = try await env.store.create(makeParams(type: .duplicateScan, scopeId: "retry"))
        _ = try await env.store.claim(id: failed.id, leaseOwner: "test-owner")
        _ = try await env.store.finish(
            id: failed.id, leaseOwner: "test-owner", status: .failed, error: ("worker_error", "boom"))
        let retried = try await runner.retry(failed.id)
        #expect(retried)
        let retriedStatus = try await env.store.get(failed.id)?.status
        #expect(retriedStatus == .queued)

        let scan = try await env.store.create(makeParams(type: .metadataScan, scopeId: "scan"))
        _ = try await env.store.claim(id: scan.id, leaseOwner: "test-owner")
        _ = try await env.store.finish(id: scan.id, leaseOwner: "test-owner", status: .succeeded)
        let export = try await env.store.create(makeParams(type: .exportExecute, scopeId: "export"))
        _ = try await env.store.claim(id: export.id, leaseOwner: "test-owner")
        _ = try await env.store.finish(id: export.id, leaseOwner: "test-owner", status: .succeeded)
        let dup = try await env.store.create(makeParams(type: .duplicateScan, scopeId: "dup"))
        _ = try await env.store.claim(id: dup.id, leaseOwner: "test-owner")
        _ = try await env.store.finish(id: dup.id, leaseOwner: "test-owner", status: .succeeded)

        let cleared = try await runner.clearCompleted()
        #expect(cleared == 1, "仅非阶段证据终态行被清理，实际 \(cleared)")
        let scanRow = try await env.store.get(scan.id)
        let exportRow = try await env.store.get(export.id)
        let dupRow = try await env.store.get(dup.id)
        #expect(scanRow != nil, "metadata.scan 阶段证据应保留")
        #expect(exportRow != nil, "export.execute 阶段证据应保留")
        #expect(dupRow == nil)
    }

    // ── 旧 JobServiceTests 语义迁移（未覆盖用例）：
    //    并发上限 / 停止不调度 / claim 失败不覆盖取消结果 / 持久失败终态 / 进度节流 ──

    @Test func enforcesConcurrencyLimit() async throws {
        let env = try await makeEnv(heartbeatMs: 10_000, watchdogMs: 10_000)
        let runner = env.runner
        let gate = TestGate()
        let probe = ConcurrencyProbe()
        await runner.registerExecutor(type: .faceAnalyze) { _, _ in
            await probe.enter()
            await gate.wait()
            await probe.exit()
            return nil
        }
        _ = await runner.start()

        let j1 = try await runner.create(makeParams(type: .faceAnalyze, scopeId: "s1"))
        let j2 = try await runner.create(makeParams(type: .faceAnalyze, scopeId: "s2"))
        let j3 = try await runner.create(makeParams(type: .faceAnalyze, scopeId: "s3"))

        let reached = await waitUntil { await probe.maxRunning() >= 2 }
        #expect(reached, "并发上限 2：应有 2 个 executor 同时在飞")
        let peak = await probe.maxRunning()
        #expect(peak == 2, "并发峰值应为 2，实际 \(peak)")
        // 排队顺序在 updated_at 同毫秒时不保证（Store 按 priority/updated_at 排序），
        // 但「恰好 2 个在飞 + 1 个排队」是并发上限的不变量。
        let running = try await env.store.list(status: .running)
        let queued = try await env.store.list(status: .queued)
        #expect(running.count == 2, "并发上限 2：应有 2 个在飞，实际 \(running.count)")
        #expect(queued.count == 1, "并发上限 2：应有 1 个排队，实际 \(queued.count)")

        await gate.open()
        let _: Void? = try? await runner.waitForResult(jobId: j1.id, timeoutMs: 3_000)
        let _: Void? = try? await runner.waitForResult(jobId: j2.id, timeoutMs: 3_000)
        let _: Void? = try? await runner.waitForResult(jobId: j3.id, timeoutMs: 3_000)
        let finalPeak = await probe.maxRunning()
        #expect(finalPeak == 2, "全程并发峰值应为 2，实际 \(finalPeak)")
        await runner.stop()
    }

    @Test func stoppedRunnerDoesNotDrain() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        let executed = CounterActor()
        await runner.registerExecutor(type: .checksumBackfill) { _, _ in
            await executed.increment()
            return nil
        }
        // 未 start()：create 不得触发 drain（旧 JobService.stopped 语义）。
        let job = try await runner.create(makeParams(type: .checksumBackfill))
        try await Task.sleep(for: .milliseconds(200))
        let executions = await executed.value()
        #expect(executions == 0, "未 start() 不得执行任何作业")
        let status = try await env.store.get(job.id)?.status
        #expect(status == .queued)
        await runner.stop()
    }

    @Test func claimFailureDoesNotOverwriteQueuedCancellationResult() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        await runner.registerExecutor(type: .duplicateScan) { _, _ in nil }

        // 排队任务取消：cancel 同步登记 JobCancelledError。
        let job = try await runner.create(makeParams(type: .duplicateScan))
        #expect(try await runner.cancel(job.id))
        // drain 的 claim 失败分支：任务在 list 快照与 claim 之间被取消。
        await runner.handleClaimFailure(
            id: job.id, error: JobRunnerError.notClaimable(job.id))

        do {
            let _: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 500)
            Issue.record("应抛 JobCancelledError 而非 notClaimable")
        } catch is JobCancelledError {
            // 预期
        } catch {
            Issue.record("错误类型漂移：收到 \(error)")
        }

        // 对照组：无已登记结果时 claim 失败照常分发 notClaimable。
        let other = try await runner.create(makeParams(type: .duplicateScan, scopeId: "s2"))
        await runner.handleClaimFailure(
            id: other.id, error: JobRunnerError.notClaimable(other.id))
        do {
            let _: String? = try await runner.waitForResult(jobId: other.id, timeoutMs: 500)
            Issue.record("应抛 notClaimable")
        } catch let error as JobRunnerError {
            #expect(error == .notClaimable(other.id))
        }
        await runner.stop()
    }

    @Test func waitForResultHandlesPersistedFailedTerminalState() async throws {
        let env = try await makeEnv()
        let runner = env.runner
        let job = try await env.store.create(makeParams(type: .qualityScore))
        _ = try await env.store.claim(id: job.id, leaseOwner: "test-owner")
        _ = try await env.store.finish(
            id: job.id, leaseOwner: "test-owner", status: .failed,
            error: ("SCAN_READ_FAILED", "boom"))

        // 失败终态 → jobFailed（message 即执行器落库的错误消息）。
        do {
            let _: String? = try await runner.waitForResult(jobId: job.id, timeoutMs: 500)
            Issue.record("失败终态应抛 jobFailed")
        } catch let error as JobRunnerError {
            #expect(error == .jobFailed(job.id, "boom"))
            #expect(error.code == "JOB_FAILED")
        }
        await runner.stop()
    }

    @Test func throttlesProgressAndFlushesCheckpoint() async throws {
        let env = try await makeEnv(progressWriteMs: 250)
        let runner = env.runner
        let log = UpdateLog()
        await runner.setProgressSink { _, update in
            Task { await log.append(update) }
        }
        await runner.registerExecutor(type: .thumbnailBuild) { _, context in
            // 快速连续 5 次更新：250ms 节流窗口内应合并（期间不逐次落库）。
            for i in 1...5 {
                await context.updateProgress(JobProgressUpdate(current: i, total: 10))
            }
            await context.updateCheckpoint(["phase": .string("t1")])
            try await context.throwIfCancelled()
            return nil
        }
        _ = await runner.start()

        let job = try await runner.create(makeParams(type: .thumbnailBuild))
        let _: Void? = try await runner.waitForResult(jobId: job.id, timeoutMs: 3_000)

        let persisted = try await env.store.get(job.id)
        #expect(persisted?.progressCurrent == 5)
        #expect(persisted?.checkpoint["phase"] == .string("t1"))
        let sawCheckpoint = await waitUntil { await log.containsCheckpointPhase("t1") }
        #expect(sawCheckpoint, "checkpoint 更新应经 progressSink 发出")
        let frames = await log.count()
        #expect(frames <= 7, "节流合并后帧数应少于逐次上报数，实际 \(frames)")
        await runner.stop()
    }
}
