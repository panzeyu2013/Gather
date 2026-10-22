// desktop/native/gather-core/Sources/GatherProtocol/API/Core/PhotoPathPolicy.swift
// Cut 1 / 阶段 1A：照片路径授权（§6.1 的 requirePhotoPath / allowedPhotoPaths）。
//
// 职责：判定一个绝对路径是否属于 photos 表已登记的照片。image.* 与任何接收
// 文件路径的照片 API 必须在访问文件系统前经此策略校验，避免把解码/预加载接口
// 变成任意文件读取 oracle。
// 校验归属：
// - 空路径 / 超长（> 4096）/ 未登记 => false；
// - 单路径失败由 1B 的 API 实现转成 PHOTO_NOT_FOUND 语义的 GatherError
//   （D-010 后使用新增码；当前用 GatherError.invalidParameter / 域内码，见 GatherError）；
// - 批量路径由 API 实现先 filter 再调用，去重与长度上限在实现内完成。

import Foundation

public protocol PhotoPathPolicy: Sendable {
    /// 路径是否属于已登记照片。只做授权判定，不抛业务错误；I/O 失败可 throws。
    func containsFilepath(_ path: String) async throws -> Bool
}
