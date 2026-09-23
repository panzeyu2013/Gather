// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/MetadataCacheRepo.swift
// TS 源: desktop/src/main/db/repositories/metadata-cache.repo.ts
import Foundation

/// photo_metadata_cache 表行（列序与 SELECT * 一致，见 Schema.swift）。
public struct MetadataCacheRow {
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

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        photoId = row[1].textValue ?? ""
        sessionId = row[2].textValue ?? ""
        dateTaken = row[3].textValue
        cameraMake = row[4].textValue
        cameraModel = row[5].textValue
        lensModel = row[6].textValue
        focalLength = row[7].doubleValue
        fNumber = row[8].doubleValue
        exposureTime = row[9].textValue
        iso = row[10].intValue
        rating = row[11].intValue ?? 0
        label = row[12].textValue
        gpsLatitude = row[13].doubleValue
        gpsLongitude = row[14].doubleValue
        width = row[15].intValue
        height = row[16].intValue
        fileSize = row[17].intValue
        fileMtime = row[18].textValue
        keywordsJSON = row[19].textValue ?? "[]"
        cachedAt = row[20].textValue ?? ""
        updatedAt = row[21].textValue ?? ""
    }

    public var keywords: [String] {
        ((try? JSONValue.parse(keywordsJSON)) as JSONValue?)?.arrayValue ?? []
    }
}

// MetadataCacheInput 已迁至 Store/MetadataStore.swift（R1 单一来源）。

/// photo_metadata_cache 仓库（TS MetadataCacheRepository）。
public final class MetadataCacheRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func upsert(photoId: String, sessionId: String, data: MetadataCacheInput) throws {
        let now = nowISOString()
        _ = try connection.prepare("""
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
          """).run([
            .text(photoId),
            .text(data.sessionId ?? sessionId),
            optDB(data.dateTaken),
            optDB(data.cameraMake),
            optDB(data.cameraModel),
            optDB(data.lensModel),
            optDB(data.focalLength),
            optDB(data.fNumber),
            optDB(data.exposureTime),
            optDB(data.iso),
            .int(data.rating ?? 0),
            optDB(data.label),
            optDB(data.gpsLatitude),
            optDB(data.gpsLongitude),
            optDB(data.width),
            optDB(data.height),
            optDB(data.fileSize),
            optDB(data.fileMtime),
            .text(try JSONValue.stringify(JSONValue.array((data.keywords ?? []).map { JSONValue.string($0) }))),
            .text(now),
        ])
    }

    public func get(_ photoId: String) throws -> MetadataCacheRow? {
        guard let row = try connection.prepare("SELECT * FROM photo_metadata_cache WHERE photo_id = ?")
            .get([.text(photoId)]) else { return nil }
        return MetadataCacheRow(row: row)
    }

    public func getBatch(_ photoIds: [String]) throws -> [MetadataCacheRow] {
        if photoIds.isEmpty { return [] }
        var result: [MetadataCacheRow] = []
        // Stay below SQLite's parameter limit while allowing large sessions.
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT * FROM photo_metadata_cache WHERE photo_id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            result.append(contentsOf: rows.map { MetadataCacheRow(row: $0) })
        }
        return result
    }

    public func deleteBySession(_ sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM photo_metadata_cache WHERE session_id = ?").run([.text(sessionId)])
    }

    public func deleteByPhotoId(_ photoId: String) throws {
        _ = try connection.prepare("DELETE FROM photo_metadata_cache WHERE photo_id = ?").run([.text(photoId)])
    }

    public func updateRating(photoId: String, rating: Int64) throws {
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, keywords, cached_at)
            SELECT id, session_id, ?, '[]', ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              rating = excluded.rating,
              cached_at = excluded.cached_at
          """).run([.int(rating), .text(now), .text(photoId)])
    }

    public func updateLabel(photoId: String, label: String) throws {
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, label, keywords, cached_at)
            SELECT id, session_id, 0, ?, '[]', ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              label = excluded.label,
              cached_at = excluded.cached_at
          """).run([.text(label), .text(now), .text(photoId)])
    }

    public func updateKeywords(photoId: String, keywords: [String]) throws {
        let now = nowISOString()
        let keywordsJSON = try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))
        _ = try connection.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, keywords, cached_at)
            SELECT id, session_id, 0, ?, ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              keywords = excluded.keywords,
              cached_at = excluded.cached_at
          """).run([.text(keywordsJSON), .text(now), .text(photoId)])
    }
}
