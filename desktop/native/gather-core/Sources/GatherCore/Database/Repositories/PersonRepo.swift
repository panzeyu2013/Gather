// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/PersonRepo.swift
// TS 源: desktop/src/main/db/repositories/person.repo.ts
import Foundation

/// persons 表行 + thumbnail_path（最近照片 filepath，无关联照片时为 nil）。
/// get()/listWithCounts() 的 SELECT 带 thumbnail_path 子查询（9/10 列）；
/// list() 为 SELECT *（8 列，无 thumbnail_path 列）。
public struct PersonRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let keywords: String
    public let thumbnailBase64: String
    public let thumbnailPath: String?
    public let notes: String
    public let matchThreshold: Double
    public let createdAt: String
    public let updatedAt: String

    // 表列序（SELECT *，8 列）: id(0), name(1), keywords(2), thumbnail_base64(3),
    //   notes(4), match_threshold(5), created_at(6), updated_at(7)
    // get() 追加 thumbnail_path 子查询（9 列，位于索引 8）；
    // listWithCounts() 追加 thumbnail_path(8) + photo_count(9)/session_count(10)。
    init(row: DBRow) throws {
        guard row.count == 8 || row.count == 9 || row.count == 11 else {
            throw DBError.message("PersonRow 列数异常: \(row.count)")
        }
        id = row[0].textValue ?? ""
        name = row[1].textValue ?? ""
        keywords = row[2].textValue ?? ""
        thumbnailBase64 = row[3].textValue ?? ""
        notes = row[4].textValue ?? ""
        matchThreshold = row[5].doubleValue ?? 0
        createdAt = row[6].textValue ?? ""
        updatedAt = row[7].textValue ?? ""
        thumbnailPath = row.count >= 9 ? row[8].textValue : nil
    }
}

/// listWithCounts 的行：PersonRow + photo_count/session_count（第 9/10 列）。
public struct PersonWithCountsRow: Equatable, Sendable {
    public let person: PersonRow
    public let photoCount: Int
    public let sessionCount: Int

    init(row: DBRow) throws {
        person = try PersonRow(row: row)
        photoCount = Int(row[9].intValue ?? 0)
        sessionCount = Int(row[10].intValue ?? 0)
    }
}

/// person_embeddings 表行（SELECT *）。
public struct PersonEmbeddingRow: Equatable, Sendable {
    // 表列序: id(0), person_id(1), embedding(2), photo_id(3), session_id(4),
    // face_observation_id(5), face_bbox(6), quality(7), created_at(8)
    public let id: Int64
    public let personId: String
    public let embedding: Data
    public let photoId: String
    public let sessionId: String
    public let faceObservationId: Int64?
    public let faceBbox: String
    public let quality: Double
    public let createdAt: String

    init(row: DBRow) throws {
        guard row.count >= 9 else { throw DBError.message("PersonEmbeddingRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        personId = row[1].textValue ?? ""
        embedding = row[2].blobValue ?? Data()
        photoId = row[3].textValue ?? ""
        sessionId = row[4].textValue ?? ""
        faceObservationId = row[5].intValue
        faceBbox = row[6].textValue ?? ""
        quality = row[7].doubleValue ?? 0
        createdAt = row[8].textValue ?? ""
    }
}

/// person_photos 表行（SELECT *）。
public struct PersonPhotoRow: Equatable, Sendable {
    // 表列序: id(0), person_id(1), photo_id(2), session_id(3), face_bbox(4),
    // confidence(5), created_at(6)
    public let id: Int64
    public let personId: String
    public let photoId: String
    public let sessionId: String
    public let faceBbox: String
    public let confidence: Double
    public let createdAt: String

    init(row: DBRow) throws {
        guard row.count >= 7 else { throw DBError.message("PersonPhotoRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        personId = row[1].textValue ?? ""
        photoId = row[2].textValue ?? ""
        sessionId = row[3].textValue ?? ""
        faceBbox = row[4].textValue ?? ""
        confidence = row[5].doubleValue ?? 0
        createdAt = row[6].textValue ?? ""
    }
}

/// getPhotosWithDetails 的行：PersonPhotoRow + 会话名/文件名/路径（JOIN）。
public struct PersonPhotoDetail: Equatable, Sendable {
    // pp.*(0-6) + session_name(7), filename(8), filepath(9)
    public let photo: PersonPhotoRow
    public let sessionName: String
    public let filename: String
    public let filepath: String

    init(row: DBRow) throws {
        photo = try PersonPhotoRow(row: row)
        sessionName = row[7].textValue ?? ""
        filename = row[8].textValue ?? ""
        filepath = row[9].textValue ?? ""
    }
}

/// getAllEmbeddings 的轻量行（TS: { person_id, embedding, face_observation_id }）。
public struct PersonEmbeddingRef: Equatable, Sendable {
    public let personId: String
    public let embedding: Data
    public let faceObservationId: Int64?
}

// 共享 DTO（PersonPhotoInput / SaveEmbeddingInput / PersonUpdateFields）已迁至
// Store/PersonStore.swift（R1 单一来源）。

public final class PersonRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func list() throws -> [PersonRow] {
        let rows = try connection.prepare("SELECT * FROM persons ORDER BY name").query()
        return try rows.map { try PersonRow(row: $0) }
    }

    public func listWithCounts() throws -> [PersonWithCountsRow] {
        let rows = try connection.prepare(
            "SELECT p.*, (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id WHERE pp.person_id = p.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) as thumbnail_path, COALESCE(pp.photo_count, 0) as photo_count, COALESCE(pp.session_count, 0) as session_count FROM persons p LEFT JOIN (SELECT person_id, COUNT(*) as photo_count, COUNT(DISTINCT session_id) as session_count FROM person_photos GROUP BY person_id) pp ON p.id = pp.person_id ORDER BY p.name"
        ).query()
        return try rows.map { try PersonWithCountsRow(row: $0) }
    }

    public func get(id: String) throws -> PersonRow? {
        guard let row = try connection.prepare(
            "SELECT *, (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id WHERE pp.person_id = persons.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) as thumbnail_path FROM persons WHERE id = ?"
        ).get([.text(id)]) else {
            return nil
        }
        return try PersonRow(row: row)
    }

    public func create(name: String, keywords: [String]? = nil) throws -> String {
        let id = newUUID()
        let now = nowISO()
        _ = try connection.prepare(
            "INSERT INTO persons (id, name, keywords, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
        ).run([.text(id), .text(name), .text(jsonString(keywords ?? [])), .text(now), .text(now)])
        return id
    }

    /// 按精确姓名查找，不存在则创建（TS: upsertByName，绑定人脸角色时使用）。
    public func upsertByName(name: String, keywords: [String]? = nil) throws -> String {
        guard let existing = try connection.prepare("SELECT id, keywords FROM persons WHERE name = ?").get([.text(name)]) else {
            return try create(name: name, keywords: keywords)
        }
        let existingId = existing[0].textValue ?? ""
        if let keywords, !keywords.isEmpty {
            let existingKeywords = parseKeywords(existing[1].textValue ?? "")
            var merged = existingKeywords
            for keyword in keywords where !merged.contains(keyword) {
                merged.append(keyword)
            }
            if merged.count != existingKeywords.count {
                try update(id: existingId, fields: PersonUpdateFields(keywords: merged))
            }
        }
        return existingId
    }

    /// 批量添加照片到人物（INSERT OR IGNORE，重复安全，可用于重复绑定）。
    public func addPhotos(personId: String, sessionId: String, photos: [PersonPhotoInput]) throws {
        if photos.isEmpty { return }
        let now = nowISO()
        let stmt = try connection.prepare(
            "INSERT OR IGNORE INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for photo in photos {
                _ = try stmt.run([
                    .text(personId), .text(photo.photoId), .text(sessionId),
                    .text(jsonString(photo.faceBbox)), .real(photo.confidence), .text(now),
                ])
            }
        }
    }

    /// 按会话对账人物↔照片桥接表（角色绑定 → 链接增删）。
    public func reconcileSession(sessionId: String) throws {
        let bindingRows = try connection.prepare(
            "SELECT rb.role_name, fcm.photo_id, fcm.bbox, fcm.confidence FROM role_bindings rb JOIN face_cluster_members fcm ON fcm.cluster_id = rb.cluster_id WHERE rb.session_id = ?"
        ).query([.text(sessionId)])

        var desiredByRole: [String: [String: (bbox: [Double], confidence: Double)]] = [:]
        for row in bindingRows {
            let roleName = row[0].textValue ?? ""
            let photoId = row[1].textValue ?? ""
            let bbox = decodeBbox(row[2].textValue ?? "")
            let confidence = row[3].doubleValue ?? 0
            if desiredByRole[roleName] == nil {
                desiredByRole[roleName] = [:]
            }
            desiredByRole[roleName]?[photoId] = (bbox, confidence)
        }

        var affected: Set<String> = []
        for roleName in desiredByRole.keys {
            affected.insert(try upsertByName(name: roleName))
        }
        let linkedRows = try connection.prepare("SELECT DISTINCT person_id FROM person_photos WHERE session_id = ?")
            .query([.text(sessionId)])
        for row in linkedRows {
            if let personId = row[0].textValue {
                affected.insert(personId)
            }
        }
        if affected.isEmpty { return }

        let now = nowISO()
        let insertStmt = try connection.prepare(
            "INSERT OR IGNORE INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for personId in affected {
                let roleName = try get(id: personId)?.name ?? ""
                guard let desired = desiredByRole[roleName], !desired.isEmpty else {
                    _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ? AND session_id = ?")
                        .run([.text(personId), .text(sessionId)])
                    continue
                }
                let existingRows = try connection.prepare(
                    "SELECT photo_id FROM person_photos WHERE person_id = ? AND session_id = ?"
                ).query([.text(personId), .text(sessionId)])
                for existing in existingRows {
                    if let existingPhotoId = existing[0].textValue, desired[existingPhotoId] == nil {
                        _ = try connection.prepare(
                            "DELETE FROM person_photos WHERE person_id = ? AND session_id = ? AND photo_id = ?"
                        ).run([.text(personId), .text(sessionId), .text(existingPhotoId)])
                    }
                }
                for (photoId, info) in desired {
                    _ = try insertStmt.run([
                        .text(personId), .text(photoId), .text(sessionId),
                        .text(jsonString(info.bbox)), .real(info.confidence), .text(now),
                    ])
                }
            }
        }
    }

    public func update(id: String, fields: PersonUpdateFields) throws {
        let now = nowISO()
        var sets: [String] = []
        var values: [DBValue?] = []

        if let name = fields.name {
            sets.append("name = ?")
            values.append(.text(name))
        }
        if let keywords = fields.keywords {
            sets.append("keywords = ?")
            values.append(.text(jsonString(keywords)))
        }
        if let notes = fields.notes {
            sets.append("notes = ?")
            values.append(.text(notes))
        }
        if let matchThreshold = fields.matchThreshold {
            sets.append("match_threshold = ?")
            values.append(.real(matchThreshold))
        }

        if sets.isEmpty { return }

        sets.append("updated_at = ?")
        values.append(.text(now))
        values.append(.text(id))

        _ = try connection.prepare("UPDATE persons SET \(sets.joined(separator: ", ")) WHERE id = ?").run(values)
    }

    public func updateThumbnail(id: String, base64: String) throws {
        _ = try connection.prepare("UPDATE persons SET thumbnail_base64 = ? WHERE id = ?")
            .run([.text(base64), .text(id)])
    }

    public func delete(id: String) throws {
        _ = try connection.prepare("DELETE FROM persons WHERE id = ?").run([.text(id)])
    }

    /// 合并来源人物到目标人物：嵌入/照片转移、关键词并集、删除来源。
    public func merge(sourceId: String, targetId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("UPDATE person_embeddings SET person_id = ? WHERE person_id = ?")
                .run([.text(targetId), .text(sourceId)])
            _ = try connection.prepare("UPDATE person_photos SET person_id = ? WHERE person_id = ?")
                .run([.text(targetId), .text(sourceId)])
            let mergedKeywords = try getMergedKeywords(sourceId: sourceId, targetId: targetId)
            let now = nowISO()
            _ = try connection.prepare("UPDATE persons SET keywords = ?, updated_at = ? WHERE id = ?")
                .run([.text(jsonString(mergedKeywords)), .text(now), .text(targetId)])
            _ = try connection.prepare("DELETE FROM persons WHERE id = ?").run([.text(sourceId)])
        }
    }

    private func getMergedKeywords(sourceId: String, targetId: String) throws -> [String] {
        var merged: [String] = []
        let sourceRow = try connection.prepare("SELECT keywords FROM persons WHERE id = ?").get([.text(sourceId)])
        let targetRow = try connection.prepare("SELECT keywords FROM persons WHERE id = ?").get([.text(targetId)])
        if let sourceRow {
            for keyword in parseKeywords(sourceRow[0].textValue ?? "") where !merged.contains(keyword) {
                merged.append(keyword)
            }
        }
        if let targetRow {
            for keyword in parseKeywords(targetRow[0].textValue ?? "") where !merged.contains(keyword) {
                merged.append(keyword)
            }
        }
        return merged
    }

    public func getPhotos(personId: String, sessionIds: [String]? = nil, limit: Int? = nil, offset: Int? = nil) throws -> [PersonPhotoRow] {
        var sql = "SELECT * FROM person_photos WHERE person_id = ?"
        var params: [DBValue?] = [.text(personId)]
        if let sessionIds, !sessionIds.isEmpty {
            sql += " AND session_id IN (\(sessionIds.map { _ in "?" }.joined(separator: ",")))"
            params.append(contentsOf: sessionIds.map { .text($0) })
        }
        sql += " ORDER BY created_at DESC"
        if let limit {
            sql += " LIMIT ?"
            params.append(.int(Int64(limit)))
        }
        if let offset {
            sql += " OFFSET ?"
            params.append(.int(Int64(offset)))
        }
        let rows = try connection.prepare(sql).query(params)
        return try rows.map { try PersonPhotoRow(row: $0) }
    }

    public func removePhoto(personId: String, photoId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ? AND photo_id = ?")
                .run([.text(personId), .text(photoId)])
            _ = try connection.prepare("DELETE FROM person_embeddings WHERE person_id = ? AND photo_id = ?")
                .run([.text(personId), .text(photoId)])
        }
    }

    public func getPersonPhoto(personId: String, photoId: String) throws -> PersonPhotoRow? {
        guard let row = try connection.prepare(
            "SELECT * FROM person_photos WHERE person_id = ? AND photo_id = ?"
        ).get([.text(personId), .text(photoId)]) else {
            return nil
        }
        return try PersonPhotoRow(row: row)
    }

    public func addPhoto(personId: String, photoId: String, sessionId: String, faceBbox: [Double], confidence: Double) throws {
        let now = nowISO()
        _ = try connection.prepare(
            "INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        ).run([.text(personId), .text(photoId), .text(sessionId), .text(jsonString(faceBbox)), .real(confidence), .text(now)])
    }

    /// 批量保存嵌入（INSERT OR REPLACE，按 face_observation_id 唯一替换）。
    public func saveEmbeddings(embeddings: [SaveEmbeddingInput]) throws {
        let now = nowISO()
        let stmt = try connection.prepare(
            "INSERT OR REPLACE INTO person_embeddings (person_id, embedding, photo_id, session_id, face_observation_id, face_bbox, quality, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for emb in embeddings {
                _ = try stmt.run([
                    .text(emb.personId),
                    .blob(float32Data(emb.embedding)),
                    .text(emb.photoId),
                    .text(emb.sessionId),
                    emb.faceObservationId.map { .int($0) },
                    .text(jsonString(emb.faceBbox)),
                    .real(emb.quality),
                    .text(now),
                ])
            }
        }
    }

    public func deleteEmbeddingsByObservationIds(observationIds: [Int64]) throws {
        if observationIds.isEmpty { return }
        let placeholders = observationIds.map { _ in "?" }.joined(separator: ",")
        _ = try connection.prepare("DELETE FROM person_embeddings WHERE face_observation_id IN (\(placeholders))")
            .run(observationIds.map { .int($0) })
    }

    public func getAllEmbeddings() throws -> [PersonEmbeddingRef] {
        let rows = try connection.prepare(
            "SELECT person_id, embedding, face_observation_id FROM person_embeddings"
        ).query()
        return rows.map { row in
            PersonEmbeddingRef(
                personId: row[0].textValue ?? "",
                embedding: row[1].blobValue ?? Data(),
                faceObservationId: row[2].intValue
            )
        }
    }

    public func getEmbeddingsByPerson(personId: String) throws -> [PersonEmbeddingRow] {
        let rows = try connection.prepare("SELECT * FROM person_embeddings WHERE person_id = ? ORDER BY id")
            .query([.text(personId)])
        return try rows.map { try PersonEmbeddingRow(row: $0) }
    }

    public func deleteEmbeddingsByPerson(personId: String) throws {
        _ = try connection.prepare("DELETE FROM person_embeddings WHERE person_id = ?").run([.text(personId)])
    }

    public func countEmbeddings(personId: String) throws -> Int {
        let row = try connection.prepare("SELECT COUNT(*) as count FROM person_embeddings WHERE person_id = ?")
            .get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func countPhotos(personId: String) throws -> Int {
        let row = try connection.prepare("SELECT COUNT(*) as count FROM person_photos WHERE person_id = ?")
            .get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func getSessionCount(personId: String) throws -> Int {
        let row = try connection.prepare("SELECT COUNT(DISTINCT session_id) as count FROM person_photos WHERE person_id = ?")
            .get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func getThumbnailBase64(personId: String) throws -> String {
        let row = try connection.prepare("SELECT thumbnail_base64 FROM persons WHERE id = ?").get([.text(personId)])
        return row?[0].textValue ?? ""
    }

    public func getPhotosWithDetails(personId: String, sessionIds: [String]? = nil, limit: Int? = nil, offset: Int? = nil) throws -> (photos: [PersonPhotoDetail], total: Int) {
        var whereClause = "pp.person_id = ?"
        var params: [DBValue?] = [.text(personId)]
        if let sessionIds, !sessionIds.isEmpty {
            whereClause += " AND pp.session_id IN (\(sessionIds.map { _ in "?" }.joined(separator: ",")))"
            params.append(contentsOf: sessionIds.map { .text($0) })
        }

        let countRow = try connection.prepare("SELECT COUNT(*) as count FROM person_photos pp WHERE \(whereClause)")
            .get(params)
        let total = Int(countRow?[0].intValue ?? 0)

        var sql = """
        SELECT pp.*, s.name as session_name, p.filename, p.filepath
        FROM person_photos pp
        JOIN sessions s ON pp.session_id = s.id
        JOIN photos p ON pp.photo_id = p.id
        WHERE \(whereClause)
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

    // ── 私有辅助 ──

    private func parseKeywords(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return parsed
    }

    private func decodeBbox(_ raw: String) -> [Double] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Double].self, from: data) else {
            return []
        }
        return decoded
    }
}

private extension DBValue {
    var blobValue: Data? {
        if case .blob(let data) = self { return data }
        return nil
    }
}

/// TS: JSON.stringify(keywords) —— JSON 数组文本。
private func jsonString(_ keywords: [String]) -> String {
    guard let data = try? JSONEncoder().encode(keywords) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// TS: JSON.stringify(faceBbox)（number[]）。
private func jsonString(_ bbox: [Double]) -> String {
    guard let data = try? JSONEncoder().encode(bbox) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// TS: Buffer.from(new Float32Array(embedding).buffer) —— Float32 小端字节序。
private func float32Data(_ floats: [Float]) -> Data {
    floats.withUnsafeBytes { Data($0) }
}

private func newUUID() -> String {
    UUID().uuidString.lowercased()
}

private func nowISO() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
