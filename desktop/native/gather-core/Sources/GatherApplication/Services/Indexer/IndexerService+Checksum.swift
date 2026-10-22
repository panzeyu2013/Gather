// desktop/native/gather-core/Sources/GatherApplication/Services/Indexer/IndexerService+Checksum.swift
// P1-4 收口：IndexerService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：checksum 回填（keyset 分页 + 并发哈希 + 单事务乐观写入）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension IndexerService {

    // ─────────────────────────── checksum 回填 ───────────────────────────

    /// TS: pendingChecksums —— 会话内仍缺 checksum 的照片数（调用方决定是否
    /// 创建 checksum.backfill 任务）。
    public func pendingChecksums(sessionId: String) throws -> Int {
        // E-5（性能审计）：下沉为 COUNT(*)（旧实现物化整会话行、含大列）。
        try self.photoRepo.pendingChecksumCount(sessionId: sessionId)
    }

    /// TS: backfillChecksums —— 后台回填懒索引留下的空 checksum：循环直到无
    /// pending；每批 stat 取新鲜 size/mtime，乐观守卫（AND checksum = ''）保证
    /// 与并发扫描互不覆盖；不可读照片记入 per-job 失败集避免死循环。
    public func backfillChecksums(
        sessionId: String,
        context: JobRunContext? = nil
    ) async throws -> (processed: Int, backfilled: Int, skipped: Int) {
        var processed = 0
        var backfilled = 0
        var skipped = 0
        var failedPhotoIds = Set<String>()
        // Keyset 游标：首趟全扫，后续从最后 rowid 继续。
        var afterRowId: Int64?
        for _ in 0... {
            try context?.throwIfCancelled()
            let (pending, lastRowId) = try loadPendingBackfill(
                sessionId: sessionId, afterRowId: afterRowId, failedPhotoIds: failedPhotoIds
            )
            if let lastRowId { afterRowId = lastRowId }
            if pending.isEmpty { break }
            context?.updateProgress(JobProgressUpdate(
                current: 0, total: pending.count, phase: "index.checksum"
            ))
            var passBackfilled = 0
            for offset in stride(from: 0, to: pending.count, by: Self.checksumBackfillBatch) {
                try context?.throwIfCancelled()
                let batch = Array(pending[offset..<min(offset + Self.checksumBackfillBatch, pending.count)])
                // 哈希阶段只读；全部写入进入单事务。
                let results = try await batchAsync(
                    batch, concurrency: Self.checksumBackfillConcurrency
                ) { photo -> (photo: PhotoPageRow, checksum: String, size: Int64, mtimeMs: Double)? in
                    do {
                        let source = try self.stat(photo.filepath)
                        let checksum = try self.fileHasher(photo.filepath)
                        return (photo, checksum, source.size, source.mtimeMs)
                    } catch {
                        // 已删除/不可读：本任务内放弃，循环得以终止；
                        // 下次全量扫描会标记 missing。
                        return nil
                    }
                }
                try self.transactions.transaction {
                    for (index, result) in results.enumerated() {
                        guard let result else {
                            failedPhotoIds.insert(batch[index].id)
                            skipped += 1
                            processed += 1
                            continue
                        }
                        // 乐观填充：仅当照片 checksum 仍为空才写（并发扫描
                        // 刚写/清空的值不被覆盖）。
                        let photoChanges = try self.indexer.backfillPhotoChecksum(
                            photoId: result.photo.id,
                            checksum: result.checksum,
                            fileSize: result.size,
                            fileMtimeMs: result.mtimeMs,
                            timestamp: nowISOString()
                        )
                        if !photoChanges {
                            // 另一写入者已填充（或清空）：跳过资产行写入，
                            // 保持 photos 与 asset_files 一致。
                            skipped += 1
                        } else {
                            if let assetFileId = result.photo.assetFileId {
                                try self.indexer.backfillAssetFileChecksum(
                                    assetFileId: assetFileId,
                                    checksum: result.checksum,
                                    fileSize: result.size,
                                    fileMtimeMs: result.mtimeMs,
                                    timestamp: nowISOString()
                                )
                            }
                            passBackfilled += 1
                            backfilled += 1
                        }
                        processed += 1
                    }
                }
                context?.updateProgress(JobProgressUpdate(current: processed, total: pending.count))
            }
            // 全部 pending 要么已失败要么重试只会重复失败：停止而非空转。
            if passBackfilled == 0 { break }
        }
        return (processed: processed, backfilled: backfilled, skipped: skipped)
    }

    /// TS: loadPendingBackfill —— keyset 分页扫描待回填照片。
    private func loadPendingBackfill(
        sessionId: String,
        afterRowId: Int64?,
        failedPhotoIds: Set<String>
    ) throws -> (rows: [PhotoPageRow], lastRowId: Int64?) {
        var rows: [PhotoPageRow] = []
        var cursor: Int64? = afterRowId
        var lastRowId: Int64?
        for _ in 0... {
            let page = try self.photoRepo.getBySessionPage(
                sessionId: sessionId, afterRowId: cursor, limit: Self.checksumBackfillPageSize
            )
            if page.isEmpty { break }
            lastRowId = page[page.count - 1].rowid
            for photo in page {
                if photo.checksum?.isEmpty ?? true,
                   photo.status != "missing",
                   !failedPhotoIds.contains(photo.id) {
                    rows.append(photo)
                }
            }
            cursor = lastRowId
        }
        return (rows, lastRowId)
    }
}
