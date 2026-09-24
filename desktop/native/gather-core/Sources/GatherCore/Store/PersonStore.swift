// Store/PersonStore.swift
// R1：persons / person_photos / person_embeddings 的访问入口
// （取代 Database/Repositories/PersonRepo.swift；本轮先落 CRUD/计数/照片桥接，
//  merge/嵌入存取/reconcileSession 随后并入同一 Store）。
import Foundation

public struct PersonRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let keywords: String
    public let thumbnailBase64: String
    public let thumbnailPath: String?
    public let notes: String
    public let matchThreshold: Double
    public let createdAt: String
    public let updatedAt: String

    /// keywords JSON → 字符串数组。
    public var keywordList: [String] {
        ((try? JSONValue.parse(keywords)) as JSONValue?)?.arrayValue ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, name, keywords, notes
        case thumbnailBase64 = "thumbnail_base64"
        case thumbnailPath = "thumbnail_path"
        case matchThreshold = "match_threshold"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct PersonWithCounts: Decodable, Equatable, Sendable {
    public let person: PersonRecord
    public let photoCount: Int
    public let sessionCount: Int

    /// listWithCounts 的列是 p.* 展开，因此人员字段与计数同级。
    public init(from decoder: Decoder) throws {
        person = try PersonRecord(from: decoder)
        let container = try decoder.container(keyedBy: CountKeys.self)
        photoCount = try container.decode(Int.self, forKey: .photoCount)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
    }

    private enum CountKeys: String, CodingKey {
        case photoCount = "photo_count"
        case sessionCount = "session_count"
    }
}

public struct PersonPhotoRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let personId: String
    public let photoId: String
    public let sessionId: String
    public let faceBbox: String
    public let confidence: Double
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, confidence
        case personId = "person_id"
        case photoId = "photo_id"
        case sessionId = "session_id"
        case faceBbox = "face_bbox"
        case createdAt = "created_at"
    }
}

/// W2b：person_photos JOIN persons 的照片-姓名行（culling 富查询用；按 p.name 排序，
/// 同名去重由调用方保序处理）。
public struct PersonPhotoNameRow: Equatable, Sendable {
    public let photoId: String
    public let name: String

    public init(photoId: String, name: String) {
        self.photoId = photoId
        self.name = name
    }
}

public protocol PersonStore: Sendable {
    func list() async throws -> [PersonRecord]
    func listWithCounts() async throws -> [PersonWithCounts]
    func get(id: String) async throws -> PersonRecord?
    func create(name: String, keywords: [String]?) async throws -> String
    func upsertByName(name: String, keywords: [String]?) async throws -> String
    func addPhotos(personId: String, sessionId: String, photos: [PersonPhotoInput]) async throws
    func addPhoto(personId: String, photoId: String, sessionId: String, faceBbox: [Double], confidence: Double) async throws
    func getPhotos(personId: String, sessionIds: [String]?, limit: Int?, offset: Int?) async throws -> [PersonPhotoRecord]
    func getPersonPhoto(personId: String, photoId: String) async throws -> PersonPhotoRecord?
    /// W2b：批量照片 → 人物名（ORDER BY p.name）；photoIds 为空返回 []。
    func personNamesByPhoto(sessionId: String, photoIds: [String]) async throws -> [PersonPhotoNameRow]
    func removePhoto(personId: String, photoId: String) async throws
    func countPhotos(personId: String) async throws -> Int
    func sessionCount(personId: String) async throws -> Int
    func thumbnailBase64(personId: String) async throws -> String

    // MARK: 更新 / 合并 / 明细

    func update(id: String, fields: PersonUpdateFields) async throws
    func updateThumbnail(id: String, base64: String) async throws
    func deletePerson(id: String) async throws
    func merge(sourceId: String, targetId: String) async throws
    func getPhotosWithDetails(
        personId: String,
        sessionIds: [String]?,
        limit: Int?,
        offset: Int?
    ) async throws -> (photos: [PersonPhotoDetailRecord], total: Int)

    // MARK: 嵌入

    func saveEmbeddings(_ embeddings: [SaveEmbeddingInput]) async throws
    func deleteEmbeddingsByObservationIds(_ observationIds: [Int64]) async throws
    func allEmbeddings() async throws -> [PersonEmbeddingRefRecord]
    func embeddings(personId: String) async throws -> [PersonEmbeddingRecord]
    func deleteEmbeddings(personId: String) async throws
    func countEmbeddings(personId: String) async throws -> Int

    // MARK: 角色绑定对账

    func reconcileSession(sessionId: String) async throws
}

public struct PersonEmbeddingRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let personId: String
    public let embedding: Data
    public let photoId: String
    public let sessionId: String
    public let faceObservationId: Int64?
    public let faceBbox: String
    public let quality: Double
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, embedding, quality
        case personId = "person_id"
        case photoId = "photo_id"
        case sessionId = "session_id"
        case faceObservationId = "face_observation_id"
        case faceBbox = "face_bbox"
        case createdAt = "created_at"
    }
}

public struct PersonEmbeddingRefRecord: Equatable, Sendable {
    public let personId: String
    public let embedding: Data
    public let faceObservationId: Int64?
}

public struct PersonPhotoDetailRecord: Decodable, Equatable, Sendable {
    public let photo: PersonPhotoRecord
    public let sessionName: String
    public let filename: String
    public let filepath: String

    public init(from decoder: Decoder) throws {
        photo = try PersonPhotoRecord(from: decoder)
        let container = try decoder.container(keyedBy: ExtraKeys.self)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        filename = try container.decode(String.self, forKey: .filename)
        filepath = try container.decode(String.self, forKey: .filepath)
    }

    private enum ExtraKeys: String, CodingKey {
        case sessionName = "session_name"
        case filename
        case filepath
    }
}

public extension PersonStore {
    func create(name: String) async throws -> String {
        try await create(name: name, keywords: nil)
    }

    func upsertByName(name: String) async throws -> String {
        try await upsertByName(name: name, keywords: nil)
    }

    func getPhotos(personId: String) async throws -> [PersonPhotoRecord] {
        try await getPhotos(personId: personId, sessionIds: nil, limit: nil, offset: nil)
    }
}

public struct SQLitePersonStore: PersonStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: 查询

    public func list() async throws -> [PersonRecord] {
        try await database.query("SELECT * FROM persons ORDER BY name")
            .map { try $0.decode(PersonRecord.self) }
    }

    public func listWithCounts() async throws -> [PersonWithCounts] {
        try await database.query(
            """
            SELECT p.*,
              (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id
               WHERE pp.person_id = p.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) AS thumbnail_path,
              COALESCE(pp.photo_count, 0) AS photo_count,
              COALESCE(pp.session_count, 0) AS session_count
            FROM persons p
            LEFT JOIN (
              SELECT person_id, COUNT(*) AS photo_count, COUNT(DISTINCT session_id) AS session_count
              FROM person_photos GROUP BY person_id
            ) pp ON p.id = pp.person_id
            ORDER BY p.name
            """
        ).map { try $0.decode(PersonWithCounts.self) }
    }

    public func get(id: String) async throws -> PersonRecord? {
        try await database.queryOne(
            """
            SELECT *,
              (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id
               WHERE pp.person_id = persons.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) AS thumbnail_path
            FROM persons WHERE id = ?
            """,
            [.text(id)]
        )?.decode(PersonRecord.self)
    }

    // MARK: 写入

    public func create(name: String, keywords: [String]? = nil) async throws -> String {
        let id = newUUIDString()
        let now = nowISOString()
        try await database.run(
            "INSERT INTO persons (id, name, keywords, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(name), .text(Self.jsonString(keywords ?? [])), .text(now), .text(now)]
        )
        return id
    }

    public func upsertByName(name: String, keywords: [String]? = nil) async throws -> String {
        guard let existing = try await database.queryOne(
            "SELECT id, keywords FROM persons WHERE name = ?",
            [.text(name)]
        ) else {
            return try await create(name: name, keywords: keywords)
        }
        let existingId = existing.text("id") ?? ""
        if let keywords, !keywords.isEmpty {
            let existingKeywords = Self.parseKeywords(existing.text("keywords") ?? "")
            var merged = existingKeywords
            for keyword in keywords where !merged.contains(keyword) {
                merged.append(keyword)
            }
            if merged.count != existingKeywords.count {
                try await updateKeywords(id: existingId, keywords: merged)
            }
        }
        return existingId
    }

    internal func updateKeywords(id: String, keywords: [String]) async throws {
        try await database.run(
            "UPDATE persons SET keywords = ?, updated_at = ? WHERE id = ?",
            [.text(Self.jsonString(keywords)), .text(nowISOString()), .text(id)]
        )
    }

    public func addPhotos(personId: String, sessionId: String, photos: [PersonPhotoInput]) async throws {
        guard !photos.isEmpty else { return }
        let now = nowISOString()
        try await database.transaction { db in
            for photo in photos {
                try db.run(
                    """
                    INSERT OR IGNORE INTO person_photos
                      (person_id, photo_id, session_id, face_bbox, confidence, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(personId), .text(photo.photoId), .text(sessionId),
                        .text(Self.jsonString(photo.faceBbox)), .real(photo.confidence), .text(now),
                    ]
                )
            }
        }
    }

    public func addPhoto(
        personId: String,
        photoId: String,
        sessionId: String,
        faceBbox: [Double],
        confidence: Double
    ) async throws {
        try await database.run(
            """
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(personId), .text(photoId), .text(sessionId),
                .text(Self.jsonString(faceBbox)), .real(confidence), .text(nowISOString()),
            ]
        )
    }

    public func removePhoto(personId: String, photoId: String) async throws {
        try await database.transaction { db in
            try db.run(
                "DELETE FROM person_photos WHERE person_id = ? AND photo_id = ?",
                [.text(personId), .text(photoId)]
            )
            try db.run(
                "DELETE FROM person_embeddings WHERE person_id = ? AND photo_id = ?",
                [.text(personId), .text(photoId)]
            )
        }
    }

    // MARK: 照片桥接查询

    public func getPhotos(
        personId: String,
        sessionIds: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> [PersonPhotoRecord] {
        var sql = "SELECT * FROM person_photos WHERE person_id = ?"
        var values: [SQLiteValue] = [.text(personId)]
        if let sessionIds, !sessionIds.isEmpty {
            sql += " AND session_id IN (\(sessionIds.map { _ in "?" }.joined(separator: ",")))"
            values.append(contentsOf: sessionIds.map { .text($0) })
        }
        sql += " ORDER BY created_at DESC"
        if let limit {
            sql += " LIMIT ?"
            values.append(.int(Int64(limit)))
        }
        if let offset {
            sql += " OFFSET ?"
            values.append(.int(Int64(offset)))
        }
        return try await database.query(sql, values).map { try $0.decode(PersonPhotoRecord.self) }
    }

    public func getPersonPhoto(personId: String, photoId: String) async throws -> PersonPhotoRecord? {
        try await database.queryOne(
            "SELECT * FROM person_photos WHERE person_id = ? AND photo_id = ?",
            [.text(personId), .text(photoId)]
        )?.decode(PersonPhotoRecord.self)
    }

    /// W2b：culling 富查询的批量人物名（原 CullingService.loadPeople 的 SQL 下沉）。
    public func personNamesByPhoto(
        sessionId: String,
        photoIds: [String]
    ) async throws -> [PersonPhotoNameRow] {
        guard !photoIds.isEmpty else { return [] }
        var result: [PersonPhotoNameRow] = []
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT pp.photo_id, p.name
                FROM person_photos pp
                JOIN persons p ON p.id = pp.person_id
                WHERE pp.session_id = ? AND pp.photo_id IN (\(placeholders))
                ORDER BY p.name
                """,
                [.text(sessionId)] + chunk.map { .text($0) }
            )
            result.append(contentsOf: rows.map {
                PersonPhotoNameRow(photoId: $0.text("photo_id") ?? "", name: $0.text("name") ?? "")
            })
        }
        return result
    }

    public func countPhotos(personId: String) async throws -> Int {
        Int(try await database.scalarInt(
            "SELECT COUNT(*) AS count FROM person_photos WHERE person_id = ?",
            [.text(personId)]
        ) ?? 0)
    }

    public func sessionCount(personId: String) async throws -> Int {
        Int(try await database.scalarInt(
            "SELECT COUNT(DISTINCT session_id) AS count FROM person_photos WHERE person_id = ?",
            [.text(personId)]
        ) ?? 0)
    }

    public func thumbnailBase64(personId: String) async throws -> String {
        try await database.queryOne("SELECT thumbnail_base64 FROM persons WHERE id = ?", [.text(personId)])?
            .text("thumbnail_base64") ?? ""
    }

    // MARK: 私有：JSON

    internal static func jsonString(_ keywords: [String]) -> String {
        guard let data = try? JSONEncoder().encode(keywords) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    internal static func jsonString(_ bbox: [Double]) -> String {
        guard let data = try? JSONEncoder().encode(bbox) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    internal static func parseKeywords(_ json: String) -> [String] {
        ((try? JSONValue.parse(json)) as JSONValue?)?.arrayValue ?? []
    }
}

// MARK: - 更新 / 合并 / 明细 / 嵌入 / 对账

public extension SQLitePersonStore {
    func update(id: String, fields: PersonUpdateFields) async throws {
        var sets: [String] = []
        var values: [SQLiteValue] = []

        if let name = fields.name {
            sets.append("name = ?")
            values.append(.text(name))
        }
        if let keywords = fields.keywords {
            sets.append("keywords = ?")
            values.append(.text(Self.jsonString(keywords)))
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
        values.append(.text(nowISOString()))
        values.append(.text(id))
        try await database.run("UPDATE persons SET \(sets.joined(separator: ", ")) WHERE id = ?", values)
    }

    func updateThumbnail(id: String, base64: String) async throws {
        try await database.run(
            "UPDATE persons SET thumbnail_base64 = ? WHERE id = ?",
            [.text(base64), .text(id)]
        )
    }

    func deletePerson(id: String) async throws {
        try await database.run("DELETE FROM persons WHERE id = ?", [.text(id)])
    }

    /// 合并来源人物到目标人物：嵌入/照片转移、关键词并集（来源在前）、删除来源。
    func merge(sourceId: String, targetId: String) async throws {
        try await database.transaction { db in
            try db.run("UPDATE person_embeddings SET person_id = ? WHERE person_id = ?", [.text(targetId), .text(sourceId)])
            try db.run("UPDATE person_photos SET person_id = ? WHERE person_id = ?", [.text(targetId), .text(sourceId)])
            var merged: [String] = []
            for id in [sourceId, targetId] {
                let raw = try db.queryOne("SELECT keywords FROM persons WHERE id = ?", [.text(id)])?
                    .text("keywords") ?? ""
                for keyword in Self.parseKeywords(raw) where !merged.contains(keyword) {
                    merged.append(keyword)
                }
            }
            try db.run(
                "UPDATE persons SET keywords = ?, updated_at = ? WHERE id = ?",
                [.text(Self.jsonString(merged)), .text(nowISOString()), .text(targetId)]
            )
            try db.run("DELETE FROM persons WHERE id = ?", [.text(sourceId)])
        }
    }

    func getPhotosWithDetails(
        personId: String,
        sessionIds: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> (photos: [PersonPhotoDetailRecord], total: Int) {
        var whereClause = "pp.person_id = ?"
        var params: [SQLiteValue] = [.text(personId)]
        if let sessionIds, !sessionIds.isEmpty {
            whereClause += " AND pp.session_id IN (\(sessionIds.map { _ in "?" }.joined(separator: ",")))"
            params.append(contentsOf: sessionIds.map { .text($0) })
        }

        let total = Int(try await database.scalarInt(
            "SELECT COUNT(*) AS count FROM person_photos pp WHERE \(whereClause)",
            params
        ) ?? 0)

        var sql = """
        SELECT pp.*, s.name AS session_name, p.filename, p.filepath
        FROM person_photos pp
        JOIN sessions s ON pp.session_id = s.id
        JOIN photos p ON pp.photo_id = p.id
        WHERE \(whereClause)
        ORDER BY pp.created_at DESC
        """
        var queryValues = params
        if let limit {
            sql += " LIMIT ?"
            queryValues.append(.int(Int64(limit)))
        }
        if let offset {
            sql += " OFFSET ?"
            queryValues.append(.int(Int64(offset)))
        }
        let photos = try await database.query(sql, queryValues).map { try $0.decode(PersonPhotoDetailRecord.self) }
        return (photos, total)
    }

    // MARK: 嵌入

    /// 批量保存嵌入（INSERT OR REPLACE，按 face_observation_id 唯一替换）。
    func saveEmbeddings(_ embeddings: [SaveEmbeddingInput]) async throws {
        guard !embeddings.isEmpty else { return }
        let now = nowISOString()
        try await database.transaction { db in
            for embedding in embeddings {
                try db.run(
                    """
                    INSERT OR REPLACE INTO person_embeddings
                      (person_id, embedding, photo_id, session_id, face_observation_id, face_bbox, quality, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(embedding.personId),
                        .blob(Self.float32Data(embedding.embedding)),
                        .text(embedding.photoId),
                        .text(embedding.sessionId),
                        embedding.faceObservationId.map { SQLiteValue.int($0) } ?? .null,
                        .text(Self.jsonString(embedding.faceBbox)),
                        .real(embedding.quality),
                        .text(now),
                    ]
                )
            }
        }
    }

    func deleteEmbeddingsByObservationIds(_ observationIds: [Int64]) async throws {
        guard !observationIds.isEmpty else { return }
        let placeholders = observationIds.map { _ in "?" }.joined(separator: ",")
        try await database.run(
            "DELETE FROM person_embeddings WHERE face_observation_id IN (\(placeholders))",
            observationIds.map { .int($0) }
        )
    }

    func allEmbeddings() async throws -> [PersonEmbeddingRefRecord] {
        try await database.query("SELECT person_id, embedding, face_observation_id FROM person_embeddings")
            .map {
                PersonEmbeddingRefRecord(
                    personId: $0.text("person_id") ?? "",
                    embedding: $0.blob("embedding") ?? Data(),
                    faceObservationId: $0.int("face_observation_id")
                )
            }
    }

    func embeddings(personId: String) async throws -> [PersonEmbeddingRecord] {
        try await database.query(
            "SELECT * FROM person_embeddings WHERE person_id = ? ORDER BY id",
            [.text(personId)]
        ).map { try $0.decode(PersonEmbeddingRecord.self) }
    }

    func deleteEmbeddings(personId: String) async throws {
        try await database.run("DELETE FROM person_embeddings WHERE person_id = ?", [.text(personId)])
    }

    func countEmbeddings(personId: String) async throws -> Int {
        Int(try await database.scalarInt(
            "SELECT COUNT(*) AS count FROM person_embeddings WHERE person_id = ?",
            [.text(personId)]
        ) ?? 0)
    }

    // MARK: 角色绑定对账

    /// 按会话对账人物↔照片桥接表（角色绑定 → 链接增删）。
    func reconcileSession(sessionId: String) async throws {
        let bindingRows = try await database.query(
            """
            SELECT rb.role_name, fcm.photo_id, fcm.bbox, fcm.confidence
            FROM role_bindings rb
            JOIN face_cluster_members fcm ON fcm.cluster_id = rb.cluster_id
            WHERE rb.session_id = ?
            """,
            [.text(sessionId)]
        )
        var desiredByRole: [String: [String: (bbox: [Double], confidence: Double)]] = [:]
        for row in bindingRows {
            let roleName = row.text("role_name") ?? ""
            let photoId = row.text("photo_id") ?? ""
            let bbox = Self.decodeBbox(row.text("bbox") ?? "")
            let confidence = row.double("confidence") ?? 0
            desiredByRole[roleName, default: [:]][photoId] = (bbox, confidence)
        }

        var affected: Set<String> = []
        for roleName in desiredByRole.keys {
            affected.insert(try await upsertByName(name: roleName, keywords: nil))
        }
        let linkedRows = try await database.query(
            "SELECT DISTINCT person_id FROM person_photos WHERE session_id = ?",
            [.text(sessionId)]
        )
        for row in linkedRows {
            if let personId = row.text("person_id") {
                affected.insert(personId)
            }
        }
        if affected.isEmpty { return }

        let now = nowISOString()
        let desiredSnapshot = desiredByRole
        try await database.transaction { db in
            for personId in affected {
                let roleName = try db.queryOne("SELECT name FROM persons WHERE id = ?", [.text(personId)])?
                    .text("name") ?? ""
                guard let desired = desiredSnapshot[roleName], !desired.isEmpty else {
                    try db.run(
                        "DELETE FROM person_photos WHERE person_id = ? AND session_id = ?",
                        [.text(personId), .text(sessionId)]
                    )
                    continue
                }
                let existingRows = try db.query(
                    "SELECT photo_id FROM person_photos WHERE person_id = ? AND session_id = ?",
                    [.text(personId), .text(sessionId)]
                )
                for existing in existingRows {
                    if let existingPhotoId = existing.text("photo_id"), desired[existingPhotoId] == nil {
                        try db.run(
                            "DELETE FROM person_photos WHERE person_id = ? AND session_id = ? AND photo_id = ?",
                            [.text(personId), .text(sessionId), .text(existingPhotoId)]
                        )
                    }
                }
                for (photoId, info) in desired {
                    try db.run(
                        """
                        INSERT OR IGNORE INTO person_photos
                          (person_id, photo_id, session_id, face_bbox, confidence, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(personId), .text(photoId), .text(sessionId),
                            .text(Self.jsonString(info.bbox)), .real(info.confidence), .text(now),
                        ]
                    )
                }
            }
        }
    }

    // MARK: 私有辅助

    internal static func decodeBbox(_ raw: String) -> [Double] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Double].self, from: data) else {
            return []
        }
        return decoded
    }

    /// TS: Buffer.from(new Float32Array(embedding).buffer) —— Float32 小端字节序。
    internal static func float32Data(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }
}

// MARK: - 共享 DTO（从 Database/Repositories/PersonRepo.swift 迁入）

/// addPhotos 的单条输入（TS: { photoId, faceBbox, confidence }）。
public struct PersonPhotoInput {
    public let photoId: String
    public let faceBbox: [Double]
    public let confidence: Double

    public init(photoId: String, faceBbox: [Double], confidence: Double) {
        self.photoId = photoId
        self.faceBbox = faceBbox
        self.confidence = confidence
    }
}

/// saveEmbeddings 的单条输入（TS: SaveEmbeddingInput，embedding 为 Float32 数组）。
public struct SaveEmbeddingInput {
    public let personId: String
    public let embedding: [Float]
    public let photoId: String
    public let sessionId: String
    public let faceObservationId: Int64?
    public let faceBbox: [Double]
    public let quality: Double

    public init(personId: String, embedding: [Float], photoId: String, sessionId: String, faceObservationId: Int64?, faceBbox: [Double], quality: Double) {
        self.personId = personId
        self.embedding = embedding
        self.photoId = photoId
        self.sessionId = sessionId
        self.faceObservationId = faceObservationId
        self.faceBbox = faceBbox
        self.quality = quality
    }
}

public struct PersonUpdateFields {
    public let name: String?
    public let keywords: [String]?
    public let notes: String?
    public let matchThreshold: Double?

    public init(name: String? = nil, keywords: [String]? = nil, notes: String? = nil, matchThreshold: Double? = nil) {
        self.name = name
        self.keywords = keywords
        self.notes = notes
        self.matchThreshold = matchThreshold
    }
}
