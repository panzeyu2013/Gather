// desktop/native/gather-core/Sources/GatherPersistence/Ports/FaceConstraintTypes.swift
// P0 / F0：人脸簇约束与复核成员的持久层 DTO。
//
// - 约束用 set-vs-set 表达（member/peer），键 = observationId + photoId + bbox；
// - 重推理会重建 face_observations，因此不能只存 observationId；
// - 复核成员行携带 embedding（Float32 blob）供 Application 计算 cohesion。
import Foundation
import GatherProtocol

public enum FaceClusterConstraintKind: String, Codable, Sendable, Equatable {
    case separate
    case together
}

public struct FaceClusterConstraintKey: Codable, Equatable, Sendable {
    public let observationId: Int64
    public let photoId: String
    public let bbox: [Double]

    public init(observationId: Int64, photoId: String, bbox: [Double]) {
        self.observationId = observationId
        self.photoId = photoId
        self.bbox = bbox
    }
}

public struct FaceClusterConstraintRow: Sendable, Equatable {
    public let id: Int64
    public let sessionId: String
    public let kind: FaceClusterConstraintKind
    public let memberKeys: [FaceClusterConstraintKey]
    public let peerKeys: [FaceClusterConstraintKey]
    public let createdAt: String

    public init(
        id: Int64, sessionId: String, kind: FaceClusterConstraintKind,
        memberKeys: [FaceClusterConstraintKey], peerKeys: [FaceClusterConstraintKey],
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.memberKeys = memberKeys
        self.peerKeys = peerKeys
        self.createdAt = createdAt
    }
}

public struct FaceClusterMemberRecord: Sendable, Equatable {
    public let id: Int64
    public let photoId: String
    public let bbox: [Double]
    public let confidence: Double
    public let observationId: Int64?

    public init(id: Int64, photoId: String, bbox: [Double], confidence: Double, observationId: Int64?) {
        self.id = id
        self.photoId = photoId
        self.bbox = bbox
        self.confidence = confidence
        self.observationId = observationId
    }
}

public struct FaceReviewMemberRow: Sendable, Equatable {
    public let clusterId: Int64
    public let clusterLabel: String
    public let memberId: Int64
    public let photoId: String
    public let photoPath: String
    public let bbox: [Double]
    public let confidence: Double
    public let observationId: Int64?
    public let embedding: [Float]
    public let quality: Double
    public let faceSizePx: Double
    public let modelId: String
    public let modelVersion: String

    public init(
        clusterId: Int64, clusterLabel: String, memberId: Int64, photoId: String,
        photoPath: String, bbox: [Double], confidence: Double, observationId: Int64?,
        embedding: [Float], quality: Double, faceSizePx: Double,
        modelId: String, modelVersion: String
    ) {
        self.clusterId = clusterId
        self.clusterLabel = clusterLabel
        self.memberId = memberId
        self.photoId = photoId
        self.photoPath = photoPath
        self.bbox = bbox
        self.confidence = confidence
        self.observationId = observationId
        self.embedding = embedding
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.modelId = modelId
        self.modelVersion = modelVersion
    }
}

public enum FaceConstraintCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode(_ keys: [FaceClusterConstraintKey]) throws -> String {
        let data = try encoder.encode(keys)
        return String(decoding: data, as: UTF8.self)
    }

    /// 畸形/非法键被剪除（不阻断分析）；空数组表示整条约束无有效键。
    public static func decode(_ raw: String) -> [FaceClusterConstraintKey] {
        guard let data = raw.data(using: .utf8),
              let keys = try? decoder.decode([FaceClusterConstraintKey].self, from: data)
        else { return [] }
        return keys.filter { key in
            key.observationId > 0
                && !key.photoId.isEmpty
                && key.bbox.count == 4
                && key.bbox.allSatisfy { $0.isFinite }
        }
    }
}

func decodeFaceFloatBlob(_ value: DBValue?) -> [Float] {
    guard case .blob(let data) = value, data.count >= MemoryLayout<Float>.size else { return [] }
    let count = data.count / MemoryLayout<Float>.size
    var floats = [Float](repeating: 0, count: count)
    _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return floats
}
