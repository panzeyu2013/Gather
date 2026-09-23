// Store/WorkspaceStore.swift
// R1：工作区状态聚合所需的派生查询（analysis_jobs / analysis_runs / photos /
// writeback_items / metadata_outbox），取代 WorkspaceStatusService 的内联 SQL。
import Foundation

public struct WorkspaceScanJob: Equatable, Sendable {
    public let status: String
    public let progressCurrent: Int
    public let progressTotal: Int

    public init(status: String, progressCurrent: Int, progressTotal: Int) {
        self.status = status
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
    }
}

public struct WorkspaceAnalysisRun: Equatable, Sendable {
    public let kind: String
    public let indexSeq: Int
    public let finishedAt: String

    public init(kind: String, indexSeq: Int, finishedAt: String) {
        self.kind = kind
        self.indexSeq = indexSeq
        self.finishedAt = finishedAt
    }
}

public struct WorkspaceFailedJobRecord: Equatable, Sendable {
    public let id: String
    public let type: String
    public let code: String
    public let message: String

    public init(id: String, type: String, code: String, message: String) {
        self.id = id
        self.type = type
        self.code = code
        self.message = message
    }
}

public protocol WorkspaceStore: Sendable {
    func latestScanJob(sessionId: String) async throws -> WorkspaceScanJob?
    func latestOkRun(sessionId: String, kind: String) async throws -> WorkspaceAnalysisRun?
    func hasWrittenBackCulling(sessionId: String) async throws -> Bool
    func hasSuccessfulExport(sessionId: String) async throws -> Bool
    func failedJobs(sessionId: String) async throws -> [WorkspaceFailedJobRecord]
    func offlinePhotoCount(sessionId: String) async throws -> Int
}

public struct SQLiteWorkspaceStore: WorkspaceStore {
    /// TS: MAX_FAILED_JOBS。
    public static let maxFailedJobs = 10

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// TS: latestScanJob —— 最近更新的 metadata.scan 行（scope_id = sessionId）。
    public func latestScanJob(sessionId: String) async throws -> WorkspaceScanJob? {
        try await database.queryOne(
            """
            SELECT status, progress_current, progress_total
            FROM analysis_jobs
            WHERE type = 'metadata.scan' AND scope_id = ?
            ORDER BY updated_at DESC
            LIMIT 1
            """,
            [.text(sessionId)]
        ).map {
            WorkspaceScanJob(
                status: $0.text("status") ?? "",
                progressCurrent: Int($0.int("progress_current") ?? 0),
                progressTotal: Int($0.int("progress_total") ?? 0)
            )
        }
    }

    /// TS: latestOkRun —— 最近一次成功的分析 run（status='ok'，ORDER BY id DESC）。
    public func latestOkRun(sessionId: String, kind: String) async throws -> WorkspaceAnalysisRun? {
        try await database.queryOne(
            """
            SELECT kind, index_seq, finished_at
            FROM analysis_runs
            WHERE session_id = ? AND kind = ? AND status = 'ok'
            ORDER BY id DESC
            LIMIT 1
            """,
            [.text(sessionId), .text(kind)]
        ).map {
            WorkspaceAnalysisRun(
                kind: $0.text("kind") ?? "",
                indexSeq: Int($0.int("index_seq") ?? 0),
                finishedAt: $0.text("finished_at") ?? ""
            )
        }
    }

    /// 已写回的挑片决策：writeback_items（module='culling'）或 metadata_outbox
    /// （source_module='culling'）任一出现 written/synced 行即视为已写回。
    public func hasWrittenBackCulling(sessionId: String) async throws -> Bool {
        if try await database.queryOne(
            """
            SELECT 1 FROM writeback_items
            WHERE session_id = ? AND module = 'culling' AND xmp_status IN ('written', 'synced')
            LIMIT 1
            """,
            [.text(sessionId)]
        ) != nil {
            return true
        }
        return try await database.queryOne(
            """
            SELECT 1
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ? AND o.source_module = 'culling' AND o.status IN ('written', 'synced')
            LIMIT 1
            """,
            [.text(sessionId)]
        ) != nil
    }

    /// 存在成功导出的 job 记录：analysis_jobs type='export.execute' status='succeeded'。
    public func hasSuccessfulExport(sessionId: String) async throws -> Bool {
        try await database.queryOne(
            """
            SELECT 1 FROM analysis_jobs
            WHERE type = 'export.execute' AND scope_id = ? AND status = 'succeeded'
            LIMIT 1
            """,
            [.text(sessionId)]
        ) != nil
    }

    /// TS: listFailedJobs —— scope_type='session' 的失败 job，按 updated_at 倒序，上限 10。
    public func failedJobs(sessionId: String) async throws -> [WorkspaceFailedJobRecord] {
        try await database.query(
            """
            SELECT id, type, error_message, error_code
            FROM analysis_jobs
            WHERE scope_type = 'session' AND scope_id = ? AND status = 'failed'
            ORDER BY updated_at DESC
            LIMIT \(Self.maxFailedJobs)
            """,
            [.text(sessionId)]
        ).map {
            WorkspaceFailedJobRecord(
                id: $0.text("id") ?? "",
                type: $0.text("type") ?? "",
                code: $0.text("error_code") ?? "",
                message: $0.text("error_message") ?? ""
            )
        }
    }

    public func offlinePhotoCount(sessionId: String) async throws -> Int {
        Int(try await database.scalarInt(
            "SELECT COUNT(*) AS count FROM photos WHERE session_id = ? AND status = 'missing'",
            [.text(sessionId)]
        ) ?? 0)
    }
}
