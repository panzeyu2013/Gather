// desktop/native/gather-core/Tests/GatherCoreTests/Logging/TraceLoggingTests.swift
// WP7b：Job/Delivery 关联 trace 与阶段日志的行为门禁。
//
// 口径：
// - trace 字符串：job:<id>、delivery:<id>/rev:<revision>/<phase>；
// - JobService：start（claim 成功）与 terminal（succeeded/failed/cancelled/
//   interrupted/lease-lost）各一条，均带 duration_ms（run 起点=claim 成功），
//   失败终态为 warn 且带 phase + reason；
// - Delivery：confirm 的 DB 边界、cleanup/finalize/replay 的 file/db/backup 边界与
//   批次 summary（整体 duration_ms）、WritebackService/MirrorWriter 的写租约冲突（lease）；
//   失败路径 warn 必须带 phase + reason，且 reason 不泄漏绝对路径；
// - 捕获方式：替换 GatherLogger.output（GatherLogger.log 不抛错，日志不影响业务）。
//   过滤用本测试独有的 job id / xmp 路径，避免并行套件的日志串扰。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - fixtures

/// 线程安全日志捕获：GatherLogger.output 可能在任何执行线程被调用。
private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var previousOutput: ((String) -> Void)?
    private var previousLevel: LogLevel?

    func start() {
        let output = GatherLogger.output
        let level = GatherLogger.minimumLevel
        lock.lock()
        previousOutput = output
        previousLevel = level
        lock.unlock()
        GatherLogger.output = { [weak self] line in self?.append(line) }
        if level > .info {
            GatherLogger.minimumLevel = .info
        }
    }

    func stop() {
        lock.lock()
        let output = previousOutput
        let level = previousLevel
        lock.unlock()
        if let output { GatherLogger.output = output }
        if let level { GatherLogger.minimumLevel = level }
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}

private enum TraceFileError: Error, Equatable {
    case injected
}

/// 带绝对路径的错误描述（模拟 Foundation file error 的 NSFilePath）：用于验证
/// reason=... 进 trace 前被替换成 basename#hash，但错误码仍保留。
private struct TracePathError: Error, CustomStringConvertible {
    let path: String

    var description: String {
        "XMP_INJECTED_PATH: \(path) (NSFilePath=\(path))"
    }
}

/// 写回租约测试的最小 XMP 假件：租约冲突发生在碰盘之前，所有文件操作都不应被调用。
private final class TraceWritebackXMP: XMPProvider, @unchecked Sendable {
    func readKeywords(photoPath: String) async throws -> [String] { [] }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        MetadataWriteAttributes()
    }

    func writeAttributes(
        photoPath: String, attributes: MetadataWriteAttributes
    ) async throws {}

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    func fileExists(_ path: String) -> Bool { false }

    func removeFile(_ path: String) async throws {}
}

/// 内存 XMP 假件：restore 覆盖写（幂等），removeFile 删除内存键；可注入失败。
private final class TraceFilePort: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var restoreFailure: Error?
    private var removeFailure: Error?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func setContents(_ path: String, _ value: String) {
        locked { storage[path] = value }
    }

    func contents(_ path: String) -> String? {
        locked { storage[path] }
    }

    func setRestoreFailure(_ error: Error?) {
        locked { restoreFailure = error }
    }

    func setRemoveFailure(_ error: Error?) {
        locked { removeFailure = error }
    }

    func fileExists(_ path: String) -> Bool {
        locked { storage[path] != nil }
    }

    func restore(photoPath: String, backupPath: String) async throws {
        let target = TSPath.xmpSidecarPath(photoPath)
        try locked {
            if let restoreFailure { throw restoreFailure }
            guard let backup = storage[backupPath] else {
                throw TraceFileError.injected
            }
            storage[target] = backup
        }
    }

    func removeFile(_ path: String) async throws {
        try locked {
            if let removeFailure { throw removeFailure }
            storage.removeValue(forKey: path)
        }
    }
}

private let traceXmp = "/v/wp7b-trace/IMG_TRACE.xmp"
private let tracePhoto = "/v/wp7b-trace/IMG_TRACE.jpg"
private let traceBackup = "/v/wp7b-trace/IMG_TRACE.xmp.gather-backup-test"
/// 同目录、但不符合 `<xmp>.gather-backup-<non-empty>` 约定：P2-12 必须 fail-closed。
private let traceInvalidBackup = "/v/wp7b-trace/wp7b-trace-bogus.xmp"
private let traceSession = "wp7b-trace-s1"

/// 最小交付夹具：written（或 synced）交付 + coordinator。
private struct TraceDeliveryFixture {
    let db: DBConnection
    let repo: DeliveryRepo
    let intents: DeliveryIntentRepo
    let files: TraceFilePort
    let coordinator: DeliveryCoordinator
    let delivery: DeliveryRow

    init(confirm: Bool, backupPath: String = traceBackup) throws {
        let db = try makeTestDB()
        try insertSession(db, traceSession)
        try insertPhoto(db, id: "wp7b-trace-p1", sessionId: traceSession)
        let repo = DeliveryRepo(connection: db)
        let intents = DeliveryIntentRepo(connection: db)
        let files = TraceFilePort()
        files.setContents(traceXmp, "gather-written")
        files.setContents(backupPath, "original")
        let delivery = try repo.createOrGet(
            xmpPath: traceXmp, photoPath: tracePhoto, revision: 1)
        _ = try repo.linkSession(xmpPath: traceXmp, sessionId: traceSession)
        _ = try repo.upsertItem(
            xmpPath: traceXmp, photoId: "wp7b-trace-p1",
            module: .culling, status: .written)
        _ = try repo.markWriting(xmpPath: traceXmp, revision: 1)
        _ = try repo.markWritten(
            xmpPath: traceXmp,
            revision: 1,
            baseFingerprint: "fp-current",
            baseValues: .object([:]),
            backupPath: backupPath)
        if confirm {
            // 直接走仓储确认，绕开 coordinator 的 reload-ack 门禁（本套件不测门禁）。
            _ = try repo.confirm(scope: .module, sessionId: traceSession, module: .culling)
        }
        self.db = db
        self.repo = repo
        self.intents = intents
        self.files = files
        self.delivery = delivery
        self.coordinator = DeliveryCoordinator(
            connection: db,
            deliveryRepo: repo,
            intentRepo: intents,
            files: files,
            fileLock: XMPFileLock(),
            fingerprint: { _ in "fp-current" },
            requireReloadAck: false)
    }
}

private func traceLines(_ capture: LogCapture, deliveryId: Int64, phase: String) -> [String] {
    let prefix = "trace=delivery:\(deliveryId)/rev:1/\(phase)"
    return capture.lines.filter { $0.contains(prefix) }
}

/// 从 trace 行提取 duration_ms（空格分隔字段；reason 内的空格不影响）。
private func traceDurationMs(in line: String) -> Int? {
    guard let token = line.split(separator: " ").first(where: { $0.hasPrefix("duration_ms=") }) else {
        return nil
    }
    return Int(token.dropFirst("duration_ms=".count))
}

// MARK: - tests

/// 串行化：所有用例替换 GatherLogger 的全局 output（进程级单例），并发会互相覆盖。
@Suite(.serialized)
struct TraceLoggingTests {
    @Test func jobStartAndTerminalLogsCarryTrace() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let db = try makeTestDB()
        defer { db.close() }
        let repo = AnalysisJobRepo(connection: db)
        let service = JobService(repo: repo, heartbeatIntervalMs: 500, weightBudget: 2)
        service.registerExecutor(type: .metadataScan, weight: 1) { _, _ in "ok" }
        service.start()
        defer { Task { await service.stop() } }

        let job = try service.create(JobCreateParams(
            type: .metadataScan,
            scopeType: "session",
            scopeId: "wp7b-trace-s1",
            dedupeKey: "wp7b-trace-ok"))
        let result: String? = try await service.waitForResult(jobId: job.id)
        #expect(result == "ok")

        let lines = capture.lines.filter { $0.contains("trace=job:\(job.id)") }
        #expect(lines.contains {
            $0.contains("event=start") && $0.contains("phase=start")
                && $0.contains("type=metadata.scan")
        })
        #expect(lines.contains {
            $0.contains("event=terminal") && $0.contains("phase=terminal")
                && $0.contains("status=succeeded")
        })
        // duration_ms：start 以 run 起点记 0，终态记实际耗时（数值非负）。
        #expect(lines.contains {
            $0.contains("event=start") && $0.contains("duration_ms=0")
        })
        #expect(lines.contains {
            $0.contains("event=terminal") && traceDurationMs(in: $0) != nil
        })
        // 两条日志必须是同一个 trace（可关联）。
        #expect(lines.allSatisfy { $0.contains("trace=job:\(job.id)") })
    }

    @Test func jobFailureTerminalWarnsWithPhaseAndReason() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        struct Boom: Error {}
        let db = try makeTestDB()
        defer { db.close() }
        let repo = AnalysisJobRepo(connection: db)
        let service = JobService(repo: repo, heartbeatIntervalMs: 500, weightBudget: 2)
        service.registerExecutor(type: .duplicateScan, weight: 1) { _, _ in throw Boom() }
        service.start()
        defer { Task { await service.stop() } }

        let job = try service.create(JobCreateParams(
            type: .duplicateScan,
            scopeType: "session",
            scopeId: "wp7b-trace-fail",
            dedupeKey: "wp7b-trace-fail"))
        let _: Void? = try? await service.waitForResult(jobId: job.id, timeoutMs: 8_000)
        let persisted = try repo.get(job.id)
        #expect(persisted?.status == .failed)

        let warning = capture.lines.first {
            $0.contains("trace=job:\(job.id)")
                && $0.contains("event=terminal")
                && $0.contains("status=failed")
        }
        let line = try #require(warning)
        #expect(line.contains("[warn]"))
        #expect(line.contains("phase=terminal"))
        #expect(line.contains("reason="))
        #expect(traceDurationMs(in: line) != nil)
    }

    @Test func cleanupLogsFileAndDBBoundariesWithDeliveryTrace() async throws {
        let fixture = try TraceDeliveryFixture(confirm: true)
        defer { fixture.db.close() }
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let result = try await fixture.coordinator.cleanup(
            sessionId: traceSession, module: .culling)
        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)

        let pathToken = DeliveryTrace.pathToken(traceXmp)
        let allLines = capture.lines.filter {
            $0.contains("trace=delivery:\(fixture.delivery.id)/rev:1/")
                && $0.contains("xmp=\(pathToken)")
        }
        let fileLines = traceLines(capture, deliveryId: fixture.delivery.id, phase: "file")
        let dbLines = traceLines(capture, deliveryId: fixture.delivery.id, phase: "db")
        let fileStart = try #require(allLines.firstIndex {
            $0.contains("/file") && $0.contains("event=start") && $0.contains("op=cleanup")
        })
        let fileDone = try #require(allLines.firstIndex {
            $0.contains("/file") && $0.contains("event=done")
                && $0.contains("outcome=completed")
        })
        let dbStart = try #require(allLines.firstIndex {
            $0.contains("/db") && $0.contains("event=start") && $0.contains("op=cleanup")
        })
        let dbDone = try #require(allLines.firstIndex {
            $0.contains("/db") && $0.contains("event=done") && $0.contains("outcome=deleted")
        })
        #expect(fileStart < fileDone)
        #expect(dbStart < dbDone)
        #expect(fileDone < dbStart, "file 阶段必须整体先于 DB 阶段")
        // P2-8：trace 只出现 basename#hash，绝不出现绝对路径。
        let token = DeliveryTrace.pathToken(traceXmp)
        #expect(fileLines.contains { $0.contains("xmp=\(token)") })
        #expect(!allLines.contains { $0.contains(traceXmp) }, "trace 不得泄漏绝对 xmpPath")
        #expect(dbLines.contains { $0.contains("phase=db") })

        // 批次汇总：session token + phase=summary，整体耗时字段存在。
        let summaryTrace = "trace=delivery:\(DeliveryTrace.sessionToken(traceSession))/rev:0/summary"
        let summary = try #require(capture.lines.first {
            $0.contains(summaryTrace) && $0.contains("op=cleanup") && $0.contains("event=done")
                && $0.contains("deleted=1")
        })
        #expect(traceDurationMs(in: summary) != nil)
    }

    @Test func cleanupFailureWarnsThenReplayRetriesWithTrace() async throws {
        let fixture = try TraceDeliveryFixture(confirm: true)
        defer { fixture.db.close() }
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        fixture.files.setRestoreFailure(TraceFileError.injected)
        let failed = try await fixture.coordinator.cleanup(
            sessionId: traceSession, module: .culling)
        #expect(failed.deletedCount == 0)
        #expect(failed.errors.count == 1)

        let fileWarning = capture.lines.first {
            $0.contains("trace=delivery:\(fixture.delivery.id)/rev:1/file")
                && $0.contains("[warn]")
                && $0.contains("event=failed")
        }
        let warning = try #require(fileWarning)
        #expect(warning.contains("phase=file"))
        #expect(warning.contains("reason="))

        // prepared intent 保留；修复文件条件后 replay 重做 file + db。
        fixture.files.setRestoreFailure(nil)
        let replayed = try await fixture.coordinator.replay()
        #expect(replayed.appliedCount == 1)
        #expect(replayed.failedCount == 0)

        let replayPrefix = "trace=delivery:\(fixture.delivery.id)/rev:1/"
        let replayFile = capture.lines.filter {
            $0.contains(replayPrefix + "file") && $0.contains("op=replay")
        }
        let replayDB = capture.lines.filter {
            $0.contains(replayPrefix + "db") && $0.contains("op=replay")
        }
        #expect(replayFile.contains {
            $0.contains("event=done") && $0.contains("outcome=completed")
        })
        #expect(replayDB.contains {
            $0.contains("event=done") && $0.contains("outcome=deleted")
        })

        // replay 是跨交付批次：固定 replay 汇总 trace + 整体耗时。
        let replaySummary = try #require(capture.lines.first {
            $0.contains("trace=delivery:replay/rev:0/summary")
                && $0.contains("op=replay") && $0.contains("event=done")
                && $0.contains("applied=1") && $0.contains("failed=0")
        })
        #expect(traceDurationMs(in: replaySummary) != nil)
    }

    @Test func confirmLogsSessionScopedTraceAtDBBoundary() throws {
        let fixture = try TraceDeliveryFixture(confirm: false)
        defer { fixture.db.close() }
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let summary = try fixture.coordinator.confirm(
            sessionId: traceSession, module: .culling)
        #expect(summary.deliveriesSynced == 1)

        // confirm 是 (session, module) 级事务，没有单条 delivery id：
        // trace 的 id 段用 session:<short-hash>、revision 固定 0（P2-8 脱敏）。
        let lines = capture.lines.filter {
            $0.contains("trace=delivery:\(DeliveryTrace.sessionToken(traceSession))/rev:0/confirm")
        }
        #expect(lines.contains {
            $0.contains("event=done") && $0.contains("phase=confirm")
        })
        #expect(lines.contains {
            $0.contains("event=start") && $0.contains("module=culling")
        })
    }


    // MARK: - WP7b 边界补测（cancelled / interrupted / lease-lost / finalize 失败）

    /// queued 取消不经过执行器，仍必须留下终态 trace，且 reason 指向取消来源。
    @Test func jobQueuedCancelTerminalLogsTraceWithReason() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let db = try makeTestDB()
        defer { db.close() }
        let repo = AnalysisJobRepo(connection: db)
        let service = JobService(repo: repo, heartbeatIntervalMs: 60_000, weightBudget: 2)
        // 不注册执行器：任务停在 queued，cancel 走「不需要执行器参与」的分支。
        service.start()
        defer { Task { await service.stop() } }

        let job = try service.create(JobCreateParams(
            type: .qualityScore,
            scopeType: "session",
            scopeId: "wp7b-trace-queued-cancel",
            dedupeKey: "wp7b-trace-queued-cancel"))
        #expect(try repo.get(job.id)?.status == .queued)

        #expect(try service.cancel(job.id))

        let jobTrace = "trace=job:" + job.id
        let terminal = try #require(capture.lines.first {
            $0.contains(jobTrace)
                && $0.contains("event=terminal")
                && $0.contains("status=cancelled")
        })
        #expect(terminal.contains("[info]"))
        #expect(terminal.contains("phase=terminal"))
        #expect(terminal.contains("reason=queued-cancel"))
        // 未 claim（无 run 起点）：duration_ms 必须是 0，而不是缺字段。
        #expect(terminal.contains("duration_ms=0"))
        #expect(try repo.get(job.id)?.status == .cancelled)
    }

    /// running 取消（执行器协作退出）：settle 的 cancelled 分支必须留终态 trace，
    /// 并与 queued-cancel/cancel-grace/application-stopped 的 reason 口径一致。
    @Test func jobRunningCancelTerminalLogsTrace() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let db = try makeTestDB()
        defer { db.close() }
        let repo = AnalysisJobRepo(connection: db)
        let service = JobService(repo: repo, heartbeatIntervalMs: 60_000, weightBudget: 2)
        let gate = TraceGate()
        service.registerExecutor(type: .duplicateScan, weight: 1) { _, _ in
            await gate.wait()
            return "late"
        }
        service.start()
        defer { Task { await service.stop() } }

        let job = try service.create(JobCreateParams(
            type: .duplicateScan,
            scopeType: "session",
            scopeId: "wp7b-trace-running-cancel",
            dedupeKey: "wp7b-trace-running-cancel"))
        await waitUntil { (try? repo.get(job.id)?.status == .running) ?? false }
        #expect(try repo.get(job.id)?.status == .running)

        #expect(try service.cancel(job.id))
        gate.open()
        do {
            let _: String? = try await service.waitForResult(jobId: job.id, timeoutMs: 2_000)
            Issue.record("取消后 waitForResult 应抛 JobCancelledError")
        } catch is JobCancelledError {
            // 预期
        }

        let jobTrace = "trace=job:" + job.id
        let terminal = try #require(capture.lines.first {
            $0.contains(jobTrace) && $0.contains("event=terminal")
        })
        #expect(terminal.contains("[info]"))
        #expect(terminal.contains("phase=terminal"))
        #expect(terminal.contains("status=cancelled"))
        #expect(terminal.contains("type=duplicate.scan"))
        #expect(terminal.contains("reason=cancel-grace"))
        #expect(traceDurationMs(in: terminal) != nil)
        #expect(try repo.get(job.id)?.status == .cancelled)
    }

    /// 停机中断：settle 在 stopped + 取消时走 interrupt，trace 必须带 reason。
    @Test func jobApplicationStopLogsInterruptedTrace() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let db = try makeTestDB()
        defer { db.close() }
        let repo = AnalysisJobRepo(connection: db)
        let service = JobService(repo: repo, heartbeatIntervalMs: 60_000, weightBudget: 2)
        service.registerExecutor(type: .similarityAnalyze, weight: 1) { _, context in
            while !context.signal.aborted {
                try? await Task.sleep(for: .milliseconds(5))
            }
            throw JobCancelledError()
        }
        service.start()
        defer { Task { await service.stop() } }

        let job = try service.create(JobCreateParams(
            type: .similarityAnalyze,
            scopeType: "session",
            scopeId: "wp7b-trace-stop",
            dedupeKey: "wp7b-trace-stop"))
        await waitUntil { (try? repo.get(job.id)?.status == .running) ?? false }
        #expect(try repo.get(job.id)?.status == .running)

        await service.stop()

        let jobTrace = "trace=job:" + job.id
        let lines = capture.lines.filter { $0.contains(jobTrace) }
        #expect(lines.contains { $0.contains("event=start") && $0.contains("phase=start") })
        let terminal = try #require(lines.first { $0.contains("event=terminal") })
        #expect(terminal.contains("[info]"))
        #expect(terminal.contains("phase=terminal"))
        #expect(terminal.contains("status=interrupted"))
        #expect(terminal.contains("reason=application-stopped"))
        #expect(traceDurationMs(in: terminal) != nil)
        #expect(try repo.get(job.id)?.status == .interrupted)
        expectNoPathLeak(lines, [])
    }

    /// 租约被对端接管：条件 UPDATE 未命中 → lease-lost 终态 warn。
    @Test func jobLeaseLostTerminalWarnsWithTrace() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let db = try makeTestDB()
        defer { db.close() }
        let repo = AnalysisJobRepo(connection: db)
        let service = JobService(repo: repo, heartbeatIntervalMs: 60_000, weightBudget: 2)
        let gate = TraceGate()
        service.registerExecutor(type: .outputRun, weight: 1) { _, _ in
            await gate.wait()
            return "late"
        }
        service.start()
        defer { Task { await service.stop() } }

        let job = try service.create(JobCreateParams(
            type: .outputRun,
            scopeType: "session",
            scopeId: "wp7b-trace-lease",
            dedupeKey: "wp7b-trace-lease"))
        await waitUntil { (try? repo.get(job.id)?.status == .running) ?? false }
        #expect(try repo.get(job.id)?.status == .running)

        // 模拟对端接管（等价于 recoverStale 后由新进程持有租约）：本执行器的
        // 条件 UPDATE 全部未命中，finishMiss 必须留下 warn trace。
        _ = try db.prepare("UPDATE analysis_jobs SET lease_owner = ? WHERE id = ?")
            .run([.text("peer-process"), .text(job.id)])
        gate.open()

        do {
            let _: String? = try await service.waitForResult(jobId: job.id, timeoutMs: 2_000)
            Issue.record("租约丢失后 waitForResult 应抛 leaseLost")
        } catch JobServiceError.leaseLost(let id) {
            #expect(id == job.id)
        }

        let jobTrace = "trace=job:" + job.id
        let terminal = try #require(capture.lines.first {
            $0.contains(jobTrace) && $0.contains("event=terminal")
        })
        #expect(terminal.contains("[warn]"))
        #expect(terminal.contains("phase=terminal"))
        #expect(terminal.contains("status=lease-lost"))
        #expect(terminal.contains("reason=conditional-update-missed"))
        #expect(traceDurationMs(in: terminal) != nil)
        #expect(try repo.get(job.id)?.status == .running, "对端行必须原样保留")
    }

    /// finalize 文件阶段 fail-closed：backup_path 不可信 → skipped + phase/reason；
    /// trace 只出现 basename#hash，完整路径只留在 summary.errors（仍可定位）。
    @Test func finalizeInvalidBackupSkipsWithTrace() async throws {
        let fixture = try TraceDeliveryFixture(confirm: true, backupPath: traceInvalidBackup)
        defer { fixture.db.close() }
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let result = try await fixture.coordinator.finalize(
            sessionId: traceSession, module: .culling)
        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 1)
        let error = try #require(result.errors.first)
        #expect(error.hasPrefix("XMP_FINALIZE_BACKUP_PATH_INVALID"))
        #expect(error.contains(traceXmp), "summary.errors 仍须保留完整路径以便定位")

        let fileTrace = "trace=delivery:" + String(fixture.delivery.id) + "/rev:1/file"
        let lines = capture.lines.filter { $0.contains(fileTrace) }
        let skipped = try #require(lines.first {
            $0.contains("event=skipped") && $0.contains("outcome=invalid-backup")
        })
        #expect(skipped.contains("[warn]"))
        #expect(skipped.contains("op=finalize"))
        #expect(skipped.contains("phase=file"))
        #expect(skipped.contains("reason=XMP_BACKUP_PATH_UNEXPECTED_NAME"))
        expectNoPathLeak(lines, [traceXmp, tracePhoto, traceInvalidBackup])

        // finalize 批次汇总同样必须带整体 duration_ms。
        let summaryTrace = "trace=delivery:\(DeliveryTrace.sessionToken(traceSession))/rev:0/summary"
        let summary = try #require(capture.lines.first {
            $0.contains(summaryTrace) && $0.contains("op=finalize") && $0.contains("event=done")
                && $0.contains("deleted=0") && $0.contains("skipped=1")
        })
        #expect(traceDurationMs(in: summary) != nil)
        #expect(try fixture.repo.get(traceXmp) != nil, "fail-closed：行与备份都必须保留")
    }

    /// finalize DB 阶段失败：trace 带 delivery:<id>/rev:<rev>/db + phase=db + reason；
    /// 事务回滚后交付行仍在（replay 可重试），trace 不泄漏绝对路径。
    @Test func finalizeDBFailureWarnsWithPhaseAndReason() async throws {
        let fixture = try TraceDeliveryFixture(confirm: true)
        defer { fixture.db.close() }
        // 注入 DB 失败：删除 deliveries 时 RAISE(ABORT)（等价 SQL/约束错误）。
        try fixture.db.exec(
            "CREATE TRIGGER wp7b_trace_fail_finalize BEFORE DELETE ON deliveries "
                + "BEGIN SELECT RAISE(ABORT, 'INJECTED_FINALIZE_DB_FAILURE'); END;")
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let result = try await fixture.coordinator.finalize(
            sessionId: traceSession, module: .culling)
        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 0)
        let error = try #require(result.errors.first)
        #expect(error.hasPrefix("XMP_FINALIZE_DB_FAILED"))

        let dbTrace = "trace=delivery:" + String(fixture.delivery.id) + "/rev:1/db"
        let failed = try #require(capture.lines.first {
            $0.contains(dbTrace)
                && $0.contains("event=failed")
                && $0.contains("outcome=db-failed")
        })
        #expect(failed.contains("[warn]"))
        #expect(failed.contains("op=finalize"))
        #expect(failed.contains("phase=db"))
        #expect(failed.contains("reason="))
        #expect(failed.contains("INJECTED_FINALIZE_DB_FAILURE"))
        expectNoPathLeak([failed], [traceXmp, traceBackup, tracePhoto])

        #expect(try fixture.repo.get(traceXmp) != nil, "DB 事务回滚后交付行必须保留")
        #expect(try fixture.repo.get(traceXmp)?.typedStatus == .synced)
        #expect(try fixture.intents.pending().fileDone.count == 1, "文件阶段已完成，DB 段待重试")
    }

    /// finalize 文件 IO 失败（DB 提交后的备份清理）：同一交付 trace + phase=backup；
    /// 行已删（不回滚），备份保留、错误进 summary（绝不伪造成成功）。
    @Test func finalizeBackupRemovalFailureWarnsWithTrace() async throws {
        let fixture = try TraceDeliveryFixture(confirm: true)
        defer { fixture.db.close() }
        fixture.files.setRemoveFailure(TraceFileError.injected)
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let result = try await fixture.coordinator.finalize(
            sessionId: traceSession, module: .culling)
        #expect(result.deletedCount == 1)
        #expect(result.skippedCount == 0)
        let error = try #require(result.errors.first)
        #expect(error.hasPrefix("XMP_FINALIZE_BACKUP_CLEANUP_FAILED"))
        #expect(error.contains(traceXmp))

        #expect(try fixture.repo.get(traceXmp) == nil, "DB 删除已提交，不回滚")
        #expect(fixture.files.contents(traceBackup) == "original", "删备份失败时备份必须原样保留")

        // 备份清理是 DB 提交后的独立段：trace 段与 phase=backup 必须一致
        //（不能再借用 /db，否则按段 grep 会把尾段误读成 DB）。
        let dbTrace = "trace=delivery:" + String(fixture.delivery.id) + "/rev:1/db"
        let backupTrace = "trace=delivery:" + String(fixture.delivery.id) + "/rev:1/backup"
        let failed = try #require(capture.lines.first {
            $0.contains(backupTrace)
                && $0.contains("op=finalize")
                && $0.contains("phase=backup")
                && $0.contains("event=failed")
        })
        #expect(failed.contains("[warn]"))
        #expect(failed.contains("reason="))
        #expect(!capture.lines.contains {
            $0.contains(dbTrace) && $0.contains("phase=backup")
        }, "备份清理段必须是 /backup，不得留在 /db")
        expectNoPathLeak([failed], [traceXmp, traceBackup, tracePhoto])
    }

    /// 交付写租约被他人持有：WritebackService 必须留 delivery:<id>/rev:<n>/lease
    /// warn（op/phase/reason code），且 trace 不出现绝对 xmpPath。
    @Test func writebackLeaseHeldWarnsWithDeliveryTrace() async throws {
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, traceSession)
        try insertPhoto(db, id: "wp7b-lease-p1", sessionId: traceSession)
        let repo = DeliveryRepo(connection: db)
        let delivery = try repo.createOrGet(
            xmpPath: traceXmp, photoPath: tracePhoto, revision: 0)
        _ = try repo.linkSession(xmpPath: traceXmp, sessionId: traceSession)
        let item = try repo.upsertItem(
            xmpPath: traceXmp,
            photoId: "wp7b-lease-p1",
            module: .culling,
            keywords: ["leased"],
            status: .pending)
        // 另一个活跃写者持有未过期租约：本服务不得无条件覆盖。
        _ = try repo.claimWriting(
            xmpPath: traceXmp, revision: 0, leaseOwner: "peer-writer")

        let service = WritebackService(
            deliveryRepo: repo,
            xmp: TraceWritebackXMP(),
            photoRepo: PhotoRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            fileLock: XMPFileLock())
        let writebackItem = WritebackItem(
            id: Int(item.id),
            photoId: "wp7b-lease-p1",
            photoPath: tracePhoto,
            sessionId: traceSession,
            module: "culling",
            keywords: ["leased"],
            xmpPath: traceXmp,
            backupPath: "",
            xmpStatus: DeliveryItemStatus.pending.rawValue,
            errorMessage: "",
            attemptCount: 0,
            lastAttemptAt: "")
        let result = try await service.execute(
            sessionId: traceSession, module: "culling", items: [writebackItem])
        #expect(result.written == 0)
        #expect(result.failed == 1)

        let leaseTrace = "trace=delivery:\(delivery.id)/rev:0/lease"
        let warning = try #require(capture.lines.first {
            $0.contains(leaseTrace)
                && $0.contains("op=writeback-execute")
                && $0.contains("phase=lease")
                && $0.contains("event=failed")
        })
        #expect(warning.contains("[warn]"))
        #expect(warning.contains("reason=DELIVERY_LEASE_HELD"))
        expectNoPathLeak([warning], [traceXmp, tracePhoto, traceBackup])
    }

    /// 错误文本里带绝对路径（NSFilePath 风格）也必须脱敏：trace 只保留错误码 +
    /// basename#hash；summary.errors 仍保留完整路径供定位。
    @Test func cleanupFailureReasonRedactsAbsolutePaths() async throws {
        let fixture = try TraceDeliveryFixture(confirm: true)
        defer { fixture.db.close() }
        let capture = LogCapture()
        capture.start()
        defer { capture.stop() }

        fixture.files.setRestoreFailure(TracePathError(path: traceXmp))
        let result = try await fixture.coordinator.cleanup(
            sessionId: traceSession, module: .culling)
        #expect(result.deletedCount == 0)
        #expect(result.errors.count == 1)
        let reported = try #require(result.errors.first)
        #expect(reported.contains(traceXmp), "summary.errors 仍须保留完整路径")

        let warning = try #require(capture.lines.first {
            $0.contains("trace=delivery:\(fixture.delivery.id)/rev:1/file")
                && $0.contains("event=failed")
        })
        #expect(warning.contains("XMP_INJECTED_PATH"))
        #expect(!warning.contains(traceXmp), "trace 不得泄漏绝对 xmpPath")
        #expect(!warning.contains("/Users/"), "trace 不得泄漏用户主目录")
        expectNoPathLeak([warning], [traceXmp, tracePhoto, traceBackup])
    }

    // MARK: - helpers

    /// 条件等待：满足即返回；超时由调用方断言（轮询 10ms）。
    private func waitUntil(timeoutMs: Int64 = 4_000, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// P2-8 脱敏断言：trace 行只允许 basename#hash，不得出现绝对路径/主目录。
    private func expectNoPathLeak(_ lines: [String], _ forbidden: [String]) {
        for line in lines {
            for path in forbidden where !path.isEmpty {
                #expect(!line.contains(path), Comment(rawValue: "trace 泄漏绝对路径 " + path + ": " + line))
            }
            #expect(!line.contains("/v/wp7b-trace"), Comment(rawValue: "trace 泄漏 fixture 目录: " + line))
            #expect(!line.contains(NSHomeDirectory()), Comment(rawValue: "trace 泄漏用户主目录: " + line))
        }
    }
}

/// continuation 门：让执行器在测试选定时点返回（JobServiceTests.Gate 的简化版）。
private final class TraceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var openFlag = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if openFlag {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
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
