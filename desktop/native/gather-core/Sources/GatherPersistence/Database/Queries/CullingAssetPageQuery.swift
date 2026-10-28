// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/CullingAssetPageQuery.swift
// WP3b-2：Culling 分页/计数读模型下沉（原 CullingService 内联 SQL + 谓词拼接）。
//
// 迁移口径：SQL 与子句顺序逐字保留（filtered 两段式资产组 keyset 页、相似度
// 成员 EXISTS、countForScope 的 GROUP BY 子查询）。Application 只决定 scope，
// 谓词如何拼、分块多大、代表行规则如何写都留在这里。
import Foundation
import GatherProtocol

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
    /// P0 / T0：triage verdict 过滤（仅 filtered scope 使用）。
    public var triageVerdicts: [String]?
    /// P0 / T0：当前建议门控；非 nil 时过滤/排序都只认这一代建议行。
    /// nil = 未接入 T0（旧调用方/测试），保持历史行为。
    public var triageFingerprint: String?
    public var triagePolicyVersion: String?

    public init(
        decisions: [String]? = nil,
        ratings: [Double]? = nil,
        colorLabels: [String]? = nil,
        unreviewedOnly: Bool? = nil,
        metadataConflictOnly: Bool? = nil,
        qualityStatus: CullingQualityFilter? = nil,
        triageVerdicts: [String]? = nil,
        triageFingerprint: String? = nil,
        triagePolicyVersion: String? = nil
    ) {
        self.decisions = decisions
        self.ratings = ratings
        self.colorLabels = colorLabels
        self.unreviewedOnly = unreviewedOnly
        self.metadataConflictOnly = metadataConflictOnly
        self.qualityStatus = qualityStatus
        self.triageVerdicts = triageVerdicts
        self.triageFingerprint = triageFingerprint
        self.triagePolicyVersion = triagePolicyVersion
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

    /// 唯一的资产组 keyset 页：scope 决定 WHERE，sort 决定 keyset 键。
    /// 排序键按资产组聚合（variant 不参与排序）；并列恒用 first_rowid ASC。
    public func pageSorted(
        sessionId: String,
        scope: CullingScope,
        filter: CullingPageFilter,
        similarity: CullingSimilarityScope?,
        sort: CullingSort,
        cursor: CullingPageCursor?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: CullingPageCursor?) {
        let base: (sql: String, params: [DBValue?])
        switch scope {
        case .all:
            base = (
                "p.session_id = ? AND \(PhotoVisibility.visiblePredicate())",
                [.text(sessionId)]
            )
        case .filtered:
            base = filteredWhere(sessionId: sessionId, filter: filter)
        case .similarityGroup:
            // 组 id 无法解析时没有可比对的成员集合：空页而不是回退到全部照片。
            guard let similarity else { return ([], nil) }
            let clause = similarityClause(sessionId: sessionId, scope: similarity)
            base = (
                "p.session_id = ? AND \(clause.sql) AND \(preferredRowPredicate())"
                    + " AND \(PhotoVisibility.visiblePredicate())",
                [.text(sessionId)] + clause.params
            )
        }

        let sortExpression: String
        switch sort.keyKind {
        case .rowId:
            sortExpression = "MIN(p.rowid)"
        case .date:
            // EXIF DateTimeOriginal 落库是 "YYYY:MM:DD HH:MM:SS"；ISO 是 "YYYY-MM-DD..."。
            // 先归一，再交给 strftime 产出固定宽度文本。未知/非法日期统一成 ''。
            sortExpression = """
                COALESCE(strftime('%Y-%m-%dT%H:%M:%S', MAX(
                  CASE WHEN c.date_taken GLOB '????:??:??*'
                       THEN replace(substr(c.date_taken, 1, 10), ':', '-') || substr(c.date_taken, 11)
                       ELSE c.date_taken END
                )), '')
                """
        case .number:
            // 游标统一携带 REAL：rating 列是 INTEGER，不 CAST 会让 doubleValue 读成 0。
            sortExpression = sort == .ratingDesc
                ? "CAST(COALESCE(MAX(c.rating), 0) AS REAL)"
                // 2.0 是“无建议”的排序哨兵（confidence 恒在 0...1）；ASC 时排最后，
                // 与 T0 §7.3 的 nulls-last 一致，且游标可原样携带。
                : "CAST(COALESCE(MAX(t.confidence), 2.0) AS REAL)"
        }

        // triage 排序/过滤只认当前门控代；未接入门控的调用方保持历史 JOIN 行为。
        var triageJoin = ""
        var joinParams: [DBValue?] = []
        if let fingerprint = filter.triageFingerprint,
           let policyVersion = filter.triagePolicyVersion {
            triageJoin = " AND t.input_fingerprint = ? AND t.policy_version = ?"
            joinParams = [.text(fingerprint), .text(policyVersion)]
        }
        var inner = """
            SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
                   MIN(p.rowid) AS first_rowid,
                   \(sortExpression) AS sort_key
            FROM photos p
            LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
            LEFT JOIN triage_suggestions t
              ON t.photo_id = p.id AND t.session_id = p.session_id \(triageJoin)
            """
        if scope == .filtered {
            inner += "\n" + """
                LEFT JOIN culling_decisions d
                  ON d.session_id = p.session_id AND d.photo_id = p.id
                """
        }
        inner += "\nWHERE \(base.sql)\nGROUP BY gid"

        var sql = "SELECT gid, first_rowid, sort_key FROM (\(inner)) AS grouped"
        // 参数顺序必须与 SQL 文本一致：JOIN 在前、WHERE 在后。
        var params = joinParams
        params.append(contentsOf: base.params)
        if let cursor {
            let op = sort.descending ? "<" : ">"
            let key: DBValue = switch sort.keyKind {
            case .rowId: .int(cursor.rowId)
            case .date: .text(cursor.dateKey ?? "")
            case .number: .real(cursor.numberKey ?? 0)
            }
            sql += " WHERE (sort_key \(op) ?) OR (sort_key = ? AND first_rowid > ?)"
            params.append(key)
            params.append(key)
            params.append(.int(cursor.rowId))
        }
        sql += " ORDER BY sort_key \(sort.descending ? "DESC" : "ASC"), first_rowid ASC LIMIT ?"
        params.append(.int(Int64(limit)))

        let grouped = try connection.prepare(sql).query(params)
        let groups = grouped.map {
            (gid: $0[0].textValue ?? "", firstRowid: $0[1].intValue ?? 0, sortKey: $0[2])
        }
        let rows = try loadAssetRows(
            sessionId: sessionId,
            groups: groups.map { (gid: $0.gid, firstRowid: $0.firstRowid) }
        )
        // loadAssetRows 按 rowid 排序（导入序）；排序页必须按组序重排，
        // 否则一页内的组会按 rowid 回退（capture_desc 前 3 组变成 a1/a2/a3）。
        let groupOrder = Dictionary(
            uniqueKeysWithValues: groups.enumerated().map { ($1.gid, $0) }
        )
        let orderedRows = rows.sorted { lhs, rhs in
            let left = groupOrder[Self.assetGroupId(lhs)] ?? Int.max
            let right = groupOrder[Self.assetGroupId(rhs)] ?? Int.max
            if left != right { return left < right }
            return lhs.rowid < rhs.rowid
        }
        // 不足一页即末页，不再返回 cursor（避免 UI 多发一次空页请求）。
        let next = groups.count < limit ? nil : groups.last.map { last -> CullingPageCursor in
            switch sort.keyKind {
            case .rowId:
                return CullingPageCursor(sort: sort, rowId: last.firstRowid)
            case .date:
                return CullingPageCursor(
                    sort: sort, dateKey: last.sortKey.textValue ?? "", rowId: last.firstRowid)
            case .number:
                return CullingPageCursor(
                    sort: sort, numberKey: last.sortKey.doubleValue ?? 0, rowId: last.firstRowid)
            }
        }
        return (orderedRows, next)
    }

    private static func assetGroupId(_ row: PhotoPageRow) -> String {
        if let assetId = row.assetId, !assetId.isEmpty { return assetId }
        return row.id
    }

    // MARK: - 计数

    public func countFiltered(sessionId: String, filter: CullingPageFilter) throws -> Int {
        let whereClause = filteredWhere(sessionId: sessionId, filter: filter)
        // COUNT(DISTINCT gid) 直接聚合，省掉 GROUP BY 子查询的临时结果集。
        let row = try connection.prepare("""
            SELECT COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id))
            FROM photos p
            LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
            LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
            WHERE \(whereClause.sql)
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
                    AND \(PhotoVisibility.visiblePredicate())
                  GROUP BY gid)
          """).get([.text(sessionId)] + clause.params)
        return Int(row?[0].intValue ?? 0)
    }

    /// P0 / A1：当前 scope/filters 下的代表行 id（跨页"全选"与移出用）。
    ///
    /// 与 pageSorted 共用同一套 WHERE/代表行规则，只是不排序键集、只取 id：
    /// - 多取一行用于判断 truncated（UI 必须知道"没全选上"）；
    /// - 已归档照片同样被 PhotoVisibility 排除。
    public func representativeIds(
        sessionId: String,
        scope: CullingScope,
        filter: CullingPageFilter,
        similarity: CullingSimilarityScope?,
        limit: Int
    ) throws -> (ids: [String], truncated: Bool) {
        let base: (sql: String, params: [DBValue?])
        switch scope {
        case .all:
            base = (
                "p.session_id = ? AND \(PhotoVisibility.visiblePredicate())",
                [.text(sessionId)]
            )
        case .filtered:
            base = filteredWhere(sessionId: sessionId, filter: filter)
        case .similarityGroup:
            guard let similarity else { return ([], false) }
            let clause = similarityClause(sessionId: sessionId, scope: similarity)
            base = (
                "p.session_id = ? AND \(clause.sql)"
                    + " AND \(preferredRowPredicate()) AND \(PhotoVisibility.visiblePredicate())",
                [.text(sessionId)] + clause.params
            )
        }
        let sql = """
            SELECT p.id
            FROM photos p
            LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
            LEFT JOIN culling_decisions d
              ON d.session_id = p.session_id AND d.photo_id = p.id
            WHERE \(base.sql) AND \(preferredRowPredicate())
            ORDER BY p.rowid
            LIMIT ?
            """
        var params = base.params
        params.append(.int(Int64(max(1, limit) + 1)))
        let rows = try connection.prepare(sql).query(params)
        let ids = rows.compactMap { $0[0].textValue }
        if ids.count > limit {
            return (Array(ids.prefix(limit)), true)
        }
        return (ids, false)
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
                  AND \(PhotoVisibility.visiblePredicate())
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
            // P0：首选行必须在**可见**变体里选。否则 RAW 被移出后，子查询仍返回
            // 已归档的 RAW，可见的 JPEG 永远不等于它，整个资产从筛选/选择集消失。
            " AND \(PhotoVisibility.visiblePredicate(alias: "p2"))" +
            " ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))" +
            " LIMIT 1" +
        ")"
    }

    /// TS: buildFilteredWhere —— matchesFilters 的精确下推（顺序与旧实现一致）。
    private func filteredWhere(
        sessionId: String,
        filter: CullingPageFilter
    ) -> (sql: String, params: [DBValue?]) {
        var clauses: [String] = [
            "p.session_id = ?", PhotoVisibility.visiblePredicate(),
        ]
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
                      ORDER BY a3.updated_at DESC, a3.id DESC
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
        if let verdicts = filter.triageVerdicts, !verdicts.isEmpty {
            let placeholders = verdicts.map { _ in "?" }.joined(separator: ",")
            var gateClause = ""
            var gateParams: [DBValue?] = []
            if let fingerprint = filter.triageFingerprint,
               let policyVersion = filter.triagePolicyVersion {
                gateClause = " AND t2.input_fingerprint = ? AND t2.policy_version = ?"
                gateParams = [.text(fingerprint), .text(policyVersion)]
            }
            clauses.append("""
                EXISTS (
                  SELECT 1 FROM triage_suggestions t2
                  WHERE t2.session_id = p.session_id AND t2.photo_id = p.id
                    AND t2.verdict IN (\(placeholders))\(gateClause)
                    AND NOT EXISTS (
                      SELECT 1 FROM culling_decisions d
                      JOIN photos p2 ON p2.id = d.photo_id
                      WHERE d.session_id = t2.session_id
                        AND d.decision_source = 'manual'
                        AND d.decision <> 'pending'
                        AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                            = COALESCE(NULLIF(p.asset_id, ''), p.id)
                    )
                )
                """)
            params.append(contentsOf: verdicts.map { .text($0) })
            params.append(contentsOf: gateParams)
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
