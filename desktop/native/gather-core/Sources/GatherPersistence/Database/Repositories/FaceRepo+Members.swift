// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Members.swift
// 源：FaceRepo.swift（HEAD c4aa5b5）；纯拆分（members），方法体/SQL/错误逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 FaceRepo.swift 头部记账。

import Foundation
import GatherProtocol

/// face_cluster_members LEFT JOIN photos 的行（fm.id, fm.cluster_id, fm.session_id,
/// fm.photo_id, p.filepath AS photo_path, fm.bbox, fm.confidence, fm.observation_id）。
/// 照片行缺失时 photoPath 为空字符串（成员仍在计数与清单中，不再被 JOIN 丢掉）。
public struct FaceClusterMemberRow {
    public let id: Int64
    public let clusterId: Int64
    public let sessionId: String
    public let photoId: String
    public let photoPath: String
    public let bbox: String
    public let confidence: Double
    public let observationId: Int64?

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        clusterId = row[1].intValue ?? 0
        sessionId = row[2].textValue ?? ""
        photoId = row[3].textValue ?? ""
        photoPath = row[4].textValue ?? ""
        bbox = row[5].textValue ?? ""
        confidence = row[6].doubleValue ?? 0
        observationId = row[7].intValue
    }
}

/// getClusterMembers 的成员投影。
public struct ClusterMemberLite {
    public let photoId: String
    public let bbox: [Double]
    public let confidence: Double
}

extension FaceRepo {

    public func getClusterMembers(_ clusterId: Int64) throws -> [ClusterMemberLite] {
        let rows = try connection.prepare(
            "SELECT photo_id, bbox, confidence FROM face_cluster_members WHERE cluster_id = ?"
        ).query([.int(clusterId)])
        return rows.map { row in
            ClusterMemberLite(
                photoId: row[0].textValue ?? "",
                bbox: parseBbox(row[1].textValue ?? ""),
                confidence: row[2].doubleValue ?? 0
            )
        }
    }

    // MARK: - WP3b-2：FaceKwService 的内联 SQL 下沉

    /// 无脸结果清理的成员段（clearOnEmpty）：清空会话成员行，簇行留给
    /// deleteUnboundClusters 只删未绑定的（绑定必须保留）。调用方事务内。
    public func clearClusterMembers(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    /// 增量聚类 C 段：向已有簇追加成员（语句只准备一次，调用方事务内）。
    public func appendClusterMembers(
        sessionId: String,
        groups: [(clusterId: Int64, members: [FaceClusterMemberInput])]
    ) throws {
        guard groups.contains(where: { !$0.members.isEmpty }) else { return }
        let insertMember = try connection.prepare("""
            INSERT INTO face_cluster_members
             (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
             VALUES (?, ?, ?, ?, ?, ?)
            """)
        for group in groups {
            for member in group.members {
                let bboxJSON = try JSONValue.stringify(
                    JSONValue.array(member.bbox.map { JSONValue.real($0) }))
                _ = try insertMember.run([
                    .int(group.clusterId),
                    .text(sessionId),
                    .text(member.photoId),
                    .text(bboxJSON),
                    .real(member.confidence),
                    optDB(member.observationId),
                ])
            }
        }
    }

    /// 按成员行 id 删除（幽灵成员清理；400 分块防参数上限，调用方事务内）。
    public func deleteClusterMembers(ids: [Int64]) throws {
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "DELETE FROM face_cluster_members WHERE id IN (\(placeholders))"
            ).run(chunk.map { .int($0) })
        }
    }

    /// 移除成员。最后一个成员被移除时：
    /// - 还有绑定 → 保留簇行与绑定（孤儿绑定，供 UI 解绑并清理 XMP 关键词）；
    /// - 无绑定 → 删除簇行。
    public func removeMemberFromCluster(clusterId: Int64, memberId: Int64) throws -> Bool {
        let liveCountBefore = try memberCount(clusterId: clusterId)
        let hasBinding = try bindingExists(clusterId: clusterId)
        let thumbnailPathToDelete = liveCountBefore == 1 ? try getClusterThumbnailPath(clusterId) : ""

        let deleted: Bool = try connection.transaction {
            let removed = try connection.prepare(
                "DELETE FROM face_cluster_members WHERE cluster_id = ? AND id = ?"
            ).run([.int(clusterId), .int(memberId)])
            if removed == 0 { return false }
            let remaining = try memberCount(clusterId: clusterId)
            if remaining == 0 && !hasBinding {
                _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(clusterId)])
                _ = try connection.prepare("DELETE FROM face_clusters WHERE id = ?").run([.int(clusterId)])
            } else {
                // member_count 不再是物理列（V1）：读取恒为实时 COUNT，只更新 updated_at。
                _ = try connection.prepare("UPDATE face_clusters SET updated_at = ? WHERE id = ?")
                    .run([.text(nowISOString()), .int(clusterId)])
            }
            return true
        }
        if deleted { deleteThumbnailFile(thumbnailPathToDelete) }
        return deleted
    }

    // ─────────────────────────── 辅助 ───────────────────────────

    private func memberCount(clusterId: Int64) throws -> Int64 {
        try connection.prepare("SELECT COUNT(*) FROM face_cluster_members WHERE cluster_id = ?")
            .get([.int(clusterId)])?[0].intValue ?? 0
    }

    private func bindingExists(clusterId: Int64) throws -> Bool {
        try connection.prepare("SELECT 1 FROM role_bindings WHERE cluster_id = ? LIMIT 1")
            .get([.int(clusterId)]) != nil
    }
}
