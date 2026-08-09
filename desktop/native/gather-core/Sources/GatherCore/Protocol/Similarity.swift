// desktop/native/gather-core/Sources/GatherCore/Protocol/Similarity.swift
// TS 源: packages/shared/src/protocol/similarity.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: SimilarityGroupingMode
public enum SimilarityGroupingMode: String, Codable, CaseIterable, Equatable, Sendable {
    case sequential
    case global
}

// TS: SimAnalyzeParams
public struct SimAnalyzeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var threshold: Double? // TS: threshold?
    public var minGroupSize: Int? // TS: minGroupSize?
    public var groupingMode: SimilarityGroupingMode? // TS: groupingMode?

    public init(sessionId: String, threshold: Double? = nil, minGroupSize: Int? = nil, groupingMode: SimilarityGroupingMode? = nil) {
        self.sessionId = sessionId
        self.threshold = threshold
        self.minGroupSize = minGroupSize
        self.groupingMode = groupingMode
    }
}

// TS: SimCancelAnalysisParams
public struct SimCancelAnalysisParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: SimResultParams
public struct SimResultParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var threshold: Double? // TS: threshold?

    public init(sessionId: String, threshold: Double? = nil) {
        self.sessionId = sessionId
        self.threshold = threshold
    }
}

// TS: SimReclusterParams
public struct SimReclusterParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var threshold: Double? // TS: threshold?
    public var minGroupSize: Int? // TS: minGroupSize?
    public var groupingMode: SimilarityGroupingMode? // TS: groupingMode?

    public init(sessionId: String, threshold: Double? = nil, minGroupSize: Int? = nil, groupingMode: SimilarityGroupingMode? = nil) {
        self.sessionId = sessionId
        self.threshold = threshold
        self.minGroupSize = minGroupSize
        self.groupingMode = groupingMode
    }
}

// TS: SimilarityKeywordAssignment
public struct SimilarityKeywordAssignment: Codable, Equatable, Sendable {
    public var groupId: Int
    public var keywords: [String]

    public init(groupId: Int, keywords: [String]) {
        self.groupId = groupId
        self.keywords = keywords
    }
}

// TS: SimPreviewWritebackParams
public struct SimPreviewWritebackParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var assignments: [SimilarityKeywordAssignment]
    public var threshold: Double? // TS: threshold?

    public init(sessionId: String, assignments: [SimilarityKeywordAssignment], threshold: Double? = nil) {
        self.sessionId = sessionId
        self.assignments = assignments
        self.threshold = threshold
    }
}

// TS: SimWritebackParams
public struct SimWritebackParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var itemIds: [Int]
    public var confirmed: Bool
    public var threshold: Double? // TS: threshold?

    public init(sessionId: String, itemIds: [Int], confirmed: Bool, threshold: Double? = nil) {
        self.sessionId = sessionId
        self.itemIds = itemIds
        self.confirmed = confirmed
        self.threshold = threshold
    }
}

// TS: SimWritebackItemsParams
public struct SimWritebackItemsParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: SimRetryFailedWritebackParams
public struct SimRetryFailedWritebackParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool

    public init(sessionId: String, confirmed: Bool) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: SimConfirmSyncParams
public struct SimConfirmSyncParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: SimCleanupParams
public struct SimCleanupParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool

    public init(sessionId: String, confirmed: Bool) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: SimilarityImage
public struct SimilarityImage: Codable, Equatable, Sendable {
    public var path: String
    public var representative: Bool? // TS: representative?

    public init(path: String, representative: Bool? = nil) {
        self.path = path
        self.representative = representative
    }
}

// TS: SimilarityGroup
public struct SimilarityGroup: Codable, Equatable, Sendable {
    public var id: Int
    public var label: String
    public var count: Int
    public var images: [SimilarityImage]
    public var thumbnailBase64: String? // TS: thumbnailBase64?

    public init(id: Int, label: String, count: Int, images: [SimilarityImage], thumbnailBase64: String? = nil) {
        self.id = id
        self.label = label
        self.count = count
        self.images = images
        self.thumbnailBase64 = thumbnailBase64
    }
}

// TS: SimilarityResultStats
public struct SimilarityResultStats: Codable, Equatable, Sendable {
    public var totalGroups: Int
    public var totalUngrouped: Int
    public var threshold: Double
    public var minGroupSize: Int
    public var groupingMode: SimilarityGroupingMode
    public var precomputed: Bool? // TS: precomputed?

    public init(totalGroups: Int, totalUngrouped: Int, threshold: Double, minGroupSize: Int, groupingMode: SimilarityGroupingMode, precomputed: Bool? = nil) {
        self.totalGroups = totalGroups
        self.totalUngrouped = totalUngrouped
        self.threshold = threshold
        self.minGroupSize = minGroupSize
        self.groupingMode = groupingMode
        self.precomputed = precomputed
    }
}
