// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/PhotoOutputs.swift
// Cut 1 / 阶段 1A：PhotoAPI 的结果类型。
//
// 职责：
// - PhotoPage：photo.list_page 的键集分页结果（rows 复用 Protocol 的 PhotoData，
//   与旧 assemblePhotos 的字段一一对应）；
// - PhotoSearchResult：filter.photos(_global) 的统一结果（M3），photos 复用
//   GlobalPhotoResult，total 为全局/会话级计数；
// - PhotoDimensions：image.get_dimensions 的单路径结果。
// 校验归属：无（纯输出）。

import Foundation

public struct PhotoPage: Codable, Equatable, Sendable {
    public let rows: [PhotoData]
    /// nil = 已到末页（旧契约的 cursor: null）。
    public let cursor: Int64?

    public init(rows: [PhotoData], cursor: Int64? = nil) {
        self.rows = rows
        self.cursor = cursor
    }
}

public struct PhotoSearchResult: Codable, Equatable, Sendable {
    public let photos: [GlobalPhotoResult]
    public let total: Int

    public init(photos: [GlobalPhotoResult], total: Int) {
        self.photos = photos
        self.total = total
    }
}

public struct PhotoDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
