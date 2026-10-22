#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewProviders.swift
// Cut 4 / 4c-1：三个 DataProvider 的 Preview 实现（只在 DEBUG 编译）。
//
// Dashboard/Library/Gallery 的数据协议是 UI-owned 的同步/异步端口（不是
// GatherProtocol 的 API）。生产实现（Live*DataProvider）在 Host；这里用固定
// fixture 顶替，保证 Preview 不碰 SQLite / 文件系统。
//
// 与 Tests 的 Stub*Provider 无关：测试替身记录调用/注入错误，这里只返回样例。

// MARK: - Dashboard

struct PreviewDashboardProvider: DashboardDataProvider {
    func listSessions() async throws -> [SessionData] { PreviewData.sessions }

    func createSession(name: String, source: String, sourcePath: String) async throws -> SessionData {
        throw PreviewAPIError.unavailable("dashboard.createSession")
    }

    func deleteSession(_ sessionId: String, confirmed: Bool) async throws {
        throw PreviewAPIError.unavailable("dashboard.deleteSession")
    }

    func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? {
        PreviewData.workspaceStatus(sessionId)
    }

    func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] { PreviewData.jobs }

    func cancelJob(_ jobId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("dashboard.cancelJob")
    }

    func retryJob(_ jobId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("dashboard.retryJob")
    }

    func clearCompletedJobs() async throws -> Int {
        throw PreviewAPIError.unavailable("dashboard.clearCompletedJobs")
    }
}

// MARK: - Gallery

struct PreviewGalleryProvider: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? {
        PreviewData.sessions.first { $0.id == sessionId }
    }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        (PreviewData.galleryPhotos, nil)
    }

    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? {
        PreviewData.workspaceStatus(sessionId)
    }

    func thumbnailSize() async -> Int { 1024 }
}

// MARK: - Library

struct PreviewLibraryProvider: LibraryDataProvider {
    func listSessions() async throws -> [SessionData] { PreviewData.sessions }

    func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        (PreviewData.globalPhotos, PreviewData.globalPhotos.count)
    }

    func listAlbums() async throws -> [SmartAlbumData] { PreviewData.albums }

    func listAssetCandidates() async throws -> [AssetLinkCandidateData] { PreviewData.assetCandidates }

    func listAssetVolumes() async throws -> [AssetVolumeData] { PreviewData.assetVolumes }

    func listMetadataOrphans() async throws -> [MetadataOrphan] { PreviewData.orphanXMPs }
}
#endif
