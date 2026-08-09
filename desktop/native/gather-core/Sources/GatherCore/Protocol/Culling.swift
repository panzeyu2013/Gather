// desktop/native/gather-core/Sources/GatherCore/Protocol/Culling.swift
// TS 源: packages/shared/src/protocol/culling.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 映射决策:
// - TS `CullingPage.nextRowId: number | null` 在 JSON 中 key 恒存在、值为 null；
//   Swift 用 Optional 表达，并通过自定义 encode 把 nil 编码为 null。
// - 跨域引用：photo: PhotoData（session.ts，GatherCore 已有）、
//   metadataSource: MetadataMutationSource（metadata.ts，GatherCore 已有）。

import Foundation

// TS: PickState
public enum PickState: String, Codable, CaseIterable, Equatable, Sendable {
    case unreviewed
    case picked
    case rejected
}

// TS: LegacyCullingDecision
public enum LegacyCullingDecision: String, Codable, CaseIterable, Equatable, Sendable {
    case keep
    case reject
    case pending
}

// TS: CullingDecisionSource
public enum CullingDecisionSource: String, Codable, CaseIterable, Equatable, Sendable {
    case manual
    case ai
    case template
    case imported
}

// TS: CaptureOneColorLabel
public enum CaptureOneColorLabel: String, Codable, CaseIterable, Equatable, Sendable {
    case none = "None"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case pink = "Pink"
    case purple = "Purple"
}

// TS: CullingScope
public enum CullingScope: String, Codable, CaseIterable, Equatable, Sendable {
    case all
    case filtered
    case similarityGroup = "similarity_group"
}

// TS: MetadataSyncStatus
public enum MetadataSyncStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case clean
    case pending
    case writing
    case written
    case failed
    case conflict
    case synced
    case cleaned
}

// TS: CullingFilters.qualityStatus（culling.ts 内联联合 'analysed' | 'unanalysed' | 'failed'）
public enum CullingFilterQualityStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case analysed
    case unanalysed
    case failed
}

// TS: CullingFilters
public struct CullingFilters: Codable, Equatable, Sendable {
    public var ratings: [Double]? // TS: ratings?
    public var pickStates: [PickState]? // TS: pickStates?
    public var colorLabels: [CaptureOneColorLabel]? // TS: colorLabels?
    public var unreviewedOnly: Bool? // TS: unreviewedOnly?
    public var qualityStatus: CullingFilterQualityStatus? // TS: qualityStatus?
    public var metadataConflictOnly: Bool? // TS: metadataConflictOnly?

    public init(
        ratings: [Double]? = nil,
        pickStates: [PickState]? = nil,
        colorLabels: [CaptureOneColorLabel]? = nil,
        unreviewedOnly: Bool? = nil,
        qualityStatus: CullingFilterQualityStatus? = nil,
        metadataConflictOnly: Bool? = nil
    ) {
        self.ratings = ratings
        self.pickStates = pickStates
        self.colorLabels = colorLabels
        self.unreviewedOnly = unreviewedOnly
        self.qualityStatus = qualityStatus
        self.metadataConflictOnly = metadataConflictOnly
    }
}

// TS: AssetCullingState
public struct AssetCullingState: Codable, Equatable, Sendable {
    public var photoId: String
    public var pickState: PickState
    public var rating: Double
    public var colorLabel: CaptureOneColorLabel
    public var source: CullingDecisionSource
    public var revision: Int
    public var updatedAt: String

    public init(photoId: String, pickState: PickState, rating: Double, colorLabel: CaptureOneColorLabel, source: CullingDecisionSource, revision: Int, updatedAt: String) {
        self.photoId = photoId
        self.pickState = pickState
        self.rating = rating
        self.colorLabel = colorLabel
        self.source = source
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

// TS: CullingAsset.quality.status（culling.ts 内联联合 'succeeded' | 'failed'）
public enum CullingQualityStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case succeeded
    case failed
}

// TS: CullingAsset.quality（内联匿名对象）
public struct CullingQuality: Codable, Equatable, Sendable {
    public var status: CullingQualityStatus
    public var score: Double
    public var sharpness: Double
    public var exposure: Double
    public var subjectSharpness: Double? // TS: subjectSharpness?
    public var closedEyeRisk: Double? // TS: closedEyeRisk?
    public var closedEyeProbability: Double? // TS: closedEyeProbability?
    public var confidence: Double? // TS: confidence?
    public var relativeRank: Double? // TS: relativeRank?
    public var errorMessage: String? // TS: errorMessage?
    public var warnings: [String]

    public init(
        status: CullingQualityStatus,
        score: Double,
        sharpness: Double,
        exposure: Double,
        subjectSharpness: Double? = nil,
        closedEyeRisk: Double? = nil,
        closedEyeProbability: Double? = nil,
        confidence: Double? = nil,
        relativeRank: Double? = nil,
        errorMessage: String? = nil,
        warnings: [String]
    ) {
        self.status = status
        self.score = score
        self.sharpness = sharpness
        self.exposure = exposure
        self.subjectSharpness = subjectSharpness
        self.closedEyeRisk = closedEyeRisk
        self.closedEyeProbability = closedEyeProbability
        self.confidence = confidence
        self.relativeRank = relativeRank
        self.errorMessage = errorMessage
        self.warnings = warnings
    }
}

// TS: CullingAsset —— photo: PhotoData（session.ts）、metadataSource: MetadataMutationSource（metadata.ts）
public struct CullingAsset: Codable, Equatable, Sendable {
    public var photo: PhotoData
    public var state: AssetCullingState
    public var xmpPath: String
    public var syncStatus: MetadataSyncStatus
    public var people: [String]
    public var keywords: [String]
    public var similarityGroupId: String? // TS: similarityGroupId?
    public var linkedVariantCount: Int
    public var faceBboxes: [[Double]] // TS: faceBboxes: number[][]
    public var quality: CullingQuality? // TS: quality?
    public var metadataSource: MetadataMutationSource? // TS: metadataSource?

    public init(
        photo: PhotoData,
        state: AssetCullingState,
        xmpPath: String,
        syncStatus: MetadataSyncStatus,
        people: [String],
        keywords: [String],
        similarityGroupId: String? = nil,
        linkedVariantCount: Int,
        faceBboxes: [[Double]],
        quality: CullingQuality? = nil,
        metadataSource: MetadataMutationSource? = nil
    ) {
        self.photo = photo
        self.state = state
        self.xmpPath = xmpPath
        self.syncStatus = syncStatus
        self.people = people
        self.keywords = keywords
        self.similarityGroupId = similarityGroupId
        self.linkedVariantCount = linkedVariantCount
        self.faceBboxes = faceBboxes
        self.quality = quality
        self.metadataSource = metadataSource
    }
}

// TS: CullingPage —— nextRowId: number | null，key 恒存在
public struct CullingPage: Codable, Equatable, Sendable {
    public var assets: [CullingAsset]
    public var nextRowId: Int? // TS: nextRowId: number | null
    public var total: Int

    public init(assets: [CullingAsset], nextRowId: Int? = nil, total: Int) {
        self.assets = assets
        self.nextRowId = nextRowId
        self.total = total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.assets = try container.decode([CullingAsset].self, forKey: .assets)
        self.nextRowId = try container.decodeIfPresent(Int.self, forKey: .nextRowId)
        self.total = try container.decode(Int.self, forKey: .total)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assets, forKey: .assets)
        if let nextRowId {
            try container.encode(nextRowId, forKey: .nextRowId)
        } else {
            try container.encodeNil(forKey: .nextRowId)
        }
        try container.encode(total, forKey: .total)
    }

    private enum CodingKeys: String, CodingKey {
        case assets, nextRowId, total
    }
}

// TS: CullingListPageParams
public struct CullingListPageParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var scope: CullingScope
    public var filters: CullingFilters? // TS: filters?
    public var groupId: String? // TS: groupId?
    public var afterRowId: Int? // TS: afterRowId?
    public var limit: Int? // TS: limit?

    public init(sessionId: String, scope: CullingScope, filters: CullingFilters? = nil, groupId: String? = nil, afterRowId: Int? = nil, limit: Int? = nil) {
        self.sessionId = sessionId
        self.scope = scope
        self.filters = filters
        self.groupId = groupId
        self.afterRowId = afterRowId
        self.limit = limit
    }
}

// TS: CullingUpdatePatch
public struct CullingUpdatePatch: Codable, Equatable, Sendable {
    public var rating: Double? // TS: rating?
    public var pickState: PickState? // TS: pickState?
    public var colorLabel: CaptureOneColorLabel? // TS: colorLabel?

    public init(rating: Double? = nil, pickState: PickState? = nil, colorLabel: CaptureOneColorLabel? = nil) {
        self.rating = rating
        self.pickState = pickState
        self.colorLabel = colorLabel
    }
}

// TS: CullingUpdateParams
public struct CullingUpdateParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoId: String
    public var expectedRevision: Int
    public var patch: CullingUpdatePatch

    public init(sessionId: String, photoId: String, expectedRevision: Int, patch: CullingUpdatePatch) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.expectedRevision = expectedRevision
        self.patch = patch
    }
}

// TS: CullingUpdateResult
public struct CullingUpdateResult: Codable, Equatable, Sendable {
    public var states: [AssetCullingState]
    public var xmpPath: String
    public var syncStatus: MetadataSyncStatus
    public var historyOperationId: Int? // TS: historyOperationId?

    public init(states: [AssetCullingState], xmpPath: String, syncStatus: MetadataSyncStatus, historyOperationId: Int? = nil) {
        self.states = states
        self.xmpPath = xmpPath
        self.syncStatus = syncStatus
        self.historyOperationId = historyOperationId
    }
}

// TS: CullingHistoryEntry.before/after —— Pick<AssetCullingState, 'pickState' | 'rating' | 'colorLabel'>
public struct CullingStateSnapshot: Codable, Equatable, Sendable {
    public var pickState: PickState
    public var rating: Double
    public var colorLabel: CaptureOneColorLabel

    public init(pickState: PickState, rating: Double, colorLabel: CaptureOneColorLabel) {
        self.pickState = pickState
        self.rating = rating
        self.colorLabel = colorLabel
    }
}

// TS: fields: Array<keyof CullingUpdatePatch> —— 'rating' | 'pickState' | 'colorLabel'
public enum CullingUpdatePatchField: String, Codable, CaseIterable, Equatable, Sendable {
    case rating
    case pickState
    case colorLabel
}

// TS: CullingHistoryEntry
public struct CullingHistoryEntry: Codable, Equatable, Sendable {
    public var photoId: String
    public var before: CullingStateSnapshot
    public var after: CullingStateSnapshot
    public var expectedRevision: Int
    public var fields: [CullingUpdatePatchField]

    public init(photoId: String, before: CullingStateSnapshot, after: CullingStateSnapshot, expectedRevision: Int, fields: [CullingUpdatePatchField]) {
        self.photoId = photoId
        self.before = before
        self.after = after
        self.expectedRevision = expectedRevision
        self.fields = fields
    }
}

// TS: CullingHistoryOperation
public struct CullingHistoryOperation: Codable, Equatable, Sendable {
    public var id: Int
    public var sessionId: String
    public var entries: [CullingHistoryEntry]
    public var undone: Bool
    public var createdAt: String

    public init(id: Int, sessionId: String, entries: [CullingHistoryEntry], undone: Bool, createdAt: String) {
        self.id = id
        self.sessionId = sessionId
        self.entries = entries
        self.undone = undone
        self.createdAt = createdAt
    }
}

// TS: CullingHistoryParams
public struct CullingHistoryParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var limit: Int? // TS: limit?

    public init(sessionId: String, limit: Int? = nil) {
        self.sessionId = sessionId
        self.limit = limit
    }
}

// TS: CullingHistoryApplyEntry
public struct CullingHistoryApplyEntry: Codable, Equatable, Sendable {
    public var photoId: String
    public var expectedRevision: Int
    public var patch: CullingUpdatePatch

    public init(photoId: String, expectedRevision: Int, patch: CullingUpdatePatch) {
        self.photoId = photoId
        self.expectedRevision = expectedRevision
        self.patch = patch
    }
}

// TS: CullingHistoryApplyParams.direction（culling.ts 内联联合 'undo' | 'redo'）
public enum CullingHistoryDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case undo
    case redo
}

// TS: CullingHistoryApplyParams
public struct CullingHistoryApplyParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var entries: [CullingHistoryApplyEntry]
    public var historyOperationId: Int
    public var direction: CullingHistoryDirection

    public init(sessionId: String, entries: [CullingHistoryApplyEntry], historyOperationId: Int, direction: CullingHistoryDirection) {
        self.sessionId = sessionId
        self.entries = entries
        self.historyOperationId = historyOperationId
        self.direction = direction
    }
}

// TS: CullingBatchUpdateParams
public struct CullingBatchUpdateParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]
    public var patch: CullingUpdatePatch

    public init(sessionId: String, photoIds: [String], patch: CullingUpdatePatch) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.patch = patch
    }
}

// TS: CullingDecideGroupParams
public struct CullingDecideGroupParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var groupId: String
    public var keepPhotoIds: [String]

    public init(sessionId: String, groupId: String, keepPhotoIds: [String]) {
        self.sessionId = sessionId
        self.groupId = groupId
        self.keepPhotoIds = keepPhotoIds
    }
}

// TS: CullingSyncStatusParams
public struct CullingSyncStatusParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: CullingFlushParams
public struct CullingFlushParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: CullingRetrySyncParams
public struct CullingRetrySyncParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: CullingFinalizeSyncParams
public struct CullingFinalizeSyncParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool

    public init(sessionId: String, confirmed: Bool) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: MetadataSyncItem
public struct MetadataSyncItem: Codable, Equatable, Sendable {
    public var xmpPath: String
    public var revision: Int
    public var persistedRevision: Int
    public var status: MetadataSyncStatus
    public var attemptCount: Int
    public var errorMessage: String
    public var updatedAt: String

    public init(xmpPath: String, revision: Int, persistedRevision: Int, status: MetadataSyncStatus, attemptCount: Int, errorMessage: String, updatedAt: String) {
        self.xmpPath = xmpPath
        self.revision = revision
        self.persistedRevision = persistedRevision
        self.status = status
        self.attemptCount = attemptCount
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

// TS: MetadataSyncSummary（core.ts Event 联合的 culling:sync-status 载荷）
public struct MetadataSyncSummary: Codable, Equatable, Sendable {
    public var sessionId: String
    public var pending: Int
    public var writing: Int
    public var written: Int
    public var failed: Int
    public var conflict: Int
    public var synced: Int
    public var items: [MetadataSyncItem]

    public init(sessionId: String, pending: Int, writing: Int, written: Int, failed: Int, conflict: Int, synced: Int, items: [MetadataSyncItem]) {
        self.sessionId = sessionId
        self.pending = pending
        self.writing = writing
        self.written = written
        self.failed = failed
        self.conflict = conflict
        self.synced = synced
        self.items = items
    }
}

// ── 旧版 Culling renderer 兼容契约（culling.ts 保留段）──

// TS: CullingGroupsParams
public struct CullingGroupsParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: CullingDecideParams
public struct CullingDecideParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoId: String
    public var decision: LegacyCullingDecision

    public init(sessionId: String, photoId: String, decision: LegacyCullingDecision) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.decision = decision
    }
}

// TS: CullingBatchDecideParams
public struct CullingBatchDecideParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]
    public var decision: LegacyCullingDecision

    public init(sessionId: String, photoIds: [String], decision: LegacyCullingDecision) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.decision = decision
    }
}

// TS: CullingSummaryParams
public struct CullingSummaryParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: CullingWritebackParams.target（culling.ts 内联联合 'rating' | 'color_label' | 'keyword'）
public enum CullingWritebackTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case rating
    case colorLabel = "color_label"
    case keyword
}

// TS: CullingWritebackParams
public struct CullingWritebackParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool
    public var target: CullingWritebackTarget

    public init(sessionId: String, confirmed: Bool, target: CullingWritebackTarget) {
        self.sessionId = sessionId
        self.confirmed = confirmed
        self.target = target
    }
}

// TS: CullingRetryWritebackParams
public struct CullingRetryWritebackParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool

    public init(sessionId: String, confirmed: Bool) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: CullingConfirmSyncParams
public struct CullingConfirmSyncParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: CullingCleanupParams
public struct CullingCleanupParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool

    public init(sessionId: String, confirmed: Bool) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: CullingResetParams
public struct CullingResetParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var groupId: String? // TS: groupId?
    public var confirmed: Bool

    public init(sessionId: String, groupId: String? = nil, confirmed: Bool) {
        self.sessionId = sessionId
        self.groupId = groupId
        self.confirmed = confirmed
    }
}

// TS: CullingGroup
public struct CullingGroup: Codable, Equatable, Sendable {
    public var groupId: String
    public var groupIndex: Int
    public var images: [CullingImage]
    public var keepCount: Int
    public var rejectCount: Int
    public var pendingCount: Int

    public init(groupId: String, groupIndex: Int, images: [CullingImage], keepCount: Int, rejectCount: Int, pendingCount: Int) {
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.images = images
        self.keepCount = keepCount
        self.rejectCount = rejectCount
        self.pendingCount = pendingCount
    }
}

// TS: CullingImage
public struct CullingImage: Codable, Equatable, Sendable {
    public var photoId: String
    public var filepath: String
    public var filename: String
    public var decision: LegacyCullingDecision

    public init(photoId: String, filepath: String, filename: String, decision: LegacyCullingDecision) {
        self.photoId = photoId
        self.filepath = filepath
        self.filename = filename
        self.decision = decision
    }
}

// TS: CullingSummary
public struct CullingSummary: Codable, Equatable, Sendable {
    public var totalGroups: Int
    public var totalPhotos: Int
    public var kept: Int
    public var rejected: Int
    public var pending: Int
    public var rated: Int
    public var labeled: Int

    public init(totalGroups: Int, totalPhotos: Int, kept: Int, rejected: Int, pending: Int, rated: Int, labeled: Int) {
        self.totalGroups = totalGroups
        self.totalPhotos = totalPhotos
        self.kept = kept
        self.rejected = rejected
        self.pending = pending
        self.rated = rated
        self.labeled = labeled
    }
}
