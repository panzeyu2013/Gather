// Tests/GatherCoreTests/Store/SimilarityStoreTests.swift
// R1：SimilarityStore 测试（结果部分端口自 SimilarityResultRepoTests；
// 聚类状态部分为新增的 Store 级直测，旧套件只通过 Service 间接覆盖）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/SimilarityStore (R1)")
struct SimilarityStoreTests {
    private func makeStore() async throws -> (SQLiteSimilarityStore, SimilarityMembershipCache, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "similarity")
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s2', 'S2', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        let cache = SimilarityMembershipCache()
        return (SQLiteSimilarityStore(database: database, membersCache: cache), cache, database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, sessionId: String = "s1", filepath: String) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, ?, ?, 'f.jpg', 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text(filepath)]
        )
    }

    // MARK: similarity_results

    @Test func replaceInsertsResultWithMembersAndGetLatestFindsIt() async throws {
        let (store, _, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", filepath: "/b.jpg")

        let resultId = try await store.replaceResult(
            sessionId: "s1",
            groupsJson: "{\"groups\":2}",
            statsJson: "{\"groupCount\":2}",
            threshold: 12,
            minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "p1", groupIndex: 0),
                SimilarityMembership(photoId: "p2", groupIndex: 1),
            ]
        )
        #expect(resultId > 0)

        let latest = try await store.latestResult(sessionId: "s1")
        #expect(latest != nil)
        #expect(latest?.id == resultId)
        #expect(latest?.paramThreshold == 12)
        #expect(latest?.paramMinGroupSize == 2)
        #expect(latest?.groupsJson == "{\"groups\":2}")
        #expect(latest?.statsJson == "{\"groupCount\":2}")
        #expect(!(latest?.createdAt.isEmpty ?? true))

        #expect(try await store.result(sessionId: "s1", threshold: 12)?.id == resultId)
        #expect(try await store.result(sessionId: "s1", threshold: 15) == nil)
    }

    @Test func replaceRemovesPreviousSessionResults() async throws {
        let (store, _, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let first = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )
        let second = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: []
        )
        #expect(second > first)

        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's1'") == 1)
        #expect(try await store.result(sessionId: "s1", threshold: 10) == nil)
        #expect(try await store.latestResult(sessionId: "s1")?.id == second)
    }

    @Test func replaceForThresholdKeepsOtherThresholds() async throws {
        let (store, _, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let t10 = try await store.replaceResultForThreshold(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )
        let t12 = try await store.replaceResultForThreshold(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: []
        )
        let t12again = try await store.replaceResultForThreshold(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: []
        )

        #expect(try await store.result(sessionId: "s1", threshold: 10)?.id == t10)
        #expect(try await store.result(sessionId: "s1", threshold: 12)?.id == t12again)
        #expect(t12 != t12again)
        #expect(try await database.scalarInt(
            "SELECT COUNT(*) FROM similarity_results WHERE session_id = 's1' AND param_threshold = 12"
        ) == 1)
    }

    @Test func getLatestExcludesPrecomputedTierRows() async throws {
        let (store, _, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await database.run(
            """
            INSERT INTO similarity_results
              (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('s1', '{}', '{"precomputed":true}', 10, 2, '2026-01-01T00:00:00.000Z')
            """
        )
        let normalId = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 14, minGroupSize: 2, memberships: []
        )

        let latest = try await store.latestResult(sessionId: "s1")
        #expect(latest?.id == normalId)
        #expect(latest?.paramThreshold == 14)
    }

    @Test func getPhotoGroupMapMapsPhotoToResultAndGroupAndCaches() async throws {
        let (store, cache, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", filepath: "/b.jpg")
        try await insertPhoto(database, id: "p3", filepath: "/c.jpg")

        let resultId = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "p1", groupIndex: 0),
                SimilarityMembership(photoId: "p2", groupIndex: 0),
                SimilarityMembership(photoId: "p3", groupIndex: 1),
            ]
        )

        let map = try await store.photoGroupMap(sessionId: "s1", resultId: resultId)
        #expect(map == ["p1": "\(resultId):0", "p2": "\(resultId):0", "p3": "\(resultId):1"])

        // 未知 resultId → 空映射（也进入缓存）；命中返回相同内容。
        #expect(try await store.photoGroupMap(sessionId: "s1", resultId: 999).isEmpty)
        #expect(try await store.photoGroupMap(sessionId: "s1", resultId: resultId) == map)
        #expect(await cache.count == 2)
    }

    @Test func replaceInvalidatesCachedMapsForSession() async throws {
        let (store, cache, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", filepath: "/b.jpg")

        let oldId = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 10, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0)]
        )
        _ = try await store.photoGroupMap(sessionId: "s1", resultId: oldId)
        _ = try await store.photoGroupMap(sessionId: "s2", resultId: 1)
        #expect(await cache.count == 2)

        // replace 使 s1 的缓存失效；s2 的缓存保留。
        let newId = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p2", groupIndex: 0)]
        )
        #expect(newId != oldId)
        #expect(await cache.count == 1)
        #expect(try await store.photoGroupMap(sessionId: "s1", resultId: newId) == ["p2": "\(newId):0"])
    }

    @Test func getGroupMembersJoinsPhotosAndOrdersByRowid() async throws {
        let (store, _, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", filepath: "/b.jpg")
        try await insertPhoto(database, id: "p3", filepath: "/c.jpg")

        let resultId = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "p2", groupIndex: 1),
                SimilarityMembership(photoId: "p1", groupIndex: 0),
                SimilarityMembership(photoId: "p3", groupIndex: 0),
            ]
        )

        let members = try await store.groupMembers(sessionId: "s1", resultId: resultId)
        #expect(members?.count == 3)
        // ORDER BY m.rowid：保持成员表写入顺序。
        #expect(members?[0] == SimilarityMember(groupIndex: 1, photoId: "p2", filepath: "/b.jpg"))
        #expect(members?[1] == SimilarityMember(groupIndex: 0, photoId: "p1", filepath: "/a.jpg"))
        #expect(members?[2] == SimilarityMember(groupIndex: 0, photoId: "p3", filepath: "/c.jpg"))

        let emptyResultId = try await store.replaceResult(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 20, minGroupSize: 2, memberships: []
        )
        #expect(try await store.groupMembers(sessionId: "s1", resultId: emptyResultId) == nil)
    }

    // MARK: cluster state

    @Test func clusterStateRoundTripsThroughSnapshot() async throws {
        let (store, _, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        #expect(try await store.loadClusterSnapshot(sessionId: "s1") == nil)

        let state = ClusterState(
            components: [["a", "b"], ["c"]],
            groups: [["a", "b"]],
            hashes: ["a": "h1", "b": "h2", "c": "h3"]
        )
        try await store.replaceClusterState(
            sessionId: "s1",
            threshold: 12,
            minGroupSize: 2,
            groupingMode: "global",
            version: 3,
            incrementalUpdates: 1,
            state: state
        )

        let snapshot = try await store.loadClusterSnapshot(sessionId: "s1")
        #expect(snapshot != nil)
        #expect(snapshot?.meta.paramThreshold == 12)
        #expect(snapshot?.meta.paramMinGroupSize == 2)
        #expect(snapshot?.meta.groupingMode == "global")
        #expect(snapshot?.meta.memberCount == 3)
        #expect(snapshot?.meta.version == 3)
        #expect(snapshot?.meta.incrementalUpdates == 1)
        #expect(snapshot?.meta.updatedAt.isEmpty == false)
        #expect(snapshot?.rows.count == 3)
        #expect(snapshot?.state == state)
    }

    @Test func clusterSnapshotMatchesOnlyWhenAllParamsEqual() async throws {
        let (store, _, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.replaceClusterState(
            sessionId: "s1", threshold: 12, minGroupSize: 2, groupingMode: "global", version: 1,
            incrementalUpdates: 0,
            state: ClusterState(components: [["a"]], groups: [], hashes: ["a": "h"])
        )
        let snapshot = try #require(try await store.loadClusterSnapshot(sessionId: "s1"))
        #expect(snapshot.matches(threshold: 12, minGroupSize: 2, groupingMode: "global"))
        #expect(!snapshot.matches(threshold: 13, minGroupSize: 2, groupingMode: "global"))
        #expect(!snapshot.matches(threshold: 12, minGroupSize: 3, groupingMode: "global"))
        #expect(!snapshot.matches(threshold: 12, minGroupSize: 2, groupingMode: "perComponent"))
    }

    @Test func clusterStateReplaceOverwritesAndDeleteRemoves() async throws {
        let (store, _, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.replaceClusterState(
            sessionId: "s1", threshold: 10, minGroupSize: 2, groupingMode: "global", version: 1,
            incrementalUpdates: 0,
            state: ClusterState(components: [["a"], ["b"]], groups: [], hashes: ["a": "h1", "b": "h2"])
        )
        try await store.replaceClusterState(
            sessionId: "s1", threshold: 11, minGroupSize: 3, groupingMode: "perComponent", version: 2,
            incrementalUpdates: 5,
            state: ClusterState(components: [["a", "b"]], groups: [["a", "b"]], hashes: ["a": "h1", "b": "h3"])
        )

        let snapshot = try #require(try await store.loadClusterSnapshot(sessionId: "s1"))
        #expect(snapshot.meta.version == 2)
        #expect(snapshot.meta.incrementalUpdates == 5)
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.state.hashes["b"] == "h3")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_cluster_state WHERE session_id = 's1'") == 2)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_cluster_meta WHERE session_id = 's1'") == 1)

        try await store.deleteClusterState(sessionId: "s1")
        #expect(try await store.loadClusterSnapshot(sessionId: "s1") == nil)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_cluster_state WHERE session_id = 's1'") == 0)
    }
}
