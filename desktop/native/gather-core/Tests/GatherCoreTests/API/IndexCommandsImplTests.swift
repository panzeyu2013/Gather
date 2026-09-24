// Tests/GatherCoreTests/API/IndexCommandsImplTests.swift
// R5：index 域命令实现直测（批次 B3）。
// 覆盖旧路由分支语义：scan 正常落库计数（discovered/added），会话不存在
// （SESSION_NOT_FOUND）与无源目录（INDEX_SESSION_NO_SOURCE）两条错误路径。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/IndexCommandsImpl (R5)")
struct IndexCommandsImplTests {
    private struct Harness {
        let impl: IndexCommandsImpl
        let db: SQLiteDatabase
        let sessionId: String
        let root: String
        let path: String
    }

    private func makeHarness() async throws -> Harness {
        let path = storeTempPath("index-commands")
        let db = try await makeMigratedStore(path: path)
        let root = storeTempDir("index-commands-root")
        let sessions = SQLiteSessionStore(database: db)
        let session = try await sessions.create(
            name: "Index", source: "folder", sourcePath: root, truncatedImport: false)
        let runtime = IndexerRuntime(dependencies: IndexerRuntime.Dependencies(
            sessionStore: sessions,
            photoStore: SQLitePhotoStore(database: db),
            assetStore: SQLiteAssetStore(database: db),
            database: db,
            getDimensions: { _ in (100, 80) },
            getSetting: { _, defaultValue in defaultValue }
        ))
        return Harness(
            impl: IndexCommandsImpl(indexer: runtime),
            db: db, sessionId: session.id, root: root, path: path
        )
    }

    @Test("scan indexes session files and reports counts")
    func scanIndexesDirectory() async throws {
        let harness = try await makeHarness()
        defer {
            removeStoreFiles(harness.path)
            removeStoreDirectory(harness.root)
        }
        _ = try writeTempFile(in: harness.root, name: "IMG_0001.jpg")
        _ = try writeTempFile(in: harness.root, name: "notes.txt")

        let result = try await harness.impl.scan(IndexScanParams(sessionId: harness.sessionId))

        #expect(result.sessionId == harness.sessionId)
        #expect(result.discovered == 1)
        #expect(result.added == 1)
        #expect(result.skipped == 0)
        #expect(result.missing == 0)
        #expect(result.failed.isEmpty)
        #expect(try await rowCount(
            harness.db,
            "SELECT COUNT(*) FROM photos WHERE session_id = ?",
            [.text(harness.sessionId)]
        ) == 1)
    }

    @Test("scan throws SESSION_NOT_FOUND for an unknown session")
    func scanMissingSession() async throws {
        let harness = try await makeHarness()
        defer {
            removeStoreFiles(harness.path)
            removeStoreDirectory(harness.root)
        }

        await #expect(throws: IndexerError.sessionNotFound) {
            try await harness.impl.scan(IndexScanParams(sessionId: "missing"))
        }
        #expect(String(describing: IndexerError.sessionNotFound) == "SESSION_NOT_FOUND")
    }

    @Test("scan throws INDEX_SESSION_NO_SOURCE for a session without a source path")
    func scanNoSourcePath() async throws {
        let harness = try await makeHarness()
        defer {
            removeStoreFiles(harness.path)
            removeStoreDirectory(harness.root)
        }
        let empty = try await SQLiteSessionStore(database: harness.db).create(
            name: "Empty", source: "manual", sourcePath: "", truncatedImport: false)

        await #expect(throws: IndexerError.noSourcePath) {
            try await harness.impl.scan(IndexScanParams(sessionId: empty.id))
        }
        #expect(String(describing: IndexerError.noSourcePath) == "INDEX_SESSION_NO_SOURCE")
    }
}
