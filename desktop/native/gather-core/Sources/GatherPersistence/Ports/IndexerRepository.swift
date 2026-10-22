// desktop/native/gather-core/Sources/GatherPersistence/Ports/IndexerRepository.swift
// WP3b-2：索引扫描写路径端口（扫缓存 / 文件状态 / checksum 回填 / 派生失效）。
//
// 跨表顺序语义（person_photos → photos、asset_files → assets、photos 与
// asset_files 双写）全部封在 IndexerRepo；Application 只表达业务分支。
import Foundation

public protocol IndexerRepository {
    func deletePersonPhotoBindings(photoIds: [String]) throws
    func deletePhotos(photoIds: [String]) throws
    func pruneSessionAssets(sessionId: String) throws
    func pruneOrphanAssets(fileIds: [String]) throws

    func fileStats(sessionId: String) throws -> [AssetFileStatRow]
    func updateAssetFile(
        assetFileId: String,
        volumeId: String,
        fileIdentity: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        checksum: String,
        preserveChecksum: Bool,
        timestamp: String
    ) throws
    func photoIds(assetFileId: String) throws -> [String]
    func deleteAssetAnalysis(assetFileId: String) throws
    func updatePhotos(
        assetFileId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        width: Int,
        height: Int,
        timestamp: String
    ) throws
    func markAssetFilesOffline(fileIds: [String], timestamp: String) throws

    @discardableResult
    func backfillPhotoChecksum(
        photoId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        timestamp: String
    ) throws -> Bool
    func backfillAssetFileChecksum(
        assetFileId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        timestamp: String
    ) throws

    func deletePhotoInputs(photoIds: [String]) throws
    func automaticNavigationGroups(
        sessionId: String,
        photoIds: [String],
        prefilterCap: Int
    ) throws -> [AutomaticNavigationGroupRow]
    func deleteNavigationGroups(ids: [String]) throws
    func deleteSimilarityResults(sessionId: String) throws
    func sessionIds(photoIds: [String]) throws -> Set<String>
    func photoIdsBySession(photoIds: [String]) throws -> [String: [String]]
}

extension IndexerRepo: IndexerRepository {}
