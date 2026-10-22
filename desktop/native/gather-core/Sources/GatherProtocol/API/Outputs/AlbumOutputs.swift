// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/AlbumOutputs.swift
// Cut 1 / 阶段 1A：AlbumAPI 的结果类型。
//
// 职责：album.get_photos 的 {photos, total}；photos 复用 Protocol 的
// GlobalPhotoResult（与 filter 全局查询同一照片投影）。
// 校验归属：无（纯输出）。

import Foundation

public struct GlobalPhotoPage: Codable, Equatable, Sendable {
    public let photos: [GlobalPhotoResult]
    public let total: Int

    public init(photos: [GlobalPhotoResult], total: Int) {
        self.photos = photos
        self.total = total
    }
}
