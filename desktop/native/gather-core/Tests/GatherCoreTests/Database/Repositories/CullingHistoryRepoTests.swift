// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/CullingHistoryRepoTests.swift
// TS 源: desktop/src/main/db/repositories/culling-history.repo.ts

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

struct CullingHistoryRepoTests {
    private func makeRepo() throws -> (DBConnection, CullingHistoryRepo) {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        return (db, CullingHistoryRepo(connection: db))
    }

    private func entry(photoId: String = "p1") -> CullingHistoryEntry {
        CullingHistoryEntry(
            photoId: photoId,
            before: CullingStateSnapshot(pickState: .unreviewed, rating: 0, colorLabel: .none),
            after: CullingStateSnapshot(pickState: .picked, rating: 5, colorLabel: .red),
            expectedRevision: 1,
            fields: [.pickState, .rating, .colorLabel]
        )
    }

    @Test func appendReturnsOperationAndRoundTrips() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let operation = try repo.append(sessionId: "s1", entries: [entry()])
        #expect(operation.id == 1)
        #expect(operation.sessionId == "s1")
        #expect(operation.undone == false)
        #expect(operation.createdAt != "")

        // JSON 存储键与 TS JSON.stringify 一致（camelCase）
        let raw = try db.prepare("SELECT operation_json FROM culling_history WHERE id = 1").get()
        #expect(raw?[0].textValue?.contains("\"photoId\"") == true)
        #expect(raw?[0].textValue?.contains("\"pickState\"") == true)
        #expect(raw?[0].textValue?.contains("\"expectedRevision\"") == true)

        let fetched = try repo.get(sessionId: "s1", operationId: 1)
        #expect(fetched != nil)
        #expect(fetched?.entries == [entry()])
        #expect(fetched?.entries[0].after.rating == 5)
    }

    @Test func appendClearsPreviousUndoneRows() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let op1 = try repo.append(sessionId: "s1", entries: [entry()])
        let op2 = try repo.append(sessionId: "s1", entries: [entry(photoId: "p2")])
        try repo.setUndone(sessionId: "s1", operationId: op2.id, undone: true)

        _ = try repo.append(sessionId: "s1", entries: [entry(photoId: "p3")])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM culling_history") == 2)
        #expect(try repo.get(sessionId: "s1", operationId: op1.id) != nil)
        #expect(try repo.get(sessionId: "s1", operationId: op2.id) == nil, "undone 行在下次 append 时被清除")
    }

    @Test func setUndoneRequiresLatestBoundary() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let op1 = try repo.append(sessionId: "s1", entries: [entry()])
        let op2 = try repo.append(sessionId: "s1", entries: [entry(photoId: "p2")])

        #expect(throws: PersistenceError(code: .CULLING_UNDO_NOT_LATEST)) {
            try repo.setUndone(sessionId: "s1", operationId: op1.id, undone: true)
        }
        try repo.setUndone(sessionId: "s1", operationId: op2.id, undone: true)
        #expect(try repo.get(sessionId: "s1", operationId: op2.id)?.undone == true)

        // redo 只能按 MIN(id) 顺序：op2 是唯一 undone 行，redo 合法
        try repo.setUndone(sessionId: "s1", operationId: op2.id, undone: false)
        #expect(try repo.get(sessionId: "s1", operationId: op2.id)?.undone == false)
        // op1 从未 undone → 不在边界上，redo 报错
        #expect(throws: PersistenceError(code: .CULLING_REDO_OUT_OF_ORDER)) {
            try repo.setUndone(sessionId: "s1", operationId: op1.id, undone: false)
        }
    }

    @Test func setUndoneStaleOrMissing() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(throws: PersistenceError(code: .CULLING_UNDO_NOT_LATEST)) {
            try repo.setUndone(sessionId: "s1", operationId: 999, undone: true)
        }
        let op = try repo.append(sessionId: "s1", entries: [entry()])
        // 用 SQL 篡改边界外的行：id 存在但不是 boundary（应报 STALE，因 update 影响 0 行）
        _ = try db.prepare("UPDATE culling_history SET undone = 1 WHERE id = ?").run([.int(Int64(op.id))])
        // 篡改后先撞边界守卫（UNDO_NOT_LATEST）；STALE 是并发下 update 影响 0 行的兜底，
        // 同步测试无法稳定构造，码值由 CullingHistoryRepo 的防御分支保留。
        #expect(throws: PersistenceError(code: .CULLING_UNDO_NOT_LATEST)) {
            try repo.setUndone(sessionId: "s1", operationId: op.id, undone: true)
        }
    }

    @Test func getUnknownReturnsNil() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        #expect(try repo.get(sessionId: "s1", operationId: 42) == nil)
    }

    @Test func corruptOperationJSONThrowsOnGetAndIsSkippedInList() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.append(sessionId: "s1", entries: [entry()])
        _ = try db.prepare("""
            INSERT INTO culling_history (session_id, operation_json, undone, created_at)
            VALUES ('s1', '{not-json', 0, '2026-01-01T00:00:00.000Z')
        """).run()

        #expect(throws: PersistenceError(code: .CULLING_HISTORY_CORRUPT)) {
            try repo.get(sessionId: "s1", operationId: 2)
        }
        let list = try repo.list(sessionId: "s1")
        #expect(list.count == 1, "损坏行在 list 中被跳过")
    }

    @Test func listOrdersDescAndClampsLimit() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        for index in 0..<3 {
            _ = try repo.append(sessionId: "s1", entries: [entry(photoId: "p\(index)")])
        }
        let list = try repo.list(sessionId: "s1")
        #expect(list.map(\.id) == [3, 2, 1])

        #expect(try repo.list(sessionId: "s1", limit: 0).count == 1, "limit 下限钳到 1")
        #expect(try repo.list(sessionId: "s1", limit: 1000).count == 3, "limit 上限钳到 500，但只有 3 行")
        #expect(try repo.list(sessionId: "s1", limit: 2).count == 2)
    }
}
