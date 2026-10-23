// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo.swift
// 人脸域仓储（全量重写；TS face.repo.ts 时代的存档计数与整会话删绑定已删除）。
//
// 核心约定：
// 1. 用户数据 vs 派生数据。role_bindings / face_clusters.matched_person_id 是用户
//    身份数据；face_observations / face_cluster_members / face_cluster_state 是派生
//    数据。内容/路径变化只销毁派生数据（invalidateDerivedResults），**绝不**删除
//    role_bindings、face_clusters 或 metadata_keyword_origins —— 绑定只能由用户
//    显式解绑（deleteBinding）或人物身份生命周期（PersonRepo）变更。
// 2. 成员计数唯一真相 = COUNT(face_cluster_members)。V1 已删除 member_count 物理列
//    （读取恒为 COUNT 别名，写侧不再维护缓存）；成员清单用 LEFT JOIN photos，
//    照片行缺失的成员不再静默消失 → 计数与清单恒一致。
// 3. 孤儿绑定（成员为 0 但仍有 role_bindings）必须可读（getClusters 返回），
//    这是「解绑路径独立于簇成员身份」的载体，也是 XMP 人物关键词的清理入口。
// 拆分：facade/存储留本文件；实现见 FaceRepo+Observations/Clusters/Members/Feedback.swift（纯移动）。
// 跨文件访问级：仅 connection、deleteThumbnailFile 由 private 放宽为 internal。

import Foundation
import GatherProtocol

/// 人脸仓库（TS FaceRepository）。
public final class FaceRepo {
    let connection: DBConnection
    private let faceThumbnailDir: String?

    public init(connection: DBConnection, faceThumbnailDir: String? = nil) {
        self.connection = connection
        self.faceThumbnailDir = faceThumbnailDir
    }

    // ─────────────────────────── 缩略图 ───────────────────────────

    private func resolveFaceThumbDir() -> String {
        if let faceThumbnailDir, !faceThumbnailDir.isEmpty { return faceThumbnailDir }
        #if os(macOS)
        return TSPath.join([NSHomeDirectory(), "Library", "Application Support", "Gather", "face-thumbnails"])
        #else
        return TSPath.join([NSHomeDirectory(), ".local", "share", "gather", "face-thumbnails"])
        #endif
    }

    func deleteThumbnailFile(_ thumbnailPath: String) {
        if thumbnailPath.isEmpty { return }
        let fullPath = TSPath.join([resolveFaceThumbDir(), thumbnailPath])
        try? FileManager.default.removeItem(atPath: fullPath)
    }
}
