// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/AnalysisJobRepoTests.swift
// TS 源: desktop/src/main/db/repositories/analysis-job.repo.ts

import Foundation
import Testing
@testable import GatherCore

struct AnalysisJobRepoTests {
    private func makeRepo() throws -> (DBConnection, AnalysisJobRepo) {
        let db = try makeMigratedDB()
        return (db, AnalysisJobRepo(connection: db))
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

    @Test func createInsertsAndGetReturnsTypedData() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let checkpoint = ["stage": JSONValue.string("scan"), "count": JSONValue.int(42)]
        let job = try repo.create(createParams(checkpoint: checkpoint))
        #expect(job.status == .queued)
        #expect(job.priority == 0)
        #expect(job.inputFingerprint == "fp")
        #expect(job.checkpoint["stage"]?.stringValue == "scan")
        #expect(job.checkpoint["count"] == .number(42))

        let fetched = try repo.get(job.id)
        #expect(fetched != nil)
        #expect(fetched?.type == .metadataScan)
        #expect(fetched?.scopeId == "s1")
        #expect(fetched?.dedupeKey == "dedupe-1")
        #expect(fetched?.checkpoint["count"] == .number(42))
        #expect(try rowCount(db, "SELECT COUNT(*) FROM analysis_jobs") == 1)
    }

    @Test func createWithDuplicateActiveDedupeReturnsExisting() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let first = try repo.create(createParams())
        let second = try repo.create(createParams())
        #expect(second.id == first.id)
        #expect(second.status == .queued)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM analysis_jobs") == 1)
    }

    @Test func createAfterTerminalDedupeCreatesFreshRow() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams())
        _ = try repo.claim(id: job.id, leaseOwner: "worker-1")
        _ = try repo.finish(id: job.id, leaseOwner: "worker-1", status: .failed, error: (code: "boom", message: "bad"))
        // 终态行不在 idx_analysis_jobs_active_dedupe（部分唯一索引）内 → INSERT 不冲突，
        // 与 TS 一致：此时创建新行（终态复用分支仅在同 dedupe 存在活跃行时可达）
        let retried = try repo.create(createParams())
        #expect(retried.id != job.id)
        #expect(retried.status == .queued)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM analysis_jobs") == 2)
    }

    @Test func getUnknownReturnsNil() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        #expect(try repo.get("nope") == nil)
    }

    @Test func listFiltersByStatusAndOrdersByPriority() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.create(createParams(dedupeKey: "a", priority: 1))
        _ = try repo.create(createParams(dedupeKey: "b", priority: 5))
        _ = try repo.create(createParams(dedupeKey: "c", priority: 3, checkpoint: ["x": JSONValue.bool(true)]))
        // 直接改状态制造一个 running
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'running' WHERE dedupe_key = 'b'").run()

        let running = try repo.list(status: .running)
        #expect(running.count == 1)
        #expect(running[0].dedupeKey == "b")

        let all = try repo.list()
        #expect(all.count == 3)
        // list() 无 status 时按 updated_at DESC（TS 语义），同毫秒创建时顺序不定
        #expect(all.map(\.priority).sorted() == [1, 3, 5])
    }

    @Test func listByTypeFilters() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.create(createParams(dedupeKey: "a"))
        _ = try repo.create(createParams(type: .faceAnalyze, dedupeKey: "b"))
        let jobs = try repo.listByType(.metadataScan)
        #expect(jobs.count == 1)
        #expect(jobs[0].dedupeKey == "a")
    }

    @Test func requestCancelTransitions() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let queued = try repo.create(createParams())
        #expect(try repo.requestCancel(queued.id))
        #expect(try repo.get(queued.id)?.status == .cancelled)

        let running = try repo.create(createParams(dedupeKey: "running"))
        _ = try repo.claim(id: running.id, leaseOwner: "w")
        #expect(try repo.requestCancel(running.id))
        #expect(try repo.get(running.id)?.status == .cancelling)

        #expect(!(try repo.requestCancel("missing")))
    }

    @Test func retryOnlyFromTerminal() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let failed = try repo.create(createParams())
        _ = try repo.claim(id: failed.id, leaseOwner: "w")
        _ = try repo.finish(id: failed.id, leaseOwner: "w", status: .failed, error: (code: "e", message: "m"))
        #expect(try repo.retry(failed.id))
        #expect(try repo.get(failed.id)?.status == .queued)

        let queued = try repo.create(createParams(dedupeKey: "queued"))
        #expect(!(try repo.retry(queued.id)))
    }

    @Test func recoverStaleInterruptsExpiredHeartbeats() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let stale = try repo.create(createParams(dedupeKey: "stale"))
        _ = try repo.claim(id: stale.id, leaseOwner: "w")
        _ = try db.prepare("UPDATE analysis_jobs SET heartbeat_at = '2020-01-01T00:00:00.000Z' WHERE id = ?")
            .run([.text(stale.id)])

        let fresh = try repo.create(createParams(dedupeKey: "fresh"))
        _ = try repo.claim(id: fresh.id, leaseOwner: "w")

        // 60s 租约：fresh 的心跳（now）远小于 cutoff，不会被误伤
        let count = try repo.recoverStale(leaseTimeoutMs: 60_000)
        #expect(count == 1)
        #expect(try repo.get(stale.id)?.status == .interrupted)
        #expect(try repo.get(stale.id)?.errorCode == "worker_lost")
        #expect(try repo.get(fresh.id)?.status == .running)
    }

    @Test func resumeInterruptedByTypes() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let a = try repo.create(createParams(dedupeKey: "a"))
        let b = try repo.create(createParams(type: .faceAnalyze, dedupeKey: "b"))
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'interrupted'").run()

        let count = try repo.resumeInterrupted(types: [.metadataScan])
        #expect(count == 1)
        #expect(try repo.get(a.id)?.status == .queued)
        #expect(try repo.get(b.id)?.status == .interrupted)
        #expect(try repo.resumeInterrupted(types: []) == 0)
    }

    @Test func claimLifecycle() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams())
        #expect(try repo.claim(id: job.id, leaseOwner: "worker"))
        let claimed = try repo.get(job.id)
        #expect(claimed?.status == .running)
        #expect(claimed?.leaseOwner == "worker")
        #expect(claimed?.attemptCount == 1)
        #expect(claimed?.startedAt != "")
        let startedAt = claimed?.startedAt
        #expect(!(try repo.claim(id: job.id, leaseOwner: "worker")))
        #expect(try repo.get(job.id)?.startedAt == startedAt, "started_at 只写一次")
    }

    @Test func heartbeatValidatesOwner() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams())
        _ = try repo.claim(id: job.id, leaseOwner: "worker")
        #expect(try repo.heartbeat(id: job.id, leaseOwner: "worker"))
        #expect(!(try repo.heartbeat(id: job.id, leaseOwner: "intruder")))
        #expect(!(try repo.heartbeat(id: "missing", leaseOwner: "worker")))
    }

    @Test func updateProgressPartialAndCheckpoint() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams(checkpoint: ["kept": JSONValue.bool(true)]))
        _ = try repo.claim(id: job.id, leaseOwner: "worker")
        _ = try repo.updateProgress(id: job.id, leaseOwner: "worker", update: JobProgressUpdate(current: 3, phase: "index.scanning"))
        let updated = try repo.get(job.id)
        #expect(updated?.progressCurrent == 3)
        #expect(updated?.progressTotal == 0)
        #expect(updated?.progressMessage == "index.scanning")
        #expect(updated?.checkpoint["kept"] == .bool(true))

        // 提供 checkpoint 时整体替换
        _ = try repo.updateProgress(id: job.id, leaseOwner: "worker", update: JobProgressUpdate(checkpoint: ["new": JSONValue.int(7)]))
        #expect(try repo.get(job.id)?.checkpoint["new"] == .number(7))
        #expect(try repo.get(job.id)?.checkpoint["kept"] == nil)

        #expect(!(try repo.updateProgress(id: job.id, leaseOwner: "intruder", update: JobProgressUpdate(current: 9))))
        #expect(!(try repo.updateProgress(id: "missing", leaseOwner: "worker", update: JobProgressUpdate(current: 9))))
    }

    @Test func finishAndInterrupt() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams())
        _ = try repo.claim(id: job.id, leaseOwner: "worker")
        #expect(try repo.finish(id: job.id, leaseOwner: "worker", status: .succeeded))
        let done = try repo.get(job.id)
        #expect(done?.status == .succeeded)
        #expect(done?.finishedAt != "")

        let other = try repo.create(createParams(dedupeKey: "other"))
        _ = try repo.claim(id: other.id, leaseOwner: "worker")
        #expect(try repo.interrupt(id: other.id, leaseOwner: "worker", message: "stopped"))
        #expect(try repo.get(other.id)?.status == .interrupted)
        #expect(try repo.get(other.id)?.errorCode == "application_stopped")
        #expect(!(try repo.finish(id: other.id, leaseOwner: "intruder", status: .failed)))
    }

    @Test func clearCompletedWithExclusion() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let done = try repo.create(createParams(type: .faceAnalyze, dedupeKey: "done"))
        let excluded = try repo.create(createParams(dedupeKey: "excluded"))
        let active = try repo.create(createParams(dedupeKey: "active"))
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'succeeded' WHERE dedupe_key = 'done'").run()
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'failed' WHERE dedupe_key = 'excluded'").run()

        let cleared = try repo.clearCompleted(excludeTypes: [.metadataScan])
        #expect(cleared == 1)
        #expect(try repo.get(done.id) == nil)
        #expect(try repo.get(excluded.id) != nil, "被排除类型的终态行保留")
        #expect(try repo.get(active.id) != nil)

        let clearedAll = try repo.clearCompleted()
        #expect(clearedAll == 1)
        #expect(try repo.get(excluded.id) == nil)
    }
}
