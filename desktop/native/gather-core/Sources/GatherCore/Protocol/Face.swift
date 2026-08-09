// desktop/native/gather-core/Sources/GatherCore/Protocol/Face.swift
// TS 源: packages/shared/src/protocol/face.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 说明: face.ts import type { WritebackOptions, WritebackItem } from './core'；
// Core.swift 尚未包含这两个 core.ts 类型，且本任务不得改动已有文件，
// 故按 core.ts 的最终 JSON 形状落地于此（见文件尾部 Writeback* 区块）。

import Foundation

// TS: FkwAnalyzeParams
public struct FkwAnalyzeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var eps: Double? // TS: eps?
    public var minSamples: Int? // TS: minSamples?
    public var detectorPath: String? // TS: detectorPath?
    public var encoderPath: String? // TS: encoderPath?

    public init(sessionId: String, eps: Double? = nil, minSamples: Int? = nil, detectorPath: String? = nil, encoderPath: String? = nil) {
        self.sessionId = sessionId
        self.eps = eps
        self.minSamples = minSamples
        self.detectorPath = detectorPath
        self.encoderPath = encoderPath
    }
}

// TS: FkwCancelAnalysisParams
public struct FkwCancelAnalysisParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: FkwClustersParams
public struct FkwClustersParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// TS: FkwBindParams
public struct FkwBindParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var clusterId: Int
    public var roleName: String
    public var keywords: [String]

    public init(sessionId: String, clusterId: Int, roleName: String, keywords: [String]) {
        self.sessionId = sessionId
        self.clusterId = clusterId
        self.roleName = roleName
        self.keywords = keywords
    }
}

// TS: FkwUnbindParams
public struct FkwUnbindParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var clusterId: Int
    public var confirmed: Bool

    public init(sessionId: String, clusterId: Int, confirmed: Bool) {
        self.sessionId = sessionId
        self.clusterId = clusterId
        self.confirmed = confirmed
    }
}

// TS: FkwMergeParams
public struct FkwMergeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var source: Int
    public var target: Int

    public init(sessionId: String, source: Int, target: Int) {
        self.sessionId = sessionId
        self.source = source
        self.target = target
    }
}

// TS: FkwRemoveMemberParams
public struct FkwRemoveMemberParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var clusterId: Int
    public var memberId: Int

    public init(sessionId: String, clusterId: Int, memberId: Int) {
        self.sessionId = sessionId
        self.clusterId = clusterId
        self.memberId = memberId
    }
}

// TS: FkwPreviewParams
public struct FkwPreviewParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var options: WritebackOptions? // TS: options?: WritebackOptions

    public init(sessionId: String, options: WritebackOptions? = nil) {
        self.sessionId = sessionId
        self.options = options
    }
}

// TS: FkwWritebackParams
public struct FkwWritebackParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool? // TS: confirmed?
    public var items: [WritebackItem]? // TS: items?: WritebackItem[]

    public init(sessionId: String, confirmed: Bool? = nil, items: [WritebackItem]? = nil) {
        self.sessionId = sessionId
        self.confirmed = confirmed
        self.items = items
    }
}

// TS: FkwConfirmSyncParams
public struct FkwConfirmSyncParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool? // TS: confirmed?

    public init(sessionId: String, confirmed: Bool? = nil) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: FkwConfirmCleanupParams
public struct FkwConfirmCleanupParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool? // TS: confirmed?

    public init(sessionId: String, confirmed: Bool? = nil) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: FkwCleanupParams
public struct FkwCleanupParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var confirmed: Bool? // TS: confirmed?

    public init(sessionId: String, confirmed: Bool? = nil) {
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: FaceModelsStatusData
public struct FaceModelsStatusData: Codable, Equatable, Sendable {
    public var detectorPresent: Bool
    public var encoderPresent: Bool
    public var detectorPath: String
    public var encoderPath: String

    public init(detectorPresent: Bool, encoderPresent: Bool, detectorPath: String, encoderPath: String) {
        self.detectorPresent = detectorPresent
        self.encoderPresent = encoderPresent
        self.detectorPath = detectorPath
        self.encoderPath = encoderPath
    }
}

// TS: FaceObservation
public struct FaceObservation: Codable, Equatable, Sendable {
    public var id: Int? // TS: id?
    public var photoId: String
    public var sessionId: String
    public var bboxX: Double
    public var bboxY: Double
    public var bboxW: Double
    public var bboxH: Double
    public var embedding: [Double]
    public var confidence: Double

    public init(id: Int? = nil, photoId: String, sessionId: String, bboxX: Double, bboxY: Double, bboxW: Double, bboxH: Double, embedding: [Double], confidence: Double) {
        self.id = id
        self.photoId = photoId
        self.sessionId = sessionId
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxW = bboxW
        self.bboxH = bboxH
        self.embedding = embedding
        self.confidence = confidence
    }
}

// TS: ClusterMember
public struct ClusterMember: Codable, Equatable, Sendable {
    public var memberId: Int
    public var photoId: String
    public var photoPath: String
    public var filename: String
    public var bbox: [Double]
    public var confidence: Double

    public init(memberId: Int, photoId: String, photoPath: String, filename: String, bbox: [Double], confidence: Double) {
        self.memberId = memberId
        self.photoId = photoId
        self.photoPath = photoPath
        self.filename = filename
        self.bbox = bbox
        self.confidence = confidence
    }
}

// TS: BindingData
public struct BindingData: Codable, Equatable, Sendable {
    public var clusterId: Int
    public var roleName: String
    public var keywords: [String]
    public var notes: String? // TS: notes?

    public init(clusterId: Int, roleName: String, keywords: [String], notes: String? = nil) {
        self.clusterId = clusterId
        self.roleName = roleName
        self.keywords = keywords
        self.notes = notes
    }
}

// TS: FaceCluster
public struct FaceCluster: Codable, Equatable, Sendable {
    public var id: Int
    public var sessionId: String
    public var label: String
    public var size: Int
    public var members: [ClusterMember]
    public var status: String
    public var binding: BindingData? // TS: binding?
    public var thumbnailBase64: String? // TS: thumbnailBase64?
    public var syncedToLibrary: Bool? // TS: syncedToLibrary?
    public var matchedPersonId: String? // TS: matchedPersonId?
    public var matchConfidence: Double? // TS: matchConfidence?

    public init(
        id: Int,
        sessionId: String,
        label: String,
        size: Int,
        members: [ClusterMember],
        status: String,
        binding: BindingData? = nil,
        thumbnailBase64: String? = nil,
        syncedToLibrary: Bool? = nil,
        matchedPersonId: String? = nil,
        matchConfidence: Double? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.label = label
        self.size = size
        self.members = members
        self.status = status
        self.binding = binding
        self.thumbnailBase64 = thumbnailBase64
        self.syncedToLibrary = syncedToLibrary
        self.matchedPersonId = matchedPersonId
        self.matchConfidence = matchConfidence
    }
}

// ── core.ts 依赖（face.ts 引用，Core.swift 未包含，按 JSON 形状落地于此）──

// TS: WritebackOptions（core.ts）—— FkwPreviewParams.options
public struct WritebackOptions: Codable, Equatable, Sendable {
    public var createAlbums: Bool? // TS: createAlbums?
    public var addPrefix: Bool? // TS: addPrefix?
    public var markUngrouped: Bool? // TS: markUngrouped?
    public var writeIPTC: Bool? // TS: writeIPTC?

    public init(createAlbums: Bool? = nil, addPrefix: Bool? = nil, markUngrouped: Bool? = nil, writeIPTC: Bool? = nil) {
        self.createAlbums = createAlbums
        self.addPrefix = addPrefix
        self.markUngrouped = markUngrouped
        self.writeIPTC = writeIPTC
    }
}

// TS: WritebackAttributes（core.ts）
public struct WritebackAttributes: Codable, Equatable, Sendable {
    public var keywords: [String]? // TS: keywords?
    public var rating: Double? // TS: rating?
    public var label: String? // TS: label?

    public init(keywords: [String]? = nil, rating: Double? = nil, label: String? = nil) {
        self.keywords = keywords
        self.rating = rating
        self.label = label
    }
}

// TS: WritebackItem.preview.dirtyFields（core.ts 内联联合 'rating' | 'label' | 'keywords'）
public enum WritebackDirtyField: String, Codable, CaseIterable, Equatable, Sendable {
    case rating
    case label
    case keywords
}

// TS: WritebackItem.preview（core.ts 内联匿名对象）
public struct WritebackItemPreview: Codable, Equatable, Sendable {
    public var dirtyFields: [WritebackDirtyField]
    public var before: WritebackAttributes
    public var after: WritebackAttributes
    public var source: String
    public var sharedPhotoCount: Int
    public var externalChanged: Bool
    public var willCreate: Bool

    public init(dirtyFields: [WritebackDirtyField], before: WritebackAttributes, after: WritebackAttributes, source: String, sharedPhotoCount: Int, externalChanged: Bool, willCreate: Bool) {
        self.dirtyFields = dirtyFields
        self.before = before
        self.after = after
        self.source = source
        self.sharedPhotoCount = sharedPhotoCount
        self.externalChanged = externalChanged
        self.willCreate = willCreate
    }
}

// TS: WritebackItem（core.ts）—— FkwWritebackParams.items
public struct WritebackItem: Codable, Equatable, Sendable {
    public var id: Int? // TS: id?
    public var photoId: String
    public var photoPath: String
    public var sessionId: String
    public var module: String
    public var keywords: [String]
    public var attributes: WritebackAttributes? // TS: attributes?
    public var xmpPath: String
    public var backupPath: String
    public var xmpStatus: String
    public var errorMessage: String
    public var attemptCount: Int
    public var lastAttemptAt: String
    public var preview: WritebackItemPreview? // TS: preview?

    public init(
        id: Int? = nil,
        photoId: String,
        photoPath: String,
        sessionId: String,
        module: String,
        keywords: [String],
        attributes: WritebackAttributes? = nil,
        xmpPath: String,
        backupPath: String,
        xmpStatus: String,
        errorMessage: String,
        attemptCount: Int,
        lastAttemptAt: String,
        preview: WritebackItemPreview? = nil
    ) {
        self.id = id
        self.photoId = photoId
        self.photoPath = photoPath
        self.sessionId = sessionId
        self.module = module
        self.keywords = keywords
        self.attributes = attributes
        self.xmpPath = xmpPath
        self.backupPath = backupPath
        self.xmpStatus = xmpStatus
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.preview = preview
    }
}
