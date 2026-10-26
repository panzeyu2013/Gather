// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Triage.swift
// P0 / T0：技术质量建议的 UI 状态与动作（生成 / 应用 / 复核队列）。
//
// 边界：
//   - 建议只写 Gather 决策（服务层 source=ai），本文件不触发任何 XMP 写回；
//   - 生成/应用都必须带当前 fingerprint；stale 时禁止应用；
//   - 应用是破坏性但可撤销的动作，确认由 View 的确认 sheet 提供，VM 不伪造 Confirmed。
import Foundation
import GatherProtocol

extension CullingViewModel {
    /// 当前会话的建议摘要；未生成时为 nil（不是 0）。
    public var triageSummary: TriageSummary? { summary?.triage }

    /// 建议是否已过期（指纹/策略不一致）。
    public var isTriageStale: Bool { triageSummary?.stale == true }

    /// 可应用的 keep/reject 建议数（review 不参与）。
    public var triageApplicableCount: Int {
        guard let counts = triageSummary?.counts else { return 0 }
        return counts.keep + counts.reject
    }

    /// 已完成技术质量分析的占比（0...100）。
    /// 建议只覆盖无人工决策的逻辑资产，不能拿 suggestions.total 当分母。
    public var triageCoveragePercent: Int {
        guard let coverage = triageSummary?.counts.coverage else { return 0 }
        return min(100, max(0, Int((coverage * 100).rounded())))
    }

    public var canGenerateTriage: Bool { !isTriageBusy && !sessionId.isEmpty }

    public var canApplyTriage: Bool {
        !isTriageBusy && !isTriageStale && !triageApplied && triageApplicableCount > 0
    }

    /// 生成/重新生成建议。成功后刷新 summary 与当前页角标。
    public func generateTriage(force: Bool = false) async {
        guard canGenerateTriage else { return }
        isTriageBusy = true
        triageError = nil
        defer { isTriageBusy = false }
        do {
            let result = try await cullingAPI.generateTriage(
                TriageGenerateInput(sessionId: sessionId, force: force)
            )
            triageApplied = false
            mergeTriageSummary(result)
            notice = CullingNotice("技术质量建议已生成")
            await loadPage(reset: true)
            // 生成结果是本次请求的权威值；summary 查询可能落后一帧，回填防抖动。
            mergeTriageSummary(result)
        } catch {
            triageError = CommandError(error)
        }
    }

    /// 应用 keep/reject 建议。调用方必须已经过确认 sheet；失败时返回 nil 并保留错误。
    @discardableResult
    public func applyTriage(
        verdicts: [TriageVerdict] = [.keep, .reject],
        minConfidence: Double? = nil
    ) async -> TriageApplyResult? {
        guard canApplyTriage, let summary = triageSummary else {
            if isTriageStale {
                triageError = CommandError.localized("技术质量建议已过期，请重新生成")
            }
            return nil
        }
        isTriageBusy = true
        triageError = nil
        defer { isTriageBusy = false }
        do {
            let input = TriageApplyInput(
                sessionId: sessionId,
                verdicts: verdicts,
                minConfidence: minConfidence,
                fingerprint: summary.inputFingerprint
            )
            let result = try await cullingAPI.applyTriage(Confirmed(input))
            triageApplied = true
            triageHistoryOperationId = result.historyOperationId
            triageError = nil
            notice = CullingNotice(
                "已应用 %lld 条建议",
                params: ["\(result.appliedAssets)"]
            )
            postCullingChange()
            await loadPage(reset: true)
            return result
        } catch {
            triageError = CommandError(error)
            return nil
        }
    }

    /// 进入复核队列：只看待复核、低置信度优先、网格布局由调用方设置。
    public func showTriageReviewQueue() async {
        sortMode = .triageConfidenceAsc
        scopeMode = .filtered
        var next = FilterState()
        next.triageVerdicts = [.review]
        filterState = next
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    /// 从生成结果回填 summary（不覆盖其他 CullingSummary 字段）。
    func mergeTriageSummary(_ value: TriageSummary) {
        // 生成/应用可能发生在首帧 summary 尚未加载时；此时必须创建承载对象，
        // 否则 optional chaining 会静默丢掉本次生成结果。
        if var current = summary {
            current.triage = value
            summary = current
        } else {
            summary = CullingSummary(
                totalGroups: 0, totalPhotos: 0, kept: 0, rejected: 0,
                pending: 0, rated: 0, labeled: 0, triage: value)
        }
    }
}
