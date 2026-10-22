// desktop/native/gather-core/Sources/GatherPersistence/Ports/JobRepository.swift
// WP3b-1：Job 仓储端口（只含 Application 实际调用的方法）。
//
// JobService 是纯编排（租约/心跳/进度/取消），旧实现已全部经 AnalysisJobRepo；
// 本端口只是把具体类换成协议。WorkspaceStatus 的三个 job 只读投影也在此。
import Foundation
import GatherProtocol

/// WorkspaceStatus.latestScanJob。
public struct ScanJobRecord: Equatable, Sendable {
    public let status: String
    public let progressCurrent: Int
    public let progressTotal: Int

    public init(status: String, progressCurrent: Int, progressTotal: Int) {
        self.status = status
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
    }
}

/// WorkspaceStatus.listFailedJobs。
public struct FailedJobRecord: Equatable, Sendable {
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

public protocol JobRepository {
    func create(_ params: JobCreateParams, inheritCheckpoint: Bool) throws -> AnalysisJobData
    func get(_ id: String) throws -> AnalysisJobData?
    func list(status: AnalysisJobStatus?, includeCheckpoint: Bool) throws -> [AnalysisJobData]
    func latestTerminalCheckpoint(dedupeKey: String) throws -> [String: JSONValue]?
    func requestCancel(_ id: String) throws -> JobCancelOutcome
    func retry(_ id: String) throws -> Bool
    func recoverStale(leaseTimeoutMs: Int) throws -> Int
    func resumeInterrupted(types: [AnalysisJobType], maxAttempts: Int?) throws -> Int
    func claim(id: String, leaseOwner: String) throws -> Bool
    func heartbeat(id: String, leaseOwner: String) throws -> Bool
    func updateProgress(id: String, leaseOwner: String, update: JobProgressUpdate) throws -> Bool
    func finish(
        id: String,
        leaseOwner: String,
        status: AnalysisJobStatus,
        error: (code: String, message: String)?
    ) throws -> Bool
    func interrupt(id: String, leaseOwner: String, message: String) throws -> Bool
    func clearTerminal(statuses: [AnalysisJobStatus], excludeTypes: [AnalysisJobType]) throws -> Int
    /// WorkspaceStatus：最近一次 metadata.scan 行。
    func latestScanJob(sessionId: String) throws -> ScanJobRecord?
    /// WorkspaceStatus：scope=session 的失败 job（updated_at 倒序，limit）。
    func failedJobs(sessionId: String, limit: Int) throws -> [FailedJobRecord]
    /// WorkspaceStatus：成功 export.execute 的 checkpoint_json（最多 limit 条）。
    func successfulExportCheckpoints(sessionId: String, limit: Int) throws -> [String]
    /// SessionService：删除会话时清理无 FK 的 analysis_jobs 僵尸行。
    func deleteSessionJobs(sessionId: String) throws
}

public extension JobRepository {
    func create(_ params: JobCreateParams) throws -> AnalysisJobData {
        try create(params, inheritCheckpoint: true)
    }

    func list() throws -> [AnalysisJobData] {
        try list(status: nil, includeCheckpoint: true)
    }

    func list(status: AnalysisJobStatus?) throws -> [AnalysisJobData] {
        try list(status: status, includeCheckpoint: true)
    }

    func list(includeCheckpoint: Bool) throws -> [AnalysisJobData] {
        try list(status: nil, includeCheckpoint: includeCheckpoint)
    }

    func recoverStale() throws -> Int {
        try recoverStale(leaseTimeoutMs: 30_000)
    }

    func resumeInterrupted(types: [AnalysisJobType]) throws -> Int {
        try resumeInterrupted(types: types, maxAttempts: nil)
    }

    func finish(id: String, leaseOwner: String, status: AnalysisJobStatus) throws -> Bool {
        try finish(id: id, leaseOwner: leaseOwner, status: status, error: nil)
    }

    func interrupt(id: String, leaseOwner: String) throws -> Bool {
        try interrupt(
            id: id,
            leaseOwner: leaseOwner,
            message: "Application stopped during execution"
        )
    }

    func clearTerminal(statuses: [AnalysisJobStatus]) throws -> Int {
        try clearTerminal(statuses: statuses, excludeTypes: [])
    }
}

extension AnalysisJobRepo: JobRepository {}
