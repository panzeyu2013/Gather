// desktop/native/gather-core/Sources/GatherPersistence/Ports/TriageRepository.swift
// P0 / T0：技术质量初筛的持久化端口（读候选、写建议、读应用目标、指纹/摘要）。
//
// 纯 Persistence DTO；不引用 GatherApplication 的 TriageCandidate/Evaluator，
// 由 TriageService 负责 DTO → 纯函数输入的映射（分层：Persistence 只依赖 Protocol）。
import Foundation
import GatherProtocol

/// 候选的组引用（kind 用字符串，映射由 Application 负责）。
public struct TriageGroupRecord: Equatable, Sendable {
    public let kind: String
    public let groupId: String
    public let memberPhotoIds: [String]
    public let leadPhotoId: String?

    public init(kind: String, groupId: String, memberPhotoIds: [String], leadPhotoId: String? = nil) {
        self.kind = kind
        self.groupId = groupId
        self.memberPhotoIds = memberPhotoIds
        self.leadPhotoId = leadPhotoId
    }
}

/// 一个逻辑资产代表行的候选投影。
public struct TriageCandidateRecord: Equatable, Sendable {
    public let photoId: String
    public let quality: QualityResult?
    public let faceCount: Int
    public let maxFaceAreaRatio: Double
    public let groups: [TriageGroupRecord]
    public let manualDecision: String?
    public let decisionSource: String?
    public let importOrder: Int
    /// exact 重复组的“最佳”判据（设计 §5.3）。
    public let width: Int
    public let height: Int
    public let fileSize: Int64

    public init(
        photoId: String,
        quality: QualityResult?,
        faceCount: Int,
        maxFaceAreaRatio: Double,
        groups: [TriageGroupRecord],
        manualDecision: String?,
        decisionSource: String?,
        importOrder: Int,
        width: Int = 0,
        height: Int = 0,
        fileSize: Int64 = 0
    ) {
        self.photoId = photoId
        self.quality = quality
        self.faceCount = faceCount
        self.maxFaceAreaRatio = maxFaceAreaRatio
        self.groups = groups
        self.manualDecision = manualDecision
        self.decisionSource = decisionSource
        self.importOrder = importOrder
        self.width = width
        self.height = height
        self.fileSize = fileSize
    }
}

public struct TriageCandidateLoad: Equatable, Sendable {
    public let candidates: [TriageCandidateRecord]
    /// 成功分析的代表行数 / 代表行总数（0 会话时为 0）。
    public let coverage: Double

    public init(candidates: [TriageCandidateRecord], coverage: Double) {
        self.candidates = candidates
        self.coverage = coverage
    }
}

/// 应用目标：代表行 + 其全部变体的当前决策/缓存快照。
public struct TriageVariantRecord: Equatable, Sendable {
    public let photoId: String
    public let decision: String
    public let decisionSource: String?
    public let revision: Int
    public let rating: Int
    public let colorLabel: String
    public let groupId: String

    public init(
        photoId: String,
        decision: String,
        decisionSource: String?,
        revision: Int,
        rating: Int,
        colorLabel: String,
        groupId: String
    ) {
        self.photoId = photoId
        self.decision = decision
        self.decisionSource = decisionSource
        self.revision = revision
        self.rating = rating
        self.colorLabel = colorLabel
        self.groupId = groupId
    }
}

public struct TriageApplyTargetRecord: Equatable, Sendable {
    public let representativePhotoId: String
    public let variants: [TriageVariantRecord]

    public init(representativePhotoId: String, variants: [TriageVariantRecord]) {
        self.representativePhotoId = representativePhotoId
        self.variants = variants
    }
}

public protocol TriageRepository {
    /// 每个逻辑资产代表行一条；质量/人脸/组/人工决策按代表行口径装配。
    func loadCandidates(sessionId: String) throws -> TriageCandidateLoad

    /// quality/similarity/duplicate/navigation/policy/thresholds 的 SHA-256。
    func fingerprint(
        sessionId: String,
        policyVersion: String,
        thresholdsDigest: String
    ) throws -> String

    func loadSuggestions(sessionId: String) throws -> [TriageSuggestion]

    /// 调用方事务内：DELETE 本会话全部建议 + INSERT 新建议。
    func replaceSuggestions(sessionId: String, suggestions: [TriageSuggestion]) throws

    /// 从已落库行统计 counts/generatedAt，并按当前 fingerprint/policy 判 stale。
    /// 空行不等于 stale：只有“存在可生成候选”才算过期（区分“未生成/全人工”与“真过期”）。
    func summary(
        sessionId: String,
        policyVersion: String,
        fingerprint: String
    ) throws -> TriageSummary

    /// 删除已人工决策资产上的建议行（generate 前调用，保持“人工决策不建行”）。
    func deleteSuggestionsForManualAssets(sessionId: String) throws

    /// 可生成建议的代表行数：排除任一变体已被人工决策的逻辑资产。
    /// generate 用它短路“全人工/空会话”，避免每次重算且 stale 永远为真。
    func eligibleSuggestionCount(sessionId: String) throws -> Int

    /// 代表行 → 全部变体的当前决策/缓存快照。
    func loadApplyTargets(
        sessionId: String,
        representativePhotoIds: [String]
    ) throws -> [TriageApplyTargetRecord]
}
