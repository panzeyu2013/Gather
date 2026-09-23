// desktop/native/gather-core/Tests/GatherCoreTests/Services/PhotoAssetResolverTests.swift
// PhotoAssetResolver 行为测试（Phase 3.2）。
// TS 源: desktop/src/main/services/assets/photo-asset-resolver.ts 的行为基线
// （asset_read_mode 三态 + resolveMany 去重/分块）。

import Foundation
import Testing
@testable import GatherCore

private struct ResolverHarness {
    let db: DBConnection
    let settings: [String: String]
}

private func makeHarness(settings: [String: String] = [:]) async throws -> ResolverHarness {
    let db = try await makeMigratedDB()
    return ResolverHarness(db: db, settings: settings)
}

/// 幂等会话种子（photos.session_id 外键）。
private func seedSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare(
        "INSERT OR IGNORE INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at) VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
    ).run([.text(id)])
}

/// 会话行 + 照片（photos.session_id 外键）。
private func seedPhoto(_ harness: ResolverHarness, id: String, sessionId: String, filepath: String) throws {
    try seedSession(harness.db, sessionId)
    try insertPhoto(harness.db, id: id, sessionId: sessionId, filepath: filepath)
}

private func makeResolver(_ harness: ResolverHarness) -> PhotoAssetResolver {
    PhotoAssetResolver(
        connection: harness.db,
        getSetting: { key, defaultValue in harness.settings[key] ?? defaultValue }
    )
}

/// 种子：照片 + 资产文件 + active sidecar binding（TS resolver 的 5 路 JOIN 数据）。
/// 会话行必须先存在（photos.session_id 外键）。
private func seedBoundAsset(
    _ db: DBConnection,
    photoId: String,
    sessionId: String,
    legacyPath: String,
    assetFileId: String,
    assetPath: String,
    xmpPath: String
) throws {
    try seedSession(db, sessionId)
    try insertAsset(db, id: assetFileId)
    try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: legacyPath)
    try insertAssetFile(db, id: assetFileId, normalizedPath: assetPath)
    _ = try db.prepare("""
        INSERT INTO sidecar_bindings (id, xmp_path, normalized_xmp_path, binding_rule, status, created_at, updated_at)
        VALUES (?, ?, ?, 'explicit', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([.text("sb-" + photoId), .text(xmpPath), .text(xmpPath)])
    _ = try db.prepare(
        "INSERT INTO sidecar_binding_files (sidecar_binding_id, file_id) VALUES (?, ?)"
    ).run([.text("sb-" + photoId), .text(assetFileId)])
    _ = try db.prepare(
        "UPDATE photos SET asset_id = ?, asset_file_id = ? WHERE id = ?"
    ).run([.text(assetFileId), .text(assetFileId), .text(photoId)])
}

@Suite("PhotoAssetResolver.resolve")
struct PhotoAssetResolverResolveTests {
    @Test("resolves to the legacy path by default when no asset linkage exists")
    func legacyDefault() async throws {
        let harness = try await makeHarness()
        try seedPhoto(harness, id: "p1", sessionId: "s1", filepath: "/shoot/a.jpg")
        let resolver = makeResolver(harness)

        let asset = try resolver.resolve(sessionId: "s1", photoId: "p1")

        #expect(asset.photoId == "p1")
        #expect(asset.sessionId == "s1")
        #expect(asset.assetId == "p1")
        #expect(asset.assetFileId == "p1")
        #expect(asset.filepath == "/shoot/a.jpg")
        #expect(asset.xmpPath == "/shoot/a.xmp")
        #expect(asset.source == "legacy")
    }

    @Test("resolves to the asset path in asset mode with a binding xmp path")
    func assetModeWithBinding() async throws {
        let harness = try await makeHarness(settings: ["asset_read_mode": "asset"])
        try seedBoundAsset(
            harness.db, photoId: "p1", sessionId: "s1",
            legacyPath: "/legacy/a.jpg", assetFileId: "af1",
            assetPath: "/vault/a.NEF", xmpPath: "/vault/a.xmp"
        )
        let resolver = makeResolver(harness)

        let asset = try resolver.resolve(sessionId: "s1", photoId: "p1")

        #expect(asset.assetId == "af1")
        #expect(asset.filepath == "/vault/a.NEF")
        #expect(asset.xmpPath == "/vault/a.xmp")
        #expect(asset.source == "asset")
    }

    @Test("falls back to the legacy path in asset mode without a binding xmp path")
    func assetModeWithoutBindingXmp() async throws {
        let harness = try await makeHarness(settings: ["asset_read_mode": "asset"])
        try seedPhoto(harness, id: "p1", sessionId: "s1", filepath: "/shoot/a.jpg")
        try insertAsset(harness.db, id: "af1")
        try insertAssetFile(harness.db, id: "af1", normalizedPath: "/vault/a.NEF")
        _ = try harness.db.prepare(
            "UPDATE photos SET asset_id = 'af1', asset_file_id = 'af1' WHERE id = 'p1'"
        ).run()
        let resolver = makeResolver(harness)

        let asset = try resolver.resolve(sessionId: "s1", photoId: "p1")

        // 资产就绪且无 binding 行：xmp 从资产路径推导。
        #expect(asset.filepath == "/vault/a.NEF")
        #expect(asset.xmpPath == "/vault/a.xmp")
        #expect(asset.source == "asset")
    }

    @Test("throws for a photo outside the session")
    func photoNotInSession() async throws {
        let harness = try await makeHarness()
        try seedPhoto(harness, id: "p1", sessionId: "s1", filepath: "/shoot/a.jpg")
        let resolver = makeResolver(harness)

        #expect(throws: PhotoAssetResolverError.photoNotInSession) {
            try resolver.resolve(sessionId: "s2", photoId: "p1")
        }
    }

    @Test("throws when asset mode demands a completed migration")
    func assetModeIncompleteMigration() async throws {
        let harness = try await makeHarness(settings: ["asset_read_mode": "asset"])
        // 照片无资产链接：迁移不完整。
        try seedPhoto(harness, id: "p1", sessionId: "s1", filepath: "/shoot/a.jpg")
        let resolver = makeResolver(harness)

        #expect(throws: PhotoAssetResolverError.migrationIncomplete) {
            try resolver.resolve(sessionId: "s1", photoId: "p1")
        }
    }
}

@Suite("PhotoAssetResolver.resolveMany")
struct PhotoAssetResolverResolveManyTests {
    @Test("batches reads and skips unknown photos")
    func batchesAndSkipsUnknown() async throws {
        let harness = try await makeHarness(settings: ["asset_read_mode": "asset"])
        try seedBoundAsset(
            harness.db, photoId: "p1", sessionId: "s1",
            legacyPath: "/legacy/a.jpg", assetFileId: "af1",
            assetPath: "/vault/a.NEF", xmpPath: "/vault/a.xmp"
        )
        try seedPhoto(harness, id: "p2", sessionId: "s1", filepath: "/shoot/b.jpg")
        let resolver = makeResolver(harness)

        let resolved = try resolver.resolveMany(sessionId: "s1", photoIds: ["p1", "p2", "ghost"])

        #expect(resolved.count == 1)
        #expect(resolved["p1"]?.source == "asset")
        #expect(resolved["p1"]?.filepath == "/vault/a.NEF")
        // asset 模式下迁移不完整的 p2 缺席（调用方自行兜底）。
        #expect(resolved["p2"] == nil)
        #expect(resolved["ghost"] == nil)
    }

    @Test("dedupes by photo id keeping the newest binding")
    func dedupesKeepingNewestBinding() async throws {
        let harness = try await makeHarness(settings: ["asset_read_mode": "asset"])
        try seedPhoto(harness, id: "p1", sessionId: "s1", filepath: "/legacy/a.jpg")
        try insertAsset(harness.db, id: "af1")
        try insertAssetFile(harness.db, id: "af1", normalizedPath: "/vault/a.NEF")
        _ = try harness.db.prepare(
            "UPDATE photos SET asset_id = 'af1', asset_file_id = 'af1' WHERE id = 'p1'"
        ).run()
        for (bindingId, xmp, updatedAt) in [
            ("sb-old", "/vault/stale.xmp", "2026-01-01T00:00:00.000Z"),
            ("sb-new", "/vault/fresh.xmp", "2026-02-01T00:00:00.000Z"),
        ] {
            _ = try harness.db.prepare("""
                INSERT INTO sidecar_bindings (id, xmp_path, normalized_xmp_path, binding_rule, status, created_at, updated_at)
                VALUES (?, ?, ?, 'explicit', 'active', '2026-01-01T00:00:00.000Z', ?)
              """).run([.text(bindingId), .text(xmp), .text(xmp), .text(updatedAt)])
            _ = try harness.db.prepare(
                "INSERT INTO sidecar_binding_files (sidecar_binding_id, file_id) VALUES (?, 'af1')"
            ).run([.text(bindingId)])
        }
        let resolver = makeResolver(harness)

        let resolved = try resolver.resolveMany(sessionId: "s1", photoIds: ["p1", "p1"])

        #expect(resolved.count == 1)
        #expect(resolved["p1"]?.xmpPath == "/vault/fresh.xmp")
    }

    @Test("returns empty for empty input")
    func emptyInput() async throws {
        let harness = try await makeHarness()
        let resolver = makeResolver(harness)
        let resolved = try resolver.resolveMany(sessionId: "s1", photoIds: [])
        #expect(resolved.isEmpty)
    }
}
