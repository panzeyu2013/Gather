// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/IndexerRepo.swift
// WP3b-2：索引扫描的写路径与派生失效 SQL 下沉（原 IndexerService 内联 SQL）。
//
// 这些语句有跨表顺序语义（person_photos → photos、asset_files → assets、
// photos 与 asset_files 双写），所以收在一个仓储里而不是散到多个 Repo；
// 事务边界仍由调用方通过 TransactionRunner 提供（SAVEPOINT 语义不变）。
import Foundation

/// asset_files JOIN photos 的文件状态快照（扫描的 unchanged/updated 判定输入）。
public struct AssetFileStatRow: Equatable, Sendable {
    public let id: String
    public let fileSize: Int64
    public let fileMtimeMs: Double
    public let checksum: String

    public init(id: String, fileSize: Int64, fileMtimeMs: Double, checksum: String) {
        self.id = id
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
        self.checksum = checksum
    }
}

/// 自动导航组行（剪枝的候选投影）。
public struct AutomaticNavigationGroupRow: Equatable, Sendable {
    public let id: String
    public let photoIdsJSON: String

    public init(id: String, photoIdsJSON: String) {
        self.id = id
        self.photoIdsJSON = photoIdsJSON
    }
}

public final class IndexerRepo {
    /// 生成缓存清扫/失效删除的 IN 分块（与旧 IndexerService.chunk 同口径）。
    static let chunkSize = 400

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 生成缓存清扫（单事务内）

    /// 删缓存照片前的身份桥接解除（person_photos 是 ON DELETE RESTRICT）。
    public func deletePersonPhotoBindings(photoIds: [String]) throws {
        for chunk in photoIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            _ = try connection.prepare(
                "DELETE FROM person_photos WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
        }
    }

    public func deletePhotos(photoIds: [String]) throws {
        for chunk in photoIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            _ = try connection.prepare("DELETE FROM photos WHERE id IN (\(placeholders))")
                .run(chunk.map { .text($0) })
        }
    }

    /// 删照片后剪掉不再被引用的 session_assets 行。
    public func pruneSessionAssets(sessionId: String) throws {
        _ = try connection.prepare("""
            DELETE FROM session_assets
            WHERE session_id = ? AND NOT EXISTS (
              SELECT 1 FROM photos p
              WHERE p.session_id = session_assets.session_id
                AND p.asset_id = session_assets.asset_id
            )
          """).run([.text(sessionId)])
    }

    /// 删照片后清理孤儿 asset_files / assets。
    public func pruneOrphanAssets(fileIds: [String]) throws {
        guard !fileIds.isEmpty else { return }
        for chunk in fileIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            _ = try connection.prepare("""
                DELETE FROM asset_files
                WHERE id IN (\(placeholders))
                  AND NOT EXISTS (SELECT 1 FROM photos p WHERE p.asset_file_id = asset_files.id)
              """).run(chunk.map { .text($0) })
        }
        _ = try connection.prepare("""
            DELETE FROM assets
            WHERE NOT EXISTS (SELECT 1 FROM asset_members am WHERE am.asset_id = assets.id)
          """).run()
    }

    // MARK: - 扫描写路径

    /// 会话内 asset_files 的文件状态快照（JOIN photos）。
    public func fileStats(sessionId: String) throws -> [AssetFileStatRow] {
        try connection.prepare("""
            SELECT af.id, af.file_size, af.file_mtime_ms, af.checksum
            FROM asset_files af
            JOIN photos p ON p.asset_file_id = af.id
            WHERE p.session_id = ?
          """).query([.text(sessionId)]).map { row in
            AssetFileStatRow(
                id: row[0].textValue ?? "",
                fileSize: row[1].intValue ?? 0,
                fileMtimeMs: row[2].doubleValue ?? 0,
                checksum: row[3].textValue ?? ""
            )
        }
    }

    /// 已存在照片的 asset_files 刷新（内容变化时 checksum 走 CASE 保留旧值）。
    public func updateAssetFile(
        assetFileId: String,
        volumeId: String,
        fileIdentity: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        checksum: String,
        preserveChecksum: Bool,
        timestamp: String
    ) throws {
        _ = try connection.prepare("""
            UPDATE asset_files
            SET volume_id = ?, file_identity = ?, file_size = ?, file_mtime_ms = ?,
                checksum = CASE WHEN ? = 1 THEN checksum ELSE ? END,
                online_status = 'online', last_seen_at = ?, updated_at = ?
            WHERE id = ?
          """).run([
            .text(volumeId), .text(fileIdentity), .int(fileSize), .real(fileMtimeMs),
            .int(preserveChecksum ? 1 : 0), .text(checksum),
            .text(timestamp), .text(timestamp), .text(assetFileId),
          ])
    }

    /// 同一资产文件下的全部照片 id（内容变化时的失效范围）。
    public func photoIds(assetFileId: String) throws -> [String] {
        try connection.prepare(
            "SELECT id FROM photos WHERE asset_file_id = ?"
        ).query([.text(assetFileId)]).compactMap { $0[0].textValue }
    }

    /// 文件级清扫：内容变化后删掉该资产文件下旧的 analysis 行。
    public func deleteAssetAnalysis(assetFileId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM asset_analysis WHERE asset_file_id = ?"
        ).run([.text(assetFileId)])
    }

    /// 内容变化后按资产文件把新的 checksum/尺寸写回其全部照片行。
    public func updatePhotos(
        assetFileId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        width: Int,
        height: Int,
        timestamp: String
    ) throws {
        _ = try connection.prepare("""
            UPDATE photos
            SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                width = ?, height = ?, updated_at = ?
            WHERE asset_file_id = ?
          """).run([
            .text(checksum), .int(fileSize), .real(fileMtimeMs),
            .int(Int64(width)), .int(Int64(height)),
            .text(timestamp), .text(assetFileId),
          ])
    }

    /// missing 照片对应的资产文件置 offline（分块）。
    public func markAssetFilesOffline(fileIds: [String], timestamp: String) throws {
        for chunk in fileIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            _ = try connection.prepare("""
                UPDATE asset_files SET online_status = 'offline', updated_at = ?
                WHERE id IN (\(placeholders))
              """).run([.text(timestamp)] + chunk.map { .text($0) })
        }
    }

    /// checksum 回填：乐观填充 photos（仅当 checksum 仍为空）。返回是否实际写入。
    @discardableResult
    public func backfillPhotoChecksum(
        photoId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        timestamp: String
    ) throws -> Bool {
        let changes = try connection.prepare("""
            UPDATE photos
            SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                updated_at = ?
            WHERE id = ? AND checksum = ''
          """).run([
            .text(checksum), .int(fileSize), .real(fileMtimeMs),
            .text(timestamp), .text(photoId),
          ])
        return changes != 0
    }

    /// checksum 回填的资产行同步（同样只在仍为空时写）。
    public func backfillAssetFileChecksum(
        assetFileId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        timestamp: String
    ) throws {
        _ = try connection.prepare("""
            UPDATE asset_files
            SET checksum = ?, file_size = ?, file_mtime_ms = ?, updated_at = ?
            WHERE id = ? AND checksum = ''
          """).run([
            .text(checksum), .int(fileSize), .real(fileMtimeMs),
            .text(timestamp), .text(assetFileId),
          ])
    }

    // MARK: - 派生失效

    /// 逐照片删除分析输入（相似度 hash、技术质量、元数据缓存）。
    /// 人脸段由 FaceRepo.invalidateDerivedResults 单独负责（顺序敏感）。
    public func deletePhotoInputs(photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        try SimilarityHashRepo(connection: connection).deleteByPhotoIds(photoIds)
        for chunk in photoIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "DELETE FROM asset_analysis WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
            _ = try connection.prepare(
                "DELETE FROM photo_metadata_cache WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
        }
    }

    /// 自动导航组候选：有受影响照片时按 photo_ids_json LIKE 预过滤，否则全量。
    public func automaticNavigationGroups(
        sessionId: String,
        photoIds: [String],
        prefilterCap: Int
    ) throws -> [AutomaticNavigationGroupRow] {
        if !photoIds.isEmpty && photoIds.count <= prefilterCap {
            let conditions = photoIds.map { _ in "photo_ids_json LIKE ? ESCAPE '\\'" }
                .joined(separator: " OR ")
            let patterns = photoIds.map { id -> String in
                let escaped = id
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                return "%\"\(escaped)\"%"
            }
            return try connection.prepare("""
                SELECT id, photo_ids_json FROM navigation_groups
                WHERE session_id = ? AND source = 'automatic' AND (\(conditions))
              """).query([.text(sessionId)] + patterns.map { .text($0) }).map {
                AutomaticNavigationGroupRow(
                    id: $0[0].textValue ?? "", photoIdsJSON: $0[1].textValue ?? "")
            }
        }
        return try connection.prepare("""
            SELECT id, photo_ids_json FROM navigation_groups
            WHERE session_id = ? AND source = 'automatic'
          """).query([.text(sessionId)]).map {
            AutomaticNavigationGroupRow(
                id: $0[0].textValue ?? "", photoIdsJSON: $0[1].textValue ?? "")
        }
    }

    public func deleteNavigationGroups(ids: [String]) throws {
        for chunk in ids.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "DELETE FROM navigation_groups WHERE id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
        }
    }

    public func deleteSimilarityResults(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM similarity_results WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    /// 照片 → 会话（失效范围）。
    public func sessionIds(photoIds: [String]) throws -> Set<String> {
        var sessions = Set<String>()
        for chunk in photoIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT DISTINCT session_id FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            for row in rows {
                if let sessionId = row[0].textValue { sessions.insert(sessionId) }
            }
        }
        return sessions
    }

    /// 照片 → 所属会话分组（人脸失效按会话分批）。
    public func photoIdsBySession(photoIds: [String]) throws -> [String: [String]] {
        var bySession: [String: [String]] = [:]
        for chunk in photoIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT id, session_id FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            for row in rows {
                guard let id = row[0].textValue, let sessionId = row[1].textValue else { continue }
                bySession[sessionId, default: []].append(id)
            }
        }
        return bySession
    }
}
