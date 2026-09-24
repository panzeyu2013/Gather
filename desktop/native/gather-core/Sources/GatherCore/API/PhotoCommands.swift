// API/PhotoCommands.swift
// R5 类型化 async 域协议：photo 域。
// 旧实现来源：gather-app/Sources/GatherApp/Host/路由层.swift 的
// photo.list_page 分支。
// 约定：方法 async throws、行元素只用 Protocol/ 既有 DTO；本轮不新造类型。
// 缺口（W5-1 计划新增，见 docs/ARCHITECTURE-W5-DESIGN.md 第 2 节）：photo.list_page 的
// 请求/分页壳 DTO（Protocol/Photo.swift 的 PhotoAssetPage）尚不存在，故本协议
// 沿用既有形状：扁平参数 + (rows: [PhotoData], cursor: Int64?)。
// 行 DTO 取 Protocol/PhotoData（app 侧 GalleryPhotoData 是其丢弃恒空 metadata/result
// 两键后的投影，对齐方式留待 W5-1 裁决）。
import Foundation

/// photo 域命令（1 条）。
///
/// 旧命令清单：`photo.list_page`。
public protocol PhotoCommands: Sendable {
    /// 旧命令：`photo.list_page`。
    /// keyset 分页：afterFirstRowid 为 nil 取首页，非 nil 取该 rowid 之后；
    /// limit 缺省 200、上限 1000；expandVariants 为 true 时按资产展开全部变体，
    /// 否则按 RAW / camera_jpeg / 首个的偏好折叠为一条。
    /// 返回 (rows, cursor)：cursor 为下一页游标，末页为 nil。
    func listPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int?,
        expandVariants: Bool
    ) async throws -> (rows: [PhotoData], cursor: Int64?)
}
