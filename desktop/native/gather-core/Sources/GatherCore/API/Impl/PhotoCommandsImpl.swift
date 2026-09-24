// API/Impl/PhotoCommandsImpl.swift
// R5 命令层接线：photo 域实现（批次 B3）。
// 逻辑来源：宿主路由层 photo.list_page 分支的「取页 + 行装配」两段逻辑：
// - 取页走 PhotoStore.getAssetPage（keyset 分页，cursor 为下页游标）；
// - limit 缺省 200、钳制 1...1000（旧 clampedLimit 语义，参数已为 Int?）；
// - 行装配按逻辑资产分组（asset_id ?? "photo:<id>"），expandVariants=false 时
//   每组按成员角色 raw → camera_jpeg → 首行的偏好折叠为一条，成员角色与
//   人脸计数为 best-effort 小查询（失败回退空映射，与旧分支一致）。
// 旧 JSON 字面量收敛为 Protocol/Session.swift 的 PhotoData：checksum 缺省 ""、
// hasExistingXmp 恒 false、metadata/result 为空对象、nil assetId 不输出，
// 与旧行逐字段对齐；cursor 末页为 nil。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// photo 域命令实现：注入照片存储、资产成员角色与人脸观测计数。
public actor PhotoCommandsImpl: PhotoCommands {
    private let photos: any PhotoStore
    private let assets: any AssetStore
    private let faces: any FaceStore

    public init(photos: any PhotoStore, assets: any AssetStore, faces: any FaceStore) {
        self.photos = photos
        self.assets = assets
        self.faces = faces
    }

    /// 旧命令：`photo.list_page`。keyset 分页 + 逻辑资产折叠。
    public func listPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int?,
        expandVariants: Bool
    ) async throws -> (rows: [PhotoData], cursor: Int64?) {
        let page = try await photos.getAssetPage(
            sessionId: sessionId,
            afterFirstRowid: afterFirstRowid,
            limit: Self.clampedLimit(limit)
        )
        guard !page.rows.isEmpty else { return ([], page.cursor) }

        let ids = page.rows.map(\.id)
        let memberRoles = (try? await assets.memberRoles(sessionId: sessionId, photoIds: ids)) ?? [:]
        let faceCounts = (try? await faces.countsByPhoto(sessionId: sessionId, photoIds: ids)) ?? [:]
        let rows = Self.assembleRows(
            page.rows,
            expandVariants: expandVariants,
            memberRoles: memberRoles,
            faceCounts: faceCounts
        )
        return (rows, page.cursor)
    }

    /// 旧 clampedLimit：缺省 200、钳制 1...1000。
    private static func clampedLimit(_ limit: Int?) -> Int {
        guard let limit else { return 200 }
        return Swift.max(1, Swift.min(1_000, limit))
    }

    /// 旧 assemblePhotos：按逻辑资产分组折叠，并附带成员角色与人脸计数。
    private static func assembleRows(
        _ rows: [PhotoPage],
        expandVariants: Bool,
        memberRoles: [String: String],
        faceCounts: [String: Int]
    ) -> [PhotoData] {
        func toPhotoData(_ row: PhotoPage, variants: [PhotoPage]) -> PhotoData {
            PhotoData(
                id: row.id,
                sessionId: row.sessionId,
                filepath: row.filepath,
                filename: row.filename,
                checksum: row.checksum ?? "",
                hasExistingXmp: false,
                faceCount: faceCounts[row.id] ?? 0,
                width: row.width,
                height: row.height,
                metadata: [:],
                result: [:],
                status: row.status,
                assetId: row.assetId,
                variantCount: variants.count,
                variants: variants.map { variant in
                    PhotoVariant(
                        photoId: variant.id,
                        filepath: variant.filepath,
                        filename: variant.filename,
                        role: memberRoles[variant.id] ?? "unknown"
                    )
                },
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }

        var groups: [String: [PhotoPage]] = [:]
        var order: [String] = []
        for row in rows {
            let key = row.assetId ?? "photo:\(row.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        if expandVariants {
            return rows.map { row in
                toPhotoData(row, variants: groups[row.assetId ?? "photo:\(row.id)"] ?? [row])
            }
        }
        return order.compactMap { key in
            guard let variants = groups[key] else { return nil }
            let preferred = variants.first { memberRoles[$0.id] == "raw" }
                ?? variants.first { memberRoles[$0.id] == "camera_jpeg" }
                ?? variants[0]
            return toPhotoData(preferred, variants: variants)
        }
    }
}
