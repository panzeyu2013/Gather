// Tests/GatherCoreTests/API/SessionCommandsImplTests.swift
// R5：session 域命令实现直测（命令层接线首域）。
// 覆盖旧路由分支的关键语义：create 的 filepaths 导入回读、get 的
// SESSION_NOT_FOUND、update/add_photos 的结果映射与 source 缺省、
// delete* 的确认门控与计数、create_from_directory 的 scan 入队。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/SessionCommandsImpl (R5)")
struct SessionCommandsImplTests {
    /// 目录直连 harness：Runtime 与作业运行器共享同一临时库（多连接，与既有
    /// SessionRuntime/JobRunner 测试同构）；metadata.scan executor 为空壳，
    /// 只为通过运行器的「已注册类型」门控，不实际执行扫描。
    private func makeHarness(
        dimensions: @escaping (String) throws -> (width: Int, height: Int) = { _ in (100, 80) }
    ) async throws -> (impl: SessionCommandsImpl, db: SQLiteDatabase) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-session-commands-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let runtime = SessionRuntime(
            sessionStore: SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            photoStore: SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            faceStore: SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath)),
            deletionStore: SQLiteSessionDeletionStore(database: try SQLiteDatabase(path: dbPath)),
            dimensionsProvider: dimensions
        )
        let runner = JobRunner(jobStore: SQLiteJobStore(database: try SQLiteDatabase(path: dbPath)))
        await runner.registerExecutor(type: .metadataScan, executor: { _, _ in nil }, autoResume: false)
        return (SessionCommandsImpl(runtime: runtime, jobs: runner), db)
    }

    @Test("create imports filepaths, reads back the session and derives the source path")
    func createWithFilepathsImportsAndReloads() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photoA = try writeTempFile(in: dir, name: "a.jpg")
        let photoB = try writeTempFile(in: dir, name: "b.jpg")
        let (impl, _) = try await makeHarness()

        let session = try await impl.create(SessionCreateParams(name: "Import", filepaths: [photoA, photoB]))

        #expect(session.name == "Import")
        #expect(session.importSource == "manual")
        #expect(session.photoCount == 2)
        #expect(session.status == .photosLoaded)
        #expect(session.sourcePath == TSPath.resolve(dir))
        let listed = try await impl.list()
        #expect(listed.count == 1)
    }

    @Test("create without filepaths keeps a zero-photo draft session")
    func createWithoutFilepaths() async throws {
        let (impl, _) = try await makeHarness()
        let session = try await impl.create(SessionCreateParams(name: "Empty"))
        #expect(session.photoCount == 0)
        #expect(session.status == .draft)
    }

    @Test("get throws SESSION_NOT_FOUND for a missing session")
    func getMissingSessionThrows() async throws {
        let (impl, _) = try await makeHarness()
        await #expect(throws: SessionServiceError.sessionNotFound) {
            try await impl.get(SessionGetParams(sessionId: "missing"))
        }
    }

    @Test("update renames and addPhotos maps the result with the import default source")
    func updateAndAddPhotos() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let good = try writeTempFile(in: dir, name: "a.jpg")
        let (impl, _) = try await makeHarness(dimensions: { path in
            if path.hasSuffix("broken.jpg") { throw SessionServiceError.sourceNotDir }
            return (120, 90)
        })
        let session = try await impl.create(SessionCreateParams(name: "Before"))

        let updated = try await impl.update(SessionUpdateParams(sessionId: session.id, name: "After"))
        #expect(updated.name == "After")

        let result = try await impl.addPhotos(SessionAddPhotosParams(
            sessionId: session.id,
            filepaths: [good, dir + "/broken.jpg"]
        ))
        #expect(result.added == 1)
        #expect(result.failedFiles == [TSPath.resolve(dir + "/broken.jpg")])
        #expect(result.total == 1)
        let reloaded = try await impl.get(SessionGetParams(sessionId: session.id))
        #expect(reloaded.photoCount == 1)
    }

    @Test("delete* enforces the confirmed gate and deleteMany returns the removed count")
    func deleteGateAndCount() async throws {
        let (impl, _) = try await makeHarness()
        let first = try await impl.create(SessionCreateParams(name: "A"))
        let second = try await impl.create(SessionCreateParams(name: "B"))

        await #expect(throws: SessionServiceError.deleteNotConfirmed) {
            try await impl.delete(SessionDeleteParams(sessionId: first.id, confirmed: false))
        }
        await #expect(throws: SessionServiceError.deleteNotConfirmed) {
            try await impl.deleteMany(SessionDeleteManyParams(sessionIds: [first.id, second.id], confirmed: false))
        }
        let beforeDelete = try await impl.list()
        #expect(beforeDelete.count == 2)

        let removed = try await impl.deleteMany(SessionDeleteManyParams(
            sessionIds: [first.id, second.id], confirmed: true))
        #expect(removed == 2)
        let afterDelete = try await impl.list()
        #expect(afterDelete.isEmpty)
    }

    @Test("createFromDirectory enqueues a metadata.scan job for the new session")
    func createFromDirectoryEnqueuesScan() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try writeTempFile(in: dir, name: "a.jpg")
        let (impl, db) = try await makeHarness()

        let session = try await impl.createFromDirectory(
            SessionCreateFromDirectoryParams(sourcePath: dir))

        #expect(session.importSource == "local")
        #expect(session.sourcePath == TSPath.resolve(dir))
        let jobCount = try await rowCount(
            db,
            "SELECT COUNT(*) FROM analysis_jobs WHERE type = 'metadata.scan' AND scope_id = ?",
            [.text(session.id)]
        )
        #expect(jobCount == 1)
    }

    @Test("createFromDirectory rejects a non-directory and leaves no session behind")
    func createFromDirectoryRejectsNonDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = try writeTempFile(in: dir, name: "a.jpg")
        let (impl, _) = try await makeHarness()

        await #expect(throws: SessionServiceError.sourceNotDir) {
            try await impl.createFromDirectory(SessionCreateFromDirectoryParams(sourcePath: filePath))
        }
        let listed = try await impl.list()
        #expect(listed.isEmpty)
    }
}
