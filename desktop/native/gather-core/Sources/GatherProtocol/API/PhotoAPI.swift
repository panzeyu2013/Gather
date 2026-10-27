// desktop/native/gather-core/Sources/GatherProtocol/API/PhotoAPI.swift
// Cut 1 / 阶段 1A：照片域协议（7 个方法）。
//
// 职责：照片分页、查询 DSL、建议、派生媒体（尺寸/缩略图/预览）。
// 对应命令（9 条）：photo.list_page、filter.photos + filter.photos_global（M3 合并）、
// filter.suggest、image.get_dimensions（单形态）、image.prioritize_thumbnail /
// preload_thumbnails / preload_previews。
// 校验归属：
// - 分页/排序/关键词的形状校验在输入类型；
// - 路径授权：实现必须经 pathPolicy.containsFilepath 过滤后才能触碰文件系统，
//   未登记路径转 PHOTO_NOT_FOUND 语义错误（D-010 后使用新增码）；
// - 查询字段/操作符的合法性仍由 FilterEngine（FILTER_* 码）负责；
// - 缩略图 job 的建 job 细节由实现调用 JobService 完成。
// 无实现：Live 实现属于阶段 1B。

import Foundation

public protocol PhotoAPI: Sendable {
    /// 路径授权策略（image.* 的 P/A 校验归属）。
    var pathPolicy: any PhotoPathPolicy { get }

    /// photo.list_page
    func page(_ query: PhotoPageQuery) async throws -> PhotoPage

    /// filter.photos / filter.photos_global（M3：sessionId == nil 即全局）
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult

    /// filter.suggest
    func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion]

    /// P1 / C：facet 计数（每维独立 COUNT，已按该维剔除自身条件）。
    func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup]

    /// image.get_dimensions（单路径 = paths 只有一个元素）
    func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions]

    /// image.prioritize_thumbnail
    func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws

    /// image.preload_thumbnails；paths 为空返回 nil（无需建 job）
    func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle?

    /// image.preload_previews
    func preloadPreviews(_ input: PreviewPreloadInput) async throws
}
