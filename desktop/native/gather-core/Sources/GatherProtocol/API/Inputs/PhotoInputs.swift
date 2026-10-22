// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/PhotoInputs.swift
// Cut 1 / 阶段 1A：PhotoAPI 输入（photo.* + filter.* + image.* 合并为 7 个方法）。
//
// 对应命令：photo.list_page、filter.photos(_global)（M3 合并）、filter.suggest、
// image.prioritize_thumbnail / preload_thumbnails / preload_previews / get_dimensions
// （image.* 的 P/A 路径授权）。
// 校验归属：
// - limit/offset 沿用旧钳制规则（PageRequest），afterFirstRowid 必须 >= 0；
// - 路径仅做非空/长度校验；是否已登记由 PhotoAPI 实现经 PhotoPathPolicy 判定，
//   未登记路径不得进入文件系统（1B 转 PHOTO_NOT_FOUND 语义错误）；
// - 尺寸范围在这里显式失败（D-012/G7），不再把 0/负值传进解码层。

import Foundation

/// photo.list_page 的键集分页查询。
public struct PhotoPageQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let limit: Int
    public let afterFirstRowid: Int64?
    public let expandVariants: Bool

    public init(
        sessionId: String,
        limit: Int? = nil,
        afterFirstRowid: Int64? = nil,
        expandVariants: Bool = false
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.limit = PageRequest.normalizedLimit(
            limit,
            default: PageRequest.photoDefaultLimit,
            max: PageRequest.photoMaxLimit
        )
        if let afterFirstRowid, afterFirstRowid < 0 {
            throw GatherError.invalidParameter(field: "afterFirstRowid", reason: "must be non-negative")
        }
        self.afterFirstRowid = afterFirstRowid
        self.expandVariants = expandVariants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            afterFirstRowid: try container.decodeIfPresent(Int64.self, forKey: .afterFirstRowid),
            expandVariants: try container.decodeIfPresent(Bool.self, forKey: .expandVariants) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, limit, afterFirstRowid, expandVariants
    }
}

/// filter.photos + filter.photos_global 的统一查询（M3）：sessionId == nil 即全局。
public struct PhotoQuery: Decodable, Sendable, Equatable {
    public let sessionId: String?
    public let criteria: FilterGroup
    public let sortBy: String?
    public let sortOrder: String?
    public let page: PageRequest

    public init(
        criteria: FilterGroup,
        sessionId: String? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws {
        if let sessionId {
            self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        } else {
            self.sessionId = nil
        }
        self.criteria = criteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.page = PageRequest.filter(limit: limit, offset: offset)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            criteria: try container.decode(FilterGroup.self, forKey: .criteria),
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
            sortBy: try container.decodeIfPresent(String.self, forKey: .sortBy),
            sortOrder: try container.decodeIfPresent(String.self, forKey: .sortOrder),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            offset: try container.decodeIfPresent(Int.self, forKey: .offset)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, criteria, sortBy, sortOrder, limit, offset
    }
}

/// filter.suggest 的查询（keyword 缺省空串）。
public struct PhotoSuggestionQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let keyword: String

    public init(sessionId: String, keyword: String = "") throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.keyword = try APIValidation.bounded(keyword, field: "keyword", maxLength: 256, allowEmpty: true)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            keyword: try container.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, keyword
    }
}

/// image.get_dimensions 的单形态输入：单路径 = 只传一个元素。
public struct PhotoDimensionsInput: Decodable, Sendable, Equatable {
    public let paths: [String]

    public init(paths: [String]) throws {
        self.paths = try APIValidation.nonEmpty(paths, field: "paths", maxCount: 10_000)
        for (index, path) in self.paths.enumerated() {
            _ = try APIValidation.path(path, field: "paths[\(index)]")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(paths: try container.decode([String].self, forKey: .paths))
    }

    private enum CodingKeys: String, CodingKey {
        case paths
    }
}

/// image.prioritize_thumbnail 的输入（size 缺省由实现读取 thumbnail_size 设置）。
public struct ThumbnailPrioritizeInput: Decodable, Sendable, Equatable {
    public let path: String
    public let size: Int?

    public init(path: String, size: Int? = nil) throws {
        self.path = try APIValidation.path(path)
        if let size {
            _ = try APIValidation.integerInRange(size, field: "size", 64...8192)
        }
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: try container.decode(String.self, forKey: .path),
            size: try container.decodeIfPresent(Int.self, forKey: .size)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case path, size
    }
}

/// image.preload_thumbnails 的输入；paths 为空表示无需建 job。
public struct ThumbnailPreloadInput: Decodable, Sendable, Equatable {
    public let paths: [String]
    public let size: Int?

    public init(paths: [String] = [], size: Int? = nil) throws {
        for (index, path) in paths.enumerated() {
            _ = try APIValidation.path(path, field: "paths[\(index)]")
        }
        if let size {
            _ = try APIValidation.integerInRange(size, field: "size", 64...8192)
        }
        self.paths = paths
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            paths: try container.decodeIfPresent([String].self, forKey: .paths) ?? [],
            size: try container.decodeIfPresent(Int.self, forKey: .size)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paths, size
    }
}

/// image.preload_previews 的输入（maxDimension 缺省 2048；旧命令无范围，这里补上界）。
public struct PreviewPreloadInput: Decodable, Sendable, Equatable {
    public let paths: [String]
    public let maxDimension: Int?

    public init(paths: [String] = [], maxDimension: Int? = nil) throws {
        for (index, path) in paths.enumerated() {
            _ = try APIValidation.path(path, field: "paths[\(index)]")
        }
        if let maxDimension {
            _ = try APIValidation.integerInRange(maxDimension, field: "maxDimension", 1...16_384)
        }
        self.paths = paths
        self.maxDimension = maxDimension
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            paths: try container.decodeIfPresent([String].self, forKey: .paths) ?? [],
            maxDimension: try container.decodeIfPresent(Int.self, forKey: .maxDimension)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paths, maxDimension
    }
}
