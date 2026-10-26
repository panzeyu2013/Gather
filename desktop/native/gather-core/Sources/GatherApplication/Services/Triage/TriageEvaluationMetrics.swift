// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriageEvaluationMetrics.swift
// P0 / T0：真实集质量门的纯函数指标。把“人工标注 vs 建议”折算成
// 误杀率 / reject precision / 复核率 / 覆盖率；不做 I/O，便于单测与 CLI 复用。
import Foundation
import GatherProtocol

public enum TriageGroundTruth: String, CaseIterable, Sendable, Equatable {
    case keep
    case reject
    /// 标注者不确定 / 争议未决：不计入分母，也不当作误杀。
    case unsure
}

public struct TriageLabeledVerdict: Sendable, Equatable {
    public let label: TriageGroundTruth
    public let verdict: TriageVerdict
    public let category: String?

    public init(label: TriageGroundTruth, verdict: TriageVerdict, category: String? = nil) {
        self.label = label
        self.verdict = verdict
        self.category = category
    }
}

public struct TriageRateBucket: Sendable, Equatable {
    public let labeled: Int
    public let trueKeep: Int
    public let trueReject: Int
    public let suggestedKeep: Int
    public let suggestedReject: Int
    public let review: Int
    public let falseReject: Int

    public var falseRejectRate: Double? { ratio(falseReject, trueKeep) }
    public var rejectPrecision: Double? { ratio(trueRejectResult, suggestedReject) }
    public var reviewRate: Double? { ratio(review, labeled) }
    public var coverage: Double? { ratio(suggestedKeep + suggestedReject, labeled) }

    /// 分母为 0 时返回 nil，调用方必须显式处理（不能把“没有样本”当 0%）。
    private func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }

    // 需要知道“真正类里被判为 reject”的分子；这里由 make 直接写入。
    fileprivate let trueRejectResult: Int

    init(
        labeled: Int, trueKeep: Int, trueReject: Int,
        suggestedKeep: Int, suggestedReject: Int, review: Int,
        falseReject: Int, trueRejectResult: Int
    ) {
        self.labeled = labeled
        self.trueKeep = trueKeep
        self.trueReject = trueReject
        self.suggestedKeep = suggestedKeep
        self.suggestedReject = suggestedReject
        self.review = review
        self.falseReject = falseReject
        self.trueRejectResult = trueRejectResult
    }
}

public struct TriageEvaluationReport: Sendable, Equatable {
    public let overall: TriageRateBucket
    public let byCategory: [String: TriageRateBucket]
    public let ignoredUnsure: Int

    public init(overall: TriageRateBucket, byCategory: [String: TriageRateBucket], ignoredUnsure: Int) {
        self.overall = overall
        self.byCategory = byCategory
        self.ignoredUnsure = ignoredUnsure
    }
}

public enum TriageMetrics {
    public static func evaluate(_ rows: [TriageLabeledVerdict]) -> TriageEvaluationReport {
        var considered: [TriageLabeledVerdict] = []
        var ignoredUnsure = 0
        for row in rows {
            if row.label == .unsure { ignoredUnsure += 1 } else { considered.append(row) }
        }
        let byCategory = Dictionary(grouping: considered) { $0.category ?? "all" }
        return TriageEvaluationReport(
            overall: bucket(considered),
            byCategory: byCategory.mapValues(bucket),
            ignoredUnsure: ignoredUnsure
        )
    }

    private static func bucket(_ rows: [TriageLabeledVerdict]) -> TriageRateBucket {
        var trueKeep = 0, trueReject = 0
        var suggestedKeep = 0, suggestedReject = 0, review = 0
        var falseReject = 0
        var trueRejectResult = 0
        for row in rows {
            switch row.label {
            case .keep: trueKeep += 1
            case .reject: trueReject += 1
            case .unsure: continue
            }
            switch row.verdict {
            case .keep:
                suggestedKeep += 1
            case .reject:
                suggestedReject += 1
                if row.label == .reject { trueRejectResult += 1 }
                if row.label == .keep { falseReject += 1 }
            case .review:
                review += 1
            }
        }
        return TriageRateBucket(
            labeled: rows.count,
            trueKeep: trueKeep,
            trueReject: trueReject,
            suggestedKeep: suggestedKeep,
            suggestedReject: suggestedReject,
            review: review,
            falseReject: falseReject,
            trueRejectResult: trueRejectResult
        )
    }
}
