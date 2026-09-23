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
    func removePhoto(personId: String, photoId: String) async throws
    func countPhotos(personId: String) async throws -> Int
    func sessionCount(personId: String) async throws -> Int
    func thumbnailBase64(personId: String) async throws -> String
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
