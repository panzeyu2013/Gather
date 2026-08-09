// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/AnalysisJobRepo.swift
// TS 源: desktop/src/main/db/repositories/analysis-job.repo.ts
// 类型说明：AnalysisJobData/JobCreateParams/JobProgressUpdate/类型枚举复用 Protocol/Jobs.swift。

import Foundation

/// analysis_jobs 表行（列序与 SELECT * 一致，见 Schema.swift）。
public struct AnalysisJobRow {
    public let id: String
    public let type: String
    public let scopeType: String
    public let scopeId: String
    public let dedupeKey: String
    public let status: String
    public let priority: Int64
    public let progressCurrent: Int64
    public let progressTotal: Int64
    public let progressMessage: String
    public let inputFingerprint: String
    public let modelId: String
    public let modelVersion: String
    public let checkpointJSON: String
    public let attemptCount: Int64
    public let leaseOwner: String
    public let heartbeatAt: String
    public let cancelRequestedAt: String
    public let errorCode: String
    public let errorMessage: String
    public let createdAt: String
    public let startedAt: String
    public let finishedAt: String
    public let updatedAt: String

    public init(row: DBRow) {
        id = row[0].textValue ?? ""
        type = row[1].textValue ?? ""
        scopeType = row[2].textValue ?? ""
        scopeId = row[3].textValue ?? ""
        dedupeKey = row[4].textValue ?? ""
        status = row[5].textValue ?? ""
        priority = row[6].intValue ?? 0
        progressCurrent = row[7].intValue ?? 0
        progressTotal = row[8].intValue ?? 0
        progressMessage = row[9].textValue ?? ""
        inputFingerprint = row[10].textValue ?? ""
        modelId = row[11].textValue ?? ""
        modelVersion = row[12].textValue ?? ""
        checkpointJSON = row[13].textValue ?? ""
        attemptCount = row[14].intValue ?? 0
        leaseOwner = row[15].textValue ?? ""
        heartbeatAt = row[16].textValue ?? ""
        cancelRequestedAt = row[17].textValue ?? ""
        errorCode = row[18].textValue ?? ""
        errorMessage = row[19].textValue ?? ""
        createdAt = row[20].textValue ?? ""
        startedAt = row[21].textValue ?? ""
        finishedAt = row[22].textValue ?? ""
        updatedAt = row[23].textValue ?? ""
    }
}

/// analysis_jobs 仓库（TS AnalysisJobRepository）。
public final class AnalysisJobRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func create(_ params: JobCreateParams) throws -> AnalysisJobData {
        let now = nowISOString()
        let id = newUUIDString()
        let checkpoint = try JSONValue.stringify(JSONValue.object(params.checkpoint ?? [:]))
        do {
            _ = try connection.prepare("""
                INSERT INTO analysis_jobs (
                  id, type, scope_type, scope_id, dedupe_key, status, priority,
                  input_fingerprint, model_id, model_version, checkpoint_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?)
              """).run([
                .text(id), .text(params.type.rawValue), .text(params.scopeType), .text(params.scopeId),
                .text(params.dedupeKey), params.priority.map { .int(Int64($0)) } ?? .int(0),
                .text(params.inputFingerprint ?? ""), .text(params.modelId ?? ""),
                .text(params.modelVersion ?? ""), .text(checkpoint), .text(now), .text(now),
            ])
        } catch DBError.message(let message) where message.contains("UNIQUE") {
            if let row = try? connection.prepare("""
                SELECT * FROM analysis_jobs WHERE dedupe_key = ?
                  AND status IN ('queued', 'running', 'cancelling')
              """).get([.text(params.dedupeKey)]) {
                return toData(AnalysisJobRow(row: row))
            }
            // The only other row with this dedupe key is in a terminal state
            // (failed/cancelled/succeeded). Re-run reuses the row as an automatic retry.
            if let row = try? connection.prepare("""
                SELECT * FROM analysis_jobs WHERE dedupe_key = ?
                  AND status IN ('failed', 'cancelled', 'interrupted', 'succeeded')
              """).get([.text(params.dedupeKey)]) {
                let terminal = AnalysisJobRow(row: row)
                _ = try connection.prepare("""
                    UPDATE analysis_jobs
                    SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
                        lease_owner = '', heartbeat_at = '', progress_current = 0,
                        progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
                    WHERE id = ?
                  """).run([.text(nowISOString()), .text(terminal.id)])
                return try get(terminal.id)!
            }
            throw DBError.message(message)
        }
        return try get(id)!
    }

    public func get(_ id: String) throws -> AnalysisJobData? {
        guard let row = try connection.prepare("SELECT * FROM analysis_jobs WHERE id = ?").get([.text(id)]) else {
            return nil
        }
        return toData(AnalysisJobRow(row: row))
    }

    public func list(status: AnalysisJobStatus? = nil) throws -> [AnalysisJobData] {
        let rows: [DBRow]
        if let status {
            rows = try connection.prepare(
                "SELECT * FROM analysis_jobs WHERE status = ? ORDER BY priority DESC, updated_at DESC"
            ).query([.text(status.rawValue)])
        } else {
            rows = try connection.prepare("SELECT * FROM analysis_jobs ORDER BY updated_at DESC").query()
        }
        return rows.map { toData(AnalysisJobRow(row: $0)) }
    }

    public func listByType(_ type: AnalysisJobType) throws -> [AnalysisJobData] {
        let rows = try connection.prepare(
            "SELECT * FROM analysis_jobs WHERE type = ? ORDER BY updated_at DESC"
        ).query([.text(type.rawValue)])
        return rows.map { toData(AnalysisJobRow(row: $0)) }
    }

    public func requestCancel(_ id: String) throws -> Bool {
        try connection.prepare("""
            UPDATE analysis_jobs
            SET status = CASE WHEN status = 'queued' THEN 'cancelled' ELSE 'cancelling' END,
                cancel_requested_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('queued', 'running')
          """).run([.text(nowISOString()), .text(nowISOString()), .text(id)]) == 1
    }

    public func retry(_ id: String) throws -> Bool {
        try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
                lease_owner = '', heartbeat_at = '', progress_current = 0,
                progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
            WHERE id = ? AND status IN ('failed', 'interrupted', 'cancelled')
          """).run([.text(nowISOString()), .text(id)]) == 1
    }

    public func recoverStale(leaseTimeoutMs: Int = 30_000) throws -> Int {
        let cutoff = isoString(Date().addingTimeInterval(-Double(leaseTimeoutMs) / 1000))
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'interrupted', error_code = 'worker_lost',
                error_message = 'Worker heartbeat expired', finished_at = ?, updated_at = ?
            WHERE status IN ('running', 'cancelling')
              AND (heartbeat_at = '' OR heartbeat_at < ?)
          """).run([.text(nowISOString()), .text(nowISOString()), .text(cutoff)])
    }

    public func resumeInterrupted(types: [AnalysisJobType]) throws -> Int {
        if types.isEmpty { return 0 }
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        let now = nowISOString()
        var values: [DBValue?] = [.text(now)]
        values.append(contentsOf: types.map { .text($0.rawValue) })
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'queued', error_code = '', error_message = '',
                cancel_requested_at = '', lease_owner = '', heartbeat_at = '',
                finished_at = '', updated_at = ?
            WHERE status = 'interrupted' AND type IN (\(placeholders))
          """).run(values)
    }

    public func claim(id: String, leaseOwner: String) throws -> Bool {
        let now = nowISOString()
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'running', lease_owner = ?, heartbeat_at = ?, started_at = COALESCE(NULLIF(started_at, ''), ?),
                attempt_count = attempt_count + 1, updated_at = ?
            WHERE id = ? AND status = 'queued'
          """).run([.text(leaseOwner), .text(now), .text(now), .text(now), .text(id)]) == 1
    }

    public func heartbeat(id: String, leaseOwner: String) throws -> Bool {
        try connection.prepare("""
            UPDATE analysis_jobs SET heartbeat_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
          """).run([.text(nowISOString()), .text(nowISOString()), .text(id), .text(leaseOwner)]) == 1
    }

    public func updateProgress(id: String, leaseOwner: String, update: JobProgressUpdate) throws -> Bool {
        guard let current = try get(id) else { return false }
        let checkpoint = update.checkpoint ?? current.checkpoint
        let checkpointJSON = try JSONValue.stringify(JSONValue.object(checkpoint))
        let values: [DBValue?] = [
            update.current.map { .int(Int64($0)) } ?? .int(Int64(current.progressCurrent)),
            update.total.map { .int(Int64($0)) } ?? .int(Int64(current.progressTotal)),
            .text(update.phase ?? update.message ?? current.progressMessage),
            .text(checkpointJSON),
            .text(nowISOString()), .text(nowISOString()), .text(id), .text(leaseOwner),
        ]
        return try connection.prepare("""
            UPDATE analysis_jobs SET progress_current = ?, progress_total = ?, progress_message = ?,
              checkpoint_json = ?, heartbeat_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
          """).run(values) == 1
    }

    public func finish(
        id: String,
        leaseOwner: String,
        status: AnalysisJobStatus,
        error: (code: String, message: String)? = nil
    ) throws -> Bool {
        let now = nowISOString()
        return try connection.prepare("""
            UPDATE analysis_jobs SET status = ?, error_code = ?, error_message = ?, finished_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
          """).run([
            .text(status.rawValue), .text(error?.code ?? ""), .text(error?.message ?? ""),
            .text(now), .text(now), .text(id), .text(leaseOwner),
        ]) == 1
    }

    public func interrupt(id: String, leaseOwner: String, message: String = "Application stopped during execution") throws -> Bool {
        let now = nowISOString()
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'interrupted', error_code = 'application_stopped',
                error_message = ?, finished_at = ?, updated_at = ?
            WHERE id = ? AND status = 'running' AND lease_owner = ?
          """).run([.text(message), .text(now), .text(now), .text(id), .text(leaseOwner)]) == 1
    }

    /// Terminal rows in every status are cleared so failed/interrupted jobs
    /// do not accumulate; stage-evidence types may be excluded via `excludeTypes`.
    public func clearCompleted(excludeTypes: [AnalysisJobType] = []) throws -> Int {
        let exclusion = excludeTypes.isEmpty
            ? ""
            : " AND type NOT IN (\(excludeTypes.map { _ in "?" }.joined(separator: ", ")))"
        let values: [DBValue?] = excludeTypes.map { .text($0.rawValue) }
        let sql = "DELETE FROM analysis_jobs WHERE status IN ('succeeded', 'cancelled', 'failed', 'interrupted')\(exclusion)"
        return try connection.prepare(sql).run(values)
    }

    /// TS toData：checkpoint_json → 对象；未知枚举值回退到默认值（仅在脏数据时发生）。
    public func toData(_ row: AnalysisJobRow) -> AnalysisJobData {
        let parsed = (try? JSONValue.parse(row.checkpointJSON)) ?? JSONValue.object([:])
        let checkpoint: [String: JSONValue] = {
            if case .object(let dict) = parsed { return dict }
            return [:]
        }()
        return AnalysisJobData(
            id: row.id,
            type: AnalysisJobType(rawValue: row.type) ?? .metadataScan,
            scopeType: row.scopeType,
            scopeId: row.scopeId,
            dedupeKey: row.dedupeKey,
            status: AnalysisJobStatus(rawValue: row.status) ?? .queued,
            priority: Int(row.priority),
            progressCurrent: Int(row.progressCurrent),
            progressTotal: Int(row.progressTotal),
            progressMessage: row.progressMessage,
            inputFingerprint: row.inputFingerprint,
            modelId: row.modelId,
            modelVersion: row.modelVersion,
            checkpoint: checkpoint,
            attemptCount: Int(row.attemptCount),
            leaseOwner: row.leaseOwner,
            heartbeatAt: row.heartbeatAt,
            errorCode: row.errorCode,
            errorMessage: row.errorMessage,
            createdAt: row.createdAt,
            startedAt: row.startedAt,
            finishedAt: row.finishedAt,
            updatedAt: row.updatedAt
        )
    }
}
