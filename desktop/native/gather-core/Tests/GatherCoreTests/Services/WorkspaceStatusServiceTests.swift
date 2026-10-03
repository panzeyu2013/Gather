// desktop/native/gather-core/Tests/GatherCoreTests/Services/WorkspaceStatusServiceTests.swift
// WorkspaceStatusService 行为测试。
// TS 源: tests/unit/services/workspace/workspace-status.test.ts（用例逐一对应，
// 见文件末尾对照表）。差异说明：
// - TS 通过注入 mock 的 getSummary() 直接设置 summary 计数；Swift 侧没有
//    coordinator，summary 来自真实 outbox 表（summaryCounts 投影），
//   "folds failed xmp rows into pending" 用例改为种子 outbox 行断言同一投影。
// - clear_completed 两用例：TS 走 JobService.clearCompleted()（排除
//   metadata.scan / export.execute 证据行），Swift 等价于
//   AnalysisJobRepo.clearTerminal(statuses:excludeTypes:)（状态集合必填；
//   只清点名的终态，失败原因不会被顺手删除）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - Fixtures

private struct ServiceHarness {
    let db: DBConnection
    let sessionId: String
    let service: WorkspaceStatusService
}

private func makeHarness(
    clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
) throws -> ServiceHarness {
    let db = try makeMigratedDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Workspace", source: "folder")
    let service = WorkspaceStatusService(
        connection: db,
        sessionRepo: sessionRepo,
        photoRepo: PhotoRepo(connection: db),
        outboxRepo: MetadataOutboxRepo(connection: db),
        clock: clock
    )
    return ServiceHarness(db: db, sessionId: session.id, service: service)
}

/// TS: addPhoto。
private func addPhoto(_ db: DBConnection, _ sessionId: String, _ id: String, status: String = "pending") throws {
    let now = nowISOString()
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', ?, '{}', '{}', 100, 80, ?, ?)
      """).run([.text(id), .text(sessionId), .text("/tmp/\(id).jpg"), .text("\(id).jpg"), .text(status), .text(now), .text(now)])
}

private struct JobSeed {
    var id: String
    var type: String = "metadata.scan"
    var status: String
    var updatedAt: String
    var progressCurrent: Int = 0
    var progressTotal: Int = 0
    var errorMessage: String = ""
    var errorCode: String = ""
    /// checkpoint_json（D02：交付摘要就存在这里）。
    var checkpointJSON: String = "{}"
}

/// TS: addJob。
private func addJob(_ db: DBConnection, _ sessionId: String, options: JobSeed) throws {
    _ = try db.prepare("""
        INSERT INTO analysis_jobs (
          id, type, scope_type, scope_id, dedupe_key, status, priority,
          progress_current, progress_total, progress_message, error_message, error_code,
          input_fingerprint, model_id, model_version, checkpoint_json, attempt_count,
          lease_owner, heartbeat_at, cancel_requested_at, created_at, started_at, finished_at, updated_at
        ) VALUES (?, ?, 'session', ?, ?, ?, 0, ?, ?, '', ?, ?, '', '', '', ?, 0, '', '', '', ?, '', ?, ?)
      """).run([
        .text(options.id),
        .text(options.type),
        .text(sessionId),
        .text("\(options.type):\(sessionId)"),
        .text(options.status),
        .int(Int64(options.progressCurrent)),
        .int(Int64(options.progressTotal)),
        .text(options.errorMessage),
        .text(options.errorCode),
        .text(options.checkpointJSON),
        .text(options.updatedAt),
        .text(options.updatedAt),
        .text(options.updatedAt),
      ])
}

/// TS: addAnalysisRun。
private func addAnalysisRun(
    _ db: DBConnection,
    _ sessionId: String,
    kind: String,
    indexSeq: Int,
    status: String = "ok",
    finishedAt: String? = nil
) throws {
    let finished = finishedAt ?? nowISOString()
    _ = try db.prepare("""
        INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
        VALUES (?, ?, 1, ?, ?, ?, '{}', ?)
      """).run([.text(sessionId), .text(kind), .int(Int64(indexSeq)), .text(finished), .text(finished), .text(status)])
}

/// 种子一条 outbox 行并挂到 session（TS 测试里 metadata_outbox + metadata_outbox_sessions 两组 INSERT）。
private func addOutboxRow(
    _ db: DBConnection,
    _ sessionId: String,
    xmpPath: String,
    status: String,
    sourceModule: String = "culling"
) throws {
    let now = nowISOString()
    _ = try db.prepare("""
        INSERT INTO metadata_outbox (xmp_path, photo_path, patch_json, dirty_fields, source_module, revision, persisted_revision, status, updated_at)
        VALUES (?, ?, '{}', '[]', ?, 1, 0, ?, ?)
      """).run([.text(xmpPath), .text("/tmp/photo.jpg"), .text(sourceModule), .text(status), .text(now)])
    _ = try db.prepare("""
        INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
        VALUES (?, ?, '', ?)
      """).run([.text(xmpPath), .text(sessionId), .text(now)])
}

/// TS: writeback_items（culling 写回）INSERT。
private func addWritebackItem(_ db: DBConnection, _ sessionId: String, xmpStatus: String = "written") throws {
    _ = try db.prepare("""
        INSERT INTO writeback_items (photo_id, photo_path, session_id, module, keywords, attributes_json, xmp_path, backup_path, xmp_status, error_message, last_attempt_at)
        VALUES ('photo-1', '/tmp/photo-1.jpg', ?, 'culling', '[]', '{}', '/tmp/photo-1.xmp', '', ?, '', '')
      """).run([.text(sessionId), .text(xmpStatus)])
}

// MARK: - Tests

struct WorkspaceStatusServiceTests {

    // MARK: stage derivation（TS: 'WorkspaceStatusService stage derivation'）

    @Test func returnsNilForUnknownSession() throws {
        let harness = try makeHarness()
        #expect(try harness.service.getStatus(sessionId: "missing-session") == nil)
    }

    @Test func reportsCreatedForSessionWithoutPhotos() throws {
        let harness = try makeHarness()
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).stage == .created)
    }

    @Test func reportsImportedOncePhotosExist() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.stage == .imported)
        #expect(unwrapped.softFlags == WorkspaceSoftFlags(culled: false, exported: false))
    }

    @Test func reportsIndexedAfterSucceededScanJob() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).stage == .indexed)
    }

    @Test func treatsActiveIndexWorkAfterSucceededScanAsNotIndexed() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-2", status: "queued", updatedAt: "2026-08-08T00:01:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).stage == .imported)
    }

    @Test func reportsAnalyzedForNonStaleSimilarityRun() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.stage == .analyzed)
        #expect(unwrapped.staleAnalyses.isEmpty)
    }

    @Test func fallsBackToIndexedWhenSimilarityRunBecomesStale() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        _ = try SessionRepo(connection: harness.db).bumpIndexSeq(id: harness.sessionId)
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.stage == .indexed)
        #expect(unwrapped.staleAnalyses.count == 1)
        #expect(unwrapped.staleAnalyses[0].kind == .similarity)
        #expect(!unwrapped.staleAnalyses[0].lastRunAt.isEmpty)
    }

    @Test func reportsIndexingProgressFromActiveScanJob() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1",
            status: "running",
            updatedAt: "2026-08-08T00:00:00.000Z",
            progressCurrent: 25,
            progressTotal: 100
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.indexing == WorkspaceIndexingProgress(total: 100, done: 25, percent: 25, status: .active))
        #expect(unwrapped.stage == .imported)
    }

    @Test func reportsQueuedScansAsActiveEvenWithZeroProgress() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "queued", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.indexing == WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .active))
        #expect(unwrapped.recommendedNext == WorkspaceRecommendedNext(action: "scan_incomplete", target: "index"))
    }

    @Test func reportsFailedScansAsFailedNotSettled() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "failed", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.indexing == WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .failed))
        #expect(unwrapped.stage == .imported)
        #expect(unwrapped.recommendedNext == WorkspaceRecommendedNext(action: "scan_incomplete", target: "index"))
    }

    @Test func reportsZeroIdleIndexingWhenNoScanJobActive() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).indexing == WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .idle))
    }

    // MARK: stale analyses（TS: 'WorkspaceStatusService stale analyses'）

    @Test func listsStaleSimilarityAndFaceRunsWithLastRunTime() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0, finishedAt: "2026-08-08T01:00:00.000Z")
        try addAnalysisRun(harness.db, harness.sessionId, kind: "face", indexSeq: 0, finishedAt: "2026-08-08T02:00:00.000Z")
        _ = try SessionRepo(connection: harness.db).bumpIndexSeq(id: harness.sessionId)
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).staleAnalyses == [
            WorkspaceStaleAnalysis(kind: .similarity, lastRunAt: "2026-08-08T01:00:00.000Z"),
            WorkspaceStaleAnalysis(kind: .face, lastRunAt: "2026-08-08T02:00:00.000Z"),
        ])
    }

    @Test func omitsFailedRunsAndNonStaleRuns() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0, status: "failed")
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).staleAnalyses.isEmpty)
    }

    // MARK: offline photos TTL（TS: 'WorkspaceStatusService offline photos TTL'）

    @Test func cachesOfflinePhotosWithinTTLAndReQueriesAfter() throws {
        var now = 1_000_000
        let harness = try makeHarness(clock: { now })
        try addPhoto(harness.db, harness.sessionId, "photo-1")

        let before = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(before).offlinePhotos == 0)
        _ = try harness.db.prepare("UPDATE photos SET status = 'missing' WHERE id = 'photo-1'").run()

        // TTL 内（TTL - 1ms）仍然命中旧缓存值。
        now += WorkspaceStatusService.offlinePhotosTTLMs - 1
        let withinTTL = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(withinTTL).offlinePhotos == 0)

        // 越过 TTL 后重新查库。
        now += 2
        let afterTTL = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(afterTTL).offlinePhotos == 1)
    }

    // MARK: recommendedNext priority（TS: 'WorkspaceStatusService recommendedNext priority'）

    @Test func scanIncompleteWinsOverXmpConflicts() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c1.xmp", status: "conflict")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c2.xmp", status: "conflict")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c3.xmp", status: "conflict")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "queued", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).recommendedNext == WorkspaceRecommendedNext(action: "scan_incomplete", target: "index"))
    }

    @Test func xmpConflictsBeatStaleAnalyses() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c1.xmp", status: "conflict")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        _ = try SessionRepo(connection: harness.db).bumpIndexSeq(id: harness.sessionId)
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).recommendedNext == WorkspaceRecommendedNext(action: "resolve_conflicts", target: "metadata"))
    }

    @Test func staleAnalysesBeatFailedJobs() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        _ = try SessionRepo(connection: harness.db).bumpIndexSeq(id: harness.sessionId)
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "job-1", type: "quality.score", status: "failed",
            updatedAt: "2026-08-08T00:02:00.000Z", errorMessage: "boom"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).recommendedNext == WorkspaceRecommendedNext(action: "re_analyze", target: "similarity"))
    }

    @Test func failedJobsSurfaceWhenNothingElseIsPending() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "job-1", type: "quality.score", status: "failed",
            updatedAt: "2026-08-08T00:02:00.000Z", errorMessage: "boom"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        #expect(unwrapped.recommendedNext == WorkspaceRecommendedNext(action: "retry_jobs", target: "jobs"))
        #expect(unwrapped.failedJobs == [
            WorkspaceFailedJob(id: "job-1", type: "quality.score", code: "", message: "boom"),
        ])
    }

    @Test func progressesToCullingThenExportWhenHealthy() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addAnalysisRun(harness.db, harness.sessionId, kind: "similarity", indexSeq: 0)
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).recommendedNext == WorkspaceRecommendedNext(action: "start_culling", target: "culling"))

        try addWritebackItem(harness.db, harness.sessionId)
        let afterCulling = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(afterCulling).recommendedNext == WorkspaceRecommendedNext(action: "export", target: "export"))

        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "export-1", type: "export.execute", status: "succeeded",
            updatedAt: "2026-08-08T00:03:00.000Z"
        ))
        let afterExport = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(afterExport).recommendedNext == nil)
    }

    // MARK: soft flags and counts（TS: 'WorkspaceStatusService soft flags and counts'）

    @Test func culledIsTrueWhenCullingWritebackItemWasWrittenBack() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addWritebackItem(harness.db, harness.sessionId, xmpStatus: "written")
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).softFlags.culled == true)
    }

    @Test func culledIsTrueWhenCullingOutboxReachedSynced() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/photo-1.xmp", status: "synced")
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).softFlags.culled == true)
    }

    @Test func exportedIsTrueAfterSucceededExportJob() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "export-1", type: "export.execute", status: "succeeded",
            updatedAt: "2026-08-08T00:03:00.000Z"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).softFlags.exported == true)
    }

    @Test func foldsFailedXmpRowsIntoPendingAndReportsConflicts() throws {
        let harness = try makeHarness()
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/p1.xmp", status: "pending")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/p2.xmp", status: "pending")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/f1.xmp", status: "failed")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c1.xmp", status: "conflict")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c2.xmp", status: "conflict")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c3.xmp", status: "conflict")
        try addOutboxRow(harness.db, harness.sessionId, xmpPath: "/tmp/c4.xmp", status: "conflict")
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).xmp == WorkspaceXmpCounts(pending: 3, conflict: 4))
    }

    @Test func returnsErrorCodeAndErrorMessageSeparatelyForFailedJobs() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "job-1", type: "export.execute", status: "failed",
            updatedAt: "2026-08-08T00:03:00.000Z", errorMessage: "disk full", errorCode: "worker_error"
        ))
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "job-2", type: "thumbnail.build", status: "failed",
            updatedAt: "2026-08-08T00:04:00.000Z", errorCode: "worker_error"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
         #expect(try #require(status).failedJobs == [
            WorkspaceFailedJob(id: "job-2", type: "thumbnail.build", code: "worker_error", message: ""),
            WorkspaceFailedJob(id: "job-1", type: "export.execute", code: "worker_error", message: "disk full"),
        ])
    }

    // MARK: clear_completed stage-evidence protection（TS: 'WorkspaceStatusService clear_completed stage-evidence protection'）

    @Test func keepsWorkspaceIndexedAfterClearCompleted() throws {
        let harness = try makeHarness()
        let jobs = AnalysisJobRepo(connection: harness.db)
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "succeeded", updatedAt: "2026-08-08T00:00:00.000Z"
        ))
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "export-1", type: "export.execute", status: "succeeded",
            updatedAt: "2026-08-08T00:03:00.000Z"
        ))
        // 一个已完成的非证据 job 被正常清理。
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "thumb-1", type: "thumbnail.build", status: "succeeded",
            updatedAt: "2026-08-08T00:04:00.000Z"
        ))

        let cleared = try jobs.clearTerminal(statuses: [.succeeded], excludeTypes: [.metadataScan, .exportExecute])
        #expect(cleared == 1)

        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        // 成功的 metadata.scan 行是阶段证据：必须保留，否则完整索引的工作区
        // 会回退到 imported / scan_incomplete。
        #expect(unwrapped.stage == .indexed)
        #expect(unwrapped.recommendedNext?.action != "scan_incomplete")
        #expect(unwrapped.softFlags.exported == true)
    }

    @Test func keepsFailedScanEvidenceSoFailureSignalSurvivesClearCompleted() throws {
        let harness = try makeHarness()
        let jobs = AnalysisJobRepo(connection: harness.db)
        try addPhoto(harness.db, harness.sessionId, "photo-1")
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "scan-1", status: "failed", updatedAt: "2026-08-08T00:00:00.000Z", errorMessage: "io"
        ))
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "job-1", type: "quality.score", status: "failed",
            updatedAt: "2026-08-08T00:02:00.000Z", errorMessage: "boom"
        ))

        // 显式点名清理失败终态：quality 行被清，failed metadata.scan 作为证据保留。
        _ = try jobs.clearTerminal(statuses: [.failed], excludeTypes: [.metadataScan, .exportExecute])

        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        let unwrapped = try #require(status)
        // metadata.scan 行是失败信号源（Dashboard/CC "index failed" 种子），
        // 必须保留并继续出现在 failedJobs；quality 行不是阶段证据，正常被清理。
        #expect(unwrapped.failedJobs == [
            WorkspaceFailedJob(id: "scan-1", type: "metadata.scan", code: "", message: "io"),
        ])
        #expect(unwrapped.indexing.status == .failed)
    }

    /// TTL 是「严格小于」才命中缓存：恰好等于 TTL 必须失效重查。
    /// 变异「now - cachedAt < TTL 改成 <=」可杀。
    @Test func offlinePhotosCacheExpiresExactlyAtTTL() throws {
        var now = 2_000_000
        let harness = try makeHarness(clock: { now })
        try addPhoto(harness.db, harness.sessionId, "photo-1")

        let first = try harness.service.getStatus(sessionId: harness.sessionId)
        #expect(try #require(first).offlinePhotos == 0)
        _ = try harness.db.prepare("UPDATE photos SET status = 'missing' WHERE id = 'photo-1'").run()

        // 恰好到达 TTL（不是 TTL-1，也不是 TTL+1）：边界必须判失效。
        now += WorkspaceStatusService.offlinePhotosTTLMs
        let atTTL = try harness.service.getStatus(sessionId: harness.sessionId)
        #expect(try #require(atTTL).offlinePhotos == 1, "恰好到达 TTL 时必须重新查库，实际缓存值被复用")
    }

    // MARK: 深度审查 D02：已导出必须基于实际交付结果

    @Test func allFailedExportDoesNotMarkWorkspaceExported() throws {
        // 全失败的空交付：任务记录是 succeeded（执行器正常返回），但交付摘要
        // exported == 0 —— 工作区不得因此显示「已导出」（阶段徽章/待办都会误报）。
        let harness = try makeHarness()
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "export-all-failed",
            type: "export.execute",
            status: "succeeded",
            updatedAt: nowISOString(),
            checkpointJSON: "{\"exported\":0,\"failed\":3,\"skipped\":0,\"totalFiles\":3}"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        #expect(try #require(status).softFlags.exported == false, "零产出的 succeeded 任务不算已交付")
    }

    @Test func successfulExportWithDeliveriesMarksWorkspaceExported() throws {
        let harness = try makeHarness()
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "export-partial",
            type: "export.execute",
            status: "succeeded",
            updatedAt: nowISOString(),
            checkpointJSON: "{\"exported\":2,\"failed\":1,\"skipped\":0,\"totalFiles\":3}"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        #expect(try #require(status).softFlags.exported, "至少产出一个文件才算交付（部分成功仍是交付）")
    }

    @Test func legacyExportWithoutDeliverySummaryKeepsOldSemantics() throws {
        // 兼容：本次改动之前的历史成功任务没有交付摘要，无法回溯区分，
        // 按原语义视为已导出（不因为一次审计把老用户的工作区状态清空）。
        let harness = try makeHarness()
        try addJob(harness.db, harness.sessionId, options: JobSeed(
            id: "export-legacy",
            type: "export.execute",
            status: "succeeded",
            updatedAt: nowISOString(),
            checkpointJSON: "{}"
        ))
        let status = try harness.service.getStatus(sessionId: harness.sessionId)
        #expect(try #require(status).softFlags.exported == true)
    }
}
