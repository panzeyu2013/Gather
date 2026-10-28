// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PersonRepo+Query.swift
// 源：PersonRepo.swift（HEAD 3fbf997）；纯拆分（只读查询），方法体/SQL/错误逐字未改。
// 访问级：connection 为 internal（记账见 PersonRepo.swift 头部）。

import Foundation
import GatherProtocol

extension PersonRepo {
    // ─────────────────────────── 查询 ───────────────────────────

    public func list() throws -> [PersonRow] {
        // persons：8 列（TableColumns.persons，列序 = PersonRow 0-7）
        let rows = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.persons)) FROM persons ORDER BY name").query()
        return try rows.map { try PersonRow(row: $0) }
    }

    public func listWithCounts() throws -> [PersonWithCountsRow] {
        // persons：8 列 + thumbnail_path/photo_count/session_count（PersonWithCountsRow 0-10）
        let rows = try connection.prepare(
            "SELECT \(TableColumns.sql(TableColumns.persons, prefix: "p")), (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id AND ph.archived_at IS NULL WHERE pp.person_id = p.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) as thumbnail_path, COALESCE(pp.photo_count, 0) as photo_count, COALESCE(pp.session_count, 0) as session_count FROM persons p LEFT JOIN (SELECT pph.person_id, COUNT(*) as photo_count, COUNT(DISTINCT pph.session_id) as session_count FROM person_photos pph JOIN photos pv ON pv.id = pph.photo_id AND pv.archived_at IS NULL GROUP BY pph.person_id) pp ON p.id = pp.person_id ORDER BY p.name"
        ).query()
        return try rows.map { try PersonWithCountsRow(row: $0) }
    }

    /// 批量身份摘要（名字 + match_threshold）；未命中的 id 不出现在结果中。
    public func summaries(ids: [String]) throws -> [String: PersonIdentitySummary] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: PersonIdentitySummary] = [:]
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare(
                "SELECT id, name, match_threshold FROM persons WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            for row in rows {
                guard let id = row[0].textValue else { continue }
                result[id] = PersonIdentitySummary(
                    id: id,
                    name: row[1].textValue ?? "",
                    matchThreshold: row[2].doubleValue ?? 0.65
                )
            }
        }
        return result
    }

    public func get(id: String) throws -> PersonRow? {
        // persons：8 列 + thumbnail_path（PersonRow 9 列）
        guard let row = try connection.prepare(
            "SELECT \(TableColumns.sql(TableColumns.persons)), (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id AND ph.archived_at IS NULL WHERE pp.person_id = persons.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) as thumbnail_path FROM persons WHERE id = ?"
        ).get([.text(id)]) else {
            return nil
        }
        return try PersonRow(row: row)
    }

    public func countPhotos(personId: String) throws -> Int {
        // P1：归档（已移出工作区）的照片不再计入人物照片数。
        let row = try connection.prepare("""
            SELECT COUNT(*) as count
            FROM person_photos pp
            JOIN photos p ON p.id = pp.photo_id
            WHERE pp.person_id = ? AND p.archived_at IS NULL
          """).get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func getSessionCount(personId: String) throws -> Int {
        let row = try connection.prepare("""
            SELECT COUNT(DISTINCT pp.session_id) as count
            FROM person_photos pp
            JOIN photos p ON p.id = pp.photo_id
            WHERE pp.person_id = ? AND p.archived_at IS NULL
          """).get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func getPhotosWithDetails(personId: String, sessionIds: [String]? = nil, limit: Int? = nil, offset: Int? = nil) throws -> (photos: [PersonPhotoDetail], total: Int) {
        var whereClause = "pp.person_id = ?"
        var params: [DBValue?] = [.text(personId)]
        if let sessionIds, !sessionIds.isEmpty {
            whereClause += " AND pp.session_id IN (\(sessionIds.map { _ in "?" }.joined(separator: ",")))"
            params.append(contentsOf: sessionIds.map { .text($0) })
        }

        let countRow = try connection.prepare("""
            SELECT COUNT(*) as count
            FROM person_photos pp
            JOIN photos p ON p.id = pp.photo_id
            WHERE \(whereClause) AND p.archived_at IS NULL
          """).get(params)
        let total = Int(countRow?[0].intValue ?? 0)

        // person_photos：7 列 + session_name/filename/filepath（PersonPhotoDetail 0-9）
        var sql = """
        SELECT \(TableColumns.sql(TableColumns.personPhotos, prefix: "pp")), s.name as session_name, p.filename, p.filepath
        FROM person_photos pp
        JOIN sessions s ON pp.session_id = s.id
        JOIN photos p ON pp.photo_id = p.id
        WHERE \(whereClause) AND p.archived_at IS NULL
        ORDER BY pp.created_at DESC
        """
        var queryParams = params
        if let limit {
            sql += " LIMIT ?"
            queryParams.append(.int(Int64(limit)))
        }
        if let offset {
            sql += " OFFSET ?"
            queryParams.append(.int(Int64(offset)))
        }

        let rows = try connection.prepare(sql).query(queryParams)
        let photos = try rows.map { try PersonPhotoDetail(row: $0) }
        return (photos, total)
    }
}
