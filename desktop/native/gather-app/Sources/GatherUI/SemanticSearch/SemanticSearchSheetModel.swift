// desktop/native/gather-app/Sources/GatherUI/SemanticSearch/SemanticSearchSheetModel.swift
// Wave2 / task-14：场景/事件标签的检索与写回（语义检索 labels 分支 + 多选相似 + 标签→关键词）。
//
// 产品边界（ROADMAP §七）：**不做**自然语言/CLIP 文搜；这里是"Vision 标签的词面
// 检索"（英文标签 + UI 本地化映射）与"多选平均向量找同类"，两条都不需要新模型资产。
//
// Wave5 batch7：中文输入/显示走 SemanticLabelCatalog（中文→英文标签再检索；
// 结果与写回预览显示中文名）；检索参数与写回路径始终英文（可逆）。
//
// Wave4c / task-50：撤销 scope（上次写回的 appliedPhotoIds）落会话级 JSON 文件
// （见 SemanticKeywordBatchStore.swift），面板重开/App 重启后仍可撤销上一次写回。
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

    /// 中文输入 → 英文检索标签的可见映射（输入框提示用：海滩 → beach）。
    struct LabelMapping: Equatable, Identifiable {
        let input: String
        let english: String
        var id: String { input + "->" + english }
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
    /// 上一次"写回"实际落到的照片 id（服务端返回，E2）：撤销时作为 photoIds 回传，
    /// 让"撤销本批"只清本批写过的照片，而不是整个会话的 AI 场景子树。
    private(set) var lastWriteScopePhotoIds: [String] = []
    /// 上一次写回批次的持久化保存时间（Wave4c：从磁盘加载时来自记录；nil = 没写过）。
    private(set) var lastBatchSavedAt: String?
    /// 撤销 scope 的会话级持久化（重开面板 / 重启 App 后仍可撤销上一次写回）。
    let batchStore: any SemanticKeywordBatchStoring
    private let timestamp: () -> String

    init(
        api: any PhotoAPI,
        sessionId: String,
        seedPhotoIds: [String],
        batchStore: (any SemanticKeywordBatchStoring)? = nil,
        timestamp: @escaping () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.api = api
        self.sessionId = sessionId
        self.seedPhotoIds = seedPhotoIds
        self.batchStore = batchStore ?? FileSemanticKeywordBatchStore()
        self.timestamp = timestamp
        // 启动即恢复上一次写回批次：面板重开/App 重启后"撤销"入口仍可用。
        if let record = self.batchStore.load(sessionId: sessionId), !record.photoIds.isEmpty {
            self.lastWriteScopePhotoIds = record.photoIds
            self.canUndoWriteback = true
            self.lastBatchSavedAt = record.savedAt
        }
    }

    /// 用户原始输入词（中文/英文；逗号/空白分隔）。
    var labelQueryTerms: [String] {
        labelQuery
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 检索参数：中文经 catalog 反向映射成英文标签，再交给既有 labels 检索。
    /// 英文原样；目录未收录的中文原样透传（结果为空时由 notice 引导）。
    var labelKeywords: [String] {
        SemanticLabelCatalog.englishLabels(for: labelQueryTerms)
    }

    /// 已识别的中文→英文映射（输入框下方的可见提示；未识别中文不在此列）。
    var labelMappings: [LabelMapping] {
        labelQueryTerms.compactMap { term in
            guard SemanticLabelCatalog.containsChinese(term) else { return nil }
            let mapped = SemanticLabelCatalog.englishLabels(for: term)
            let mappedLowercased = mapped.map { $0.lowercased() }
            guard !mapped.isEmpty,
                  mappedLowercased != [SemanticLabelCatalog.normalize(term)] else {
                return nil
            }
            return LabelMapping(input: term, english: mapped.joined(separator: "/"))
        }
    }

    /// 目录无法映射的中文词（检索为空时提示换英文/常见中文名）。
    var unmappedChineseTerms: [String] {
        labelQueryTerms.filter {
            SemanticLabelCatalog.containsChinese($0) && !SemanticLabelCatalog.isKnown($0)
        }
    }

    /// 命中标签的显示名（中文优先；未收录回落英文原串）。
    func displayLabels(_ labels: [String]) -> [String] {
        SemanticLabelCatalog.displayList(labels)
    }

    func displayText(_ labels: [String]) -> String {
        displayLabels(labels).joined(separator: " · ")
    }

    /// 写回预览中的一条关键词：path 仍是英文（AI|场景|beach），displayName 只用于界面。
    struct PlannedKeyword: Identifiable, Equatable {
        let path: String
        let englishLabel: String
        let displayName: String
        var id: String { path }
    }

    /// 计划明细里的关键词（去重、保留置信度顺序）；路径不翻译，只给展示名。
    var plannedKeywords: [PlannedKeyword] {
        guard let plan else { return [] }
        var seen = Set<String>()
        var result: [PlannedKeyword] = []
        for item in plan.items {
            for path in item.keywords where seen.insert(path).inserted {
                let english = SemanticLabelCatalog.labelSegment(of: path) ?? path
                result.append(PlannedKeyword(
                    path: path,
                    englishLabel: english,
                    displayName: SemanticLabelCatalog.displayName(for: english)))
            }
        }
        return result
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
        // 中文输入先经 catalog 映射成英文标签（落盘/检索参数始终英文）。
        let keywords = labelKeywords
        guard !keywords.isEmpty else {
            hits = []
            notice = l10n("输入标签再检索（中文或英文均可，例如 海滩、wedding）")
            return
        }
        let unmapped = unmappedChineseTerms
        await run {
            let outcome = try await self.api.semanticSearch(SemanticSearchQuery(
                sessionId: self.sessionId, labels: keywords))
            self.hits = outcome.hits
            if !outcome.hits.isEmpty {
                self.notice = nil
                return
            }
            if let unavailable = outcome.unavailableReason {
                self.notice = unavailable
            } else if !unmapped.isEmpty {
                // 未收录中文不能静默空结果：明确引导换英文/常见中文名。
                self.notice = l10n.format(
                    "没有命中这些标签的照片；中文「%@」暂无映射，可换用英文或常见中文名（如 海滩、婚礼）。",
                    unmapped.joined(separator: "、"))
            } else {
                self.notice = l10n("没有命中这些标签的照片")
            }
        }
    }

    /// 计划请求统一带"明细上限"（Wave4b）：计数全量、明细前 N 张，避免大会话
    /// 一次 IPC 传递上万条 item。写回/撤销后刷新计划同样走这里。
    private func planInput() -> SemanticKeywordPlanInput {
        SemanticKeywordPlanInput(
            sessionId: sessionId, maxItems: SemanticKeywordPath.maxDisplayedPlanItems)
    }

    /// 预览写回：会新增多少个关键词、多少张照片已经具备（幂等）。
    func previewWriteback(l10n: L10n) async {
        await run {
            let plan = try await self.api.semanticKeywordPlan(self.planInput())
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
    ///
    /// 写回 = 会话范围（与预览一致）；撤销 = **上一次写回实际改动的照片集合**（服务端回传
    /// `appliedPhotoIds`），不再清整个会话的 root 子树（E2 破坏性误删修复）。
    func applyWriteback(_ action: WritebackAction, l10n: L10n) async {
        let undoScope = lastWriteScopePhotoIds
        if action == .undo && undoScope.isEmpty {
            notice = l10n("没有可撤销的写回批次（先写回一次）。")
            return
        }
        await run {
            var applyInput = SemanticKeywordApplyInput(
                sessionId: self.sessionId,
                remove: action == .undo)
            if action == .undo {
                applyInput.photoIds = undoScope
            }
            let result = try await self.api.applySemanticKeywords(Confirmed(applyInput))
            // 写回/撤销改的是关键词数据：发 metadata 域事件让已挂载页刷新。
            GatherEventCenter.postDomainChange(.metadata, sessionId: self.sessionId)
            // Wave4b：场景标签→关键词也改挑片/图库可见信息（facet、检查器标签），
            // 一并广播 culling 域（否则已挂载页停留在旧关键词）。
            GatherEventCenter.postDomainChange(
                .culling, sessionId: self.sessionId, origin: "semantic-keywords")
            if action == .undo {
                self.lastWriteScopePhotoIds = []
                self.lastBatchSavedAt = nil
                self.canUndoWriteback = false
                // 撤销成功（或本批已无可移除词）：持久化批次一并清掉，避免旧入口复活。
                self.batchStore.clear(sessionId: self.sessionId)
                self.notice = l10n.format(
                    "已撤销 %lld 个场景关键词", Int64(result.keywordsRemoved))
            } else if !result.appliedPhotoIds.isEmpty {
                // 只有真正写到了照片才更新"上一次写回"：空写不能覆盖上一批的撤销入口。
                self.lastWriteScopePhotoIds = result.appliedPhotoIds
                self.canUndoWriteback = true
                let record = SemanticKeywordBatchRecord(
                    photoIds: result.appliedPhotoIds,
                    batchId: result.batchId,
                    savedAt: self.timestamp(),
                    keywordsAdded: result.keywordsAdded,
                    keywordsRemoved: 0)
                self.batchStore.save(record, sessionId: self.sessionId)
                self.lastBatchSavedAt = record.savedAt
            }
            if action == .write {
                if result.failedPhotoIds.isEmpty {
                    self.notice = l10n.format(
                        "已写回 %lld 个关键词（%lld 张）",
                        Int64(result.keywordsAdded), Int64(result.appliedPhotos))
                } else {
                    self.notice = l10n.format(
                        "已写回 %lld 个关键词（%lld 张，%lld 张失败）",
                        Int64(result.keywordsAdded), Int64(result.appliedPhotos),
                        Int64(result.failedPhotoIds.count))
                }
            }
            // 写回后刷新计划：第二次预览的 totalAdditions 应为 0（幂等的 UI 证据）。
            if let refreshed = try? await self.api.semanticKeywordPlan(self.planInput()) {
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
