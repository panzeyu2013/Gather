// desktop/native/gather-app/Sources/GatherUI/SemanticSearch/SemanticSearchSheetModel.swift
// Wave2 / task-14：场景/事件标签的检索与写回（语义检索 labels 分支 + 多选相似 + 标签→关键词）。
//
// 产品边界（ROADMAP §七）：**不做**自然语言/CLIP 文搜；这里是"Vision 标签的词面
// 检索"（英文标签 + UI 本地化映射）与"多选平均向量找同类"，两条都不需要新模型资产。
import Foundation
import Observation
import GatherProtocol

@MainActor
@Observable
final class SemanticSearchSheetModel {
    enum Mode: String, CaseIterable, Identifiable {
        case similar
        case labels
        var id: String { rawValue }
    }

    /// 待确认的写回动作（破坏性：写 XMP 关键词 / 撤销同批关键词）。
    enum WritebackAction: String, Identifiable {
        case write
        case undo
        var id: String { rawValue }
    }

    let api: any PhotoAPI
    let sessionId: String
    /// 相似检索的种子集合（挑片页多选；单张时只有一个元素）。
    let seedPhotoIds: [String]

    var mode: Mode = .similar
    var labelQuery = ""
    var hits: [SemanticSearchHitSnapshot] = []
    var plan: SemanticKeywordPlan?
    var isBusy = false
    var error: (any Error)?
    var notice: String?
    /// 写回后建议的撤销入口是否可用（有写入才显示）。
    var canUndoWriteback = false

    init(api: any PhotoAPI, sessionId: String, seedPhotoIds: [String]) {
        self.api = api
        self.sessionId = sessionId
        self.seedPhotoIds = seedPhotoIds
    }

    /// 标签检索词（逗号/空白分隔；Vision 标签是英文原串，UI 直接展示匹配到的标签）。
    var labelKeywords: [String] {
        labelQuery
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var hasMultipleSeeds: Bool { seedPhotoIds.count > 1 }

    func loadSimilar(l10n: L10n) async {
        guard !seedPhotoIds.isEmpty else {
            hits = []
            notice = l10n("先在网格里选中照片（可多选）再找相似")
            return
        }
        await run {
            let outcome = try await self.api.semanticSearch(SemanticSearchQuery(
                sessionId: self.sessionId,
                photoIds: self.seedPhotoIds,
                minSimilarity: 0.82))
            self.hits = outcome.hits
            self.notice = outcome.hits.isEmpty
                ? (outcome.unavailableReason ?? l10n("没有足够相似的已分析照片"))
                : nil
        }
    }

    func searchLabels(l10n: L10n) async {
        let keywords = labelKeywords
        guard !keywords.isEmpty else {
            hits = []
            notice = l10n("输入标签再检索（例如 beach、wedding、indoor）")
            return
        }
        await run {
            let outcome = try await self.api.semanticSearch(SemanticSearchQuery(
                sessionId: self.sessionId, labels: keywords))
            self.hits = outcome.hits
            self.notice = outcome.hits.isEmpty
                ? (outcome.unavailableReason ?? l10n("没有命中这些标签的照片"))
                : nil
        }
    }

    /// 预览写回：会新增多少个关键词、多少张照片已经具备（幂等）。
    func previewWriteback(l10n: L10n) async {
        await run {
            let plan = try await self.api.semanticKeywordPlan(
                SemanticKeywordPlanInput(sessionId: self.sessionId))
            self.plan = plan
            if let unavailable = plan.unavailableReason {
                self.notice = unavailable
            } else if plan.totalAdditions == 0 {
                self.notice = l10n("没有需要新增的关键词（已全部写过，幂等）")
            } else {
                self.notice = l10n.format(
                    "将新增 %lld 个关键词，覆盖 %lld 张照片",
                    Int64(plan.totalAdditions), Int64(plan.photosWithLabels))
            }
        }
    }

    /// 写回/撤销（调用方已确认；Confirmed 在调用点构造，API 不得自己补确认）。
    func applyWriteback(_ action: WritebackAction, l10n: L10n) async {
        await run {
            let input = Confirmed(SemanticKeywordApplyInput(
                sessionId: self.sessionId,
                remove: action == .undo))
            let result = try await self.api.applySemanticKeywords(input)
            // 写回/撤销改的是关键词数据：发 metadata 域事件让已挂载页刷新。
            GatherEventCenter.postDomainChange(.metadata, sessionId: self.sessionId)
            self.canUndoWriteback = result.keywordsAdded > 0 || result.keywordsRemoved > 0
            if action == .undo {
                self.notice = l10n.format(
                    "已撤销 %lld 个场景关键词", Int64(result.keywordsRemoved))
            } else if result.failedPhotoIds.isEmpty {
                self.notice = l10n.format(
                    "已写回 %lld 个关键词（%lld 张）",
                    Int64(result.keywordsAdded), Int64(result.appliedPhotos))
            } else {
                self.notice = l10n.format(
                    "已写回 %lld 个关键词（%lld 张，%lld 张失败）",
                    Int64(result.keywordsAdded), Int64(result.appliedPhotos),
                    Int64(result.failedPhotoIds.count))
            }
            // 写回后刷新计划：第二次预览的 totalAdditions 应为 0（幂等的 UI 证据）。
            if let refreshed = try? await self.api.semanticKeywordPlan(
                SemanticKeywordPlanInput(sessionId: self.sessionId)) {
                self.plan = refreshed
            }
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await body()
        } catch {
            self.error = error
        }
    }
}
