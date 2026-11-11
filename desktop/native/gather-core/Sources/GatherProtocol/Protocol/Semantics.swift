// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Semantics.swift
// P1 下一波 §3.11.3：语义检索的 IPC 快照（图搜图 / 标签检索）。
//
// 应用层 SemanticIndex 返回更细的 SemanticSearchOutcome；LivePhotoAPI 在这里
// 映射成可编码快照，UI/命令面不依赖 GatherApplication。

import Foundation

/// 场景/事件标签写回关键词的路径约定（写回、facet、UI 三处共用一份常量）。
///
/// 为什么集中在这里：标签→关键词的映射一旦各处各写一遍，facet 的桶与网格的
/// keyword_path 规则就会对不上（"数字对不上列表"是本仓 facet 的红线）。
/// 层级分隔符沿用 KeywordPath 的 `|`（\"A|B"），与 photo_keywords.keyword_path 一致。
public enum SemanticKeywordPath {
    /// 标签写回的总根（用户可在写回入口改根，facet 只认默认根）。
    public static let root = "AI"
    /// 场景/事件标签的默认根：`AI|场景|<normalized label>`。
    public static let scene = "AI|场景"
    /// 单张照片最多写回的标签数（Vision top-8 里取前 N，避免关键词爆炸）。
    public static let maxLabelsPerPhoto = 6
    /// 标签规范化后的最大长度（Vision 标识符可能很长，keyword 列有上限）。
    public static let maxLabelLength = 40
    /// UI 预览最多返回多少条"逐张明细"（Wave4b：2 万张会话的 plan.items 会占满 IPC/内存；
    /// 计数仍是全量，只有明细截断并由 `itemsTruncated` 标注）。
    public static let maxDisplayedPlanItems = 500
}

public struct SemanticSearchQuery: Codable, Equatable, Sendable {
    public var sessionId: String
    /// 非 nil = 以该照片的特征向量做"相似照片"；nil = 按 labels 检索。
    public var photoId: String?
    /// Wave2 / task-14：多选种子（取平均向量再检索）。非空时**优先于** photoId：
    /// 单张只是多选的退化情形，语义上永远用"种子集合的平均向量"更稳定
    /// （单张容易被构图抖动带偏）。空数组 = 不用多选。
    public var photoIds: [String]
    /// 标签检索词（photoId/photoIds 非 nil 时忽略；空 = INVALID_PARAM 语义，返回空结果）。
    public var labels: [String]
    public var limit: Int
    /// 图搜图余弦下限（0…1）；标签检索忽略。
    public var minSimilarity: Double

    public init(
        sessionId: String,
        photoId: String? = nil,
        photoIds: [String] = [],
        labels: [String] = [],
        limit: Int = 50,
        minSimilarity: Double = 0.6
    ) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.photoIds = photoIds
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

// MARK: - 场景标签写回关键词（Wave2 / task-14）

/// 写回预览的输入：photoIds 为 nil = 会话内有语义标签的全部照片。
public struct SemanticKeywordPlanInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]?
    /// 关键词根（默认 `SemanticKeywordPath.scene`）；UI 可改成自己的命名空间。
    public var root: String
    /// 单张最多写回几个标签（Vision top-8 里取前 N）。
    public var maxLabelsPerPhoto: Int
    /// 逐张明细上限（0 = 不截断；UI 预览传 `SemanticKeywordPath.maxDisplayedPlanItems`）。
    /// 只截断 `plan.items`，`totalAdditions` 等计数始终按全量算。
    public var maxItems: Int

    public init(
        sessionId: String,
        photoIds: [String]? = nil,
        root: String = SemanticKeywordPath.scene,
        maxLabelsPerPhoto: Int = SemanticKeywordPath.maxLabelsPerPhoto,
        maxItems: Int = 0
    ) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.root = root
        self.maxLabelsPerPhoto = maxLabelsPerPhoto
        self.maxItems = max(0, maxItems)
    }
}

/// 单张照片的计划：`keywords` 是**完整 keyword_path**（含根），可直接落到
/// photo_keywords / XMP 层级关键词；`alreadyPresent` 表示该照片已全部具备
///（重复跑不会重复加词 → 幂等）。
public struct SemanticKeywordPlanItem: Codable, Equatable, Sendable {
    public var photoId: String
    public var keywords: [String]
    public var alreadyPresent: Bool

    public init(photoId: String, keywords: [String], alreadyPresent: Bool) {
        self.photoId = photoId
        self.keywords = keywords
        self.alreadyPresent = alreadyPresent
    }
}

public struct SemanticKeywordPlan: Codable, Equatable, Sendable {
    public var sessionId: String
    public var root: String
    public var items: [SemanticKeywordPlanItem]
    public var photosWithLabels: Int
    public var photosWithoutLabels: Int
    /// 需要新增的关键词条数（已存在的已扣除）。
    public var totalAdditions: Int
    /// `items` 是否被 `maxItems` 截断（计数仍是全量；UI 用来说明"明细不全"）。
    public var itemsTruncated: Bool
    /// 无法生成计划的原因（语义索引未建立 / 未接线）：UI 显示，不当错误。
    public var unavailableReason: String?

    public init(
        sessionId: String,
        root: String,
        items: [SemanticKeywordPlanItem],
        photosWithLabels: Int,
        photosWithoutLabels: Int,
        totalAdditions: Int,
        itemsTruncated: Bool = false,
        unavailableReason: String? = nil
    ) {
        self.sessionId = sessionId
        self.root = root
        self.items = items
        self.photosWithLabels = photosWithLabels
        self.photosWithoutLabels = photosWithoutLabels
        self.totalAdditions = totalAdditions
        self.itemsTruncated = itemsTruncated
        self.unavailableReason = unavailableReason
    }
}

/// 写回/撤销输入。`remove == false` 追加缺失关键词；`true` 撤销同一批
///（移除 root 子树下的关键词，不改其它来源的关键词）。
public struct SemanticKeywordApplyInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]?
    public var root: String
    public var maxLabelsPerPhoto: Int
    public var remove: Bool

    public init(
        sessionId: String,
        photoIds: [String]? = nil,
        root: String = SemanticKeywordPath.scene,
        maxLabelsPerPhoto: Int = SemanticKeywordPath.maxLabelsPerPhoto,
        remove: Bool = false
    ) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.root = root
        self.maxLabelsPerPhoto = maxLabelsPerPhoto
        self.remove = remove
    }
}

public struct SemanticKeywordApplyResult: Codable, Equatable, Sendable {
    public var sessionId: String
    public var appliedPhotos: Int
    /// 本批**实际写到**的照片 id（E2）：UI 保存后作为撤销 scope 回传，
    /// 让"撤销本批"只清本批写过的照片，而不是整个会话的 root 子树。
    public var appliedPhotoIds: [String]
    public var skippedPhotos: Int
    public var keywordsAdded: Int
    public var keywordsRemoved: Int
    /// 批次标识（审计/日志；undo 用 photoIds + root 即可复现同一批）。
    public var batchId: String
    public var failedPhotoIds: [String]

    public init(
        sessionId: String,
        appliedPhotos: Int,
        appliedPhotoIds: [String] = [],
        skippedPhotos: Int,
        keywordsAdded: Int,
        keywordsRemoved: Int,
        batchId: String,
        failedPhotoIds: [String] = []
    ) {
        self.sessionId = sessionId
        self.appliedPhotos = appliedPhotos
        self.appliedPhotoIds = appliedPhotoIds
        self.skippedPhotos = skippedPhotos
        self.keywordsAdded = keywordsAdded
        self.keywordsRemoved = keywordsRemoved
        self.batchId = batchId
        self.failedPhotoIds = failedPhotoIds
    }
}

