// Store/MetadataStore.swift
// R1：photo_metadata_cache / metadata_keyword_origins 的唯一访问入口
// （取代 Database/Repositories/MetadataCacheRepo.swift + MetadataKeywordOriginRepo.swift）。
import Foundation

/// 元数据缓存写入输入（从旧 MetadataCacheRepo.swift 迁入，字段与默认值不变）。
public struct MetadataCacheInput {
    public var sessionId: String?
    public var dateTaken: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var focalLength: Double?
    public var fNumber: Double?
    public var exposureTime: String?
    public var iso: Int64?
    public var rating: Int64?
    public var label: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var width: Int64?
    public var height: Int64?
    public var fileSize: Int64?
    public var fileMtime: String?
    public var keywords: [String]?

    public init(
        sessionId: String? = nil,
        dateTaken: String? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        fNumber: Double? = nil,
        exposureTime: String? = nil,
        iso: Int64? = nil,
        rating: Int64? = nil,
        label: String? = nil,
        gpsLatitude: Double? = nil,
        gpsLongitude: Double? = nil,
        width: Int64? = nil,
        height: Int64? = nil,
        fileSize: Int64? = nil,
        fileMtime: String? = nil,
        keywords: [String]? = nil
    ) {
        self.sessionId = sessionId
        self.dateTaken = dateTaken
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.iso = iso
        self.rating = rating
        self.label = label
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.keywords = keywords
    }
}

public struct MetadataCacheRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let photoId: String
    public let sessionId: String
    public let dateTaken: String?
    public let cameraMake: String?
    public let cameraModel: String?
    public let lensModel: String?
    public let focalLength: Double?
    public let fNumber: Double?
    public let exposureTime: String?
    public let iso: Int64?
    public let rating: Int64
    public let label: String?
    public let gpsLatitude: Double?
    public let gpsLongitude: Double?
    public let width: Int64?
    public let height: Int64?
    public let fileSize: Int64?
    public let fileMtime: String?
    public let keywordsJSON: String
    public let cachedAt: String
    public let updatedAt: String

    /// 键 word（TS JSON.parse 语义：非法 JSON → 空数组）。
    public var keywords: [String] {
        ((try? JSONValue.parse(keywordsJSON)) as JSONValue?)?.arrayValue ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, label, rating, iso, width, height
        case photoId = "photo_id"
        case sessionId = "session_id"
        case dateTaken = "date_taken"
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case lensModel = "lens_model"
        case focalLength = "focal_length"
        case fNumber = "f_number"
        case exposureTime = "exposure_time"
        case gpsLatitude = "gps_latitude"
        case gpsLongitude = "gps_longitude"
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
        case keywordsJSON = "keywords"
        case cachedAt = "cached_at"
        case updatedAt = "updated_at"
    }
}

public protocol MetadataStore: Sendable {
    // MARK: photo_metadata_cache

    func upsertMetadata(photoId: String, sessionId: String, data: MetadataCacheInput) async throws
    func upsertMetadataBatch(_ entries: [(photoId: String, sessionId: String, data: MetadataCacheInput)]) async throws
    func metadata(photoId: String) async throws -> MetadataCacheRecord?
    func metadataBatch(photoIds: [String]) async throws -> [MetadataCacheRecord]
    func deleteMetadataBySession(_ sessionId: String) async throws
    func deleteMetadataByPhotoId(_ photoId: String) async throws
    func updateRating(photoId: String, rating: Int64) async throws
    func updateLabel(photoId: String, label: String) async throws
    func updateKeywords(photoId: String, keywords: [String]) async throws

    // MARK: metadata_keyword_origins

    func markKeywordIntroduced(xmpPath: String, source: String, keywords: [String]) async throws
    func activeIntroducedKeywords(xmpPath: String, source: String, keywords: [String]) async throws -> [String]
    func deactivateKeywordOrigins(xmpPath: String, source: String, keywords: [String]) async throws
}

public struct SQLiteMetadataStore: MetadataStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: cache

    public func upsertMetadata(photoId: String, sessionId: String, data: MetadataCacheInput) async throws {
        let keywordsJSON = try JSONValue.stringify(
            JSONValue.array((data.keywords ?? []).map { JSONValue.string($0) })
        )
        try await database.run(
            """
            INSERT INTO photo_metadata_cache
             (photo_id, session_id, date_taken, camera_make, camera_model, lens_model,
              focal_length, f_number, exposure_time, iso, rating, label,
              gps_latitude, gps_longitude, width, height, file_size, file_mtime, keywords, cached_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(photo_id) DO UPDATE SET
              session_id = excluded.session_id,
              date_taken = excluded.date_taken,
              camera_make = excluded.camera_make,
              camera_model = excluded.camera_model,
              lens_model = excluded.lens_model,
              focal_length = excluded.focal_length,
              f_number = excluded.f_number,
              exposure_time = excluded.exposure_time,
              iso = excluded.iso,
              rating = excluded.rating,
              label = excluded.label,
              gps_latitude = excluded.gps_latitude,
              gps_longitude = excluded.gps_longitude,
              width = excluded.width,
              height = excluded.height,
              file_size = excluded.file_size,
              file_mtime = excluded.file_mtime,
              keywords = excluded.keywords,
              cached_at = excluded.cached_at
            """,
            [
                .text(photoId),
                .text(data.sessionId ?? sessionId),
                sqlValue(data.dateTaken),
                sqlValue(data.cameraMake),
                sqlValue(data.cameraModel),
                sqlValue(data.lensModel),
                sqlValue(data.focalLength),
                sqlValue(data.fNumber),
                sqlValue(data.exposureTime),
                sqlValue(data.iso),
                .int(data.rating ?? 0),
                sqlValue(data.label),
                sqlValue(data.gpsLatitude),
                sqlValue(data.gpsLongitude),
                sqlValue(data.width),
                sqlValue(data.height),
                sqlValue(data.fileSize),
                sqlValue(data.fileMtime),
                .text(keywordsJSON),
                .text(nowISOString()),
            ]
        )
    }

    public func upsertMetadataBatch(
        _ entries: [(photoId: String, sessionId: String, data: MetadataCacheInput)]
    ) async throws {
        // 逐条 upsert（每条自带语句的事务）；缓存行是派生数据，
        // 批中间失败重跑即可，不要求跨行原子。
        for entry in entries {
            try await upsertMetadata(photoId: entry.photoId, sessionId: entry.sessionId, data: entry.data)
        }
    }

    public func metadata(photoId: String) async throws -> MetadataCacheRecord? {
        try await database.queryOne("SELECT * FROM photo_metadata_cache WHERE photo_id = ?", [.text(photoId)])?
            .decode(MetadataCacheRecord.self)
    }

    public func metadataBatch(photoIds: [String]) async throws -> [MetadataCacheRecord] {
        guard !photoIds.isEmpty else { return [] }
        var result: [MetadataCacheRecord] = []
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                "SELECT * FROM photo_metadata_cache WHERE photo_id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
            result.append(contentsOf: try rows.map { try $0.decode(MetadataCacheRecord.self) })
        }
        return result
    }

    public func deleteMetadataBySession(_ sessionId: String) async throws {
        try await database.run("DELETE FROM photo_metadata_cache WHERE session_id = ?", [.text(sessionId)])
    }

    public func deleteMetadataByPhotoId(_ photoId: String) async throws {
        try await database.run("DELETE FROM photo_metadata_cache WHERE photo_id = ?", [.text(photoId)])
    }

    public func updateRating(photoId: String, rating: Int64) async throws {
        try await database.run(
            """
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, keywords, cached_at)
            SELECT id, session_id, ?, '[]', ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              rating = excluded.rating,
              cached_at = excluded.cached_at
            """,
            [.int(rating), .text(nowISOString()), .text(photoId)]
        )
    }

    public func updateLabel(photoId: String, label: String) async throws {
        try await database.run(
            """
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, label, keywords, cached_at)
            SELECT id, session_id, 0, ?, '[]', ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              label = excluded.label,
              cached_at = excluded.cached_at
            """,
            [.text(label), .text(nowISOString()), .text(photoId)]
        )
    }

    public func updateKeywords(photoId: String, keywords: [String]) async throws {
        let keywordsJSON = try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))
        try await database.run(
            """
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, keywords, cached_at)
            SELECT id, session_id, 0, ?, ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              keywords = excluded.keywords,
              cached_at = excluded.cached_at
            """,
            [.text(keywordsJSON), .text(nowISOString()), .text(photoId)]
        )
    }

    // MARK: keyword origins

    public func markKeywordIntroduced(xmpPath: String, source: String, keywords: [String]) async throws {
        guard !keywords.isEmpty else { return }
        let timestamp = nowISOString()
        // TS new Set(keywords)：去重且保留首次出现顺序。
        var seen = Set<String>()
        let unique = keywords.filter { seen.insert($0).inserted }
        try await database.transaction { db in
            for keyword in unique {
                try db.run(
                    """
                    INSERT INTO metadata_keyword_origins (
                      xmp_path, source, keyword, active, created_at, updated_at
                    ) VALUES (?, ?, ?, 1, ?, ?)
                    ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
                      active = 1, updated_at = excluded.updated_at
                    """,
                    [.text(xmpPath), .text(source), .text(keyword), .text(timestamp), .text(timestamp)]
                )
            }
        }
    }

    public func activeIntroducedKeywords(xmpPath: String, source: String, keywords: [String]) async throws -> [String] {
        guard !keywords.isEmpty else { return [] }
        let placeholders = keywords.map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query(
            """
            SELECT keyword FROM metadata_keyword_origins
            WHERE xmp_path = ? AND source = ? AND active = 1
              AND keyword IN (\(placeholders))
            """,
            [.text(xmpPath), .text(source)] + keywords.map { .text($0) }
        )
        return rows.compactMap { $0.text("keyword") }
    }

    public func deactivateKeywordOrigins(xmpPath: String, source: String, keywords: [String]) async throws {
        guard !keywords.isEmpty else { return }
        let placeholders = keywords.map { _ in "?" }.joined(separator: ", ")
        try await database.run(
            """
            UPDATE metadata_keyword_origins
            SET active = 0, updated_at = ?
            WHERE xmp_path = ? AND source = ?
              AND keyword IN (\(placeholders))
            """,
            [.text(nowISOString()), .text(xmpPath), .text(source)] + keywords.map { .text($0) }
        )
    }
}
