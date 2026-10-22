// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Similarity.swift
// TS 源: packages/shared/src/protocol/similarity.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: SimilarityGroupingMode
public enum SimilarityGroupingMode: String, Codable, CaseIterable, Equatable, Sendable {
    case sequential
    case global
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

// 可落库的增量聚类状态（原声明在 Similarity/IncrementalClusterer.swift）。
// Cut 3 / 3a：Persistence 的 SimilarityClusterStateRepo 需要还原/写入该状态，
// 而 Persistence 不得依赖 Analysis；状态本身是纯值类型，故下移到 Protocol。
// - components：全图连通分量（含未成组的次阈值分量），规范序：分量内按输入序
//   升序、分量间按首成员输入序升序；
// - groups：引擎语义下已成组的簇，每组首元素为种子，组间按种子输入序升序；
// - hashes：photoId → hash 快照，用于 diff（新增 / 哈希变化 / 移除）。
public struct ClusterState: Equatable, Sendable {
    public let components: [[String]]
    public let groups: [[String]]
    public let hashes: [String: String]

    public init(components: [[String]], groups: [[String]], hashes: [String: String]) {
        self.components = components
        self.groups = groups
        self.hashes = hashes
    }
}
