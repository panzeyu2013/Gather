// desktop/native/gather-core/Sources/GatherDomain/Services/FilterEngine.swift
// TS 源: desktop/src/main/services/filter/filter-engine.ts（Phase 3.6 移植）
//
// 纯 SQL 生成 + 参数绑定（无 Node 依赖，可独立对账）。
// 行为红线（与 TS 逐条对应）：
//   - 字段三分类：SIMPLE（前缀 p）/ METADATA（前缀 pmc）/ 特殊字段
//     （has_face/person/keywords/directory/volume/has_duplicates）；未知字段
//     抛 FILTER_FIELD_UNKNOWN（error.params.field）
//   - 13 操作符逐条 SQL 形态；in 空数组 → 1=0；between 取二元组
//   - keywords：contains_any（json_each IN）/ contains_all（COUNT(DISTINCT)=n）/
//     eq（json_group_array 排序后相等）/ exists（!= '[]'）
//   - directory：仅 eq/starts_with，其余抛 "Unsupported operator..."；
//     escapeLike 转义 \ % _
//   - has_face/person/volume/has_duplicates：EXISTS/NOT EXISTS 专属 SQL
//   - has_duplicates 绑定决策状态（§4.2 修复）：仅「仍有未决成员的重复组」命中；
//     已处理（全部成员已决策）的组不命中。全部消费方（filterPhotos/filterGlobally/
//     countPhotos/countGlobally/智能相册）共用本 SQL 生成器，语义单点。
//   - filterPhotos 引擎内不钳制 limit/offset；filterGlobally 钳制
//     1..500 / ≥0（不对称，与 TS 一致）；countPhotos 全局模式 asset 去重
//   - rowToPhotoData 硬编码 hasExistingXmp: false
// 与 TS 的差异：参数统一 DBValue；FaceCount 子查询保留。
import Foundation
import GatherPersistence
import GatherProtocol

/// TS: WhereClauseResult。
public struct WhereClauseResult: Equatable, Sendable {
    public let sql: String
    public let params: [DBValue]

    public init(sql: String, params: [DBValue]) {
        self.sql = sql
        self.params = params
    }
}

/// TS: PhotoData（filterPhotos 返回）。
public struct FilteredPhotoData: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let hasExistingXmp: Bool
    public let faceCount: Int
    public let width: Int
    public let height: Int
    /// 仅为 IPC 形状兼容恒为 "{}"；V1 photos 不再存 metadata/result。
    public let metadata: String
    /// 同上：不参与 SQL 投影与行映射。
    public let result: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String
}

public final class FilterEngine {
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

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: API

    /// TS: filterPhotos —— 引擎内不钳制 limit/offset。
    public func filterPhotos(
        sessionId: String,
        criteria: FilterGroup,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> [FilteredPhotoData] {
        let clause = try buildWhereClause(criteria)
        let sessionFilter = sessionId == "__global__" ? "1=1" : "p.session_id = ?"
        // V1 photos 无 metadata/result（Cut 2 S5b / R1-01）：投影只取 V1 交集列，
        // 且每列显式 AS —— 下游 rowToPhotoData 按列名解码，不再依赖位置 6/7。
        let sql = [
            "SELECT DISTINCT p.id AS id, p.session_id AS session_id, p.filepath AS filepath,",
            "p.filename AS filename, p.checksum AS checksum, p.status AS status,",
            "p.created_at AS created_at, p.updated_at AS updated_at,",
            "(SELECT COUNT(*) FROM face_observations fo WHERE fo.photo_id = p.id AND fo.session_id = p.session_id) AS face_count",
            "FROM photos p",
            "LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id",
            "WHERE \(sessionFilter) AND (\(clause.sql.isEmpty ? "1=1" : clause.sql))",
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
            resolvedSql += " OFFSET ?"
            allParams.append(.int(Int64(offset)))
        }

        let rows = try connection.prepare(resolvedSql).queryNamed(allParams)
        return try rows.map(rowToPhotoData)
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
            "), ranked AS (",
            // 代表行规则（唯一真相源 PhotoRepo.preferredRowOrderSQL）：RAW 变体优先、
            // 其次最小 rowid。排序只作用于 matching 集 —— 变体一旦不满足筛选条件就
            // 不能当代表（否则会返回一条不匹配的照片，页内容与计数互相矛盾）。
            "SELECT matching.asset_key, matching.photo_rowid,",
            "ROW_NUMBER() OVER (PARTITION BY matching.asset_key",
            "  ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p"))) AS preference_rank",
            "FROM matching JOIN photos p ON p.rowid = matching.photo_rowid",
            "), representatives AS (",
            "SELECT asset_key, photo_rowid FROM ranked WHERE preference_rank = 1",
            ")",
            "SELECT p.id AS photo_id, COALESCE(NULLIF(p.asset_id, ''), p.id) AS asset_id,",
            "p.session_id, s.name AS session_name, p.filename, p.filepath, p.status,",
            "COALESCE(pmc.rating, 0) AS rating, COALESCE(pmc.label, '') AS label,",
            "COALESCE(pmc.keywords, '[]') AS keywords,",
            "(SELECT GROUP_CONCAT(DISTINCT member.session_id) FROM photos member",
            " WHERE COALESCE(NULLIF(member.asset_id, ''), member.id) = representatives.asset_key) AS session_ids,",
            "(SELECT GROUP_CONCAT(DISTINCT member_session.name) FROM photos member",
            " JOIN sessions member_session ON member_session.id = member.session_id",
            " WHERE COALESCE(NULLIF(member.asset_id, ''), member.id) = representatives.asset_key) AS session_names",
            "FROM representatives JOIN photos p ON p.rowid = representatives.photo_rowid",
            "LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id",
            "JOIN sessions s ON p.session_id = s.id",
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
                rating: row[7].doubleValue ?? 0,
                label: row[8].textValue ?? "",
                keywords: parseKeywords(row[9].textValue ?? "[]")
            )
        }
    }

    /// TS: countGlobally。
    public func countGlobally(criteria: FilterGroup, sessionId: String? = nil) throws -> Int {
        let clause = try buildWhereClause(criteria)
        let membershipFilter = membershipSql(sessionId)
        var params = clause.params
        if sessionId != nil { params.append(.text(sessionId!)) }
        guard let row = try connection.prepare("""
            SELECT COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id)) AS count
            FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
            WHERE (\(clause.sql.isEmpty ? "1=1" : clause.sql)) \(membershipFilter)
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
        """).get(allParams) else { return 0 }
        return Int(row[0].intValue ?? 0)
    }

    /// TS: suggest —— 仅 camera_make LIKE，<2 字符返回空。
    public func suggest(_ sessionId: String, keyword: String) throws -> [FilterSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let pattern = "%\(trimmed)%"
        let rows = try connection.prepare(
            "SELECT DISTINCT camera_make FROM photo_metadata_cache WHERE camera_make LIKE ? LIMIT 5"
        ).query([.text(pattern)])
        return [FilterSuggestion(
            field: "camera_make",
            values: rows.compactMap { $0[0].textValue }
        )]
    }

    // MARK: buildWhereClause（public —— album IPC 用它做 criteria 校验）

    /// TS: buildWhereClause —— 递归组合；空组 → sql:''（调用方视为 1=1）。
    public func buildWhereClause(_ group: FilterGroup) throws -> WhereClauseResult {
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
            return WhereClauseResult(sql: "", params: [])
        }
        let joiner = group.logic == .or ? " OR " : " AND "
        return WhereClauseResult(sql: parts.joined(separator: joiner), params: params)
    }

    // MARK: buildConditionSql

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
        case "directory":
            if op != .eq && op != .startsWith {
                // TS: 静默全匹配 → 显式抛错（误导性 "all photos match"）。
                throw FilterEngineError.unsupportedOperatorForField(field: field, op: op.rawValue)
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
        case "has_duplicates":
            // 语义（§4.2 P1 修复，与 DuplicateService 单事务后状态一致）：
            // 照片仍存在**未决**的重复关系才命中。一个组「已处理」⇔ 组内不存在
            // resolution IS NULL 的成员——成员行的 resolution 是决策真相，
            // duplicate_groups.resolution 只是重扫/整组决策时落下的派生值，不再
            // 作为第二判据（消除双真相源）。
            // 部分处理：同组只要还有未决成员，组内所有成员继续命中。重复关系的
            // 处理是组级动作（保留谁/丢弃谁），存在未决成员时「这组重复处理了吗」
            // 仍未回答；某成员是否被丢弃（is_kept／导出排除）是另一维度，不影响
            // 本判据。
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

        let resolved = try resolveField(field)
        let fullCol = "\(resolved.prefix).\(resolved.col)"

        switch op {
        case .eq: return ("\(fullCol) = ?", [value.toDBValue])
        case .neq: return ("\(fullCol) != ?", [value.toDBValue])
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
            return ("\(fullCol) LIKE '%' || ? || '%'", [.text(stringValue(value))])
        case .startsWith:
            return ("\(fullCol) LIKE ? || '%'", [.text(stringValue(value))])
        case .containsAny:
            let arr = (value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)])
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let orParts = arr.map { _ in "\(fullCol) LIKE '%' || ? || '%'" }
            return ("(\(orParts.joined(separator: " OR ")))", arr.map(DBValue.text))
        case .containsAll:
            let arr = (value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)])
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let andParts = arr.map { _ in "\(fullCol) LIKE '%' || ? || '%'" }
            return ("(\(andParts.joined(separator: " AND ")))", arr.map(DBValue.text))
        case .exists:
            return ("\(fullCol) IS NOT NULL", [])
        }
    }

    private func buildKeywordsCondition(`operator`: FilterOperator, value: JSONValue) throws -> (sql: String, params: [DBValue]) {
        let op = `operator`
        let arr = value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)]
        switch op {
        case .containsAny:
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let placeholders = arr.map { _ in "?" }.joined(separator: ", ")
            return (
                sql: "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value IN (\(placeholders)))",
                params: arr.map(DBValue.text)
            )
        case .containsAll:
            if arr.isEmpty { return (sql: "1=0", params: []) }
            let unique = Array(Set(arr))
            let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
            // TS: [...unique, unique.length] —— 长度参数必须是整数（COUNT 是
            // INTEGER，绑 TEXT '2' 会因 SQLite 类型序 INTEGER < TEXT 恒不等）。
            return (
                sql: "(SELECT COUNT(DISTINCT value) FROM json_each(pmc.keywords) WHERE value IN (\(placeholders))) = ?",
                params: unique.map(DBValue.text) + [.int(Int64(unique.count))]
            )
        case .exists:
            return (sql: "pmc.keywords IS NOT NULL AND pmc.keywords != '[]'", params: [])
        case .eq:
            let sorted = arr.sorted()
            let sortedJSON = try! JSONSerialization.data(withJSONObject: sorted)
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
        default:
            return (sql: "1=1", params: [])
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
                sql: "EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name LIKE '%' || ? || '%')",
                params: [.text(stringValue(value))]
            )
        case .neq:
            return (
                sql: "NOT EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)",
                params: [.text(stringValue(value))]
            )
        case .containsAny:
            let names = value.arrayElements?.compactMap { $0.stringValue } ?? [stringValue(value)]
            if names.isEmpty { return (sql: "1=0", params: []) }
            let parts = names.map { _ in "per.name LIKE '%' || ? || '%'" }
            return (
                sql: "EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND (\(parts.joined(separator: " OR "))))",
                params: names.map(DBValue.text)
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
        guard sessionId != nil else { return "" }
        return """
            AND EXISTS (
              SELECT 1 FROM photos member
              WHERE COALESCE(NULLIF(member.asset_id, ''), member.id) =
                COALESCE(NULLIF(p.asset_id, ''), p.id)
                AND member.session_id = ?
            )
        """
    }

    private func resolveField(_ field: String) throws -> (prefix: String, col: String) {
        if Self.simpleFields.contains(field) {
            return ("p", field)
        }
        if Self.metadataFields.contains(field) {
            return ("pmc", field)
        }
        throw FilterEngineError.fieldUnknown(field)
    }

    private func resolveSortColumn(_ sortBy: String) -> String {
        if Self.simpleFields.contains(sortBy) { return "p.\(sortBy)" }
        if Self.metadataFields.contains(sortBy) { return "pmc.\(sortBy)" }
        return "p.filename"
    }

    /// 按列名解码（NamedRow）：查询列序变化不会再静默错列。metadata/result 不读库
    /// （V1 无此二列；旧库该二列恒为 INSERT 常量 '{}'），字段仅保留 IPC 形状兼容。
    private func rowToPhotoData(_ row: NamedRow) throws -> FilteredPhotoData {
        FilteredPhotoData(
            id: try row.decoded(by: "id"),
            sessionId: try row.decoded(by: "session_id"),
            filepath: try row.decoded(by: "filepath"),
            filename: try row.decoded(by: "filename"),
            checksum: try row.decoded(by: "checksum"),
            hasExistingXmp: false,
            faceCount: try row.decoded(by: "face_count"),
            width: 0, // TS: SELECT 未含 width/height，row.width ?? 0 → 恒 0
            height: 0,
            metadata: "{}",
            result: "{}",
            status: try row.decoded(by: "status"),
            createdAt: try row.decoded(by: "created_at"),
            updatedAt: try row.decoded(by: "updated_at")
        )
    }
}

// MARK: - 纯函数（对账友好）

/// TS: escapeLike。
public func escapeLike(_ value: String) -> String {
    value.replacingOccurrences(of: #"([\\%_])"#, with: #"\\$1"#, options: .regularExpression)
}

/// TS: stringValue（value 的 String 化：String 直取，其他 JSONValue → "\(value)"）。
private func stringValue(_ value: JSONValue) -> String {
    if let string = value.stringValue { return string }
    return "\(value)"
}

private func parseKeywords(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else { return [] }
    return parsed.compactMap { $0 as? String }
}

/// 过滤引擎错误（description 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
public enum FilterEngineError: Error, CustomStringConvertible {
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
