// desktop/native/gather-core/Tests/GatherCoreTests/Logging/TraceLoggingTests.swift
// WP7b：Job/Delivery 关联 trace 与阶段日志的行为门禁。
//
// 口径：
// - trace 字符串：job:<id>、delivery:<id>/rev:<revision>/<phase>；
// - JobService：start（claim 成功）与 terminal（succeeded/failed/cancelled/
//   interrupted/lease-lost）各一条，失败终态为 warn 且带 phase + reason；
// - Delivery：confirm 的 DB 边界、cleanup/finalize/replay 的 file/db 边界；
//   失败路径 warn 必须带 phase + reason；
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

/// 内存 XMP 假件：restore 覆盖写（幂等），removeFile 删除内存键；可注入失败。
private final class TraceFilePort: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var restoreFailure: Error?

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
        _ = locked { storage.removeValue(forKey: path) }
    }
}

private let traceXmp = "/v/wp7b-trace/IMG_TRACE.xmp"
private let tracePhoto = "/v/wp7b-trace/IMG_TRACE.jpg"
private let traceBackup = "/backup/wp7b-trace/IMG_TRACE.xmp"
private let traceSession = "wp7b-trace-s1"

/// 最小交付夹具：written（或 synced）交付 + coordinator。
private struct TraceDeliveryFixture {
    let db: DBConnection
    let repo: DeliveryRepo
    let intents: DeliveryIntentRepo
    let files: TraceFilePort
    let coordinator: DeliveryCoordinator
    let delivery: DeliveryRow

    init(confirm: Bool) throws {
        let db = try makeTestDB()
        try insertSession(db, traceSession)
        try insertPhoto(db, id: "wp7b-trace-p1", sessionId: traceSession)
        let repo = DeliveryRepo(connection: db)
        let intents = DeliveryIntentRepo(connection: db)
        let files = TraceFilePort()
        files.setContents(traceXmp, "gather-written")
        files.setContents(traceBackup, "original")
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
            backupPath: traceBackup)
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
            fingerprint: { _ in "fp-current" },
            requireReloadAck: false)
    }
}

private func traceLines(_ capture: LogCapture, deliveryId: Int64, phase: String) -> [String] {
    let prefix = "trace=delivery:\(deliveryId)/rev:1/\(phase)"
    return capture.lines.filter { $0.contains(prefix) }
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

        let allLines = capture.lines.filter {
            $0.contains("trace=delivery:\(fixture.delivery.id)/rev:1/")
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
        #expect(fileLines.contains { $0.contains("xmp=\(traceXmp)") })
        #expect(dbLines.contains { $0.contains("phase=db") })
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
        // trace 的 id 段用 session:<sessionId>、revision 固定 0（WP7b 唯一例外）。
        let lines = capture.lines.filter {
            $0.contains("trace=delivery:session:\(traceSession)/rev:0/confirm")
        }
        #expect(lines.contains {
            $0.contains("event=done") && $0.contains("phase=confirm")
        })
        #expect(lines.contains {
            $0.contains("event=start") && $0.contains("module=culling")
        })
    }
}
