// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/PhotoFilterQuery.swift
// WP3b-1：FilterEngine 的 SQL 生成与执行下沉。
//
// 迁移动机：FilterEngine 曾是 Application 里唯一「动态拼 SQL + 直接执行」的
// 查询对象（5 处 prepare）。现在：
//   - SQL 生成（SIMPLE/METADATA 字段、13 操作符、keywords json_each、
//     has_face/person/volume/has_duplicates、membership、代表行规则）全部在本文件；
//   - Application 的 FilterEngine 只保留公开门面（buildWhereClause 包装）与
//     FilteredPhotoData 行映射所需的字段转换。
// SQL 文本、参数顺序、分块/钳制语义逐条照搬，未改行为。
import Foundation
import GatherProtocol

public struct FilterWhereClause: Equatable, Sendable {
    public let sql: String
    public let params: [DBValue]

    public init(sql: String, params: [DBValue]) {
        self.sql = sql
        self.params = params
    }
}

/// filterPhotos 的命名行投影（FilterEngine 再映射为 FilteredPhotoData）。
public struct FilteredPhotoRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let faceCount: Int
    public let status: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        checksum: String,
        faceCount: Int,
        status: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.faceCount = faceCount
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public final class PhotoFilterQuery {
    /// TS: SIMPLE_FIELDS。
    public static let simpleFields: Set<String> = [
        "filename", "filepath", "checksum", "status", "created_at",
    ]
    /// TS: METADATA_FIELDS。
    public static let metadataFields: Set<String> = [
        "date_taken", "camera_make", "camera_model", "lens_model",
        "focal_length", "f_number", "exposure_time", "iso", "rating",
        "gps_latitude", "gps_longitude", "width", "height", "file_size", "file_mtime", "label",
    ]

    /// P1 / C：iptc_json 里可按列语义查询的字段（field 名 → JSON key）。
    /// 注意 caption 的对外字段名是 description（IPTC "Description"），内部 JSON key 是 caption。
    public static let jsonFields: [String: String] = [
        // IPTC Core
        "title": "title",
        "description": "caption",
        "headline": "headline",
        "creator": "creator",
        "creator_job_title": "creatorJobTitle",
        "credit": "credit",
        "source": "source",
        "copyright": "copyrightNotice",
        "usage_terms": "usageTerms",
        "web_statement": "webStatement",
        "job_identifier": "jobIdentifier",
        "caption_writer": "captionWriter",
        // Wave5（batch2）：IPTC Core Instructions / IPTC Ext Event Id / PLUS release id。
        "instructions": "instructions",
        "subject_code": "subjectCode",
        "scene": "scene",
        "intellectual_genre": "intellectualGenre",
        "location": "location",
        "city": "city",
        "state": "state",
        "country": "country",
        "country_code": "countryCode",
        "date_created": "dateCreated",
        // IPTC Extension
        "person_in_image": "personInImage",
        "event": "event",
        "event_identifier": "eventIdentifier",
        "organisation_in_image": "organisationInImage",
        "sublocation": "sublocation",
        "world_region": "worldRegion",
        "province_state": "provinceState",
        "model_release_status": "modelReleaseStatus",
        "model_release_id": "modelReleaseID",
        "property_release_status": "propertyReleaseStatus",
        "property_release_id": "propertyReleaseID",
        "digital_source_type": "digitalSourceType",
        "additional_model_info": "additionalModelInfo",
    ]

    /// 值为 JSON 数组的字段：eq/in/contains 必须对数组元素判定，不能比较整段 JSON。
    /// 覆盖 DescriptiveMetadata 的全部 list 形状字段（contactInfo 是结构，不在此列；
    /// 它的人员/地址检索走 city/country 等标量字段）。
    public static let jsonArrayFields: Set<String> = [
        "creator", "person_in_image", "subject_code", "scene", "organisation_in_image",
        // Wave5（batch2）：标准里 eventIdentifier / releaseID 都是 string + multi（Bag）。
        "event_identifier", "model_release_id", "property_release_id",
    ]

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// TS: whereClause —— 递归组合；空组 → sql:''（调用方视为 1=1）。
    public func whereClause(_ group: FilterGroup) throws -> FilterWhereClause {
        try buildWhereClause(group)
    }

    /// TS: filterPhotos —— 引擎内不钳制 limit/offset。
    public func filterPhotos(
        sessionId: String,
        criteria: FilterGroup,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> [FilteredPhotoRow] {
        let clause = try buildWhereClause(criteria)
        let sessionFilter = sessionId == "__global__" ? "1=1" : "p.session_id = ?"
        // 无 DISTINCT（性能审计 R3）：这条查询**没有任何可增殖行的 JOIN** ——
        // (a) `LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id` 是 1:1
        //     （Schema: photo_metadata_cache.photo_id UNIQUE）；
        // (b) buildWhereClause 只生成标量比较 / EXISTS / 子查询（person、keywords、
        //     keyword_path、collection/stack、has_face、volume 全是 EXISTS），不 JOIN 主查询。
        // 因此每张照片至多一行，DISTINCT 去掉不改变结果集与顺序，只省掉一次
        // TEMP B-TREE（bench: scripts/perf-sqlite-bench.py --compare）。
        let sql = [
            "SELECT p.id AS id, p.session_id AS session_id, p.filepath AS filepath,",
            "p.filename AS filename, p.checksum AS checksum, p.status AS status,",
            "p.created_at AS created_at, p.updated_at AS updated_at,",
            "(SELECT COUNT(*) FROM face_observations fo WHERE fo.photo_id = p.id AND fo.session_id = p.session_id) AS face_count",
            "FROM photos p",
            "LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id",
            "WHERE \(sessionFilter) AND (\(clause.sql.isEmpty ? "1=1" : clause.sql))",
            // P0 / A1：已移出工作区的照片不进入图库/检索结果。
            "AND \(PhotoVisibility.visiblePredicate())",
        ].joined(separator: " ")

        var allParams: [DBValue] = sessionId == "__global__" ? clause.params : [.text(sessionId)] + clause.params
        var resolvedSql = sql
        if let sortBy {
            resolvedSql += " ORDER BY \(resolveSortColumn(sortBy)) \(sortOrder == "asc" ? "ASC" : "DESC")"
        }
        if let limit {
            resolvedSql += " LIMIT ?"
            allParams.append(.int(Int64(limit)))
        }
        if let offset {
            // SQLite 的 OFFSET 必须跟 LIMIT；只传 offset 时补 LIMIT -1（不限行）。
            if limit == nil { resolvedSql += " LIMIT -1" }
            resolvedSql += " OFFSET ?"
            allParams.append(.int(Int64(offset)))
        }

        let rows = try connection.prepare(resolvedSql).queryNamed(allParams)
        return try rows.map(rowToPhotoRow)
    }

    /// P1 下一波 §3.7.1：带 criteria 的资产分页（photo.list_page 的游标语义）。
    ///
    /// 与 `PhotoRepo.getAssetPage` 的关系：
    /// - 同一套"按逻辑资产分组、游标 = 上一页最后一个资产组的首行 rowid"；
    /// - 差别只有一个 AND：资产必须**至少有一行**满足 criteria（代表行的挑选仍在
    ///   API 装配层按 RAW/JPEG 角色做，所以这里返回组内全部行）；
    /// - 排序只支持导入顺序（rowid）正/逆序：PhotoPage.cursor 是 Int64，
    ///   按 date_taken/rating 排序需要 (排序值, rowid) 复合游标才能跨页不重复，
    ///   那种查询走 PhotoAPI.search 的 offset 分页。
    ///   因此这里**只按 photos.rowid 排**（A4：descending 同时作用于游标比较与
    ///   行取回）；PhotoPageQuery.sortBy 的两个允许值（rowid / import_order）都落到
    ///   同一个 rowid 顺序，本方法不 JOIN session_assets 去读 import_order 列。
    public func assetPage(
        sessionId: String,
        criteria: FilterGroup?,
        afterFirstRowid: Int64?,
        limit: Int,
        descending: Bool = false
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        let clause = try buildWhereClause(criteria ?? FilterGroup(logic: .and, conditions: []))
        let predicate = clause.sql.isEmpty ? "1=1" : clause.sql
        let direction = descending ? "DESC" : "ASC"
        let comparison = descending ? "<" : ">"
        let cursorValue = afterFirstRowid ?? (descending ? Int64.max : 0)
        let groups = try connection.prepare("""
            WITH matching AS (
              SELECT p.rowid AS rowid,
                     COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
              FROM photos p
              LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
              WHERE p.session_id = ? AND (\(predicate))
                AND \(PhotoVisibility.visiblePredicate(alias: "p"))
            ),
            asset_groups AS (
              SELECT gid, MIN(rowid) AS first_rowid
              FROM matching
              GROUP BY gid
              HAVING MIN(rowid) \(comparison) ?
              ORDER BY MIN(rowid) \(direction)
              LIMIT ?
            )
            SELECT gid, first_rowid FROM asset_groups ORDER BY first_rowid \(direction)
            """).query(
                [.text(sessionId)] + clause.params
                    + [.int(cursorValue), .int(Int64(max(1, limit)))])
        if groups.isEmpty { return ([], nil) }
        let gids = groups.map { row in
            (gid: row[0].textValue ?? "", firstRowid: row[1].intValue ?? 0)
        }
        var rows: [PhotoPageRow] = []
        for chunkStart in stride(from: 0, to: gids.count, by: 800) {
            let chunk = gids[chunkStart..<min(chunkStart + 800, gids.count)].map(\.gid)
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            // A4：行序与游标方向必须一致（原实现固定 ORDER BY p.rowid ASC，降序页
            // 的游标按 DESC 推进、页内行却仍升序 —— 首页"最新在前"之后每一页都反着
            // 排，UI 直接拼接时出现锯齿）。
            let chunkRows = try connection.prepare("""
                SELECT \(PhotoRepo.photoPageColumns) FROM photos p
                WHERE p.session_id = ?
                  AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (\(placeholders))
                  AND \(PhotoVisibility.visiblePredicate(alias: "p"))
                ORDER BY p.rowid \(direction)
                """).query([.text(sessionId)] + chunk.map { .text($0) })
            rows.append(contentsOf: try chunkRows.map { try PhotoPageRow(row: $0) })
        }
        // 排序方向一致：降序页的游标要回到组首，UI 只把它当不透明标记传回。
        return (rows, gids[gids.count - 1].firstRowid)
    }

    /// TS: filterGlobally —— 引擎内钳制 limit 1..500 / offset ≥0。
    public func filterGlobally(
        criteria: FilterGroup,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        sessionId: String? = nil
    ) throws -> [GlobalPhotoResult] {
        let clause = try buildWhereClause(criteria)
        let membershipFilter = membershipSql(sessionId)
        let sql = [
            "WITH matching AS (",
            "SELECT p.rowid AS photo_rowid, COALESCE(NULLIF(p.asset_id, ''), p.id) AS asset_key",
            "FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id",
            "WHERE (\(clause.sql.isEmpty ? "1=1" : clause.sql)) \(membershipFilter)",
            "AND \(PhotoVisibility.visiblePredicate())",
            "), ranked AS (",
            "SELECT matching.asset_key, matching.photo_rowid,",
            "ROW_NUMBER() OVER (PARTITION BY matching.asset_key",
            "  ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p"))) AS preference_rank",
            "FROM matching JOIN photos p ON p.rowid = matching.photo_rowid",
            "), representatives AS (",
            "SELECT asset_key, photo_rowid FROM ranked WHERE preference_rank = 1",
            "), asset_rollup AS (",
            // 一次分组聚合替代两个逐行相关子查询；100k 会话下这是主要成本。
            "SELECT COALESCE(NULLIF(member.asset_id, ''), member.id) AS asset_key,",
            "GROUP_CONCAT(DISTINCT member.session_id) AS session_ids,",
            "GROUP_CONCAT(DISTINCT member_session.name) AS session_names",
            "FROM photos member",
            "JOIN sessions member_session ON member_session.id = member.session_id",
            // 跨会话汇总同样只统计仍在工作区的成员（否则归档件会把会话数+名字带出来）。
            "WHERE \(PhotoVisibility.visiblePredicate(alias: "member"))",
            "GROUP BY asset_key",
            ")",
            "SELECT p.id AS photo_id, COALESCE(NULLIF(p.asset_id, ''), p.id) AS asset_id,",
            "p.session_id, s.name AS session_name, p.filename, p.filepath, p.status,",
            "COALESCE(pmc.rating, 0) AS rating, COALESCE(pmc.label, '') AS label,",
            "COALESCE(pmc.keywords, '[]') AS keywords,",
            "asset_rollup.session_ids AS session_ids,",
            "asset_rollup.session_names AS session_names",
            "FROM representatives JOIN photos p ON p.rowid = representatives.photo_rowid",
            "LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id",
            "JOIN sessions s ON p.session_id = s.id",
            "LEFT JOIN asset_rollup ON asset_rollup.asset_key = representatives.asset_key",
            sortBy != nil
                ? "ORDER BY \(resolveSortColumn(sortBy!)) \(sortOrder == "asc" ? "ASC" : "DESC")"
                : "ORDER BY p.rowid",
        ].joined(separator: " ")

        var params: [DBValue] = clause.params
        if sessionId != nil { params.append(.text(sessionId!)) }
        var paginatedSql = sql
        if let limit {
            paginatedSql += " LIMIT ?"
            params.append(.int(Int64(max(1, min(500, Int(floor(Double(limit))))))))
            if let offset {
                paginatedSql += " OFFSET ?"
                params.append(.int(Int64(max(0, Int(floor(Double(offset)))))))
            }
        }
        let rows = try connection.prepare(paginatedSql).query(params)
        return rows.map { row in
            // SELECT 共 12 列（0-11）：session_ids(10) / session_names(11)。
            let sessionIds = (row[10].textValue ?? "").split(separator: ",").map(String.init)
            let sessionNames = (row[11].textValue ?? "").split(separator: ",").map(String.init)
            return GlobalPhotoResult(
                photoId: row[0].textValue ?? "",
                assetId: row[1].textValue ?? "",
                sessionId: row[2].textValue ?? "",
                sessionName: row[3].textValue ?? "",
                sessionIds: sessionIds.isEmpty ? [row[2].textValue ?? ""] : sessionIds,
                sessionNames: sessionNames.isEmpty ? [row[3].textValue ?? ""] : sessionNames,
                filename: row[4].textValue ?? "",
                filepath: row[5].textValue ?? "",
                status: row[6].textValue ?? "",
                rating: row[7].doubleValue
                    ?? row[7].intValue.map(Double.init) ?? 0,
                label: row[8].textValue ?? "",
                keywords: parseKeywords(row[9].textValue ?? "[]")
            )
        }
    }

    /// TS: countGlobally。
    /// 图库“全选”专用：一次 CTE 取代表行 id，最多 20k。
    /// 与 filterGlobally 同源（同 WHERE/同 preferred 代表行），只去掉跨会话 rollup。
    public func filterGloballyIDs(
        criteria: FilterGroup,
        sessionId: String,
        limit: Int
    ) throws -> [String] {
        let clause = try buildWhereClause(criteria)
        let sql = """
            WITH matching AS (
              SELECT p.rowid AS photo_rowid,
                     COALESCE(NULLIF(p.asset_id, ''), p.id) AS asset_key
              FROM photos p
              LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
              WHERE (\(clause.sql.isEmpty ? "1=1" : clause.sql))
                AND p.session_id = ?
                AND \(PhotoVisibility.visiblePredicate())
            ), ranked AS (
              SELECT matching.asset_key, matching.photo_rowid,
                     ROW_NUMBER() OVER (PARTITION BY matching.asset_key
                       ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p"))) AS preference_rank
              FROM matching JOIN photos p ON p.rowid = matching.photo_rowid
            ), representatives AS (
              SELECT asset_key, photo_rowid FROM ranked WHERE preference_rank = 1
            )
            SELECT p.id AS photo_id
            FROM representatives JOIN photos p ON p.rowid = representatives.photo_rowid
            ORDER BY p.rowid
            LIMIT ?
            """
        var params = clause.params
        params.append(.text(sessionId))
        params.append(.int(Int64(max(1, min(20_000, limit)))))
        let rows = try connection.prepare(sql).query(params)
        return rows.compactMap { $0[0].textValue }
    }

    public func countGlobally(criteria: FilterGroup, sessionId: String? = nil) throws -> Int {
        let clause = try buildWhereClause(criteria)
        let membershipFilter = membershipSql(sessionId)
        var params = clause.params
        if sessionId != nil { params.append(.text(sessionId!)) }
        guard let row = try connection.prepare("""
            SELECT COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id)) AS count
            FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
            WHERE (\(clause.sql.isEmpty ? "1=1" : clause.sql)) \(membershipFilter)
              AND \(PhotoVisibility.visiblePredicate())
        """).get(params) else { return 0 }
        return Int(row[0].intValue ?? 0)
    }

    /// TS: countPhotos —— __global__ 时 asset 去重。
    public func countPhotos(sessionId: String, criteria: FilterGroup) throws -> Int {
        let clause = try buildWhereClause(criteria)
        let sessionFilter = sessionId == "__global__" ? "1=1" : "p.session_id = ?"
        let allParams: [DBValue] = sessionId == "__global__" ? clause.params : [.text(sessionId)] + clause.params
        let countExpression = sessionId == "__global__"
            ? "COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id))"
            : "COUNT(DISTINCT p.id)"
        guard let row = try connection.prepare("""
            SELECT \(countExpression) AS count
            FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
            WHERE \(sessionFilter) AND (\(clause.sql.isEmpty ? "1=1" : clause.sql))
              AND \(PhotoVisibility.visiblePredicate())
        """).get(allParams) else { return 0 }
        return Int(row[0].intValue ?? 0)
    }

    /// K0：相机（会话内，≥2 字符）+ 关键词（1 个汉字也允许，按 fold 包含匹配）。
    /// 相机在前；空态返回空数组，不编造建议。
    public func suggest(_ sessionId: String, keyword: String) throws -> [FilterSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var suggestions: [FilterSuggestion] = []

        if trimmed.count >= 2 {
            let pattern = "%\(escapeLike(trimmed))%"
            // 建议只来自仍在工作区的照片：否则会给出"只存在于 _rejects"的机型，
            // 选中后网格 0 结果（P2）。
            let cameraRows = try connection.prepare("""
                SELECT DISTINCT c.camera_make FROM photo_metadata_cache c
                JOIN photos p ON p.id = c.photo_id
                WHERE c.session_id = ? AND \(PhotoVisibility.visiblePredicate(alias: "p"))
                  AND c.camera_make LIKE ? ESCAPE '\\'
                LIMIT 5
                """).query([.text(sessionId), .text(pattern)])
            let cameras = cameraRows.compactMap { $0[0].textValue }
            if !cameras.isEmpty {
                suggestions.append(FilterSuggestion(field: "camera_make", values: cameras))
            }
        }

        let keywordRows = try connection.prepare("""
            SELECT c.keywords FROM photo_metadata_cache c
            JOIN photos p ON p.id = c.photo_id
            WHERE c.session_id = ? AND \(PhotoVisibility.visiblePredicate(alias: "p"))
              AND c.keywords LIKE ? ESCAPE '\\'
            LIMIT 200
            """).query([.text(sessionId), .text("%\(escapeLike(trimmed))%")])
        let needle = KeywordNormalizer.fold(trimmed)
        var seen = Set<String>()
        var keywords: [String] = []
        let decoder = JSONDecoder()
        for row in keywordRows {
            guard keywords.count < 8,
                  let text = row[0].textValue,
                  let data = text.data(using: .utf8) else { continue }
            let list: [String]
            do {
                list = try decoder.decode([String].self, from: data)
            } catch {
                continue
            }
            for keyword in list where KeywordNormalizer.fold(keyword).contains(needle) {
                guard seen.insert(KeywordNormalizer.fold(keyword)).inserted else { continue }
                keywords.append(keyword)
                if keywords.count >= 8 { break }
            }
        }
        if !keywords.isEmpty {
            suggestions.append(FilterSuggestion(field: "keyword", values: keywords))
        }
        return suggestions
    }

    // MARK: buildWhereClause

    private func buildWhereClause(_ group: FilterGroup) throws -> FilterWhereClause {
        var parts: [String] = []
        var params: [DBValue] = []
        for condition in group.conditions {
            switch condition {
            case .rule(let rule):
                let built = try buildConditionSql(rule)
                if !built.sql.isEmpty {
                    parts.append(built.sql)
                    params.append(contentsOf: built.params)
                }
            case .group(let subGroup):
                let sub = try buildWhereClause(subGroup)
                if !sub.sql.isEmpty {
                    parts.append("(\(sub.sql))")
                    params.append(contentsOf: sub.params)
                }
            }
        }
        if parts.isEmpty {
            // Wave4a（Review P2-10）：空 AND/OR 组 = 无约束（删除条件不应变成空集）；
            // 空 NOT 组按逻辑取反 = "没有任何条件满足" → 1=0（NOT(TRUE)=FALSE）。
            // 与 FilterLogic.not 文档一致：编辑器把 NOT 组删光时，筛选明确为空，
            // 而不是静默回到全量。
            if group.logic == .not {
                return FilterWhereClause(sql: "1=0", params: [])
            }
            return FilterWhereClause(sql: "", params: [])
        }
        switch group.logic {
        case .and:
            return FilterWhereClause(sql: parts.joined(separator: " AND "), params: params)
        case .or:
            return FilterWhereClause(sql: parts.joined(separator: " OR "), params: params)
        case .not:
            // Wave2（task-15）：子条件按 OR 组合后整体取反 = "一个都不满足"
            //（与 FilterLogic.not 的文档同一口径；单条件时 NOT (x) 等价）。
            return FilterWhereClause(
                sql: "NOT (\(parts.joined(separator: " OR ")))", params: params)
        }
    }

    private func buildConditionSql(_ rule: FilterRule) throws -> (sql: String, params: [DBValue]) {
        let field = rule.field
        let op = rule.`operator`
        let value = rule.value

        switch field {
        case "has_face":
            return try buildHasFaceCondition(operator: op, value: value)
        case "person":
            return try buildPersonCondition(operator: op, value: value)
        case "keywords":
            return try buildKeywordsCondition(operator: op, value: value)
        case FilterFields.keywordPath:
            // P1 下一波 §3.6.4：层级关键词走 photo_keywords 索引（不是 pmc.keywords JSON），
            // 这样 facet 与网格用的是同一份行（starts_with 才能做下钻）。
            return try buildKeywordPathCondition(operator: op, value: value)
        case "directory":
            if op != .eq && op != .startsWith {
                throw PhotoFilterQueryError.unsupportedOperatorForField(field: field, op: op.rawValue)
            }
            return (
                sql: "p.filepath LIKE ? || '%' ESCAPE '\\'",
                params: [.text(escapeLike(stringValue(value)))]
            )
        case "volume":
            return (
                sql: """
                    EXISTS (
                      SELECT 1 FROM asset_files af
                      WHERE af.id = p.asset_file_id AND af.volume_id = ?
                    )
                """,
                params: [.text(stringValue(value))]
            )
        // Wave2（task-15）：容器成员（手动集合 / 堆栈）与相对日期。
        case FilterFields.collection:
            return try buildMembershipCondition(
                rule: rule, table: "collection_items", column: "collection_id")
        case FilterFields.stack:
            return try buildMembershipCondition(
                rule: rule, table: "photo_stack_members", column: "stack_id")
        case FilterFields.relativeDate:
            return try buildRelativeDateCondition(rule: rule)
        case "has_duplicates":
            let pendingSql = """
                EXISTS (
                  SELECT 1 FROM duplicate_group_members dgm
                  WHERE dgm.photo_id = p.id
                    AND EXISTS (
                      SELECT 1 FROM duplicate_group_members other
                      WHERE other.group_id = dgm.group_id AND other.photo_id != dgm.photo_id
                    )
                    AND EXISTS (
                      SELECT 1 FROM duplicate_group_members pending
                      WHERE pending.group_id = dgm.group_id AND pending.resolution IS NULL
                    )
                )
            """
            if value.boolValue == false {
                return (sql: "NOT \(pendingSql)", params: [])
            }
            return (sql: pendingSql, params: [])
        default:
            break
        }

        // P1 / C：描述性元数据存在 photo_metadata_cache.iptc_json（单列 JSON），
        // 用 json_extract 投影成列，使搜索/筛选与普通列同构（操作符语义完全一致）。
        // var：#10 的空值规范化会按 op 重写这个表达式（只改 eq/in，见下方）。
        var fullCol: String
        if field == "date_taken" {
            // EXIF 原样存 "2024:05:01 10:00:00"，sidecar/相册可能是 ISO：先归一
            // 到 "2024-05-01 10:00:00" 再做文本比较/排序，否则混合数据 BETWEEN
            // 会整段丢 EXIF 行。
            fullCol = Self.normalizedDateTaken
        } else if let jsonKey = Self.jsonFields[field] {
            fullCol = "json_extract(pmc.iptc_json, '$.\(jsonKey)')"
        } else {
            let resolved = try resolveField(field)
            fullCol = "\(resolved.prefix).\(resolved.col)"
        }

        // #10：空值口径与挑片对齐（**只对 eq/in**）。rating 的缺行 = 0 星（与上方投影
        // COALESCE(pmc.rating,0) 同口径）；label 的 '' 与 NULL 都算 None。
        // 不套在 neq/gt/exists 上：那会把「未填写」的语义改掉（label exists 会恒真）。
        if op == .eq || op == .in {
            switch field {
            case "rating": fullCol = FilterFieldSQL.rating(fullCol)
            case "label": fullCol = FilterFieldSQL.label(fullCol)
            default: break
            }
        }

        // 数组字段：对 json_each 的每个元素判定（creator=["张三","李四"]）。
        if Self.jsonArrayFields.contains(field) {
            let each = "SELECT 1 FROM json_each(\(fullCol))"
            switch op {
            case .eq:
                return ("EXISTS (\(each) WHERE value = ?)", [value.toDBValue])
            case .neq:
                return ("NOT EXISTS (\(each) WHERE value = ?)", [value.toDBValue])
            case .contains:
                return ("EXISTS (\(each) WHERE value LIKE '%' || ? || '%' ESCAPE '\\')",
                        [.text(escapeLike(stringValue(value)))])
            case .containsAny:
                let arr = (value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)])
                if arr.isEmpty { return (sql: "1=0", params: []) }
                let ors = arr.map { _ in "EXISTS (\(each) WHERE value LIKE '%' || ? || '%' ESCAPE '\\')" }
                return ("(\(ors.joined(separator: " OR ")))", arr.map { DBValue.text(escapeLike($0)) })
            case .containsAll:
                let arr = (value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)])
                if arr.isEmpty { return (sql: "1=0", params: []) }
                let ands = arr.map { _ in "EXISTS (\(each) WHERE value LIKE '%' || ? || '%' ESCAPE '\\')" }
                return ("(\(ands.joined(separator: " AND ")))", arr.map { DBValue.text(escapeLike($0)) })
            case .in:
                let arr = value.arrayElements ?? []
                if arr.isEmpty { return (sql: "1=0", params: []) }
                let placeholders = arr.map { _ in "?" }.joined(separator: ", ")
                return ("EXISTS (\(each) WHERE value IN (\(placeholders)))", arr.map { $0.toDBValue })
            case .exists:
                return ("json_array_length(\(fullCol)) > 0", [])
            case .gt, .lt, .gte, .lte, .between, .startsWith:
                return ("1=0", [])
            }
        }

        switch op {
        case .eq: return ("\(fullCol) = ?", [value.toDBValue])
        case .neq:
            // NULL 是「未填写」：不等于 X 必须保留未填写的照片（与数组分支一致）。
            // #10 复审：rating/label 的 eq/in 已套空值规范化（COALESCE），若 neq 仍用
            // 「IS NULL OR != ?」，同一张未抽取/未标色照片会同时命中 = 与 != 两个互斥筛选。
            // 这里改为对**规范化表达式**取反：单行资产上 eq 与 neq 严格互补。
            // 注意残留限制：图库是「任一行命中即整组入选」，多行资产（RAW+JPEG 变体）
            // 仍可能同时命中 eq 与 neq（不同行各自成立）——这是分组模型的固有语义，
            // 不在本处修复；契约测试已记录该行为。
            switch field {
            case "rating":
                return ("NOT (\(FilterFieldSQL.rating(fullCol)) = ?)", [value.toDBValue])
            case "label":
                return ("NOT (\(FilterFieldSQL.label(fullCol)) = ?)", [value.toDBValue])
            default:
                return ("(\(fullCol) IS NULL OR \(fullCol) != ?)", [value.toDBValue])
            }
        case .gt: return ("\(fullCol) > ?", [value.toDBValue])
        case .lt: return ("\(fullCol) < ?", [value.toDBValue])
        case .gte: return ("\(fullCol) >= ?", [value.toDBValue])
        case .lte: return ("\(fullCol) <= ?", [value.toDBValue])
        case .between:
            let arr = value.arrayElements ?? []
            guard arr.count >= 2 else {
                return ("\(fullCol) BETWEEN ? AND ?", [value.toDBValue, value.toDBValue])
            }
            return ("\(fullCol) BETWEEN ? AND ?", [arr[0].toDBValue, arr[1].toDBValue])
        case .in:
            let arr = value.arrayElements ?? []
            if arr.isEmpty {
                return (sql: "1=0", params: [])
            }
            let placeholders = arr.map { _ in "?" }.joined(separator: ", ")
            return ("\(fullCol) IN (\(placeholders))", arr.map { $0.toDBValue })
        case .contains:
            return ("\(fullCol) LIKE '%' || ? || '%' ESCAPE '\\'",
                    [.text(escapeLike(stringValue(value)))])
        case .startsWith:
            return ("\(fullCol) LIKE ? || '%' ESCAPE '\\'",
                    [.text(escapeLike(stringValue(value)))])
        case .containsAny:
            let arr = (value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)])
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let orParts = arr.map { _ in "\(fullCol) LIKE '%' || ? || '%' ESCAPE '\\'" }
            return ("(\(orParts.joined(separator: " OR ")))", arr.map { DBValue.text(escapeLike($0)) })
        case .containsAll:
            let arr = (value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)])
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let andParts = arr.map { _ in "\(fullCol) LIKE '%' || ? || '%' ESCAPE '\\'" }
            return ("(\(andParts.joined(separator: " AND ")))", arr.map { DBValue.text(escapeLike($0)) })
        case .exists:
            return ("\(fullCol) IS NOT NULL", [])
        }
    }

    // MARK: - Wave2（task-15）：容器成员 / 相对日期

    /// 容器成员判定（手动集合 collection_items / 堆栈 photo_stack_members）。
    ///
    /// 表名/列名是**内部固定字面量**（由本文件的分支传入），用户输入（集合 id）
    /// 一律走绑定参数；子查询用 `m.photo_id = p.id` 与主查询相连。
    /// 操作符语义与 FilterFields.collection 的文档一致：
    /// eq=属于 / neq=不属于（差集）/ in|contains_any=属于任一（并集）/
    /// contains_all=同时属于全部（交集）/ exists=属于任意容器。
    private func buildMembershipCondition(
        rule: FilterRule, table: String, column: String
    ) throws -> (sql: String, params: [DBValue]) {
        let op = rule.`operator`
        let exists = "EXISTS (SELECT 1 FROM \(table) m WHERE m.photo_id = p.id"
        let ids: [String] = {
            if let array = rule.value.arrayElements {
                return array.compactMap { $0.stringValue }
            }
            let single = stringValue(rule.value)
            return single.isEmpty ? [] : [single]
        }()
        switch op {
        case .eq:
            guard let first = ids.first else { return ("1=0", []) }
            return ("\(exists) AND m.\(column) = ?)", [.text(first)])
        case .neq:
            guard let first = ids.first else { return ("1=1", []) }
            return ("NOT (\(exists) AND m.\(column) = ?))", [.text(first)])
        case .in, .containsAny:
            let unique = Array(Set(ids)).sorted()
            guard !unique.isEmpty else { return ("1=0", []) }
            let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
            return (
                "\(exists) AND m.\(column) IN (\(placeholders)))",
                unique.map(DBValue.text))
        case .containsAll:
            let unique = Array(Set(ids)).sorted()
            guard !unique.isEmpty else { return ("1=0", []) }
            let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
            return (
                """
                (SELECT COUNT(DISTINCT m.\(column)) FROM \(table) m
                 WHERE m.photo_id = p.id AND m.\(column) IN (\(placeholders))) = ?
                """,
                unique.map(DBValue.text) + [.int(Int64(unique.count))])
        case .exists:
            return ("\(exists))", [])
        case .gt, .lt, .gte, .lte, .between, .contains, .startsWith:
            throw PhotoFilterQueryError.unsupportedOperatorForField(
                field: rule.field, op: op.rawValue)
        }
    }

    /// 相对日期窗口（最近 7/30 天、本月）。**按查询时刻求值**，因此保存成智能相册/
    /// 保存查询后不会隔天过期。
    ///
    /// 日期表达式复用 normalizedDateTaken（EXIF 冒号日期已归一），只取前 10 位比日；
    /// 时区口径与用户直觉一致：`localtime`（本机时区）而不是 UTC。
    /// 未知 token 显式报错（INVALID_PARAM 路径），不静默返回空集。
    private func buildRelativeDateCondition(
        rule: FilterRule
    ) throws -> (sql: String, params: [DBValue]) {
        guard rule.`operator` == .eq || rule.`operator` == .in else {
            throw PhotoFilterQueryError.unsupportedOperatorForField(
                field: rule.field, op: rule.`operator`.rawValue)
        }
        let tokens: [String]
        if let array = rule.value.arrayElements {
            tokens = array.compactMap { $0.stringValue }
        } else {
            let single = stringValue(rule.value)
            tokens = single.isEmpty ? [] : [single]
        }
        guard !tokens.isEmpty else { return ("1=0", []) }
        let dateExpr = "substr(\(Self.normalizedDateTaken), 1, 10)"
        let clauses: [String] = try tokens.map { token in
            guard let range = RelativeDateRange(rawValue: token) else {
                throw PhotoFilterQueryError.unsupportedOperatorForField(
                    field: "\(rule.field):\(token)", op: rule.`operator`.rawValue)
            }
            switch range {
            case .last7:
                return "\(dateExpr) >= date('now', 'localtime', '-6 days')"
            case .last30:
                return "\(dateExpr) >= date('now', 'localtime', '-29 days')"
            case .thisMonth:
                return "strftime('%Y-%m', \(dateExpr)) = strftime('%Y-%m', 'now', 'localtime')"
            }
        }
        return ("(\(clauses.joined(separator: " OR ")))", [])
    }

    // MARK: - Wave5（batch2）：关键词同义词展开

    /// 查询词 → 同义词表命中的规范路径（**整词映射**）。
    ///
    /// 口径与边界：
    /// - 只有「查询词与 keyword_synonyms.synonym 经 KeywordNormalizer.fold 后完全
    ///   相等」才展开成该同义词所属的规范路径；contains 的子串语义**不**反向映射
    ///   （否则输入「宫」会把「故宫」的同义词整批拉进来，筛选范围失控）；
    /// - 词库规模小：一次全表读 + Swift 侧 fold 比较（SQLite 的 LIKE 不认 NFC/大小写
    ///   折叠，放 SQL 里会漏命中）；读失败退化为"无同义词"，检索不因此整条报错；
    /// - 返回字典序稳定，SQL 参数顺序可预期（测试可断言）。
    private func keywordSynonymPaths(for term: String) -> [String] {
        let needle = KeywordNormalizer.fold(term)
        guard !needle.isEmpty else { return [] }
        let rows: [(path: String, synonym: String)]
        do {
            rows = try connection.prepare(
                "SELECT keyword_path, synonym FROM keyword_synonyms ORDER BY keyword_path")
                .query()
                .compactMap { row in
                    guard let path = row[0].textValue, let synonym = row[1].textValue else {
                        return nil
                    }
                    return (path, synonym)
                }
        } catch {
            return []
        }
        var seen = Set<String>()
        var paths: [String] = []
        for row in rows where KeywordNormalizer.fold(row.synonym) == needle {
            if seen.insert(row.path).inserted { paths.append(row.path) }
        }
        return paths.sorted()
    }

    /// 一个查询词的检索别名：原词 + 同义词命中的规范路径。
    ///
    /// - includeLeaves=true：pmc.keywords（dc:subject）里可能是叶子也可能是完整路径
    ///   （取决于 keyword_dc_style），两种形态都要能命中；
    /// - keyword_path 一定存规范路径，不需要叶子。
    private func keywordTermAlternatives(_ term: String, includeLeaves: Bool) -> [String] {
        var values = [term]
        var seen = Set([term])
        for synonymPath in keywordSynonymPaths(for: term) {
            if seen.insert(synonymPath).inserted { values.append(synonymPath) }
            guard includeLeaves, let leaf = KeywordPath(synonymPath)?.leaf, !leaf.isEmpty else {
                continue
            }
            if seen.insert(leaf).inserted { values.append(leaf) }
        }
        return values
    }

    /// 交替拼 SQL 的 IN 子句 + 参数（保持调用点短）。
    private static func inPlaceholders(_ count: Int) -> String {
        (0..<count).map { _ in "?" }.joined(separator: ", ")
    }

    private func buildKeywordsCondition(`operator`: FilterOperator, value: JSONValue) throws -> (sql: String, params: [DBValue]) {
        let op = `operator`
        let arr = value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)]
        switch op {
        case .contains:
            let term = stringValue(value)
            let alternatives = keywordTermAlternatives(term, includeLeaves: true)
            guard alternatives.count > 1 else {
                return (
                    sql: "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value LIKE '%' || ? || '%' ESCAPE '\\')",
                    params: [.text(escapeLike(term))]
                )
            }
            // 同义词是等价词：对每个等价词各做一次子串匹配（叶子/完整路径都能命中）。
            let likes = alternatives
                .map { _ in "value LIKE '%' || ? || '%' ESCAPE '\\'" }
                .joined(separator: " OR ")
            return (
                sql: "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE \(likes))",
                params: alternatives.map { .text(escapeLike($0)) }
            )
        case .containsAny:
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let expanded = arr.map { keywordTermAlternatives($0, includeLeaves: true) }
            guard expanded.contains(where: { $0.count > 1 }) else {
                let placeholders = Self.inPlaceholders(arr.count)
                return (
                    sql: "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value IN (\(placeholders)))",
                    params: arr.map(DBValue.text)
                )
            }
            var clauses: [String] = []
            var params: [DBValue] = []
            for alternatives in expanded {
                clauses.append(
                    "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value IN (\(Self.inPlaceholders(alternatives.count))))")
                params.append(contentsOf: alternatives.map(DBValue.text))
            }
            return (sql: "(\(clauses.joined(separator: " OR ")))", params: params)
        case .containsAll:
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let unique = Array(Set(arr)).sorted()
            let expanded = unique.map { keywordTermAlternatives($0, includeLeaves: true) }
            guard expanded.contains(where: { $0.count > 1 }) else {
                let placeholders = Self.inPlaceholders(unique.count)
                return (
                    sql: "(SELECT COUNT(DISTINCT value) FROM json_each(pmc.keywords) WHERE value IN (\(placeholders))) = ?",
                    params: unique.map(DBValue.text) + [.int(Int64(unique.count))]
                )
            }
            // 有同义词时改「每个词各有一个等价命中」的 AND：等价词会让 distinct 计数
            // 重复（两个词映射到同一路径时 count 不等），AND-of-EXISTS 语义更准。
            var clauses: [String] = []
            var params: [DBValue] = []
            for alternatives in expanded {
                clauses.append(
                    "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value IN (\(Self.inPlaceholders(alternatives.count))))")
                params.append(contentsOf: alternatives.map(DBValue.text))
            }
            return (sql: "(\(clauses.joined(separator: " AND ")))", params: params)
        case .exists:
            return (sql: "pmc.keywords IS NOT NULL AND pmc.keywords != '[]'", params: [])
        case .eq:
            let terms = arr
            let expanded = terms.map { keywordTermAlternatives($0, includeLeaves: true) }
            guard expanded.contains(where: { $0.count > 1 }) else {
                let sorted = terms.sorted()
                let sortedJSON = try JSONSerialization.data(withJSONObject: sorted)
                let jsonString = String(data: sortedJSON, encoding: .utf8) ?? "[]"
                return (
                    sql: """
                        (
                          SELECT json_group_array(value ORDER BY value) FROM json_each(pmc.keywords)
                        ) = (
                          SELECT json_group_array(value ORDER BY value) FROM json_each(?)
                        )
                    """,
                    params: [.text(jsonString)]
                )
            }
            // eq = 整组关键词相等；同义词是"等价替换"，整表比较无法表达，
            // 命中同义词时退化为「每个查询词都有一个等价命中」（与 containsAll 同口径；
            // 取舍已写入 40 册同义词章节与测试）。
            var clauses: [String] = []
            var params: [DBValue] = []
            for alternatives in expanded {
                clauses.append(
                    "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value IN (\(Self.inPlaceholders(alternatives.count))))")
                params.append(contentsOf: alternatives.map(DBValue.text))
            }
            return (sql: "(\(clauses.joined(separator: " AND ")))", params: params)
        default:
            return (sql: "1=1", params: [])
        }
    }

    /// P1 下一波 §3.6.4：层级关键词（photo_keywords.keyword_path）。
    ///
    /// 语义要点：
    /// - eq：命中该路径本身（叶子多选）；
    /// - startsWith：命中该节点**及其子孙**（点 A 看到 A 与 A|B）。这样 facet 下钻
    ///   与"点 A"生成的单条规则是同一件事，不需要在 UI 侧把父级规则叠加起来；
    /// - contains：序列化路径的子串匹配（与旧的 keywords contains 同手感）；
    /// - 路径一律先过 KeywordPath 归一（trim/NFC/丢空段），否则用户输入
    ///   "A | B" 会与库里的 "A|B" 永远不相等。
    private func buildKeywordPathCondition(
        `operator`: FilterOperator, value: JSONValue
    ) throws -> (sql: String, params: [DBValue]) {
        let raw = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = KeywordPath.parse(raw)?.serialized ?? raw
        func exists(_ condition: String, _ params: [DBValue]) -> (sql: String, params: [DBValue]) {
            (
                "EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = p.id AND (\(condition)))",
                params
            )
        }
        /// 路径的等价集合：规范路径 + 同义词命中的规范路径（整词映射）。
        func alternatives(_ term: String) -> [String] {
            var values = [term]
            var seen = Set([term])
            for synonymPath in keywordSynonymPaths(for: term) {
                if seen.insert(synonymPath).inserted { values.append(synonymPath) }
            }
            return values
        }
        func inCondition(_ values: [String]) -> (condition: String, params: [DBValue]) {
            ("pk.keyword_path IN (\(Self.inPlaceholders(values.count)))", values.map(DBValue.text))
        }
        let values = value.arrayElements?.compactMap { $0.stringValue } ?? [raw]
        let normalizedValues = values.map { KeywordPath.parse($0)?.serialized ?? $0 }
        switch `operator` {
        case .eq:
            let expanded = alternatives(path)
            guard expanded.count > 1 else {
                return exists("pk.keyword_path = ?", [.text(path)])
            }
            let (condition, params) = inCondition(expanded)
            return exists(condition, params)
        case .neq:
            let expanded = alternatives(path)
            guard expanded.count > 1 else {
                return (
                    "NOT EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = p.id AND pk.keyword_path = ?)",
                    [.text(path)])
            }
            let (condition, params) = inCondition(expanded)
            return (
                "NOT EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = p.id AND \(condition))",
                params)
        case .startsWith:
            // 命中节点及其子孙；同义词等价节点同样展开子树（点 A 也看到 A|B）。
            let expanded = alternatives(path).filter { KeywordPath($0) != nil }
            let candidates = expanded.isEmpty ? [path] : expanded
            if candidates.count == 1 {
                return exists(
                    "pk.keyword_path = ? OR (pk.keyword_path >= ? AND pk.keyword_path < ?)",
                    [
                        .text(path),
                        .text(KeywordPathSQL.subtreeLowerBound(path)),
                        .text(KeywordPathSQL.subtreeUpperBound(path)),
                    ])
            }
            var clauses: [String] = []
            var params: [DBValue] = []
            for candidate in candidates {
                clauses.append(
                    "(pk.keyword_path = ? OR (pk.keyword_path >= ? AND pk.keyword_path < ?))")
                params.append(contentsOf: [
                    .text(candidate),
                    .text(KeywordPathSQL.subtreeLowerBound(candidate)),
                    .text(KeywordPathSQL.subtreeUpperBound(candidate)),
                ])
            }
            return exists(clauses.joined(separator: " OR "), params)
        case .contains:
            let expanded = alternatives(path)
            guard expanded.count > 1 else {
                return exists(
                    "pk.keyword_path LIKE '%' || ? || '%' ESCAPE '\\'",
                    [.text(escapeLike(path))])
            }
            // contains 是子串：同义词只做整词映射（等价词各自做子串匹配），
            // 不做"输入子串 → 反查同义词"（边界见 keywordSynonymPaths 注释）。
            let likes = expanded
                .map { _ in "pk.keyword_path LIKE '%' || ? || '%' ESCAPE '\\'" }
                .joined(separator: " OR ")
            return exists(likes, expanded.map { .text(escapeLike($0)) })
        case .in, .containsAny:
            if normalizedValues.isEmpty { return (sql: "1=0", params: []) }
            var expanded: [String] = []
            var seen = Set<String>()
            for term in normalizedValues {
                for candidate in alternatives(term) where seen.insert(candidate).inserted {
                    expanded.append(candidate)
                }
            }
            let (condition, params) = inCondition(expanded.sorted())
            return exists(condition, params)
        case .containsAll:
            if normalizedValues.isEmpty { return (sql: "1=0", params: []) }
            let unique = Array(Set(normalizedValues)).sorted()
            guard unique.contains(where: { alternatives($0).count > 1 }) else {
                let placeholders = Self.inPlaceholders(unique.count)
                return (
                    """
                    (SELECT COUNT(DISTINCT pk.keyword_path) FROM photo_keywords pk
                     WHERE pk.photo_id = p.id AND pk.keyword_path IN (\(placeholders))) = ?
                    """,
                    unique.map(DBValue.text) + [.int(Int64(unique.count))])
            }
            var clauses: [String] = []
            var params: [DBValue] = []
            for term in unique {
                let (condition, itemParams) = inCondition(alternatives(term).sorted())
                clauses.append(
                    "EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = p.id AND \(condition))")
                params.append(contentsOf: itemParams)
            }
            return ("(\(clauses.joined(separator: " AND ")))", params)
        case .exists:
            return exists("1=1", [])
        case .gt, .lt, .gte, .lte, .between:
            // 路径没有大小语义：显式返回空集，而不是把字符串比较当"范围"用。
            return (sql: "1=0", params: [])
        }
    }

    private func buildHasFaceCondition(`operator`: FilterOperator, value: JSONValue) throws -> (sql: String, params: [DBValue]) {
        let op = `operator`
        let existsSql = "EXISTS (SELECT 1 FROM face_observations fo WHERE fo.photo_id = p.id AND fo.session_id = p.session_id)"
        switch op {
        case .eq:
            return value.boolValue == true
                ? (existsSql, [])
                : ("NOT \(existsSql)", [])
        case .neq:
            return value.boolValue == true
                ? ("NOT \(existsSql)", [])
                : (existsSql, [])
        case .exists:
            return (existsSql, [])
        default:
            return (existsSql, [])
        }
    }

    private func buildPersonCondition(`operator`: FilterOperator, value: JSONValue) throws -> (sql: String, params: [DBValue]) {
        let op = `operator`
        switch op {
        case .eq:
            return (
                sql: "EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)",
                params: [.text(stringValue(value))]
            )
        case .contains:
            return (
                sql: "EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name LIKE '%' || ? || '%' ESCAPE '\\')",
                params: [.text(escapeLike(stringValue(value)))]
            )
        case .neq:
            return (
                sql: "NOT EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)",
                params: [.text(stringValue(value))]
            )
        case .containsAny:
            let names = value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)]
            if names.isEmpty { return (sql: "1=0", params: []) }
            let parts = names.map { _ in "per.name LIKE '%' || ? || '%' ESCAPE '\\'" }
            return (
                sql: "EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND (\(parts.joined(separator: " OR "))))",
                params: names.map { DBValue.text(escapeLike($0)) }
            )
        case .in:
            let ids = value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)]
            if ids.isEmpty { return (sql: "1=0", params: []) }
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            return (
                sql: "EXISTS (SELECT 1 FROM person_photos pp WHERE pp.photo_id = p.id AND pp.person_id IN (\(placeholders)))",
                params: ids.map(DBValue.text)
            )
        default:
            return (
                sql: "EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)",
                params: [.text(stringValue(value))]
            )
        }
    }

    // MARK: 辅助

    private func membershipSql(_ sessionId: String?) -> String {
        // 选中工作区时必须限制代表行本身属于该会话；只要求"资产在该会话有成员"
        // 会让跨会话资产把别的会话行选成代表，UI 打开后跳到错误会话。
        guard sessionId != nil else { return "" }
        return "AND p.session_id = ?"
    }

    private func resolveField(_ field: String) throws -> (prefix: String, col: String) {
        if Self.simpleFields.contains(field) {
            return ("p", field)
        }
        if Self.metadataFields.contains(field) {
            return ("pmc", field)
        }
        throw PhotoFilterQueryError.fieldUnknown(field)
    }

    private func resolveSortColumn(_ sortBy: String) -> String {
        if sortBy == "date_taken" { return Self.normalizedDateTaken }
        if Self.simpleFields.contains(sortBy) { return "p.\(sortBy)" }
        if Self.metadataFields.contains(sortBy) { return "pmc.\(sortBy)" }
        return "p.filename"
    }

    /// 归一化后的拍摄时间（EXIF 冒号日期 → ISO 文本，其余原样）。
    static let normalizedDateTaken = """
        CASE WHEN pmc.date_taken LIKE '____:__:__%'
             THEN replace(substr(pmc.date_taken, 1, 10), ':', '-') || substr(pmc.date_taken, 11)
             ELSE pmc.date_taken END
        """

    private func rowToPhotoRow(_ row: NamedRow) throws -> FilteredPhotoRow {
        FilteredPhotoRow(
            id: try row.decoded(by: "id"),
            sessionId: try row.decoded(by: "session_id"),
            filepath: try row.decoded(by: "filepath"),
            filename: try row.decoded(by: "filename"),
            checksum: try row.decoded(by: "checksum"),
            faceCount: try row.decoded(by: "face_count"),
            status: try row.decoded(by: "status"),
            createdAt: try row.decoded(by: "created_at"),
            updatedAt: try row.decoded(by: "updated_at")
        )
    }
}

/// TS: escapeLike。
public func escapeLike(_ value: String) -> String {
    value.replacingOccurrences(of: #"([\\%_])"#, with: #"\\$1"#, options: .regularExpression)
}

/// TS: stringValue（value 的 String 化：String 直取，其他 JSONValue → "\(value)"）。
func stringValue(_ value: JSONValue) -> String {
    if let string = value.stringValue { return string }
    return "\(value)"
}

func parseKeywords(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else { return [] }
    return parsed.compactMap { $0 as? String }
}

/// SQL 生成错误（Application 的 FilterEngine 门面映射为 FilterEngineError，
/// 保持既有公开错误类型不变）。
public enum PhotoFilterQueryError: Error, Equatable, CustomStringConvertible {
    case fieldUnknown(String)
    case unsupportedOperatorForField(field: String, op: String)

    public var description: String {
        switch self {
        case .fieldUnknown: return "FILTER_FIELD_UNKNOWN"
        case .unsupportedOperatorForField(let field, let op):
            return "Unsupported operator for \(field) field: \(op)"
        }
    }
}

// MARK: - JSONValue → DBValue

extension JSONValue {
    var toDBValue: DBValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .int(value ? 1 : 0)
        case .number(let value): return .real(value)
        case .string(let value): return .text(value)
        case .array: return .null
        case .object: return .null
        }
    }
}

public protocol PhotoFilterQuerying {
    func whereClause(_ group: FilterGroup) throws -> FilterWhereClause
    /// P1 下一波：带 criteria 的资产游标分页（photo.list_page 的 criteria 分支）。
    func assetPage(
        sessionId: String,
        criteria: FilterGroup?,
        afterFirstRowid: Int64?,
        limit: Int,
        descending: Bool
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?)
    func filterPhotos(
        sessionId: String,
        criteria: FilterGroup,
        sortBy: String?,
        sortOrder: String?,
        limit: Int?,
        offset: Int?
    ) throws -> [FilteredPhotoRow]
    func filterGlobally(
        criteria: FilterGroup,
        sortBy: String?,
        sortOrder: String?,
        limit: Int?,
        offset: Int?,
        sessionId: String?
    ) throws -> [GlobalPhotoResult]
    /// 只取代表行 photo id（一次 CTE，最多 20k），供图库全选。
    func filterGloballyIDs(
        criteria: FilterGroup,
        sessionId: String,
        limit: Int
    ) throws -> [String]
    func countGlobally(criteria: FilterGroup, sessionId: String?) throws -> Int
    func countPhotos(sessionId: String, criteria: FilterGroup) throws -> Int
    func suggest(_ sessionId: String, keyword: String) throws -> [FilterSuggestion]
}

extension PhotoFilterQuery: PhotoFilterQuerying {}
