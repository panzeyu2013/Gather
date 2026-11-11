// desktop/native/gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift
// Cut 1 / B2：PhotoAPI 的 Live 实现（7 个方法）。
//
// 对应命令（9 条）：photo.list_page、filter.photos / filter.photos_global（M3 合并）、
// filter.suggest、image.prioritize_thumbnail / preload_thumbnails /
// preload_previews / get_dimensions（单形态）。
//
// 校验归属：
// - sessionId/limit/afterFirstRowid/size/maxDimension 的形状校验由输入类型完成
//   （D-012：显式抛错，不静默改默认值）；
// - 路径授权全部经 pathPolicy（PhotoRepo.containsFilepath）：单路径未登记抛
//   PHOTO_NOT_FOUND，批量路径过滤掉未登记/重复/超长项；未登记路径不触碰文件
//   系统；
// - 分页/查询字段与排序规则仍由 PhotoRepo / FilterEngine 负责，本文件不复制
//   SQL；
// - 缩略图 job 的建 job 细节复用 JobAPI.start（与旧命令面 的
//   thumbnail.build dedupeKey/checkpoint 逐字一致）。
//
// 形状说明（M3）：
// - page 逐行装配为 Protocol.PhotoData（旧 assemblePhotos 的资产分组/变体/角色/
//   人脸计数语义保留）；
// - search 统一返回 GlobalPhotoResult 投影 + total。filter.photos 的会话内
//   “逐照片”形状与 GlobalPhotoResult 不同，协议在 1A 已确定统一为全局投影；
//   sessionId == nil 时与原 filter.photos_global 完全一致，sessionId 非 nil 时
//   使用同一过滤/计数 SQL（会按逻辑资产折叠），保留旧 photos_global 的排序与
//   分页语义。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LivePhotoAPI: PhotoAPI, @unchecked Sendable {
    public let pathPolicy: any PhotoPathPolicy

    private let photoRepo: PhotoRepo
    private let assetRepo: AssetRepo
    private let faceKwService: FaceKwService
    private let filterEngine: FilterEngine
    private let imagePreloadService: ImagePreloadService
    private let settingsService: SettingsService
    private let jobAPI: any JobAPI
    /// P1 / C：facet 计数（与 filter 引擎同库；nil = 未接线，返回空面板）。
    /// P1 下一波起它还持有公开的过滤分页入口（filterQuery），网格的 criteria
    /// 分页与 facet 计数因此共用同一条 WHERE。
    private let facetQuery: FacetQuery?
    /// P1 下一波 §3.7.3：保存查询（nil = 未接线，列表空、写入显式失败）。
    private let savedSearchRepo: SavedSearchRepo?
    /// P1：语义检索（nil = 未接线，返回空结果 + 明确原因）。
    private let semanticIndex: SemanticIndex?
    /// Wave2 / task-14：场景标签 → 关键词写回（nil = 未接线：预览给原因、写回显式失败）。
    private let semanticKeywords: SemanticKeywordService?
    /// Wave5（Batch4 / task-19）：照片文件级操作（批量重命名 + 移动到文件夹）。
    ///
    /// 默认在 init 内用 photoRepo/assetRepo 组装（relocate = AssetRepo 的事务化路径迁移）；
    /// 测试可注入替身。写盘/改库的域事件与缩略图缓存失效由 UI 层成功后统一处理。
    private let fileOps: PhotoFileOpsService

    /// @unchecked Sendable 依据：全部依赖均为构造后不可变的 let；Repo/Service 的
    /// 可变状态由 DBConnection 的递归锁或各服务自己的锁保护（同组合根约定）。
    public init(
        photoRepo: PhotoRepo,
        assetRepo: AssetRepo,
        faceKwService: FaceKwService,
        filterEngine: FilterEngine,
        imagePreloadService: ImagePreloadService,
        settingsService: SettingsService,
        jobAPI: any JobAPI,
        facetQuery: FacetQuery? = nil,
        savedSearchRepo: SavedSearchRepo? = nil,
        semanticIndex: SemanticIndex? = nil,
        semanticKeywords: SemanticKeywordService? = nil,
        fileOps: PhotoFileOpsService? = nil
    ) {
        self.photoRepo = photoRepo
        self.assetRepo = assetRepo
        self.faceKwService = faceKwService
        self.filterEngine = filterEngine
        self.imagePreloadService = imagePreloadService
        self.settingsService = settingsService
        self.jobAPI = jobAPI
        self.facetQuery = facetQuery
        self.savedSearchRepo = savedSearchRepo
        self.semanticIndex = semanticIndex
        self.semanticKeywords = semanticKeywords
        self.pathPolicy = LivePhotoPathPolicy(photoRepo: photoRepo)
        self.fileOps = fileOps ?? PhotoFileOpsService(
            photoRepo: photoRepo,
            relocate: { photoId, oldPath, newPath, sharesSidecar in
                // 路径迁移与 photos.filepath / sidecar 绑定 / 交付与关键词来源
                // 在同一事务内完成（AssetRepo 内部 connection.transaction）。
                try assetRepo.relocatePhotoPathsAfterMove(
                    photoId: photoId,
                    oldPhotoPath: oldPath,
                    newPhotoPath: newPath,
                    sharesSidecar: sharesSidecar,
                    archivedAt: nil,
                    timestamp: nowISOString())
            },
            captureMetadata: LivePhotoAPI.captureMetadataReader)
    }

    /// 重命名 token 的 EXIF 来源：读盘上 DateTimeOriginal / Model。
    ///
    /// 读不到（RAW 无 EXIF 段 / 权限）返回 nil，由服务退化为文件修改时间。
    private static let captureMetadataReader: PhotoFileOpsService.CaptureMetadataReader = { path in
        let ext = (path as NSString).pathExtension.lowercased()
        let isJpeg = ext == "jpg" || ext == "jpeg"
        do {
            guard let parsed = try await ImageIOExifProvider().parse(
                filePath: path, isJpeg: isJpeg) else { return nil }
            guard case .object(let exif)? = parsed.exif else { return nil }
            let camera = exif["Model"]?.stringValue
            let rawDate = exif["DateTimeOriginal"]?.stringValue
            return PhotoCaptureMetadata(
                date: rawDate.flatMap(parseExifDate),
                cameraModel: (camera?.isEmpty ?? true) ? nil : camera)
        } catch {
            return nil
        }
    }

    /// EXIF 时间格式："2026:05:01 10:20:30"（本地时区语义）。
    private static func parseExifDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    // MARK: - PhotoAPI

    public func page(_ query: PhotoPageQuery) async throws -> PhotoPage {
        // §3.7.1：带 criteria 时走 PhotoFilterQuery 的同一条 WHERE + rowid 游标；
        // 无 criteria 保持原样（PhotoRepo.getAssetPage），两条路径的行序与游标语义一致。
        let page: (rows: [PhotoPageRow], cursor: Int64?)
        if query.hasCriteria {
            guard let facetQuery else {
                // 未接线时不能静默返回未筛选的页：UI 会显示"筛选生效"但列的是全部照片。
                throw GatherError.invalidParameter(
                    field: "criteria",
                    reason: "server-side filtering is not available in this build")
            }
            do {
                page = try facetQuery.filterQuery.assetPage(
                    sessionId: query.sessionId,
                    criteria: query.criteria,
                    afterFirstRowid: query.afterFirstRowid,
                    limit: query.limit,
                    descending: query.isDescending)
            } catch let error as PhotoFilterQueryError {
                throw Self.mappedFilterError(error)
            }
        } else {
            page = try photoRepo.getAssetPage(
                sessionId: query.sessionId,
                afterFirstRowid: query.afterFirstRowid,
                limit: query.limit)
        }
        return PhotoPage(
            rows: assemblePhotoRows(
                page.rows,
                sessionId: query.sessionId,
                expandVariants: query.expandVariants
            ),
            cursor: page.cursor
        )
    }

    public func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        let photos = try mapFilterError {
            try filterEngine.filterGlobally(
                criteria: query.criteria,
                sortBy: query.sortBy,
                sortOrder: query.sortOrder,
                limit: query.page.limit,
                offset: query.page.offset,
                sessionId: query.sessionId
            )
        }
        let total = try mapFilterError {
            try filterEngine.countGlobally(criteria: query.criteria, sessionId: query.sessionId)
        }
        return PhotoSearchResult(photos: photos, total: total)
    }

    public func select(_ query: PhotoSelectionQuery) async throws -> PhotoSelectionIds {
        var conditions: [FilterCondition] = []
        switch query.filter {
        case .all:
            break
        case .hasFace:
            conditions.append(.rule(FilterRule(field: "has_face", operator: .eq, value: .bool(true))))
        case .noFace:
            conditions.append(.rule(FilterRule(field: "has_face", operator: .eq, value: .bool(false))))
        case .offline:
            conditions.append(.rule(FilterRule(field: "status", operator: .eq, value: .string("missing"))))
        }
        if let search = query.search, !search.isEmpty {
            conditions.append(.rule(FilterRule(field: "filename", operator: .contains, value: .string(search))))
        }
        let criteria = FilterGroup(logic: .and, conditions: conditions)
        let limit = query.limit ?? 20_000
        // 一次 CTE 取代表行 id（旧实现按 500/页循环，20k=41 次全量扫描）。
        let ids = try mapFilterError {
            try filterEngine.filterGloballyIDs(
                criteria: criteria, sessionId: query.sessionId, limit: limit)
        }
        let total = try mapFilterError {
            try filterEngine.countGlobally(criteria: criteria, sessionId: query.sessionId)
        }
        let digest = SHA256.hash(Data(ids.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return PhotoSelectionIds(ids: ids, idsHash: digest, truncated: total > ids.count)
    }

    // MARK: - 保存查询（§3.7.3）

    public func savedSearches(_ query: SavedSearchesQuery) async throws -> [SavedSearchData] {
        guard let savedSearchRepo else { return [] }
        do {
            return try savedSearchRepo.list(sessionId: query.sessionId).map(Self.savedSearchData)
        } catch let error as SavedSearchRepoError {
            throw Self.mappedSavedSearchError(error)
        }
    }

    public func saveSearch(_ input: SaveSearchInput) async throws -> SavedSearchData {
        guard let savedSearchRepo else {
            throw GatherError.invalidParameter(
                field: "name", reason: "saved searches are not available in this build")
        }
        do {
            // 上限只挡"新增"：同名覆盖在 UI 里是"更新这个查询"，不该被容量限制拒绝。
            let existing = try savedSearchRepo
                .list(sessionId: input.sessionId)
                .first { $0.name == input.name && $0.sessionId == input.sessionId }
            if existing == nil {
                let limit = Self.savedSearchLimit(settingsService)
                if try savedSearchRepo.count() >= limit {
                    throw GatherError.invalidParameter(
                        field: "name",
                        reason: "saved search limit reached (\(limit))")
                }
            }
            return Self.savedSearchData(
                try savedSearchRepo.upsert(
                    name: input.name,
                    sessionId: input.sessionId,
                    criteria: input.criteria))
        } catch let error as SavedSearchRepoError {
            throw Self.mappedSavedSearchError(error)
        }
    }

    public func deleteSavedSearch(_ input: DeleteSavedSearchInput) async throws {
        guard let savedSearchRepo else {
            throw GatherError.invalidParameter(
                field: "id", reason: "saved searches are not available in this build")
        }
        if try savedSearchRepo.delete(id: input.id) { return }
        // 不存在不能静默成功：UI 的"删除"会留下幽灵行。
        throw GatherError.invalidParameter(
            field: "id", reason: "saved search not found: \(input.id)")
    }

    public func count(_ input: SearchCountInput) async throws -> Int {
        try mapFilterError {
            try filterEngine.countGlobally(
                criteria: input.criteria, sessionId: input.sessionId)
        }
    }


    public func semanticSearch(
        _ query: SemanticSearchQuery
    ) async throws -> SemanticSearchOutcomeSnapshot {
        guard let semanticIndex else {
            return SemanticSearchOutcomeSnapshot(
                sessionId: query.sessionId, method: "unavailable", hits: [],
                scanned: 0, skipped: 0, unavailableReason: "语义索引未接线")
        }
        // Wave2 / task-14：多选优先（单张只是种子集合的退化情形）。
        if !query.photoIds.isEmpty {
            let outcome = try mapFilterError {
                try semanticIndex.similar(
                    to: query.photoIds, sessionId: query.sessionId,
                    limit: query.limit, minSimilarity: query.minSimilarity)
            }
            return Self.semanticSnapshot(outcome)
        }
        if let photoId = query.photoId, !photoId.isEmpty {
            let outcome = try mapFilterError {
                try semanticIndex.similar(
                    to: photoId, sessionId: query.sessionId,
                    limit: query.limit, minSimilarity: query.minSimilarity)
            }
            return Self.semanticSnapshot(outcome)
        }
        let outcome = try mapFilterError {
            try semanticIndex.search(
                sessionId: query.sessionId, labels: query.labels, limit: query.limit)
        }
        return Self.semanticSnapshot(outcome)
    }

    private static func semanticSnapshot(
        _ outcome: SemanticSearchOutcome
    ) -> SemanticSearchOutcomeSnapshot {
        SemanticSearchOutcomeSnapshot(
            sessionId: outcome.sessionId,
            method: outcome.method.rawValue,
            hits: outcome.hits.map {
                SemanticSearchHitSnapshot(
                    photoId: $0.photoId, similarity: $0.similarity,
                    labels: $0.labels.map(\.label),
                    matchedLabels: $0.matchedLabels)
            },
            scanned: outcome.scanned, skipped: outcome.skipped,
            unavailableReason: outcome.unavailableReason)
    }

    // MARK: - Wave2 / task-14：场景标签写回

    public func semanticKeywordPlan(
        _ input: SemanticKeywordPlanInput
    ) async throws -> SemanticKeywordPlan {
        guard let semanticKeywords else {
            return SemanticKeywordPlan(
                sessionId: input.sessionId, root: input.root, items: [],
                photosWithLabels: 0, photosWithoutLabels: 0, totalAdditions: 0,
                unavailableReason: "场景标签写回未接线")
        }
        do {
            return try semanticKeywords.plan(input)
        } catch let error as SemanticKeywordError {
            throw GatherError(code: error.code, params: ["reason": error.description])
        }
    }

    public func applySemanticKeywords(
        _ input: Confirmed<SemanticKeywordApplyInput>
    ) async throws -> SemanticKeywordApplyResult {
        guard let semanticKeywords else {
            throw GatherError.invalidParameter(
                field: "sessionId",
                reason: "semantic keyword writeback is not available in this build")
        }
        do {
            return try await semanticKeywords.apply(input.value)
        } catch let error as SemanticKeywordError {
            throw GatherError(code: error.code, params: ["reason": error.description])
        }
    }


    // MARK: - Wave5（Batch4 / task-19）：批量重命名 + 移动到文件夹

    public func previewRename(_ input: PhotoRenamePreviewInput) async throws -> PhotoRenamePreview {
        try await fileOps.previewRename(input)
    }

    /// 破坏性：Confirmed 已由 UI 的预览确认分支构造；这里只透传（不补确认）。
    public func renamePhotos(_ input: Confirmed<PhotoRenameInput>) async throws -> PhotoRenameResult {
        try await fileOps.renamePhotos(input.value)
    }

    public func movePhotos(_ input: Confirmed<PhotoMoveInput>) async throws -> PhotoMoveResult {
        try await fileOps.movePhotos(input.value)
    }

    public func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion] {
        try mapFilterError {
            try filterEngine.suggest(query.sessionId, keyword: query.keyword)
        }
    }

    /// P1 / C：facet 计数。每维单独 COUNT，且按该维剔除自身条件（同维多选取并集）。
    public func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup] {
        guard let facetQuery else { return [] }
        let requested: [FacetDimension] = input.dimensions.isEmpty
            ? FacetDimension.allCases
            : input.dimensions.compactMap(FacetDimension.init(rawValue:))
        return try mapFilterError {
            try requested.map { dimension in
                let buckets = try facetQuery.buckets(
                    sessionId: input.sessionId,
                    criteria: input.criteria,
                    dimension: dimension,
                    limit: input.limit,
                    keywordPrefix: input.keywordPrefix
                )
                return PhotoFacetGroup(
                    dimension: dimension.rawValue,
                    buckets: buckets.map { PhotoFacetBucket(value: $0.value, count: $0.count) }
                )
            }
        }
    }

    public func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions] {
        let allowed = try await allowedPaths(input.paths)
        if input.paths.count == 1 {
            guard let path = allowed.first else {
                throw GatherError(code: .PHOTO_NOT_FOUND, params: ["path": input.paths[0]])
            }
            do {
                let dimensions = try RAWDecoder.getDimensions(path: path)
                return [path: PhotoDimensions(width: dimensions.width, height: dimensions.height)]
            } catch {
                // 单路径是旧 image.get_dimensions(path:) 的形态：解码失败不应静默
                // 返回空字典，否则 UI 无法区分“未登记”和“文件损坏/缺失”。
                throw GatherError(
                    code: .PHOTO_NOT_FOUND,
                    params: ["path": path],
                    underlying: String(describing: error)
                )
            }
        }
        // 批量路径保持旧命令的 best-effort：未登记/解码失败的项跳过，不拖垮整批。
        var results: [String: PhotoDimensions] = [:]
        for path in allowed {
            guard let dimensions = try? RAWDecoder.getDimensions(path: path) else { continue }
            results[path] = PhotoDimensions(width: dimensions.width, height: dimensions.height)
        }
        return results
    }

    public func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws {
        let allowed = try await allowedPaths([input.path])
        guard let path = allowed.first else {
            throw GatherError(code: .PHOTO_NOT_FOUND, params: ["path": input.path])
        }
        try imagePreloadService.prioritizeThumbnail(
            path: path,
            size: resolvedThumbnailSize(input.size)
        )
    }

    public func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle? {
        let paths = try await allowedPaths(input.paths)
        guard !paths.isEmpty else { return nil }
        let size = resolvedThumbnailSize(input.size)
        let fingerprint = paths.joined(separator: "\u{0}")
        return try await jobAPI.start(JobCreateParams(
            type: .thumbnailBuild,
            scopeType: "paths",
            scopeId: paths[0],
            dedupeKey: "thumbnail.build:\(size):\(fingerprint)",
            priority: -1,
            checkpoint: [
                "paths": .array(paths.map(JSONValue.string)),
                "size": .number(Double(size)),
            ]
        ))
    }

    public func preloadPreviews(_ input: PreviewPreloadInput) async throws {
        let paths = try await allowedPaths(input.paths)
        guard !paths.isEmpty else { return }
        imagePreloadService.preloadPreviews(
            paths: paths,
            maxDimension: input.maxDimension ?? 2048
        )
    }

    // MARK: - 装配（对齐旧命令面 assemblePhotoRows）

    /// TS photo.ipc.ts assemblePhotos：按逻辑资产分组（asset_id ?? "photo:<id>"），
    /// expandVariants=false 时每组取 raw → camera_jpeg → 首行，并带成员角色与
    /// 人脸计数（页级三次小查询）。
    private func assemblePhotoRows(
        _ rows: [PhotoPageRow],
        sessionId: String,
        expandVariants: Bool
    ) -> [PhotoData] {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return [] }

        // 角色/人脸计数是页级辅助信息：单个小查询失败不应让整页打不开，保持旧
        // 旧实现的 try? 降级语义。
        let memberRoles = (try? assetRepo.memberRoles(sessionId: sessionId, photoIds: ids)) ?? [:]
        let faceCounts = (try? faceKwService.faceCounts(sessionId: sessionId, photoIds: ids)) ?? [:]

        func toPhotoData(_ row: PhotoPageRow, variants: [PhotoPageRow]) -> PhotoData {
            PhotoData(
                id: row.id,
                sessionId: row.sessionId,
                filepath: row.filepath,
                filename: row.filename,
                checksum: row.checksum ?? "",
                hasExistingXmp: false,
                faceCount: faceCounts[row.id] ?? 0,
                width: row.width,
                height: row.height,
                metadata: [:],
                result: [:],
                status: row.status,
                assetId: row.assetId,
                variantCount: variants.count,
                variants: variants.map { variant in
                    PhotoVariant(
                        photoId: variant.id,
                        filepath: variant.filepath,
                        filename: variant.filename,
                        role: memberRoles[variant.id] ?? "unknown"
                    )
                },
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }

        var groups: [String: [PhotoPageRow]] = [:]
        var order: [String] = []
        for row in rows {
            let key = row.assetId ?? "photo:\(row.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        if expandVariants {
            return rows.map { row in
                toPhotoData(row, variants: groups[row.assetId ?? "photo:\(row.id)"] ?? [row])
            }
        }
        return order.compactMap { key in
            guard let variants = groups[key] else { return nil }
            let preferred = variants.first { memberRoles[$0.id] == "raw" }
                ?? variants.first { memberRoles[$0.id] == "camera_jpeg" }
                ?? variants[0]
            return toPhotoData(preferred, variants: variants)
        }
    }

    // MARK: - 内部

    /// 批量路径授权：空/超长/未登记/重复项过滤；与旧 allowedPhotoPaths 逐条一致。
    private func allowedPaths(_ paths: [String]) async throws -> [String] {
        var seen = Set<String>()
        var allowed: [String] = []
        for path in paths where !path.isEmpty && path.count <= 4096 && seen.insert(path).inserted {
            if try await pathPolicy.containsFilepath(path) { allowed.append(path) }
        }
        return allowed
    }

    /// thumbnail_size 设置可能是外部写入的任意 Double：非有限/越界一律钳制，
    /// 保持旧命令面 的 clampedInt 行为（不在解码层收到 0/负值）。
    private func resolvedThumbnailSize(_ explicit: Int?) -> Int {
        if let explicit { return explicit }
        let raw = settingsService.double(.thumbnailSize)
        guard raw.isFinite else { return 1024 }
        let rounded = raw.rounded()
        if rounded < 64 { return 64 }
        if rounded > 8192 { return 8192 }
        return Int(rounded)
    }

    /// 保存查询上限（设置键 gallery_saved_search_limit；异常值钳到 1...1000）。
    static func savedSearchLimit(_ settings: SettingsService) -> Int {
        let raw = settings.double(.gallerySavedSearchLimit)
        guard raw.isFinite else { return 50 }
        let rounded = Int(raw.rounded())
        if rounded < 1 { return 1 }
        if rounded > 1_000 { return 1_000 }
        return rounded
    }

    static func savedSearchData(_ row: SavedSearchRow) -> SavedSearchData {
        SavedSearchData(
            id: row.id,
            name: row.name,
            sessionId: row.sessionId,
            criteria: row.criteria,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt)
    }

    /// PhotoFilterQuery 的 SQL 生成错误 → API 边界错误码（与 FilterEngine 同一映射）。
    static func mappedFilterError(_ error: PhotoFilterQueryError) -> GatherError {
        switch error {
        case .fieldUnknown(let field):
            GatherError(code: .FILTER_FIELD_UNKNOWN, params: ["field": field])
        case .unsupportedOperatorForField(let field, let op):
            GatherError.invalidParameter(
                field: "criteria", reason: "unsupported operator \(op) for \(field)")
        }
    }

    /// 保存查询的存量/输入错误：不新增全局码，用既有的 FILTER_CRITERIA_INVALID / INVALID_PARAM。
    static func mappedSavedSearchError(_ error: SavedSearchRepoError) -> GatherError {
        switch error {
        case .corruptedCriteria(let id):
            GatherError(code: .FILTER_CRITERIA_INVALID, params: ["id": id])
        case .notFound(let id):
            GatherError.invalidParameter(field: "id", reason: "not found: \(id)")
        }
    }

    /// FilterEngine 的字段未知错误带参数（FILTER_FIELD_UNKNOWN::field）；API 边界
    /// 转成 (code, params)，其余错误保持原样（非域错误由 UI 通用漏斗兜底）。
    private func mapFilterError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch FilterEngineError.fieldUnknown(let field) {
            throw GatherError(code: .FILTER_FIELD_UNKNOWN, params: ["field": field])
        } catch FilterEngineError.unsupportedOperatorForField(let field, let op) {
            throw GatherError.invalidParameter(
                field: "criteria",
                reason: "unsupported operator \(op) for \(field)"
            )
        }
    }
}
