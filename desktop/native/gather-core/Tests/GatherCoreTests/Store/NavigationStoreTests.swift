// Tests/GatherCoreTests/Store/NavigationStoreTests.swift
// R1：NavigationStore 测试（navigation_groups CRUD/替换 + 拍摄行查询）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/NavigationStore (R1)")
struct NavigationStoreTests {
    private func makeStore() async throws -> (SQLiteNavigationStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "navigation")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        // navigation_groups.lead_photo_id 有 FK，且这些占位照片放在 s2 且为 missing，
        // 不参与 s1 的拍摄行查询。
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s2', 'GFK', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        for index in 1...8 {
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
                VALUES (?, 's2', ?, ?, 'missing', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text("gfk\(index)"), .text("/gfk/\(index).jpg"), .text("gfk\(index).jpg")]
            )
        }
        return (SQLiteNavigationStore(database: database), database, path)
    }

    private func insertGroup(
        _ store: SQLiteNavigationStore,
        id: String,
        type: String,
        photoIds: [String],
        source: String,
        fingerprint: String = ""
    ) async throws {
        try await store.insertGroup(
            sessionId: "s1",
            group: NavigationGroupInsert(
                id: id,
                groupType: type,
                photoIdsJSON: SQLiteNavigationStore.photoIDsJSON(photoIds),
                leadPhotoId: photoIds.first,
                explanation: "\(type)-\(source)",
                source: source,
                fingerprint: fingerprint
            )
        )
    }

    @Test func insertListAndFingerprint() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertGroup(store, id: "g2", type: "scene", photoIds: ["gfk2", "gfk3"], source: "automatic", fingerprint: "fp-1")
        try await insertGroup(store, id: "g1", type: "burst", photoIds: ["gfk1", "gfk2"], source: "manual")
        try await insertGroup(store, id: "g3", type: "burst", photoIds: ["gfk3", "gfk4"], source: "automatic", fingerprint: "fp-1")

        let all = try await store.groups(sessionId: "s1")
        #expect(all.map(\.id) == ["g1", "g3", "g2"], "ORDER BY group_type, created_at, id")
        #expect(all[0].groupType == "burst")
        #expect(all[0].photoIds == ["gfk1", "gfk2"])
        #expect(all[0].leadPhotoId == "gfk1")
        #expect(all[0].source == "manual")
        #expect(all[2].photoIds == ["gfk2", "gfk3"])

        #expect(try await store.manualGroups(sessionId: "s1").map(\.id) == ["g1"])
        #expect(try await store.cachedFingerprint(sessionId: "s1") == "fp-1")
        #expect(try await store.groups(sessionId: "other").isEmpty)
    }

    @Test func deleteGroupAndDeleteGroups() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertGroup(store, id: "g1", type: "burst", photoIds: ["gfk1", "gfk2"], source: "manual")
        try await insertGroup(store, id: "g2", type: "burst", photoIds: ["gfk3", "gfk4"], source: "manual")
        try await insertGroup(store, id: "g3", type: "scene", photoIds: ["gfk5", "gfk6"], source: "manual")

        try await store.deleteGroup(sessionId: "s1", id: "g1")
        #expect(try await store.groups(sessionId: "s1").map(\.id) == ["g2", "g3"])
        try await store.deleteGroup(sessionId: "other", id: "g2")
        #expect(try await store.groups(sessionId: "s1").count == 2, "会话不匹配不删除")

        try await store.deleteGroups(sessionId: "s1", ids: ["g2", "g3"])
        #expect(try await store.groups(sessionId: "s1").isEmpty)
        try await store.deleteGroups(sessionId: "s1", ids: [])
    }

    @Test func deleteAutomaticGroupsKeepsManual() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertGroup(store, id: "m1", type: "burst", photoIds: ["gfk1", "gfk2"], source: "manual")
        try await insertGroup(store, id: "a1", type: "burst", photoIds: ["gfk3", "gfk4"], source: "automatic", fingerprint: "fp")

        try await store.deleteAutomaticGroups(sessionId: "s1")
        #expect(try await store.groups(sessionId: "s1").map(\.id) == ["m1"])
        #expect(try await store.cachedFingerprint(sessionId: "s1") == nil)
    }

    @Test func replaceAutomaticGroupsReplacesOnlyAutomatic() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertGroup(store, id: "m1", type: "burst", photoIds: ["gfk1", "gfk2"], source: "manual")
        try await insertGroup(store, id: "a-old", type: "scene", photoIds: ["gfk3", "gfk4"], source: "automatic", fingerprint: "old")

        try await store.replaceAutomaticGroups(
            sessionId: "s1",
            groups: [
                NavigationGroupInsert(
                    id: "a-new-1", groupType: "burst", photoIdsJSON: SQLiteNavigationStore.photoIDsJSON(["gfk1", "gfk5"]),
                    leadPhotoId: "gfk5", explanation: "e1", source: "automatic", fingerprint: ""
                ),
                NavigationGroupInsert(
                    id: "a-new-2", groupType: "scene", photoIdsJSON: SQLiteNavigationStore.photoIDsJSON(["gfk6", "gfk7"]),
                    leadPhotoId: nil, explanation: "e2", source: "automatic", fingerprint: "explicit"
                ),
            ],
            fingerprint: "new-fp"
        )

        let all = try await store.groups(sessionId: "s1")
        #expect(all.map(\.id).sorted() == ["a-new-1", "a-new-2", "m1"])
        let first = try #require(all.first { $0.id == "a-new-1" })
        #expect(first.inputFingerprint == "new-fp", "空指纹用批次指纹补齐")
        #expect(first.leadPhotoId == "gfk5")
        let second = all.first { $0.id == "a-new-2" }
        #expect(second?.inputFingerprint == "explicit")
        #expect(try await store.cachedFingerprint(sessionId: "s1") == "new-fp")
    }

    @Test func captureRowsJoinsMetadataHashAndLatestQuality() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        for index in 1...3 {
            try await database.run(
                """
                INSERT INTO asset_files (id, volume_id, normalized_path, filename, created_at, updated_at)
                VALUES (?, 'dev:1', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text("f\(index)"), .text("/v/p\(index).jpg"), .text("p\(index).jpg")]
            )
        }
        for index in 1...3 {
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, status, asset_file_id, created_at, updated_at)
                VALUES (?, 's1', ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [
                    .text("p\(index)"), .text("/v/p\(index).jpg"), .text("p\(index).jpg"),
                    .text(index == 3 ? "missing" : "pending"), .text("f\(index)"),
                ]
            )
        }
        try await database.run(
            """
            INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken, camera_model, keywords, rating, cached_at)
            VALUES ('p1', 's1', '2026-02-01T10:00:00.000Z', 'Canon R5', '[]', 4, '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run(
            "INSERT INTO similarity_hashes (photo_id, session_id, hash_hex) VALUES ('p1', 's1', 'abcd')"
        )
        try await database.run(
            """
            INSERT INTO asset_analysis
              (asset_file_id, analysis_type, result_json, input_fingerprint, created_at, updated_at)
            VALUES ('f1', 'technical_quality', '{"qualityScore":0.4}', 'v1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
                   ('f1', 'technical_quality', '{"qualityScore":0.9}', 'v2', '2026-01-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z'),
                   ('f2', 'technical_quality', '{"qualityScore":0.5}', 'v1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )

        let rows = try await store.captureRows(sessionId: "s1")
        #expect(rows.count == 2, "missing 状态被排除")
        #expect(rows.map(\.id) == ["p2", "p1"], "ORDER BY captured_at 升序")
        let p2 = rows[0]
        let p1 = rows[1]
        #expect(p1.capturedAt == "2026-02-01T10:00:00.000Z", "date_taken 优先于 created_at")
        #expect(p1.cameraModel == "Canon R5")
        #expect(p1.hashHex == "abcd")
        #expect(p1.rating == 4)
        #expect(p1.assetFileId == "f1")
        #expect(p1.qualityJSON == "{\"qualityScore\":0.9}", "取 updated_at 最新一条")
        #expect(p2.capturedAt == "2026-01-01T00:00:00.000Z")
        #expect(p2.qualityJSON == "{\"qualityScore\":0.5}")
        #expect(p2.hashHex == "")
        #expect(p2.rating == 0)
    }
}
