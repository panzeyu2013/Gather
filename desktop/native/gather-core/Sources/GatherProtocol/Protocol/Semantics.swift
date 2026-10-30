// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Semantics.swift
// P1 下一波 §3.11.3：语义检索的 IPC 快照（图搜图 / 标签检索）。
//
// 应用层 SemanticIndex 返回更细的 SemanticSearchOutcome；LivePhotoAPI 在这里
// 映射成可编码快照，UI/命令面不依赖 GatherApplication。

import Foundation

public struct SemanticSearchQuery: Codable, Equatable, Sendable {
    public var sessionId: String
    /// 非 nil = 以该照片的特征向量做"相似照片"；nil = 按 labels 检索。
    public var photoId: String?
    /// 标签检索词（photoId 非 nil 时忽略；空 = INVALID_PARAM 语义，返回空结果）。
    public var labels: [String]
    public var limit: Int
    /// 图搜图余弦下限（0…1）；标签检索忽略。
    public var minSimilarity: Double

    public init(
        sessionId: String,
        photoId: String? = nil,
        labels: [String] = [],
        limit: Int = 50,
        minSimilarity: Double = 0.6
    ) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.labels = labels
        self.limit = limit
        self.minSimilarity = minSimilarity
    }
}

public struct SemanticSearchHitSnapshot: Codable, Equatable, Sendable {
    public var photoId: String
    /// 图搜图余弦；标签检索为 nil（不用 Jaccard 冒充）。
    public var similarity: Double?
    /// 标签名（按置信度降序）。
    public var labels: [String]
    public var matchedLabels: [String]

    public init(
        photoId: String,
        similarity: Double?,
        labels: [String],
        matchedLabels: [String]
    ) {
        self.photoId = photoId
        self.similarity = similarity
        self.labels = labels
        self.matchedLabels = matchedLabels
    }
}

public struct SemanticSearchOutcomeSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    /// "featurePrint" / "labels"。
    public var method: String
    public var hits: [SemanticSearchHitSnapshot]
    public var scanned: Int
    public var skipped: Int
    /// 索引未建立/维度不符等原因；hits 为空时给 UI 显示，不是错误。
    public var unavailableReason: String?

    public init(
        sessionId: String,
        method: String,
        hits: [SemanticSearchHitSnapshot],
        scanned: Int,
        skipped: Int,
        unavailableReason: String? = nil
    ) {
        self.sessionId = sessionId
        self.method = method
        self.hits = hits
        self.scanned = scanned
        self.skipped = skipped
        self.unavailableReason = unavailableReason
    }
}
