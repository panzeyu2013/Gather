// desktop/native/gather-app/Sources/GatherHost/SyncAPIPortBridge.swift
// Cut 3 / 3b-3（E-18 / E-19）：Live API → GatherUI 同步端口的适配。
//
// Live 实现的同步核是 internal（与 async API 同文件、同 target）；这里用
// public extension 把端口方法薄转发过去，不复制任何领域逻辑，也不改同步核
// 的可见性。UI 只认端口协议，Host 只是实现者。
import Foundation
import GatherAnalysis
import GatherDomain
import GatherProtocol
import GatherUI

extension LiveSessionAPI: SessionSyncAPI {
    public func listSessionsSync() throws -> [SessionData] { try listSync() }
    public func createSessionSync(_ input: SessionCreateInput) throws -> SessionCreateResult {
        try createSync(input)
    }
    public func deleteSessionsSync(_ input: Confirmed<SessionDeleteInput>) throws {
        try deleteSync(input)
    }
    public func workspaceStatusSync(_ sessionId: String) throws -> WorkspaceStatus? {
        try statusSync(sessionId)
    }
}

extension LiveAlbumAPI: AlbumSyncAPI {
    public func listAlbumsSync() throws -> [SmartAlbumData] { try listSync() }
    public func createAlbumSync(_ input: AlbumCreateParams) throws -> SmartAlbumDetailData {
        try createSync(input)
    }
    public func updateAlbumSync(_ input: AlbumUpdateParams) throws {
        try updateSync(input)
    }
    public func deleteAlbumSync(_ albumId: String) throws {
        try deleteSync(albumId)
    }
}

extension LiveAssetAPI: AssetSyncAPI {
    public func assetCandidatesSync(_ sessionId: String?) throws -> [AssetLinkCandidateData] {
        try candidatesSync(sessionId)
    }
    public func assetVolumesSync() throws -> [AssetVolumeData] {
        try volumesSync()
    }
    public func acceptCandidateSync(_ candidateId: String) throws -> Bool {
        try acceptSync(candidateId)
    }
    public func rejectCandidateSync(_ candidateId: String) throws -> Bool {
        try rejectSync(candidateId)
    }
    public func assetRelinkRootSync(oldRoot: String, newRoot: String) throws -> Int {
        try relinkRootSync(oldRoot: oldRoot, newRoot: newRoot)
    }
}

extension LiveJobAPI: JobSyncAPI {
    public func listJobsSync(_ filter: JobListFilter) throws -> [AnalysisJobData] {
        try listSync(filter)
    }
    public func cancelJobSync(_ jobId: String) throws -> Bool {
        try cancelSync(jobId)
    }
    public func retryJobSync(_ jobId: String) throws -> Bool {
        try retrySync(jobId)
    }
    public func clearCompletedJobsSync() throws -> Int {
        try clearCompletedSync()
    }
    public func startJobSync(_ request: JobCreateParams) throws -> AnalysisJobData {
        try createJobSync(request)
    }
}

extension JobCancelledError: JobCancellationMarker {}

extension JobServiceError: DomainErrorMessaging {
    public var rawErrorMessage: String? {
        switch self {
        case .jobFailed(_, let message), .waitForResultTimeout(let message):
            return message
        case .jobNotFound(let id), .leaseLost(let id):
            return id
        }
    }
}

extension FaceKwServiceError: DomainErrorMessaging {
    public var rawErrorMessage: String? { description }
}

// E-19 相邻：分析层的中文可读错误同样经端口上屏（原 UI 直接 as? 该类型）。
extension FaceEmbeddingError: DomainErrorMessaging {
    public var rawErrorMessage: String? { description }
}
