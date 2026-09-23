// Tests/GatherCoreTests/Store/FaceStoreClusterTests.swift
// R1：FaceStore 聚类/绑定测试（端口自 FaceRepoTests 后半 7 个用例）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/FaceStore clusters (R1)")
struct FaceStoreClusterTests {
    private func makeStore() async throws -> (SQLiteFaceStore, SQLiteDatabase, String, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "face-cluster")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        for id in ["p1", "p2"] {
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
                VALUES (?, 's1', ?, ?, 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(id), .text("/v/\(id).jpg"), .text("\(id).jpg")]
            )
        }
        let dir = try makeTempDir()
        return (SQLiteFaceStore(database: database, faceThumbnailDir: dir), database, path, dir)
    }

    private func member(_ photoId: String, bbox: [Double] = [0, 0, 1, 1], confidence: Double = 0.9) -> FaceClusterMemberInput {
        FaceClusterMemberInput(photoId: photoId, photoPath: "/v/\(photoId).jpg", bbox: bbox, confidence: confidence)
    }

    @Test func saveClustersAndGetClustersWithMembersAndBinding() async throws {
        let (store, database, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 100, 100], confidence: 0.9),
                FaceClusterMemberInput(photoId: "p2", photoPath: "/v/p2.jpg", bbox: [10, 10, 50, 50], confidence: 0.8),
            ]),
            FaceClusterInput(label: "B", members: [member("p2", bbox: [1, 1, 2, 2], confidence: 0.7)]),
        ])
        #expect(ids == [1, 2])

        let bare = try await store.clusters(sessionId: "s1", includeMembers: false)
        #expect(bare.count == 2)
        #expect(bare[0].label == "A")
        #expect(bare[0].memberCount == 2)
        #expect(bare[0].status == "unbound")
        #expect(bare[0].members == nil, "includeMembers=false 不加载成员")

        var withMembers = try await store.clusters(sessionId: "s1", includeMembers: true)
        #expect(withMembers[0].members?.count == 2)
        #expect(withMembers[0].members?[0].photoPath == "/v/p1.jpg")
        #expect(withMembers[0].members?[0].bbox == "[0,0,100,100]")
        #expect(withMembers[0].members?[0].confidence == 0.9)

        try await store.updateBinding(clusterId: 1, roleName: "main", keywords: ["kw1", "kw2"])
        withMembers = try await store.clusters(sessionId: "s1", includeMembers: true)
        #expect(withMembers[0].binding?.roleName == "main")
        #expect(withMembers[0].binding?.keywords == ["kw1", "kw2"])
        #expect(withMembers[0].status == "bound")

        try await store.updateBinding(clusterId: 1, roleName: "main", keywords: ["kw3"])
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM role_bindings") == 1, "更新已有绑定不新增行")
        #expect(try await store.clusters(sessionId: "s1", includeMembers: true)[0].binding?.keywords == ["kw3"])

        try await store.deleteBinding(clusterId: 1)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM role_bindings") == 0)
        #expect(try await store.clusters(sessionId: "s1", includeMembers: true)[0].status == "unbound")

        try await store.restoreBinding(clusterId: 1, sessionId: "s1", roleName: "main", keywords: ["a"])
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM role_bindings") == 1)
        #expect(try await store.clusters(sessionId: "s1", includeMembers: true)[0].binding?.roleName == "main")
    }

    @Test func clusterAccessors() async throws {
        let (store, _, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [member("p1", bbox: [1, 2, 3, 4], confidence: 0.5)]),
        ])
        #expect(try await store.clusterSessionId(clusterId: ids[0]) == "s1")
        #expect(try await store.clusterSessionId(clusterId: 999) == nil)
        #expect(try await store.clusterThumbnailPath(clusterId: ids[0]) == "")
        #expect(try await store.clusterThumbnailPath(clusterId: 999) == "")

        try await store.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "1.jpg")
        #expect(try await store.clusterThumbnailPath(clusterId: ids[0]) == "1.jpg")
        #expect(try await store.thumbnailPaths(sessionId: "s1") == ["1.jpg"])

        let members = try await store.clusterMembers(clusterId: ids[0])
        #expect(members.count == 1)
        #expect(members[0].photoId == "p1")
        #expect(members[0].bbox == [1, 2, 3, 4])
        #expect(members[0].confidence == 0.5)
    }

    @Test func mergeClustersMovesMembersAndDeletesThumbnailFile() async throws {
        let (store, _, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [member("p1")]),
            FaceClusterInput(label: "B", members: [member("p2")]),
        ])
        try await store.updateBinding(clusterId: ids[0], roleName: "r", keywords: [])
        try await store.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "\(ids[0]).jpg")
        _ = try writeTempFile(in: dir, name: "\(ids[0]).jpg")

        try await store.mergeClusters(sourceId: ids[0], targetId: ids[1])

        let clusters = try await store.clusters(sessionId: "s1", includeMembers: true)
        #expect(clusters.count == 1, "源聚类成员清零后 member_count=0 被过滤")
        #expect(clusters[0].id == ids[1])
        #expect(clusters[0].memberCount == 2)
        #expect(clusters[0].members?.map(\.photoId) == ["p1", "p2"])
        #expect(clusters[0].binding == nil, "源绑定被删除")
        #expect(!FileManager.default.fileExists(atPath: dir + "/\(ids[0]).jpg"), "源缩略图文件被删除")
    }

    @Test func restoreMerge() async throws {
        let (store, _, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [member("p1")]),
            FaceClusterInput(label: "B", members: [member("p2")]),
        ])
        let sourceMemberIDs = try await store.clusters(sessionId: "s1", includeMembers: true)[0].members!.map(\.id)
        let binding = FaceBindingData(clusterId: String(ids[0]), roleName: "r", keywords: ["k"])
        try await store.restoreMerge(
            sourceId: ids[0],
            targetId: ids[1],
            sessionId: "s1",
            sourceMemberIds: sourceMemberIDs,
            sourceMemberCount: 1,
            sourceBinding: binding
        )
        let clusters = try await store.clusters(sessionId: "s1", includeMembers: true)
        #expect(clusters.count == 2)
        #expect(clusters[0].memberCount == 1)
        #expect(clusters[1].memberCount == 1)
        #expect(clusters[0].status == "bound")
        #expect(clusters[0].binding?.keywords == ["k"])
    }

    @Test func deleteClustersBySessionClearsEverythingAndFiles() async throws {
        let (store, database, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [member("p1")]),
        ])
        try await store.updateBinding(clusterId: ids[0], roleName: "r", keywords: [])
        let thumb = try writeTempFile(in: dir, name: "thumb.jpg")
        try await store.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "thumb.jpg")

        try await store.deleteClustersBySession("s1")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_cluster_members") == 0)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM role_bindings") == 0)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_clusters") == 0)
        #expect(!FileManager.default.fileExists(atPath: thumb))
    }

    @Test func getBindingsBySession() async throws {
        let (store, _, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [member("p1")]),
            FaceClusterInput(label: "B", members: [member("p2")]),
        ])
        try await store.updateBinding(clusterId: ids[0], roleName: "r1", keywords: ["a", "b"])
        try await store.updateBinding(clusterId: ids[1], roleName: "r2", keywords: ["c"])

        let details = try await store.bindingsBySession("s1")
        #expect(details.count == 2)
        #expect(details[0].roleName == "r1")
        #expect(details[0].keywords == ["a", "b"])
        #expect(details[0].memberPhotoIds == ["p1"])
        #expect(details[1].memberPhotoIds == ["p2"])
    }

    @Test func removeMemberFromClusterLastMemberDeletesCluster() async throws {
        let (store, database, path, dir) = try await makeStore()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let ids = try await store.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [member("p1"), member("p2")]),
        ])
        try await store.updateBinding(clusterId: ids[0], roleName: "r", keywords: [])
        let memberIDs = try await store.clusters(sessionId: "s1", includeMembers: true)[0].members!.map(\.id)

        #expect(try await store.removeMemberFromCluster(clusterId: ids[0], memberId: memberIDs[0]))
        #expect(try await store.clusters(sessionId: "s1", includeMembers: false)[0].memberCount == 1)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM role_bindings") == 1, "还有成员时绑定保留")

        let thumb = try writeTempFile(in: dir, name: "\(ids[0]).jpg")
        try await store.updateClusterThumbnail(clusterId: ids[0], thumbnailPath: "\(ids[0]).jpg")
        #expect(try await store.removeMemberFromCluster(clusterId: ids[0], memberId: memberIDs[1]))
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_clusters") == 0, "最后一个成员被移除后聚类删除")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM role_bindings") == 0)
        #expect(!FileManager.default.fileExists(atPath: thumb))

        #expect(try await store.removeMemberFromCluster(clusterId: 999, memberId: 1) == false, "不存在的成员返回 false")
    }
}
