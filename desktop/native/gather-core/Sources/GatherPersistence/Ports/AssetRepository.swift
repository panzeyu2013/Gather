// desktop/native/gather-core/Sources/GatherPersistence/Ports/AssetRepository.swift
// WP3b-1：Asset 仓储端口（只含 Application 实际调用的方法）。
import Foundation

public protocol AssetRepository {
    func backfillSession(_ sessionId: String) throws -> BackfillResult
    func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        fileIdentity: String
    ) throws -> RelinkMovedFileResult?
    /// SessionService：删除会话后，把无会话引用的资产标 orphan。
    func markOrphanedAssets() throws
    /// metadata.scan（#3）：会话导入后复核 RAW/JPEG 配对候选，返回配对成对数。
    /// 返回 Int64 与仓储一致（relink 计数口径）。
    @discardableResult
    func reconcileRawJpegLinks(_ sessionId: String) throws -> Int64
}

public extension AssetRepository {
    func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double
    ) throws -> RelinkMovedFileResult? {
        try relinkMovedFile(
            newPath: newPath,
            checksum: checksum,
            fileSize: fileSize,
            fileMtimeMs: fileMtimeMs,
            fileIdentity: ""
        )
    }
}

extension AssetRepo: AssetRepository {}
