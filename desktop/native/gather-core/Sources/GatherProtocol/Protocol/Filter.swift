// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Filter.swift
// TS 源: packages/shared/src/protocol/filter.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 映射决策:
// - TS `FilterRule.value: unknown` → JSONValue（任意 JSON 值）。
// - TS `conditions: Array<FilterRule | FilterGroup>` 为递归判别联合 →
//   indirect enum FilterCondition，按「先试 rule、失败回退 group」解码
//   （两分支必填字段不相交：rule 需要 field/operator/value，group 需要 logic/conditions）。

import Foundation

// TS: FilterPhotosParams
public struct FilterPhotosParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var criteria: FilterGroup
    public var sortBy: String? // TS: sortBy?
    public var sortOrder: String? // TS: sortOrder?

    public init(sessionId: String, criteria: FilterGroup, sortBy: String? = nil, sortOrder: String? = nil) {
        self.sessionId = sessionId
        self.criteria = criteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

// TS: FilterPhotosGlobalParams
public struct FilterPhotosGlobalParams: Codable, Equatable, Sendable {
    public var criteria: FilterGroup
    public var sessionId: String? // TS: sessionId?
    public var limit: Int? // TS: limit?
    public var offset: Int? // TS: offset?

    public init(criteria: FilterGroup, sessionId: String? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.criteria = criteria
        self.sessionId = sessionId
        self.limit = limit
        self.offset = offset
    }
}

// TS: FilterSuggestParams
public struct FilterSuggestParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var keyword: String

    public init(sessionId: String, keyword: String) {
        self.sessionId = sessionId
        self.keyword = keyword
    }
}

// TS: AlbumCreateParams
public struct AlbumCreateParams: Codable, Equatable, Sendable {
    public var name: String
    public var criteria: FilterGroup
    public var sortBy: String? // TS: sortBy?
    public var sortOrder: String? // TS: sortOrder?
    public var description: String? // TS: description?
    public var icon: String? // TS: icon?

    public init(name: String, criteria: FilterGroup, sortBy: String? = nil, sortOrder: String? = nil, description: String? = nil, icon: String? = nil) {
        self.name = name
        self.criteria = criteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.description = description
        self.icon = icon
    }
}

// TS: AlbumListParams
public struct AlbumListParams: Codable, Equatable, Sendable {
    public init() {}
}

// TS: AlbumGetParams
public struct AlbumGetParams: Codable, Equatable, Sendable {
    public var albumId: String

    public init(albumId: String) {
        self.albumId = albumId
    }
}

// TS: AlbumUpdateParams
public struct AlbumUpdateParams: Codable, Equatable, Sendable {
    public var albumId: String
    public var name: String? // TS: name?
    public var criteria: FilterGroup? // TS: criteria?
    public var sortBy: String? // TS: sortBy?
    public var sortOrder: String? // TS: sortOrder?
    public var description: String? // TS: description?
    public var icon: String? // TS: icon?

    public init(albumId: String, name: String? = nil, criteria: FilterGroup? = nil, sortBy: String? = nil, sortOrder: String? = nil, description: String? = nil, icon: String? = nil) {
        self.albumId = albumId
        self.name = name
        self.criteria = criteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.description = description
        self.icon = icon
    }
}

// TS: AlbumDeleteParams
public struct AlbumDeleteParams: Codable, Equatable, Sendable {
    public var albumId: String
    public var confirmed: Bool

    public init(albumId: String, confirmed: Bool) {
        self.albumId = albumId
        self.confirmed = confirmed
    }
}

// TS: AlbumGetPhotosParams
public struct AlbumGetPhotosParams: Codable, Equatable, Sendable {
    public var albumId: String
    public var limit: Int? // TS: limit?
    public var offset: Int? // TS: offset?

    public init(albumId: String, limit: Int? = nil, offset: Int? = nil) {
        self.albumId = albumId
        self.limit = limit
        self.offset = offset
    }
}

// TS: FilterRule.operator（filter.ts 内联联合）
public enum FilterOperator: String, Codable, CaseIterable, Equatable, Sendable {
    case eq
    case neq
    case gte
    case lte
    case gt
    case lt
    case between
    case `in`
    case contains
    case containsAny = "contains_any"
    case containsAll = "contains_all"
    case startsWith = "starts_with"
    case exists
}

// TS: FilterRule —— value: unknown → JSONValue
public struct FilterRule: Codable, Equatable, Sendable {
    public var field: String
    public var `operator`: FilterOperator
    public var value: JSONValue

    public init(field: String, `operator`: FilterOperator, value: JSONValue) {
        self.field = field
        self.`operator` = `operator`
        self.value = value
    }
}

// TS: FilterGroup.logic（filter.ts 内联联合 'and' | 'or'）
public enum FilterLogic: String, Codable, CaseIterable, Equatable, Sendable {
    case and
    case or
}

// TS: FilterGroup.conditions 的元素：FilterRule | FilterGroup（递归判别联合）
public indirect enum FilterCondition: Codable, Equatable, Sendable {
    case rule(FilterRule)
    case group(FilterGroup)

    public init(from decoder: Decoder) throws {
        if let rule = try? FilterRule(from: decoder) {
            self = .rule(rule)
        } else {
            self = .group(try FilterGroup(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .rule(let rule): try rule.encode(to: encoder)
        case .group(let group): try group.encode(to: encoder)
        }
    }
}

// TS: FilterGroup
public struct FilterGroup: Codable, Equatable, Sendable {
    public var logic: FilterLogic
    public var conditions: [FilterCondition]

    public init(logic: FilterLogic, conditions: [FilterCondition]) {
        self.logic = logic
        self.conditions = conditions
    }
}

// TS: FilterSuggestion
public struct FilterSuggestion: Codable, Equatable, Sendable {
    public var field: String
    public var values: [String]

    public init(field: String, values: [String]) {
        self.field = field
        self.values = values
    }
}

// TS: GlobalPhotoResult
public struct GlobalPhotoResult: Codable, Equatable, Sendable {
    public var photoId: String
    public var assetId: String
    public var sessionId: String
    public var sessionName: String
    public var sessionIds: [String]
    public var sessionNames: [String]
    public var filename: String
    public var filepath: String
    public var status: String
    public var rating: Double
    public var label: String
    public var keywords: [String]

    public init(
        photoId: String,
        assetId: String,
        sessionId: String,
        sessionName: String,
        sessionIds: [String],
        sessionNames: [String],
        filename: String,
        filepath: String,
        status: String,
        rating: Double,
        label: String,
        keywords: [String]
    ) {
        self.photoId = photoId
        self.assetId = assetId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.sessionIds = sessionIds
        self.sessionNames = sessionNames
        self.filename = filename
        self.filepath = filepath
        self.status = status
        self.rating = rating
        self.label = label
        self.keywords = keywords
    }
}

// TS: SmartAlbumData
public struct SmartAlbumData: Codable, Equatable, Sendable {
    public var id: String
    public var schemaVersion: Int
    public var name: String
    public var description: String
    public var filterCriteria: FilterGroup
    public var sortBy: String
    public var sortOrder: String
    public var icon: String
    public var createdAt: String
    public var updatedAt: String
    public var validationError: String? // TS: validationError?

    public init(
        id: String,
        schemaVersion: Int,
        name: String,
        description: String,
        filterCriteria: FilterGroup,
        sortBy: String,
        sortOrder: String,
        icon: String,
        createdAt: String,
        updatedAt: String,
        validationError: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.description = description
        self.filterCriteria = filterCriteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.icon = icon
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.validationError = validationError
    }
}

// TS: SmartAlbumDetailData extends SmartAlbumData —— Swift 无继承，展开字段并追加 photoCount
public struct SmartAlbumDetailData: Codable, Equatable, Sendable {
    public var id: String
    public var schemaVersion: Int
    public var name: String
    public var description: String
    public var filterCriteria: FilterGroup
    public var sortBy: String
    public var sortOrder: String
    public var icon: String
    public var createdAt: String
    public var updatedAt: String
    public var validationError: String? // TS: validationError?
    public var photoCount: Int

    public init(
        id: String,
        schemaVersion: Int,
        name: String,
        description: String,
        filterCriteria: FilterGroup,
        sortBy: String,
        sortOrder: String,
        icon: String,
        createdAt: String,
        updatedAt: String,
        validationError: String? = nil,
        photoCount: Int
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.description = description
        self.filterCriteria = filterCriteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.icon = icon
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.validationError = validationError
        self.photoCount = photoCount
    }
}
