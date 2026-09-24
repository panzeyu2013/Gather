// Tests/GatherCoreTests/API/WorkspaceCommandsImplTests.swift
// R5：workspace 域命令实现直测（批次 B2）。
// 覆盖旧路由分支语义：正常路径返回聚合 WorkspaceStatus（非可选），
// 会话不存在 → SESSION_NOT_FOUND。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/WorkspaceCommandsImpl (R5)")
struct WorkspaceCommandsImplTests {
    /// 目录直连 harness：WorkspaceAPI 与命令实现共享同一临时库。
    private func makeHarness() async throws -> (impl: WorkspaceCommandsImpl, db: SQLiteDatabase, path: String) {
        let path = storeTempPath("workspace-commands")
        let db = try await makeMigratedStore(path: path)
        let workspace = WorkspaceAPI(
            workspace: SQLiteWorkspaceStore(database: db),
            sessions: SQLiteSessionStore(database: db),
            photos: SQLitePhotoStore(database: db),
            writeback: SQLiteWritebackStore(database: db)
        )
        return (WorkspaceCommandsImpl(workspace: workspace), db, path)
    }

    private func insertScanJob(_ db: SQLiteDatabase, sessionId: String, status: String, done: Int, total: Int) async throws {
        _ = try await db.run(
            """
            INSERT INTO analysis_jobs
              (id, type, scope_type, scope_id, dedupe_key, status, progress_current, progress_total,
               created_at, updated_at)
            VALUES (?, 'metadata.scan', 'session', ?, ?, ?, ?, ?,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text("job-\(status)"), .text(sessionId), .text("metadata.scan:\(sessionId)"),
             .text(status), .int(Int64(done)), .int(Int64(total))]
        )
    }

    @Test("status returns the aggregated workspace status for an existing session")
    func statusReturnsAggregate() async throws {
        let (impl, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        try await insertSession(db, "s1")
        try await insertPhoto(db, id: "p1", sessionId: "s1")
        try await insertScanJob(db, sessionId: "s1", status: "succeeded", done: 1, total: 1)

        let status = try await impl.status(WorkspaceStatusParams(sessionId: "s1"))

        #expect(status.sessionId == "s1")
        #expect(status.stage == .indexed)
        #expect(status.indexing.done == 1)
        #expect(status.indexing.total == 1)
        #expect(status.indexing.percent == 100)
        #expect(status.indexing.status == .idle)
        #expect(status.offlinePhotos == 0)
        #expect(status.failedJobs.isEmpty)
        #expect(status.recommendedNext?.action == "start_culling")
        #expect(!status.generatedAt.isEmpty)
    }

    @Test("status throws SESSION_NOT_FOUND for a missing session")
    func statusMissingSessionThrows() async throws {
        let (impl, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        await #expect(throws: SessionServiceError.sessionNotFound) {
            try await impl.status(WorkspaceStatusParams(sessionId: "missing"))
        }
    }
}
