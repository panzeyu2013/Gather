// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/MetadataCacheRepo.swift
// TS 源: desktop/src/main/db/repositories/metadata-cache.repo.ts
import Foundation
import GatherProtocol

/// photo_metadata_cache 表行（列序 = TableColumns.photoMetadataCache，见 Schema.swift）。
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
    /// P1 / IPTC：描述性元数据 JSON（DescriptiveMetadata 的编码）。
    public let iptcJSON: String

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
        iptcJSON = row[22].textValue ?? "{}"
    }

    public var keywords: [String] {
        ((try? JSONValue.parse(keywordsJSON)) as JSONValue?)?.arrayValue ?? []
    }

    /// P1 / IPTC：解析描述性元数据；损坏/空视为"未设置"而非抛错。
    public var descriptive: DescriptiveMetadata {
        guard let value = try? JSONValue.parse(iptcJSON),
              let decoded = try? value.decode(DescriptiveMetadata.self) else {
            return DescriptiveMetadata()
        }
        return decoded
    }
}

/// TS MetadataCacheInput。
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
    /// P1 / IPTC：描述性元数据；nil 表示本次不更新（沿用现有 JSON）。
    public var descriptive: DescriptiveMetadata?

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
        keywords: [String]? = nil,
        descriptive: DescriptiveMetadata? = nil
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
        self.descriptive = descriptive
    }
}

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
              gps_latitude, gps_longitude, width, height, file_size, file_mtime, keywords,
              iptc_json, cached_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
              -- nil 描述性元数据表示"本次不更新"（flag=0）：评分/关键词等局部更新
              -- 不得把已有 IPTC 冲掉；扫描显式传空值时可清空（flag=1）。
              iptc_json = CASE
                WHEN ? = 1 THEN excluded.iptc_json
                ELSE photo_metadata_cache.iptc_json END,
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
            .text(try Self.encodeDescriptive(data.descriptive)),
            .text(now),
            // 与 SQL 中的 CASE ? 对应：只有调用方明确给出 descriptive（含空值 = 清空）
            // 才更新 iptc_json；nil 表示本次不触碰。
            .int(data.descriptive == nil ? 0 : 1),
        ])
    }

    /// 描述性元数据 → JSON 文本；nil 编码为 '{}'（配合同名 CASE WHEN 表达"不更新"）。
    static func encodeDescriptive(_ descriptive: DescriptiveMetadata?) throws -> String {
        guard let descriptive, !descriptive.isEmpty else { return "{}" }
        return try JSONValue.stringify(JSONValue(encoding: descriptive))
    }

    public func get(_ photoId: String) throws -> MetadataCacheRow? {
        // photo_metadata_cache：23 列（TableColumns.photoMetadataCache，列序 = MetadataCacheRow 0-22）
        guard let row = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.photoMetadataCache)) FROM photo_metadata_cache WHERE photo_id = ?")
            .get([.text(photoId)]) else { return nil }
        return MetadataCacheRow(row: row)
    }

    public func getBatch(_ photoIds: [String]) throws -> [MetadataCacheRow] {
        if photoIds.isEmpty { return [] }
        var result: [MetadataCacheRow] = []
        // Stay below SQLite's parameter limit while allowing large sessions.
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            // photo_metadata_cache：22 列（TableColumns.photoMetadataCache）
            let rows = try connection.prepare(
                "SELECT \(TableColumns.sql(TableColumns.photoMetadataCache)) FROM photo_metadata_cache WHERE photo_id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            result.append(contentsOf: rows.map { MetadataCacheRow(row: $0) })
        }
        return result
    }

    public func deleteBySession(_ sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM photo_metadata_cache WHERE session_id = ?").run([.text(sessionId)])
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

    /// P1 / IPTC：描述性元数据写盘后的本地投影刷新（读回值 → 缓存）。
    /// 显式覆盖：空 DescriptiveMetadata 表示盘上已无这些字段。
    public func updateDescriptive(photoId: String, descriptive: DescriptiveMetadata) throws {
        let now = nowISOString()
        let json = try Self.encodeDescriptive(descriptive)
        _ = try connection.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, keywords, iptc_json, cached_at)
            SELECT id, session_id, 0, '[]', ?, ?
            FROM photos
            WHERE id = ?
            ON CONFLICT(photo_id) DO UPDATE SET
              iptc_json = excluded.iptc_json,
              cached_at = excluded.cached_at
          """).run([.text(json), .text(now), .text(photoId)])
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
