// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/TriageWritebackInputs.swift
// P1 / E：triage 写回的 API 契约。
//
// 调用方（UI）传入的是"已经过人工优先过滤"的决策列表：TriageService 在产出建议时
// 已排除人工决策过的照片，因此这里不再重复判定，只做"空 rating 才写"的二次保护。
import Foundation

/// 写回策略（放 Protocol：API 输入要用）。
public enum TriageWritebackPolicy: String, Codable, CaseIterable, Sendable {
    case off
    /// 默认：只写空 rating + 私有命名空间
    case ratingOnlyWhenEmpty
    /// 额外写 Gather|AI|Keep / Gather|AI|Reject 关键词（会进交付物）
    case ratingAndKeyword
}

/// P0 / A2：星级策略（产品未拍板前不偷偷改默认，而是把它显式暴露给用户）。
///
/// - keep3Reject1（默认，保持现状）：keep→3★，reject→1★；
/// - keep3Only：只给 keep 写 3★，reject 不写星级（避免 1★ 与人工 1★ 混淆）；
/// - none：完全不写星级，只写私有命名空间/关键词。
public enum TriageRatingMode: String, Codable, CaseIterable, Sendable {
    case keep3Reject1
    case keep3Only
    case none
}

public struct TriageWritebackItem: Decodable, Sendable, Equatable {
    public let photoId: String
    /// "keep" / "reject"（大小写不敏感，统一归一到小写；其它值显式失败）。
    ///
    /// 不静默忽略：非法 verdict 若被服务端跳过，这张照片既不在 written 也不在
    /// skipped/failed，调用方无从发现漏写（Cut 1 的显式校验约定）。
    public let verdict: String
    /// 人工已决策（UI 从 culling 决策行得到；true 时绝不写 rating）。
    public let manuallyDecided: Bool

    public init(photoId: String, verdict: String, manuallyDecided: Bool = false) throws {
        self.photoId = try APIValidation.nonBlank(photoId, field: "photoId", maxLength: 128)
        let normalized = verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == "keep" || normalized == "reject" else {
            throw GatherError.invalidParameter(
                field: "items.verdict", reason: "must be keep or reject")
        }
        self.verdict = normalized
        self.manuallyDecided = manuallyDecided
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoId: try container.decode(String.self, forKey: .photoId),
            verdict: try container.decode(String.self, forKey: .verdict),
            manuallyDecided: try container.decodeIfPresent(Bool.self, forKey: .manuallyDecided) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey { case photoId, verdict, manuallyDecided }
}

public struct TriageWritebackInput: Decodable, Sendable, Equatable {
    public let policy: TriageWritebackPolicy
    public let ratingMode: TriageRatingMode
    public let items: [TriageWritebackItem]

    public init(
        policy: TriageWritebackPolicy,
        ratingMode: TriageRatingMode = .keep3Reject1,
        items: [TriageWritebackItem]
    ) throws {
        // 上限对齐"大库全会话写回"（UI 分页 500×200 = 100k，项目目标含 100k 级会话）：
        // 太小会让合法的整会话写回直接被拒绝。真正非法的是空/重复/超大数组。
        let values = try APIValidation.nonEmpty(items, field: "items", maxCount: 100_000)
        guard Set(values.map(\.photoId)).count == values.count else {
            throw GatherError.invalidParameter(field: "items", reason: "photoId must be unique")
        }
        self.policy = policy
        self.ratingMode = ratingMode
        self.items = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            policy: try container.decodeIfPresent(TriageWritebackPolicy.self, forKey: .policy) ?? .ratingOnlyWhenEmpty,
            ratingMode: try container.decodeIfPresent(TriageRatingMode.self, forKey: .ratingMode) ?? .keep3Reject1,
            items: try container.decode([TriageWritebackItem].self, forKey: .items)
        )
    }

    private enum CodingKeys: String, CodingKey { case policy, ratingMode, items }
}

public struct TriageWritebackResult: Codable, Equatable, Sendable {
    /// 供撤销使用（undoTriageWriteback 的入参）。
    public var batchId: String
    public var written: [String]
    public var skipped: [String]
    public var failed: [MetadataApplyFailureDTO]
    /// P1：批次是否真的可撤销（written ∪ uncertain 非空）。UI 不得用 written.isEmpty
    /// 推导——回读失败的照片仍可能已写盘，批次必须保留撤销入口。
    public var undoAvailable: Bool
    public init(
        batchId: String,
        written: [String],
        skipped: [String],
        failed: [MetadataApplyFailureDTO],
        undoAvailable: Bool = false
    ) {
        self.batchId = batchId
        self.written = written
        self.skipped = skipped
        self.failed = failed
        self.undoAvailable = undoAvailable
    }
}
