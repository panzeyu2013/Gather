// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/FacetQuery.swift
// P1 / C：facet 计数（一次往返、按维度 GROUP BY、排除自身维度）。
//
// 语义（与 Lightroom / Bridge 的筛选面板一致）：
// - 同维多选取并集、跨维取交集 → 计算某一维的计数时，必须先把该维自己的规则
//   从条件树里剔除（FilterGroup.removing），否则选了机身 A 之后镜头只剩 A 的；
// - 计数口径必须与网格一致（同 session、同 base 条件），否则面板数字对不上列表。
//
// 刻意不复用 PhotoFilterQuery.filterPhotos：那条 SQL 带 SELECT DISTINCT 与
// face_count 相关子查询，是给分页网格用的；facet 只要 COUNT(*)。
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

    /// 用于剔除同维规则时匹配的 FilterRule.field。
    public var field: String {
        switch self {
        case .camera: "camera_model"
        case .lens: "lens_model"
        case .iso: "iso"
        case .year: "date_taken"
        case .label: "label"
        }
    }

    /// SQL 投影：必须与 field 的语义一致（year 是 date_taken 的前 4 位）。
    var expression: String {
        switch self {
        case .camera: "pmc.camera_model"
        case .lens: "pmc.lens_model"
        case .iso: "CAST(pmc.iso AS TEXT)"
        case .year: "substr(pmc.date_taken, 1, 4)"
        case .label: "pmc.label"
        }
    }
}

public final class FacetQuery {
    private let connection: DBConnection
    private let filterQuery: PhotoFilterQuery

    public init(connection: DBConnection) {
        self.connection = connection
        self.filterQuery = PhotoFilterQuery(connection: connection)
    }

    /// 单维 facet；sessionId == "__global__" 时不加会话过滤（与 filterPhotos 同语义）。
    public func buckets(
        sessionId: String,
        criteria: FilterGroup,
        dimension: FacetDimension,
        limit: Int = 60
    ) throws -> [FacetBucket] {
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

    /// 一次取多个维度（面板首屏）：每维一条 GROUP BY，参数与会话过滤一致。
    public func buckets(
        sessionId: String,
        criteria: FilterGroup,
        dimensions: [FacetDimension],
        limit: Int = 60
    ) throws -> [FacetDimension: [FacetBucket]] {
        var result: [FacetDimension: [FacetBucket]] = [:]
        for dimension in dimensions {
            result[dimension] = try buckets(
                sessionId: sessionId, criteria: criteria, dimension: dimension, limit: limit
            )
        }
        return result
    }
}
