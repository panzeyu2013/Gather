// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/FaceRepoTests.swift
// TS 源: desktop/src/main/db/repositories/face.repo.ts

import Foundation
import Testing
@testable import GatherCore

struct FaceRepoTests {
    private func makeRepo() throws -> (DBConnection, FaceRepo) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        return (db, FaceRepo(connection: db))
    }

    private func observation(photoId: String, embedding: [Float] = [0.5, -0.25, 1.0]) -> FaceObservationInput {
        FaceObservationInput(
            photoId: photoId,
            bboxX: 1.5, bboxY: 2.5, bboxW: 100.0, bboxH: 200.0,
            embedding: embedding,
            confidence: 0.95,
            sourceFileSize: 1234,
            sourceFileMtimeMs: 1_700_000_000_123.5,
            analysisSignature: "sig-1"
        )
    }

    private func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // ─────────────────────────── 观察 ───────────────────────────

    @Test func replaceAndGetObservations() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let ids = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [observation(photoId: "p1")])
            + repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p2", observations: [observation(photoId: "p2")])
        #expect(ids == [1, 2])

        let rows = try repo.getObservations("s1")
        #expect(rows.count == 2)
        #expect(rows[0].photoId == "p1")
        #expect(rows[0].bboxX == 1.5)
        #expect(rows[0].sourceFileSize == 1234)
        #expect(rows[0].analysisSignature == "sig-1")
        #expect(rows[0].embedding.count == 12)
        #expect(floats(from: rows[0].embedding) == [0.5, -0.25, 1.0])
        #expect(rows[1].id == 2)
    }

    /// v34 六列写→读往返：显式传值逐项落库；既有调用点（走默认值）得到确定
    /// 默认值，且 embedding_dim 如实回退为 embedding.count。
    @Test func replaceAndGetObservationQualityMetadata() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            FaceObservationInput(
                photoId: "p1",
                bboxX: 1.5, bboxY: 2.5, bboxW: 100.0, bboxH: 200.0,
                embedding: [0.5, -0.25, 1.0, 0.75],
                confidence: 0.95,
                sourceFileSize: 1234,
                sourceFileMtimeMs: 1_700_000_000_123.5,
                analysisSignature: "sig-1",
                quality: 0.82,
                faceSizePx: 96.5,
                rollDegrees: -12.5,
                modelId: "vision-featureprint",
                modelVersion: "2",
                embeddingDim: 4
            ),
        ])
        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p2", observations: [
            observation(photoId: "p2", embedding: [0.1, 0.2, 0.3]),
        ])

        let rows = try repo.getObservations("s1")
        let p1 = rows.first { $0.photoId == "p1" }!
        #expect(p1.quality == 0.82)
        #expect(p1.faceSizePx == 96.5)
        #expect(p1.rollDegrees == -12.5)
        #expect(p1.modelId == "vision-featureprint")
        #expect(p1.modelVersion == "2")
        #expect(p1.embeddingDim == 4)

        let p2 = rows.first { $0.photoId == "p2" }!
        #expect(p2.quality == 0)
        #expect(p2.faceSizePx == 0)
        #expect(p2.rollDegrees == 0)
        #expect(p2.modelId == "")
        #expect(p2.modelVersion == "")
        #expect(p2.embeddingDim == 3, "默认 embeddingDim=0 时必须如实记录 embedding.count")
    }

    @Test func replaceObservationsByPhoto() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [observation(photoId: "p1")])
        let newIDs = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            observation(photoId: "p1", embedding: [0.1]),
            observation(photoId: "p1", embedding: [0.2]),
        ])
        #expect(newIDs.count == 2)
        let rows = try repo.getObservations("s1")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.photoId == "p1" })
    }

    @Test func replacingObservationsDropsTheirPersonEmbeddings() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let oldIDs = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [observation(photoId: "p1")])
        let now = "2026-01-01T00:00:00.000Z"
        _ = try db.prepare("""
            INSERT INTO persons (id, name, keywords, thumbnail_base64, notes, match_threshold, created_at, updated_at)
            VALUES ('person-1', 'Alice', '[]', '', '', 0.65, ?, ?)
            """).run([.text(now), .text(now)])
        _ = try db.prepare("""
            INSERT INTO person_embeddings (person_id, embedding, photo_id, session_id, face_observation_id,
                                           face_bbox, quality, created_at)
            VALUES ('person-1', ?, 'p1', 's1', ?, '[1,2,3,4]', 0.9, ?)
            """).run([.blob(Data([0, 0, 128, 63])), .int(oldIDs[0]), .text(now)])

        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            observation(photoId: "p1", embedding: [0.3]),
        ])

        // face_observation_id 无 FK（见 Schema 注释）：必须由调用方同事务清理，
        // 否则删除的观察仍留在匹配库里。
        #expect(try rowCount(db, "SELECT COUNT(*) FROM person_embeddings") == 0)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_observations") == 1)
    }

    @Test func deleteObservationsVariants() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [observation(photoId: "p1")])
        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p2", observations: [observation(photoId: "p2")])
        try repo.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 1, sourceFileMtimeMs: 2, analysisSignature: "s")
        try repo.upsertClusterSignature(sessionId: "s1", signature: "sig")

        try repo.deleteObservationsByPhoto(sessionId: "s1", photoId: "p1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_observations") == 1)
        try repo.deleteAnalysisStateByPhoto(sessionId: "s1", photoId: "p1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_analysis_state") == 0)

        try repo.deleteObservationsBySession("s1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_observations") == 0)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_cluster_state") == 0)
    }

    @Test func analysisStateAndClusterSignature() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(try repo.getAnalysisStates("s1").isEmpty)
        #expect(try repo.getClusterSignature("s1") == nil)

        try repo.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 100, sourceFileMtimeMs: 200.5, analysisSignature: "a")
        var states = try repo.getAnalysisStates("s1")
        #expect(states["p1"] == FaceAnalysisState(sourceFileSize: 100, sourceFileMtimeMs: 200.5, analysisSignature: "a"))

        // 重复 upsert 覆盖
        try repo.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 101, sourceFileMtimeMs: 201.5, analysisSignature: "b")
        states = try repo.getAnalysisStates("s1")
        #expect(states["p1"]?.analysisSignature == "b")
        #expect(states.count == 1)

        try repo.upsertClusterSignature(sessionId: "s1", signature: "cluster-v1")
        #expect(try repo.getClusterSignature("s1") == "cluster-v1")
        try repo.upsertClusterSignature(sessionId: "s1", signature: "cluster-v2")
        #expect(try repo.getClusterSignature("s1") == "cluster-v2")
    }

    @Test func reuseObservationsForAssetFile() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // p1/p2 共享同一 asset file
        _ = try db.prepare("""
            INSERT INTO asset_files (id, volume_id, normalized_path, filename, created_at, updated_at)
            VALUES ('f1', 'dev:1', '/v/p1.jpg', 'p1.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run()
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'f1' WHERE id IN ('p1', 'p2')").run()

        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [observation(photoId: "p1")])
        try repo.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5, analysisSignature: "sig-1")

        // 批量形式
        let batch = try repo.reuseObservationsForAssetFile(
            sessionId: "s1",
            targets: [
                FaceReuseTarget(photoId: "p2", assetFileId: "f1", sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5),
                FaceReuseTarget(photoId: "nope", assetFileId: "f1", sourceFileSize: 999, sourceFileMtimeMs: 0),
            ],
            analysisSignature: "sig-1"
        )
        #expect(batch["p2"] == ReuseResult(reused: true, faceCount: 1))
        #expect(batch["nope"] == nil, "文件状态不匹配的目标不在结果中")
        let p2Rows = try repo.getObservations("s1").filter { $0.photoId == "p2" }
        #expect(p2Rows.count == 1)
        #expect(p2Rows[0].sessionId == "s1")
        #expect(p2Rows[0].analysisSignature == "sig-1")

        // 单照片兼容形式（复用后状态仍在，重复复用会先删后拷）
        let single = try repo.reuseObservationsForAssetFile(sessionId: "s1", photoId: "p2", sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5, analysisSignature: "sig-1")
        #expect(single.reused)
        #expect(single.faceCount == 1)

        // 状态不匹配 → 不复用
        let miss = try repo.reuseObservationsForAssetFile(sessionId: "s1", photoId: "p2", sourceFileSize: 1, sourceFileMtimeMs: 1, analysisSignature: "other")
        #expect(miss.reused == false)
    }

    /// 复用同 asset file 的观察时，v34 质量/几何/模型列必须随行拷贝，
    /// 否则复用照片会静默丢失质量权重与模型版本。
    @Test func reuseObservationsForAssetFileCopiesQualityMetadata() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try db.prepare("""
            INSERT INTO asset_files (id, volume_id, normalized_path, filename, created_at, updated_at)
            VALUES ('f1', 'dev:1', '/v/p1.jpg', 'p1.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run()
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'f1' WHERE id IN ('p1', 'p2')").run()

        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            FaceObservationInput(
                photoId: "p1",
                bboxX: 1, bboxY: 2, bboxW: 30, bboxH: 40,
                embedding: [0.5, -0.25, 1.0],
                confidence: 0.9,
                sourceFileSize: 1234,
                sourceFileMtimeMs: 1_700_000_000_123.5,
                analysisSignature: "sig-1",
                quality: 0.77,
                faceSizePx: 64,
                rollDegrees: 3.5,
                modelId: "vision-featureprint",
                modelVersion: "2",
                embeddingDim: 3
            ),
        ])
        try repo.upsertAnalysisState(
            sessionId: "s1", photoId: "p1",
            sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5, analysisSignature: "sig-1"
        )

        let result = try repo.reuseObservationsForAssetFile(
            sessionId: "s1", photoId: "p2",
            sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5, analysisSignature: "sig-1"
        )
        #expect(result == ReuseResult(reused: true, faceCount: 1))

        let reused = try repo.getObservations("s1").first { $0.photoId == "p2" }!
        #expect(reused.quality == 0.77)
        #expect(reused.faceSizePx == 64)
        #expect(reused.rollDegrees == 3.5)
        #expect(reused.modelId == "vision-featureprint")
        #expect(reused.modelVersion == "2")
        #expect(reused.embeddingDim == 3)
    }

    // ─────────────────────────── 聚类 ───────────────────────────

    private func makeClusterRepo() throws -> (DBConnection, FaceRepo, String) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/v/p2.jpg")
        let dir = try makeTempDir()
        let repo = FaceRepo(connection: db, faceThumbnailDir: dir)
        return (db, repo, dir)
    }

    @Test func saveClustersAndGetClustersWithMembersAndBinding() throws {
        let (db, repo, _) = try makeClusterRepo()
        defer { db.close() }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 100, 100], confidence: 0.9),
                FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [10, 10, 50, 50], confidence: 0.8),
            ]),
            FaceClusterInput(label: "B", members: [
                FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [1, 1, 2, 2], confidence: 0.7),
            ]),
        ])
        #expect(ids == [1, 2])

        let bare = try repo.getClusters("s1")
        #expect(bare.count == 2)
        #expect(bare[0].label == "A")
        #expect(bare[0].memberCount == 2)
        #expect(bare[0].status == "unbound")
        #expect(bare[0].members == nil, "includeMembers=false 不加载成员")

        var withMembers = try repo.getClusters("s1", includeMembers: true)
        #expect(withMembers[0].members?.count == 2)
        #expect(withMembers[0].members?[0].photoPath == "/v/p1.jpg")
        #expect(withMembers[0].members?[0].bbox == "[0,0,100,100]")
        #expect(withMembers[0].members?[0].confidence == 0.9)

        // 绑定
        try repo.updateBinding(clusterId: 1, roleName: "main", keywords: ["kw1", "kw2"])
        withMembers = try repo.getClusters("s1", includeMembers: true)
        #expect(withMembers[0].binding?.roleName == "main")
        #expect(withMembers[0].binding?.keywords == ["kw1", "kw2"])
        #expect(withMembers[0].status == "bound")

        // 更新已有绑定（不新增行）
        try repo.updateBinding(clusterId: 1, roleName: "main", keywords: ["kw3"])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 1)
        withMembers = try repo.getClusters("s1", includeMembers: true)
        #expect(withMembers[0].binding?.keywords == ["kw3"])

        // 删除绑定
        try repo.deleteBinding(clusterId: 1)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 0)
        #expect(try repo.getClusters("s1", includeMembers: true)[0].status == "unbound")

    }

    @Test func clusterAccessors() throws {
        let (db, repo, _) = try makeClusterRepo()
        defer { db.close() }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [1, 2, 3, 4], confidence: 0.5)]),
        ])
        #expect(try repo.getClusterSessionId(ids[0]) == "s1")
        #expect(try repo.getClusterSessionId(999) == nil)
        #expect(try repo.getClusterThumbnailPath(ids[0]) == "")
        #expect(try repo.getClusterThumbnailPath(999) == "")

        _ = try db.prepare("UPDATE face_clusters SET thumbnail_path = '1.jpg' WHERE id = ?").run([.int(ids[0])])
        #expect(try repo.getClusterThumbnailPath(ids[0]) == "1.jpg")
        #expect(try repo.getThumbnailPathsBySession("s1") == ["1.jpg"])

        let members = try repo.getClusterMembers(ids[0])
        #expect(members.count == 1)
        #expect(members[0].photoId == "p1")
        #expect(members[0].bbox == [1, 2, 3, 4])
        #expect(members[0].confidence == 0.5)
    }

    /// 匹配读路径（getClusterMemberEmbeddings）必须带回观察行的 v34 质量元数据。
    @Test func clusterMemberEmbeddingsCarryObservationQualityMetadata() throws {
        let (db, repo, _) = try makeClusterRepo()
        defer { db.close() }

        let observationIds = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            FaceObservationInput(
                photoId: "p1",
                bboxX: 0, bboxY: 0, bboxW: 10, bboxH: 10,
                embedding: [1, 0, 0],
                confidence: 0.8,
                quality: 0.66, faceSizePx: 42, rollDegrees: -7,
                modelId: "m", modelVersion: "v1", embeddingDim: 3
            ),
        ])
        let clusterIds = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(
                    photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 10, 10],
                    confidence: 0.8, observationId: observationIds[0]
                ),
            ]),
        ])

        let embeddings = try repo.getClusterMemberEmbeddings(clusterIds[0])
        #expect(embeddings.count == 1)
        #expect(embeddings[0].quality == 0.66)
        #expect(embeddings[0].faceSizePx == 42)
        #expect(embeddings[0].rollDegrees == -7)
        #expect(embeddings[0].modelId == "m")
        #expect(embeddings[0].modelVersion == "v1")
        #expect(embeddings[0].embeddingDim == 3)
    }

    @Test func mergeClustersMovesMembersAndDeletesThumbnailFile() throws {
        let (db, repo, dir) = try makeClusterRepo()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
            FaceClusterInput(label: "B", members: [FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
        ])
        try repo.updateBinding(clusterId: ids[0], roleName: "r", keywords: [])
        _ = try db.prepare("UPDATE face_clusters SET thumbnail_path = ? WHERE id = ?").run([.text("\(ids[0]).jpg"), .int(ids[0])])
        _ = try writeTempFile(in: dir, name: "\(ids[0]).jpg")

        try repo.mergeClusters(sourceId: ids[0], targetId: ids[1])

        let clusters = try repo.getClusters("s1", includeMembers: true)
        #expect(clusters.count == 1, "源簇成员清零且无绑定 → 不出现在清单")
        #expect(clusters[0].id == ids[1])
        #expect(clusters[0].memberCount == 2)
        #expect(clusters[0].members?.map(\.photoId) == ["p1", "p2"])
        #expect(clusters[0].binding == nil, "源绑定被删除")
        #expect(!FileManager.default.fileExists(atPath: dir + "/\(ids[0]).jpg"), "源缩略图文件被删除")
    }

    @Test func deleteClustersBySessionClearsEverythingAndFiles() throws {
        let (db, repo, dir) = try makeClusterRepo()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
        ])
        try repo.updateBinding(clusterId: ids[0], roleName: "r", keywords: [])
        let thumb = try writeTempFile(in: dir, name: "thumb.jpg")
        _ = try db.prepare("UPDATE face_clusters SET thumbnail_path = 'thumb.jpg' WHERE id = ?").run([.int(ids[0])])

        try repo.deleteClustersBySession("s1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_cluster_members") == 0)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 0)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_clusters") == 0)
        #expect(!FileManager.default.fileExists(atPath: thumb))
    }

    @Test func getBindingsBySession() throws {
        let (db, repo, _) = try makeClusterRepo()
        defer { db.close() }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
            FaceClusterInput(label: "B", members: [FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
        ])
        try repo.updateBinding(clusterId: ids[0], roleName: "r1", keywords: ["a", "b"])
        try repo.updateBinding(clusterId: ids[1], roleName: "r2", keywords: ["c"])

        let details = try repo.getBindingsBySession("s1")
        #expect(details.count == 2)
        #expect(details[0].roleName == "r1")
        #expect(details[0].keywords == ["a", "b"])
        #expect(details[0].memberPhotoIds == ["p1"])
        #expect(details[1].memberPhotoIds == ["p2"])
    }

    @Test func removeMemberFromClusterKeepsOrphanBinding() throws {
        let (db, repo, dir) = try makeClusterRepo()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9),
                FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [0, 0, 1, 1], confidence: 0.9),
            ]),
        ])
        try repo.updateBinding(clusterId: ids[0], roleName: "r", keywords: [])
        let memberIDs = try repo.getClusters("s1", includeMembers: true)[0].members!.map(\.id)

        #expect(try repo.removeMemberFromCluster(clusterId: ids[0], memberId: memberIDs[0]))
        #expect(try repo.getClusters("s1")[0].memberCount == 1)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 1, "还有成员时绑定保留")

        let thumb = try writeTempFile(in: dir, name: "\(ids[0]).jpg")
        _ = try db.prepare("UPDATE face_clusters SET thumbnail_path = ? WHERE id = ?").run([.text("\(ids[0]).jpg"), .int(ids[0])])
        #expect(try repo.removeMemberFromCluster(clusterId: ids[0], memberId: memberIDs[1]))
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_clusters") == 1, "最后一个成员被移除但有绑定 → 保留孤儿绑定")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 1)
        #expect(!FileManager.default.fileExists(atPath: thumb), "成员清空后缩略图文件删除")

        // 无绑定的簇最后一个成员被移除 → 簇行删除。
        let unbound = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "B", members: [
                FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [0, 0, 1, 1], confidence: 0.8),
            ]),
        ])
        let unboundMemberId = try repo.getClusters("s1", includeMembers: true)
            .first { $0.id == unbound[0] }!.members![0].id
        #expect(try repo.removeMemberFromCluster(clusterId: unbound[0], memberId: unboundMemberId))
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_clusters WHERE id = \(unbound[0])") == 0)

        #expect(!(try repo.removeMemberFromCluster(clusterId: 999, memberId: 1)), "不存在的成员返回 false")
    }

    // ─────────────────────────── 实时计数 / 孤儿绑定 / 派生失效 ───────────────────────────

    @Test func getClustersUsesLiveMemberCountAndKeepsOrphanBinding() throws {
        let (db, repo, dir) = try makeClusterRepo()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        // 存档 member_count 被写脏（99）也不影响读取：计数来自成员表。
        _ = try db.prepare("""
            INSERT INTO face_clusters (id, session_id, label, member_count, status, thumbnail_base64, thumbnail_path)
            VALUES (5, 's1', 'stale', 99, 'unbound', '', '')
            """).run()
        _ = try db.prepare("""
            INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence)
            VALUES (5, 's1', 'p1', '[0,0,1,1]', 0.9)
            """).run()

        var rows = try repo.getClusters("s1", includeMembers: true)
        #expect(rows.count == 1)
        #expect(rows[0].memberCount == 1, "读取忽略存档 member_count")
        #expect(rows[0].members?.map(\.photoId) == ["p1"])

        // 有绑定但成员清空 → 仍是可读的孤儿绑定（解绑/XMP 清理入口）。
        try repo.updateBinding(clusterId: 5, roleName: "Alice", keywords: ["kw"])
        #expect(try repo.removeMemberFromCluster(clusterId: 5, memberId: rows[0].members![0].id))
        rows = try repo.getClusters("s1", includeMembers: true)
        #expect(rows.count == 1, "孤儿绑定不得变成读不到的幽灵")
        #expect(rows[0].memberCount == 0)
        #expect(rows[0].members?.isEmpty == true)
        #expect(rows[0].binding?.roleName == "Alice")
        #expect(try repo.getBindingsBySession("s1").count == 1)
    }

    @Test func orphanMembersStayVisibleAndInvalidationPrunesOnlyMissingPhotos() throws {
        let (db, repo, dir) = try makeClusterRepo()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        _ = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9),
            ]),
        ])
        // 模拟历史/受损库：照片行已消失的成员行（关闭 FK 才能构造）。
        _ = try db.exec("PRAGMA foreign_keys = OFF")
        _ = try db.prepare("""
            INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence)
            VALUES (1, 's1', 'ghost', '[0,0,1,1]', 0.5)
            """).run()
        _ = try db.exec("PRAGMA foreign_keys = ON")

        let before = try repo.getClusters("s1", includeMembers: true)
        #expect(before[0].memberCount == 2, "实时计数包含照片行缺失的成员")
        #expect(before[0].members?.count == 2, "成员清单不再被 JOIN 丢掉")
        #expect(before[0].members?.first { $0.photoId == "ghost" }?.photoPath == "")

        // 失效只删除照片行已消失的成员；照片仍在的成员保留（绑定的照片集合）。
        try repo.invalidateDerivedResults(sessionId: "s1", photoIds: ["p1", "ghost"])
        let after = try repo.getClusters("s1", includeMembers: true)
        #expect(after[0].members?.map(\.photoId) == ["p1"])
        #expect(after[0].memberCount == 1)
    }

    @Test func invalidateDerivedResultsPreservesUserBindings() throws {
        let (db, repo, dir) = try makeClusterRepo()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9),
            ]),
        ])
        try repo.updateBinding(clusterId: ids[0], roleName: "Alice", keywords: ["kw"])
        _ = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [observation(photoId: "p1")])
        try repo.upsertAnalysisState(
            sessionId: "s1", photoId: "p1", sourceFileSize: 1, sourceFileMtimeMs: 2, analysisSignature: "s")
        try repo.upsertClusterSignature(sessionId: "s1", signature: "0.6:2")
        let xmpPath = TSPath.xmpSidecarPath("/v/p1.jpg")
        _ = try db.prepare("""
            INSERT INTO metadata_keyword_origins (xmp_path, source, keyword, active, created_at, updated_at)
            VALUES (?, 'face-keyword', 'Alice', 1, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([.text(xmpPath)])

        try repo.invalidateDerivedResults(sessionId: "s1", photoIds: ["p1"])

        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 1, "绑定不得被销毁")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_clusters") == 1, "簇不得被销毁")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_keyword_origins WHERE active = 1") == 1, "关键词凭据不得被销毁")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_observations") == 0)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_analysis_state") == 0)
        #expect(try repo.getClusterSignature("s1") == nil, "聚类签名失效以触发重算")

        let members = try repo.getClusters("s1", includeMembers: true)[0].members ?? []
        #expect(members.map(\.photoId) == ["p1"], "照片仍在 → 绑定照片集合保留")
        #expect(members[0].observationId == nil, "观察引用被解除")
    }
}
