// Tests/GatherCoreTests/Store/InvalidatePathDependentAnalysisTests.swift
// R1 / M3：invalidatePathDependentAnalysis（旧 IndexerService.swift 797-833 + 706-793）Store 级直测。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/InvalidatePathDependentAnalysis (M3)")
struct InvalidatePathDependentAnalysisTests {
    private let now = "2026-01-01T00:00:00.000Z"

    /// 受影响会话 s1（photos p1/p2，分析行挂 p1）与无关对照组 s2（photo p3）的逐表探针。
    private static let analysisProbes: [(table: String, column: String, affected: String, control: String)] = [
        ("similarity_hashes", "session_id", "s1", "s2"),
        ("face_observations", "session_id", "s1", "s2"),
        ("face_analysis_state", "session_id", "s1", "s2"),
        ("asset_analysis", "photo_id", "p1", "p3"),
        ("photo_metadata_cache", "session_id", "s1", "s2"),
        ("face_cluster_state", "session_id", "s1", "s2"),
        ("face_clusters", "session_id", "s1", "s2"),
        ("face_cluster_members", "session_id", "s1", "s2"),
        ("role_bindings", "session_id", "s1", "s2"),
        ("similarity_results", "session_id", "s1", "s2"),
    ]

    private func makeStore() async throws -> (SQLiteAssetStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset-invalidation")
        return (SQLiteAssetStore(database: database), database, path)
    }

    private func insertAssetFile(_ database: SQLiteDatabase) async throws {
        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES ('af1', 'dev:1', '', '/Volumes/SSD/af1.jpg', 'af1.jpg', '', 'unknown',
                    0, 0, '', 'online', ?, ?, ?)
            """,
            [.text(now), .text(now), .text(now)]
        )
    }

    private func insertSession(_ database: SQLiteDatabase, id: String) async throws {
        try await database.run(
            "INSERT INTO sessions (id, created_at, updated_at) VALUES (?, ?, ?)",
            [.text(id), .text(now), .text(now)]
        )
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, sessionId: String) async throws {
        try await database.run(
            "INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id), .text(sessionId), .text("/library/\(id).jpg"), .text("\(id).jpg"), .text(now), .text(now)]
        )
    }

    /// 每张受影响照片/会话在旧实现会触碰的表里各留 1 行。
    /// asset_analysis 无 session_id，故以 photo_id 区分两行（UNIQUE 键含 input_fingerprint）。
    private func insertAnalysisRows(_ database: SQLiteDatabase, sessionId: String, photoId: String) async throws {
        try await database.run(
            "INSERT INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES (?, ?, ?)",
            [.text(sessionId), .text(photoId), .text("hash-\(photoId)")]
        )
        try await database.run(
            "INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding) VALUES (?, ?, 0, 0, 1, 1, ?)",
            [.text(photoId), .text(sessionId), .blob(Data([0]))]
        )
        try await database.run(
            "INSERT INTO face_analysis_state (photo_id, session_id, source_file_size, source_file_mtime_ms, analysis_signature, updated_at) VALUES (?, ?, 0, 0, '', ?)",
            [.text(photoId), .text(sessionId), .text(now)]
        )
        try await database.run(
            "INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, input_fingerprint, created_at, updated_at) VALUES (?, 'af1', 'quality', ?, ?, ?)",
            [.text(photoId), .text(photoId), .text(now), .text(now)]
        )
        try await database.run(
            "INSERT INTO photo_metadata_cache (photo_id, session_id, cached_at) VALUES (?, ?, ?)",
            [.text(photoId), .text(sessionId), .text(now)]
        )
        try await database.run(
            "INSERT INTO face_cluster_state (session_id, cluster_signature, updated_at) VALUES (?, ?, ?)",
            [.text(sessionId), .text("signature-\(sessionId)"), .text(now)]
        )
        try await database.run(
            "INSERT INTO face_clusters (session_id, label, created_at, updated_at) VALUES (?, ?, ?, ?)",
            [.text(sessionId), .text("cluster-\(sessionId)"), .text(now), .text(now)]
        )
        let clusterId = await database.lastInsertRowID
        try await database.run(
            "INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox) VALUES (?, ?, ?, '[]')",
            [.int(clusterId), .text(sessionId), .text(photoId)]
        )
        try await database.run(
            "INSERT INTO role_bindings (cluster_id, session_id, role_name) VALUES (?, ?, ?)",
            [.int(clusterId), .text(sessionId), .text("role-\(sessionId)")]
        )
        try await database.run(
            "INSERT INTO similarity_results (session_id, groups_json, param_threshold, created_at) VALUES (?, '[]', 5, ?)",
            [.text(sessionId), .text(now)]
        )
    }

    private func insertNavigationGroup(
        _ database: SQLiteDatabase, id: String, sessionId: String, photoId: String, source: String
    ) async throws {
        try await database.run(
            "INSERT INTO navigation_groups (id, session_id, group_type, photo_ids_json, source, created_at, updated_at) VALUES (?, ?, 'burst', ?, ?, ?, ?)",
            [.text(id), .text(sessionId), .text("[\"\(photoId)\"]"), .text(source), .text(now), .text(now)]
        )
    }

    /// 1 会话 + 2 照片（最小受影响数据）。
    private func seedAffectedSession(_ database: SQLiteDatabase) async throws {
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1")
        try await insertPhoto(database, id: "p2", sessionId: "s1")
        try await insertAnalysisRows(database, sessionId: "s1", photoId: "p1")
    }

    /// 无关会话对照组：清理必须只作用于 photoIds 命中的会话。
    private func seedControlSession(_ database: SQLiteDatabase) async throws {
        try await insertSession(database, id: "s2")
        try await insertPhoto(database, id: "p3", sessionId: "s2")
        try await insertAnalysisRows(database, sessionId: "s2", photoId: "p3")
    }

    private func count(_ database: SQLiteDatabase, table: String, column: String, value: String) async throws -> Int {
        Int(try await database.scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(column) = ?", [.text(value)]) ?? -1)
    }

    @Test func clearsAffectedSessionAndKeepsControlSession() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertAssetFile(database)
        try await seedAffectedSession(database)
        try await seedControlSession(database)
        try await insertNavigationGroup(database, id: "g-auto-s1", sessionId: "s1", photoId: "p1", source: "automatic")
        try await insertNavigationGroup(database, id: "g-manual-s1", sessionId: "s1", photoId: "p1", source: "manual")
        try await insertNavigationGroup(database, id: "g-auto-s2", sessionId: "s2", photoId: "p3", source: "automatic")

        // 前置：受影响会话与对照组在各表各 1 行。
        for probe in Self.analysisProbes {
            #expect(try await count(database, table: probe.table, column: probe.column, value: probe.affected) == 1)
            #expect(try await count(database, table: probe.table, column: probe.column, value: probe.control) == 1)
        }

        let affected = try await store.invalidatePathDependentAnalysis(photoIds: ["p1", "p2"])
        #expect(affected == 2)

        for probe in Self.analysisProbes {
            #expect(try await count(database, table: probe.table, column: probe.column, value: probe.affected) == 0, "受影响会话行未清")
            #expect(try await count(database, table: probe.table, column: probe.column, value: probe.control) == 1, "无关会话行被误删")
        }

        // 自动导航组按成员剪枝；手动组与无关会话组保留。
        #expect(try await count(database, table: "navigation_groups", column: "id", value: "g-auto-s1") == 0)
        #expect(try await count(database, table: "navigation_groups", column: "id", value: "g-manual-s1") == 1)
        #expect(try await count(database, table: "navigation_groups", column: "id", value: "g-auto-s2") == 1)

        // photos 行不受失效影响。
        #expect(try await count(database, table: "photos", column: "session_id", value: "s1") == 2)
        // 事务提交后深度归零。
        #expect(await database.currentTransactionDepth == 0)
    }

    @Test func emptyPhotoIdsReturnsZeroWithoutWrites() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertAssetFile(database)
        try await seedAffectedSession(database)
        try await insertNavigationGroup(database, id: "g-auto-s1", sessionId: "s1", photoId: "p1", source: "automatic")

        let affected = try await store.invalidatePathDependentAnalysis(photoIds: [])
        #expect(affected == 0)

        for probe in Self.analysisProbes {
            #expect(try await count(database, table: probe.table, column: probe.column, value: probe.affected) == 1, "空输入不得写库")
        }
        #expect(try await count(database, table: "navigation_groups", column: "id", value: "g-auto-s1") == 1)
        #expect(await database.currentTransactionDepth == 0)
    }
}
