// desktop/native/gather-core/Sources/GatherPersistence/Ports/PhotoRepository.swift
// WP3b-1：Photo 仓储端口（只含 Application 实际调用的方法）。
import Foundation
import GatherProtocol

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

/// Wave2（task-15）：全库导入去重用的照片指纹（photos 行）。
///
/// 只包含**已算出校验和**的照片：跨工作区去重以 SHA-256 为判据，未回填校验和的
/// 行无法安全比较（大小/修改时间只能预筛）。懒索引遗留的空校验和行由既有
/// checksum.backfill 任务补齐后自然进入本投影。
public struct LibraryPhotoFingerprint: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let filepath: String
    public let checksum: String
    public let fileSize: Int
    public let fileMtimeMs: Double

    public init(
        photoId: String,
        sessionId: String,
        filepath: String,
        checksum: String,
        fileSize: Int,
        fileMtimeMs: Double
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.filepath = filepath
        self.checksum = checksum
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
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

/// #6 S4 前置：加 Sendable——MetadataAttributeWriter 是 Sendable 结构体。
/// 唯一实现 PhotoRepo 只有 connection 一个存储属性（DBConnection 已是 @unchecked Sendable），
/// 因此可以隐式满足，不需要新增 @unchecked 标注。
public protocol PhotoRepository: Sendable {
    func getBySession(sessionId: String) throws -> [PhotoRow]
    func getBySessionProjection(sessionId: String) throws -> [PhotoProjectionRow]
    /// 物理行分页。默认 **visibleOnly = true**（面向用户的列表必须过滤归档件）；
    /// 只有"按行做数据维护"的路径（checksum 回填：归档件也要补校验和）才传 false。
    func getBySessionPage(
        sessionId: String, afterRowId: Int64?, limit: Int, visibleOnly: Bool
    ) throws -> [PhotoPageRow]
    func pendingChecksumCount(sessionId: String) throws -> Int
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
    /// Wave2（task-15）：跨会话导入去重 —— 全库已知校验和的照片指纹。
    /// matchingSizes 非空时只返回文件大小在集合内的行（省掉整库扫）。
    func libraryFingerprints(matchingSizes: Set<Int>) throws -> [LibraryPhotoFingerprint]
}

public extension PhotoRepository {
    func getBySessionPage(sessionId: String) throws -> [PhotoPageRow] {
        try getBySessionPage(sessionId: sessionId, afterRowId: nil, limit: 200, visibleOnly: true)
    }

    func getAssetPage(sessionId: String) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        try getAssetPage(sessionId: sessionId, afterFirstRowid: nil, limit: 200)
    }

    /// 测试 stub 默认实现（真实实现见 PhotoRepo）。
    func libraryFingerprints(matchingSizes: Set<Int>) throws -> [LibraryPhotoFingerprint] {
        []
    }
}

extension PhotoRepo: PhotoRepository {}
