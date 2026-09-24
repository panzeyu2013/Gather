// Store/ChecksumBackfillStore.swift
// R1：checksum 回填的乐观写库事务（photos 条件写 + asset_files 同步条件写）
// 的唯一访问入口。写入序与守卫由 Services/IndexerService.backfillChecksums
// 的内联事务逐字下沉而来（idx2b5）：Runtime/Indexer 与 Service 共用本协议，
// Runtime 层保持零 SQL 文本。
import Foundation

/// 单条待回填写库输入：读取/哈希阶段的产物，字段与旧内联事务消费的批元素
/// 一一对应。
public struct ChecksumBackfillWrite: Sendable, Equatable {
    /// photos.id。
    public let photoId: String
    /// photos.asset_file_id（可空：无资产行的照片只回填 photos 行）。
    public let assetFileId: String?
    /// 新算出的 checksum（hex）。
    public let checksum: String
    /// stat 取得的当前文件字节数。
    public let fileSize: Int64
    /// stat 取得的当前 mtime（毫秒）。
    public let fileMtimeMs: Double

    public init(
        photoId: String,
        assetFileId: String?,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double
    ) {
        self.photoId = photoId
        self.assetFileId = assetFileId
        self.checksum = checksum
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

/// 单批回填写库结果：backfilled + skipped 恒等于输入条数。
public struct ChecksumBackfillOutcome: Sendable, Equatable {
    /// photos 守卫写命中并完成（含 asset_files 同步）的条数。
    public let backfilled: Int
    /// 并发写入者已填充（或清空）导致守卫未过的条数。
    public let skipped: Int

    public init(backfilled: Int, skipped: Int) {
        self.backfilled = backfilled
        self.skipped = skipped
    }
}

public protocol ChecksumBackfillStore: Sendable {
    /// 单事务乐观回填一批：photos 仅当 checksum = '' 时写（并发扫描/回填刚写或
    /// 清空的值不被覆盖）；命中后同步 asset_files（同样仅当 checksum = ''）。
    /// 守卫未过仅计 skipped，不触碰资产行，保持 photos 与 asset_files 一致。
    func applyBackfilledChecksums(_ writes: [ChecksumBackfillWrite]) async throws -> ChecksumBackfillOutcome
}

public struct SQLiteChecksumBackfillStore: ChecksumBackfillStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func applyBackfilledChecksums(_ writes: [ChecksumBackfillWrite]) async throws -> ChecksumBackfillOutcome {
        guard !writes.isEmpty else { return ChecksumBackfillOutcome(backfilled: 0, skipped: 0) }
        return try await database.transaction { db in
            var backfilled = 0
            var skipped = 0
            for write in writes {
                // 乐观填充：仅当照片 checksum 仍为空才写（并发扫描刚写/清空的值
                // 不被覆盖）。
                let photoChanges = try db.run("""
                    UPDATE photos
                    SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                        updated_at = ?
                    WHERE id = ? AND checksum = ''
                  """, [
                    .text(write.checksum), .int(write.fileSize), .real(write.fileMtimeMs),
                    .text(nowISOString()), .text(write.photoId),
                ])
                if photoChanges == 0 {
                    // 另一写入者已填充（或清空）：跳过资产行写入，保持 photos 与
                    // asset_files 一致。
                    skipped += 1
                } else {
                    if let assetFileId = write.assetFileId {
                        _ = try db.run("""
                            UPDATE asset_files
                            SET checksum = ?, file_size = ?, file_mtime_ms = ?, updated_at = ?
                            WHERE id = ? AND checksum = ''
                          """, [
                            .text(write.checksum), .int(write.fileSize), .real(write.fileMtimeMs),
                            .text(nowISOString()), .text(assetFileId),
                        ])
                    }
                    backfilled += 1
                }
            }
            return ChecksumBackfillOutcome(backfilled: backfilled, skipped: skipped)
        }
    }
}
