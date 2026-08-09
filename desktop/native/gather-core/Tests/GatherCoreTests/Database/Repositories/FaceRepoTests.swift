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

    @Test func saveAndGetObservations() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let ids = try repo.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1"), observation(photoId: "p2")])
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

    @Test func replaceObservationsByPhoto() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1")])
        let newIDs = try repo.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            observation(photoId: "p1", embedding: [0.1]),
            observation(photoId: "p1", embedding: [0.2]),
        ])
        #expect(newIDs.count == 2)
        let rows = try repo.getObservations("s1")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.photoId == "p1" })
    }

    @Test func deleteObservationsVariants() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1"), observation(photoId: "p2")])
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

    @Test func updateEmbedding() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let ids = try repo.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1", embedding: [0.0, 0.0])])
        try repo.updateEmbedding(observationId: ids[0], embedding: [9.9, -8.8])
        let row = try repo.getObservations("s1")[0]
        #expect(floats(from: row.embedding) == [9.9, -8.8])
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

        _ = try repo.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1")])
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

        // restoreBinding（INSERT OR REPLACE）
        try repo.restoreBinding(clusterId: 1, sessionId: "s1", roleName: "main", keywords: ["a"])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 1)
        #expect(try repo.getClusters("s1", includeMembers: true)[0].binding?.roleName == "main")
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

        try repo.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "1.jpg")
        #expect(try repo.getClusterThumbnailPath(ids[0]) == "1.jpg")
        #expect(try repo.getThumbnailPathsBySession("s1") == ["1.jpg"])

        let members = try repo.getClusterMembers(ids[0])
        #expect(members.count == 1)
        #expect(members[0].photoId == "p1")
        #expect(members[0].bbox == [1, 2, 3, 4])
        #expect(members[0].confidence == 0.5)
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
        try repo.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "\(ids[0]).jpg")
        _ = try writeTempFile(in: dir, name: "\(ids[0]).jpg")

        try repo.mergeClusters(sourceId: ids[0], targetId: ids[1])

        let clusters = try repo.getClusters("s1", includeMembers: true)
        #expect(clusters.count == 1, "源聚类成员清零后 member_count=0 被过滤")
        #expect(clusters[0].id == ids[1])
        #expect(clusters[0].memberCount == 2)
        #expect(clusters[0].members?.map(\.photoId) == ["p1", "p2"])
        #expect(clusters[0].binding == nil, "源绑定被删除")
        #expect(!FileManager.default.fileExists(atPath: dir + "/\(ids[0]).jpg"), "源缩略图文件被删除")
    }

    @Test func restoreMerge() throws {
        let (db, repo, _) = try makeClusterRepo()
        defer { db.close() }

        let ids = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
            FaceClusterInput(label: "B", members: [FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [0, 0, 1, 1], confidence: 0.9)]),
        ])
        let sourceMemberIDs = try repo.getClusters("s1", includeMembers: true)[0].members!.map(\.id)
        let binding = FaceBindingData(clusterId: String(ids[0]), roleName: "r", keywords: ["k"])
        try repo.restoreMerge(
            sourceId: ids[0],
            targetId: ids[1],
            sessionId: "s1",
            sourceMemberIds: sourceMemberIDs,
            sourceMemberCount: 1,
            sourceBinding: binding
        )
        let clusters = try repo.getClusters("s1", includeMembers: true)
        #expect(clusters.count == 2)
        #expect(clusters[0].memberCount == 1)
        #expect(clusters[1].memberCount == 1)
        #expect(clusters[0].status == "bound")
        #expect(clusters[0].binding?.keywords == ["k"])
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
        try repo.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "thumb.jpg")

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

    @Test func removeMemberFromClusterLastMemberDeletesCluster() throws {
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
        try repo.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "\(ids[0]).jpg")
        #expect(try repo.removeMemberFromCluster(clusterId: ids[0], memberId: memberIDs[1]))
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_clusters") == 0, "最后一个成员被移除后聚类删除")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM role_bindings") == 0)
        #expect(!FileManager.default.fileExists(atPath: thumb))

        #expect(!(try repo.removeMemberFromCluster(clusterId: 999, memberId: 1)), "不存在的成员返回 false")
    }
}
