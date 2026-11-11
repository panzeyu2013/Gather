// desktop/native/gather-core/Sources/GatherProtocol/API/PhotoAPI.swift
// Cut 1 / 阶段 1A：照片域协议（9 个方法；P2-2 追加 select；P1 下一波追加 4 个查询面方法）。
//
// 职责：照片分页、查询 DSL、建议、派生媒体（尺寸/缩略图/预览）；
// P1 下一波 §3.7.3 起还承载 Gallery 的保存查询（savedSearches/saveSearch/
// deleteSavedSearch/count），不新开协议域（父 agent 决策：PhotoAPI 已注册在组合根）。
// 对应命令（9 条）：photo.list_page、filter.photos + filter.photos_global（M3 合并）、
// filter.suggest、image.get_dimensions（单形态）、image.prioritize_thumbnail /
// preload_thumbnails / preload_previews。
// 校验归属：
// - 分页/排序/关键词的形状校验在输入类型；
// - 路径授权：实现必须经 pathPolicy.containsFilepath 过滤后才能触碰文件系统，
//   未登记路径转 PHOTO_NOT_FOUND 语义错误（D-010 后使用新增码）；
// - 查询字段/操作符的合法性仍由 FilterEngine（FILTER_* 码）负责；
// - 缩略图 job 的建 job 细节由实现调用 JobService 完成。

import Foundation

public protocol PhotoAPI: Sendable {
    /// 路径授权策略（image.* 的 P/A 校验归属）。
    var pathPolicy: any PhotoPathPolicy { get }

    /// photo.list_page
    ///
    /// P1 下一波 §3.7.1：入参可带 criteria（服务端筛选）+ sortBy/sortOrder；
    /// 游标语义不变（仍是资产组首行 rowid），criteria 只多一个 AND。
    func page(_ query: PhotoPageQuery) async throws -> PhotoPage

    /// filter.photos / filter.photos_global（M3：sessionId == nil 即全局）
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult

    /// P2-2：按当前图库搜索/筛选取完整 ID 集（20k 上限 + hash），供 ⌘A。
    func select(_ query: PhotoSelectionQuery) async throws -> PhotoSelectionIds

    /// filter.suggest
    func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion]

    /// P1 / C：facet 计数（每维独立 COUNT，已按该维剔除自身条件）。
    /// P1 下一波 §3.6.4：keyword 维按逻辑资产去重计数，keywordPrefix 支持下钻。
    func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup]

    /// image.get_dimensions（单路径 = paths 只有一个元素）
    func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions]

    /// image.prioritize_thumbnail
    func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws

    /// image.preload_thumbnails；paths 为空返回 nil（无需建 job）
    func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle?

    /// image.preload_previews
    func preloadPreviews(_ input: PreviewPreloadInput) async throws

    // MARK: - P1 下一波 §3.7.3：保存查询（Gallery / Library 共用）

    /// 作用域内的保存查询列表：全局（session_id IS NULL）+ 该会话的，按 updated_at 倒序。
    /// sessionId == nil 时只返回全局。
    func savedSearches(_ query: SavedSearchesQuery) async throws -> [SavedSearchData]

    /// 保存/覆盖（同作用域同名 = 更新原行）；上限由 gallery_saved_search_limit 决定。
    func saveSearch(_ input: SaveSearchInput) async throws -> SavedSearchData

    /// 删除（按 id；不存在 = INVALID_PARAM，不静默成功）。
    func deleteSavedSearch(_ input: DeleteSavedSearchInput) async throws

    /// 计数（与 search.total 同口径，但不带分页；一次 COUNT）。
    func count(_ input: SearchCountInput) async throws -> Int

    /// P1：语义检索（photoId = 单张相似；photoIds = 多选平均向量；labels = 标签检索）。
    func semanticSearch(_ query: SemanticSearchQuery) async throws -> SemanticSearchOutcomeSnapshot

    // MARK: - Wave2 / task-14：场景标签写回关键词

    /// 只读预览：标签会变成哪些关键词、哪些已存在（幂等判定），不写盘。
    func semanticKeywordPlan(_ input: SemanticKeywordPlanInput) async throws -> SemanticKeywordPlan

    /// 写回/撤销场景标签关键词。破坏性（改 XMP 关键词）→ Confirmed 门禁；
    /// remove=true 撤销同一批（移除 root 子树关键词，保留其它来源关键词）。
    func applySemanticKeywords(
        _ input: Confirmed<SemanticKeywordApplyInput>
    ) async throws -> SemanticKeywordApplyResult
}

// MARK: - 默认实现（P1 下一波）
//
// 为什么给默认实现：PhotoAPI 有多个测试/预览桩（StubPhotoAPI、PreviewAPIs、
// GatherAppTests 的 fake），新增 4 个 requirement 会让它们全部编译失败。默认实现
// 让旧桩保持可用，同时**不静默装作成功**：写操作显式失败（错误码不新增，用
// INVALID_PARAM），查询返回空。生产实现（LivePhotoAPI）全部覆写。
public extension PhotoAPI {
    func savedSearches(_ query: SavedSearchesQuery) async throws -> [SavedSearchData] { [] }

    func saveSearch(_ input: SaveSearchInput) async throws -> SavedSearchData {
        throw GatherError.invalidParameter(
            field: "name", reason: "saved searches are not available in this build")
    }

    func deleteSavedSearch(_ input: DeleteSavedSearchInput) async throws {
        throw GatherError.invalidParameter(
            field: "id", reason: "saved searches are not available in this build")
    }

    /// 默认实现退回 search().total：语义相同（同一套 COUNT），只是多一次投影；
    /// 生产实现直接走 countGlobally，不做无用的行投影。
    func count(_ input: SearchCountInput) async throws -> Int {
        try await search(PhotoQuery(criteria: input.criteria, sessionId: input.sessionId)).total
    }

    /// 未接线（Preview/测试替身）：空结果 + 明确原因，不伪造命中。
    func semanticSearch(_ query: SemanticSearchQuery) async throws -> SemanticSearchOutcomeSnapshot {
        SemanticSearchOutcomeSnapshot(
            sessionId: query.sessionId, method: "unavailable", hits: [],
            scanned: 0, skipped: 0,
            unavailableReason: "语义索引未接线")
    }

    /// 未接线（Preview/测试替身）：不伪造计划。
    func semanticKeywordPlan(_ input: SemanticKeywordPlanInput) async throws -> SemanticKeywordPlan {
        SemanticKeywordPlan(
            sessionId: input.sessionId, root: input.root, items: [],
            photosWithLabels: 0, photosWithoutLabels: 0, totalAdditions: 0,
            unavailableReason: "场景标签写回未接线")
    }

    /// 未接线（Preview/测试替身）：显式失败，不静默成功。
    func applySemanticKeywords(
        _ input: Confirmed<SemanticKeywordApplyInput>
    ) async throws -> SemanticKeywordApplyResult {
        throw GatherError.invalidParameter(
            field: "sessionId", reason: "semantic keyword writeback is not available in this build")
    }
}
