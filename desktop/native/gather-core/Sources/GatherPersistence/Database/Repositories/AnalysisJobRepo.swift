// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AnalysisJobRepo.swift
// analysis_jobs 唯一仓储：状态机迁移、去重语义、队列排序、清理口径都在此显式定义。
//
// ── 状态机（唯一迁移表，其它层只能经本文件的原子 UPDATE 迁移）──
//   queued    → running（claim）/ cancelled（requestCancel）
//   running   → succeeded | failed（finish）/ cancelling（requestCancel）
//               | interrupted（interrupt / recoverStale）
//   cancelling→ cancelled（cancelled 请求兑现 / recoverStale）/ failed（finish）
//   interrupted → queued（resumeInterrupted / retry）
//   failed | cancelled → queued（retry）
//   succeeded：终态，不可再迁移（重跑=新建行，见 create）
//
// ── 三条语义规则 ──
// 1) 去重：活跃状态 = {queued, running, cancelling}。create 先显式查询同 dedupeKey 的
//    活跃行（按 rowid 最旧）并复用；无活跃行则新建行，并在 inheritCheckpoint 时
//    把「最近一条终态行」的 checkpoint 作为续跑基线（调用方键优先覆盖）。
//    终态行不参与活跃索引，但 checkpoint 可被续跑复用 → 取消后重开不产生副本。
// 2) 优先级：数值越小越紧急（与 heavy-task-scheduler 一致；缩略图 -1 先于默认 0）。
//    队列排序唯一口径：priority ASC, updated_at ASC, rowid ASC（同优先级 FIFO）。
// 3) 清理：clearTerminal(statuses:excludeTypes:) 必须显式给出终态集合；只删调用方
//    点名的状态，失败/中断原因不会被顺手删除。

import Foundation
import GatherProtocol

/// analysis_jobs 表行（列序 = TableColumns.analysisJobs，见 Schema.swift）。
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

/// 终态集合（状态机唯一入口用它校验，调用方不得自行拼字符串）。
public let terminalAnalysisJobStatuses: Set<AnalysisJobStatus> = [.succeeded, .failed, .cancelled, .interrupted]

/// 活跃集合（同一 dedupeKey 只允许一条）。
public let activeAnalysisJobStatuses: Set<AnalysisJobStatus> = [.queued, .running, .cancelling]

public enum AnalysisJobRepoError: Error, Equatable {
    /// finish/clearTerminal 收到了非终态目标（编程错误，不得静默接受）。
    case nonTerminalStatus(AnalysisJobStatus)
    /// 写入后读回缺失（写成功但没落盘＝必须显式失败，禁止静默）。
    case writeNotPersisted(String)
}

/// requestCancel 的结果（替代 Bool：调用方据此决定是否需要等执行器收尾）。
public enum JobCancelOutcome: Equatable, Sendable {
    /// queued → cancelled，未进入执行器的排队任务已直接终结。
    case cancelledQueued
    /// running → cancelling，已受理取消请求，等待执行器观察并收尾。
    case cancellationRequested
    /// 已是 cancelling（幂等重放，不产生二次迁移）。
    case alreadyCancelling
    /// 终态或不存在，无可取消内容。
    case notCancellable
}

public final class AnalysisJobRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 创建 / 查询

    /// 创建任务（去重见文件头规则 1）。
    /// - Parameter inheritCheckpoint: 无活跃行时，是否把最近终态行的 checkpoint 作为
    ///   续跑基线（调用方本次显式提供的键优先）。调用方对「参数型 checkpoint」
    ///   可传 false 关闭继承。
    @discardableResult
    public func create(_ params: JobCreateParams, inheritCheckpoint: Bool = true) throws -> AnalysisJobData {
        if let active = try activeRow(dedupeKey: params.dedupeKey) {
            return toData(active)
        }
        var checkpoint = params.checkpoint ?? [:]
        if inheritCheckpoint, let previous = try latestTerminalRow(dedupeKey: params.dedupeKey) {
            for (key, value) in toData(previous).checkpoint where checkpoint[key] == nil {
                checkpoint[key] = value
            }
        }
        let now = nowISOString()
        let id = newUUIDString()
        let checkpointJSON = try JSONValue.stringify(JSONValue.object(checkpoint))
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
                .text(params.modelVersion ?? ""), .text(checkpointJSON), .text(now), .text(now),
            ])
        } catch DBError.message(let message) where message.uppercased().contains("UNIQUE") {
            // 跨进程竞态：另一写者抢先插入同 dedupeKey 活跃行（唯一索引兜底）。
            if let active = try activeRow(dedupeKey: params.dedupeKey) {
                return toData(active)
            }
            throw DBError.message(message)
        }
        guard let created = try get(id) else {
            throw AnalysisJobRepoError.writeNotPersisted(id)
        }
        return created
    }

    public func get(_ id: String) throws -> AnalysisJobData? {
        // analysis_jobs：24 列（TableColumns.analysisJobs，列序 = AnalysisJobRow 0-23）
        guard let row = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs WHERE id = ?").get([.text(id)]) else {
            return nil
        }
        return toData(AnalysisJobRow(row: row))
    }

    /// 队列读取（唯一排序口径：priority ASC, updated_at ASC, rowid ASC）。
    /// - Parameter includeCheckpoint: 列表展示路径可传 false（B-4/D-1/E-P0-2 性能审计）：
    ///   旧实现每行都 JSONValue.parse 整个 checkpoint_json（导出任务可达 ~1MB），
    ///   而展示侧只用进度/状态字段。默认 true 保持 IPC 契约不变。
    public func list(status: AnalysisJobStatus? = nil, includeCheckpoint: Bool = true) throws -> [AnalysisJobData] {
        let rows: [DBRow]
        if let status {
            // analysis_jobs：24 列（TableColumns.analysisJobs）
            rows = try connection.prepare("""
                SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs WHERE status = ?
                ORDER BY priority ASC, updated_at ASC, rowid ASC
                """).query([.text(status.rawValue)])
        } else {
            // 无状态筛选用于展示（最近更新在前）；队列必须走 status == .queued。
            // analysis_jobs：24 列（TableColumns.analysisJobs）
            rows = try connection.prepare(
                "SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs ORDER BY updated_at DESC, rowid DESC"
            ).query()
        }
        return rows.map { toData(AnalysisJobRow(row: $0), includeCheckpoint: includeCheckpoint) }
    }

    /// 字面量来自 SchemaSQL.activeAnalysisJobStatusSQLList：与部分唯一索引
    /// idx_analysis_jobs_active_dedupe 的 WHERE 子句逐字一致（写死两份会漂移，
    /// 顺序/参数化任一变化都会让该查询丢掉部分索引，见 Schema 注释的 EQP 证据）。
    private func activeRow(dedupeKey: String) throws -> AnalysisJobRow? {
        // analysis_jobs：24 列（TableColumns.analysisJobs）
        try connection.prepare("""
            SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs
            WHERE dedupe_key = ? AND status IN (\(SchemaSQL.activeAnalysisJobStatusSQLList))
            ORDER BY rowid ASC LIMIT 1
            """).get([.text(dedupeKey)]).map(AnalysisJobRow.init)
    }

    /// 最近一次同键终态行的 checkpoint（公开只读视图）。
    ///
    /// 供**只读**路径复用续跑基线：导出预览要展示"续跑实际会写的名字"，
    /// 必须看到与执行相同的 destinations/completedPhotoIds，否则预览会按
    /// 全新交付算名字（已存在的目标 → 多加 _2 后缀），与实际写出不符。
    public func latestTerminalCheckpoint(dedupeKey: String) throws -> [String: JSONValue]? {
        try latestTerminalRow(dedupeKey: dedupeKey).map { toData($0).checkpoint }
    }

    private func latestTerminalRow(dedupeKey: String) throws -> AnalysisJobRow? {
        // analysis_jobs：24 列（TableColumns.analysisJobs）
        try connection.prepare("""
            SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs
            WHERE dedupe_key = ? AND status IN ('succeeded', 'failed', 'cancelled', 'interrupted')
            ORDER BY updated_at DESC, rowid DESC LIMIT 1
            """).get([.text(dedupeKey)]).map(AnalysisJobRow.init)
    }

    // MARK: - 状态迁移

    /// 取消请求：queued 直接终态；running 转 cancelling（等执行器收尾）；幂等。
    public func requestCancel(_ id: String) throws -> JobCancelOutcome {
        // analysis_jobs：24 列（TableColumns.analysisJobs）
        guard let row = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs WHERE id = ?").get([.text(id)]) else {
            return .notCancellable
        }
        return try requestCancel(AnalysisJobRow(row: row))
    }

    private func requestCancel(_ row: AnalysisJobRow) throws -> JobCancelOutcome {
        let now = nowISOString()
        switch AnalysisJobStatus(rawValue: row.status) {
        case .queued:
            let changed = try connection.prepare("""
                UPDATE analysis_jobs
                SET status = 'cancelled', cancel_requested_at = ?, finished_at = ?, updated_at = ?
                WHERE id = ? AND status = 'queued'
                """).run([.text(now), .text(now), .text(now), .text(row.id)]) == 1
            if changed { return .cancelledQueued }
            return try requestCancelAfterLostRace(row.id)
        case .running:
            let changed = try connection.prepare("""
                UPDATE analysis_jobs
                SET status = 'cancelling', cancel_requested_at = ?, updated_at = ?
                WHERE id = ? AND status = 'running'
                """).run([.text(now), .text(now), .text(row.id)]) == 1
            if changed { return .cancellationRequested }
            return try requestCancelAfterLostRace(row.id)
        case .cancelling:
            return .alreadyCancelling
        default:
            return .notCancellable
        }
    }

    /// 条件 UPDATE 未命中（并发迁移抢先）：重读一次按真实状态归类，不猜测。
    private func requestCancelAfterLostRace(_ id: String) throws -> JobCancelOutcome {
        // analysis_jobs：24 列（TableColumns.analysisJobs）
        guard let latest = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.analysisJobs)) FROM analysis_jobs WHERE id = ?").get([.text(id)]) else {
            return .notCancellable
        }
        let row = AnalysisJobRow(row: latest)
        switch AnalysisJobStatus(rawValue: row.status) {
        case .queued, .running:
            return try requestCancel(row)
        case .cancelling:
            return .alreadyCancelling
        default:
            return .notCancellable
        }
    }

    /// 重试：仅 failed/interrupted/cancelled → queued；checkpoint 保留（续跑），
    /// 进度/错误/租约/取消标记全部清零。
    public func retry(_ id: String) throws -> Bool {
        try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
                lease_owner = '', heartbeat_at = '', progress_current = 0,
                progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
            WHERE id = ? AND status IN ('failed', 'interrupted', 'cancelled')
          """).run([.text(nowISOString()), .text(id)]) == 1
    }

    /// 租约超时回收：
    /// - running 心跳超时 → interrupted / worker_lost（可自动恢复）；
    /// - cancelling 心跳超时 → cancelled（用户已请求取消，绝不允许恢复执行）。
    public func recoverStale(leaseTimeoutMs: Int = 30_000) throws -> Int {
        let now = nowISOString()
        let cutoff = isoString(Date().addingTimeInterval(-Double(leaseTimeoutMs) / 1000))
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = CASE WHEN status = 'cancelling' THEN 'cancelled' ELSE 'interrupted' END,
                error_code = CASE WHEN status = 'cancelling' THEN '' ELSE 'worker_lost' END,
                error_message = CASE WHEN status = 'cancelling' THEN '' ELSE 'Worker heartbeat expired' END,
                finished_at = ?, updated_at = ?
            WHERE status IN ('running', 'cancelling')
              AND (heartbeat_at = '' OR heartbeat_at < ?)
          """).run([.text(now), .text(now), .text(cutoff)])
    }

    /// 自动恢复：interrupted → queued（checkpoint 保留）。
    /// - Parameter maxAttempts: 非 nil 时仅恢复 attempt_count < maxAttempts 的行，
    ///   防止崩溃-重启死循环；超限行保持 interrupted 等用户显式重试。
    public func resumeInterrupted(types: [AnalysisJobType], maxAttempts: Int? = nil) throws -> Int {
        if types.isEmpty { return 0 }
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        let attemptClause = maxAttempts == nil ? "" : " AND attempt_count < ?"
        var values: [DBValue?] = [.text(nowISOString())]
        values.append(contentsOf: types.map { .text($0.rawValue) })
        if let maxAttempts {
            values.append(.int(Int64(maxAttempts)))
        }
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'queued', error_code = '', error_message = '',
                cancel_requested_at = '', lease_owner = '', heartbeat_at = '',
                finished_at = '', updated_at = ?
            WHERE status = 'interrupted' AND type IN (\(placeholders))\(attemptClause)
          """).run(values)
    }

    /// 认领：仅 queued → running，attempt_count 自增，started_at 只写一次。
    public func claim(id: String, leaseOwner: String) throws -> Bool {
        let now = nowISOString()
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'running', lease_owner = ?, heartbeat_at = ?, started_at = COALESCE(NULLIF(started_at, ''), ?),
                attempt_count = attempt_count + 1, updated_at = ?
            WHERE id = ? AND status = 'queued'
          """).run([.text(leaseOwner), .text(now), .text(now), .text(now), .text(id)]) == 1
    }

    /// 心跳：仅 running/cancelling 且租约匹配；返回 false = 租约已丢失。
    public func heartbeat(id: String, leaseOwner: String) throws -> Bool {
        try connection.prepare("""
            UPDATE analysis_jobs SET heartbeat_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
          """).run([.text(nowISOString()), .text(nowISOString()), .text(id), .text(leaseOwner)]) == 1
    }

    /// 进度/checkpoint：checkpoint 缺省继承库中现值；租约或状态不符返回 false。
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

    /// 终态收尾：仅 running/cancelling 且租约匹配；目标状态必须是终态。
    public func finish(
        id: String,
        leaseOwner: String,
        status: AnalysisJobStatus,
        error: (code: String, message: String)? = nil
    ) throws -> Bool {
        guard terminalAnalysisJobStatuses.contains(status) else {
            throw AnalysisJobRepoError.nonTerminalStatus(status)
        }
        let now = nowISOString()
        return try connection.prepare("""
            UPDATE analysis_jobs SET status = ?, error_code = ?, error_message = ?, finished_at = ?, updated_at = ?
            WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
          """).run([
            .text(status.rawValue), .text(error?.code ?? ""), .text(error?.message ?? ""),
            .text(now), .text(now), .text(id), .text(leaseOwner),
          ]) == 1
    }

    /// 进程停止兜底：running → interrupted（下次启动按类型策略恢复）。
    public func interrupt(id: String, leaseOwner: String, message: String = "Application stopped during execution") throws -> Bool {
        let now = nowISOString()
        return try connection.prepare("""
            UPDATE analysis_jobs
            SET status = 'interrupted', error_code = 'application_stopped',
                error_message = ?, finished_at = ?, updated_at = ?
            WHERE id = ? AND status = 'running' AND lease_owner = ?
          """).run([.text(message), .text(now), .text(now), .text(id), .text(leaseOwner)]) == 1
    }

    /// 显式清理：只删除调用方点名的终态集合（默认由调用方传 [.succeeded]），
    /// excludeTypes 用于保护 workspace 阶段证据（metadata.scan / export.execute）。
    /// 失败/中断/取消行及其错误原因不会被隐式删除。
    public func clearTerminal(statuses: [AnalysisJobStatus], excludeTypes: [AnalysisJobType] = []) throws -> Int {
        for status in statuses where !terminalAnalysisJobStatuses.contains(status) {
            throw AnalysisJobRepoError.nonTerminalStatus(status)
        }
        guard !statuses.isEmpty else { return 0 }
        let statusPlaceholders = statuses.map { _ in "?" }.joined(separator: ", ")
        var values: [DBValue?] = statuses.map { .text($0.rawValue) }
        var exclusion = ""
        if !excludeTypes.isEmpty {
            exclusion = " AND type NOT IN (\(excludeTypes.map { _ in "?" }.joined(separator: ", ")))"
            values.append(contentsOf: excludeTypes.map { .text($0.rawValue) })
        }
        return try connection.prepare(
            "DELETE FROM analysis_jobs WHERE status IN (\(statusPlaceholders))\(exclusion)"
        ).run(values)
    }

    /// WP3b-1（WorkspaceStatus 下沉）：最近更新的 metadata.scan 行。
    public func latestScanJob(sessionId: String) throws -> ScanJobRecord? {
        guard let row = try connection.prepare("""
            SELECT status, progress_current, progress_total
            FROM analysis_jobs
            WHERE type = 'metadata.scan' AND scope_id = ?
            ORDER BY updated_at DESC
            LIMIT 1
          """).get([.text(sessionId)]) else { return nil }
        return ScanJobRecord(
            status: row[0].textValue ?? "",
            progressCurrent: Int(row[1].intValue ?? 0),
            progressTotal: Int(row[2].intValue ?? 0)
        )
    }

    /// WP3b-1（WorkspaceStatus 下沉）：scope=session 的失败 job。
    public func failedJobs(sessionId: String, limit: Int) throws -> [FailedJobRecord] {
        let rows = try connection.prepare("""
            SELECT id, type, error_message, error_code
            FROM analysis_jobs
            WHERE scope_type = 'session' AND scope_id = ? AND status = 'failed'
            ORDER BY updated_at DESC
            LIMIT ?
          """).query([.text(sessionId), .int(Int64(limit))])
        return rows.map { row in
            FailedJobRecord(
                id: row[0].textValue ?? "",
                type: row[1].textValue ?? "",
                code: row[3].textValue ?? "",
                message: row[2].textValue ?? ""
            )
        }
    }

    /// WP3b-1（WorkspaceStatus 下沉）：成功 export.execute 的 checkpoint_json。
    /// 「是否实际交付了文件」的判定仍留在 Application（解析 exported 键）。
    public func successfulExportCheckpoints(sessionId: String, limit: Int) throws -> [String] {
        let rows = try connection.prepare("""
            SELECT checkpoint_json FROM analysis_jobs
            WHERE type = 'export.execute' AND scope_id = ? AND status = 'succeeded'
            ORDER BY updated_at DESC
            LIMIT ?
          """).query([.text(sessionId), .int(Int64(limit))])
        return rows.map { $0.first?.textValue ?? "" }
    }

    /// WP3b-1（SessionService 下沉）：无 FK 的 analysis_jobs 僵尸行清理。
    public func deleteSessionJobs(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM analysis_jobs WHERE scope_type = 'session' AND scope_id = ?")
            .run([.text(sessionId)])
    }

    /// 行 → 契约类型；checkpoint_json 解析失败（脏数据）按空对象处理，
    /// 未知枚举值回退默认值——仅在库被外部改写时发生。
    public func toData(_ row: AnalysisJobRow, includeCheckpoint: Bool = true) -> AnalysisJobData {
        let checkpoint: [String: JSONValue]
        if includeCheckpoint {
            let parsed = (try? JSONValue.parse(row.checkpointJSON)) ?? JSONValue.object([:])
            if case .object(let dict) = parsed { checkpoint = dict } else { checkpoint = [:] }
        } else {
            checkpoint = [:]
        }
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