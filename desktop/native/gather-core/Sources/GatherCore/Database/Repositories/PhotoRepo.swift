// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/PhotoRepo.swift
// TS 源: desktop/src/main/db/repositories/photo.repo.ts
import Foundation

/// photos 表全行（含重 JSON 列 metadata/result）。
public struct PhotoRow: Equatable, Sendable {
    // 表列序: id(0), session_id(1), filepath(2), filename(3), checksum(4),
    // checksum_file_size(5), checksum_file_mtime_ms(6), status(7), metadata(8),
    // result(9), asset_id(10), asset_file_id(11), width(12), height(13),
    // created_at(14), updated_at(15)
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let checksumFileSize: Int
    public let checksumFileMtimeMs: Double
    public let status: String
    public let metadata: String
    public let result: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String

    init(row: DBRow) throws {
        guard row.count >= 16 else { throw DBError.message("PhotoRow 列数不足: \(row.count)") }
        id = row[0].textValue ?? ""
        sessionId = row[1].textValue ?? ""
        filepath = row[2].textValue ?? ""
        filename = row[3].textValue ?? ""
        checksum = row[4].textValue ?? ""
        checksumFileSize = Int(row[5].intValue ?? 0)
        checksumFileMtimeMs = row[6].doubleValue ?? 0
        status = row[7].textValue ?? ""
        metadata = row[8].textValue ?? ""
        result = row[9].textValue ?? ""
        assetId = row[10].textValue
        assetFileId = row[11].textValue
        width = Int(row[12].intValue ?? 0)
        height = Int(row[13].intValue ?? 0)
        createdAt = row[14].textValue ?? ""
        updatedAt = row[15].textValue ?? ""
    }
}

/// 轻投影：除 metadata/result 外的全部列（TS: PhotoProjection）。

/// 分页轻投影（TS: PhotoPageRow）。PHOTO_PAGE_COLUMNS 只含 13 列；
/// metadata/result/checksum_file_size/checksum_file_mtime_ms 为可选尾部列，
/// 本 repo 的查询不选中时恒为 nil。
public struct PhotoPageRow: Equatable, Sendable {
    public let rowid: Int64
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let checksum: String?
    public let createdAt: String
    public let updatedAt: String
    public let metadata: String?
    public let result: String?
    public let checksumFileSize: Int?
    public let checksumFileMtimeMs: Double?

    // PHOTO_PAGE_COLUMNS 列序: rowid(0), id(1), session_id(2), filepath(3),
    // filename(4), status(5), asset_id(6), asset_file_id(7), width(8),
    // height(9), checksum(10), created_at(11), updated_at(12)
    init(row: DBRow) throws {
        guard row.count >= 13 else { throw DBError.message("PhotoPageRow 列数不足: \(row.count)") }
        rowid = row[0].intValue ?? 0
        id = row[1].textValue ?? ""
        sessionId = row[2].textValue ?? ""
        filepath = row[3].textValue ?? ""
        filename = row[4].textValue ?? ""
        status = row[5].textValue ?? ""
        assetId = row[6].textValue
        assetFileId = row[7].textValue
        width = Int(row[8].intValue ?? 0)
        height = Int(row[9].intValue ?? 0)
        checksum = row[10].textValue
        createdAt = row[11].textValue ?? ""
        updatedAt = row[12].textValue ?? ""
        metadata = row.count > 13 ? row[13].textValue : nil
        result = row.count > 14 ? row[14].textValue : nil
        checksumFileSize = row.count > 15 ? Int(row[15].intValue ?? 0) : nil
        checksumFileMtimeMs = row.count > 16 ? row[16].doubleValue : nil
    }
}

// PhotoAddInput / PhotoAddResult 已迁至 Store/PhotoStore.swift（R1 单一来源）。

public final class PhotoRepo {
    /// 以下三个常量已迁至 Store/PhotoFormats.swift（R1 单一来源），此处仅转调，
    /// R1 收尾删除本文件后由 PhotoFormats 独占。
    public static var photoPageColumns: String { PhotoFormats.pageColumns }
    public static var rawExtensions: [String] { PhotoFormats.rawExtensions }
    public static var rawExtensionLikeSQL: String { PhotoFormats.rawExtensionLikeSQL }

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func getBySession(sessionId: String) throws -> [PhotoRow] {
        let rows = try connection.prepare("SELECT * FROM photos WHERE session_id = ? ORDER BY rowid")
            .query([.text(sessionId)])
        return try rows.map { try PhotoRow(row: $0) }
    }

    public func getBySessionProjection(sessionId: String) throws -> [PhotoProjection] {
        let rows = try connection.prepare(
            "SELECT id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, asset_id, asset_file_id, width, height, created_at, updated_at FROM photos WHERE session_id = ? ORDER BY rowid"
        ).query([.text(sessionId)])
        // 旧连接行 → Store 投影（两类型 14 字段一一对应，键集分页改造后可互换）。
        return rows.map { row in
            func text(_ i: Int) -> String? {
                if case .text(let v) = row[i] { return v }
                return nil
            }
            func int(_ i: Int) -> Int64? {
                if case .int(let v) = row[i] { return v }
                return nil
            }
            func real(_ i: Int) -> Double? {
                if case .real(let v) = row[i] { return v }
                return nil
            }
            return PhotoProjection(
                id: text(0) ?? "", sessionId: text(1) ?? "", filepath: text(2) ?? "",
                filename: text(3) ?? "", checksum: text(4) ?? "",
                checksumFileSize: Int(int(5) ?? 0), checksumFileMtimeMs: real(6) ?? 0,
                status: text(7) ?? "", assetId: text(8), assetFileId: text(9),
                width: Int(int(10) ?? 0), height: Int(int(11) ?? 0),
                createdAt: text(12) ?? "", updatedAt: text(13) ?? ""
            )
        }
    }

    public func getBySessionPage(sessionId: String, afterRowId: Int64? = nil, limit: Int = 200) throws -> [PhotoPageRow] {
        let rows: [DBRow]
        if let afterRowId {
            rows = try connection.prepare(
                "SELECT \(Self.photoPageColumns) FROM photos p WHERE p.session_id = ? AND p.rowid > ? ORDER BY p.rowid LIMIT ?"
            ).query([.text(sessionId), .int(afterRowId), .int(Int64(limit))])
        } else {
            rows = try connection.prepare(
                "SELECT \(Self.photoPageColumns) FROM photos p WHERE p.session_id = ? ORDER BY p.rowid LIMIT ?"
            ).query([.text(sessionId), .int(Int64(limit))])
        }
        return try rows.map { try PhotoPageRow(row: $0) }
    }

    public func countBySession(sessionId: String) throws -> Int {
        let row = try connection.prepare("SELECT COUNT(*) as count FROM photos WHERE session_id = ?")
            .get([.text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    /// 按逻辑资产分组的分页（RAW/JPEG 变体同页），返回每页行 + 游标。
    /// 审计 P1-性能：原 GROUP BY COALESCE(asset_id,id) 无索引可走（SQLite
    /// 表达式索引禁止引用 rowid）→ 改两分支 UNION：有 asset_id 的照片按
    /// asset_id 分组（走 idx_photos_asset_group 覆盖索引），无 asset_id 的
    /// 照片每行自成一组。语义与 COALESCE 分组等价。
    public func getAssetPage(sessionId: String, afterFirstRowid: Int64? = nil, limit: Int = 200) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        let groups = try connection.prepare(
            """
            SELECT gid, MIN(first_rowid) AS first_rowid FROM (
              SELECT asset_id AS gid, MIN(rowid) AS first_rowid
                FROM photos WHERE session_id = ? AND asset_id IS NOT NULL
                GROUP BY asset_id
              UNION ALL
              SELECT id AS gid, rowid AS first_rowid
                FROM photos WHERE session_id = ? AND asset_id IS NULL
            )
            GROUP BY gid
            HAVING MIN(first_rowid) > ?
            ORDER BY MIN(first_rowid)
            LIMIT ?
            """
        ).query([.text(sessionId), .text(sessionId), .int(afterFirstRowid ?? 0), .int(Int64(limit))])
        if groups.isEmpty {
            return ([], nil)
        }
        let gids = groups.map { row in (gid: row[0].textValue ?? "", firstRowid: row[1].intValue ?? 0) }
        var rows: [PhotoPageRow] = []
        for chunkStart in stride(from: 0, to: gids.count, by: 800) {
            let chunk = gids[chunkStart..<min(chunkStart + 800, gids.count)].map { $0.gid }
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let chunkRows = try connection.prepare(
                "SELECT \(Self.photoPageColumns) FROM photos p WHERE p.session_id = ? AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (\(placeholders)) ORDER BY p.rowid"
            ).query([.text(sessionId)] + chunk.map { .text($0) })
            rows.append(contentsOf: try chunkRows.map { try PhotoPageRow(row: $0) })
        }
        return (rows, gids[gids.count - 1].firstRowid)
    }

    public func countAssetsBySession(sessionId: String) throws -> Int {
        let row = try connection.prepare(
            "SELECT COUNT(*) AS count FROM (SELECT COALESCE(NULLIF(asset_id, ''), id) AS gid FROM photos WHERE session_id = ? GROUP BY gid)"
        ).get([.text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func containsFilepath(filepath: String) throws -> Bool {
        try connection.prepare("SELECT 1 FROM photos WHERE filepath = ? LIMIT 1").get([.text(filepath)]) != nil
    }

    /// 批量添加照片；返回 added/skipped 计数与逐路径 id（重复路径为 ""）。
    public func addPhotos(sessionId: String, filepaths: [PhotoAddInput], _ source: String) throws -> PhotoAddResult {
        let now = nowISO()
        var added = 0
        var skipped = 0
        var ids: [String] = []

        let insertStmt = try connection.prepare(
            "INSERT OR IGNORE INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, width, height, created_at, updated_at) VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?, ?, ?)"
        )
        let existsStmt = try connection.prepare("SELECT 1 FROM photos WHERE session_id = ? AND filepath = ? LIMIT 1")

        try connection.transaction {
            for input in filepaths {
                if try existsStmt.get([.text(sessionId), .text(input.filepath)]) != nil {
                    skipped += 1
                    ids.append("")
                    continue
                }
                let filename = input.filepath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? input.filepath
                let id = newUUID()
                let changes = try insertStmt.run([
                    .text(id), .text(sessionId), .text(input.filepath), .text(filename),
                    .int(Int64(input.width)), .int(Int64(input.height)), .text(now), .text(now),
                ])
                if changes > 0 {
                    added += 1
                    ids.append(id)
                } else {
                    skipped += 1
                    ids.append("")
                }
            }
        }
        return PhotoAddResult(added: added, skipped: skipped, ids: ids)
    }

    public func deleteBySession(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM photos WHERE session_id = ?").run([.text(sessionId)])
    }

    public func updateIndexedFile(photoId: String, width: Int, height: Int, changed: Bool) throws {
        _ = try connection.prepare(
            "UPDATE photos SET width = ?, height = ?, status = 'pending', checksum = CASE WHEN ? THEN '' ELSE checksum END, checksum_file_size = CASE WHEN ? THEN 0 ELSE checksum_file_size END, checksum_file_mtime_ms = CASE WHEN ? THEN 0 ELSE checksum_file_mtime_ms END, updated_at = ? WHERE id = ?"
        ).run([
            .int(Int64(width)),
            .int(Int64(height)),
            .int(changed ? 1 : 0),
            .int(changed ? 1 : 0),
            .int(changed ? 1 : 0),
            .text(nowISO()),
            .text(photoId),
        ])
    }

    public func updateChecksum(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double) throws {
        _ = try connection.prepare(
            "UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?, updated_at = ? WHERE id = ?"
        ).run([.text(checksum), .int(Int64(fileSize)), .real(fileMtimeMs), .text(nowISO()), .text(photoId)])
    }

    public func markMissing(photoIds: [String]) throws {
        let statement = try connection.prepare("UPDATE photos SET status = 'missing', updated_at = ? WHERE id = ?")
        try connection.transaction {
            let now = nowISO()
            for id in photoIds {
                _ = try statement.run([.text(now), .text(id)])
            }
        }
    }
}

private func newUUID() -> String {
    UUID().uuidString.lowercased()
}

private func nowISO() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
