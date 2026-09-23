// Tests/GatherCoreTests/Store/JobStoreTests.swift
// R1：JobStore 测试（端口自 AnalysisJobRepoTests）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/JobStore (R1)")
struct JobStoreTests {
    private func makeStore() async throws -> (SQLiteJobStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "job")
        return (SQLiteJobStore(database: database), database, path)
    }

    private func createParams(
        type: AnalysisJobType = .metadataScan,
        dedupeKey: String = "dedupe-1",
        priority: Int? = nil,
        checkpoint: [String: JSONValue]? = nil
    ) -> JobCreateParams {
        JobCreateParams(
            type: type,
            scopeType: "session",
            scopeId: "s1",
            dedupeKey: dedupeKey,
            priority: priority,
            inputFingerprint: "fp",
            modelId: "model-a",
            modelVersion: "v1",
            checkpoint: checkpoint
        )
    }

    private func rowCount(_ database: SQLiteDatabase, _ sql: String) async throws -> Int64 {
        try await database.scalarInt(sql) ?? -1
    }

    @Test func createInsertsAndGetReturnsTypedData() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let checkpoint = ["stage": JSONValue.string("scan"), "count": JSONValue.int(42)]
        let job = try await store.create(createParams(checkpoint: checkpoint))
        #expect(job.status == .queued)
        #expect(job.priority == 0)
        #expect(job.inputFingerprint == "fp")
        #expect(job.checkpoint["stage"]?.stringValue == "scan")
        #expect(job.checkpoint["count"] == .number(42))

        let fetched = try await store.get(job.id)
        #expect(fetched != nil)
        #expect(fetched?.type == .metadataScan)
        #expect(fetched?.scopeId == "s1")
        #expect(fetched?.dedupeKey == "dedupe-1")
        #expect(fetched?.checkpoint["count"] == .number(42))
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM analysis_jobs") == 1)
    }

    @Test func createWithDuplicateActiveDedupeReturnsExisting() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let first = try await store.create(createParams())
        let second = try await store.create(createParams())
        #expect(second.id == first.id)
        #expect(second.status == .queued)
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM analysis_jobs") == 1)
    }

    @Test func createAfterTerminalDedupeCreatesFreshRow() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let job = try await store.create(createParams())
        _ = try await store.claim(id: job.id, leaseOwner: "worker-1")
        _ = try await store.finish(id: job.id, leaseOwner: "worker-1", status: .failed, error: (code: "boom", message: "bad"))
        // 终态行不在活跃 dedupe 部分唯一索引内 → 不冲突，创建新行（与 TS 一致）。
        let retried = try await store.create(createParams())
        #expect(retried.id != job.id)
        #expect(retried.status == .queued)
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM analysis_jobs") == 2)
    }

    @Test func getUnknownReturnsNil() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        #expect(try await store.get("nope") == nil)
    }

    @Test func listFiltersByStatusAndOrdersByPriority() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        _ = try await store.create(createParams(dedupeKey: "a", priority: 1))
        _ = try await store.create(createParams(dedupeKey: "b", priority: 5))
        _ = try await store.create(createParams(dedupeKey: "c", priority: 3, checkpoint: ["x": JSONValue.bool(true)]))
        try await database.run("UPDATE analysis_jobs SET status = 'running' WHERE dedupe_key = 'b'")

        let running = try await store.list(status: .running)
        #expect(running.count == 1)
        #expect(running[0].dedupeKey == "b")

        let all = try await store.list()
        #expect(all.count == 3)
        #expect(all.map(\.priority).sorted() == [1, 3, 5])
    }

    @Test func listByTypeFilters() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        _ = try await store.create(createParams(dedupeKey: "a"))
        _ = try await store.create(createParams(type: .faceAnalyze, dedupeKey: "b"))
        let jobs = try await store.listByType(.metadataScan)
        #expect(jobs.count == 1)
        #expect(jobs[0].dedupeKey == "a")
    }

    @Test func requestCancelTransitions() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let queued = try await store.create(createParams())
        #expect(try await store.requestCancel(queued.id))
        #expect(try await store.get(queued.id)?.status == .cancelled)

        let running = try await store.create(createParams(dedupeKey: "running"))
        _ = try await store.claim(id: running.id, leaseOwner: "w")
        #expect(try await store.requestCancel(running.id))
        #expect(try await store.get(running.id)?.status == .cancelling)

        #expect(try await store.requestCancel("missing") == false)
    }

    @Test func retryOnlyFromTerminal() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let failed = try await store.create(createParams())
        _ = try await store.claim(id: failed.id, leaseOwner: "w")
        _ = try await store.finish(id: failed.id, leaseOwner: "w", status: .failed, error: (code: "e", message: "m"))
        #expect(try await store.retry(failed.id))
        #expect(try await store.get(failed.id)?.status == .queued)

        let queued = try await store.create(createParams(dedupeKey: "queued"))
        #expect(try await store.retry(queued.id) == false)
    }

    @Test func recoverStaleInterruptsExpiredHeartbeats() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let stale = try await store.create(createParams(dedupeKey: "stale"))
        _ = try await store.claim(id: stale.id, leaseOwner: "w")
        try await database.run(
            "UPDATE analysis_jobs SET heartbeat_at = '2020-01-01T00:00:00.000Z' WHERE id = ?",
            [.text(stale.id)]
        )

        let fresh = try await store.create(createParams(dedupeKey: "fresh"))
        _ = try await store.claim(id: fresh.id, leaseOwner: "w")

        let count = try await store.recoverStale(leaseTimeoutMs: 60_000)
        #expect(count == 1)
        #expect(try await store.get(stale.id)?.status == .interrupted)
        #expect(try await store.get(stale.id)?.errorCode == "worker_lost")
        #expect(try await store.get(fresh.id)?.status == .running)
    }

    @Test func resumeInterruptedByTypes() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let a = try await store.create(createParams(dedupeKey: "a"))
        let b = try await store.create(createParams(type: .faceAnalyze, dedupeKey: "b"))
        try await database.run("UPDATE analysis_jobs SET status = 'interrupted'")

        let count = try await store.resumeInterrupted(types: [.metadataScan])
        #expect(count == 1)
        #expect(try await store.get(a.id)?.status == .queued)
        #expect(try await store.get(b.id)?.status == .interrupted)
        #expect(try await store.resumeInterrupted(types: []) == 0)
    }

    @Test func claimLifecycle() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let job = try await store.create(createParams())
        #expect(try await store.claim(id: job.id, leaseOwner: "worker"))
        let claimed = try await store.get(job.id)
        #expect(claimed?.status == .running)
        #expect(claimed?.leaseOwner == "worker")
        #expect(claimed?.attemptCount == 1)
        #expect(claimed?.startedAt != "")
        let startedAt = claimed?.startedAt
        #expect(try await store.claim(id: job.id, leaseOwner: "worker") == false)
        #expect(try await store.get(job.id)?.startedAt == startedAt, "started_at 只写一次")
    }

    @Test func heartbeatValidatesOwner() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let job = try await store.create(createParams())
        _ = try await store.claim(id: job.id, leaseOwner: "worker")
        #expect(try await store.heartbeat(id: job.id, leaseOwner: "worker"))
        #expect(try await store.heartbeat(id: job.id, leaseOwner: "intruder") == false)
        #expect(try await store.heartbeat(id: "missing", leaseOwner: "worker") == false)
    }

    @Test func updateProgressPartialAndCheckpoint() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let job = try await store.create(createParams(checkpoint: ["kept": JSONValue.bool(true)]))
        _ = try await store.claim(id: job.id, leaseOwner: "worker")
        _ = try await store.updateProgress(
            id: job.id, leaseOwner: "worker", update: JobProgressUpdate(current: 3, phase: "index.scanning")
        )
        let updated = try await store.get(job.id)
        #expect(updated?.progressCurrent == 3)
        #expect(updated?.progressTotal == 0)
        #expect(updated?.progressMessage == "index.scanning")
        #expect(updated?.checkpoint["kept"] == .bool(true))

        // 提供 checkpoint 时整体替换。
        _ = try await store.updateProgress(
            id: job.id, leaseOwner: "worker", update: JobProgressUpdate(checkpoint: ["new": JSONValue.int(7)])
        )
        #expect(try await store.get(job.id)?.checkpoint["new"] == .number(7))
        #expect(try await store.get(job.id)?.checkpoint["kept"] == nil)

        #expect(try await store.updateProgress(
            id: job.id, leaseOwner: "intruder", update: JobProgressUpdate(current: 9)
        ) == false)
        #expect(try await store.updateProgress(
            id: "missing", leaseOwner: "worker", update: JobProgressUpdate(current: 9)
        ) == false)
    }

    @Test func finishAndInterrupt() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let job = try await store.create(createParams())
        _ = try await store.claim(id: job.id, leaseOwner: "worker")
        #expect(try await store.finish(id: job.id, leaseOwner: "worker", status: .succeeded))
        let done = try await store.get(job.id)
        #expect(done?.status == .succeeded)
        #expect(done?.finishedAt != "")

        let other = try await store.create(createParams(dedupeKey: "other"))
        _ = try await store.claim(id: other.id, leaseOwner: "worker")
        #expect(try await store.interrupt(id: other.id, leaseOwner: "worker", message: "stopped"))
        #expect(try await store.get(other.id)?.status == .interrupted)
        #expect(try await store.get(other.id)?.errorCode == "application_stopped")
        #expect(try await store.finish(id: other.id, leaseOwner: "intruder", status: .failed) == false)
    }

    @Test func clearCompletedWithExclusion() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let done = try await store.create(createParams(type: .faceAnalyze, dedupeKey: "done"))
        let excluded = try await store.create(createParams(dedupeKey: "excluded"))
        let active = try await store.create(createParams(dedupeKey: "active"))
        try await database.run("UPDATE analysis_jobs SET status = 'succeeded' WHERE dedupe_key = 'done'")
        try await database.run("UPDATE analysis_jobs SET status = 'failed' WHERE dedupe_key = 'excluded'")

        let cleared = try await store.clearCompleted(excludeTypes: [.metadataScan])
        #expect(cleared == 1)
        #expect(try await store.get(done.id) == nil)
        #expect(try await store.get(excluded.id) != nil, "被排除类型的终态行保留")
        #expect(try await store.get(active.id) != nil)

        let clearedAll = try await store.clearCompleted()
        #expect(clearedAll == 1)
        #expect(try await store.get(excluded.id) == nil)
    }
}
