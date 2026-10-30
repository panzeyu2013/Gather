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
///
/// P1 下一波 §3.7.1：criteria / sortBy / sortOrder 为**可选**新增字段，
/// 缺字段 = nil（旧客户端/测试的解码结果不变）。
///
/// 游标语义没有变：afterFirstRowid 仍是"上一页最后一个资产组的首行 rowid"。
/// 因此 sortBy 只接受能由 rowid 游标单调编码的顺序（导入顺序）；需要按拍摄
/// 时间/评分排序时走 PhotoAPI.search（offset 分页），不在这里做复合游标。
public struct PhotoPageQuery: Decodable, Sendable, Equatable {
    /// 游标分页允许的排序字段：只有 rowid（导入顺序）。
    /// 其余字段（date_taken/rating/...）需要 (排序值, rowid) 复合游标才能跨页
    /// 无重复无漏项，而 PhotoPage.cursor 只有 Int64 —— 显式失败好过静默错序。
    /// 旧实现把 import_order 也列进来当 rowid 的别名，但服务端只按 photos.rowid
    /// 排序、且该字段在 session_assets 上（并非同义），已删除避免"白名单承诺了
    /// 一个没实现的顺序"。需要按拍摄时间/评分排序时走 PhotoAPI.search（offset 分页）。
    public static let allowedSortFields: [String] = ["rowid"]

    public let sessionId: String
    public let limit: Int
    public let afterFirstRowid: Int64?
    public let expandVariants: Bool
    /// 服务端筛选（与 PhotoAPI.facets 同一套 FilterEngine 语义）。
    public let criteria: FilterGroup?
    /// 排序字段（nil = 导入顺序）；取值见 allowedSortFields。
    public let sortBy: String?
    /// asc / desc（归一化为小写）；nil = 默认（导入顺序正序）。
    public let sortOrder: String?

    /// 是否带有效筛选（空组等同于不带）。
    public var hasCriteria: Bool {
        guard let criteria else { return false }
        return !criteria.conditions.isEmpty
    }

    /// 排序方向：true = 逆序（rowid 游标按降序推进）。
    public var isDescending: Bool { sortOrder == "desc" }

    public init(
        sessionId: String,
        limit: Int? = nil,
        afterFirstRowid: Int64? = nil,
        expandVariants: Bool = false,
        criteria: FilterGroup? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil
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
        self.criteria = criteria
        if let sortBy {
            let normalized = sortBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.allowedSortFields.contains(normalized) else {
                throw GatherError.invalidParameter(
                    field: "sortBy",
                    reason: "cursor pagination supports "
                        + Self.allowedSortFields.joined(separator: "/")
                        + " only; use filter.photos for sorted results")
            }
            self.sortBy = normalized
        } else {
            self.sortBy = nil
        }
        if let sortOrder {
            let normalized = sortOrder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "asc" || normalized == "desc" else {
                throw GatherError.invalidParameter(field: "sortOrder", reason: "must be asc or desc")
            }
            self.sortOrder = normalized
        } else {
            self.sortOrder = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            afterFirstRowid: try container.decodeIfPresent(Int64.self, forKey: .afterFirstRowid),
            expandVariants: try container.decodeIfPresent(Bool.self, forKey: .expandVariants) ?? false,
            criteria: try container.decodeIfPresent(FilterGroup.self, forKey: .criteria),
            sortBy: try container.decodeIfPresent(String.self, forKey: .sortBy),
            sortOrder: try container.decodeIfPresent(String.self, forKey: .sortOrder)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, limit, afterFirstRowid, expandVariants, criteria, sortBy, sortOrder
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

// MARK: - P1 下一波 §3.7.3：保存查询（Gallery/Library 共用）

/// savedSearches 的作用域查询：sessionId == nil 返回全局 + 该会话的（见实现契约）。
public struct SavedSearchesQuery: Decodable, Sendable, Equatable {
    public let sessionId: String?

    public init(sessionId: String? = nil) throws {
        if let sessionId {
            self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        } else {
            self.sessionId = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
    }
}

/// 保存的查询（wire：id/name/session_id/criteria_json/created_at/updated_at）。
///
/// criteria 是**完整**筛选：4 档过滤、搜索串与规则编辑器条件在保存前已合成为一个
/// FilterGroup（§3.7.2），恢复时整份回填，不依赖 UI 侧的第二份状态。
public struct SavedSearchData: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// nil = 全局查询（跨会话）。
    public var sessionId: String?
    public var criteria: FilterGroup
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        sessionId: String?,
        criteria: FilterGroup,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.sessionId = sessionId
        self.criteria = criteria
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// saveSearch 的输入；name 在同作用域内唯一（重名 = 覆盖，不新增一行）。
public struct SaveSearchInput: Decodable, Sendable, Equatable {
    public static let maxNameLength = 120

    public let name: String
    public let sessionId: String?
    public let criteria: FilterGroup

    public init(name: String, sessionId: String? = nil, criteria: FilterGroup) throws {
        // bounded(allowEmpty: false) 会同时做 trim + 长度校验 + 空白拒绝。
        self.name = try APIValidation.bounded(
            name, field: "name", maxLength: Self.maxNameLength, allowEmpty: false)
        if let sessionId {
            self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        } else {
            self.sessionId = nil
        }
        self.criteria = criteria
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: try container.decode(String.self, forKey: .name),
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
            criteria: try container.decode(FilterGroup.self, forKey: .criteria)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, sessionId, criteria
    }
}

public struct DeleteSavedSearchInput: Decodable, Sendable, Equatable {
    public let id: String

    public init(id: String) throws {
        self.id = try APIValidation.nonBlank(id, field: "id", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: try container.decode(String.self, forKey: .id))
    }

    private enum CodingKeys: String, CodingKey {
        case id
    }
}

/// 计数查询：与 PhotoAPI.search 同口径（按逻辑资产去重），但不带分页。
public struct SearchCountInput: Decodable, Sendable, Equatable {
    public let sessionId: String?
    public let criteria: FilterGroup

    public init(criteria: FilterGroup, sessionId: String? = nil) throws {
        self.criteria = criteria
        if let sessionId {
            self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        } else {
            self.sessionId = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            criteria: try container.decode(FilterGroup.self, forKey: .criteria),
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, criteria
    }
}
