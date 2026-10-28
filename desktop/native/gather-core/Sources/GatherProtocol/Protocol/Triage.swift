// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Triage.swift
// P0 / T0：技术质量初筛的契约类型（纯值；无 I/O、无仓储依赖）。
//
// 语义冻结见 docs/design/p0/x0-contracts.md §1.2 与 t0-triage-policy.md §7.2。
// - 建议只是建议：apply 只写 culling 决策，绝不自动写 XMP；
// - review 的 confidence 是“可执行置信度”的上界，不是准确率；
// - 未生成/已过期/人工决策 = 无行（nil），不是 confidence 0。
import Foundation

public enum TriageVerdict: String, Codable, CaseIterable, Equatable, Sendable {
    case keep
    case reject
    case review
}

public enum TriageReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
    case groupBest = "group_best"
    case weakerThanGroupBest = "weaker_than_group_best"
    case motionBlur = "motion_blur"
    case exposureLow = "exposure_low"
    case closedEyeSuspect = "closed_eye_suspect"
    /// 模型级信号（model_review）：真实眼睛几何分判闭眼，替代旧的"眼部梯度代理"。
    case eyesClosed = "eyes_closed"
    /// 主体脸合焦不足（人脸区域的拉普拉斯方差），比全局锐度更贴近"人脸糊了"。
    case faceOutOfFocus = "face_out_of_focus"
    /// 截图/文档（审美分模型的 isUtility）：婚礼/活动现场混进的非照片素材。
    case utilityImage = "utility_image"
    case closeCall = "close_call"
    case tieWithGroup = "tie_with_group"
    case singleShot = "single_shot"
    case noAlternative = "no_alternative"
    case lowTechnical = "low_technical"
    case qualityMissing = "quality_missing"
    case analysisFailed = "analysis_failed"
    case duplicateExact = "duplicate_exact"
    case duplicateVisual = "duplicate_visual"
    case multiFaceLowConfidence = "multi_face_low_confidence"
    case smallFace = "small_face"
    case manualOverride = "manual_override"
}

public struct TriageReason: Codable, Equatable, Sendable {
    public var code: TriageReasonCode
    /// 仅数值型理由携带（如与组内最佳的分数差）；其余为 nil。
    public var value: Double?

    public init(code: TriageReasonCode, value: Double? = nil) {
        self.code = code
        self.value = value
    }
}

public struct TriageSuggestion: Codable, Equatable, Sendable {
    public var photoId: String
    public var verdict: TriageVerdict
    public var score: Double
    /// 可执行置信度：keep/reject 为对应方向；review 为 max(cKeep, cReject)。
    public var confidence: Double
    public var reasons: [TriageReason]
    public var groupId: String?
    public var policyVersion: String
    public var inputFingerprint: String
    public var computedAt: String

    public init(
        photoId: String,
        verdict: TriageVerdict,
        score: Double,
        confidence: Double,
        reasons: [TriageReason],
        groupId: String? = nil,
        policyVersion: String,
        inputFingerprint: String,
        computedAt: String
    ) {
        self.photoId = photoId
        self.verdict = verdict
        self.score = score
        self.confidence = confidence
        self.reasons = reasons
        self.groupId = groupId
        self.policyVersion = policyVersion
        self.inputFingerprint = inputFingerprint
        self.computedAt = computedAt
    }
}

public struct TriageCounts: Codable, Equatable, Sendable {
    public var keep: Int
    public var reject: Int
    public var review: Int
    public var total: Int
    /// 成功分析数 / total，0...1。
    public var coverage: Double

    public init(keep: Int, reject: Int, review: Int, total: Int, coverage: Double) {
        self.keep = keep
        self.reject = reject
        self.review = review
        self.total = total
        self.coverage = coverage
    }
}

public struct TriageSummary: Codable, Equatable, Sendable {
    public var counts: TriageCounts
    public var stale: Bool
    public var policyVersion: String
    public var inputFingerprint: String
    public var generatedAt: String

    public init(
        counts: TriageCounts,
        stale: Bool,
        policyVersion: String,
        inputFingerprint: String,
        generatedAt: String
    ) {
        self.counts = counts
        self.stale = stale
        self.policyVersion = policyVersion
        self.inputFingerprint = inputFingerprint
        self.generatedAt = generatedAt
    }
}

public struct TriageGenerateInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var force: Bool

    public init(sessionId: String, force: Bool = false) {
        self.sessionId = sessionId
        self.force = force
    }
}

public struct TriageApplyInput: Codable, Equatable, Sendable {
    public var sessionId: String
    /// 仅 keep/reject；含 review 时服务层返回 TRIAGE_APPLY_INVALID。
    public var verdicts: [TriageVerdict]
    /// nil = 按 verdict 取 keep 0.60 / reject 0.75；非 nil 取 max(输入, 下限)。
    public var minConfidence: Double?
    /// 应用前校验；stale 返回 TRIAGE_STALE。
    public var fingerprint: String
    /// nil = 全部；非 nil 只应用这些照片。
    public var photoIds: [String]?

    public init(
        sessionId: String,
        verdicts: [TriageVerdict],
        minConfidence: Double? = nil,
        fingerprint: String,
        photoIds: [String]? = nil
    ) {
        self.sessionId = sessionId
        self.verdicts = verdicts
        self.minConfidence = minConfidence
        self.fingerprint = fingerprint
        self.photoIds = photoIds
    }
}

public struct TriageApplyResult: Codable, Equatable, Sendable {
    public var appliedAssets: Int
    public var appliedPhotos: Int
    public var appliedKeep: Int
    public var appliedReject: Int
    public var skippedManual: Int
    public var skippedLowConfidence: Int
    public var skippedMissing: Int
    /// 并发保护：写入前复核发现 revision 已变化而跳过的资产数。
    public var skippedConflict: Int
    public var historyOperationId: Int?

    public init(
        appliedAssets: Int = 0,
        appliedPhotos: Int = 0,
        appliedKeep: Int = 0,
        appliedReject: Int = 0,
        skippedManual: Int = 0,
        skippedLowConfidence: Int = 0,
        skippedMissing: Int = 0,
        skippedConflict: Int = 0,
        historyOperationId: Int? = nil
    ) {
        self.appliedAssets = appliedAssets
        self.appliedPhotos = appliedPhotos
        self.appliedKeep = appliedKeep
        self.appliedReject = appliedReject
        self.skippedManual = skippedManual
        self.skippedLowConfidence = skippedLowConfidence
        self.skippedMissing = skippedMissing
        self.skippedConflict = skippedConflict
        self.historyOperationId = historyOperationId
    }
}
