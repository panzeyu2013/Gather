// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PhotoRepo.swift
// TS 源: desktop/src/main/db/repositories/photo.repo.ts
import Foundation
import GatherProtocol

/// photos 表投影（V1 14 列，无 metadata/result）。
public struct PhotoRow: Equatable, Sendable {
    /// SELECT 与位置解码共用的唯一列清单；顺序 = SchemaCurrent photos 的物理列序。
    /// 旧库仍有 metadata/result，但 SELECT 不再选它们（Cut 2 S5a / R1-B）。
    public static let columns = [
        "id", "session_id", "filepath", "filename", "checksum", "checksum_file_size",
        "checksum_file_mtime_ms", "status", "asset_id", "asset_file_id", "width", "height",
        "created_at", "updated_at",
    ]
    // 列序: id(0), session_id(1), filepath(2), filename(3), checksum(4),
    // checksum_file_size(5), checksum_file_mtime_ms(6), status(7), asset_id(8),
    // asset_file_id(9), width(10), height(11), created_at(12), updated_at(13)
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let checksumFileSize: Int
    public let checksumFileMtimeMs: Double
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String

    init(row: DBRow) throws {
        guard row.count >= 14 else { throw DBError.message("PhotoRow 列数不足: \(row.count)") }
        id = row[0].textValue ?? ""
        sessionId = row[1].textValue ?? ""
        filepath = row[2].textValue ?? ""
        filename = row[3].textValue ?? ""
        checksum = row[4].textValue ?? ""
        checksumFileSize = Int(row[5].intValue ?? 0)
        checksumFileMtimeMs = row[6].doubleValue ?? 0
        status = row[7].textValue ?? ""
        assetId = row[8].textValue
        assetFileId = row[9].textValue
        width = Int(row[10].intValue ?? 0)
        height = Int(row[11].intValue ?? 0)
        createdAt = row[12].textValue ?? ""
        updatedAt = row[13].textValue ?? ""
    }
}

/// 轻投影：除 metadata/result 外的全部列（TS: PhotoProjectionRow）。
public struct PhotoProjectionRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let checksumFileSize: Int
    public let checksumFileMtimeMs: Double
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String

    // SELECT 列序: id(0), session_id(1), filepath(2), filename(3), checksum(4),
    // checksum_file_size(5), checksum_file_mtime_ms(6), status(7), asset_id(8),
    // asset_file_id(9), width(10), height(11), created_at(12), updated_at(13)
    init(row: DBRow) throws {
        guard row.count >= 14 else { throw DBError.message("PhotoProjectionRow 列数不足: \(row.count)") }
        id = row[0].textValue ?? ""
        sessionId = row[1].textValue ?? ""
        filepath = row[2].textValue ?? ""
        filename = row[3].textValue ?? ""
        checksum = row[4].textValue ?? ""
        checksumFileSize = Int(row[5].intValue ?? 0)
        checksumFileMtimeMs = row[6].doubleValue ?? 0
        status = row[7].textValue ?? ""
        assetId = row[8].textValue
        assetFileId = row[9].textValue
        width = Int(row[10].intValue ?? 0)
        height = Int(row[11].intValue ?? 0)
        createdAt = row[12].textValue ?? ""
        updatedAt = row[13].textValue ?? ""
    }
}

/// 分页轻投影（TS: PhotoPageRow）。PHOTO_PAGE_COLUMNS 恒为 13 列（V1 交集列）；
/// 旧 TS 的行形状还带 metadata/result/checksum 尾部可选列，V1 不再读它们
/// （Cut 2 S5b / R1-01）：行映射只认这 13 列，尾部多出的列不参与解码。
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

    // PHOTO_PAGE_COLUMNS 列序: rowid(0), id(1), session_id(2), filepath(3),
    // filename(4), status(5), asset_id(6), asset_file_id(7), width(8),
    // height(9), checksum(10), created_at(11), updated_at(12)
    public init(row: DBRow) throws {
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
    }
}

public struct PhotoAddInput {
    public let filepath: String
    public let width: Int
    public let height: Int

    public init(filepath: String, width: Int, height: Int) {
        self.filepath = filepath
        self.width = width
        self.height = height
    }
}

public struct PhotoAddResult: Equatable, Sendable {
    public let added: Int
    public let skipped: Int
    public let ids: [String]
}

public final class PhotoRepo {
    /// TS: PHOTO_PAGE_COLUMNS（键集分页查询与 service 侧共享的列清单，需 p 别名）。
    public static let photoPageColumns = """
    p.rowid, p.id, p.session_id, p.filepath, p.filename, p.status,
      p.asset_id, p.asset_file_id, p.width, p.height, p.checksum, p.created_at, p.updated_at
    """

    /// TS: RAW_EXTENSIONS —— 原始格式扩展名列表（RAW+JPEG 配对时优先变体）。
    /// 唯一真相源是 PhotoFileTypes.rawExtensions（Cut 3a / E-01 上移到 Protocol；
    /// 此处仅排序别名：SQL 文本稳定，便于语句缓存；不再本地维护字面量清单）。
    public static let rawExtensions: [String] = PhotoFileTypes.sortedRawExtensions

    /// TS: RAW_EXTENSION_LIKE_SQL —— 由 RAW_EXTENSIONS 推导的 SQL 片段
    /// （`(LOWER(p2.filename) LIKE '%.nef' OR ...)`，需 p2 表别名）。
    /// RAW 变体判定（按文件名扩展名）的**唯一**定义，别名可换。
    /// 整个 OR 链外包一层括号：嵌入 AND/OR 复合表达式时优先级才正确
    /// （CASE WHEN / ORDER BY 单表达式位置本可省略，收敛为一种安全形态）。
    public static func rawVariantSQL(alias: String) -> String {
        let clauses = rawExtensions
            .map { "LOWER(\(alias).filename) LIKE '%\($0)'" }
            .joined(separator: " OR ")
        return "(\(clauses))"
    }

    /// 资产组代表行的**唯一**排序规则：RAW 变体优先，其次最小 rowid
    /// （rowid = 导入顺序 ⇒ 展示顺序稳定）。
    ///
    /// 必须全仓共用：图库全局查询（FilterEngine.filterGlobally 的
    /// representatives）与挑片分组（CullingService.preferredRowPredicate）若各写
    /// 一份，同一资产在两页会显示成不同的照片（RAW/JPEG 变体各自的缩略图与
    /// 元数据），且筛选计数与页内容会互相矛盾。
    public static func preferredRowOrderSQL(alias: String) -> String {
        "CASE WHEN \(rawVariantSQL(alias: alias)) THEN 1 ELSE 0 END DESC, \(alias).rowid"
    }

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func getBySession(sessionId: String) throws -> [PhotoRow] {
        let columns = PhotoRow.columns.joined(separator: ", ")
        let rows = try connection.prepare(
            "SELECT \(columns) FROM photos WHERE session_id = ? ORDER BY rowid"
        ).query([.text(sessionId)])
        return try rows.map { try PhotoRow(row: $0) }
    }

    public func getBySessionProjection(sessionId: String) throws -> [PhotoProjectionRow] {
        let rows = try connection.prepare(
            "SELECT id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, asset_id, asset_file_id, width, height, created_at, updated_at FROM photos WHERE session_id = ? ORDER BY rowid"
        ).query([.text(sessionId)])
        return try rows.map { try PhotoProjectionRow(row: $0) }
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

    /// 待补校验和照片数（E-5 性能审计）：旧实现在服务层 flatMap 整个会话行
    ///（含 metadata/result 大列）只为得到一个整数，这里下沉为一条 COUNT(*)。
    public func pendingChecksumCount(sessionId: String) throws -> Int {
        let row = try connection.prepare("""
            SELECT COUNT(*) AS count FROM photos
            WHERE session_id = ? AND (checksum IS NULL OR checksum = '') AND status != 'missing'
            """).get([.text(sessionId)])
        return Int(row?[0].intValue ?? 0)
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
        let now = nowISOString()
        var added = 0
        var skipped = 0
        var ids: [String] = []

        // metadata/result 不再写（V1 无此二列；旧 schema 是 NOT NULL DEFAULT '{}'，
        // 省略后由默认值补上，语义与原先显式写 '{}' 完全相同）。Cut 2 S5b / R1-06。
        let insertStmt = try connection.prepare(
            "INSERT OR IGNORE INTO photos (id, session_id, filepath, filename, checksum, status, width, height, created_at, updated_at) VALUES (?, ?, ?, ?, '', 'pending', ?, ?, ?, ?)"
        )
        // 去重判据只有 idx_photos_session_filepath（迁移末尾无条件创建：
        // ensurePhotoPathUniqueness 建不出唯一索引就回滚并让迁移失败，故不存在
        // "无该索引" 的库）。命中唯一索引时 INSERT OR IGNORE 的 changes == 0，
        // 由下方 else 分支给出 skipped/"" 语义；旧实现另加一次 SELECT 点查，
        // 等于在约束之外把同一条规则再抄一遍，已删除。
        try connection.transaction {
            for input in filepaths {
                let filename = input.filepath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? input.filepath
                let id = newUUIDString()
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
            .text(nowISOString()),
            .text(photoId),
        ])
    }

    public func updateChecksum(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double) throws {
        _ = try connection.prepare(
            "UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?, updated_at = ? WHERE id = ?"
        ).run([.text(checksum), .int(Int64(fileSize)), .real(fileMtimeMs), .text(nowISOString()), .text(photoId)])
    }

    /// P1 / D：淘汰移动后改写登记路径与文件名（一起改，避免路径与文件名不一致）。
    public func updateFilepath(photoId: String, filepath: String) throws {
        _ = try connection.prepare("""
            UPDATE photos SET filepath = ?, filename = ?, updated_at = ? WHERE id = ?
            """).run([
                .text(filepath),
                .text((filepath as NSString).lastPathComponent),
                .text(nowISOString()),
                .text(photoId),
            ])
    }

    public func markMissing(photoIds: [String]) throws {
        let statement = try connection.prepare("UPDATE photos SET status = 'missing', updated_at = ? WHERE id = ?")
        try connection.transaction {
            let now = nowISOString()
            for id in photoIds {
                _ = try statement.run([.text(now), .text(id)])
            }
        }
    }

    /// WP3b-1（WorkspaceStatus 下沉）：按状态计数（缺省语义同旧内联 SQL）。
    public func countByStatus(sessionId: String, status: String) throws -> Int {
        let row = try connection.prepare("""
            SELECT COUNT(*) AS count FROM photos
            WHERE session_id = ? AND status = ?
          """).get([.text(sessionId), .text(status)])
        return Int(row?[0].intValue ?? 0)
    }

    /// WP3b-1（MetadataService 下沉）：800/块 IN 查询，列序与旧实现一致。
    public func getLookupByIds(_ photoIds: [String]) throws -> [PhotoLookupRow] {
        if photoIds.isEmpty { return [] }
        var photos: [PhotoLookupRow] = []
        for chunkStart in stride(from: 0, to: photoIds.count, by: 800) {
            let chunk = Array(photoIds[chunkStart..<min(chunkStart + 800, photoIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT id, session_id, filepath FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            photos.append(contentsOf: rows.map {
                PhotoLookupRow(
                    id: $0[0].textValue ?? "",
                    sessionId: $0[1].textValue ?? "",
                    filepath: $0[2].textValue ?? ""
                )
            })
        }
        return photos
    }

    /// WP3b-1（ExportService.session_summary 下沉）：旧查询列序逐字保留。
    public func reportRows(sessionId: String) throws -> [PhotoReportRow] {
        let rows = try connection.prepare(
            "SELECT filename, filepath, status FROM photos WHERE session_id = ? ORDER BY rowid"
        ).query([.text(sessionId)])
        return rows.map {
            PhotoReportRow(
                filename: $0[0].textValue ?? "",
                filepath: $0[1].textValue ?? "",
                status: $0[2].textValue ?? ""
            )
        }
    }
}

