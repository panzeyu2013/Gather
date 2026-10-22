// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Workspace.swift
// TS 源: packages/shared/src/protocol/workspace.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 映射决策:
// - TS `recommendedNext: WorkspaceRecommendedNext | null` 在 JSON 中 key 恒存在、
//   值为 null；Swift 用 Optional 表达，并通过自定义 encode 把 nil 编码为 null。

import Foundation

// TS: WorkspaceStage
public enum WorkspaceStage: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case imported
    case indexed
    case analyzed
}

// TS: WorkspaceIndexingProgress.status（workspace.ts 内联联合 'idle' | 'active' | 'failed'）
public enum WorkspaceIndexingStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case active
    case failed
}

// TS: WorkspaceIndexingProgress
public struct WorkspaceIndexingProgress: Codable, Equatable, Sendable {
    public var total: Int
    public var done: Int
    public var percent: Double
    public var status: WorkspaceIndexingStatus

    public init(total: Int, done: Int, percent: Double, status: WorkspaceIndexingStatus) {
        self.total = total
        self.done = done
        self.percent = percent
        self.status = status
    }
}

// TS: WorkspaceStaleAnalysis.kind（workspace.ts 内联联合 'similarity' | 'face'）
public enum WorkspaceStaleAnalysisKind: String, Codable, CaseIterable, Equatable, Sendable {
    case similarity
    case face
}

// TS: WorkspaceStaleAnalysis
public struct WorkspaceStaleAnalysis: Codable, Equatable, Sendable {
    public var kind: WorkspaceStaleAnalysisKind
    public var lastRunAt: String

    public init(kind: WorkspaceStaleAnalysisKind, lastRunAt: String) {
        self.kind = kind
        self.lastRunAt = lastRunAt
    }
}

// TS: WorkspaceXmpCounts
public struct WorkspaceXmpCounts: Codable, Equatable, Sendable {
    public var pending: Int
    public var conflict: Int

    public init(pending: Int, conflict: Int) {
        self.pending = pending
        self.conflict = conflict
    }
}

// TS: WorkspaceFailedJob
public struct WorkspaceFailedJob: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var code: String
    public var message: String

    public init(id: String, type: String, code: String, message: String) {
        self.id = id
        self.type = type
        self.code = code
        self.message = message
    }
}

// TS: WorkspaceRecommendedNext
public struct WorkspaceRecommendedNext: Codable, Equatable, Sendable {
    public var action: String
    public var target: String

    public init(action: String, target: String) {
        self.action = action
        self.target = target
    }
}

// TS: WorkspaceStatus.softFlags（内联匿名对象）
public struct WorkspaceSoftFlags: Codable, Equatable, Sendable {
    public var culled: Bool
    public var exported: Bool

    public init(culled: Bool, exported: Bool) {
        self.culled = culled
        self.exported = exported
    }
}

// TS: WorkspaceStatus —— recommendedNext: WorkspaceRecommendedNext | null，key 恒存在
public struct WorkspaceStatus: Codable, Equatable, Sendable {
    public var sessionId: String
    public var stage: WorkspaceStage
    public var softFlags: WorkspaceSoftFlags
    public var indexing: WorkspaceIndexingProgress
    public var staleAnalyses: [WorkspaceStaleAnalysis]
    public var xmp: WorkspaceXmpCounts
    public var offlinePhotos: Int
    public var failedJobs: [WorkspaceFailedJob]
    public var recommendedNext: WorkspaceRecommendedNext? // TS: recommendedNext: WorkspaceRecommendedNext | null
    public var generatedAt: String

    public init(
        sessionId: String,
        stage: WorkspaceStage,
        softFlags: WorkspaceSoftFlags,
        indexing: WorkspaceIndexingProgress,
        staleAnalyses: [WorkspaceStaleAnalysis],
        xmp: WorkspaceXmpCounts,
        offlinePhotos: Int,
        failedJobs: [WorkspaceFailedJob],
        recommendedNext: WorkspaceRecommendedNext? = nil,
        generatedAt: String
    ) {
        self.sessionId = sessionId
        self.stage = stage
        self.softFlags = softFlags
        self.indexing = indexing
        self.staleAnalyses = staleAnalyses
        self.xmp = xmp
        self.offlinePhotos = offlinePhotos
        self.failedJobs = failedJobs
        self.recommendedNext = recommendedNext
        self.generatedAt = generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.stage = try container.decode(WorkspaceStage.self, forKey: .stage)
        self.softFlags = try container.decode(WorkspaceSoftFlags.self, forKey: .softFlags)
        self.indexing = try container.decode(WorkspaceIndexingProgress.self, forKey: .indexing)
        self.staleAnalyses = try container.decode([WorkspaceStaleAnalysis].self, forKey: .staleAnalyses)
        self.xmp = try container.decode(WorkspaceXmpCounts.self, forKey: .xmp)
        self.offlinePhotos = try container.decode(Int.self, forKey: .offlinePhotos)
        self.failedJobs = try container.decode([WorkspaceFailedJob].self, forKey: .failedJobs)
        self.recommendedNext = try container.decodeIfPresent(WorkspaceRecommendedNext.self, forKey: .recommendedNext)
        self.generatedAt = try container.decode(String.self, forKey: .generatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(stage, forKey: .stage)
        try container.encode(softFlags, forKey: .softFlags)
        try container.encode(indexing, forKey: .indexing)
        try container.encode(staleAnalyses, forKey: .staleAnalyses)
        try container.encode(xmp, forKey: .xmp)
        try container.encode(offlinePhotos, forKey: .offlinePhotos)
        try container.encode(failedJobs, forKey: .failedJobs)
        if let recommendedNext {
            try container.encode(recommendedNext, forKey: .recommendedNext)
        } else {
            try container.encodeNil(forKey: .recommendedNext)
        }
        try container.encode(generatedAt, forKey: .generatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, stage, softFlags, indexing, staleAnalyses, xmp, offlinePhotos, failedJobs, recommendedNext, generatedAt
    }
}

// TS: WorkspaceStatusParams
public struct WorkspaceStatusParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
