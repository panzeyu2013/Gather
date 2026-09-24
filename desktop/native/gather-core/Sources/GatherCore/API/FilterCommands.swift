// API/FilterCommands.swift
// R5 类型化 async 域协议：filter 域。
// 旧实现来源：gather-app 路由层的 filter.* 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO 与基础类型、无同步重载。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// filter 域命令（3 条）。
///
/// 旧命令清单：filter.photos、filter.photos_global、filter.suggest。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - Protocol/Filter.swift 的 FilterPhotosParams 不含 limit/offset，而旧分发层以
///   基础参数做钳制（缺省 100、上限 500、offset ≥ 0）；本协议以扁平参数
///   limit/offset 承接，钳制语义由实现保留（W5-2 待裁决是否扩展 DTO）。
/// - 旧 filter.photos 行数据源为服务层对象（metadata/result 为 JSON 字符串），
///   响应投影为 Protocol/Session.swift 的 PhotoData（metadata/result 为对象）；
///   字段对齐由实现映射承载。
/// - 旧 filter.photos_global 返回 {photos, total}；Protocol/ 暂无复合 DTO，
///   本协议以 (photos, total) 元组返回（photos 为 Protocol/Filter.swift 的
///   GlobalPhotoResult），同样由实现保留 limit 1..500 / offset ≥ 0 的钳制。
/// - 旧 filter.suggest 的 keyword 缺省为空串；DTO 中为非可选，实现需在入口
///   补缺省后再调用。
public protocol FilterCommands: Sendable {
    /// 旧命令：filter.photos。
    /// 按 criteria 过滤会话照片；limit/offset 由实现按旧分发层语义钳制
    /// （缺省 limit 100、上限 500，offset ≥ 0）；返回 Protocol/Session.swift 的
    /// PhotoData 数组。
    func photos(_ params: FilterPhotosParams, limit: Int, offset: Int) async throws -> [PhotoData]

    /// 旧命令：filter.photos_global。
    /// 跨会话全局过滤；返回匹配照片与总数（旧响应 {photos, total} 的元组投影）。
    func photosGlobal(_ params: FilterPhotosGlobalParams) async throws
        -> (photos: [GlobalPhotoResult], total: Int)

    /// 旧命令：filter.suggest。
    /// 返回字段取值建议，元素为 Protocol/Filter.swift 的 FilterSuggestion。
    func suggest(_ params: FilterSuggestParams) async throws -> [FilterSuggestion]
}
