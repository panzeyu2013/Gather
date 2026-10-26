// desktop/native/gather-core/Sources/GatherProtocol/Protocol/FaceReview.swift
// P0 / F0：人脸拆分与复核的契约类型（纯值）。
//
// 语义冻结见 docs/design/p0/f0-face-split.md §7 与 x0-contracts §1.4。
// - 拆分 v1 仅未绑定簇；绑定簇由服务层拒绝；
// - review 的游标是服务端不透明字符串（v1:<cohesion>:<memberId>），非法即
//   FACE_REVIEW_CURSOR_INVALID；
// - cohesion：未解析 = -1；n<=3 为两两最小值；n>=4 为到质心的 cosine。
import Foundation

public struct FaceSplitInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int
    public let memberIds: [Int]

    public init(sessionId: String, clusterId: Int, memberIds: [Int]) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        guard clusterId >= 0 else {
            throw GatherError.invalidParameter(field: "clusterId", reason: "must be >= 0")
        }
        _ = try APIValidation.nonEmpty(memberIds, field: "memberIds", maxCount: 10_000)
        for (index, id) in memberIds.enumerated() where id <= 0 {
            throw GatherError.invalidParameter(field: "memberIds[\(index)]", reason: "must be positive")
        }
        self.clusterId = clusterId
        self.memberIds = memberIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            clusterId: try container.decode(Int.self, forKey: .clusterId),
            memberIds: try container.decode([Int].self, forKey: .memberIds)
        )
    }

    private enum CodingKeys: String, CodingKey { case sessionId, clusterId, memberIds }
}

public struct FaceSplitResult: Codable, Equatable, Sendable {
    public let newClusterId: Int
    public let movedCount: Int
    public let remainingCount: Int
    public let label: String

    public init(newClusterId: Int, movedCount: Int, remainingCount: Int, label: String) {
        self.newClusterId = newClusterId
        self.movedCount = movedCount
        self.remainingCount = remainingCount
        self.label = label
    }
}

public struct FaceReviewInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int?
    public let cursor: Int?
    public let limit: Int
    public let includeResolved: Bool

    public init(
        sessionId: String,
        clusterId: Int? = nil,
        cursor: Int? = nil,
        limit: Int? = nil,
        includeResolved: Bool = false
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let clusterId, clusterId < 0 {
            throw GatherError.invalidParameter(field: "clusterId", reason: "must be >= 0")
        }
        if let cursor, cursor < 1 {
            throw GatherError.invalidParameter(field: "cursor", reason: "must be a positive member id")
        }
        self.clusterId = clusterId
        self.cursor = cursor
        self.limit = try APIValidation.integerInRange(limit ?? 50, field: "limit", 1...200)
        self.includeResolved = includeResolved
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            clusterId: try container.decodeIfPresent(Int.self, forKey: .clusterId),
            cursor: try container.decodeIfPresent(Int.self, forKey: .cursor),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            includeResolved: try container.decodeIfPresent(Bool.self, forKey: .includeResolved) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey { case sessionId, clusterId, cursor, limit, includeResolved }
}

public enum FaceReviewFlag: String, Codable, CaseIterable, Equatable, Sendable {
    case suspect
    case lowQuality = "low_quality"
    case smallFace = "small_face"
    case unresolvedObservation = "unresolved_observation"
    case incompatibleModel = "incompatible_model"
}

public struct FaceReviewItem: Codable, Equatable, Sendable {
    public let clusterId: Int
    public let clusterLabel: String
    public let memberId: Int
    public let photoId: String
    public let photoPath: String
    public let filename: String
    public let bbox: [Double]
    public let confidence: Double
    public let quality: Double
    public let faceSizePx: Double
    /// 未解析 = -1；n<=3 时为两两最小值；n>=4 时为到质心 cosine。
    public let cohesion: Double
    public let flags: [FaceReviewFlag]

    public init(
        clusterId: Int, clusterLabel: String, memberId: Int, photoId: String,
        photoPath: String, filename: String, bbox: [Double], confidence: Double,
        quality: Double, faceSizePx: Double, cohesion: Double, flags: [FaceReviewFlag]
    ) {
        self.clusterId = clusterId
        self.clusterLabel = clusterLabel
        self.memberId = memberId
        self.photoId = photoId
        self.photoPath = photoPath
        self.filename = filename
        self.bbox = bbox
        self.confidence = confidence
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.cohesion = cohesion
        self.flags = flags
    }
}

public struct FaceReviewClusterSummary: Codable, Equatable, Sendable {
    public let clusterId: Int
    public let label: String
    public let size: Int
    public let suspectCount: Int
    public let reviewCount: Int
    public let cohesion: Double?

    public init(clusterId: Int, label: String, size: Int, suspectCount: Int, reviewCount: Int, cohesion: Double?) {
        self.clusterId = clusterId
        self.label = label
        self.size = size
        self.suspectCount = suspectCount
        self.reviewCount = reviewCount
        self.cohesion = cohesion
    }
}

public struct FaceReviewPage: Codable, Equatable, Sendable {
    public let items: [FaceReviewItem]
    public let nextCursor: Int?
    public let total: Int
    public let suspectTotal: Int
    public let clusters: [FaceReviewClusterSummary]

    public init(items: [FaceReviewItem], nextCursor: Int?, total: Int, suspectTotal: Int, clusters: [FaceReviewClusterSummary]) {
        self.items = items
        self.nextCursor = nextCursor
        self.total = total
        self.suspectTotal = suspectTotal
        self.clusters = clusters
    }
}
