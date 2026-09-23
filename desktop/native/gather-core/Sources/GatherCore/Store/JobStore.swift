// Store/JobStore.swift
// R1：analysis_jobs 的唯一访问入口（取代 Database/Repositories/AnalysisJobRepo.swift）。
// 返回类型沿用 Protocol/Jobs.swift 的领域 DTO（AnalysisJobData 已是 Sendable 值类型）。
import Foundation

public protocol JobStore: Sendable {
    func create(_ params: JobCreateParams) async throws -> AnalysisJobData
    func get(_ id: String) async throws -> AnalysisJobData?
    func list(status: AnalysisJobStatus?) async throws -> [AnalysisJobData]
    func listByType(_ type: AnalysisJobType) async throws -> [AnalysisJobData]
    func requestCancel(_ id: String) async throws -> Bool
    func retry(_ id: String) async throws -> Bool
    func recoverStale(leaseTimeoutMs: Int) async throws -> Int
    func resumeInterrupted(types: [AnalysisJobType]) async throws -> Int
    func claim(id: String, leaseOwner: String) async throws -> Bool
    func heartbeat(id: String, leaseOwner: String) async throws -> Bool
    func updateProgress(id: String, leaseOwner: String, update: JobProgressUpdate) async throws -> Bool
    func finish(
        id: String,
        leaseOwner: String,
        status: AnalysisJobStatus,
        error: (code: String, message: String)?
    ) async throws -> Bool
    func interrupt(id: String, leaseOwner: String, message: String) async throws -> Bool
    func clearCompleted(excludeTypes: [AnalysisJobType]) async throws -> Int
}

public extension JobStore {
    func list() async throws -> [AnalysisJobData] {
        try await list(status: nil)
    }

    func recoverStale() async throws -> Int {
        try await recoverStale(leaseTimeoutMs: 30_000)
    }

    func finish(id: String, leaseOwner: String, status: AnalysisJobStatus) async throws -> Bool {
        try await finish(id: id, leaseOwner: leaseOwner, status: status, error: nil)
    }

    func interrupt(id: String, leaseOwner: String) async throws -> Bool {
        try await interrupt(id: id, leaseOwner: leaseOwner, message: "Application stopped during execution")
    }

    func clearCompleted() async throws -> Int {
        try await clearCompleted(excludeTypes: [])
    }
}

public struct SQLiteJobStore: JobStore {
    private static let insertSQL = """
        INSERT INTO analysis_jobs (
          id, type, scope_type, scope_id, dedupe_key, status, priority,
          input_fingerprint, model_id, model_version, checkpoint_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?)
        """

    private static let resetToQueuedSQL = """
        UPDATE analysis_jobs
        SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
            lease_owner = '', heartbeat_at = '', progress_current = 0,
            progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
        WHERE id = ?
        """

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func create(_ params: JobCreateParams) async throws -> AnalysisJobData {
        let now = nowISOString()
        let id = newUUIDString()
        let checkpointJSON = try JSONValue.stringify(JSONValue.object(params.checkpoint ?? [:]))
        do {
            try await database.run(
                Self.insertSQL,
                [
                    .text(id), .text(params.type.rawValue), .text(params.scopeType), .text(params.scopeId),
                    .text(params.dedupeKey), params.priority.map { .int(Int64($0)) } ?? .int(0),
                    .text(params.inputFingerprint ?? ""), .text(params.modelId ?? ""),
                    .text(params.modelVersion ?? ""), .text(checkpointJSON), .text(now), .text(now),
                ]
            )
        } catch let failure as SQLiteFailure where failure.isUniqueViolation {
            // 活跃行（queued/running/cancelling）占用 dedupe_key → 返回既有行。
            if let row = try await database.queryOne(
                "SELECT * FROM analysis_jobs WHERE dedupe_key = ? AND status IN ('queued', 'running', 'cancelling')",
                [.text(params.dedupeKey)]
            ) {
                return try Self.makeData(row)
            }
            // 终态行复用为自动重试（部分唯一索引只覆盖活跃状态，此分支通常不可达但保留语义）。
            if let row = try await database.queryOne(
                "SELECT * FROM analysis_jobs WHERE dedupe_key = ? AND status IN ('failed', 'cancelled', 'interrupted', 'succeeded')",
                [.text(params.dedupeKey)]
            ) {
                let terminalId = row.text("id") ?? ""
                try await database.run(Self.resetToQueuedSQL, [.text(nowISOString()), .text(terminalId)])
                guard let retried = try await get(terminalId) else {
                    throw SQLiteFailure(phase: .other, code: 0, extended: 0, message: "job row missing after retry reset: \(terminalId)")
                }
                return retried
            }
            throw failure
        }
        guard let created = try await get(id) else {
            throw SQLiteFailure(phase: .other, code: 0, extended: 0, message: "job row missing after insert: \(id)")
        }
        return created
    }

    public func get(_ id: String) async throws -> AnalysisJobData? {
        guard let row = try await database.queryOne("SELECT * FROM analysis_jobs WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try Self.makeData(row)
    }

    public func list(status: AnalysisJobStatus? = nil) async throws -> [AnalysisJobData] {
        let rows: [SQLiteRow]
        if let status {
            rows = try await database.query(
                "SELECT * FROM analysis_jobs WHERE status = ? ORDER BY priority DESC, updated_at DESC",
                [.text(status.rawValue)]
            )
        } else {
            rows = try await database.query("SELECT * FROM analysis_jobs ORDER BY updated_at DESC")
        }
        return try rows.map { try Self.makeData($0) }
    }

    public func listByType(_ type: AnalysisJobType) async throws -> [AnalysisJobData] {
        try await database.query(
            "SELECT * FROM analysis_jobs WHERE type = ? ORDER BY updated_at DESC",
            [.text(type.rawValue)]
        ).map { try Self.makeData($0) }
    }

    public func requestCancel(_ id: String) async throws -> Bool {
        try await database.run(
            """
            UPDATE analysis_jobs
            SET status = CASE WHEN status = 'queued' THEN 'cancelled' ELSE 'cancelling' END,
                cancel_requested_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('queued', 'running')
            """,
            [.text(nowISOString()), .text(nowISOString()), .text(id)]
        ) == 1
    }

    public func retry(_ id: String) async throws -> Bool {
        try await database.run(
            """
            UPDATE analysis_jobs
            SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
                lease_owner = '', heartbeat_at = '', progress_current = 0,
                progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
            WHERE id = ? AND status IN ('failed', 'interrupted', 'cancelled')
            """,
            [.text(nowISOString()), .text(id)]
        ) == 1
    }

    public func recoverStale(leaseTimeoutMs: Int = 30_000) async throws -> Int {
        let cutoff = isoString(Date().addingTimeInterval(-Double(leaseTimeoutMs) / 1000))
        return try await database.run(
            """
            UPDATE analysis_jobs
            SET status = 'interrupted', error_code = 'worker_lost',
                error_message = 'Worker heartbeat expired', finished_at = ?, updated_at = ?
            WHERE status IN ('running', 'cancelling')
              AND (heartbeat_at = '' OR heartbeat_at < ?)
            """,
            [.text(nowISOString()), .text(nowISOString()), .text(cutoff)]
        )
    }

    public func resumeInterrupted(types: [AnalysisJobType]) async throws -> Int {
        guard !types.isEmpty else { return 0 }
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        return try await database.run(
            """
            UPDATE analysis_jobs
            SET status = 'queued', error_code = '', error_message = '',
                cancel_requested_at = '', lease_owner = '', heartbeat_at = '',
                finished_at = '', updated_at = ?
            WHERE status = 'interrupted' AND type IN (\(placeholders))
            """,
            [.text(nowISOString())] + types.map { .text($0.rawValue) }
        )
    }

    public func claim(id: String, leaseOwner: String) async throws -> Bool {
        let now = nowISOString()
        return try await database.run(
            """
            UPDATE analysis_jobs
            SET status = 'running', lease_owner = ?, heartbeat_at = ?,
                started_at = COALESCE(NULLIF(started_at, ''), ?),
                attempt_count = attempt_count + 1, updated_at = ?
            WHERE id = ? AND status = 'queued'
            """,
            [.text(leaseOwner), .text(now), .text(now), .text(now), .text(id)]
        ) == 1
    }

    public func heartbeat(id: String, leaseOwner: String) async throws -> Bool {
        try await database.run(
            """
            UPDATE analysis_jobs SET heartbeat_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
            """,
            [.text(nowISOString()), .text(nowISOString()), .text(id), .text(leaseOwner)]
        ) == 1
    }

    public func updateProgress(id: String, leaseOwner: String, update: JobProgressUpdate) async throws -> Bool {
        guard let current = try await get(id) else { return false }
        let checkpoint = update.checkpoint ?? current.checkpoint
        let checkpointJSON = try JSONValue.stringify(JSONValue.object(checkpoint))
        return try await database.run(
            """
            UPDATE analysis_jobs SET progress_current = ?, progress_total = ?, progress_message = ?,
              checkpoint_json = ?, heartbeat_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
            """,
            [
                update.current.map { .int(Int64($0)) } ?? .int(Int64(current.progressCurrent)),
                update.total.map { .int(Int64($0)) } ?? .int(Int64(current.progressTotal)),
                .text(update.phase ?? update.message ?? current.progressMessage),
                .text(checkpointJSON),
                .text(nowISOString()), .text(nowISOString()), .text(id), .text(leaseOwner),
            ]
        ) == 1
    }

    public func finish(
        id: String,
        leaseOwner: String,
        status: AnalysisJobStatus,
        error: (code: String, message: String)? = nil
    ) async throws -> Bool {
        let now = nowISOString()
        return try await database.run(
            """
            UPDATE analysis_jobs SET status = ?, error_code = ?, error_message = ?, finished_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
            """,
            [
                .text(status.rawValue), .text(error?.code ?? ""), .text(error?.message ?? ""),
                .text(now), .text(now), .text(id), .text(leaseOwner),
            ]
        ) == 1
    }

    public func interrupt(
        id: String,
        leaseOwner: String,
        message: String = "Application stopped during execution"
    ) async throws -> Bool {
        let now = nowISOString()
        return try await database.run(
            """
            UPDATE analysis_jobs
            SET status = 'interrupted', error_code = 'application_stopped',
                error_message = ?, finished_at = ?, updated_at = ?
            WHERE id = ? AND status = 'running' AND lease_owner = ?
            """,
            [.text(message), .text(now), .text(now), .text(id), .text(leaseOwner)]
        ) == 1
    }

    /// 终态行全部清理；阶段证据类型可经 excludeTypes 排除。
    public func clearCompleted(excludeTypes: [AnalysisJobType] = []) async throws -> Int {
        let exclusion = excludeTypes.isEmpty
            ? ""
            : " AND type NOT IN (\(excludeTypes.map { _ in "?" }.joined(separator: ", ")))"
        return try await database.run(
            "DELETE FROM analysis_jobs WHERE status IN ('succeeded', 'cancelled', 'failed', 'interrupted')\(exclusion)",
            excludeTypes.map { .text($0.rawValue) }
        )
    }

    /// 行 → 领域 DTO（checkpoint_json 解析失败回退空对象；未知枚举回退默认值）。
    static func makeData(_ row: SQLiteRow) throws -> AnalysisJobData {
        let parsed = (try? JSONValue.parse(row.text("checkpoint_json") ?? "")) ?? JSONValue.object([:])
        let checkpoint: [String: JSONValue]
        if case .object(let dict) = parsed {
            checkpoint = dict
        } else {
            checkpoint = [:]
        }
        return AnalysisJobData(
            id: row.text("id") ?? "",
            type: AnalysisJobType(rawValue: row.text("type") ?? "") ?? .metadataScan,
            scopeType: row.text("scope_type") ?? "",
            scopeId: row.text("scope_id") ?? "",
            dedupeKey: row.text("dedupe_key") ?? "",
            status: AnalysisJobStatus(rawValue: row.text("status") ?? "") ?? .queued,
            priority: Int(row.int("priority") ?? 0),
            progressCurrent: Int(row.int("progress_current") ?? 0),
            progressTotal: Int(row.int("progress_total") ?? 0),
            progressMessage: row.text("progress_message") ?? "",
            inputFingerprint: row.text("input_fingerprint") ?? "",
            modelId: row.text("model_id") ?? "",
            modelVersion: row.text("model_version") ?? "",
            checkpoint: checkpoint,
            attemptCount: Int(row.int("attempt_count") ?? 0),
            leaseOwner: row.text("lease_owner") ?? "",
            heartbeatAt: row.text("heartbeat_at") ?? "",
            errorCode: row.text("error_code") ?? "",
            errorMessage: row.text("error_message") ?? "",
            createdAt: row.text("created_at") ?? "",
            startedAt: row.text("started_at") ?? "",
            finishedAt: row.text("finished_at") ?? "",
            updatedAt: row.text("updated_at") ?? ""
        )
    }
}
