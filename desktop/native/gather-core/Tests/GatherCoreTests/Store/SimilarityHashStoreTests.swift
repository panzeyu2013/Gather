// Tests/GatherCoreTests/Store/SimilarityHashStoreTests.swift
// W2c Store 测试：SimilarityStore.hashes / hashCandidates / upsertHashes
// （原 Services/SimilarityService.swift 434/452/470/596 行内联 SQL 的 Store 化）。
// 断言重点：JOIN 字段齐全、400 分块跨块无遗漏、单事务回滚、空参数短路。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/SimilarityHashStore (W2c)")
struct SimilarityHashStoreTests {
    // MARK: - Fixtures

    private func makeStore() async throws -> (store: SQLiteSimilarityStore, database: SQLiteDatabase) {
        let database = try await makeMigratedStore(path: storeTempPath("similarity-hash"))
        try await insertSession(database, "s1")
        return (SQLiteSimilarityStore(database: database), database)
    }

    /// 带 asset_file_id 的 photos 行（asset_files 行按需插入；nil = 无资产文件）。
    private func insertAssetPhoto(
        _ database: SQLiteDatabase,
        photoId: String,
        assetFileId: String?,
        sessionId: String = "s1"
    ) async throws {
        if let assetFileId {
            // 变体（RAW/JPEG）共享同一 asset_file：已存在则复用，避免 UNIQUE(volume_id, path) 冲突。
            let exists = try await database.queryOne(
                "SELECT 1 FROM asset_files WHERE id = ?", [.text(assetFileId)]
            ) != nil
            if !exists {
                try await insertAssetFile(database, id: assetFileId, normalizedPath: "/assets/\(assetFileId).jpg")
            }
        }
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
              result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', NULL, ?, 100, 100,
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [
                .text(photoId), .text(sessionId), .text("/shoot/\(photoId).jpg"),
                .text("\(photoId).jpg"), assetFileId.map { SQLiteValue.text($0) } ?? .null,
            ]
        )
    }

    // MARK: - upsertHashes / hashes

    @Test("upsertHashes：写入后 hashes 读回全字段；同 (session,photo) 冲突为 UPDATE 非新增")
    func upsertAndReadBack() async throws {
        let (store, database) = try await makeStore()
        try await insertAssetPhoto(database, photoId: "p1", assetFileId: "af1")
        try await insertAssetPhoto(database, photoId: "p2", assetFileId: "af2")

        try await store.upsertHashes(sessionId: "s1", hashes: [
            SimilarityHashUpsert(photoId: "p1", hashHex: "aaaa", fileSize: 10, fileMtimeMs: 1_700_000_000_000),
            SimilarityHashUpsert(photoId: "p2", hashHex: "bbbb", fileSize: 20, fileMtimeMs: 1_700_000_000_500),
        ])
        let hashes = try await store.hashes(sessionId: "s1")
        #expect(hashes.count == 2)
        #expect(hashes[0].photoId == "p1")
        #expect(hashes[0].hashHex == "aaaa")
        #expect(hashes[0].fileSize == 10)
        #expect(hashes[0].fileMtimeMs == 1_700_000_000_000)
        #expect(hashes[1].photoId == "p2")

        // 冲突目标 = idx_similarity_hashes_session_photo → 更新原行。
        try await store.upsertHashes(sessionId: "s1", hashes: [
            SimilarityHashUpsert(photoId: "p1", hashHex: "cccc", fileSize: 11, fileMtimeMs: 42),
        ])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM similarity_hashes WHERE session_id = ?", [.text("s1")]) == 2)
        let updated = try #require(try await store.hashes(sessionId: "s1").first { $0.photoId == "p1" })
        #expect(updated.hashHex == "cccc")
        #expect(updated.fileSize == 11)
        #expect(updated.fileMtimeMs == 42)
    }

    @Test("hashes：空会话返回 []；空 UPSERT 为 no-op")
    func emptyInputs() async throws {
        let (store, _) = try await makeStore()
        #expect(try await store.hashes(sessionId: "s1").isEmpty)
        try await store.upsertHashes(sessionId: "s1", hashes: [])
        #expect(try await store.hashes(sessionId: "s1").isEmpty)
    }

    @Test("upsertHashes：单事务回滚（FK 失败行使整批不落库，含已执行的 UPDATE）")
    func upsertRollsBackWholeBatch() async throws {
        let (store, database) = try await makeStore()
        try await insertAssetPhoto(database, photoId: "p1", assetFileId: "af1")
        try await store.upsertHashes(sessionId: "s1", hashes: [
            SimilarityHashUpsert(photoId: "p1", hashHex: "original", fileSize: 1, fileMtimeMs: 1),
        ])

        // 第二行 photo_id 无对应 photos 行 → 外键失败；第一行的 UPDATE 必须一起回滚。
        await #expect(throws: SQLiteFailure.self) {
            try await store.upsertHashes(sessionId: "s1", hashes: [
                SimilarityHashUpsert(photoId: "p1", hashHex: "clobbered", fileSize: 9, fileMtimeMs: 9),
                SimilarityHashUpsert(photoId: "ghost", hashHex: "dddd", fileSize: 2, fileMtimeMs: 2),
            ])
        }
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM similarity_hashes") == 1)
        let kept = try #require(try await store.hashes(sessionId: "s1").first)
        #expect(kept.hashHex == "original", "部分提交：更新的行未回滚")
        #expect(kept.fileSize == 1)
    }

    // MARK: - hashCandidates

    @Test("hashCandidates：JOIN photos 字段齐全、按 asset_file_id 过滤、空参数返回 []")
    func candidatesJoinAndFilter() async throws {
        let (store, database) = try await makeStore()
        // JPEG/RAW 变体共享 asset file；p3 独立资产；p4 无资产文件。
        try await insertAssetPhoto(database, photoId: "p1", assetFileId: "af1")
        try await insertAssetPhoto(database, photoId: "p2", assetFileId: "af1")
        try await insertAssetPhoto(database, photoId: "p3", assetFileId: "af2")
        try await insertAssetPhoto(database, photoId: "p4", assetFileId: nil)
        try await store.upsertHashes(sessionId: "s1", hashes: [
            SimilarityHashUpsert(photoId: "p1", hashHex: "h1", fileSize: 100, fileMtimeMs: 1.5),
            SimilarityHashUpsert(photoId: "p2", hashHex: "h2", fileSize: 200, fileMtimeMs: 2.5),
            SimilarityHashUpsert(photoId: "p3", hashHex: "h3", fileSize: 300, fileMtimeMs: 3.5),
            SimilarityHashUpsert(photoId: "p4", hashHex: "h4", fileSize: 400, fileMtimeMs: 4.5),
        ])

        #expect(try await store.hashCandidates(assetFileIds: []).isEmpty)

        let af1 = try await store.hashCandidates(assetFileIds: ["af1"])
        #expect(af1.map(\.photoId) == ["p1", "p2"], "ORDER BY h.id，且只取共享该资产文件的行")
        #expect(af1.allSatisfy { $0.assetFileId == "af1" })
        #expect(af1[0].id > 0)
        #expect(af1[0].hashHex == "h1")
        #expect(af1[0].fileSize == 100)
        #expect(af1[0].fileMtimeMs == 1.5)

        let both = try await store.hashCandidates(assetFileIds: ["af1", "af2"])
        #expect(both.map(\.photoId) == ["p1", "p2", "p3"])
        #expect(try await store.hashCandidates(assetFileIds: ["missing"]).isEmpty)
        // 无资产文件照片（p4）永不进入候选。
        #expect(!both.contains { $0.photoId == "p4" })
    }

    @Test("hashCandidates：401 个 asset_file_id 跨 400 分块全量返回（无遗漏/重复）")
    func candidatesChunkOver400() async throws {
        let (store, database) = try await makeStore()
        let total = 401
        try await database.transaction { db in
            for index in 0..<total {
                let assetFileId = "af-\(index)"
                try db.run(
                    """
                    INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename,
                      extension, media_type, file_size, file_mtime_ms, checksum, online_status,
                      last_seen_at, created_at, updated_at)
                    VALUES (?, 'dev:1', '', ?, ?, '', 'unknown', 0, 0, '', 'online', '',
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                    """,
                    [.text(assetFileId), .text("/assets/\(assetFileId).jpg"), .text("\(assetFileId).jpg")]
                )
                try db.run(
                    """
                    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
                      result, asset_id, asset_file_id, width, height, created_at, updated_at)
                    VALUES (?, 's1', ?, ?, '', 'pending', '{}', '{}', NULL, ?, 100, 100,
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                    """,
                    [
                        .text("p-\(index)"), .text("/shoot/p-\(index).jpg"),
                        .text("p-\(index).jpg"), .text(assetFileId),
                    ]
                )
                try db.run(
                    """
                    INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
                    VALUES ('s1', ?, ?, 7, 8.5)
                    """,
                    [.text("p-\(index)"), .text("h-\(index)")]
                )
            }
        }

        let ids = (0..<total).map { "af-\($0)" }
        let candidates = try await store.hashCandidates(assetFileIds: ids)
        #expect(candidates.count == total, "400 + 1 两块必须都读到")
        #expect(Set(candidates.map(\.photoId)) == Set((0..<total).map { "p-\($0)" }))
        #expect(candidates.map(\.photoId).count == total, "跨块不得重复")
    }
}
