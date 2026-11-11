// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/FacetQuery.swift
// P1 / C：facet 计数（一次往返、按维度 GROUP BY、排除自身维度）。
// P1 下一波 §3.6.4：新增 keyword 维（层级下钻 + 按逻辑资产去重）。
//
// 语义（与 Lightroom / Bridge 的筛选面板一致）：
// - 同维多选取并集、跨维取交集 → 计算某一维的计数时，必须先把该维自己的规则
//   从条件树里剔除（FilterGroup.removing），否则选了机身 A 之后镜头只剩 A 的；
// - 计数口径必须与网格一致（同 session、同 base 条件），否则面板数字对不上列表。
//
// keyword 维为什么单独一条 SQL：
// - 关键词在 photo_keywords（一张照片多行），其它维在 photo_metadata_cache 的单行；
// - 网格按逻辑资产（COALESCE(asset_id, id)）出图，因此 facet 必须
//   COUNT(DISTINCT COALESCE(NULLIF(p.asset_id,''), p.id))，不能用行数计数，
//   更不能拿 keywords.usage_count 当展示计数（它只是排序权重）。
//
// 刻意不复用 PhotoFilterQuery.filterPhotos：那条 SQL 带 SELECT DISTINCT 与
// face_count 相关子查询，是给分页网格用的；facet 只要 COUNT。
import Foundation
import GatherProtocol

public struct FacetBucket: Codable, Equatable, Sendable {
    public var value: String
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

public enum FacetDimension: String, Codable, CaseIterable, Sendable {
    case camera
    case lens
    case iso
    case year
    case label
    case keyword
    /// Wave2 / task-14：场景/事件标签（photo_keywords 中 `SemanticKeywordPath.scene` 子树的下一段）。
    case scene
    /// Wave2 / task-14：人物（person_photos；桶值 = persons.name）。
    case person

    /// 用于剔除同维规则时匹配的 FilterRule.field。
    ///
    /// scene 复用 keyword_path：场景桶的选择规则就是 `keyword_path starts_with`，
    /// 这样"选了一个场景之后场景维仍然列其它场景（并集）、其它维按场景收窄"的
    /// 口径与 keyword 维完全一致，不需要第二套规则类型。
    /// person 复用图库既有的 `person` 规则字段（PhotoFilterQuery 的 persons EXISTS）。
    public var field: String {
        switch self {
        case .camera: FilterFields.cameraModel
        case .lens: FilterFields.lensModel
        case .iso: FilterFields.iso
        case .year: FilterFields.dateTaken
        case .label: FilterFields.label
        case .keyword: FilterFields.keywordPath
        case .scene: FilterFields.keywordPath
        case .person: Self.personField
        }
    }

    /// 图库 `person` 过滤条件的字段名（FilterFields 在 Protocol 里没有该常量，
    /// 这里保留唯一副本；PhotoFilterQuery.buildPersonCondition 消费同一字面量）。
    static let personField = "person"

    /// SQL 投影：必须与 field 的语义一致（year 是 date_taken 的前 4 位）。
    /// keyword 维不在 photo_metadata_cache 上，投影见 keywordBuckets。
    var expression: String {
        switch self {
        case .camera: "pmc.camera_model"
        case .lens: "pmc.lens_model"
        case .iso: "CAST(pmc.iso AS TEXT)"
        case .year: "substr(pmc.date_taken, 1, 4)"
        case .label: "pmc.label"
        // keyword/scene/person 不在 photo_metadata_cache 单行上，各有专用 SQL：
        // keyword → keywordBuckets、scene → keywordBuckets(prefix:)、person → personBuckets。
        case .keyword, .scene, .person: ""
        }
    }
}

public final class FacetQuery {
    private let connection: DBConnection
    /// 共享的 WHERE 构建器：facet 与带 criteria 的分页必须走同一条 clause，
    /// 否则面板里的计数与网格行数对不上（§3.6 的"同口径"红线）。
    /// LivePhotoAPI 的 page(criteria:) 复用它，因此这里不另建一份。
    public let filterQuery: PhotoFilterQuery

    public init(connection: DBConnection) {
        self.connection = connection
        self.filterQuery = PhotoFilterQuery(connection: connection)
    }

    /// 单维 facet；sessionId == "__global__" 时不加会话过滤（与 filterPhotos 同语义）。
    ///
    /// - keywordPrefix：仅 keyword 维生效（下钻节点；nil = 顶级桶）。
    ///   语义是"只看该节点及其子孙的照片，桶名取下一段"，与 FilterRule.keywordPath
    ///   的 starts_with 规则一致（点 A 之后面板列出 A 的子级，而不是全库首段）。
    public func buckets(
        sessionId: String,
        criteria: FilterGroup,
        dimension: FacetDimension,
        limit: Int = 60,
        keywordPrefix: String? = nil
    ) throws -> [FacetBucket] {
        switch dimension {
        case .keyword:
            return try keywordBuckets(
                sessionId: sessionId, criteria: criteria, limit: limit, prefix: keywordPrefix)
        case .scene:
            // 场景桶 = 默认根子树下的下一段；桶值即"图库 scene 字段"的值
            // （选择规则 keyword_path starts_with <root>|<桶值>）。
            return try keywordBuckets(
                sessionId: sessionId,
                criteria: criteria,
                limit: limit,
                prefix: SemanticKeywordPath.scene)
        case .person:
            return try personBuckets(
                sessionId: sessionId, criteria: criteria, limit: limit)
        case .camera, .lens, .iso, .year, .label:
            break
        }
        let scoped = criteria.removing(field: dimension.field)
        let clause = try filterQuery.whereClause(scoped)
        let sessionFilter = sessionId == "__global__" ? "1=1" : "p.session_id = ?"
        let expr = dimension.expression
        let sql = """
            WITH ranked AS (
              SELECT \(expr) AS v,
                     ROW_NUMBER() OVER (
                       PARTITION BY COALESCE(NULLIF(p.asset_id, ''), p.id)
                       ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p"))
                     ) AS rn
              FROM photos p
              LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
              WHERE \(sessionFilter) AND (\(clause.sql.isEmpty ? "1=1" : clause.sql))
                AND \(PhotoVisibility.visiblePredicate())
            )
            SELECT v, COUNT(*) AS n
            FROM ranked
            WHERE rn = 1 AND v IS NOT NULL AND v <> ''
            GROUP BY v
            ORDER BY n DESC, v ASC
            LIMIT ?
            """
        var params: [DBValue] = sessionId == "__global__" ? clause.params : [.text(sessionId)] + clause.params
        params.append(.int(Int64(max(1, limit))))
        return try connection.prepare(sql).query(params).map { row in
            FacetBucket(value: row[0].textValue ?? "", count: Int(row[1].intValue ?? 0))
        }
    }

    /// keyword 维：顶级桶（首段）或下钻桶（prefix 之后的下一段）。
    ///
    /// 计数口径 = 网格口径：COUNT(DISTINCT COALESCE(NULLIF(asset_id,''), id))。
    /// 下钻用**范围**比较（[prefix|, prefix|\u{10FFFF})）而不是 LIKE 'prefix%'：
    /// 默认 LIKE 是大小写不敏感，走不了 idx_photo_keywords_path，还会把
    /// "pathology" 当成 "path" 的子孙。
    public func keywordBuckets(
        sessionId: String,
        criteria: FilterGroup,
        limit: Int = 60,
        prefix: String?
    ) throws -> [FacetBucket] {
        let scoped = criteria.removing(field: FacetDimension.keyword.field)
        let clause = try filterQuery.whereClause(scoped)
        let sessionFilter = sessionId == "__global__" ? "1=1" : "p.session_id = ?"
        // 下钻桶的表达式：rest = substr(path, length(prefix) + 2)，取 rest 的首段。
        // 用 length(?) 让 SQLite 算字符数（与 substr 同口径），不让 Swift 传长度。
        let bucketExpr = """
            CASE WHEN instr(substr(pk.keyword_path, length(?) + 2), '|') > 0
                 THEN substr(substr(pk.keyword_path, length(?) + 2), 1,
                             instr(substr(pk.keyword_path, length(?) + 2), '|') - 1)
                 ELSE substr(pk.keyword_path, length(?) + 2) END
            """
        let topExpr = """
            CASE WHEN instr(pk.keyword_path, '|') > 0
                 THEN substr(pk.keyword_path, 1, instr(pk.keyword_path, '|') - 1)
                 ELSE pk.keyword_path END
            """
        let hasPrefix = !(prefix ?? "").isEmpty
        let prefixFilter = hasPrefix
            ? " AND (pk.keyword_path = ? OR (pk.keyword_path >= ? AND pk.keyword_path < ?))"
            : ""
        let sql = """
            SELECT v, COUNT(DISTINCT asset_key) AS n FROM (
              SELECT \(hasPrefix ? bucketExpr : topExpr) AS v,
                     COALESCE(NULLIF(p.asset_id, ''), p.id) AS asset_key
              FROM photo_keywords pk
              JOIN photos p ON p.id = pk.photo_id
              LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
              WHERE \(sessionFilter) AND (\(clause.sql.isEmpty ? "1=1" : clause.sql))
                AND \(PhotoVisibility.visiblePredicate(alias: "p"))\(prefixFilter)
            )
            WHERE v IS NOT NULL AND v <> ''
            GROUP BY v
            ORDER BY n DESC, v ASC
            LIMIT ?
            """
        // 绑定顺序必须与 SQL 文本里的出现顺序一致：
        // bucketExpr 的 4 个 length(?) → sessionId → clause 参数 → 前缀范围 3 参 → LIMIT。
        var params: [DBValue] = []
        if let prefix, hasPrefix {
            for _ in 0..<4 { params.append(.text(prefix)) }
        }
        if sessionId != "__global__" { params.append(.text(sessionId)) }
        params.append(contentsOf: clause.params)
        if let prefix, hasPrefix {
            params.append(.text(prefix))
            params.append(.text(KeywordPathSQL.subtreeLowerBound(prefix)))
            params.append(.text(KeywordPathSQL.subtreeUpperBound(prefix)))
        }
        params.append(.int(Int64(max(1, limit))))
        return try connection.prepare(sql).query(params).map { row in
            FacetBucket(value: row[0].textValue ?? "", count: Int(row[1].intValue ?? 0))
        }
    }

    /// person 维：桶值 = persons.name，计数口径与网格一致
    /// （COUNT(DISTINCT COALESCE(NULLIF(asset_id,''), id))，同 keyword 维）。
    ///
    /// 为什么用 EXISTS 式的 JOIN 而不是 person_photos 行数：一张照片可能有多条
    /// face_observations 指向同一个人，行数会把人物计数虚高。
    /// 同维剔除：`criteria.removing(field: "person")`，否则选了"张三"后人物维只剩张三。
    public func personBuckets(
        sessionId: String,
        criteria: FilterGroup,
        limit: Int = 60
    ) throws -> [FacetBucket] {
        let scoped = criteria.removing(field: FacetDimension.person.field)
        let clause = try filterQuery.whereClause(scoped)
        let sessionFilter = sessionId == "__global__" ? "1=1" : "p.session_id = ?"
        let sql = """
            SELECT per.name AS v,
                   COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id)) AS n
            FROM person_photos pp
            JOIN persons per ON per.id = pp.person_id
            JOIN photos p ON p.id = pp.photo_id
            LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
            WHERE \(sessionFilter) AND (\(clause.sql.isEmpty ? "1=1" : clause.sql))
              AND \(PhotoVisibility.visiblePredicate(alias: "p"))
              AND per.name IS NOT NULL AND per.name <> ''
            GROUP BY per.name
            ORDER BY n DESC, v ASC
            LIMIT ?
            """
        var params: [DBValue] = sessionId == "__global__" ? clause.params : [.text(sessionId)] + clause.params
        params.append(.int(Int64(max(1, limit))))
        return try connection.prepare(sql).query(params).map { row in
            FacetBucket(value: row[0].textValue ?? "", count: Int(row[1].intValue ?? 0))
        }
    }

    /// 一次取多个维度（面板首屏）：每维一条 GROUP BY，参数与会话过滤一致。
    public func buckets(
        sessionId: String,
        criteria: FilterGroup,
        dimensions: [FacetDimension],
        limit: Int = 60,
        keywordPrefix: String? = nil
    ) throws -> [FacetDimension: [FacetBucket]] {
        var result: [FacetDimension: [FacetBucket]] = [:]
        for dimension in dimensions {
            result[dimension] = try buckets(
                sessionId: sessionId, criteria: criteria, dimension: dimension,
                limit: limit, keywordPrefix: keywordPrefix
            )
        }
        return result
    }
}
