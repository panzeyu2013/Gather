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

public struct TriageWritebackItem: Decodable, Sendable, Equatable {
    public let photoId: String
    /// "keep" / "reject"（大小写不敏感；其它值服务端忽略）。
    public let verdict: String
    /// 人工已决策（UI 从 culling 决策行得到；true 时绝不写 rating）。
    public let manuallyDecided: Bool

    public init(photoId: String, verdict: String, manuallyDecided: Bool = false) throws {
        self.photoId = try APIValidation.nonBlank(photoId, field: "photoId", maxLength: 128)
        self.verdict = verdict
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
    public let items: [TriageWritebackItem]

    public init(policy: TriageWritebackPolicy, items: [TriageWritebackItem]) throws {
        guard !items.isEmpty else {
            throw GatherError.invalidParameter(field: "items", reason: "must not be empty")
        }
        self.policy = policy
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            policy: try container.decodeIfPresent(TriageWritebackPolicy.self, forKey: .policy) ?? .ratingOnlyWhenEmpty,
            items: try container.decode([TriageWritebackItem].self, forKey: .items)
        )
    }

    private enum CodingKeys: String, CodingKey { case policy, items }
}

public struct TriageWritebackResult: Codable, Equatable, Sendable {
    /// 供撤销使用（undoTriageWriteback 的入参）。
    public var batchId: String
    public var written: [String]
    public var skipped: [String]
    public var failed: [MetadataApplyFailureDTO]
    public init(batchId: String, written: [String], skipped: [String], failed: [MetadataApplyFailureDTO]) {
        self.batchId = batchId
        self.written = written
        self.skipped = skipped
        self.failed = failed
    }
}
