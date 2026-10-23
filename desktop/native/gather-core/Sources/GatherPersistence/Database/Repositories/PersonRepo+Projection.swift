// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PersonRepo+Projection.swift
// 源：PersonRepo.swift（HEAD 3fbf997）；纯拆分（会话行 + 投影维护），方法体/SQL 逐字未改。
// 访问级：connection、linkClusters(_:personId:) 为 internal（记账见 PersonRepo.swift 头部）。

import Foundation
import GatherProtocol

extension PersonRepo {
    /// 按会话对账角色绑定与人物库投影；同时把按名归属的簇补上显式链接
    /// （rename/delete 的归属判据）。
    /// WP3b-1（SessionService 下沉）：删除会话前清理 person 侧 RESTRICT/无 FK 行。
    /// 旧顺序：person_embeddings → person_photos → role_bindings（逐字保留）。
    public func deleteSessionRows(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM person_embeddings WHERE session_id = ?").run([.text(sessionId)])
        _ = try connection.prepare("DELETE FROM person_photos WHERE session_id = ?").run([.text(sessionId)])
        _ = try connection.prepare("DELETE FROM role_bindings WHERE session_id = ?").run([.text(sessionId)])
    }

    public func reconcileSession(sessionId: String) throws {
        try connection.transaction {
            let bindingRows = try connection.prepare(
                "SELECT rb.role_name, fcm.photo_id, fcm.bbox, fcm.confidence, rb.cluster_id, fc.matched_person_id FROM role_bindings rb JOIN face_cluster_members fcm ON fcm.cluster_id = rb.cluster_id JOIN face_clusters fc ON fc.id = rb.cluster_id WHERE rb.session_id = ?"
            ).query([.text(sessionId)])


            var desiredByPerson: [String: [String: (bbox: [Double], confidence: Double)]] = [:]
            for row in bindingRows {
                let roleName = row[0].textValue ?? ""
                let personId = try row[5].textValue ?? upsertByName(name: roleName)
                try linkClusters([row[4].intValue ?? 0], personId: personId)
                let photoId = row[1].textValue ?? ""
                let bbox = decodeBbox(row[2].textValue ?? "")
                let confidence = row[3].doubleValue ?? 0
                if desiredByPerson[personId] == nil {
                    desiredByPerson[personId] = [:]
                }
                desiredByPerson[personId]?[photoId] = (bbox, confidence)
            }

            var affected: Set<String> = []
            affected.formUnion(desiredByPerson.keys)
            try connection.transaction {
                _ = try connection.prepare("DELETE FROM person_embeddings WHERE session_id = ?").run([.text(sessionId)])
                _ = try connection.prepare("""
                    -- V1 person_embeddings 无 face_bbox/quality：bbox 的真相源是
                    -- face_cluster_members.bbox / person_photos.face_bbox，质量分在 face_observations。
                    INSERT OR REPLACE INTO person_embeddings
                    (person_id, embedding, photo_id, session_id, face_observation_id, created_at)
                    SELECT fc.matched_person_id, fo.embedding, fo.photo_id, fo.session_id, fo.id, ?
                    FROM face_cluster_members fcm JOIN face_clusters fc ON fc.id = fcm.cluster_id
                    JOIN role_bindings rb ON rb.cluster_id = fc.id
                    JOIN face_observations fo ON fo.id = fcm.observation_id
                    WHERE fc.session_id = ? AND fc.matched_person_id IS NOT NULL
                    """).run([.text(nowISOString()), .text(sessionId)])
            }

            let linkedRows = try connection.prepare("SELECT DISTINCT person_id FROM person_photos WHERE session_id = ?")
                .query([.text(sessionId)])
            for row in linkedRows {
                if let personId = row[0].textValue {
                    affected.insert(personId)
                }
            }
            if affected.isEmpty { return }

            let now = nowISOString()
            let insertStmt = try connection.prepare(
                "INSERT OR IGNORE INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
            )
            try connection.transaction {
                for personId in affected {
                    guard let desired = desiredByPerson[personId], !desired.isEmpty else {
                        _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ? AND session_id = ?")
                            .run([.text(personId), .text(sessionId)])
                        continue
                    }
                    let existingRows = try connection.prepare(
                        "SELECT photo_id FROM person_photos WHERE person_id = ? AND session_id = ?"
                    ).query([.text(personId), .text(sessionId)])
                    for existing in existingRows {
                        if let existingPhotoId = existing[0].textValue, desired[existingPhotoId] == nil {
                            _ = try connection.prepare(
                                "DELETE FROM person_photos WHERE person_id = ? AND session_id = ? AND photo_id = ?"
                            ).run([.text(personId), .text(sessionId), .text(existingPhotoId)])
                        }
                    }
                    for (photoId, info) in desired {
                        _ = try insertStmt.run([
                            .text(personId), .text(photoId), .text(sessionId),
                            .text(jsonString(info.bbox)), .real(info.confidence), .text(now),
                        ])
                    }
                }
            }
        }
    }

    // ─────────────────────────── 投影维护 ───────────────────────────

    /// 批量添加照片到人物（INSERT OR IGNORE，重复安全，可用于重复绑定）。
    public func addPhotos(personId: String, sessionId: String, photos: [PersonPhotoInput]) throws {
        if photos.isEmpty { return }
        let now = nowISOString()
        let stmt = try connection.prepare(
            "INSERT OR IGNORE INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for photo in photos {
                _ = try stmt.run([
                    .text(personId), .text(photo.photoId), .text(sessionId),
                    .text(jsonString(photo.faceBbox)), .real(photo.confidence), .text(now),
                ])
            }
        }
    }

    public func removePhoto(personId: String, photoId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ? AND photo_id = ?")
                .run([.text(personId), .text(photoId)])
            _ = try connection.prepare("DELETE FROM person_embeddings WHERE person_id = ? AND photo_id = ?")
                .run([.text(personId), .text(photoId)])
        }
    }

    /// 批量保存嵌入（INSERT OR REPLACE，按 face_observation_id 唯一替换）。
    public func saveEmbeddings(embeddings: [SaveEmbeddingInput]) throws {
        let now = nowISOString()
        // V1 person_embeddings 只存向量与关联键（bbox/quality 由观察与桥接表派生）。
        let stmt = try connection.prepare(
            "INSERT OR REPLACE INTO person_embeddings (person_id, embedding, photo_id, session_id, face_observation_id, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for emb in embeddings {
                _ = try stmt.run([
                    .text(emb.personId),
                    .blob(float32Data(emb.embedding)),
                    .text(emb.photoId),
                    .text(emb.sessionId),
                    emb.faceObservationId.map { .int($0) },
                    .text(now),
                ])
            }
        }
    }

    public func getAllEmbeddings(modelSpace: String? = nil) throws -> [PersonEmbeddingRef] {
        if modelSpace?.isEmpty == true { return [] }
        if let modelSpace {
            // Observation provenance is authoritative. Orphaned legacy vectors cannot enter
            // a new model's index merely because their dimensions happen to match.
            let rows = try connection.prepare("""
                SELECT pe.person_id, pe.embedding, pe.face_observation_id, fo.analysis_signature
                FROM person_embeddings pe JOIN face_observations fo ON fo.id = pe.face_observation_id
                WHERE pe.photo_id = fo.photo_id AND pe.session_id = fo.session_id
                AND (fo.quality = 0 OR fo.quality >= 0.35)
                """).query()
            return rows.filter { FaceIdentityPolicy.modelSpace(analysisSignature: $0[3].textValue ?? "") == modelSpace }
                .map { PersonEmbeddingRef(personId: $0[0].textValue ?? "",
                                         embedding: $0[1].blobValue ?? Data(), faceObservationId: $0[2].intValue) }
        }
        let rows = try connection.prepare(
            "SELECT person_id, embedding, face_observation_id FROM person_embeddings"
        ).query()
        return rows.map { row in
            PersonEmbeddingRef(
                personId: row[0].textValue ?? "",
                embedding: row[1].blobValue ?? Data(),
                faceObservationId: row[2].intValue
            )
        }
    }

    private func decodeBbox(_ raw: String) -> [Double] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Double].self, from: data) else {
            return []
        }
        return decoded
    }
}

private extension DBValue {
    var blobValue: Data? {
        if case .blob(let data) = self { return data }
        return nil
    }
}

/// TS: JSON.stringify(faceBbox)（number[]）。
private func jsonString(_ bbox: [Double]) -> String {
    guard let data = try? JSONEncoder().encode(bbox) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// TS: Buffer.from(new Float32Array(embedding).buffer) —— Float32 小端字节序。
private func float32Data(_ floats: [Float]) -> Data {
    floats.withUnsafeBytes { Data($0) }
}
