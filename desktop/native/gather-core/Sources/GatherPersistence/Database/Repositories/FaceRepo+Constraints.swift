// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Constraints.swift
// P0 / F0：人脸簇约束、拆分写路径与复核成员查询。
//
// 约束行在会话级；Application 负责解析键并决定移动/合并，Repo 只做原子 SQL。
import Foundation
import GatherProtocol

extension FaceRepo {

    /// 复核缓存版本：只做 COUNT/MAX 聚合，不读 embedding。
    public func reviewRevision(sessionId: String) throws -> String? {
        let row = try connection.prepare("""
            SELECT
              (SELECT COUNT(*) FROM face_clusters WHERE session_id = ?1),
              (SELECT COALESCE(MAX(updated_at), '') FROM face_clusters WHERE session_id = ?1),
              (SELECT COUNT(*) FROM face_cluster_members WHERE session_id = ?1),
              (SELECT COALESCE(MAX(id), 0) FROM face_cluster_members WHERE session_id = ?1),
              (SELECT COUNT(*) FROM face_cluster_constraints WHERE session_id = ?1),
              (SELECT COALESCE(MAX(id), 0) FROM face_cluster_constraints WHERE session_id = ?1),
              (SELECT COUNT(*) FROM role_bindings WHERE session_id = ?1),
              (SELECT COALESCE(MAX(updated_at), '') FROM role_bindings WHERE session_id = ?1),
              (SELECT COUNT(*) FROM face_observations WHERE session_id = ?1),
              (SELECT COALESCE(MAX(id), 0) FROM face_observations WHERE session_id = ?1),
              (SELECT COUNT(*) FROM photos WHERE session_id = ?1),
              (SELECT COALESCE(MAX(updated_at), '') FROM photos WHERE session_id = ?1)
            """).get([.text(sessionId)])
        guard let row else { return nil }
        return row.map { $0.textValue ?? "" }.joined(separator: "|")
    }

    // MARK: - 绑定真相 / 簇写路径

    public func isClusterBound(clusterId: Int64) throws -> Bool {
        try connection.prepare(
            "SELECT 1 FROM role_bindings WHERE cluster_id = ? LIMIT 1"
        ).get([.int(clusterId)]) != nil
    }

    public func createCluster(sessionId: String, label: String) throws -> Int64 {
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO face_clusters
              (session_id, label, status, thumbnail_path, matched_person_id,
               match_confidence, created_at, updated_at)
            VALUES (?, ?, 'unbound', '', NULL, NULL, ?, ?)
            """).run([.text(sessionId), .text(label), .text(now), .text(now)])
        return connection.lastInsertRowid
    }

    public func moveClusterMembers(
        memberIds: [Int64],
        toClusterId: Int64,
        sessionId: String,
        expectedClusterId: Int64
    ) throws -> Int {
        var moved = 0
        for chunk in memberIds.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            moved += try connection.prepare("""
                UPDATE face_cluster_members SET cluster_id = ?
                WHERE id IN (\(placeholders)) AND session_id = ? AND cluster_id = ?
                """).run(
                    [.int(toClusterId)] + chunk.map { .int($0) }
                        + [.text(sessionId), .int(expectedClusterId)])
        }
        if moved > 0 {
            try touchClusters(ids: [toClusterId, expectedClusterId])
        }
        return moved
    }

    public func moveClusterMembers(
        memberIds: [Int64],
        toClusterId: Int64,
        sessionId: String
    ) throws -> Int {
        var moved = 0
        for chunk in memberIds.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            moved += try connection.prepare("""
                UPDATE face_cluster_members SET cluster_id = ?
                WHERE id IN (\(placeholders)) AND session_id = ?
                """).run([.int(toClusterId)] + chunk.map { .int($0) } + [.text(sessionId)])
        }
        return moved
    }

    public func getClusterLabels(sessionId: String) throws -> [String] {
        try connection.prepare(
            "SELECT label FROM face_clusters WHERE session_id = ? ORDER BY id"
        ).query([.text(sessionId)]).compactMap { $0[0].textValue }
    }

    public func getClusterMembersFull(clusterId: Int64) throws -> [FaceClusterMemberRecord] {
        try connection.prepare("""
            SELECT id, photo_id, bbox, confidence, observation_id
            FROM face_cluster_members WHERE cluster_id = ? ORDER BY id
            """).query([.int(clusterId)]).map { row in
                FaceClusterMemberRecord(
                    id: row[0].intValue ?? 0,
                    photoId: row[1].textValue ?? "",
                    bbox: parseBbox(row[2].textValue ?? ""),
                    confidence: row[3].doubleValue ?? 0,
                    observationId: row[4].intValue
                )
            }
    }

    public func getReviewMembers(
        sessionId: String,
        clusterIds: [Int64]
    ) throws -> [FaceReviewMemberRow] {
        guard !clusterIds.isEmpty else { return [] }
        var rows: [FaceReviewMemberRow] = []
        for chunk in clusterIds.chunked(by: 200) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let result = try connection.prepare("""
                SELECT fm.cluster_id, fc.label, fm.id, fm.photo_id, COALESCE(p.filepath,''),
                       fm.bbox, fm.confidence, fo.id, fo.embedding, fo.quality,
                       fo.face_size_px, fo.model_id, fo.model_version
                FROM face_cluster_members fm
                JOIN face_clusters fc ON fc.id = fm.cluster_id
                LEFT JOIN photos p ON p.id = fm.photo_id
                LEFT JOIN face_observations fo ON fo.id = fm.observation_id
                WHERE fm.session_id = ? AND fm.cluster_id IN (\(placeholders))
                ORDER BY fm.cluster_id, fm.id
                """).query([.text(sessionId)] + chunk.map { .int($0) })
            rows.append(contentsOf: result.map { row in
                FaceReviewMemberRow(
                    clusterId: row[0].intValue ?? 0,
                    clusterLabel: row[1].textValue ?? "",
                    memberId: row[2].intValue ?? 0,
                    photoId: row[3].textValue ?? "",
                    photoPath: row[4].textValue ?? "",
                    bbox: parseBbox(row[5].textValue ?? ""),
                    confidence: row[6].doubleValue ?? 0,
                    observationId: row[7].intValue,
                    embedding: decodeFaceFloatBlob(row[8]),
                    quality: row[9].doubleValue ?? 0,
                    faceSizePx: row[10].doubleValue ?? 0,
                    modelId: row[11].textValue ?? "",
                    modelVersion: row[12].textValue ?? ""
                )
            })
        }
        return rows
    }

    // MARK: - 约束 CRUD

    public func getConstraints(sessionId: String) throws -> [FaceClusterConstraintRow] {
        try connection.prepare("""
            SELECT id, session_id, kind, member_keys_json, peer_keys_json, created_at
            FROM face_cluster_constraints WHERE session_id = ? ORDER BY id
            """).query([.text(sessionId)]).compactMap { row in
                guard let kindRaw = row[2].textValue,
                      let kind = FaceClusterConstraintKind(rawValue: kindRaw)
                else { return nil }
                return FaceClusterConstraintRow(
                    id: row[0].intValue ?? 0,
                    sessionId: row[1].textValue ?? "",
                    kind: kind,
                    memberKeys: FaceConstraintCodec.decode(row[3].textValue ?? ""),
                    peerKeys: FaceConstraintCodec.decode(row[4].textValue ?? ""),
                    createdAt: row[5].textValue ?? ""
                )
            }
    }

    @discardableResult
    public func insertConstraint(
        sessionId: String,
        kind: FaceClusterConstraintKind,
        memberKeys: [FaceClusterConstraintKey],
        peerKeys: [FaceClusterConstraintKey]
    ) throws -> Int64 {
        let memberJSON = try FaceConstraintCodec.encode(memberKeys)
        let peerJSON = try FaceConstraintCodec.encode(peerKeys)
        _ = try connection.prepare("""
            INSERT INTO face_cluster_constraints
              (session_id, kind, member_keys_json, peer_keys_json, created_at)
            VALUES (?, ?, ?, ?, ?)
            """).run([
                .text(sessionId), .text(kind.rawValue),
                .text(memberJSON), .text(peerJSON), .text(nowISOString()),
            ])
        return connection.lastInsertRowid
    }

    public func updateConstraintKeys(
        id: Int64,
        memberKeys: [FaceClusterConstraintKey],
        peerKeys: [FaceClusterConstraintKey]
    ) throws {
        let memberJSON = try FaceConstraintCodec.encode(memberKeys)
        let peerJSON = try FaceConstraintCodec.encode(peerKeys)
        _ = try connection.prepare("""
            UPDATE face_cluster_constraints
            SET member_keys_json = ?, peer_keys_json = ?
            WHERE id = ?
            """).run([.text(memberJSON), .text(peerJSON), .int(id)])
    }

    public func deleteConstraint(id: Int64) throws {
        _ = try connection.prepare("DELETE FROM face_cluster_constraints WHERE id = ?")
            .run([.int(id)])
    }

    public func deleteConstraints(ids: [Int64]) throws {
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "DELETE FROM face_cluster_constraints WHERE id IN (\(placeholders))"
            ).run(chunk.map { .int($0) })
        }
    }

    public func deleteConstraints(sessionId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM face_cluster_constraints WHERE session_id = ?"
        ).run([.text(sessionId)])
    }

    // MARK: - 簇状态

    public func deleteEmptyUnboundClusters(ids: [Int64]) throws -> Int {
        var deleted = 0
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            deleted += try connection.prepare("""
                DELETE FROM face_clusters
                WHERE id IN (\(placeholders))
                  AND NOT EXISTS (SELECT 1 FROM face_cluster_members m WHERE m.cluster_id = face_clusters.id)
                  AND NOT EXISTS (SELECT 1 FROM role_bindings rb WHERE rb.cluster_id = face_clusters.id)
                """).run(chunk.map { .int($0) })
        }
        return deleted
    }

    public func markClustersUnbound(ids: [Int64]) throws {
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare("""
                UPDATE face_clusters
                SET status = 'unbound', matched_person_id = NULL, match_confidence = NULL, updated_at = ?
                WHERE id IN (\(placeholders))
                """).run([.text(nowISOString())] + chunk.map { .int($0) })
        }
    }

    public func touchClusters(ids: [Int64]) throws {
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "UPDATE face_clusters SET updated_at = ? WHERE id IN (\(placeholders))"
            ).run([.text(nowISOString())] + chunk.map { .int($0) })
        }
    }
}
