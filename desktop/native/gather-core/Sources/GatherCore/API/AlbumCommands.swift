// API/AlbumCommands.swift
// R5 类型化 async 域协议：album 域。
// 旧实现来源：gather-app 的会话命令分发器 album.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、返回只用 Protocol/Filter.swift 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// album 域命令（6 条）。
///
/// 旧命令清单：`album.create`、`album.list`、`album.get`、`album.update`、
/// `album.delete`、`album.get_photos`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - Protocol/ 暂无 album 请求壳 DTO（无 Protocol/Album.swift），create / update /
///   delete / get_photos 沿用旧命令的扁平参数；criteria 为 Protocol/Filter.swift 的
///   FilterGroup，经过滤引擎校验后落库。
/// - 响应壳沿用 Protocol/Filter.swift：create / get 返回 SmartAlbumDetailData，
///   list 返回 [SmartAlbumData]（criteria 解码 / 校验失败的行带 validationError 保留）；
///   get_photos 的 {photos, total} 暂无复合 DTO，以元组返回，
///   photos 元素为 Protocol/Filter.swift 的 GlobalPhotoResult。
/// - 旧 `album.delete` 的 confirmed 门控必须保留（缺失时旧消息
///   "album.delete requires confirmation"）；`album.get` / `album.get_photos`
///   找不到相册时由实现抛 ALBUM_NOT_FOUND。
public protocol AlbumCommands: Sendable {
    /// 旧命令：`album.create`。
    /// name 与 criteria 必填；description / sortBy / sortOrder / icon 可选；
    /// 返回新建相册详情（photoCount 由实现补齐）。
    func create(
        name: String,
        description: String?,
        criteria: FilterGroup,
        sortBy: String?,
        sortOrder: String?,
        icon: String?
    ) async throws -> SmartAlbumDetailData

    /// 旧命令：`album.list`。
    /// 全部智能相册；criteria 解码 / 校验失败的行保留并附 validationError。
    func list() async throws -> [SmartAlbumData]

    /// 旧命令：`album.get`。
    /// 相册详情；不存在时由实现抛 ALBUM_NOT_FOUND。
    func get(albumId: String) async throws -> SmartAlbumDetailData

    /// 旧命令：`album.update`。
    /// 仅更新传入的非 nil 字段；criteria 传入时先经过滤引擎校验。
    func update(
        albumId: String,
        name: String?,
        description: String?,
        criteria: FilterGroup?,
        sortBy: String?,
        sortOrder: String?,
        icon: String?
    ) async throws

    /// 旧命令：`album.delete`（破坏性）。
    /// confirmed 必须为 true，否则实现抛 "album.delete requires confirmation"。
    func delete(albumId: String, confirmed: Bool) async throws

    /// 旧命令：`album.get_photos`。
    /// 按相册 criteria 全局过滤；limit 缺省 100、上限 500，offset ≥ 0，
    /// 返回匹配照片与总数（旧响应 {photos, total}）。
    func getPhotos(
        albumId: String,
        limit: Int?,
        offset: Int?
    ) async throws -> (photos: [GlobalPhotoResult], total: Int)
}
