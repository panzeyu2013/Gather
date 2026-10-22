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
        return try rows.map(rowToPhotoRow)
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
            return FilterWhereClause(sql: "", params: [])
        }
        let joiner = group.logic == .or ? " OR " : " AND "
        return FilterWhereClause(sql: parts.joined(separator: joiner), params: params)
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
        throw PhotoFilterQueryError.fieldUnknown(field)
    }

    private func resolveSortColumn(_ sortBy: String) -> String {
        if Self.simpleFields.contains(sortBy) { return "p.\(sortBy)" }
        if Self.metadataFields.contains(sortBy) { return "pmc.\(sortBy)" }
        return "p.filename"
    }

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
    func countGlobally(criteria: FilterGroup, sessionId: String?) throws -> Int
    func countPhotos(sessionId: String, criteria: FilterGroup) throws -> Int
    func suggest(_ sessionId: String, keyword: String) throws -> [FilterSuggestion]
}

extension PhotoFilterQuery: PhotoFilterQuerying {}
