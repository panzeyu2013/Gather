// Store/JobStore.swift
// R1：analysis_jobs 的唯一访问入口（取代 旧 AnalysisJobRepo）。
// 返回类型沿用 Protocol/Jobs.swift 的领域 DTO（AnalysisJobData 已是 Sendable 值类型）。
import Foundation

/// W2b：asset_analysis 的 technical_quality 轻投影（不含 warnings/model 等列）。
/// 同一照片多行时，行序为 updated_at DESC（首行即最新，由调用方取首）。
public struct TechnicalQualityRow: Equatable, Sendable {
    public let requestedPhotoId: String
    public let resultJSON: String

    public init(requestedPhotoId: String, resultJSON: String) {
        self.requestedPhotoId = requestedPhotoId
        self.resultJSON = resultJSON
    }
}

/// W2c：analysis_runs 插入输入（params 为已序列化 JSON 文本；started_at/status
/// 由 Store 固定为 now / 'running'，finished_at 为空串）。
public struct AnalysisRunInsert: Equatable, Sendable {
    public let sessionId: String
    public let kind: String
    public let photoCount: Int
    public let indexSeq: Int
    public let params: String

    public init(sessionId: String, kind: String, photoCount: Int, indexSeq: Int, params: String) {
        self.sessionId = sessionId
        self.kind = kind
        self.photoCount = photoCount
        self.indexSeq = indexSeq
        self.params = params
    }
}

/// W2c：analysis_runs 行（状态语义沿用旧实现：只区分 ok/failed，取消在 catch 写 failed）。
public struct AnalysisRunRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let sessionId: String
    public let kind: String
    public let photoCount: Int
    public let indexSeq: Int
    public let startedAt: String
    public let finishedAt: String
    public let params: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id, kind, params, status
        case sessionId = "session_id"
        case photoCount = "photo_count"
        case indexSeq = "index_seq"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// W2c：technical_quality 结果行（JOIN photos：requested_photo_id 为请求的会话照片 id）。
public struct QualityAnalysisRow: Equatable, Sendable {
    public let requestedPhotoId: String
    public let assetFileId: String
    public let resultJson: String
    public let warningsJson: String
    public let modelId: String
    public let modelVersion: String
    public let inputFingerprint: String
    public let updatedAt: String

    public init(
        requestedPhotoId: String,
        assetFileId: String,
        resultJson: String,
        warningsJson: String,
        modelId: String,
        modelVersion: String,
        inputFingerprint: String,
        updatedAt: String
    ) {
        self.requestedPhotoId = requestedPhotoId
        self.assetFileId = assetFileId
        self.resultJson = resultJson
        self.warningsJson = warningsJson
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.inputFingerprint = inputFingerprint
        self.updatedAt = updatedAt
    }
}

/// W2c：asset_analysis UPSERT 输入（result_json/warnings_json 已序列化；
/// created_at 与 updated_at 同取 updatedAt，与旧写入逐字一致）。
public struct QualityAnalysisUpsert: Equatable, Sendable {
    public let photoId: String
    public let assetFileId: String
    public let resultJson: String
    public let warningsJson: String
    public let modelId: String
    public let modelVersion: String
    public let inputFingerprint: String
    public let updatedAt: String

    public init(
        photoId: String,
        assetFileId: String,
        resultJson: String,
        warningsJson: String,
        modelId: String,
        modelVersion: String,
        inputFingerprint: String,
        updatedAt: String
    ) {
        self.photoId = photoId
        self.assetFileId = assetFileId
        self.resultJson = resultJson
        self.warningsJson = warningsJson
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.inputFingerprint = inputFingerprint
        self.updatedAt = updatedAt
    }
}

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

    /// W2b：批量技术质量分析行（asset_analysis JOIN photos，ORDER BY updated_at DESC）；
    /// photoIds 为空返回 []。
    func technicalQualityRows(photoIds: [String]) async throws -> [TechnicalQualityRow]

    // MARK: analysis_runs / asset_analysis（W2c）

    /// 插入分析 run（status='running'，started_at=now，finished_at=''）；返回 runId。
    /// 插入与 lastInsertRowID 读取在同一事务内，避免并发交错取错 id。
    func insertAnalysisRun(_ insert: AnalysisRunInsert) async throws -> Int64
    /// run 终态（status + finished_at=now）；未知 runId 返回 false。
    @discardableResult
    func finishAnalysisRun(runId: Int64, status: String) async throws -> Bool
    /// 最近一次 run（ORDER BY id DESC，**不过滤 status**：1.4.2 过期判定所需的
    /// ok 过滤由 WorkspaceStore.latestOkRun 负责）；无行返回 nil。
    func latestAnalysisRun(sessionId: String, kind: String) async throws -> AnalysisRunRecord?
    /// technical_quality 结果批量 UPSERT（单事务，INSERT OR REPLACE）；空参数为 no-op。
    func upsertQualityResults(_ results: [QualityAnalysisUpsert]) async throws
    /// 指定 model/version 的存储结果（JOIN photos 按 asset_file_id 共享，
    /// ORDER BY updated_at DESC；内部 400 分块）；空参数返回 []。
    func cachedQualityResults(
        photoIds: [String],
        modelId: String,
        modelVersion: String
    ) async throws -> [QualityAnalysisRow]
    /// 每照片最新 technical_quality 行（同上 JOIN，ORDER BY updated_at DESC，
    /// 首行即最新；内部 400 分块）；空参数返回 []。
    func latestQualityResults(photoIds: [String]) async throws -> [QualityAnalysisRow]
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

    /// TS 常量 IN_CHUNK_SIZE：asset_analysis 的 IN 分块（Quality 读路径）。
    private static let qualityChunkSize = 400

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

    /// W2b：culling 富查询的批量质量行（原 CullingService.loadQualityByPhoto 的 SQL 下沉）。
    public func technicalQualityRows(photoIds: [String]) async throws -> [TechnicalQualityRow] {
        guard !photoIds.isEmpty else { return [] }
        var result: [TechnicalQualityRow] = []
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT p.id AS requested_photo_id, aa.result_json
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'technical_quality'
                  AND p.id IN (\(placeholders))
                ORDER BY aa.updated_at DESC
                """,
                chunk.map { .text($0) }
            )
            result.append(contentsOf: rows.map {
                TechnicalQualityRow(
                    requestedPhotoId: $0.text("requested_photo_id") ?? "",
                    resultJSON: $0.text("result_json") ?? "{}"
                )
            })
        }
        return result
    }

    // MARK: analysis_runs / asset_analysis（W2c：原 SimilarityService/QualityService 内联 SQL 下沉）

    public func insertAnalysisRun(_ insert: AnalysisRunInsert) async throws -> Int64 {
        try await database.transaction { db in
            try db.run(
                """
                INSERT INTO analysis_runs
                  (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
                VALUES (?, ?, ?, ?, ?, '', ?, 'running')
                """,
                [
                    .text(insert.sessionId), .text(insert.kind), .int(Int64(insert.photoCount)),
                    .int(Int64(insert.indexSeq)), .text(nowISOString()), .text(insert.params),
                ]
            )
            return db.lastInsertRowID
        }
    }

    @discardableResult
    public func finishAnalysisRun(runId: Int64, status: String) async throws -> Bool {
        try await database.run(
            "UPDATE analysis_runs SET status = ?, finished_at = ? WHERE id = ?",
            [.text(status), .text(nowISOString()), .int(runId)]
        ) == 1
    }

    public func latestAnalysisRun(sessionId: String, kind: String) async throws -> AnalysisRunRecord? {
        try await database.queryOne(
            """
            SELECT * FROM analysis_runs
            WHERE session_id = ? AND kind = ?
            ORDER BY id DESC LIMIT 1
            """,
            [.text(sessionId), .text(kind)]
        )?.decode(AnalysisRunRecord.self)
    }

    /// 单事务 UPSERT（任一行失败整批回滚）。
    public func upsertQualityResults(_ results: [QualityAnalysisUpsert]) async throws {
        guard !results.isEmpty else { return }
        try await database.transaction { db in
            for insert in results {
                try db.run(
                    """
                    INSERT OR REPLACE INTO asset_analysis (
                      photo_id, asset_file_id, analysis_type, result_json, warnings_json,
                      model_id, model_version, input_fingerprint, created_at, updated_at
                    ) VALUES (?, ?, 'technical_quality', ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(insert.photoId), .text(insert.assetFileId), .text(insert.resultJson),
                        .text(insert.warningsJson), .text(insert.modelId), .text(insert.modelVersion),
                        .text(insert.inputFingerprint), .text(insert.updatedAt), .text(insert.updatedAt),
                    ]
                )
            }
        }
    }

    public func cachedQualityResults(
        photoIds: [String],
        modelId: String,
        modelVersion: String
    ) async throws -> [QualityAnalysisRow] {
        guard !photoIds.isEmpty else { return [] }
        var results: [QualityAnalysisRow] = []
        for chunk in photoIds.chunked(by: Self.qualityChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT p.id AS requested_photo_id, aa.asset_file_id, aa.result_json, aa.warnings_json,
                       aa.model_id, aa.model_version, aa.input_fingerprint, aa.updated_at
                FROM asset_analysis aa
                JOIN photos p ON p.asset_file_id = aa.asset_file_id
                WHERE p.id IN (\(placeholders)) AND aa.analysis_type = 'technical_quality'
                  AND aa.model_id = ? AND aa.model_version = ?
                ORDER BY aa.updated_at DESC
                """,
                chunk.map { .text($0) } + [.text(modelId), .text(modelVersion)]
            )
            results.append(contentsOf: rows.map(Self.makeQualityRow))
        }
        return results
    }

    public func latestQualityResults(photoIds: [String]) async throws -> [QualityAnalysisRow] {
        guard !photoIds.isEmpty else { return [] }
        var results: [QualityAnalysisRow] = []
        for chunk in photoIds.chunked(by: Self.qualityChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT p.id AS requested_photo_id, aa.asset_file_id, aa.result_json, aa.warnings_json,
                       aa.model_id, aa.model_version, aa.input_fingerprint, aa.updated_at
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'technical_quality' AND p.id IN (\(placeholders))
                ORDER BY aa.updated_at DESC
                """,
                chunk.map { .text($0) }
            )
            results.append(contentsOf: rows.map(Self.makeQualityRow))
        }
        return results
    }

    private static func makeQualityRow(_ row: SQLiteRow) -> QualityAnalysisRow {
        QualityAnalysisRow(
            requestedPhotoId: row.text("requested_photo_id") ?? "",
            assetFileId: row.text("asset_file_id") ?? "",
            resultJson: row.text("result_json") ?? "{}",
            warningsJson: row.text("warnings_json") ?? "[]",
            modelId: row.text("model_id") ?? "",
            modelVersion: row.text("model_version") ?? "",
            inputFingerprint: row.text("input_fingerprint") ?? "",
            updatedAt: row.text("updated_at") ?? ""
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
