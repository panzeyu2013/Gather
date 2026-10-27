// desktop/native/gather-app/Sources/GatherHost/Providers/LiveLibraryDataProvider.swift
// WP4b：Library 的 async 数据端口实现在 Host（原 GatherUI/Library/LibraryViewModel.swift）。
//
// B2 已把 session.list / filter.photos_global / album.* / assets.* 迁到
// SessionAPI / PhotoAPI / AlbumAPI / AssetAPI；B6b 起 metadata.orphans /
// resolve_orphan 走 MetadataAPI。本类只做渲染形状与「bool 确认 ->
// Confirmed<T>」的边界适配，不派发字符串命令，也不再有同步核。
import Foundation
import GatherProtocol
import GatherUI

public final class LiveLibraryDataProvider: LibraryDataProvider {
    private let sessionAPI: any SessionAPI
    private let photoAPI: any PhotoAPI
    private let assetAPI: any AssetAPI
    private let albumAPI: any AlbumAPI
    /// Cut 1 / B6b：元数据域（orphans / resolve_orphan）。
    private let metadataAPI: any MetadataAPI

    /// 显式装配：五个域 API 由调用方（AppServices / 测试）注入。
    /// B8.4 起不再提供字符串命令构造器；MetadataService/Coordinator 只能有
    /// 一份，因此 metadata 是必填依赖，不从组合根兜底构造。
    public init(
        session: any SessionAPI,
        photo: any PhotoAPI,
        asset: any AssetAPI,
        album: any AlbumAPI,
        metadata: any MetadataAPI
    ) {
        self.sessionAPI = session
        self.photoAPI = photo
        self.assetAPI = asset
        self.albumAPI = album
        self.metadataAPI = metadata
    }

    public func listSessions() async throws -> [SessionData] {
        try await sessionAPI.list()
    }

    public func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let result = try await photoAPI.search(try PhotoQuery(
            criteria: criteria,
            sessionId: sessionId,
            limit: limit,
            offset: offset
        ))
        return (result.photos, result.total)
    }

    public func listAlbums() async throws -> [SmartAlbumData] {
        try await albumAPI.list()
    }

    public func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let page = try await albumAPI.photos(try AlbumPhotosQuery(
            albumId: albumId,
            limit: limit,
            offset: offset
        ))
        return (page.photos, page.total)
    }

    public func createAlbum(name: String, criteria: FilterGroup) async throws -> SmartAlbumData {
        let detail = try await albumAPI.create(
            AlbumCreateParams(name: name, criteria: criteria)
        )
        return SmartAlbumData(
            id: detail.id,
            schemaVersion: detail.schemaVersion,
            name: detail.name,
            description: detail.description,
            filterCriteria: detail.filterCriteria,
            sortBy: detail.sortBy,
            sortOrder: detail.sortOrder,
            icon: detail.icon,
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            validationError: detail.validationError
        )
    }

    public func updateAlbum(albumId: String, criteria: FilterGroup) async throws {
        try await albumAPI.update(AlbumUpdateParams(albumId: albumId, criteria: criteria))
    }

    public func deleteAlbum(albumId: String, confirmed: Bool) async throws {
        // 确认来自视图弹窗的 bool；API 只接收 Confirmed。false 时根本不调用 API，
        // 保留旧命令“未确认 -> ALBUM_DELETE_CONFIRM_REQUIRED”的门禁语义。
        guard confirmed else { throw GatherError(code: .ALBUM_DELETE_CONFIRM_REQUIRED) }
        let input = try AlbumDeleteInput(albumId: albumId)
        try await albumAPI.delete(Confirmed(input, source: .userDialog))
    }

    public func listAssetCandidates() async throws -> [AssetLinkCandidateData] {
        try await assetAPI.candidates(AssetCandidatesQuery(sessionId: nil))
    }

    public func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) async throws {
        guard confirmed else {
            throw GatherError(code: accept ? .ASSET_LINK_ACCEPT_CONFIRM_REQUIRED
                                           : .ASSET_LINK_REJECT_CONFIRM_REQUIRED)
        }
        let reference = try AssetCandidateReference(candidateId: candidateId)
        if accept {
            _ = try await assetAPI.accept(Confirmed(reference, source: .userDialog))
        } else {
            _ = try await assetAPI.reject(Confirmed(reference, source: .userDialog))
        }
    }

    public func listAssetVolumes() async throws -> [AssetVolumeData] {
        try await assetAPI.volumes()
    }

    /// P1 / C：facet 计数。sessionId == nil 用 "__global__"（与筛选引擎的会话语义一致）。
    public func facets(
        criteria: FilterGroup,
        sessionId: String?,
        dimensions: [String],
        limit: Int
    ) async throws -> [PhotoFacetGroup] {
        let input = try PhotoFacetInput(
            sessionId: sessionId ?? "__global__", criteria: criteria,
            dimensions: dimensions, limit: limit
        )
        return try await photoAPI.facets(input)
    }

    public func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) async throws -> Int {
        guard confirmed else { throw GatherError(code: .ASSET_RELINK_CONFIRM_REQUIRED) }
        let input = try AssetRelinkInput(oldRoot: oldRoot, newRoot: newRoot)
        return try await assetAPI.relinkRoot(Confirmed(input, source: .userDialog))
    }

    public func listMetadataOrphans() async throws -> [MetadataOrphan] {
        try await metadataAPI.orphans()
    }

    public func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        try await metadataAPI.resolveOrphan(input)
    }
}
