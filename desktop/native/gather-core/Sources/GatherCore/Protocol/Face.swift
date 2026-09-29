// desktop/native/gather-core/Sources/GatherCore/Protocol/Face.swift
// TS 源: packages/shared/src/protocol/face.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 说明: face.ts import type { WritebackOptions, WritebackItem } from './core'；
// 这两个 core.ts 类型位于 Core.swift（Writeback* 区块），此处直接引用。

import Foundation

// TS: FkwAnalyzeParams
public struct FkwAnalyzeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    /// TS: eps? —— **人脸相似度下限**（不是半径）：仅 cosine 相似度
    /// >= eps 的两张脸视为同簇，因此 eps 越大越严格。实现与默认值见
    /// Face/Clusterer.swift 的文件头「相似度阈值语义」（default 0.6，域 0...1）。
    public var eps: Double?
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
