// Tests/GatherCoreTests/API/PhotoCommandsImplTests.swift
// R5：photo 域命令实现直测（批次 B3）。
// 覆盖旧路由分支语义：逻辑资产折叠（成员角色 raw → camera_jpeg → 首行）、
// expandVariants 展开、limit 钳制（0 → 1）、keyset 游标翻页与末页 nil、
// 未知会话空页（nil cursor）。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/PhotoCommandsImpl (R5)")
struct PhotoCommandsImplTests {
    private struct Harness {
        let impl: PhotoCommandsImpl
        let db: SQLiteDatabase
        let path: String
    }

    private func makeHarness() async throws -> Harness {
        let path = storeTempPath("photo-commands")
        let db = try await makeMigratedStore(path: path)
        try await insertSession(db, "s1")
        let impl = PhotoCommandsImpl(
            photos: SQLitePhotoStore(database: db),
            assets: SQLiteAssetStore(database: db),
            faces: SQLiteFaceStore(database: db)
        )
        return Harness(impl: impl, db: db, path: path)
    }

    private func insertPagePhoto(
        _ db: SQLiteDatabase,
        photoId: String,
        assetId: String?,
        assetFileId: String?
    ) async throws {
        let filepath = "/vault/\(photoId).jpg"
        _ = try await db.run("""
            INSERT INTO photos
              (id, session_id, filepath, filename, checksum, status, metadata, result,
               asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, 's1', ?, ?, '', 'ready', '{}', '{}', ?, ?, 100, 80,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """, [
                .text(photoId), .text(filepath),
                .text((filepath as NSString).lastPathComponent),
                assetId.map { .text($0) } ?? .null,
                assetFileId.map { .text($0) } ?? .null,
            ])
    }

    private func seedAssetPhoto(
        _ db: SQLiteDatabase,
        photoId: String,
        assetId: String,
        assetFileId: String,
        role: String
    ) async throws {
        try await insertAssetFile(db, id: assetFileId, normalizedPath: "/vault/\(photoId).jpg")
        try await insertAsset(db, id: assetId)
        _ = try await db.run(
            "INSERT INTO asset_members (asset_id, file_id, member_role) VALUES (?, ?, ?)",
            [.text(assetId), .text(assetFileId), .text(role)]
        )
        try await insertPagePhoto(db, photoId: photoId, assetId: assetId, assetFileId: assetFileId)
    }

    private func insertFaceObservation(_ db: SQLiteDatabase, photoId: String) async throws {
        _ = try await db.run("""
            INSERT INTO face_observations
              (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding,
               confidence, source_file_size, source_file_mtime_ms, analysis_signature)
            VALUES (?, 's1', 0, 0, 1, 1, ?, 0.9, 0, 0, ?)
            """, [.text(photoId), .blob(Data([0])), .text("sig-\(photoId)")])
    }

    private func seedFourPhotos(_ harness: Harness) async throws {
        try await seedAssetPhoto(
            harness.db, photoId: "p1", assetId: "a1", assetFileId: "f1", role: "raw")
        try await seedAssetPhoto(
            harness.db, photoId: "p2", assetId: "a1", assetFileId: "f2", role: "camera_jpeg")
        try await seedAssetPhoto(
            harness.db, photoId: "p3", assetId: "a2", assetFileId: "f3", role: "raw")
        try await insertPagePhoto(harness.db, photoId: "p4", assetId: nil, assetFileId: nil)
    }

    @Test("listPage folds variants by member role and carries face counts")
    func listPageFoldsVariants() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await seedFourPhotos(harness)
        try await insertFaceObservation(harness.db, photoId: "p1")

        let page = try await harness.impl.listPage(
            sessionId: "s1", afterFirstRowid: nil, limit: nil, expandVariants: false)

        #expect(page.rows.count == 3)
        let folded = try #require(page.rows.first { $0.id == "p1" })
        #expect(folded.variantCount == 2)
        #expect(folded.variants?.map(\.photoId) == ["p1", "p2"])
        #expect(folded.variants?.first { $0.photoId == "p2" }?.role == "camera_jpeg")
        #expect(folded.faceCount == 1)
        #expect(!folded.hasExistingXmp)
        #expect(folded.metadata.isEmpty)
        #expect(folded.result.isEmpty)
        #expect(page.cursor != nil)
    }

    @Test("listPage expands variants, clamps limit to 1 and pages by cursor")
    func listPageExpandsAndPages() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await seedFourPhotos(harness)

        let expanded = try await harness.impl.listPage(
            sessionId: "s1", afterFirstRowid: nil, limit: nil, expandVariants: true)
        #expect(expanded.rows.map(\.id) == ["p1", "p2", "p3", "p4"])

        // limit 0 → 旧 clampedLimit 钳制为 1：只返回一个逻辑组。
        let first = try await harness.impl.listPage(
            sessionId: "s1", afterFirstRowid: nil, limit: 0, expandVariants: false)
        #expect(first.rows.map(\.id) == ["p1"])
        let cursor = try #require(first.cursor)

        let second = try await harness.impl.listPage(
            sessionId: "s1", afterFirstRowid: cursor, limit: nil, expandVariants: false)
        #expect(second.rows.map(\.id) == ["p3", "p4"])
        let secondCursor = try #require(second.cursor)

        let third = try await harness.impl.listPage(
            sessionId: "s1", afterFirstRowid: secondCursor, limit: nil, expandVariants: false)
        #expect(third.rows.isEmpty)
        #expect(third.cursor == nil)
    }

    @Test("listPage returns an empty page with a nil cursor for an unknown session")
    func listPageUnknownSession() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }

        let page = try await harness.impl.listPage(
            sessionId: "missing", afterFirstRowid: nil, limit: nil, expandVariants: false)

        #expect(page.rows.isEmpty)
        #expect(page.cursor == nil)
    }
}
