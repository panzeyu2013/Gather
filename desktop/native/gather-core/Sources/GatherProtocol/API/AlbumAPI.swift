// desktop/native/gather-core/Sources/GatherProtocol/API/AlbumAPI.swift
// Cut 1 / 阶段 1A：智能相册域协议（5 个方法）。
//
// 职责：相册创建/列表/更新/删除、按相册取照片（详情+分页）。
// 对应命令（6 条）：album.create / list / update / delete / get_photos；
// album.get 已按 R4 删除（get_photos 复用同一详情构造）。
// 校验归属：
// - create/update 复用 AlbumCreateParams/AlbumUpdateParams；criteria 的类型在
//   解码期失败，SQL 可构建性由实现调用 FilterEngine 校验；
// - delete 使用 Confirmed<T>；ALBUM_NOT_FOUND 由实现映射；
// - get_photos 的 limit 1...500 缺省 100 / offset >= 0 由 PageRequest.album 归一化。

import Foundation

public protocol AlbumAPI: Sendable {
    func create(_ input: AlbumCreateParams) async throws -> SmartAlbumDetailData
    func list() async throws -> [SmartAlbumData]
    func update(_ input: AlbumUpdateParams) async throws
    func delete(_ input: Confirmed<AlbumDeleteInput>) async throws
    func photos(_ query: AlbumPhotosQuery) async throws -> GlobalPhotoPage
}
