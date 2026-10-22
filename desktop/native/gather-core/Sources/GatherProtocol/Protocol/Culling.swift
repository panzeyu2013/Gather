// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Culling.swift
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

/// `culling.decide` / `culling.batch_decide` 的 **decision 字段取值**（线上契约，
/// raw 值 keep/reject/pending 不可改）。TS 侧曾名 LegacyCullingDecision，原生侧改名为
/// 事实描述：它是这两个命令的载荷值类型，不是"旧实现"。
public enum CullingDecisionValue: String, Codable, CaseIterable, Equatable, Sendable {
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
    /// TS: metadataConflictOnly?。
    /// 服务端已下推 SQL（判定规则：首选变体的 photo_path 存在 status='conflict'
    /// 的 outbox 行），JS 安全网用同一规则，故 filtered 范围的 total 与页内容同口径。
    public var metadataConflictOnly: Bool?

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
//
// 真相源（挑片域，禁止双真相源）：
// - pickState ← culling_decisions.decision（取舍唯一拥有者）；
// - rating / colorLabel ← photo_metadata_cache（全应用 XMP 投影，唯一真相源）；
//   culling_decisions.rating / color_label 是同事务写下的镜像列，任何读取路径
//   都不得读它们（见 CullingDecisionRepo 文件头注）。
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

// TS: CullingHistoryDirection（culling.ts 内联联合 'undo' | 'redo'）
public enum CullingHistoryDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case undo
    case redo
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

// TS: CullingWritebackTarget（culling.ts 内联联合 'rating' | 'color_label' | 'keyword'）
public enum CullingWritebackTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case rating
    case colorLabel = "color_label"
    case keyword
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
    public var decision: CullingDecisionValue

    public init(photoId: String, filepath: String, filename: String, decision: CullingDecisionValue) {
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
