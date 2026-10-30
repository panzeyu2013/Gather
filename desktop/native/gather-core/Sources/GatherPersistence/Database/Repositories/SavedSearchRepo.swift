// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/SavedSearchRepo.swift
// P1 下一波 §3.7.3：保存查询（saved_searches）。
//
// 约定：
// - criteria_json 是完整的 FilterGroup（4 档过滤 + 搜索串 + 规则已在保存前合成）；
// - session_id 可空（NULL = 全局查询）；
// - name 在同作用域内唯一：重名 = 覆盖原行（不新增）。SQLite 的 UNIQUE(session_id,name)
//   对 NULL 不生效（NULL 互不相等），所以"全局同名覆盖"必须在这里显式处理；
// - 上限由调用方（gallery_saved_search_limit）判断，本 repo 只提供计数。
import Foundation
import GatherProtocol

public struct SavedSearchRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let sessionId: String?
    public let criteria: FilterGroup
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String, name: String, sessionId: String?, criteria: FilterGroup,
        createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.sessionId = sessionId
        self.criteria = criteria
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SavedSearchRepoError: Error, Equatable, CustomStringConvertible {
    /// 存量行里的 criteria_json 不是合法的 FilterGroup（外部写坏/旧格式）。
    case corruptedCriteria(id: String)
    case notFound(String)

    public var description: String {
        switch self {
        case .corruptedCriteria(let id):
            "FILTER_CRITERIA_INVALID: saved search \(id)"
        case .notFound(let id):
            "SAVED_SEARCH_NOT_FOUND: \(id)"
        }
    }
}

public final class SavedSearchRepo {
    private let connection: DBConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 作用域列表：全局 + 该会话（sessionId == nil 只返回全局），按 updated_at 倒序。
    public func list(sessionId: String?) throws -> [SavedSearchRow] {
        let rows: [DBRow]
        if let sessionId {
            rows = try connection.prepare("""
                SELECT id, name, session_id, criteria_json, created_at, updated_at
                FROM saved_searches
                WHERE session_id IS NULL OR session_id = ?
                ORDER BY updated_at DESC, name ASC
                """).query([.text(sessionId)])
        } else {
            rows = try connection.prepare("""
                SELECT id, name, session_id, criteria_json, created_at, updated_at
                FROM saved_searches
                WHERE session_id IS NULL
                ORDER BY updated_at DESC, name ASC
                """).query()
        }
        return try rows.map(row)
    }

    public func get(id: String) throws -> SavedSearchRow? {
        let found = try connection.prepare("""
            SELECT id, name, session_id, criteria_json, created_at, updated_at
            FROM saved_searches WHERE id = ?
            """).get([.text(id)])
        guard let found else { return nil }
        return try row(found)
    }

    /// 保存：同作用域同名覆盖，否则插入。返回落库后的行。
    public func upsert(
        name: String,
        sessionId: String?,
        criteria: FilterGroup
    ) throws -> SavedSearchRow {
        let json = try encoder.encode(criteria)
        guard let criteriaJSON = String(data: json, encoding: .utf8) else {
            throw SavedSearchRepoError.corruptedCriteria(id: name)
        }
        let now = nowISOString()
        return try connection.transaction {
            let existing: DBRow?
            if let sessionId {
                existing = try connection.prepare(
                    "SELECT id FROM saved_searches WHERE name = ? AND session_id = ?")
                    .get([.text(name), .text(sessionId)])
            } else {
                existing = try connection.prepare(
                    "SELECT id FROM saved_searches WHERE name = ? AND session_id IS NULL")
                    .get([.text(name)])
            }
            if let existing, let id = existing[0].textValue {
                _ = try connection.prepare("""
                    UPDATE saved_searches SET criteria_json = ?, updated_at = ? WHERE id = ?
                    """).run([.text(criteriaJSON), .text(now), .text(id)])
                guard let saved = try get(id: id) else {
                    throw SavedSearchRepoError.notFound(id)
                }
                return saved
            }
            let id = newUUIDString()
            _ = try connection.prepare("""
                INSERT INTO saved_searches (id, name, session_id, criteria_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """).run([
                    .text(id), .text(name), optDB(sessionId), .text(criteriaJSON),
                    .text(now), .text(now),
                ])
            guard let saved = try get(id: id) else {
                throw SavedSearchRepoError.notFound(id)
            }
            return saved
        }
    }

    /// 删除；返回是否真的删掉了（不存在 = false，调用方转错误）。
    public func delete(id: String) throws -> Bool {
        try connection.prepare("DELETE FROM saved_searches WHERE id = ?").run([.text(id)]) > 0
    }

    /// 全部行数（上限判断用：上限是"登记表"容量，不按会话分桶）。
    public func count() throws -> Int {
        Int(try connection.prepare("SELECT COUNT(*) AS n FROM saved_searches")
            .get()?[0].intValue ?? 0)
    }

    /// 某作用域内已有的条数（展示"本会话 N 条"用）。
    public func count(sessionId: String?) throws -> Int {
        if let sessionId {
            return Int(try connection.prepare("""
                SELECT COUNT(*) AS n FROM saved_searches
                WHERE session_id IS NULL OR session_id = ?
                """).get([.text(sessionId)])?[0].intValue ?? 0)
        }
        return Int(try connection.prepare("""
            SELECT COUNT(*) AS n FROM saved_searches WHERE session_id IS NULL
            """).get()?[0].intValue ?? 0)
    }

    // MARK: - 行映射

    private func row(_ row: DBRow) throws -> SavedSearchRow {
        let id = row[0].textValue ?? ""
        let json = row[3].textValue ?? ""
        guard let data = json.data(using: .utf8) else {
            throw SavedSearchRepoError.corruptedCriteria(id: id)
        }
        let criteria: FilterGroup
        do {
            criteria = try decoder.decode(FilterGroup.self, from: data)
        } catch {
            throw SavedSearchRepoError.corruptedCriteria(id: id)
        }
        return SavedSearchRow(
            id: id,
            name: row[1].textValue ?? "",
            sessionId: row[2].textValue,
            criteria: criteria,
            createdAt: row[4].textValue ?? "",
            updatedAt: row[5].textValue ?? "")
    }
}
