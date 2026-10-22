// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Jobs.swift
// TS 源: packages/shared/src/protocol/jobs.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: AnalysisJobType
public enum AnalysisJobType: String, Codable, CaseIterable, Equatable, Sendable {
    case metadataScan = "metadata.scan"
    case thumbnailBuild = "thumbnail.build"
    case similarityAnalyze = "similarity.analyze"
    case duplicateScan = "duplicate.scan"
    case faceAnalyze = "face.analyze"
    case qualityScore = "quality.score"
    case exportExecute = "export.execute"
    case checksumBackfill = "checksum.backfill"
}

// TS: AnalysisJobStatus
public enum AnalysisJobStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
    case cancelling
}

// TS: AnalysisJobData
public struct AnalysisJobData: Codable, Equatable, Sendable {
    public var id: String
    public var type: AnalysisJobType
    public var scopeType: String
    public var scopeId: String
    public var dedupeKey: String
    public var status: AnalysisJobStatus
    public var priority: Int
    public var progressCurrent: Int
    public var progressTotal: Int
    public var progressMessage: String
    public var inputFingerprint: String
    public var modelId: String
    public var modelVersion: String
    public var checkpoint: [String: JSONValue] // TS: checkpoint: Record<string, unknown>
    public var attemptCount: Int
    public var leaseOwner: String
    public var heartbeatAt: String
    public var errorCode: String
    public var errorMessage: String
    public var createdAt: String
    public var startedAt: String
    public var finishedAt: String
    public var updatedAt: String

    public init(
        id: String,
        type: AnalysisJobType,
        scopeType: String,
        scopeId: String,
        dedupeKey: String,
        status: AnalysisJobStatus,
        priority: Int,
        progressCurrent: Int,
        progressTotal: Int,
        progressMessage: String,
        inputFingerprint: String,
        modelId: String,
        modelVersion: String,
        checkpoint: [String: JSONValue],
        attemptCount: Int,
        leaseOwner: String,
        heartbeatAt: String,
        errorCode: String,
        errorMessage: String,
        createdAt: String,
        startedAt: String,
        finishedAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.type = type
        self.scopeType = scopeType
        self.scopeId = scopeId
        self.dedupeKey = dedupeKey
        self.status = status
        self.priority = priority
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
        self.progressMessage = progressMessage
        self.inputFingerprint = inputFingerprint
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.checkpoint = checkpoint
        self.attemptCount = attemptCount
        self.leaseOwner = leaseOwner
        self.heartbeatAt = heartbeatAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }
}

// TS: JobCreateParams
public struct JobCreateParams: Codable, Equatable, Sendable {
    public var type: AnalysisJobType
    public var scopeType: String
    public var scopeId: String
    public var dedupeKey: String
    public var priority: Int? // TS: priority?
    public var inputFingerprint: String? // TS: inputFingerprint?
    public var modelId: String? // TS: modelId?
    public var modelVersion: String? // TS: modelVersion?
    public var checkpoint: [String: JSONValue]? // TS: checkpoint?

    public init(
        type: AnalysisJobType,
        scopeType: String,
        scopeId: String,
        dedupeKey: String,
        priority: Int? = nil,
        inputFingerprint: String? = nil,
        modelId: String? = nil,
        modelVersion: String? = nil,
        checkpoint: [String: JSONValue]? = nil
    ) {
        self.type = type
        self.scopeType = scopeType
        self.scopeId = scopeId
        self.dedupeKey = dedupeKey
        self.priority = priority
        self.inputFingerprint = inputFingerprint
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.checkpoint = checkpoint
    }
}

// TS: JobProgressUpdate
public struct JobProgressUpdate: Codable, Equatable, Sendable {
    public var current: Int? // TS: current?
    public var total: Int? // TS: total?
    public var phase: String? // TS: phase?
    public var message: String? // TS: message?
    public var checkpoint: [String: JSONValue]? // TS: checkpoint?

    public init(current: Int? = nil, total: Int? = nil, phase: String? = nil, message: String? = nil, checkpoint: [String: JSONValue]? = nil) {
        self.current = current
        self.total = total
        self.phase = phase
        self.message = message
        self.checkpoint = checkpoint
    }
}
