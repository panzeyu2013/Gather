// desktop/native/gather-core/Tests/GatherCoreTests/Services/IngestDedupeWave4Tests.swift
// Wave4a-F：跨会话去重失效（F1）、预检只读（F2/F3 邻接）、replace 指纹刷新（F3）、
// replace × 第二目的地（F4）、archived 不参与去重（F5）、第二副本校验（L2）、
// 预检计数与只读（L1）。全部走真实内存库 + 真实 IngestService/SessionService。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

// MARK: - 夹具

private func makeTempDir(_ tag: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-wave4a-(tag)-" + UUID().uuidString, isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ path: String, _ content: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    try Data(content.utf8).write(to: URL(fileURLWithPath: path))
}

private func fileSize(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return (attrs[.size] as? NSNumber)?.intValue ?? 0
}

private func sha(_ path: String) throws -> String {
    try FileHasher.sha256File(path)
}

private func removeQuietly(at path: String) {
    do {
        try FileManager.default.removeItem(atPath: path)
    } catch {
        // 清理临时目录失败不影响断言（测试结束由系统回收）。
    }
}

private func makeSessionService(_ db: DBConnection) -> SessionService {
    SessionService(
        sessionRepo: SessionRepo(connection: db),
        photoRepo: PhotoRepo(connection: db),
        faceRepo: FaceRepo(connection: db),
        connection: db
    )
}

/// 插一行带校验和/大小/归档标记的照片（覆盖 insertPhoto 夹具没有的列）。
private func insertFingerprintPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String,
    checksum: String,
    size: Int,
    archived: Bool
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (
          id, session_id, filepath, filename, checksum, checksum_file_size,
          checksum_file_mtime_ms, status, created_at, updated_at, archived_at
        ) VALUES (?, ?, ?, ?, ?, ?, 0, 'ready', '2026-01-01T00:00:00.000Z',
                  '2026-01-01T00:00:00.000Z', ?)
        """).run([
            .text(id), .text(sessionId), .text(filepath),
            .text((filepath as NSString).lastPathComponent), .text(checksum),
            .int(Int64(size)), archived ? .text("2026-01-02T00:00:00.000Z") : .null,
        ])
}

private func setSourcePath(_ db: DBConnection, sessionId: String, path: String) throws {
    _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
        .run([.text(path), .text(sessionId)])
}

// MARK: - F5 / F1：指纹查询

@Suite("Wave4a 跨库指纹（F5/F1）")
struct LibraryFingerprintWave4Tests {

    @Test("F5 归档照片不参与；F1 未回填候选也要带出来")
    func fingerprintsVisibleAndUnhashed() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertFingerprintPhoto(
            db, id: "p-hashed", sessionId: "s1",
            filepath: "/tmp/wave4a-a.jpg", checksum: "sum-a", size: 10, archived: false)
        try insertFingerprintPhoto(
            db, id: "p-archived", sessionId: "s1",
            filepath: "/tmp/wave4a-b.jpg", checksum: "sum-b", size: 10, archived: true)
        try insertFingerprintPhoto(
            db, id: "p-unhashed", sessionId: "s1",
            filepath: "/tmp/wave4a-c.jpg", checksum: "", size: 0, archived: false)

        let rows = try PhotoRepo(connection: db).libraryFingerprints(matchingSizes: [10])
        let ids = Set(rows.map(\.photoId))
        #expect(ids.contains("p-hashed"))
        #expect(!ids.contains("p-archived"), "archived 的 _rejects 照片不能被 replace 命中")
        #expect(ids.contains("p-unhashed"), "未回填行要交给上层 stat/懒算")
    }

    @Test("F1 size 命中才懒算；摄取路径回填 checksum")
    func libraryDuplicatesLazilyHashesAndBackfills() throws {
        let db = try makeTestDB()
        try insertSession(db, "s2")
        let dir = try makeTempDir("lazy")
        defer { removeQuietly(at: dir) }
        let file = (dir as NSString).appendingPathComponent("photo.jpg")
        try writeFile(file, "payload-123")
        let size = try fileSize(file)
        try insertFingerprintPhoto(
            db, id: "p1", sessionId: "s2", filepath: file,
            checksum: "", size: 0, archived: false)

        let service = makeSessionService(db)
        let expected = try sha(file)
        let duplicates = try service.libraryPhotoDuplicates(
            matchingSizes: [size], allowChecksumBackfill: true)
        #expect(duplicates[expected]?.photoId == "p1")
        #expect(duplicates[expected]?.fileSize == size)
        let stored = try db.prepare("SELECT checksum FROM photos WHERE id = 'p1'").get([])
        #expect(stored?[0].textValue == expected, "摄取路径应顺手回填，下一次直接读")
    }

    @Test("F1/F2 只读模式不写回填（preview 用）")
    func libraryDuplicatesReadOnlyDoesNotBackfill() throws {
        let db = try makeTestDB()
        try insertSession(db, "s2")
        let dir = try makeTempDir("readonly")
        defer { removeQuietly(at: dir) }
        let file = (dir as NSString).appendingPathComponent("photo.jpg")
        try writeFile(file, "payload-read-only")
        let size = try fileSize(file)
        try insertFingerprintPhoto(
            db, id: "p1", sessionId: "s2", filepath: file,
            checksum: "", size: 0, archived: false)
        let service = makeSessionService(db)
        let expected = try sha(file)
        let duplicates = try service.libraryPhotoDuplicates(
            matchingSizes: [size], allowChecksumBackfill: false)
        #expect(duplicates[expected]?.photoId == "p1", "只读也返回命中（供预检计数）")
        let stored = try db.prepare("SELECT checksum FROM photos WHERE id = 'p1'").get([])
        #expect(stored?[0].textValue == "", "预检不得写库")
    }

    @Test("F1 size 不匹配的未回填行不做哈希")
    func libraryDuplicatesSizePreFilter() throws {
        let db = try makeTestDB()
        try insertSession(db, "s2")
        let dir = try makeTempDir("sizefilter")
        defer { removeQuietly(at: dir) }
        let file = (dir as NSString).appendingPathComponent("photo.jpg")
        try writeFile(file, "payload")
        let size = try fileSize(file)
        try insertFingerprintPhoto(
            db, id: "p1", sessionId: "s2", filepath: file,
            checksum: "", size: 0, archived: false)
        let service = makeSessionService(db)
        let duplicates = try service.libraryPhotoDuplicates(
            matchingSizes: [size + 1], allowChecksumBackfill: true)
        #expect(duplicates.isEmpty)
        let stored = try db.prepare("SELECT checksum FROM photos WHERE id = 'p1'").get([])
        #expect(stored?[0].textValue == "", "没命中就不该读整文件")
    }

    @Test("F3 refreshPhotoFingerprints 用覆盖后的文件刷新库内行")
    func refreshFingerprintsAfterReplace() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let dir = try makeTempDir("refresh")
        defer { removeQuietly(at: dir) }
        let file = (dir as NSString).appendingPathComponent("photo.jpg")
        try writeFile(file, "old-content")
        try insertFingerprintPhoto(
            db, id: "p1", sessionId: "s1", filepath: file,
            checksum: "stale-checksum", size: 1, archived: false)
        try writeFile(file, "new-content")
        let service = makeSessionService(db)
        let refreshed = try service.refreshPhotoFingerprints(
            sessionId: "s1", filepaths: [file])
        #expect(refreshed == 1)
        let expected = try sha(file)
        let stored = try db.prepare(
            "SELECT checksum, checksum_file_size FROM photos WHERE id = 'p1'").get([])
        #expect(stored?[0].textValue == expected)
        #expect(stored?[1].intValue == Int64(try fileSize(file)))
    }
}

// MARK: - F2：plan 的源哈希门控

@Suite("Wave4a 摄取 plan 去重门控（F2）")
struct IngestPlanDedupeWave4Tests {

    @Test("F2 size 不在库内候选集就不做 SHA-256（否则误判重复）")
    func planSkipsHashingWhenSizeNotCandidate() async throws {
        let source = try makeTempDir("plan-src")
        let dest = try makeTempDir("plan-dest")
        defer {
            removeQuietly(at: source)
            removeQuietly(at: dest)
        }
        let file = (source as NSString).appendingPathComponent("a.jpg")
        try writeFile(file, "plan-payload")
        let size = try fileSize(file)
        let sum = try sha(file)
        let target = SessionService.LibraryDuplicateTarget(
            photoId: "lib", sessionId: "s1", filepath: "/elsewhere/a.jpg", fileSize: size)
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}",
            duplicatePolicy: .skip)
        let service = IngestService()

        // 候选大小不匹配 → 不哈希 → 不判重复（预检不再整卡逐张哈希）。
        let unmatched = try await service.plan(
            sourcePaths: [file], options: options,
            libraryDuplicates: [sum: target], libraryCandidateSizes: [size + 1])
        #expect(unmatched.skipped.isEmpty)
        #expect(unmatched.librarySkipped.isEmpty)
        #expect(unmatched.items.count == 1)

        // 命中候选大小 → 哈希 → skip 策略跳过。
        let matched = try await service.plan(
            sourcePaths: [file], options: options,
            libraryDuplicates: [sum: target], libraryCandidateSizes: [size])
        #expect(matched.items.isEmpty)
        #expect(matched.librarySkipped == [file])
    }

    @Test("L1 coexist：库内重复照常导入（显式选择并存）")
    func coexistImportsDuplicate() async throws {
        let source = try makeTempDir("coexist-src")
        let dest = try makeTempDir("coexist-dest")
        defer {
            removeQuietly(at: source)
            removeQuietly(at: dest)
        }
        let file = (source as NSString).appendingPathComponent("a.jpg")
        try writeFile(file, "coexist")
        let size = try fileSize(file)
        let sum = try sha(file)
        let target = SessionService.LibraryDuplicateTarget(
            photoId: "lib", sessionId: "s2", filepath: "/elsewhere/a.jpg", fileSize: size)
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}",
            duplicatePolicy: .coexist)
        let plan = try await IngestService().plan(
            sourcePaths: [file], options: options,
            libraryDuplicates: [sum: target], libraryCandidateSizes: [size])
        #expect(plan.items.count == 1)
        #expect(plan.librarySkipped.isEmpty)
        #expect(plan.libraryDuplicates == [file])
    }
}

// MARK: - F4 / L2：replace 与第二目的地

@Suite("Wave4a replace 与第二目的地（F4/L2）")
struct ReplaceSecondDestinationWave4Tests {

    private func layout() throws -> (
        root: String, dest: String, second: String, oldPath: String, sourceFile: String
    ) {
        let root = try makeTempDir("replace-root")
        let dest = (root as NSString).appendingPathComponent("_ingest")
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let oldPath = (root as NSString).appendingPathComponent("old/a.jpg")
        try writeFile(oldPath, "old-content")
        let sourceRoot = try makeTempDir("replace-src")
        let sourceFile = (sourceRoot as NSString).appendingPathComponent("a.jpg")
        try writeFile(sourceFile, "new-content")
        let second = try makeTempDir("replace-second")
        return (root, dest, second, oldPath, sourceFile)
    }

    @Test("F4 replace 项跳过第二目的地并记入 secondSkipped")
    func replaceSkipsSecondDestination() async throws {
        let l = try layout()
        defer {
            for path in [l.root, l.second,
                         (l.sourceFile as NSString).deletingLastPathComponent] {
                removeQuietly(at: path)
            }
        }
        let size = try fileSize(l.sourceFile)
        let sum = try sha(l.sourceFile)
        let options = IngestOptions(
            destinationRoot: l.dest, renameTemplate: "{orig}.{ext}",
            secondDestinationRoot: l.second, verifyChecksum: true,
            duplicatePolicy: .replace, sessionId: "s1", sessionSourceRoot: l.root)
        let target = SessionService.LibraryDuplicateTarget(
            photoId: "p1", sessionId: "s1", filepath: l.oldPath, fileSize: size)
        let service = IngestService()
        let plan = try await service.plan(
            sourcePaths: [l.sourceFile], options: options,
            libraryDuplicates: [sum: target], libraryCandidateSizes: [size])
        #expect(plan.replaced == [l.sourceFile])
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        #expect(result.replaced == [l.oldPath])
        #expect(result.secondSkipped == [l.oldPath])
        let replaced = try String(contentsOfFile: l.oldPath, encoding: .utf8)
        #expect(replaced == "new-content")
        let secondFiles = try FileManager.default.contentsOfDirectory(atPath: l.second)
        #expect(secondFiles.isEmpty, "replace 目标无法按相对路径镜像，必须不写")
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: (l.oldPath as NSString).deletingLastPathComponent
        ).filter { $0.contains("gather-prev") }
        #expect(backups.isEmpty, "成功后不留备份")
    }

    @Test("L2 第二副本按 verifyChecksum 校验且内容一致")
    func secondDestinationCopiesWithVerification() async throws {
        let source = try makeTempDir("verify-src")
        let dest = try makeTempDir("verify-dest")
        let second = try makeTempDir("verify-second")
        defer {
            for path in [source, dest, second] {
                removeQuietly(at: path)
            }
        }
        let file = (source as NSString).appendingPathComponent("a.jpg")
        try writeFile(file, "verify-payload")
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}",
            secondDestinationRoot: second, verifyChecksum: true)
        let service = IngestService()
        let plan = try await service.plan(sourcePaths: [file], options: options)
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        #expect(result.copied.count == 1)
        #expect(result.secondCopied.count == 1)
        let copied = try String(contentsOfFile: result.secondCopied[0], encoding: .utf8)
        #expect(copied == "verify-payload")
    }
}

// MARK: - L1 / F2：preview 计数与只读

@Suite("Wave4a 摄取预检（L1/F2）")
struct IngestPreviewWave4Tests {

    @Test("L1/F2 preview 计数正确、库内重复按策略分类、且不回填 checksum")
    func previewCountsAndStaysReadOnly() async throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertSession(db, "s2")
        let root = try makeTempDir("preview-root")
        let dest = (root as NSString).appendingPathComponent("_ingest")
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let libraryFile = (root as NSString).appendingPathComponent("old/a.jpg")
        try writeFile(libraryFile, "same-payload")
        let sourceRoot = try makeTempDir("preview-src")
        let sourceFile = (sourceRoot as NSString).appendingPathComponent("a.jpg")
        try writeFile(sourceFile, "same-payload")
        defer {
            for path in [root, sourceRoot] {
                removeQuietly(at: path)
            }
        }
        try setSourcePath(db, sessionId: "s1", path: root)
        // 库里另一工作区已登记同一内容，但 checksum 还没回填（F1 场景）。
        try insertFingerprintPhoto(
            db, id: "p-old", sessionId: "s2", filepath: libraryFile,
            checksum: "", size: 0, archived: false)

        let runner = SessionIngestRunner(sessionService: makeSessionService(db))
        let input = try SessionIngestInput(
            sessionId: "s1", sourcePaths: [sourceFile],
            destinationRoot: dest, duplicatePolicy: .skip)
        let preview = try await runner.preview(input)
        #expect(preview.libraryDuplicateCount == 1)
        #expect(preview.librarySkippedCount == 1)
        #expect(preview.replaceableCount == 0)
        #expect(preview.newCount == 0)
        #expect(preview.totalCount == 1)
        let stored = try db.prepare(
            "SELECT checksum FROM photos WHERE id = 'p-old'").get([])
        #expect(stored?[0].textValue == "", "预览是只读的：不得回填 checksum")

        // coexist：预检把重复算作新增（执行期会真的再存一份）。
        let coexistInput = try SessionIngestInput(
            sessionId: "s1", sourcePaths: [sourceFile],
            destinationRoot: dest, duplicatePolicy: .coexist)
        let coexistPreview = try await runner.preview(coexistInput)
        #expect(coexistPreview.newCount == 1)
        #expect(coexistPreview.librarySkippedCount == 0)
    }

    @Test("F2 preview 也不回填会话内 checksum（只读）")
    func previewDoesNotBackfillSessionChecksums() async throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let root = try makeTempDir("preview-session")
        let dest = (root as NSString).appendingPathComponent("_ingest")
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let sourceRoot = try makeTempDir("preview-session-src")
        let sourceFile = (sourceRoot as NSString).appendingPathComponent("a.jpg")
        try writeFile(sourceFile, "source-only")
        // 同一会话里一条未回填照片：大小与源相同、内容不同（不命中会话去重），
        // 用来验证预检的懒算不会写库。
        let sessionFile = (root as NSString).appendingPathComponent("s/a.jpg")
        try writeFile(sessionFile, "other-conte")
        defer {
            removeQuietly(at: root)
            removeQuietly(at: sourceRoot)
        }
        try setSourcePath(db, sessionId: "s1", path: root)
        try insertFingerprintPhoto(
            db, id: "p-session", sessionId: "s1", filepath: sessionFile,
            checksum: "", size: 0, archived: false)

        let runner = SessionIngestRunner(sessionService: makeSessionService(db))
        let input = try SessionIngestInput(
            sessionId: "s1", sourcePaths: [sourceFile],
            destinationRoot: dest, duplicatePolicy: .skip)
        let preview = try await runner.preview(input)
        #expect(preview.newCount == 1)
        let stored = try db.prepare(
            "SELECT checksum FROM photos WHERE id = 'p-session'").get([])
        #expect(stored?[0].textValue == "", "预检只读：会话内懒算也不得回填")
    }

    @Test("L1 SessionIngestPreview 旧载荷解码兜底（新字段缺省 0）")
    func previewDecodesLegacyPayload() throws {
        let legacy = #"""
        {"totalCount":3,"newCount":2,"libraryDuplicateCount":1,
         "conflictCount":0,"unreadableCount":0,"policy":"skip"}
        """#
        let preview = try JSONDecoder().decode(
            SessionIngestPreview.self, from: Data(legacy.utf8))
        #expect(preview.totalCount == 3)
        #expect(preview.librarySkippedCount == 0)
        #expect(preview.replaceableCount == 0)
    }
}
