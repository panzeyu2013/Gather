// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/SimilarityHashRepo.swift
// WP3b-2：similarity_hashes 读写下沉。
//
// 三个消费者（SimilarityService 的 analyze/recluster、DuplicateService 的视觉去重、
// IndexerService 的内容变更失效）此前各写各的内联 SQL：同一 UPSERT 曾出现三份。
// 这里收敛成唯一实现，SQL 逐字保留（冲突目标仍是
// idx_similarity_hashes_session_photo），事务仍由调用方通过 TransactionRunner 提供。
import Foundation

/// similarity_hashes 行（analyze 的 size/mtime 复用判定）。
public struct SimilarityHashRecord: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int
    public let fileMtimeMs: Double

    public init(photoId: String, hashHex: String, fileSize: Int, fileMtimeMs: Double) {
        self.photoId = photoId
        self.hashHex = hashHex
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

/// analyze 解码写入行（批量 UPSERT 的输入）。
public struct SimilarityHashWrite: Equatable, Sendable {
    public let sessionId: String
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int
    public let fileMtimeMs: Double

    public init(
        sessionId: String,
        photoId: String,
        hashHex: String,
        fileSize: Int,
        fileMtimeMs: Double
    ) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.hashHex = hashHex
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

/// reuse 候选：similarity_hashes JOIN photos 的 asset_file_id。
public struct SimilarityHashCandidate: Equatable, Sendable {
    public let id: Int64
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int
    public let fileMtimeMs: Double
    public let assetFileId: String

    public init(
        id: Int64,
        photoId: String,
        hashHex: String,
        fileSize: Int,
        fileMtimeMs: Double,
        assetFileId: String
    ) {
        self.id = id
        self.photoId = photoId
        self.hashHex = hashHex
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
        self.assetFileId = assetFileId
    }
}

/// photos 的 (id, asset_file_id) 投影。
public struct PhotoAssetFileRef: Equatable, Sendable {
    public let photoId: String
    public let assetFileId: String

    public init(photoId: String, assetFileId: String) {
        self.photoId = photoId
        self.assetFileId = assetFileId
    }
}

public final class SimilarityHashRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 会话的全部 hash 行（含 size/mtime，供复用判定）。
    public func getRecords(sessionId: String) throws -> [SimilarityHashRecord] {
        try connection.prepare(
            "SELECT photo_id, hash_hex, file_size, file_mtime_ms FROM similarity_hashes WHERE session_id = ?"
        ).query([.text(sessionId)]).map { row in
            SimilarityHashRecord(
                photoId: row[0].textValue ?? "",
                hashHex: row[1].textValue ?? "",
                fileSize: Int(row[2].intValue ?? 0),
                fileMtimeMs: row[3].doubleValue ?? 0
            )
        }
    }

    /// 会话的 photo_id → hash_hex（recluster 用的窄投影）。
    public func getHashMap(sessionId: String) throws -> [String: String] {
        var map: [String: String] = [:]
        let rows = try connection.prepare(
            "SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?"
        ).query([.text(sessionId)])
        for row in rows {
            guard let photoId = row[0].textValue, let hash = row[1].textValue else { continue }
            map[photoId] = hash
        }
        return map
    }

    /// 批量 UPSERT（调用方事务内；语句只准备一次）。
    /// 冲突目标与唯一索引一致：ON CONFLICT(session_id, photo_id) DO UPDATE。
    public func upsert(_ rows: [SimilarityHashWrite]) throws {
        guard !rows.isEmpty else { return }
        let statement = try connection.prepare("""
            INSERT INTO similarity_hashes
              (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id, photo_id) DO UPDATE SET
              hash_hex = excluded.hash_hex,
              file_size = excluded.file_size,
              file_mtime_ms = excluded.file_mtime_ms
          """)
        for row in rows {
            _ = try statement.run([
                .text(row.sessionId), .text(row.photoId), .text(row.hashHex),
                .int(Int64(row.fileSize)), .real(row.fileMtimeMs),
            ])
        }
    }

    /// 会话内有 asset_file_id 的照片（reuse 的 JOIN 左侧）。
    public func getPhotoAssetFileIds(sessionId: String) throws -> [PhotoAssetFileRef] {
        try connection.prepare(
            "SELECT id, asset_file_id FROM photos WHERE session_id = ? AND asset_file_id IS NOT NULL"
        ).query([.text(sessionId)]).compactMap { row in
            guard let id = row[0].textValue, let assetFileId = row[1].textValue else { return nil }
            return PhotoAssetFileRef(photoId: id, assetFileId: assetFileId)
        }
    }

    /// 按 asset 文件分块批量读 reuse 候选（分块由调用方控制，与旧实现同口径）。
    public func getReuseCandidates(assetFileIds: [String]) throws -> [SimilarityHashCandidate] {
        guard !assetFileIds.isEmpty else { return [] }
        let placeholders = assetFileIds.map { _ in "?" }.joined(separator: ", ")
        let rows = try connection.prepare("""
            SELECT h.id AS hash_id, h.photo_id, h.hash_hex, h.file_size, h.file_mtime_ms, p.asset_file_id
            FROM similarity_hashes h
            JOIN photos p ON h.photo_id = p.id
            WHERE p.asset_file_id IN (\(placeholders))
          """).query(assetFileIds.map { .text($0) })
        return rows.compactMap { row in
            guard let assetFileId = row[5].textValue else { return nil }
            return SimilarityHashCandidate(
                id: row[0].intValue ?? 0,
                photoId: row[1].textValue ?? "",
                hashHex: row[2].textValue ?? "",
                fileSize: Int(row[3].intValue ?? 0),
                fileMtimeMs: row[4].doubleValue ?? 0,
                assetFileId: assetFileId
            )
        }
    }

    /// 按 photo_id 批量删除（IndexerService 的内容变更失效；调用方事务内）。
    public func deleteByPhotoIds(_ photoIds: [String]) throws {
        guard !photoIds.isEmpty else { return }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ", ")
        _ = try connection.prepare(
            "DELETE FROM similarity_hashes WHERE photo_id IN (\(placeholders))"
        ).run(photoIds.map { .text($0) })
    }
}
