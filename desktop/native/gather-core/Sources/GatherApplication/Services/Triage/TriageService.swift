// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriageService.swift
// P0 / T0：初筛服务编排（候选装配 → 纯函数 → 建议落库；建议 → 决策 + 历史）。
//
// 边界：
//   - 只读写 Gather 自己的表；绝不写 XMP、不写 photo_metadata_cache 的 rating/label；
//   - 应用只写 culling_decisions（source='ai'）+ 一条 culling_history；
//   - 人工已决策优先，任何路径都不覆盖。
import Foundation
import GatherProtocol
import GatherPersistence

/// 服务层错误。API/Live 层负责映射到 GatherErrorCode（TRIAGE_*）。
public enum TriageServiceError: Error, Equatable, CustomStringConvertible {
    case notReady
    case stale
    case applyInvalid(String)
    case policyInvalid(String)

    public var code: String {
        switch self {
        case .notReady: "TRIAGE_NOT_READY"
        case .stale: "TRIAGE_STALE"
        case .applyInvalid: "TRIAGE_APPLY_INVALID"
        case .policyInvalid: "TRIAGE_POLICY_INVALID"
        }
    }

    public var description: String {
        switch self {
        case .notReady: "TRIAGE_NOT_READY"
        case .stale: "TRIAGE_STALE"
        case .applyInvalid(let reason): "TRIAGE_APPLY_INVALID: \(reason)"
        case .policyInvalid(let reason): "TRIAGE_POLICY_INVALID: \(reason)"
        }
    }
}

/// 资产级建议门控：只有 fingerprint 与 policyVersion 都匹配的行才可展示/应用。
/// 由 TriageService 产出，CullingService 只读消费（不自己拼指纹）。
public struct TriageSuggestionGate: Equatable, Sendable {
    public let fingerprint: String
    public let policyVersion: String

    public init(fingerprint: String, policyVersion: String) {
        self.fingerprint = fingerprint
        self.policyVersion = policyVersion
    }
}

/// Culling 富化时的建议展示策略。
public enum TriageDisplayPolicy: Equatable, Sendable {
    /// T0 关闭：不展示任何建议（包括库里的旧行）。
    case hidden
    /// 只展示 fingerprint 与 policyVersion 都匹配的行。
    case matching(TriageSuggestionGate)
}

public final class TriageService {
    private let repository: any TriageRepository
    private let decisions: any CullingDecisionRepository
    private let history: (any CullingHistoryRepository)?
    private let transactions: any TransactionRunner
    private let fixedPolicy: TriagePolicy
    private let policyProvider: (() -> TriagePolicy)?
    private let fixedEnabled: Bool
    private let enabledProvider: (() -> Bool)?
    private let now: () -> String
    private let gateCacheTTL: TimeInterval
    private let clock: () -> Date
    private let gateCacheLock = NSLock()
    private var gateCache: [String: (gate: TriageSuggestionGate, at: Date)] = [:]

    /// 每次读取都取设置最新值；生成/应用开始时再做一次局部快照，
    /// 避免一次请求内 policy 变化导致指纹与评估混用两套阈值。
    public var policy: TriagePolicy { policyProvider?() ?? fixedPolicy }
    public var isEnabled: Bool { enabledProvider?() ?? fixedEnabled }
    /// 同一 service 实例内串行化 generate/apply：避免指纹校验与建议重读之间
    /// 被另一条任务替换建议。summary 只读，不参与锁。
    private let serialize = NSLock()

    public init(
        repository: any TriageRepository,
        decisions: any CullingDecisionRepository,
        history: (any CullingHistoryRepository)? = nil,
        transactions: any TransactionRunner,
        policy: TriagePolicy = .v1,
        enabled: Bool = true,
        policyProvider: (() -> TriagePolicy)? = nil,
        enabledProvider: (() -> Bool)? = nil,
        now: @escaping () -> String = TriageService.defaultNow,
        gateCacheTTL: TimeInterval = 2,
        clock: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.decisions = decisions
        self.history = history
        self.transactions = transactions
        self.fixedPolicy = policy
        self.policyProvider = policyProvider
        self.fixedEnabled = enabled
        self.enabledProvider = enabledProvider
        self.now = now
        self.gateCacheTTL = gateCacheTTL
        self.clock = clock
    }

    // MARK: - 门控

    /// 当前输入指纹 + 策略版本（生成/应用/摘要共用，保证三者永远同一口径）。
    public func gate(sessionId: String) throws -> TriageSuggestionGate {
        let policy = self.policy
        let fingerprint = try repository.fingerprint(
            sessionId: sessionId,
            policyVersion: policy.version,
            thresholdsDigest: thresholdsDigest(for: policy),
            includeModelReview: policy.usesModelSignals
        )
        return TriageSuggestionGate(fingerprint: fingerprint, policyVersion: policy.version)
    }

    /// 页面富化用门控：短 TTL 缓存，避免每翻一页就重算 20k 质量聚合指纹。
    /// 关闭 T0 时返回 nil：调用方据此完全不展示建议（而不是展示旧行）。
    public func cachedGate(sessionId: String) throws -> TriageSuggestionGate? {
        guard isEnabled else { return nil }
        let now = clock()
        gateCacheLock.lock()
        let cached = gateCache[sessionId]
        gateCacheLock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < gateCacheTTL {
            return cached.gate
        }
        let computed = try gate(sessionId: sessionId)
        gateCacheLock.lock()
        gateCache[sessionId] = (computed, now)
        gateCacheLock.unlock()
        return computed
    }

    /// 设置/生成/应用后让缓存失效，避免刚生成完页面仍拿旧门控。
    public func invalidateGateCache() {
        gateCacheLock.lock()
        gateCache.removeAll()
        gateCacheLock.unlock()
    }

    // MARK: - 生成 / 摘要

    public func generate(sessionId: String, force: Bool = false) throws -> TriageSummary {
        guard isEnabled else {
            throw TriageServiceError.policyInvalid("triage is disabled in settings")
        }
        serialize.lock()
        defer { serialize.unlock() }
        let policy = self.policy
        let currentGate = try gate(sessionId: sessionId)
        // 人工已决策的资产不再保留建议行：即使指纹未变（manual 不进指纹），
        // “generate 不建行”也必须在下次生成时落地，而不是靠 UI 过滤。
        try transactions.transaction {
            try repository.deleteSuggestionsForManualAssets(sessionId: sessionId)
        }
        let eligible = try repository.eligibleSuggestionCount(sessionId: sessionId)
        // 全部候选都已被人工决策（或无照片）：清空旧行，避免 `stale` 永远为真。
        if eligible == 0 {
            try transactions.transaction {
                try repository.replaceSuggestions(sessionId: sessionId, suggestions: [])
            }
            invalidateGateCache()
            return try repository.summary(
                sessionId: sessionId,
                policyVersion: currentGate.policyVersion,
                fingerprint: currentGate.fingerprint
            )
        }
        if !force {
            let existing = try repository.loadSuggestions(sessionId: sessionId)
            // 指纹一致还不够：人工决策撤销/清空会让“该资产该有建议”重新成立，
            // 但旧行已被删；行数少于 eligible 时必须重建，否则永久缺建议。
            if existing.count == eligible,
               existing.allSatisfy({
                   $0.inputFingerprint == currentGate.fingerprint
                       && $0.policyVersion == currentGate.policyVersion
               }) {
                return try repository.summary(
                    sessionId: sessionId,
                    policyVersion: currentGate.policyVersion,
                    fingerprint: currentGate.fingerprint
                )
            }
        }

        let load = try repository.loadCandidates(
            sessionId: sessionId, includeModelReview: policy.usesModelSignals)
        let candidates = load.candidates.map(mapCandidate)
        let evaluations = evaluateTriage(candidates: candidates, policy: policy)
        let computedAt = now()
        var suggestions: [TriageSuggestion] = []
        suggestions.reserveCapacity(evaluations.count)
        for evaluation in evaluations {
            guard case .suggestion(let result) = evaluation else { continue }
            suggestions.append(TriageSuggestion(
                photoId: result.photoId,
                verdict: result.verdict,
                score: result.score,
                confidence: result.confidence,
                reasons: result.reasons,
                groupId: result.groupId,
                policyVersion: currentGate.policyVersion,
                inputFingerprint: currentGate.fingerprint,
                computedAt: computedAt
            ))
        }

        try transactions.transaction {
            try repository.replaceSuggestions(sessionId: sessionId, suggestions: suggestions)
        }
        invalidateGateCache()

        var keep = 0, reject = 0, review = 0
        for suggestion in suggestions {
            switch suggestion.verdict {
            case .keep: keep += 1
            case .reject: reject += 1
            case .review: review += 1
            }
        }
        return TriageSummary(
            counts: TriageCounts(
                keep: keep, reject: reject, review: review,
                total: suggestions.count, coverage: load.coverage
            ),
            stale: false,
            policyVersion: currentGate.policyVersion,
            inputFingerprint: currentGate.fingerprint,
            generatedAt: computedAt
        )
    }

    public func summary(sessionId: String) throws -> TriageSummary {
        // 摘要每次决策后都会被 UI 重取；复用 2s 门控缓存，避免 20k 会话每次键动作
        // 都跑一遍质量聚合指纹（generate/apply 会主动失效缓存）。
        let currentGate = try cachedGate(sessionId: sessionId) ?? gate(sessionId: sessionId)
        return try repository.summary(
            sessionId: sessionId,
            policyVersion: currentGate.policyVersion,
            fingerprint: currentGate.fingerprint
        )
    }

    // MARK: - 应用

    public func apply(_ input: Confirmed<TriageApplyInput>) throws -> TriageApplyResult {
        guard isEnabled else {
            throw TriageServiceError.policyInvalid("triage is disabled in settings")
        }
        serialize.lock()
        defer { serialize.unlock() }
        let policy = self.policy
        let payload = input.value
        guard !payload.verdicts.isEmpty else {
            throw TriageServiceError.applyInvalid("verdicts must not be empty")
        }
        guard payload.verdicts.allSatisfy({ $0 == .keep || $0 == .reject }) else {
            throw TriageServiceError.applyInvalid("only keep/reject can be applied")
        }
        if let minConfidence = payload.minConfidence,
           !(0...1).contains(minConfidence) {
            throw TriageServiceError.applyInvalid("minConfidence must be 0...1")
        }
        if let photoIds = payload.photoIds, photoIds.isEmpty {
            throw TriageServiceError.applyInvalid("photoIds must not be empty")
        }

        let currentGate = try gate(sessionId: payload.sessionId)
        guard payload.fingerprint == currentGate.fingerprint else {
            throw TriageServiceError.stale
        }

        let allSuggestions = try repository.loadSuggestions(sessionId: payload.sessionId)
        // 建议行本身也必须与当前输入一致；否则“客户端指纹正确”会把旧质量/旧组
        // 算出的 keep/reject 写进库。不一致 = 整批 stale，不部分应用。
        guard allSuggestions.allSatisfy({
            $0.inputFingerprint == currentGate.fingerprint
                && $0.policyVersion == currentGate.policyVersion
        }) else {
            throw TriageServiceError.stale
        }
        let verdicts = Set(payload.verdicts)
        let requestedIds: Set<String>
        if let photoIds = payload.photoIds {
            requestedIds = Set(photoIds)
        } else {
            requestedIds = Set(allSuggestions.map(\.photoId))
        }
        let selected = allSuggestions.filter {
            verdicts.contains($0.verdict) && requestedIds.contains($0.photoId)
        }
        let suggestionIds = Set(allSuggestions.map(\.photoId))
        var skippedMissing = requestedIds.subtracting(suggestionIds).count

        let targetList = try repository.loadApplyTargets(
            sessionId: payload.sessionId,
            representativePhotoIds: selected.map(\.photoId)
        )
        let targets = Dictionary(
            targetList.map { ($0.representativePhotoId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var appliedKeep = 0
        var appliedReject = 0
        var appliedPhotos = 0
        var skippedManual = 0
        var skippedLowConfidence = 0
        var skippedConflict = 0
        var entries: [CullingHistoryEntry] = []
        var historyOperationId: Int?

        try transactions.transaction {
            for suggestion in selected {
                guard let target = targets[suggestion.photoId] else {
                    skippedMissing += 1
                    continue
                }
                // 人工优先：任一变体有人工决策（含显式“待定”）即整条资产跳过；
                // 人工清空意图不能被 AI 覆盖（data-contracts §5.3）。
                // 客户校样回传（imported）同样是人的决定，必须一起保护。
                if target.variants.contains(where: {
                    CullingDecisionSource(rawValue: $0.decisionSource ?? "")?
                        .isHumanDecision == true
                }) {
                    skippedManual += 1
                    continue
                }
                // 并发保护：读目标与写入之间可能有人工/另一端写入；事务内复核 revision，
                // 不一致整条资产跳过（不部分写入、不覆盖别人的新决策）。
                var revisionChanged = false
                for variant in target.variants {
                    let current = try decisions.getDecision(
                        sessionId: payload.sessionId, photoId: variant.photoId)
                    if (current?.revision ?? 0) != Int64(variant.revision) {
                        revisionChanged = true
                        break
                    }
                }
                if revisionChanged {
                    skippedConflict += 1
                    continue
                }
                // 幂等：同一 verdict 的 AI 决策已覆盖全部变体时不再重复写历史。
                if target.variants.allSatisfy({
                    $0.decisionSource == CullingDecisionSource.ai.rawValue
                        && $0.decision == suggestion.verdict.rawValue
                }) {
                    continue
                }
                let minimum = effectiveMinimum(
                    for: suggestion.verdict, input: payload.minConfidence, policy: policy)
                guard suggestion.confidence >= minimum else {
                    skippedLowConfidence += 1
                    continue
                }

                let targetPickState: PickState = suggestion.verdict == .keep ? .picked : .rejected
                let groupId = effectiveGroupId(
                    suggestion: suggestion, variants: target.variants
                )
                for variant in target.variants {
                    let rating = min(5, max(0, variant.rating))
                    let label = CaptureOneColorLabel(rawValue: variant.colorLabel)?.rawValue ?? "None"
                    let before = snapshot(
                        pickState: pickState(from: variant.decision),
                        rating: rating,
                        colorLabel: label
                    )
                    let after = snapshot(
                        pickState: targetPickState,
                        rating: rating,
                        colorLabel: label
                    )
                    let revision = variant.revision + 1
                    try decisions.upsertState(
                        sessionId: payload.sessionId,
                        photoId: variant.photoId,
                        groupId: groupId,
                        state: CullingDecisionStateInput(
                            decision: suggestion.verdict.rawValue,
                            rating: Int64(rating),
                            colorLabel: label,
                            revision: Int64(revision),
                            source: CullingDecisionSource.ai.rawValue
                        )
                    )
                    entries.append(CullingHistoryEntry(
                        photoId: variant.photoId,
                        before: before,
                        after: after,
                        expectedRevision: variant.revision,
                        fields: [.pickState]
                    ))
                    appliedPhotos += 1
                }
                if suggestion.verdict == .keep { appliedKeep += 1 } else { appliedReject += 1 }
            }

            if !entries.isEmpty, let history {
                // 一条操作 = 本次 apply 的全部照片条目；undo 一次回退整批。
                historyOperationId = try history.append(
                    sessionId: payload.sessionId, entries: entries
                ).id
            }
        }

        return TriageApplyResult(
            appliedAssets: appliedKeep + appliedReject,
            appliedPhotos: appliedPhotos,
            appliedKeep: appliedKeep,
            appliedReject: appliedReject,
            skippedManual: skippedManual,
            skippedLowConfidence: skippedLowConfidence,
            skippedMissing: skippedMissing,
            skippedConflict: skippedConflict,
            historyOperationId: historyOperationId
        )
    }

    // MARK: - 映射/工具

    private func mapCandidate(_ record: TriageCandidateRecord) -> TriageCandidate {
        let groups: [TriageGroupRef] = record.groups.compactMap { group in
            guard let kind = groupKind(group.kind) else { return nil }
            return TriageGroupRef(
                kind: kind,
                groupId: group.groupId,
                memberPhotoIds: group.memberPhotoIds,
                leadPhotoId: group.leadPhotoId
            )
        }
        return TriageCandidate(
            photoId: record.photoId,
            quality: record.quality,
            modelReview: record.modelReview,
            faceCount: record.faceCount,
            maxFaceAreaRatio: record.maxFaceAreaRatio,
            groups: groups,
            manualDecision: record.manualDecision.flatMap(CullingDecisionValue.init(rawValue:)),
            decisionSource: record.decisionSource.flatMap(CullingDecisionSource.init(rawValue:)),
            importOrder: record.importOrder,
            width: record.width,
            height: record.height,
            fileSize: record.fileSize
        )
    }

    private func groupKind(_ raw: String) -> TriageGroupRef.Kind? {
        switch raw {
        case "similarity": .similarity
        case "exact": .exactDuplicate
        case "visual": .visualDuplicate
        case "burst": .burst
        case "scene": .scene
        default: nil
        }
    }

    private func pickState(from decision: String) -> PickState {
        switch decision {
        case CullingDecisionValue.keep.rawValue: .picked
        case CullingDecisionValue.reject.rawValue: .rejected
        default: .unreviewed
        }
    }

    private func snapshot(
        pickState: PickState,
        rating: Int,
        colorLabel: String
    ) -> CullingStateSnapshot {
        CullingStateSnapshot(
            pickState: pickState,
            rating: Double(rating),
            colorLabel: CaptureOneColorLabel(rawValue: colorLabel) ?? .none
        )
    }

    private func effectiveMinimum(
        for verdict: TriageVerdict, input: Double?, policy: TriagePolicy
    ) -> Double {
        // 唯一门限：方向下限与全局可执行下限取大者（与评估器同一函数）。
        let floor = policy.executionFloor(for: verdict)
        return max(floor, input ?? floor)
    }

    private func effectiveGroupId(
        suggestion: TriageSuggestion,
        variants: [TriageVariantRecord]
    ) -> String {
        if let groupId = suggestion.groupId, !groupId.isEmpty { return groupId }
        if let existing = variants.first(where: { !$0.groupId.isEmpty })?.groupId {
            return existing
        }
        return "ungrouped"
    }

    private func thresholdsDigest(for policy: TriagePolicy) -> String {
        [
            String(format: "%.4f", policy.keepScoreMin),
            String(format: "%.4f", policy.groupKeepMargin),
            String(format: "%.4f", policy.groupRejectMargin),
            String(format: "%.4f", policy.tieEpsilon),
            String(format: "%.4f", policy.blurSharpnessMax),
            String(format: "%.4f", policy.exposureMin),
            String(format: "%.4f", policy.closedEyeSuspectMin),
            String(format: "%.4f", policy.eyeOpenMin),
            String(format: "%.4f", policy.faceFocusMin),
            String(format: "%.4f", policy.facePrimaryAreaMin),
            String(format: "%.4f", policy.faceSmallAreaMax),
            "\(policy.multiFaceCount)",
            String(format: "%.4f", policy.keepConfidenceMin),
            String(format: "%.4f", policy.rejectConfidenceMin),
            String(format: "%.4f", policy.minExecutableConfidence),
            "\(policy.maxReasons)",
            // 开关本身就是判据的一部分：关掉模型信号必须让旧建议变 stale。
            policy.usesModelSignals ? "model:1" : "model:0",
        ].joined(separator: ",")
    }

    public static func defaultNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
