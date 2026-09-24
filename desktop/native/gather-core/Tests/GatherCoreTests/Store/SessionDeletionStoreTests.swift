// desktop/native/gather-core/Tests/GatherCoreTests/Store/SessionDeletionStoreTests.swift
// R4：会话删除跨域清理 Store 直测（旧 SessionService 内联语句下沉后的行为锚点）。
// 覆盖五张依赖表的会话隔离删除与无引用资产的 orphan 标记。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/SessionDeletionStore (R4)")
struct SessionDeletionStoreTests {
    private func makeStore() async throws -> (SQLiteDatabase, SQLiteSessionDeletionStore) {
        let (db, _) = try await makeMigratedStoreDatabase(label: "session-deletion")
        return (db, SQLiteSessionDeletionStore(database: db))
    }

    private func seedSession(_ db: SQLiteDatabase, id: String) async throws {
        _ = try await db.run("""
            INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
            VALUES (?, ?, 'photos_loaded', 'idle', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """, [.text(id), .text(id)])
        try await insertPhoto(db, id: "photo-\(id)", sessionId: id)
    }

    /// 在五张依赖表各写一行（analysis_jobs 用 scope_id 关联会话）。
    private func seedDependencyRows(
        _ db: SQLiteDatabase,
        sessionId: String,
        personId: String,
        photoId: String
    ) async throws {
        _ = try await db.run(
            "INSERT INTO persons (id, name, created_at, updated_at) VALUES (?, 'P', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')",
            [.text(personId)]
        )
        _ = try await db.run("""
            INSERT INTO person_embeddings (person_id, embedding, photo_id, session_id, face_bbox, created_at)
            VALUES (?, ?, ?, ?, '{}', '2026-01-01T00:00:00.000Z')
        """, [.text(personId), .blob(Data([0x00])), .text(photoId), .text(sessionId)])
        _ = try await db.run("""
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, created_at)
            VALUES (?, ?, ?, '{}', '2026-01-01T00:00:00.000Z')
        """, [.text(personId), .text(photoId), .text(sessionId)])
        _ = try await db.run(
            "INSERT INTO photo_metadata_cache (photo_id, session_id, cached_at) VALUES (?, ?, '2026-01-01T00:00:00.000Z')",
            [.text(photoId), .text(sessionId)]
        )
        _ = try await db.run(
            "INSERT INTO writeback_items (photo_id, session_id, module, created_at) VALUES (?, ?, 'metadata', '2026-01-01T00:00:00.000Z')",
            [.text(photoId), .text(sessionId)]
        )
        _ = try await db.run("""
            INSERT INTO analysis_jobs (id, type, scope_type, scope_id, dedupe_key, status, created_at, updated_at)
            VALUES (?, 'metadata.scan', 'session', ?, ?, 'queued', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """, [.text("job-\(sessionId)"), .text(sessionId), .text("metadata.scan:\(sessionId)")])
    }

    @Test("deleteSessionDependencyRows removes every scoped row and keeps other sessions intact")
    func deletesDependencyRowsScopedToSession() async throws {
        let (db, store) = try await makeStore()
        try await seedSession(db, id: "s1")
        try await seedSession(db, id: "s2")
        try await seedDependencyRows(db, sessionId: "s1", personId: "person-1", photoId: "photo-s1")
        try await seedDependencyRows(db, sessionId: "s2", personId: "person-2", photoId: "photo-s2")

        try await store.deleteSessionDependencyRows(sessionId: "s1")

        for table in ["person_embeddings", "person_photos", "photo_metadata_cache", "writeback_items"] {
            #expect(try await rowCount(db, "SELECT COUNT(*) FROM \(table) WHERE session_id = ?", [.text("s1")]) == 0)
            #expect(try await rowCount(db, "SELECT COUNT(*) FROM \(table) WHERE session_id = ?", [.text("s2")]) == 1)
        }
        #expect(try await rowCount(
            db,
            "SELECT COUNT(*) FROM analysis_jobs WHERE scope_type = 'session' AND scope_id = ?",
            [.text("s1")]
        ) == 0)
        #expect(try await rowCount(
            db,
            "SELECT COUNT(*) FROM analysis_jobs WHERE scope_type = 'session' AND scope_id = ?",
            [.text("s2")]
        ) == 1)
    }

    @Test("markOrphanAssets flips only assets without a remaining session reference")
    func marksUnboundAssets() async throws {
        let (db, store) = try await makeStore()
        try await seedSession(db, id: "s1")
        try await insertAsset(db, id: "bound")
        try await insertAsset(db, id: "unbound")
        _ = try await db.run(
            "INSERT INTO session_assets (session_id, asset_id, added_at) VALUES (?, ?, '2026-01-01T00:00:00.000Z')",
            [.text("s1"), .text("bound")]
        )

        try await store.markOrphanAssets(now: "2026-01-02T00:00:00.000Z")

        #expect(try await db.queryOne("SELECT status FROM assets WHERE id = 'bound'")?.text(at: 0) == "active")
        #expect(try await db.queryOne("SELECT status FROM assets WHERE id = 'unbound'")?.text(at: 0) == "orphan")
    }
}
