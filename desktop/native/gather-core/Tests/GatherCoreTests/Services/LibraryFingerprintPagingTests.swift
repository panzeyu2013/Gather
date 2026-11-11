// desktop/native/gather-core/Tests/GatherCoreTests/Services/LibraryFingerprintPagingTests.swift
// Wave4c（task-49）：未回填 checksum 候选的 rowid 游标分页——旧实现硬 LIMIT 500，
// 大库（>500 未回填行）跨会话去重会部分失效。这里钉：分页能走完所有候选、
// 每批上限常量生效、size 预筛对跨页候选依然正确。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

// MARK: - 夹具

private func makeTempDir(_ tag: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-wave4c-\(tag)-\(UUID().uuidString)", isDirectory: true)
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

private func removeQuietly(_ path: String) {
    do {
        try FileManager.default.removeItem(atPath: path)
    } catch {
        // 清理临时目录失败不影响断言（测试结束由系统回收）。
    }
}

private func insertUnhashedPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String,
    archived: Bool = false
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum,
          status, created_at, updated_at, archived_at)
        VALUES (?, ?, ?, ?, '', 'ready', '2026-01-01T00:00:00.000Z',
                '2026-01-01T00:00:00.000Z', ?)
        """).run([
            .text(id), .text(sessionId), .text(filepath),
            .text((filepath as NSString).lastPathComponent),
            archived ? .text("2026-01-02T00:00:00.000Z") : .null,
        ])
}

private func makeSessionService(_ db: DBConnection) -> SessionService {
    SessionService(
        sessionRepo: SessionRepo(connection: db),
        photoRepo: PhotoRepo(connection: db),
        faceRepo: FaceRepo(connection: db),
        connection: db
    )
}

private func backfilledCount(_ db: DBConnection) throws -> Int {
    let row = try db.prepare(
        "SELECT COUNT(*) FROM photos WHERE checksum != ''").get([])
    return Int(row?[0].intValue ?? 0)
}

private func emptyChecksumCount(_ db: DBConnection) throws -> Int {
    let row = try db.prepare(
        "SELECT COUNT(*) FROM photos WHERE checksum = ''").get([])
    return Int(row?[0].intValue ?? 0)
}

// MARK: - 分页

@Suite("未回填候选 rowid 分页（task-49）")
struct LibraryFingerprintPagingTests {

    @Test(">1 批：游标走完 501 个候选（每批上限 500），归档行不参与")
    func pagingWalksMoreThanOnePage() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let repo = PhotoRepo(connection: db)
        let pageSize = PhotoRepo.libraryUnhashedPageSize
        #expect(pageSize == 500, "每批上限常量必须显式钉住")
        for index in 0..<501 {
            try insertUnhashedPhoto(
                db, id: "p\(index)", sessionId: "s1",
                filepath: "/tmp/wave4c-paging/\(index).jpg")
        }
        try insertUnhashedPhoto(
            db, id: "p-archived", sessionId: "s1",
            filepath: "/tmp/wave4c-paging/archived.jpg", archived: true)

        var collected: [String] = []
        var pageSizes: [Int] = []
        var afterRowId: Int64 = 0
        while true {
            let page = try repo.libraryUnhashedFingerprints(
                afterRowId: afterRowId, limit: pageSize)
            pageSizes.append(page.rows.count)
            collected.append(contentsOf: page.rows.map(\.photoId))
            if page.rows.count < pageSize { break }
            afterRowId = page.lastRowId
        }
        #expect(pageSizes == [500, 1], "旧实现在这里只会看到 500 条")
        #expect(collected.count == 501)
        #expect(Set(collected).count == 501, "游标分页不得重复行")
        #expect(!collected.contains("p-archived"), "归档行不进候选")
    }

    @Test(">500 候选全部参与 size 预筛与去重：501 命中回填、20 大小不匹配保持空")
    func libraryDuplicatesCoversMoreThanOnePage() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir("paging")
        defer { removeQuietly(dir) }
        let matchFile = (dir as NSString).appendingPathComponent("match.jpg")
        let otherFile = (dir as NSString).appendingPathComponent("other.jpg")
        try writeFile(matchFile, "match-payload")
        // 大小刻意与 match 不同：size 预筛应把它们排除在哈希之外。
        try writeFile(otherFile, "other-payload-with-a-different-length")
        let matchSize = try fileSize(matchFile)
        let matchSum = try sha(matchFile)

        // 501 个候选指向 match 文件（跨 501 个会话，filepath 唯一索引按会话）。
        for index in 0..<501 {
            let sessionId = "s-match-\(index)"
            try insertSession(db, sessionId)
            try insertUnhashedPhoto(
                db, id: "pm\(index)", sessionId: sessionId, filepath: matchFile)
        }
        // 另外 20 个候选大小不匹配：排在第 2 批之后（游标要能走到它们）。
        for index in 0..<20 {
            let sessionId = "s-other-\(index)"
            try insertSession(db, sessionId)
            try insertUnhashedPhoto(
                db, id: "po\(index)", sessionId: sessionId, filepath: otherFile)
        }

        let service = makeSessionService(db)
        let duplicates = try service.libraryPhotoDuplicates(
            matchingSizes: [matchSize], allowChecksumBackfill: true)
        #expect(duplicates[matchSum] != nil, "命中内容必须出现在去重索引里")
        #expect(try backfilledCount(db) == 501, "跨页的 501 个命中候选都要回填")
        #expect(try emptyChecksumCount(db) == 20, "大小不匹配的 20 个不哈希、不回填")
    }
}
