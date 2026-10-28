// desktop/native/gather-core/Sources/GatherPersistence/Ports/PhotoRepository.swift
// WP3b-1：Photo 仓储端口（只含 Application 实际调用的方法）。
import Foundation

/// photos 的 light lookup 投影（MetadataService.getPhotosByIds）。
public struct PhotoLookupRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String

    public init(id: String, sessionId: String, filepath: String) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
    }
}

/// ExportService 报告用照片投影。
public struct PhotoReportRow: Equatable, Sendable {
    public let filename: String
    public let filepath: String
    public let status: String

    public init(filename: String, filepath: String, status: String) {
        self.filename = filename
        self.filepath = filepath
        self.status = status
    }
}

public protocol PhotoRepository {
    func getBySession(sessionId: String) throws -> [PhotoRow]
    func getBySessionProjection(sessionId: String) throws -> [PhotoProjectionRow]
    func getBySessionPage(sessionId: String, afterRowId: Int64?, limit: Int) throws -> [PhotoPageRow]
    func pendingChecksumCount(sessionId: String) throws -> Int
    func countBySession(sessionId: String) throws -> Int
    /// 仍在工作区的照片数（PhotoVisibility.visiblePredicate）；WorkspaceStatus /
    /// sessions.photo_count 用它，避免"移出 100 张后工作区总数不变"。
    func countVisibleBySession(sessionId: String) throws -> Int
    func countAssetsBySession(sessionId: String) throws -> Int
    func getAssetPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?)
    func addPhotos(sessionId: String, filepaths: [PhotoAddInput], _ source: String) throws -> PhotoAddResult
    func deleteBySession(sessionId: String) throws
    func updateIndexedFile(photoId: String, width: Int, height: Int, changed: Bool) throws
    func updateChecksum(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double) throws
    func markMissing(photoIds: [String]) throws
    /// P1 / D：淘汰移动后改写登记路径（照片仍在库内，只换位置）。
    func updateFilepath(photoId: String, filepath: String) throws
    /// WorkspaceStatus：按状态计数（offlinePhotos 的缺失照片数）。
    func countByStatus(sessionId: String, status: String) throws -> Int
    /// MetadataService：分块 IN 查询（800/块）。
    func getLookupByIds(_ photoIds: [String]) throws -> [PhotoLookupRow]
    /// ExportService.session_summary 报告。
    func reportRows(sessionId: String) throws -> [PhotoReportRow]
}

public extension PhotoRepository {
    func getBySessionPage(sessionId: String) throws -> [PhotoPageRow] {
        try getBySessionPage(sessionId: sessionId, afterRowId: nil, limit: 200)
    }

    func getAssetPage(sessionId: String) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        try getAssetPage(sessionId: sessionId, afterFirstRowid: nil, limit: 200)
    }
}

extension PhotoRepo: PhotoRepository {}
