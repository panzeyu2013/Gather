// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/CullingAssetPageQuery.swift
// WP3b-2：Culling 分页/计数读模型下沉（原 CullingService 内联 SQL + 谓词拼接）。
//
// 迁移口径：SQL 与子句顺序逐字保留（filtered 两段式资产组 keyset 页、相似度
// 成员 EXISTS、countForScope 的 GROUP BY 子查询）。Application 只决定 scope，
// 谓词如何拼、分块多大、代表行规则如何写都留在这里。
import Foundation

/// 过滤条件的存储侧投影（Application 的 CullingFilters 在调用前映射成本类型：
/// 枚举 → DB 字符串/驱动的分支由调用方决定，SQL 不依赖 Application 类型）。
public struct CullingPageFilter: Sendable, Equatable {
    /// 挑片决策（"keep" / "reject" / "pending"），nil = 不过滤。
    public var decisions: [String]?
    /// 星级（photo_metadata_cache.rating）。
    public var ratings: [Double]?
    /// 色标（photo_metadata_cache.label 的原始值）。
    public var colorLabels: [String]?
    /// 只看未审（culling_decisions 缺行视为 pending）。
    public var unreviewedOnly: Bool?
    /// 只看元数据冲突（deliveries.status='conflict' 且归属本会话）。
    public var metadataConflictOnly: Bool?
    /// 质量状态分支（与旧 buildFilteredWhere 的三分支一一对应）。
    public var qualityStatus: CullingQualityFilter?

    public init(
        decisions: [String]? = nil,
        ratings: [Double]? = nil,
        colorLabels: [String]? = nil,
        unreviewedOnly: Bool? = nil,
        metadataConflictOnly: Bool? = nil,
        qualityStatus: CullingQualityFilter? = nil
    ) {
        self.decisions = decisions
        self.ratings = ratings
        self.colorLabels = colorLabels
        self.unreviewedOnly = unreviewedOnly
        self.metadataConflictOnly = metadataConflictOnly
        self.qualityStatus = qualityStatus
    }
}

public enum CullingQualityFilter: Sendable, Equatable {
    case analysed
    case failed
    case unanalysed
}

/// 相似度范围：指定组（resultId:groupIndex）或"最新非预计算结果"。
public enum CullingSimilarityScope: Sendable, Equatable {
    case latest
    case group(resultId: Int64, groupIndex: Int64)
}

public final class CullingAssetPageQuery {
    /// 每批 IN 参数上限（与旧 CullingService.chunkSize 同值）。
    static let chunkSize = 800

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 资产页

    /// filtered scope：资产组 keyset 页 + 组内全部行。
    public func pageFiltered(
        sessionId: String,
        filter: CullingPageFilter,
        afterRowId: Int64?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        let whereClause = filteredWhere(sessionId: sessionId, filter: filter)
        let groups = try connection.prepare("""
            SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid, MIN(p.rowid) AS first_rowid
            FROM photos p
            LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
            LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
            WHERE \(whereClause.sql)
            GROUP BY COALESCE(NULLIF(p.asset_id, ''), p.id)
            HAVING MIN(p.rowid) > ?
            ORDER BY first_rowid
            LIMIT ?
          """).query(whereClause.params + [.int(afterRowId ?? 0), .int(Int64(limit))])
        let gids = groups.map { (gid: $0[0].textValue ?? "", firstRowid: $0[1].intValue ?? 0) }
        return (try loadAssetRows(sessionId: sessionId, groups: gids), gids.last?.firstRowid)
    }

    /// similarityGroup scope：成员 EXISTS 谓词 + 首选行限定，同样两段式。
    public func pageSimilarity(
        sessionId: String,
        similarity: CullingSimilarityScope,
        afterRowId: Int64?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        let clause = similarityClause(sessionId: sessionId, scope: similarity)
        let groups = try connection.prepare("""
            SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid, MIN(p.rowid) AS first_rowid
            FROM photos p
            WHERE p.session_id = ? AND \(clause.sql) AND \(preferredRowPredicate())
            GROUP BY COALESCE(NULLIF(p.asset_id, ''), p.id)
            HAVING MIN(p.rowid) > ?
            ORDER BY first_rowid
            LIMIT ?
          """).query(
            [.text(sessionId)] + clause.params
                + [.int(afterRowId ?? 0), .int(Int64(limit))]
        )
        let gids = groups.map { (gid: $0[0].textValue ?? "", firstRowid: $0[1].intValue ?? 0) }
        return (try loadAssetRows(sessionId: sessionId, groups: gids), gids.last?.firstRowid)
    }

    // MARK: - 计数

    public func countFiltered(sessionId: String, filter: CullingPageFilter) throws -> Int {
        let whereClause = filteredWhere(sessionId: sessionId, filter: filter)
        let row = try connection.prepare("""
            SELECT COUNT(*) AS count
            FROM (SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
                  FROM photos p
                  LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
                  LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
                  WHERE \(whereClause.sql)
                  GROUP BY gid)
          """).get(whereClause.params)
        return Int(row?[0].intValue ?? 0)
    }

    public func countSimilarity(sessionId: String, similarity: CullingSimilarityScope) throws -> Int {
        let clause = similarityClause(sessionId: sessionId, scope: similarity)
        let row = try connection.prepare("""
            SELECT COUNT(*) AS count
            FROM (SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
                  FROM photos p
                  WHERE p.session_id = ? AND \(clause.sql)
                    AND \(preferredRowPredicate())
                  GROUP BY gid)
          """).get([.text(sessionId)] + clause.params)
        return Int(row?[0].intValue ?? 0)
    }

    // MARK: - 谓词（原 CullingService 内联拼接）

    /// TS: loadAssetRows —— 取给定资产组的全部行（分块，SQLite 参数上限内）。
    private func loadAssetRows(
        sessionId: String,
        groups: [(gid: String, firstRowid: Int64)]
    ) throws -> [PhotoPageRow] {
        if groups.isEmpty { return [] }
        var rows: [PhotoPageRow] = []
        for chunkStart in stride(from: 0, to: groups.count, by: Self.chunkSize) {
            let chunk = groups[chunkStart..<min(chunkStart + Self.chunkSize, groups.count)].map(\.gid)
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let chunkRows = try connection.prepare("""
                SELECT \(PhotoRepo.photoPageColumns)
                FROM photos p
                WHERE p.session_id = ? AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (\(placeholders))
                ORDER BY p.rowid
              """).query([.text(sessionId)] + chunk.map { .text($0) })
            rows.append(contentsOf: try chunkRows.map { try PhotoPageRow(row: $0) })
        }
        return rows
    }

    /// TS: preferredRowPredicate —— 每个资产组限定到首选行（规则来自 PhotoRepo，
    /// 与图库/导出的代表行同源）。
    private func preferredRowPredicate() -> String {
        "p.id = (" +
            "SELECT p2.id FROM photos p2" +
            " WHERE p2.session_id = p.session_id" +
            " AND COALESCE(NULLIF(p2.asset_id, ''), p2.id) = COALESCE(NULLIF(p.asset_id, ''), p.id)" +
            " ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))" +
            " LIMIT 1" +
        ")"
    }

    /// TS: buildFilteredWhere —— matchesFilters 的精确下推（顺序与旧实现一致）。
    private func filteredWhere(
        sessionId: String,
        filter: CullingPageFilter
    ) -> (sql: String, params: [DBValue?]) {
        var clauses: [String] = ["p.session_id = ?"]
        var params: [DBValue?] = [.text(sessionId)]
        if filter.unreviewedOnly == true {
            clauses.append("COALESCE(d.decision, 'pending') = 'pending'")
        }
        if let decisions = filter.decisions, !decisions.isEmpty {
            let placeholders = decisions.map { _ in "?" }.joined(separator: ",")
            clauses.append("COALESCE(d.decision, 'pending') IN (\(placeholders))")
            params.append(contentsOf: decisions.map { .text($0) })
        }
        // 星级/色标只读唯一真相源 c（photo_metadata_cache）。
        if let ratings = filter.ratings, !ratings.isEmpty {
            let placeholders = ratings.map { _ in "?" }.joined(separator: ",")
            clauses.append("COALESCE(c.rating, 0) IN (\(placeholders))")
            params.append(contentsOf: ratings.map { DBValue.real($0) })
        }
        if let colorLabels = filter.colorLabels, !colorLabels.isEmpty {
            let placeholders = colorLabels.map { _ in "?" }.joined(separator: ",")
            clauses.append("""
                COALESCE(NULLIF(c.label, ''), 'None') IN (\(placeholders))
                """)
            params.append(contentsOf: colorLabels.map { .text($0) })
        }
        if filter.metadataConflictOnly == true {
            clauses.append("""
                EXISTS (
                  SELECT 1 FROM deliveries d
                  JOIN delivery_sessions ds ON ds.delivery_id = d.id
                  WHERE ds.session_id = ? AND d.status = 'conflict'
                    AND d.photo_path = p.filepath
                )
                """)
            params.append(.text(sessionId))
        }
        if let qualityStatus = filter.qualityStatus {
            switch qualityStatus {
            case .analysed, .failed:
                // json_valid() 防护历史行 result_json 非法的情形。
                clauses.append("""
                    json_extract(COALESCE((
                      SELECT a3.result_json
                      FROM asset_analysis a3
                      WHERE a3.asset_file_id = p.asset_file_id
                        AND a3.analysis_type = 'technical_quality'
                        AND json_valid(a3.result_json)
                      ORDER BY a3.updated_at DESC
                      LIMIT 1
                    ), '{}'), '$.status') = ?
                    """)
                params.append(.text(qualityStatus == .analysed ? "succeeded" : "failed"))
            case .unanalysed:
                clauses.append("""
                    NOT EXISTS (
                      SELECT 1 FROM asset_analysis a3
                      WHERE a3.asset_file_id = p.asset_file_id
                        AND a3.analysis_type = 'technical_quality'
                        AND json_valid(a3.result_json)
                    )
                    """)
            }
        }
        clauses.append(preferredRowPredicate())
        return (clauses.joined(separator: " AND "), params)
    }

    /// TS: buildSimilarityClause —— 相似度组成员关系的 SQL 谓词。
    private func similarityClause(
        sessionId: String,
        scope: CullingSimilarityScope
    ) -> (sql: String, params: [DBValue?]) {
        switch scope {
        case let .group(resultId, groupIndex):
            return (
                sql: """
                EXISTS (
                  SELECT 1 FROM similarity_result_members srm
                  WHERE srm.result_id = ? AND srm.group_index = ? AND srm.session_id = ?
                    AND srm.photo_id = p.id
                )
                """,
                params: [.int(resultId), .int(groupIndex), .text(sessionId)]
            )
        case .latest:
            // 预计算阈值层共享同一张表：裸 MAX(id) 会选中最新层而非 getLatest 解析到的
            // 分析/重聚类行，故 JS 侧相似度映射与 SQL 谓词必须一致。
            return (
                sql: """
                EXISTS (
                  SELECT 1 FROM similarity_result_members srm
                  WHERE srm.session_id = ? AND srm.photo_id = p.id
                    AND srm.result_id = (
                      SELECT MAX(id) FROM similarity_results
                      WHERE session_id = ? AND stats_json NOT LIKE '%"precomputed":true%'
                    )
                )
                """,
                params: [.text(sessionId), .text(sessionId)]
            )
        }
    }
}
