// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriageEvaluator.swift
// P0 / T0：纯函数初筛器。无 I/O、无随机、同输入同输出。
//
// 规则顺序见 docs/design/p0/t0-triage-policy.md §3.2：
//   P0 人工排除 → P1 未分析/失败 → P2 无替代 → P3 exact 重复
//   → P4 硬技术失败 → P5 组内最佳 → P6 明确较弱 → P7 并列/接近
//   → P8 兜底 → P9 review
// 组源优先级 exact > similarity > visual duplicate > burst/scene；
// 每张照片只选一个组。质量分不读 relativeRank，由本函数自行排名。
import Foundation
import GatherProtocol

public struct TriageGroupRef: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case similarity
        case exactDuplicate
        case visualDuplicate
        case burst
        case scene
    }

    public var kind: Kind
    public var groupId: String
    public var memberPhotoIds: [String]
    public var leadPhotoId: String?

    public init(
        kind: Kind,
        groupId: String,
        memberPhotoIds: [String],
        leadPhotoId: String? = nil
    ) {
        self.kind = kind
        self.groupId = groupId
        self.memberPhotoIds = memberPhotoIds
        self.leadPhotoId = leadPhotoId
    }
}

public struct TriageCandidate: Equatable, Sendable {
    public var photoId: String
    public var quality: QualityResult?
    /// 模型级信号（analysis_type = model_review）；nil = 该照片还没跑模型或旧数据。
    /// 为 nil 时评估器完全退回 v1 的像素代理信号（行为不变）。
    public var modelReview: ModelReviewResult?
    public var faceCount: Int
    public var maxFaceAreaRatio: Double
    public var groups: [TriageGroupRef]
    public var manualDecision: CullingDecisionValue?
    public var decisionSource: CullingDecisionSource?
    /// 导入序（越小越早），用于并列决胜。
    public var importOrder: Int
    /// exact 重复的“最佳”判据：先比像素总数，再比文件字节数（设计 §5.3）。
    public var width: Int
    public var height: Int
    public var fileSize: Int64

    public init(
        photoId: String,
        quality: QualityResult?,
        modelReview: ModelReviewResult? = nil,
        faceCount: Int = 0,
        maxFaceAreaRatio: Double = 0,
        groups: [TriageGroupRef] = [],
        manualDecision: CullingDecisionValue? = nil,
        decisionSource: CullingDecisionSource? = nil,
        importOrder: Int = 0,
        width: Int = 0,
        height: Int = 0,
        fileSize: Int64 = 0
    ) {
        self.photoId = photoId
        self.quality = quality
        self.modelReview = modelReview
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

    /// exact 重复组内的“最佳”比较键：分辨率 → 文件大小 → 导入序 → photoId。
    /// 只在 exact 组使用（同样的画面数据，保留更完整的一份）。
    var exactBestKey: (pixels: Int, fileSize: Int64, importOrder: Int) {
        (width * height, fileSize, importOrder)
    }
}

public struct TriageResult: Equatable, Sendable {
    public var photoId: String
    public var verdict: TriageVerdict
    public var score: Double
    public var confidence: Double
    public var reasons: [TriageReason]
    public var groupId: String?

    public init(
        photoId: String,
        verdict: TriageVerdict,
        score: Double,
        confidence: Double,
        reasons: [TriageReason],
        groupId: String?
    ) {
        self.photoId = photoId
        self.verdict = verdict
        self.score = score
        self.confidence = confidence
        self.reasons = reasons
        self.groupId = groupId
    }
}

public enum TriageEvaluation: Equatable, Sendable {
    case suggestion(TriageResult)
    case excluded(TriageReasonCode)
}

// MARK: - 纯函数入口

public func evaluateTriage(
    candidates: [TriageCandidate],
    policy: TriagePolicy = .v1
) -> [TriageEvaluation] {
    let contexts = buildContexts(candidates: candidates, policy: policy)
    return candidates.map { candidate in
        let evaluation = evaluate(candidate: candidate, contexts: contexts, policy: policy)
        guard case .suggestion(var result) = evaluation,
              let groupId = result.groupId,
              contexts[groupId]?.ref.kind == .visualDuplicate,
              !result.reasons.contains(where: { $0.code == .duplicateVisual })
        else { return evaluation }
        // P2：visual duplicate 与 similarity 共用判定，靠理由码区分证据来源。
        result.reasons = reasonList(
            result.reasons.map { ($0.code, $0.value) } + [(.duplicateVisual, nil)],
            policy: policy
        )
        return .suggestion(result)
    }
}

// MARK: - 组上下文（预计算，避免组内 O(n²)）

private struct GroupSeed {
    var kind: TriageGroupRef.Kind
    var memberIds: Set<String>
    var leadPhotoId: String?
}

private struct GroupContext {
    let ref: TriageGroupRef
    let members: [TriageCandidate]
    let analyzed: [TriageCandidate]
    let rankById: [String: Int]
    let bestId: String?
    let bestScore: Double
    let secondScore: Double?
}

private func groupPriority(_ kind: TriageGroupRef.Kind) -> Int {
    switch kind {
    case .exactDuplicate: return 0
    case .similarity: return 1
    case .visualDuplicate: return 2
    case .burst: return 3
    case .scene: return 4
    }
}

private func buildContexts(
    candidates: [TriageCandidate],
    policy: TriagePolicy
) -> [String: GroupContext] {
    let byId = Dictionary(
        candidates.map { ($0.photoId, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    var seeds: [String: GroupSeed] = [:]
    for candidate in candidates {
        for ref in candidate.groups {
            var seed = seeds[ref.groupId] ?? GroupSeed(
                kind: ref.kind,
                memberIds: [],
                leadPhotoId: ref.leadPhotoId
            )
            if groupPriority(ref.kind) < groupPriority(seed.kind) {
                seed.kind = ref.kind
            }
            seed.memberIds.formUnion(ref.memberPhotoIds)
            seed.memberIds.insert(candidate.photoId)
            if seed.leadPhotoId == nil {
                seed.leadPhotoId = ref.leadPhotoId
            }
            seeds[ref.groupId] = seed
        }
    }

    var contexts: [String: GroupContext] = [:]
    for (groupId, seed) in seeds {
        let members = seed.memberIds
            .compactMap { byId[$0] }
        guard !members.isEmpty else { continue }
        // 人工淘汰的成员不能再占“组内最佳/合格替代”的位置：否则人工淘汰最佳后，
        // 其余成员会以那张已淘汰照片为锚点被判 reject（整组误杀）。
        // 工具图（截图/扫描/文字）不参与组内比较：否则它凭超高锐度占住「最佳」，
        // 随后自己早退 reject，真实照片却因此被判非最佳 → 整组误杀。
        let eligible = members.filter { !isManualReject($0) && !isUtilityImage($0, policy: policy) }

        let ref = TriageGroupRef(
            kind: seed.kind,
            groupId: groupId,
            memberPhotoIds: members.map(\.photoId).sorted(),
            leadPhotoId: seed.leadPhotoId
        )

        if seed.kind == .exactDuplicate {
            // 设计 §5.3：分辨率 → 文件大小 → 导入序 → photoId。
            let sorted = eligible.sorted {
                let left = $0.exactBestKey
                let right = $1.exactBestKey
                if left.pixels != right.pixels { return left.pixels > right.pixels }
                if left.fileSize != right.fileSize { return left.fileSize > right.fileSize }
                if left.importOrder != right.importOrder { return left.importOrder < right.importOrder }
                return $0.photoId < $1.photoId
            }
            // 最佳必须在“已分析”成员里选：否则分辨率最高但无质量行的那一张会占住
            // best，把唯一已分析的副本按 non-best 判成 reject（宁可漏杀）。
            let analyzed = sorted.filter { $0.quality?.status == .succeeded }
            let best = analyzed.first ?? sorted.first
            contexts[groupId] = GroupContext(
                ref: ref,
                members: sorted,
                analyzed: analyzed,
                rankById: [:],
                bestId: best?.photoId,
                bestScore: best?.quality?.qualityScore ?? 0,
                secondScore: nil
            )
            continue
        }

        let analyzed = eligible
            .filter { $0.quality?.status == .succeeded }
            .sorted { lhs, rhs in
                let ls = lhs.quality?.qualityScore ?? 0
                let rs = rhs.quality?.qualityScore ?? 0
                if ls != rs { return ls > rs }
                // v2：同分时先比模型信号（采集质量 → 微笑），再比 lead/导入序。
                let lk = tieBreakKey(lhs, policy: policy)
                let rk = tieBreakKey(rhs, policy: policy)
                if lk.0 != rk.0 { return lk.0 > rk.0 }
                if lk.1 != rk.1 { return lk.1 > rk.1 }
                let lhsLead = lhs.photoId == seed.leadPhotoId
                let rhsLead = rhs.photoId == seed.leadPhotoId
                if lhsLead != rhsLead { return lhsLead }
                if lhs.importOrder != rhs.importOrder { return lhs.importOrder < rhs.importOrder }
                return lhs.photoId < rhs.photoId
            }

        var rankById: [String: Int] = [:]
        for (index, candidate) in analyzed.enumerated() {
            rankById[candidate.photoId] = index + 1
        }
        // P1：只有“技术合格”的成员才能当组内最佳。否则一张高总分但明显糊/欠曝
        // 的照片会占住 best 位、把其余合格照片按“有合格替代”判成 reject。
        let qualified = analyzed.filter { isTechnicallyQualified($0, policy: policy) }
        contexts[groupId] = GroupContext(
            ref: ref,
            members: members,
            analyzed: analyzed,
            rankById: rankById,
            bestId: qualified.first?.photoId,
            bestScore: qualified.first?.quality?.qualityScore ?? 0,
            secondScore: qualified.dropFirst().first?.quality?.qualityScore
        )
    }
    return contexts
}

private func chooseContext(
    for candidate: TriageCandidate,
    contexts: [String: GroupContext]
) -> GroupContext? {
    var chosen: GroupContext?
    for ref in candidate.groups {
        guard let context = contexts[ref.groupId], context.members.count > 1 else { continue }
        if let current = chosen {
            let p1 = groupPriority(context.ref.kind)
            let p2 = groupPriority(current.ref.kind)
            if p1 < p2 || (p1 == p2 && context.ref.groupId < current.ref.groupId) {
                chosen = context
            }
        } else {
            chosen = context
        }
    }
    return chosen
}

// MARK: - 评估

private func evaluate(
    candidate: TriageCandidate,
    contexts: [String: GroupContext],
    policy: TriagePolicy
) -> TriageEvaluation {
    // P0：人工已决策（pending 不算已决策，仍可给建议）。客户校样回传同样是人的决定。
    if candidate.decisionSource?.isHumanDecision == true,
       let decision = candidate.manualDecision,
       decision != .pending {
        return .excluded(.manualOverride)
    }

    // P0.5：工具图（截图/文档）。婚礼/活动现场混进这类素材是纯噪声，
    // 即使单张也允许直接淘汰；置信度 0.90，低于门槛时仍落 review。
    if isUtilityImage(candidate, policy: policy) {
        let confidence = 0.90
        if confidence >= policy.executionFloor(for: .reject) {
            return suggestion(candidate, .reject, candidate.quality?.qualityScore ?? 0,
                              confidence, [.utilityImage], nil, policy: policy)
        }
        return suggestion(candidate, .review, candidate.quality?.qualityScore ?? 0,
                          confidence, [.utilityImage, .closeCall], nil, policy: policy)
    }

    // P1：未分析 / 分析失败。
    guard let quality = candidate.quality else {
        return suggestion(candidate, .review, 0, 0, [.qualityMissing], nil)
    }
    if quality.status == .failed {
        return suggestion(candidate, .review, 0, 0, [.analysisFailed], nil)
    }

    guard let context = chooseContext(for: candidate, contexts: contexts) else {
        return evaluateSingle(candidate, quality: quality, groupId: nil, policy: policy)
    }

    // P3：完全重复优先于相似组，且不受质量 margin 限制。
    if context.ref.kind == .exactDuplicate {
        // 完全重复的证据强度固定，但“可执行”仍必须过统一门限：
        // 用户把 minExecutable 调到 0.96 时，0.90/0.95 只能落 review。
        let isBest = context.bestId == candidate.photoId
        let confidence = isBest ? 0.90 : 0.95
        let verdict: TriageVerdict = isBest ? .keep : .reject
        if confidence < policy.executionFloor(for: verdict) {
            return suggestion(
                candidate, .review, quality.qualityScore, confidence,
                isBest ? [.duplicateExact, .groupBest, .closeCall] : [.duplicateExact, .closeCall],
                context.ref.groupId, policy: policy)
        }
        return suggestion(
            candidate, verdict, quality.qualityScore, confidence,
            isBest ? [.duplicateExact, .groupBest] : [.duplicateExact],
            context.ref.groupId, policy: policy)
    }

    // 组内可用（已分析）成员 < 2：按无替代处理。
    if context.analyzed.count < 2 {
        return evaluateSingle(candidate, quality: quality, groupId: context.ref.groupId, policy: policy)
    }

    guard let bestId = context.bestId else {
        // 组内没有任何技术合格成员：谁都不该以 keep/reject 落地（宁可漏杀）。
        return suggestion(
            candidate, .review, quality.qualityScore, 0,
            reasonList([(.lowTechnical, nil), (.noAlternative, nil)], policy: policy),
            context.ref.groupId
        )
    }
    let isBest = bestId == candidate.photoId
    // 只有一个技术合格成员时，它就是明确的组内最佳（margin 取上界）。
    let margin = context.secondScore.map { max(0, context.bestScore - $0) } ?? 1.0
    let gap = max(0, context.bestScore - quality.qualityScore)
    let hard = hasHardWarning(candidate, policy: policy)
    let closed = isClosedEye(candidate, policy: policy)
    let multiFace = isMultiFace(candidate, policy: policy)
    let smallFace = isSmallFace(candidate, policy: policy)
    let factor = faceFactor(candidate, policy: policy)
    let qualifiedAlternative = hasQualifiedAlternative(candidate, in: context, policy: policy)

    let keepAgree = keepAgreement(candidate, isBest: isBest, policy: policy)
    let cKeep = isBest
        ? groupKeepConfidence(margin: margin, agree: keepAgree, faceFactor: factor)
        : 0

    let cReject: Double
    if !isBest && qualifiedAlternative {
        let rejectAgree = rejectAgreement(candidate, gap: gap, policy: policy)
        cReject = groupRejectConfidence(
            gap: gap,
            agree: rejectAgree,
            faceFactor: factor
        )
    } else {
        cReject = 0
    }

    if isBest {
        // 闭眼优先于“最佳”：策略要求人看。
        if closed {
            return suggestion(
                candidate, .review, quality.qualityScore, cKeep,
                reasonList([.groupBest, closedEyeCode(candidate, policy: policy)], policy: policy),
                context.ref.groupId
            )
        }
        if hard {
            var items: [(TriageReasonCode, Double?)] = []
            if hasFocusProblem(candidate, policy: policy) { items.append((focusReasonCode(candidate, policy: policy), nil)) }
            if quality.exposure < policy.exposureMin { items.append((.exposureLow, nil)) }
            return suggestion(
                candidate, .review, quality.qualityScore, cKeep,
                reasonList(items, policy: policy),
                context.ref.groupId
            )
        }
        if margin < policy.tieEpsilon {
            return suggestion(
                candidate, .review, quality.qualityScore, cKeep,
                reasonList([.tieWithGroup], policy: policy),
                context.ref.groupId
            )
        }
        if margin < policy.groupKeepMargin {
            return suggestion(
                candidate, .review, quality.qualityScore, cKeep,
                reasonList([.closeCall], policy: policy),
                context.ref.groupId
            )
        }
        var items: [(TriageReasonCode, Double?)] = [(.groupBest, nil)]
        if smallFace { items.append((.smallFace, nil)) }
        let confidence = multiFace ? min(cKeep, 0.70) : cKeep
        // keep 也必须过门槛；否则交给人工，不把“最佳但证据不足”当结论。
        if confidence < policy.executionFloor(for: .keep) {
            items.append((.closeCall, nil))
            return suggestion(
                candidate, .review, quality.qualityScore, confidence,
                reasonList(items, policy: policy),
                context.ref.groupId
            )
        }
        return suggestion(
            candidate, .keep, quality.qualityScore, confidence,
            reasonList(items, policy: policy),
            context.ref.groupId
        )
    }

    // 非最佳：P4 硬技术失败（有合格替代、自身非最佳）。
    if hard && qualifiedAlternative {
        if closed {
            return suggestion(
                candidate, .review, quality.qualityScore, cReject,
                reasonList([(.weakerThanGroupBest, gap), (closedEyeCode(candidate, policy: policy), nil)], policy: policy),
                context.ref.groupId
            )
        }
        var items: [(TriageReasonCode, Double?)] = [(.weakerThanGroupBest, gap)]
        if hasFocusProblem(candidate, policy: policy) { items.append((focusReasonCode(candidate, policy: policy), nil)) }
        if quality.exposure < policy.exposureMin { items.append((.exposureLow, nil)) }
        // 硬技术失败也要过 reject 门槛；不足则复核。
        if cReject < policy.executionFloor(for: .reject) {
            items.append((.closeCall, nil))
            return suggestion(
                candidate, .review, quality.qualityScore, cReject,
                reasonList(items, policy: policy),
                context.ref.groupId
            )
        }
        return suggestion(
            candidate, .reject, quality.qualityScore, cReject,
            reasonList(items, policy: policy),
            context.ref.groupId
        )
    }

    if gap < policy.tieEpsilon {
        var items: [(TriageReasonCode, Double?)] = [(.tieWithGroup, nil)]
        if closed { items.append((closedEyeCode(candidate, policy: policy), nil)) }
        if smallFace { items.append((.smallFace, nil)) }
        if multiFace { items.append((.multiFaceLowConfidence, nil)) }
        return suggestion(
            candidate, .review, quality.qualityScore, max(cKeep, cReject),
            reasonList(items, policy: policy),
            context.ref.groupId
        )
    }

    if gap >= policy.groupRejectMargin {
        if closed {
            return suggestion(
                candidate, .review, quality.qualityScore, cReject,
                reasonList([(.weakerThanGroupBest, gap), (closedEyeCode(candidate, policy: policy), nil)], policy: policy),
                context.ref.groupId
            )
        }
        if multiFace {
            return suggestion(
                candidate, .review, quality.qualityScore, min(cReject, 0.60),
                reasonList([(.weakerThanGroupBest, gap), (.multiFaceLowConfidence, nil)], policy: policy),
                context.ref.groupId
            )
        }
        if smallFace {
            return suggestion(
                candidate, .review, quality.qualityScore, cReject,
                reasonList([.closeCall, .smallFace], policy: policy),
                context.ref.groupId
            )
        }
        if qualifiedAlternative, cReject >= policy.executionFloor(for: .reject) {
            return suggestion(
                candidate, .reject, quality.qualityScore, cReject,
                reasonList([(.weakerThanGroupBest, gap)], policy: policy),
                context.ref.groupId
            )
        }
        // review 的 confidence 仍是可执行置信度：非最佳时 cKeep=0，取 cReject；
        // 只有“确实没有合格替代”才给 noAlternative，否则是接近淘汰线的 closeCall。
        var fallbackItems: [(TriageReasonCode, Double?)] = [(.weakerThanGroupBest, gap)]
        if !qualifiedAlternative {
            fallbackItems.insert((.noAlternative, nil), at: 0)
        } else {
            fallbackItems.append((.closeCall, nil))
        }
        return suggestion(
            candidate, .review, quality.qualityScore, cReject,
            reasonList(fallbackItems, policy: policy),
            context.ref.groupId
        )
    }

    // 接近但未到淘汰线。
    if closed {
        return suggestion(
            candidate, .review, quality.qualityScore, cReject,
            reasonList([(.closeCall, nil), (.weakerThanGroupBest, gap), (closedEyeCode(candidate, policy: policy), nil)], policy: policy),
            context.ref.groupId
        )
    }
    if multiFace {
        return suggestion(
            candidate, .review, quality.qualityScore, min(cReject, 0.60),
            reasonList([(.closeCall, nil), (.weakerThanGroupBest, gap), (.multiFaceLowConfidence, nil)], policy: policy),
            context.ref.groupId
        )
    }
    if smallFace {
        return suggestion(
            candidate, .review, quality.qualityScore, cReject,
            reasonList([.closeCall, .smallFace], policy: policy),
            context.ref.groupId
        )
    }
    return suggestion(
        candidate, .review, quality.qualityScore, cReject,
        reasonList([(.closeCall, nil), (.weakerThanGroupBest, gap)], policy: policy),
        context.ref.groupId
    )
}

private func evaluateSingle(
    _ candidate: TriageCandidate,
    quality: QualityResult,
    groupId: String?,
    policy: TriagePolicy
) -> TriageEvaluation {
    let hard = hasHardWarning(candidate, policy: policy)
    let closed = isClosedEye(candidate, policy: policy)
    let smallFace = isSmallFace(candidate, policy: policy)
    let good = quality.qualityScore >= policy.keepScoreMin && !hard
    let agree = keepAgreement(candidate, isBest: true, policy: policy)
    let confidence = singleKeepConfidence(quality: quality, agree: agree, policy: policy)

    var items: [(TriageReasonCode, Double?)] = []
    if groupId != nil || !good {
        items.append((.noAlternative, nil))
    } else {
        items.append((.singleShot, nil))
    }
    if !good && !hard { items.append((.lowTechnical, nil)) }
    if hard {
        if hasFocusProblem(candidate, policy: policy) { items.append((focusReasonCode(candidate, policy: policy), nil)) }
        if quality.exposure < policy.exposureMin { items.append((.exposureLow, nil)) }
    }
    if closed { items.append((closedEyeCode(candidate, policy: policy), nil)) }
    if smallFace { items.append((.smallFace, nil)) }

    let confidentEnough = confidence >= policy.executionFloor(for: .keep)
    if good && !closed && !confidentEnough {
        items.append((.closeCall, nil))
    }
    let verdict: TriageVerdict = (good && !closed && confidentEnough) ? .keep : .review
    return suggestion(
        candidate, verdict, quality.qualityScore, confidence,
        reasonList(items, policy: policy),
        groupId
    )
}

// MARK: - 质量/人脸信号

private func clamp01(_ value: Double) -> Double {
    min(1, max(0, value))
}

private func rounded(_ value: Double) -> Double {
    (value * 1000).rounded() / 1000
}

/// 合焦分：**保持 v1 的 512px 代理量纲**，用于既有阈值（0.12/0.40）。
/// 模型的人脸合焦分是另一套量纲（拉普拉斯方差归一），只作为**额外的失焦证据**，
/// 不能直接顶替 focusScore——否则 0.12 阈值对它是失效的（大面积漏判模糊）。
private func focusScore(_ candidate: TriageCandidate) -> Double {
    guard let quality = candidate.quality else { return 0 }
    return quality.subjectSharpness ?? quality.sharpness
}

/// 模型判定主体脸失焦（独立阈值 faceFocusMin，量纲与 v1 不同）。
private func isFaceOutOfFocus(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    guard modelSignalsEnabled(policy),
          let faceFocus = candidate.modelReview?.faceFocusScore else { return false }
    return faceFocus < policy.faceFocusMin
}

/// 任一来源判定失焦：v1 代理或模型信号。
private func hasFocusProblem(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    focusScore(candidate) < policy.blurSharpnessMax || isFaceOutOfFocus(candidate, policy: policy)
}

/// 人工淘汰 = 用户（或客户校样）已明确不要这张；它不能再作为组内锚点或「合格替代」。
private func isManualReject(_ candidate: TriageCandidate) -> Bool {
    candidate.decisionSource?.isHumanDecision == true && candidate.manualDecision == .reject
}

private func hasQualifiedAlternative(
    _ candidate: TriageCandidate,
    in context: GroupContext,
    policy: TriagePolicy
) -> Bool {
    context.analyzed.contains {
        $0.photoId != candidate.photoId && isTechnicallyQualified($0, policy: policy)
    }
}

private func isTechnicallyQualified(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    guard let quality = candidate.quality else { return false }
    guard !isUtilityImage(candidate, policy: policy) else { return false }
    return !hasFocusProblem(candidate, policy: policy)
        && quality.exposure >= policy.exposureMin
}

private func hasHardWarning(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    guard let quality = candidate.quality else { return true }
    return hasFocusProblem(candidate, policy: policy)
        || quality.exposure < policy.exposureMin
}

/// 模型信号只在 triage-v2 且设置开关打开时生效：v1 必须保持既有语义（否则版本号形同虚设）。
private func modelSignalsEnabled(_ policy: TriagePolicy) -> Bool {
    policy.usesModelSignals
}

private func isClosedEye(
    _ candidate: TriageCandidate,
    policy: TriagePolicy
) -> Bool {
    // 模型信号优先：眼睛几何分是"真闭眼"，旧梯度比只是代理。
    if modelSignalsEnabled(policy), let eyesOpen = candidate.modelReview?.eyesOpenScore {
        return eyesOpen <= policy.eyeOpenMin
    }
    guard let quality = candidate.quality,
          candidate.faceCount > 0,
          candidate.maxFaceAreaRatio >= policy.facePrimaryAreaMin else { return false }
    return (quality.closedEyeRisk ?? 0) >= policy.closedEyeSuspectMin
}

/// 闭眼理由码：模型信号存在时用 eyes_closed，否则保留旧的代理码。
private func closedEyeCode(_ candidate: TriageCandidate, policy: TriagePolicy) -> TriageReasonCode {
    modelSignalsEnabled(policy) && candidate.modelReview?.eyesOpenScore != nil
        ? .eyesClosed : .closedEyeSuspect
}

/// 失焦理由码：模型判定失焦时用 face_out_of_focus，否则保留 v1 的 motion_blur。
private func focusReasonCode(_ candidate: TriageCandidate, policy: TriagePolicy) -> TriageReasonCode {
    isFaceOutOfFocus(candidate, policy: policy) ? .faceOutOfFocus : .motionBlur
}

private func isUtilityImage(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    modelSignalsEnabled(policy) && candidate.modelReview?.isUtilityImage == true
}

/// 组内并列时的模型 tie-break（采集质量 → 微笑）；无模型信号时为 -1，不改变排序。
private func tieBreakKey(
    _ candidate: TriageCandidate, policy: TriagePolicy
) -> (Double, Double) {
    guard modelSignalsEnabled(policy) else { return (-1, -1) }
    let primary = candidate.modelReview?.faces.first(where: \.isPrimary)
    return (primary?.captureQuality ?? -1, primary?.smileScore ?? -1)
}

private func isMultiFace(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    candidate.faceCount >= policy.multiFaceCount
}

private func isSmallFace(_ candidate: TriageCandidate, policy: TriagePolicy) -> Bool {
    candidate.maxFaceAreaRatio > 0
        && candidate.maxFaceAreaRatio < policy.faceSmallAreaMax
}

private func faceFactor(_ candidate: TriageCandidate, policy: TriagePolicy) -> Double {
    guard candidate.faceCount > 0, candidate.maxFaceAreaRatio > 0 else { return 0.70 }
    if candidate.maxFaceAreaRatio >= policy.facePrimaryAreaMin { return 1.00 }
    if candidate.maxFaceAreaRatio >= policy.faceSmallAreaMax { return 0.85 }
    return 0.70
}

// MARK: - 置信度

private func keepAgreement(
    _ candidate: TriageCandidate,
    isBest: Bool,
    policy: TriagePolicy
) -> Double {
    let quality = candidate.quality
    var signals: [Bool] = []
    signals.append(!hasHardWarning(candidate, policy: policy))
    signals.append(isBest)
    signals.append((quality?.qualityScore ?? 0) >= policy.keepScoreMin)
    signals.append((quality?.exposure ?? 0) >= 0.40)
    signals.append(focusScore(candidate) >= 0.40)
    let trueCount = signals.filter { $0 }.count
    return Double(trueCount + 1) / Double(signals.count + 1)
}

private func rejectAgreement(
    _ candidate: TriageCandidate,
    gap: Double,
    policy: TriagePolicy
) -> Double {
    var signals: [Bool] = []
    signals.append(hasHardWarning(candidate, policy: policy))
    signals.append(true) // 调用方保证非最佳
    signals.append(gap >= policy.groupRejectMargin)
    signals.append(false) // exact 重复在独立分支处理
    let trueCount = signals.filter { $0 }.count
    return Double(trueCount + 1) / Double(signals.count + 1)
}

private func singleKeepConfidence(
    quality: QualityResult,
    agree: Double,
    policy: TriagePolicy
) -> Double {
    let span = max(0.0001, 1 - policy.keepScoreMin)
    let m = clamp01((quality.qualityScore - policy.keepScoreMin) / span)
    return rounded(min(0.80, 0.45 + 0.30 * m + 0.10 * agree + 0.05))
}

private func groupKeepConfidence(
    margin: Double,
    agree: Double,
    faceFactor: Double
) -> Double {
    let m = clamp01(margin / 0.30)
    return rounded(clamp01(0.30 + 0.45 * m + 0.20 * agree * faceFactor + 0.05))
}

private func groupRejectConfidence(
    gap: Double,
    agree: Double,
    faceFactor: Double
) -> Double {
    // 可执行 reject 必须能过 0.75 门槛；保护型（多人脸/闭眼/小脸）在各自的
    // review 分支里再截断展示值，不能在这里把“明确较弱”永久压到 0.70。
    let m = clamp01(gap / 0.30)
    return rounded(clamp01(0.30 + 0.45 * m + 0.20 * agree * faceFactor + 0.05))
}

// MARK: - 结果/理由

private func suggestion(
    _ candidate: TriageCandidate,
    _ verdict: TriageVerdict,
    _ score: Double,
    _ confidence: Double,
    _ codes: [TriageReasonCode],
    _ groupId: String?,
    policy: TriagePolicy = .v1
) -> TriageEvaluation {
    suggestion(candidate, verdict, score, confidence, reasonList(codes, policy: policy), groupId)
}

private func suggestion(
    _ candidate: TriageCandidate,
    _ verdict: TriageVerdict,
    _ score: Double,
    _ confidence: Double,
    _ reasons: [TriageReason],
    _ groupId: String?
) -> TriageEvaluation {
    .suggestion(TriageResult(
        photoId: candidate.photoId,
        verdict: verdict,
        score: rounded(score),
        confidence: rounded(clamp01(confidence)),
        reasons: reasons,
        groupId: groupId
    ))
}

private func reasonList(
    _ items: [(TriageReasonCode, Double?)],
    policy: TriagePolicy
) -> [TriageReason] {
    var seen = Set<TriageReasonCode>()
    var unique: [(TriageReasonCode, Double?)] = []
    for item in items where seen.insert(item.0).inserted {
        unique.append(item)
    }
    unique.sort { reasonOrder($0.0) < reasonOrder($1.0) }
    return unique.prefix(policy.maxReasons).map {
        TriageReason(code: $0.0, value: $0.1.map { rounded($0) })
    }
}

private func reasonList(_ codes: [TriageReasonCode], policy: TriagePolicy) -> [TriageReason] {
    reasonList(codes.map { ($0, nil) }, policy: policy)
}

private func reasonOrder(_ code: TriageReasonCode) -> Int {
    switch code {
    case .groupBest: return 0
    case .weakerThanGroupBest: return 1
    case .motionBlur: return 2
    case .exposureLow: return 3
    case .closedEyeSuspect: return 4
    case .eyesClosed: return 4
    case .faceOutOfFocus: return 2
    case .utilityImage: return 1
    case .closeCall: return 5
    case .tieWithGroup: return 6
    case .singleShot: return 7
    case .noAlternative: return 8
    case .lowTechnical: return 9
    case .qualityMissing: return 10
    case .analysisFailed: return 11
    case .duplicateExact: return 12
    case .duplicateVisual: return 13
    case .multiFaceLowConfidence: return 14
    case .smallFace: return 15
    case .manualOverride: return 16
    }
}
