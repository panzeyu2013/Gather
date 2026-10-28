// desktop/native/gather-core/Tests/GatherCoreTests/Services/SessionServiceTests.swift
// SessionService 行为测试（Phase 3.2）。
// TS 源: tests/unit/services/session-create-from-directory.test.ts +
// tests/unit/services/session/session-add-photos-seq.test.ts（用例逐一对应，
// 另补路径工具纯函数与删除/查询用例）。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

private struct SessionHarness {
    let db: DBConnection
    let service: SessionService
    let sessionRepo: SessionRepo
    let tempDirs: [String]
}

private func makeHarness(
    dimensions: @escaping (String) throws -> (width: Int, height: Int) = { _ in (100, 80) }
) throws -> SessionHarness {
    let db = try makeTestDB()
    let sessionRepo = SessionRepo(connection: db)
    let service = SessionService(
        sessionRepo: sessionRepo,
        photoRepo: PhotoRepo(connection: db),
        faceRepo: FaceRepo(connection: db),
        connection: db,
        dimensionsProvider: dimensions
    )
    return SessionHarness(db: db, service: service, sessionRepo: sessionRepo, tempDirs: [])
}

/// TS: addOkAnalysisRun。
private func addOkAnalysisRun(_ db: DBConnection, _ sessionId: String, indexSeq: Int) throws {
    let timestamp = nowISOString()
    _ = try db.prepare("""
        INSERT INTO analysis_runs (
          session_id, kind, photo_count, index_seq, started_at, finished_at,
          params_json, status
        ) VALUES (?, 'similarity', 0, ?, ?, ?, '{}', 'ok')
      """).run([.text(sessionId), .int(Int64(indexSeq)), .text(timestamp), .text(timestamp)])
}

@Suite("SessionService.createFromDirectory (one-hop import)")
struct SessionServiceCreateFromDirectoryTests {
    @Test("creates a local session row with source_path and inserts no photos")
    func createsLocalSessionRow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeTempFile(in: dir, name: "a.jpg")
        try writeTempFile(in: dir, name: "b.jpg")

        let harness = try makeHarness()
        let session = try harness.service.createFromDirectory(name: "Wedding", sourcePath: dir)

        #expect(session.name == "Wedding")
        // V1 已删 sessions.import_source 且无替代列（schema-v1-draft 删列表）：
        // 协议字段保留但恒为空串。
        #expect(session.importSource == "")
        #expect(session.sourcePath == ScanPath.canonical(dir))
        #expect(session.photoCount == 0)
        #expect(session.truncatedImport == false)
        // 照片不在创建时插入——metadata.scan 索引 job 后台填充。
        #expect(try harness.service.getSession(session.id)?.photoCount == 0)
        #expect(try harness.service.listSessions().count == 1)
    }

    @Test("derives the session name from the directory basename when name is empty")
    func derivesNameFromBasename() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeTempFile(in: dir, name: "a.jpg")

        let harness = try makeHarness()
        let session = try harness.service.createFromDirectory(name: "   ", sourcePath: dir)

        #expect(session.name == TSPath.basename(TSPath.resolve(dir)))
    }

    @Test("rejects a non-directory path")
    func rejectsNonDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = try writeTempFile(in: dir, name: "a.jpg")

        let harness = try makeHarness()
        #expect(throws: SessionServiceError.sourceNotDir) {
            try harness.service.createFromDirectory(name: "X", sourcePath: filePath)
        }
    }

    @Test("rejects a filesystem root as the source path")
    func rejectsFilesystemRoot() throws {
        let harness = try makeHarness()
        #expect(throws: SessionServiceError.sourceRootForbidden) {
            try harness.service.createFromDirectory(name: "X", sourcePath: "/")
        }
    }
}

@Suite("SessionService.addPhotos")
struct SessionServiceAddPhotosTests {
    @Test("bumps index_seq when photos are added so a previous ok run goes stale")
    func bumpsIndexSeqOnAdd() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photoA = try writeTempFile(in: dir, name: "a.jpg")
        let photoB = try writeTempFile(in: dir, name: "b.jpg")

        let harness = try makeHarness()
        let session = try harness.sessionRepo.create(name: "Add", source: "folder", sourcePath: dir)
        // 先前 ok run 快照了加照片前的游标。
        try addOkAnalysisRun(harness.db, session.id, indexSeq: 0)

        let result = try harness.service.addPhotos(sessionId: session.id, filepaths: [photoA, photoB], source: "manual")

        #expect(result.added == 2)
        // 1.4.2: last_ok_run.index_seq (0) < session.index_seq (1) => stale。
        #expect(try harness.sessionRepo.getIndexSeq(id: session.id) == 1)
        let lastOkRun = try harness.db.prepare(
            "SELECT index_seq FROM analysis_runs WHERE session_id = ? AND status = 'ok' ORDER BY id DESC LIMIT 1"
        ).get([.text(session.id)])
        #expect(Int(lastOkRun?[0].intValue ?? -1) < (try harness.sessionRepo.getIndexSeq(id: session.id)))
    }

    @Test("photo_count 只统计工作区可见照片：归档件不计入侧栏数字")
    func photoCountExcludesArchived() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photoA = try writeTempFile(in: dir, name: "a.jpg")
        let photoB = try writeTempFile(in: dir, name: "b.jpg")
        let photoC = try writeTempFile(in: dir, name: "c.jpg")

        let harness = try makeHarness()
        let session = try harness.sessionRepo.create(name: "Count", source: "folder", sourcePath: dir)
        _ = try harness.service.addPhotos(
            sessionId: session.id, filepaths: [photoA, photoB], source: "manual")
        // 模拟淘汰移出：photos.filepath 已在事务里迁到 _rejects 并写 archived_at。
        _ = try harness.db.prepare(
            "UPDATE photos SET archived_at = ? WHERE filepath = ?"
        ).run([.text("2026-10-28T00:00:00.000Z"), .text(photoB)])

        let result = try harness.service.addPhotos(
            sessionId: session.id, filepaths: [photoC], source: "manual")
        #expect(result.added == 1)
        #expect(result.total == 2, "归档的 b 不得计入 total（物理行仍存在）")
        #expect(try harness.sessionRepo.get(id: session.id)?.photoCount == 2,
                "sessions.photo_count 必须与可见性同口径")
    }

    @Test("does NOT bump index_seq when no photos were actually added")
    func noBumpOnEmptyAdd() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photoA = try writeTempFile(in: dir, name: "a.jpg")

        let harness = try makeHarness()
        let session = try harness.sessionRepo.create(name: "Add", source: "folder", sourcePath: dir)
        try addOkAnalysisRun(harness.db, session.id, indexSeq: 0)

        let first = try harness.service.addPhotos(sessionId: session.id, filepaths: [photoA], source: "manual")
        #expect(first.added == 1)
        #expect(try harness.sessionRepo.getIndexSeq(id: session.id) == 1)

        // 重复路径插入零行：游标不得移动。
        let second = try harness.service.addPhotos(sessionId: session.id, filepaths: [photoA], source: "manual")
        #expect(second.added == 0)
        #expect(try harness.sessionRepo.getIndexSeq(id: session.id) == 1)
    }

    @Test("reports failed files and promotes draft sessions to photos_loaded")
    func failedFilesAndStatusPromotion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let goodA = try writeTempFile(in: dir, name: "a.jpg")
        let goodB = try writeTempFile(in: dir, name: "b.jpg")

        let harness = try makeHarness(
            dimensions: { path in
                if path.hasSuffix("broken.jpg") { throw SessionServiceError.sourceNotDir }
                return (100, 80)
            }
        )
        let session = try harness.sessionRepo.create(name: "Add", source: "folder")
        #expect(session.status == "draft")

        let result = try harness.service.addPhotos(
            sessionId: session.id,
            filepaths: [goodA, goodB, dir + "/broken.jpg"],
            source: "manual"
        )

        #expect(result.added == 2)
        #expect(result.failedFiles == [ScanPath.canonical(dir + "/broken.jpg")])
        #expect(result.total == 2)
        let updated = try harness.sessionRepo.get(id: session.id)
        #expect(updated?.status == "photos_loaded")
        // 导入文件绝不回填 source_path：扫描范围由调用方显式给出（历史缺陷是
        // 用这些照片的公共父目录当扫描根，把一次文件导入变成目录全树扫描）。
        #expect(updated?.sourcePath == "")
    }
}

@Suite("SessionService 删除与查询")
struct SessionServiceDeleteAndQueryTests {
    @Test("deleteSession removes the session and orphans all unbound assets")
    func deleteSessionOrphansAssets() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let service = SessionService(
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            faceRepo: FaceRepo(connection: db),
            connection: db
        )
        let session = try sessionRepo.create(name: "Del", source: "folder")
        try insertPhoto(db, id: "p1", sessionId: session.id)
        try insertAsset(db, id: "af1")
        _ = try db.prepare(
            "INSERT INTO session_assets (session_id, asset_id, added_at) VALUES (?, ?, '2026-01-01T00:00:00.000Z')"
        ).run([.text(session.id), .text("af1")])
        // 无会话引用的资产在删除时应被标记 orphan。
        try insertAsset(db, id: "af2")

        try service.deleteSession(session.id, confirmed: true)

        #expect(try sessionRepo.get(id: session.id) == nil)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(session.id)]) == 0)
        // session_assets 级联删除后，af1 失去全部会话引用，与 af2 一样成 orphan。
        let orphanStatus = try db.prepare("SELECT status FROM assets WHERE id = 'af2'").get()
        #expect(orphanStatus?[0].textValue == "orphan")
        let boundStatus = try db.prepare("SELECT status FROM assets WHERE id = 'af1'").get()
        #expect(boundStatus?[0].textValue == "orphan")
    }

    @Test("deleteSession without confirmation throws and keeps the session")
    func deleteRequiresConfirmation() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let service = SessionService(
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            faceRepo: FaceRepo(connection: db),
            connection: db
        )
        let session = try sessionRepo.create(name: "Del", source: "folder")

        #expect(throws: SessionServiceError.deleteNotConfirmed) {
            try service.deleteSession(session.id, confirmed: false)
        }
        #expect(try sessionRepo.get(id: session.id) != nil)
    }

    /// source_path 是扫描/监听作用域的唯一判据：空 = 显式文件集合作用域。
    /// getSession 绝不允许用已导入照片的公共父目录回填它——那会把一次文件导入
    /// 永久升级为对某个目录的全树扫描（历史 P0：可上溯到 home）。
    @Test("getSession never derives a source path from imported photos")
    func getSessionDoesNotDeriveSourcePath() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let service = SessionService(
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            faceRepo: FaceRepo(connection: db),
            connection: db
        )
        let session = try sessionRepo.create(name: "Derive", source: "folder")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let subA = dir + "/sub-a"
        let subB = dir + "/sub-b"
        try FileManager.default.createDirectory(atPath: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: subB, withIntermediateDirectories: true)
        try insertPhoto(db, id: "p1", sessionId: session.id, filepath: subA + "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: session.id, filepath: subB + "/b.jpg")

        let data = try service.getSession(session.id)

        #expect(data?.sourcePath == "")
        #expect(try sessionRepo.get(id: session.id)?.sourcePath == "")

        // 目录作用域的会话则保持它自己的根不变（不被照片路径改写）。
        _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
            .run([.text(ScanPath.canonical(subA)), .text(session.id)])
        let scoped = try service.getSession(session.id)
        #expect(scoped?.sourcePath == ScanPath.canonical(subA))
    }
}

@Suite("SessionService 路径工具（纯函数）")
struct SessionPathUtilityTests {
    @Test("commonParentDirectory returns the common parent and rejects the root")
    func commonParentDirectoryBehavior() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let a = root + "/shoot-a/IMG_0001.CR2"
        let b = root + "/shoot-a/IMG_0002.CR2"
        let c = root + "/shoot-b/IMG_0003.CR2"

        #expect(commonParentDirectory(filepaths: [a, b]) == ScanPath.canonical(root + "/shoot-a"))
        #expect(commonParentDirectory(filepaths: [a, c]) == ScanPath.canonical(root))
        #expect(commonParentDirectory(filepaths: [a]) == ScanPath.canonical(root + "/shoot-a"))
        #expect(commonParentDirectory(filepaths: []) == "")
        // 文件系统根不是有意义的照片源。
        #expect(commonParentDirectory(filepaths: ["/a.jpg", "/b.jpg"]) == "")
    }

    @Test("normalizeImportFilepaths trims, dedupes and resolves")
    func normalizeImportFilepathsBehavior() throws {
        #expect(normalizeImportFilepaths(["  /a/x.jpg  ", "/a/x.jpg", "", "  ", "/a/y.jpg"]) == [
            ScanPath.canonical("/a/x.jpg"), ScanPath.canonical("/a/y.jpg"),
        ])
        // trim 覆盖换行（TS String.prototype.trim 行为）。
        #expect(normalizeImportFilepaths(["\n/a/z.jpg\n"]) == [ScanPath.canonical("/a/z.jpg")])
        // 归一化口径与扫描侧逐字一致：同一个文件的词法变体（/./、//、a/../）
        // 必须收敛到同一个键，否则同一张照片会入库两行而唯一索引拦不住。
        #expect(ScanPath.canonical("/tmp/./x.jpg") == ScanPath.canonical("/tmp/x.jpg"))
        #expect(ScanPath.canonical("//tmp/x.jpg") == ScanPath.canonical("/tmp/x.jpg"))
        #expect(normalizeImportFilepaths(["/tmp/x.jpg", "/tmp/./x.jpg"]).count == 1)
        // 幂等。
        #expect(ScanPath.canonical(ScanPath.canonical("/tmp/./x.jpg")) == ScanPath.canonical("/tmp/./x.jpg"))
    }

    @Test("sanitizeSessionSourcePath only accepts the real common parent of 2+ photos")
    func sanitizeSessionSourcePathBehavior() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let a = root + "/x/IMG_0001.CR2"
        let b = root + "/x/IMG_0002.CR2"

        #expect(sanitizeSessionSourcePath(sourcePath: root + "/x", filepaths: [a, b]) == ScanPath.canonical(root + "/x"))
        // 单文件不构成有效源。
        #expect(sanitizeSessionSourcePath(sourcePath: root + "/x", filepaths: [a]) == "")
        // 根目录 / 主目录 / 祖先目录一律拒绝（递归它们 = 导入整个卷或主目录）。
        #expect(sanitizeSessionSourcePath(sourcePath: "/", filepaths: [a, b]) == "")
        #expect(sanitizeSessionSourcePath(sourcePath: NSHomeDirectory(), filepaths: [
            NSHomeDirectory() + "/a.jpg", NSHomeDirectory() + "/b.jpg",
        ]) == "")
        // 非公共父目录拒绝。
        #expect(sanitizeSessionSourcePath(sourcePath: root + "/y", filepaths: [a, b]) == "")
    }

    @Test("TSPath.resolve treats a leading tilde as a literal component like Node path.resolve")
    func resolveKeepsTildeLiteral() {
        let cwd = FileManager.default.currentDirectoryPath
        // Node path.resolve('~/foo') → cwd/~/foo（不展开家目录）。
        #expect(TSPath.resolve("~/foo") == cwd + "/~/foo")
        #expect(TSPath.resolve("~") == cwd + "/~")
        // 绝对路径中的 ~ 组件也保持字面。
        #expect(TSPath.resolve("/a/~/b") == "/a/~/b")
    }
}

@Suite("SessionServiceError 错误码映射")
struct SessionServiceErrorCodeTests {
    @Test("maps every case to its TS error code")
    func mapsToGatherCodes() {
        #expect(SessionServiceError.sourceNotDir.gatherCode == .SESSION_SOURCE_NOT_DIR)
        #expect(SessionServiceError.sourceRootForbidden.gatherCode == .SESSION_SOURCE_ROOT_FORBIDDEN)
        #expect(SessionServiceError.deleteNotConfirmed.gatherCode == .SESSION_DELETE_NOT_CONFIRMED)
        #expect(SessionServiceError.sessionNotFound.gatherCode == .SESSION_NOT_FOUND)
    }

    @Test("addPhotos survives a corrupt import_concurrency setting like TS")
    func addPhotosWithNanConcurrency() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photoA = try writeTempFile(in: dir, name: "a.jpg")

        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let service = SessionService(
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            faceRepo: FaceRepo(connection: db),
            connection: db,
            getNumber: { _, _ in .nan },
            dimensionsProvider: { _ in (100, 80) }
        )
        let session = try sessionRepo.create(name: "Add", source: "folder")

        // TS：batchSize=NaN 时循环零批次执行，不崩溃、不报错。
        let result = try service.addPhotos(sessionId: session.id, filepaths: [photoA], source: "manual")

        #expect(result.added == 0)
        #expect(result.failedFiles.isEmpty)
        #expect(try sessionRepo.getIndexSeq(id: session.id) == 0)
    }
}
