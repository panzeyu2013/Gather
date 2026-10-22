// desktop/native/gather-app/Sources/GatherHost/Providers/LiveGalleryDataProvider.swift
// WP4b：Gallery 的 async 数据端口实现在 Host（原 GatherUI/Gallery/GalleryViewModel.swift）。
//
// photo.list_page 已迁移到 PhotoAPI（B2）；资产分组/变体装配仍以 LivePhotoAPI
// 为唯一事实源，GalleryPhotoData 只做渲染形状适配。B8.2a：session.get /
// workspace.status / settings.get 走 SessionAPI / SettingsAPI。本 provider 只
// 负责读（photo/session/settings），不派发字符串命令；首载/索引重试仍在 VM。
import Foundation
import GatherProtocol
import GatherUI

public final class LiveGalleryDataProvider: GalleryDataProvider {
    private let photoAPI: any PhotoAPI
    private let sessionAPI: any SessionAPI
    private let settingsAPI: any SettingsAPI

    /// 显式装配：photo/session/settings 由调用方（AppServices / 测试）注入。
    /// B8.4 起不再提供字符串命令构造器；会话缺失返回 nil（旧 getSession 语义）。
    public init(
        photo: any PhotoAPI,
        session: any SessionAPI,
        settings: any SettingsAPI
    ) {
        self.photoAPI = photo
        self.sessionAPI = session
        self.settingsAPI = settings
    }

    public func getSession(_ sessionId: String) async throws -> SessionData? {
        do {
            return try await sessionAPI.get(sessionId)
        } catch let error as GatherError where error.code == .SESSION_NOT_FOUND {
            return nil
        }
    }

    public func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        // PhotoPageQuery 已完成 limit 1...1000 / afterFirstRowid >= 0 的归一化，
        // 与旧 photo.list_page 的 clampedLimit 语义一致。
        let page = try await photoAPI.page(try PhotoPageQuery(
            sessionId: sessionId,
            limit: limit,
            afterFirstRowid: afterFirstRowid,
            expandVariants: expandVariants
        ))
        let rows = page.rows.map { row in
            GalleryPhotoData(
                id: row.id,
                sessionId: row.sessionId,
                filepath: row.filepath,
                filename: row.filename,
                checksum: row.checksum,
                hasExistingXmp: row.hasExistingXmp,
                faceCount: row.faceCount,
                width: row.width,
                height: row.height,
                status: row.status,
                variantCount: row.variantCount ?? row.variants?.count ?? 0,
                variants: (row.variants ?? []).map { variant in
                    GalleryVariantData(
                        photoId: variant.photoId,
                        filepath: variant.filepath,
                        filename: variant.filename,
                        role: variant.role
                    )
                },
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                assetId: row.assetId
            )
        }
        return (rows, page.cursor)
    }

    /// TS: Gallery.tsx:50-55 —— settings thumbnail_size（默认 1024）分桶映射。
    /// B8.2a：SettingsAPI.get（async）；键是常量，校验失败/读取失败都回退默认值。
    public func thumbnailSize() async -> Int {
        let raw = (try? await settingsAPI.get(SettingsKey("thumbnail_size"))) ?? ""
        return Self.thumbnailBucket(Int(raw) ?? 1024)
    }

    /// TS: thumbnail_size → 解码尺寸：≤320→256、≤1280→1024、>1280→2048。
    public static func thumbnailBucket(_ value: Int) -> Int {
        switch value {
        case ...320: return 256
        case 321...1280: return 1024
        default: return 2048
        }
    }

    /// TS: workspace.status —— indexing job 派生（quque/running/cancelling →
    /// active；succeeded → stage indexed；failed → failed）。
    public func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? {
        try await sessionAPI.status(sessionId)
    }
}
