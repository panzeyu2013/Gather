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
    private let facetQuery: FacetQuery?

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
        facetQuery: FacetQuery? = nil
    ) {
        self.photoRepo = photoRepo
        self.assetRepo = assetRepo
        self.faceKwService = faceKwService
        self.filterEngine = filterEngine
        self.imagePreloadService = imagePreloadService
        self.settingsService = settingsService
        self.jobAPI = jobAPI
        self.facetQuery = facetQuery
        self.pathPolicy = LivePhotoPathPolicy(photoRepo: photoRepo)
    }

    // MARK: - PhotoAPI

    public func page(_ query: PhotoPageQuery) async throws -> PhotoPage {
        let page = try photoRepo.getAssetPage(
            sessionId: query.sessionId,
            afterFirstRowid: query.afterFirstRowid,
            limit: query.limit
        )
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
                    limit: input.limit
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
        let raw = settingsService.getNumber("thumbnail_size", defaultValue: 1024)
        guard raw.isFinite else { return 1024 }
        let rounded = raw.rounded()
        if rounded < 64 { return 64 }
        if rounded > 8192 { return 8192 }
        return Int(rounded)
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
