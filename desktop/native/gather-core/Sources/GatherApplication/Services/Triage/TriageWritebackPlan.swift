// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriageWritebackPlan.swift
// P1 / E：把 triage 建议翻译成"可移植信号"（纯函数，不做 IO）。
//
// 产品红线（写在这里，避免以后被"顺手"改掉）：
// - label（颜色）永不写：用户色标属于用户；
// - rating 只写空值（0），且人工已决策的照片一律不动；
// - 关键词默认不写（会进客户交付的元数据），仅显式策略开启；
// - 私有命名空间 gather:Triage 始终记录，便于撤回与审计。
import Foundation
import GatherProtocol

public struct TriageWritebackDecision: Equatable, Sendable {
    public var photoId: String
    /// 要写入的星级（nil = 不写）。
    public var rating: Int?
    /// 要追加的关键词（nil = 不写）。
    public var keyword: String?
    /// 私有命名空间值（始终有值，除非策略 off）。
    public var namespaceValue: String

    public init(photoId: String, rating: Int?, keyword: String?, namespaceValue: String) {
        self.photoId = photoId
        self.rating = rating
        self.keyword = keyword
        self.namespaceValue = namespaceValue
    }

    public var writesRating: Bool { rating != nil }
}

public enum TriageWritebackPlanner {
    public static let keywordKeep = "Gather|AI|Keep"
    public static let keywordReject = "Gather|AI|Reject"
    /// XMP 私有命名空间（宿主写入 SidecarXMPProvider 时使用）。
    public static let namespaceURI = "https://gather.app/ns/triage/1.0/"
    public static let namespaceProperty = "gather:Triage"

    /// - verdict: "keep" / "reject"（大小写不敏感）；其它值视为无建议。
    /// - currentRating: 现有星级（0 表示未评分）。
    /// - manuallyDecided: 人工已决策（culling_decisions.source == manual）。
    public static func plan(
        photoId: String,
        verdict: String,
        currentRating: Int,
        manuallyDecided: Bool,
        policy: TriageWritebackPolicy,
        ratingMode: TriageRatingMode = .keep3Reject1
    ) -> TriageWritebackDecision? {
        guard policy != .off else { return nil }
        let normalized = verdict.lowercased()
        guard normalized == "keep" || normalized == "reject" else { return nil }

        let isKeep = normalized == "keep"
        // P0 / A2：默认保持 3/1（不改用户现状）；keep3Only / none 由 UI 显式选择。
        let targetRating: Int? = switch ratingMode {
        case .keep3Reject1: isKeep ? 3 : 1
        case .keep3Only: isKeep ? 3 : nil
        case .none: nil
        }
        let canWriteRating = !manuallyDecided && currentRating == 0
        let rating: Int? = canWriteRating ? targetRating : nil
        let keyword: String? = (policy == .ratingAndKeyword) ? (isKeep ? keywordKeep : keywordReject) : nil

        return TriageWritebackDecision(
            photoId: photoId,
            rating: rating,
            keyword: keyword,
            namespaceValue: isKeep ? "keep" : "reject"
        )
    }

    public static func planBatch(
        photos: [(photoId: String, verdict: String, currentRating: Int, manuallyDecided: Bool)],
        policy: TriageWritebackPolicy,
        ratingMode: TriageRatingMode = .keep3Reject1
    ) -> [TriageWritebackDecision] {
        photos.compactMap { photo in
            plan(photoId: photo.photoId, verdict: photo.verdict,
                 currentRating: photo.currentRating, manuallyDecided: photo.manuallyDecided,
                 policy: policy, ratingMode: ratingMode)
        }
    }
}
