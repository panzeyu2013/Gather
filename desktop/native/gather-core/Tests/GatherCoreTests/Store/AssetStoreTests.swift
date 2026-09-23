// Tests/GatherCoreTests/Store/AssetStoreTests.swift
// R1：AssetStore 只读面测试（listVolumes 端口自 AssetRepoTests；
// memberRoles / listCandidates 为 Store 级直测，变更面测试随 backfill/relink 并入后再补）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/AssetStore (R1)")
struct AssetStoreTests {
    private func makeStore() async throws -> (SQLiteAssetStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        return (SQLiteAssetStore(database: database), database, path)
    }

    private func insertAssetFile(
        _ database: SQLiteDatabase,
        id: String,
        normalizedPath: String,
        volumeId: String = "dev:1",
        online: Bool = true
    ) async throws {
        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES (?, ?, '', ?, ?, '', 'unknown', 0, 0, '', ?, '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(volumeId), .text(normalizedPath), .text((normalizedPath as NSString).lastPathComponent), .text(online ? "online" : "offline")]
        )
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, assetFileId: String?) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, asset_file_id, created_at, updated_at)
            VALUES (?, 's1', ?, ?, 'pending', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text("/photos/\(id).jpg"), .text("\(id).jpg"), assetFileId.map { SQLiteValue.text($0) } ?? .null]
        )
    }

    @Test func listVolumesGroupsByVolume() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertAssetFile(database, id: "f1", normalizedPath: "/Volumes/SSD/a.jpg")
        try await insertAssetFile(database, id: "f2", normalizedPath: "/Volumes/SSD/b.jpg")
        try await insertAssetFile(database, id: "f3", normalizedPath: "/Volumes/HDD/c.jpg", volumeId: "dev:2", online: false)

        let volumes = try await store.listVolumes()
        #expect(volumes.count == 2)
        let ssd = volumes.first { $0.volumeId == "dev:1" }
        #expect(ssd?.roots == ["/Volumes/SSD"])
        #expect(ssd?.onlineFiles == 2)
        #expect(ssd?.offlineFiles == 0)
        let hdd = volumes.first { $0.volumeId == "dev:2" }
        #expect(hdd?.roots == ["/Volumes/HDD"])
        #expect(hdd?.offlineFiles == 1)
    }

    @Test func memberRolesMapsKnownAndUnknown() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertAssetFile(database, id: "f1", normalizedPath: "/Volumes/SSD/a.nef")
        try await insertPhoto(database, id: "p1", assetFileId: "f1")
        try await insertPhoto(database, id: "p2", assetFileId: nil)
        try await database.run(
            "INSERT INTO assets (id, created_at, updated_at) VALUES ('a1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            "INSERT INTO asset_members (asset_id, file_id, member_role) VALUES ('a1', 'f1', 'raw')"
        )

        let roles = try await store.memberRoles(sessionId: "s1", photoIds: ["p1", "p2", "missing"])
        #expect(roles == ["p1": "raw", "p2": "unknown"])
        #expect(try await store.memberRoles(sessionId: "s1", photoIds: []).isEmpty)
    }

    @Test func listCandidatesOrdersAndScopesBySession() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        for id in ["f1", "f2", "f3", "f4"] {
            try await insertAssetFile(database, id: id, normalizedPath: "/Volumes/SSD/\(id).jpg")
        }
        try await database.run(
            """
            INSERT INTO asset_link_candidates
              (id, left_file_id, right_file_id, relation_type, confidence, evidence_json, status, created_at, updated_at)
            VALUES ('c1', 'f1', 'f2', 'raw_jpeg', 0.85, '{"unambiguous":true}', 'pending',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run(
            """
            INSERT INTO asset_link_candidates
              (id, left_file_id, right_file_id, relation_type, confidence, evidence_json, status, created_at, updated_at)
            VALUES ('c2', 'f3', 'f4', 'raw_jpeg', 1.0, '{}', 'accepted',
                    '2026-01-02T00:00:00.000Z', '2026-01-02T00:00:00.000Z')
            """
        )
        // s1 通过 asset_members/session_assets 关联到 f1。
        try await database.run(
            "INSERT INTO assets (id, created_at, updated_at) VALUES ('a1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        try await database.run("INSERT INTO asset_members (asset_id, file_id, member_role) VALUES ('a1', 'f1', 'raw')")
        try await database.run(
            "INSERT INTO session_assets (session_id, asset_id, added_at) VALUES ('s1', 'a1', '2026-01-01T00:00:00.000Z')"
        )

        let all = try await store.listCandidates()
        #expect(all.count == 2)
        #expect(all[0].status == .pending, "pending 排在最前")
        #expect(all[0].confidence == 0.85)
        #expect(all[0].leftPath.hasSuffix("f1.jpg"))
        #expect(all[0].rightPath.hasSuffix("f2.jpg"))
        #expect(all[0].evidence["unambiguous"] == .bool(true))
        #expect(all[1].status == .accepted)

        let scoped = try await store.listCandidates(sessionId: "s1")
        #expect(scoped.count == 1)
        #expect(scoped[0].id == "c1")
        #expect(try await store.listCandidates(sessionId: "other").isEmpty)
    }

    @Test func assetFileDecodesExtensionColumn() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES ('f1', 'dev:1', 'ino:42', '/Volumes/SSD/a.nef', 'a.nef', '.nef', 'raw',
                    1024, 1700000000123.5, 'abc', 'online', '2026-01-01T00:00:00.000Z',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        let record = try await store.assetFile(id: "f1")
        #expect(record?.fileExtension == ".nef")
        #expect(record?.mediaType == "raw")
        #expect(record?.fileSize == 1024)
        #expect(record?.fileMtimeMs == 1700000000123.5)
        #expect(record?.fileIdentity == "ino:42")
        #expect(try await store.assetFile(id: "missing") == nil)
    }
}
