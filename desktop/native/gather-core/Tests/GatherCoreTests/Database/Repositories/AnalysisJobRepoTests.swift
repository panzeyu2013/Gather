// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/AnalysisJobRepoTests.swift
// AnalysisJobRepo 行为契约：状态机迁移、去重/checkpoint 继承、优先级排序、显式清理。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

struct AnalysisJobRepoTests {
    private func makeRepo() throws -> (DBConnection, AnalysisJobRepo) {
        let db = try makeTestDB()
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

    /// activeRow 的活跃状态字面量必须与部分唯一索引
    /// idx_analysis_jobs_active_dedupe 的 WHERE 子句逐字一致：SQLite 的部分索引
    /// 匹配是语法级的，顺序变化/参数化会让该查询退化为全状态索引 + TEMP B-TREE
    /// （去重查从索引点查变成按状态扫描）。本测试把该计划固定下来。
    @Test func activeRowLookupUsesPartialDedupeIndex() throws {
        let (db, _) = try makeRepo()
        defer { db.close() }

        let plan = try db.prepare("""
            EXPLAIN QUERY PLAN
            SELECT * FROM analysis_jobs
            WHERE dedupe_key = ? AND status IN (\(SchemaSQL.activeAnalysisJobStatusSQLList))
            ORDER BY rowid ASC LIMIT 1
            """).query()
        let text = plan.map { $0.compactMap(\.textValue).joined(separator: "|") }.joined(separator: " ")
        #expect(text.contains("idx_analysis_jobs_active_dedupe"), "活跃去重必须走部分唯一索引，实际计划: \(text)")

        // 同一字面量也被 SchemaV1 的部分索引 DDL 使用（唯一真相源，避免两处手写字面量漂移）。
        #expect(SchemaV1.sql.contains("WHERE status IN (\(SchemaSQL.activeAnalysisJobStatusSQLList))"))
    }

    /// 活跃行（queued/running/cancelling）存在时，create 复用该行，不新建。
    @Test func createWithDuplicateActiveDedupeReturnsExisting() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let first = try repo.create(createParams())
        let second = try repo.create(createParams(checkpoint: ["ignored": .bool(true)]))
        #expect(second.id == first.id)
        #expect(second.status == .queued)
        #expect(second.checkpoint["ignored"] == nil)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM analysis_jobs") == 1)
    }

    @Test func activeDedupeCoversRunningAndCancelling() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let running = try repo.create(createParams(dedupeKey: "running"))
        _ = try repo.claim(id: running.id, leaseOwner: "worker")
        #expect(try repo.create(createParams(dedupeKey: "running")).id == running.id)

        let cancelling = try repo.create(createParams(dedupeKey: "cancelling"))
        _ = try repo.claim(id: cancelling.id, leaseOwner: "worker")
        #expect(try repo.requestCancel(cancelling.id) == .cancellationRequested)
        #expect(try repo.create(createParams(dedupeKey: "cancelling")).id == cancelling.id)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM analysis_jobs") == 2)
    }

    /// 终态行不再阻塞新建；新行默认继承最近终态行的 checkpoint（调用方键优先）。
    @Test func createAfterTerminalDedupeCreatesFreshRowAndInheritsCheckpoint() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams(checkpoint: [
            "destinations": .object(["p1": .string("a.jpg")]),
            "completedPhotoIds": .array([.string("p1")]),
            "options": .object(["format": .string("jpeg")]),
        ]))
        _ = try repo.claim(id: job.id, leaseOwner: "worker-1")
        _ = try repo.finish(id: job.id, leaseOwner: "worker-1", status: .cancelled)
        #expect(try repo.get(job.id)?.status == .cancelled)

        let resumed = try repo.create(createParams(
            checkpoint: ["options": .object(["format": .string("jpeg"), "quality": .number(90)])]
        ))
        #expect(resumed.id != job.id, "终态行不得被复用，不得把已取消行改回 queued")
        #expect(resumed.status == .queued)
        #expect(resumed.checkpoint["destinations"]?.objectValue?["p1"]?.stringValue == "a.jpg",
                "续跑状态必须从最近终态行继承")
        #expect(resumed.checkpoint["completedPhotoIds"]?.arrayElements?.first?.stringValue == "p1")
        #expect(resumed.checkpoint["options"]?.objectValue?["quality"] == .number(90),
                "调用方显式键优先")
        #expect(try repo.get(job.id)?.status == .cancelled, "旧终态行保持原状")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM analysis_jobs") == 2)
    }

    @Test func createCanDisableCheckpointInheritance() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let job = try repo.create(createParams(checkpoint: ["stage": .string("old")]))
        _ = try repo.claim(id: job.id, leaseOwner: "w")
        _ = try repo.finish(id: job.id, leaseOwner: "w", status: .failed, error: (code: "e", message: "m"))

        let fresh = try repo.create(createParams(checkpoint: ["stage": .string("new")]), inheritCheckpoint: false)
        #expect(fresh.id != job.id)
        #expect(fresh.checkpoint["stage"]?.stringValue == "new")
    }

    @Test func getUnknownReturnsNil() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        #expect(try repo.get("nope") == nil)
    }

    /// 队列排序唯一口径：priority ASC（数值越小越紧急），同优先级按 FIFO。
    @Test func listOrdersQueueByAscendingPriorityThenFifo() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let normal = try repo.create(createParams(dedupeKey: "normal", priority: 0))
        let urgent = try repo.create(createParams(dedupeKey: "urgent", priority: -1))
        let low = try repo.create(createParams(dedupeKey: "low", priority: 5))
        let normal2 = try repo.create(createParams(dedupeKey: "normal-2", priority: 0))

        let queued = try repo.list(status: .queued)
        #expect(queued.map(\.id) == [urgent.id, normal.id, normal2.id, low.id],
                "priority ASC + rowid FIFO，实际 \(queued.map(\.dedupeKey))")

        // 展示用 list() 仍按 updated_at DESC；此处只断言集合完整。
        #expect(try repo.list().count == 4)
    }

    @Test func requestCancelOutcomes() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let queued = try repo.create(createParams(dedupeKey: "queued"))
        #expect(try repo.requestCancel(queued.id) == .cancelledQueued)
        let cancelled = try repo.get(queued.id)
        #expect(cancelled?.status == .cancelled)
        #expect(cancelled?.finishedAt != "")
        let cancelRequestedAt = try db.prepare(
            "SELECT cancel_requested_at FROM analysis_jobs WHERE id = ?"
        ).get([.text(queued.id)])?[0].textValue ?? ""
        #expect(cancelRequestedAt != "", "queued 取消必须记录 cancel_requested_at")
        // 终态幂等：再次取消无迁移。
        #expect(try repo.requestCancel(queued.id) == .notCancellable)

        let running = try repo.create(createParams(dedupeKey: "running"))
        _ = try repo.claim(id: running.id, leaseOwner: "w")
        #expect(try repo.requestCancel(running.id) == .cancellationRequested)
        #expect(try repo.get(running.id)?.status == .cancelling)
        // cancelling 行重复取消：幂等。
        #expect(try repo.requestCancel(running.id) == .alreadyCancelling)

        #expect(try repo.requestCancel("missing") == .notCancellable)
    }

    @Test func retryOnlyFromTerminal() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let failed = try repo.create(createParams(checkpoint: ["resume": .bool(true)]))
        _ = try repo.claim(id: failed.id, leaseOwner: "w")
        _ = try repo.finish(id: failed.id, leaseOwner: "w", status: .failed, error: (code: "e", message: "m"))
        #expect(try repo.retry(failed.id))
        let retried = try repo.get(failed.id)
        #expect(retried?.status == .queued)
        #expect(retried?.errorMessage == "")
        #expect(retried?.checkpoint["resume"] == .bool(true), "重试保留 checkpoint（续跑）")

        let queued = try repo.create(createParams(dedupeKey: "queued"))
        #expect(!(try repo.retry(queued.id)))
    }

    /// 回收：running 心跳超时 → interrupted；cancelling 心跳超时 → cancelled（不得恢复执行）。
    @Test func recoverStaleSeparatesRunningAndCancelling() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let stale = try repo.create(createParams(dedupeKey: "stale"))
        _ = try repo.claim(id: stale.id, leaseOwner: "w")
        _ = try db.prepare("UPDATE analysis_jobs SET heartbeat_at = '2020-01-01T00:00:00.000Z' WHERE id = ?")
            .run([.text(stale.id)])

        let cancelling = try repo.create(createParams(dedupeKey: "cancelling"))
        _ = try repo.claim(id: cancelling.id, leaseOwner: "w")
        _ = try repo.requestCancel(cancelling.id)
        _ = try db.prepare("UPDATE analysis_jobs SET heartbeat_at = '2020-01-01T00:00:00.000Z' WHERE id = ?")
            .run([.text(cancelling.id)])

        let fresh = try repo.create(createParams(dedupeKey: "fresh"))
        _ = try repo.claim(id: fresh.id, leaseOwner: "w")

        let count = try repo.recoverStale(leaseTimeoutMs: 60_000)
        #expect(count == 2)
        #expect(try repo.get(stale.id)?.status == .interrupted)
        #expect(try repo.get(stale.id)?.errorCode == "worker_lost")
        #expect(try repo.get(cancelling.id)?.status == .cancelled,
                "用户已请求取消的行不得变成可恢复的 interrupted")
        #expect(try repo.get(fresh.id)?.status == .running)
    }

    /// P1（复审）：看门狗必须能排除本进程仍在执行的 job，否则长事务饿死心跳时
    /// 会自己回收自己 → worker_lost → 重跑。
    @Test func recoverStaleExcludesActiveJobIds() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let active = try repo.create(createParams(dedupeKey: "active"))
        _ = try repo.claim(id: active.id, leaseOwner: "main-1")
        let other = try repo.create(createParams(dedupeKey: "other"))
        _ = try repo.claim(id: other.id, leaseOwner: "main-1")
        for id in [active.id, other.id] {
            _ = try db.prepare("UPDATE analysis_jobs SET heartbeat_at = '2020-01-01T00:00:00.000Z' WHERE id = ?")
                .run([.text(id)])
        }

        let count = try repo.recoverStale(leaseTimeoutMs: 60_000, excludingJobIds: [active.id])
        #expect(count == 1)
        #expect(try repo.get(active.id)?.status == .running,
                "本进程活跃 job 不得被看门狗回收")
        #expect(try repo.get(other.id)?.status == .interrupted)
    }

    @Test func resumeInterruptedByTypesAndAttemptCap() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let a = try repo.create(createParams(dedupeKey: "a"))
        let b = try repo.create(createParams(type: .faceAnalyze, dedupeKey: "b"))
        let capped = try repo.create(createParams(dedupeKey: "capped"))
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'interrupted'").run()
        _ = try db.prepare("UPDATE analysis_jobs SET attempt_count = 5 WHERE id = ?").run([.text(capped.id)])

        let count = try repo.resumeInterrupted(types: [.metadataScan], maxAttempts: 3)
        #expect(count == 1, "超限行不得自动恢复，实际恢复 \(count)")
        #expect(try repo.get(a.id)?.status == .queued)
        #expect(try repo.get(capped.id)?.status == .interrupted)
        #expect(try repo.get(b.id)?.status == .interrupted)

        #expect(try repo.resumeInterrupted(types: []) == 0)
        #expect(try repo.resumeInterrupted(types: [.metadataScan]) == 1)
        #expect(try repo.get(capped.id)?.status == .queued, "无上限时超限行也可恢复")
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

        // finish 只接受终态目标：running/cancelling/queued 一律显式报错。
        #expect(throws: AnalysisJobRepoError.nonTerminalStatus(.running)) {
            _ = try repo.finish(id: other.id, leaseOwner: "worker", status: .running)
        }
    }

    /// 清理必须显式给出终态集合：默认只清 succeeded，失败原因不被顺手删除。
    @Test func clearTerminalRequiresExplicitStatuses() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let done = try repo.create(createParams(type: .faceAnalyze, dedupeKey: "done"))
        let failed = try repo.create(createParams(dedupeKey: "failed"))
        let active = try repo.create(createParams(dedupeKey: "active"))
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'succeeded' WHERE dedupe_key = 'done'").run()
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'failed', error_message = 'keep-me' WHERE dedupe_key = 'failed'").run()

        let cleared = try repo.clearTerminal(statuses: [.succeeded])
        #expect(cleared == 1)
        #expect(try repo.get(done.id) == nil)
        #expect(try repo.get(failed.id)?.errorMessage == "keep-me", "失败原因不得被顺手删除")
        #expect(try repo.get(active.id) != nil)

        // 显式点名失败终态时才可删除。
        #expect(try repo.clearTerminal(statuses: [.failed, .interrupted, .cancelled]) == 1)
        #expect(try repo.get(failed.id) == nil)

        // 非终态集合是编程错误：显式抛出，不静默吞。
        #expect(throws: AnalysisJobRepoError.nonTerminalStatus(.running)) {
            _ = try repo.clearTerminal(statuses: [.running])
        }
        #expect(try repo.clearTerminal(statuses: []) == 0)
    }

    @Test func clearTerminalExcludesStageEvidenceTypes() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let scan = try repo.create(createParams(type: .metadataScan, dedupeKey: "scan"))
        let export = try repo.create(createParams(type: .exportExecute, dedupeKey: "export"))
        let dup = try repo.create(createParams(type: .duplicateScan, dedupeKey: "dup"))
        _ = try db.prepare("UPDATE analysis_jobs SET status = 'succeeded'").run()

        let cleared = try repo.clearTerminal(
            statuses: [.succeeded],
            excludeTypes: [.metadataScan, .exportExecute]
        )
        #expect(cleared == 1)
        #expect(try repo.get(scan.id) != nil, "metadata.scan 阶段证据应保留")
        #expect(try repo.get(export.id) != nil, "export.execute 阶段证据应保留")
        #expect(try repo.get(dup.id) == nil)
    }
}
