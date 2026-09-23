// Tests/GatherCoreTests/API/WorkspaceAPITests.swift
// R1/R2：WorkspaceAPI 派生逻辑测试（端口自 WorkspaceStatusServiceTests 的核心语义）。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/WorkspaceAPI (R1-R2)")
struct WorkspaceAPITests {
    private func makeAPI() async throws -> (GatherAPI, SQLiteDatabase, String) {
        let path = storeTempPath("workspace-api")
        let api = try await GatherAPI.open(path: path)
        return (api, api.container.database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, sessionId: String, status: String = "ready") async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text("/v/\(id).jpg"), .text("\(id).jpg"), .text(status)]
        )
    }

    private func insertScanJob(
        _ database: SQLiteDatabase,
        sessionId: String,
        status: String,
        current: Int = 0,
        total: Int = 0,
        updatedAt: String = "2026-01-01T00:00:00.000Z"
    ) async throws {
        try await database.run(
            """
            INSERT INTO analysis_jobs
              (id, type, scope_type, scope_id, dedupe_key, status, progress_current, progress_total,
               created_at, updated_at)
            VALUES (?, 'metadata.scan', 'session', ?, ?, ?, ?, ?,
                    '2026-01-01T00:00:00.000Z', ?)
            """,
            [.text("job-\(status)-\(current)"), .text(sessionId), .text("metadata.scan:\(sessionId)"),
             .text(status), .int(Int64(current)), .int(Int64(total)), .text(updatedAt)]
        )
    }

    private func insertRun(
        _ database: SQLiteDatabase,
        sessionId: String,
        kind: String,
        indexSeq: Int,
        status: String = "ok",
        finishedAt: String = "2026-01-01T00:00:00.000Z"
    ) async throws {
        try await database.run(
            """
            INSERT INTO analysis_runs
              (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, ?, 1, ?, '2026-01-01T00:00:00.000Z', ?, '{}', ?)
            """,
            [.text(sessionId), .text(kind), .int(Int64(indexSeq)), .text(finishedAt), .text(status)]
        )
    }

    private func insertOutbox(_ database: SQLiteDatabase, sessionId: String, status: String) async throws {
        let xmp = "/v/\(UUID().uuidString).xmp"
        try await database.run(
            """
            INSERT INTO metadata_outbox
              (xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json, dirty_fields,
               source_module, revision, persisted_revision, base_fingerprint, base_values_json,
               backup_path, status, attempt_count, error_message, updated_at)
            VALUES (?, ?, ?, '/v/p.jpg', '{}', '[]', 'metadata', 1, 0, '', '{}', '', ?, 1, '',
                    '2026-01-01T00:00:00.000Z')
            """,
            [.text(xmp), .text(sessionId), .text(sessionId), .text(status)]
        )
        try await database.run(
            """
            INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
            VALUES (?, ?, '', '2026-01-01T00:00:00.000Z')
            """,
            [.text(xmp), .text(sessionId)]
        )
    }

    private func insertFailedJob(_ database: SQLiteDatabase, sessionId: String, type: String = "similarity.analyze") async throws {
        try await database.run(
            """
            INSERT INTO analysis_jobs
              (id, type, scope_type, scope_id, dedupe_key, status, error_code, error_message,
               created_at, updated_at)
            VALUES (?, ?, 'session', ?, ?, 'failed', 'SIM_FAIL', 'boom',
                    '2026-01-01T00:00:00.000Z', '2026-01-02T00:00:00.000Z')
            """,
            [.text("failed-\(UUID().uuidString)"), .text(type), .text(sessionId), .text("\(type):\(sessionId)")]
        )
    }

    @Test func missingSessionReturnsNil() async throws {
        let (api, _, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        #expect(try await api.workspace.status(sessionId: "nope") == nil)
    }

    @Test func stageProgressionCreatedImportedIndexedAnalyzed() async throws {
        let (api, database, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")

        var status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.stage == .created)
        #expect(status?.recommendedNext?.action == "scan_incomplete")

        try await insertPhoto(database, id: "p1", sessionId: session.id)
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.stage == .imported)

        try await insertScanJob(database, sessionId: session.id, status: "succeeded")
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.stage == .indexed)
        #expect(status?.indexing.status == .idle)

        try await database.run("UPDATE sessions SET index_seq = 3 WHERE id = ?", [.text(session.id)])
        try await insertRun(database, sessionId: session.id, kind: "similarity", indexSeq: 3)
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.stage == .analyzed, "相似度 run 未过期（index_seq 相等）")
        #expect(status?.staleAnalyses.isEmpty == true)
    }

    @Test func activeScanJobReportsProgressAndBlocksIndexed() async throws {
        let (api, database, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")
        try await insertScanJob(database, sessionId: session.id, status: "succeeded")
        try await insertScanJob(
            database, sessionId: session.id, status: "running", current: 3, total: 4,
            updatedAt: "2026-01-02T00:00:00.000Z")

        let status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.stage == .created, "活跃扫描未结束 → 不进入 indexed")
        #expect(status?.indexing.status == .active)
        #expect(status?.indexing.total == 4)
        #expect(status?.indexing.done == 3)
        #expect(status?.indexing.percent == 75)
        #expect(status?.recommendedNext?.action == "scan_incomplete")
    }

    @Test func failedScanSurfacesFailureNotSettled() async throws {
        let (api, database, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")
        try await insertPhoto(database, id: "p1", sessionId: session.id)
        try await insertScanJob(database, sessionId: session.id, status: "failed")

        let status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.indexing.status == .failed)
        #expect(status?.stage == .imported)
        #expect(status?.recommendedNext?.action == "scan_incomplete")
    }

    @Test func staleRunsAndPriorityOrder() async throws {
        let (api, database, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")
        try await insertPhoto(database, id: "p1", sessionId: session.id)
        try await insertScanJob(database, sessionId: session.id, status: "succeeded")
        try await database.run("UPDATE sessions SET index_seq = 5 WHERE id = ?", [.text(session.id)])
        try await insertRun(database, sessionId: session.id, kind: "similarity", indexSeq: 2, finishedAt: "2026-02-01T00:00:00.000Z")
        try await insertRun(database, sessionId: session.id, kind: "face", indexSeq: 1, finishedAt: "2026-01-15T00:00:00.000Z")
        try await insertRun(database, sessionId: session.id, kind: "face", indexSeq: 9, status: "failed")

        var status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.stage == .indexed)
        #expect(status?.staleAnalyses.map(\.kind) == [.similarity, .face])
        #expect(status?.staleAnalyses.first?.lastRunAt == "2026-02-01T00:00:00.000Z")
        #expect(status?.recommendedNext?.action == "re_analyze", "陈旧分析优先于软标记")

        // xmp 冲突优先于陈旧分析。
        try await insertOutbox(database, sessionId: session.id, status: "conflict")
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.xmp.conflict == 1)
        #expect(status?.recommendedNext?.action == "resolve_conflicts")
    }

    @Test func failedJobsAndSoftFlagsProgression() async throws {
        let (api, database, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")
        try await insertPhoto(database, id: "p1", sessionId: session.id)
        try await insertScanJob(database, sessionId: session.id, status: "succeeded")
        try await database.run("UPDATE sessions SET index_seq = 1 WHERE id = ?", [.text(session.id)])
        try await insertRun(database, sessionId: session.id, kind: "similarity", indexSeq: 1)

        try await insertFailedJob(database, sessionId: session.id)
        var status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.failedJobs.count == 1)
        #expect(status?.failedJobs.first?.code == "SIM_FAIL")
        #expect(status?.failedJobs.first?.message == "boom")
        #expect(status?.recommendedNext?.action == "retry_jobs")

        // 失败 job 清除后：culling → export。
        try await database.run("DELETE FROM analysis_jobs WHERE status = 'failed'")
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.softFlags.culled == false)
        #expect(status?.recommendedNext?.action == "start_culling")

        try await database.run(
            """
            INSERT INTO writeback_items (photo_id, session_id, module, xmp_status)
            VALUES ('p1', ?, 'culling', 'written')
            """,
            [.text(session.id)]
        )
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.softFlags.culled == true)
        #expect(status?.recommendedNext?.action == "export")

        try await database.run(
            """
            INSERT INTO analysis_jobs
              (id, type, scope_type, scope_id, dedupe_key, status, created_at, updated_at)
            VALUES ('export-1', 'export.execute', 'session', ?, 'export.execute:\(session.id)', 'succeeded',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(session.id)]
        )
        status = try await api.workspace.status(sessionId: session.id)
        #expect(status?.softFlags.exported == true)
        #expect(status?.recommendedNext == nil, "全部软标记满足 → 无推荐")
    }

    @Test func offlinePhotosCacheHonorsTTL() async throws {
        final class Clock: @unchecked Sendable {
            var value: Int = 0
        }
        let (api, database, path) = try await makeAPI()
        defer { removeStoreFiles(path) }
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")
        try await insertPhoto(database, id: "p1", sessionId: session.id, status: "missing")

        let clock = Clock()
        let container = AppContainer(database: api.container.database)
        let workspace = WorkspaceAPI(
            workspace: container.workspace,
            sessions: container.sessions,
            photos: container.photos,
            writeback: container.writeback,
            clock: { clock.value }
        )

        #expect(try await workspace.status(sessionId: session.id)?.offlinePhotos == 1)
        try await insertPhoto(database, id: "p2", sessionId: session.id, status: "missing")

        // TTL 内仍返回缓存值。
        clock.value = 60_000
        #expect(try await workspace.status(sessionId: session.id)?.offlinePhotos == 1)
        // TTL 过后重新查库。
        clock.value = WorkspaceAPI.offlinePhotosTTLMs + 1
        #expect(try await workspace.status(sessionId: session.id)?.offlinePhotos == 2)
    }
}
