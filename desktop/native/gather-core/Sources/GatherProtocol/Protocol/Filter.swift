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
//
// Wave2（task-15）：新增 `not`——语义 = "组内子条件一个都不满足"。
// 组合方式与 SQL 生成（PhotoFilterQuery.buildWhereClause）一致：
//   - and：全部满足
//   - or ：任一满足
//   - not：子条件先按 **or** 组合，再整体取反（= LR Smart Collection 的
//          "none of the following"）。单条子条件时两种读法等价，因此常见的
//          "排除某集合/排除某评级"不需要关心这条细节。
// 空组仍返回"无约束"（1=1），NOT 空组同样不报错——编辑器里把子条件删光不该
// 让整页筛选变成"什么都不显示"。
public enum FilterLogic: String, Codable, CaseIterable, Equatable, Sendable {
    case and
    case or
    case not
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

public extension FilterGroup {
    /// P1 / C：剔除某字段的全部规则（facet 计数用：同维度不能用自己的筛选自证）。
    ///
    /// 只在**全 AND 路径**上剔除同维条件。
    /// OR 子树里删一个分支等于放宽剩余分支（示例：AND[OR[camera=A,label=Red]]），
    /// facet 会显示网格中 0 张的桶；因此 OR 内的同维条件必须保留。
    func removing(field: String) -> FilterGroup {
        removing(field: field, andContext: true)
    }

    /// Wave4b：facet 同维剔除也进入 NOT 组（存在量化口径）。
    ///
    /// 对 NOT(OR(同维, 其它))，忽略该维后等价于 NOT(其它)：
    /// OR(NOT(TRUE 或 B), NOT(FALSE 或 B)) = 非 B。因此从 NOT 组里剔除同维叶子是对的；
    /// 剔除后只剩同维规则的 NOT 组应视为 TRUE（组消失），不能留下空 NOT
    /// （空 NOT 的 SQL 语义是 1=0，会把 facet 计数全部打成 0）。
    ///
    /// OR 组仍**不**剔除：从析取里删同维叶子会改变其它规则的含义（需要 TRUE
    /// 占位，FilterGroup 表达不了），保守保持旧行为（该维在 OR 下不拆分）。
    private func removing(field: String, andContext: Bool) -> FilterGroup {
        var result: FilterGroup = self
        let canRemove = andContext && (logic == .and || logic == .not)
        result.conditions = conditions.compactMap { condition in
            switch condition {
            case .rule(let rule):
                if canRemove, rule.field == field { return nil }
                return .rule(rule)
            case .group(let group):
                let pruned = group.removing(field: field, andContext: canRemove)
                if canRemove, pruned.conditions.isEmpty { return nil }
                return .group(pruned)
            }
        }
        if result.conditions.isEmpty, result.logic == .not {
            // 根组本身就是 NOT 且被剔空：返回空 AND（无约束 = TRUE），而不是空 NOT。
            return FilterGroup(logic: .and, conditions: [])
        }
        return result
    }

    /// 该组是否引用了某字段（facet UI 判断"这一维是否已被筛过"）。
    func references(field: String) -> Bool {
        conditions.contains { condition in
            switch condition {
            case .rule(let rule): return rule.field == field
            case .group(let group): return group.references(field: field)
            }
        }
    }
}

// MARK: - P1 下一波：keyword 维的字段名常量（只新增常量，不改既有语义）

/// FilterRule.field 的字面量唯一来源。
///
/// 为什么需要常量：facet 的"同维剔除"是按**字段名**删除规则的
/// （`FilterGroup.removing(field:)`），而 facet 维度名（camera/keyword…）与字段名
/// （camera_model/keyword_path…）不同名。两边各写一份字面量迟早漂移：选了
/// keyword 维之后 facet 仍按自己筛选自证，计数与网格对不上。
///
/// 约定：
/// - `keyword_path` 是**层级关键词**维度（photo_keywords 索引，支持 `starts_with` 下钻）；
/// - `keywords` 保留为扁平 JSON 列的文本检索（旧规则/搜索串继续可用），不改语义。
public enum FilterFields {
    /// 层级关键词路径（"A|B"）。facet 维度 `keyword` 对应的字段。
    public static let keywordPath = "keyword_path"
    /// 扁平关键词列表（photo_metadata_cache.keywords）。
    public static let keywords = "keywords"

    public static let cameraModel = "camera_model"
    public static let lensModel = "lens_model"
    public static let iso = "iso"
    public static let dateTaken = "date_taken"
    public static let label = "label"

    // MARK: - Wave2（task-15）：容器成员与相对日期

    /// 手动集合成员：value = 集合 id（或 id 数组）。
    ///
    /// 操作符语义（PhotoFilterQuery 实现）：
    /// - `eq`：在该集合里；
    /// - `neq`：**不在**该集合里（差集的一半）；
    /// - `in` / `contains_any`：在任一集合里（并集）；
    /// - `contains_all`：同时在所有给定集合里（交集）；
    /// - `exists`：属于任意手动集合。
    public static let collection = "collection"

    /// 堆栈成员：字段与操作符同 `collection`，只是按堆栈归属判定。
    public static let stack = "stack"

    /// 相对日期窗口：value 取 `RelativeDateRange.rawValue`（配 `eq`）。
    /// 绝对日期仍走 `date_taken` + 比较操作符，两者互不影响。
    public static let relativeDate = "date_relative"
}

/// 「最近 N 天 / 本月」的取值域（FilterRule.value 的字符串）。
///
/// 为什么用 token 而不是让调用方算绝对日期：算绝对日期要求 UI 持有"今天"，
/// 规则保存成智能相册/保存查询后第二天就过期；token 由 SQL 侧按查询时刻求值，
/// 规则长期有效。
public enum RelativeDateRange: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// 最近 7 天（含今天，按本地时区）。
    case last7 = "last7"
    /// 最近 30 天（含今天，按本地时区）。
    case last30 = "last30"
    /// 本月（自然月，按本地时区）。
    case thisMonth = "this_month"
}

public extension FilterRule {
    /// facet 点击生成的层级关键词规则。
    ///
    /// - `drilldown == true`：`starts_with`——命中该节点自身与全部子孙路径
    ///   （点 "A" 应该同时看到 A 与 A|B 的照片）；
    /// - `drilldown == false`：`eq`——只要该节点本身（叶子多选）。
    static func keywordPath(_ path: String, drilldown: Bool = true) -> FilterRule {
        FilterRule(
            field: FilterFields.keywordPath,
            operator: drilldown ? .startsWith : .eq,
            value: .string(path))
    }

    // MARK: - Wave2（task-15）：集合运算与相对日期的规则工厂

    /// 属于某手动集合（并集的最小单元；多个 id 用 `collectionMembership(anyOf:)`）。
    static func inCollection(_ collectionId: String) -> FilterRule {
        FilterRule(field: FilterFields.collection, operator: .eq, value: .string(collectionId))
    }

    /// 不属于某手动集合（差集：`and(inCollection(A), notInCollection(B))`）。
    static func notInCollection(_ collectionId: String) -> FilterRule {
        FilterRule(field: FilterFields.collection, operator: .neq, value: .string(collectionId))
    }

    /// 属于任一集合（并集）。
    static func collectionMembership(anyOf collectionIds: [String]) -> FilterRule {
        FilterRule(field: FilterFields.collection, operator: .in, value: .array(collectionIds.map { .string($0) }))
    }

    /// 同时属于所有集合（交集）。
    static func collectionMembership(allOf collectionIds: [String]) -> FilterRule {
        FilterRule(field: FilterFields.collection, operator: .containsAll, value: .array(collectionIds.map { .string($0) }))
    }

    /// 属于某堆栈。
    static func inStack(_ stackId: String) -> FilterRule {
        FilterRule(field: FilterFields.stack, operator: .eq, value: .string(stackId))
    }

    /// 相对日期窗口（最近 7/30 天、本月）。
    static func relativeDate(_ range: RelativeDateRange) -> FilterRule {
        FilterRule(field: FilterFields.relativeDate, operator: .eq, value: .string(range.rawValue))
    }

    /// 差集的完整形态：属于 from，且不属于 excluding 中任意一个。
    static func collectionDifference(from: String, excluding: [String]) -> FilterGroup {
        var conditions: [FilterCondition] = [.rule(inCollection(from))]
        if !excluding.isEmpty {
            conditions.append(.group(FilterGroup(
                logic: .not,
                conditions: excluding.map { .rule(inCollection($0)) }
            )))
        }
        return FilterGroup(logic: .and, conditions: conditions)
    }
}
