// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/AlbumInputs.swift
// Cut 1 / 阶段 1A：AlbumAPI 输入（album.* 6 条 -> 5 个方法，album.get 已按 R4 删除）。
//
// 对应命令：album.create / list / update / delete / get_photos。
// 复用：album.create -> AlbumCreateParams，album.update -> AlbumUpdateParams
// （criteria 已类型化为 FilterGroup，未知字段/结构在解码期失败）。
// 校验归属：
// - get_photos 的 limit 1...500 缺省 100、offset >= 0 由 PageRequest.album 归一化；
// - delete 为破坏性入口，使用 Confirmed<T>；
// - criteria 的 SQL 可构建性由 1B 调用 FilterEngine.buildWhereClause 校验。

import Foundation

/// album.get_photos 的查询。
public struct AlbumPhotosQuery: Decodable, Sendable, Equatable {
    public let albumId: String
    public let page: PageRequest

    public init(albumId: String, limit: Int? = nil, offset: Int? = nil) throws {
        self.albumId = try APIValidation.nonBlank(albumId, field: "albumId", maxLength: 128)
        self.page = PageRequest.album(limit: limit, offset: offset)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            albumId: try container.decode(String.self, forKey: .albumId),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            offset: try container.decodeIfPresent(Int.self, forKey: .offset)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case albumId, limit, offset
    }
}

/// album.delete 的载荷（Confirmed<AlbumDeleteInput>）。
public struct AlbumDeleteInput: Decodable, Sendable, Equatable {
    public let albumId: String

    public init(albumId: String) throws {
        self.albumId = try APIValidation.nonBlank(albumId, field: "albumId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(albumId: try container.decode(String.self, forKey: .albumId))
    }

    private enum CodingKeys: String, CodingKey {
        case albumId
    }
}
