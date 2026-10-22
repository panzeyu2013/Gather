// desktop/native/gather-app/Sources/GatherHost/APIs/LivePhotoPathPolicy.swift
// Cut 1 / B2：PhotoPathPolicy 的 Live 实现（image.* 的 P/A 路径授权）。
//
// 职责：把“绝对路径是否属于 photos 表已登记照片”的判定收敛到 PhotoRepo。
// 字符串命令时代 requirePhotoPath / allowedPhotoPaths 直接内联在命令边界；现在由
// PhotoAPI 实现经本策略判定后再触碰文件系统，避免 image.* 变成任意文件读取
// oracle（§6.1）。
//
// 校验归属：
// - 空路径 / 超过 4096 字符 => false（不查库，避免无意义 I/O）；
// - 其余交给 PhotoRepo.containsFilepath（当前实现为 photos.filepath 精确匹配）；
// - 只做授权判定，不把“不存在”转成业务错误；单路径的 PHOTO_NOT_FOUND 由
//   LivePhotoAPI 在 API 边界抛出。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LivePhotoPathPolicy: PhotoPathPolicy, @unchecked Sendable {
    private let photoRepo: PhotoRepo

    /// @unchecked Sendable 依据：photoRepo 为构造后不可变的 let，其连接由
    /// DBConnection 的递归锁串行化（与组合根同一约定）。
    public init(photoRepo: PhotoRepo) {
        self.photoRepo = photoRepo
    }

    public func containsFilepath(_ path: String) async throws -> Bool {
        guard !path.isEmpty, path.count <= 4096 else { return false }
        return try photoRepo.containsFilepath(filepath: path)
    }
}
