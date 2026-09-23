// Tests/GatherCoreTests/Store/CullingStoreTests.swift
// R1：CullingStore 测试（端口自 CullingDecisionRepoTests + CullingHistoryRepoTests）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/CullingStore (R1)")
struct CullingStoreTests {
    private func makeStore(photoIds: [String] = ["p1", "p2"]) async throws -> (SQLiteCullingStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "culling")
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        for photoId in photoIds {
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
                VALUES (?, 's1', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(photoId), .text("/\(photoId).jpg"), .text("\(photoId).jpg")]
            )
        }
        return (SQLiteCullingStore(database: database), database, path)
    }

    private func rowCount(_ database: SQLiteDatabase, _ sql: String) async throws -> Int64 {
        try await database.scalarInt(sql) ?? -1
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

    // MARK: culling_decisions

    @Test func upsertCreatesThenUpdates() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        var row = try await store.decision(sessionId: "s1", photoId: "p1")
        #expect(row != nil)
        #expect(row?.decision == "keep")
        #expect(row?.groupId == "g1")
        #expect(row?.rating == 0)
        #expect(row?.decisionSource == "manual")
        #expect(row?.revision == 0)
        #expect(row?.createdAt != "")

        // 等 2ms 确保 updated_at 时间戳前进（ISO 毫秒精度）。
        try await Task.sleep(nanoseconds: 2_000_000)
        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "g2", decision: "reject")
        row = try await store.decision(sessionId: "s1", photoId: "p1")
        #expect(row?.decision == "reject")
        #expect(row?.groupId == "g2")
        #expect(row?.updatedAt != row?.createdAt)
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM culling_decisions") == 1)
    }

    @Test func gettersAndLiteProjection() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try await store.upsertDecision(sessionId: "s1", photoId: "p2", groupId: "g1", decision: "reject")

        let lite = try await store.decisions(sessionId: "s1")
        #expect(lite.count == 2)
        #expect(lite.contains(CullingDecisionLite(photoId: "p1", decision: "keep")))
        #expect(try await store.decisionsFull(sessionId: "s1").count == 2)
        #expect(try await store.decision(sessionId: "s1", photoId: "missing") == nil)
        #expect(try await store.decisions(sessionId: "other-session").isEmpty)
    }

    @Test func getByPhotoIdsEmptyAndChunked() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        #expect(try await store.decisions(sessionId: "s1", photoIds: []).isEmpty)

        // 跨 800 分批边界：900 张照片各一条决策。
        var photoIds: [String] = []
        for index in 0..<900 {
            let id = "bulk-\(index)"
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
                VALUES (?, 's1', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(id), .text("/\(id).jpg"), .text("\(id).jpg")]
            )
            photoIds.append(id)
            try await store.upsertDecision(sessionId: "s1", photoId: id, groupId: "g", decision: "keep")
        }
        let rows = try await store.decisions(sessionId: "s1", photoIds: photoIds)
        #expect(rows.count == 900)
        #expect(rows[899].photoId == "bulk-899")
    }

    @Test func upsertStatePersistsAllFields() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertDecisionState(
            sessionId: "s1",
            photoId: "p1",
            groupId: "g1",
            state: CullingDecisionState(decision: "keep", rating: 4, colorLabel: "Green", revision: 2)
        )
        var row = try await store.decision(sessionId: "s1", photoId: "p1")
        #expect(row?.rating == 4)
        #expect(row?.colorLabel == "Green")
        #expect(row?.revision == 2)
        #expect(row?.decisionSource == "manual")

        try await store.upsertDecisionState(
            sessionId: "s1",
            photoId: "p1",
            groupId: "g1",
            state: CullingDecisionState(decision: "reject", rating: 1, colorLabel: "Red", revision: 3, source: "template")
        )
        row = try await store.decision(sessionId: "s1", photoId: "p1")
        #expect(row?.rating == 1)
        #expect(row?.revision == 3)
        #expect(row?.decisionSource == "template")
    }

    @Test func upsertStateRejectsOutOfRangeRating() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        await #expect(throws: SQLiteFailure.self) {
            try await store.upsertDecisionState(
                sessionId: "s1",
                photoId: "p1",
                groupId: "g1",
                state: CullingDecisionState(decision: "keep", rating: 6, colorLabel: "None", revision: 0)
            )
        }
    }

    @Test func upsertManyRunsInTransaction() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let decisions = [
            CullingDecisionInput(photoId: "p1", groupId: "g1", decision: "keep"),
            CullingDecisionInput(photoId: "p2", groupId: "g1", decision: "reject"),
        ]
        try await store.upsertDecisions(sessionId: "s1", decisions: decisions)
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM culling_decisions") == 2)

        try await store.upsertDecisions(sessionId: "s1", decisions: [decisions[0]])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM culling_decisions") == 2)
    }

    @Test func resultPrefixQueries() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES ('p3', 's1', '/p3.jpg', 'p3.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )

        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "42:0", decision: "keep")
        try await store.upsertDecision(sessionId: "s1", photoId: "p2", groupId: "42:1", decision: "reject")
        try await store.upsertDecision(sessionId: "s1", photoId: "p3", groupId: "7:0", decision: "keep")

        #expect(try await store.decisionsByResultPrefix(sessionId: "s1", resultId: 42).count == 2)

        let counts = try await store.decisionCountsByResultPrefix(sessionId: "s1", resultId: 42)
        #expect(counts == [
            CullingDecisionCount(decision: "keep", cnt: 1),
            CullingDecisionCount(decision: "reject", cnt: 1),
        ])

        let total = try await store.decisionCounts(sessionId: "s1")
        #expect(total.contains(CullingDecisionCount(decision: "keep", cnt: 2)))
        #expect(total.contains(CullingDecisionCount(decision: "reject", cnt: 1)))
    }

    @Test func deleteBySessionAndGroup() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try await store.upsertDecision(sessionId: "s1", photoId: "p2", groupId: "g2", decision: "reject")

        try await store.deleteDecisions(sessionId: "s1", groupId: "g1")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM culling_decisions") == 1)

        try await store.deleteDecisions(sessionId: "s1")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM culling_decisions") == 0)
    }

    @Test func batchRestoreDecisions() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try await store.upsertDecisionState(
            sessionId: "s1",
            photoId: "p2",
            groupId: "g1",
            state: CullingDecisionState(decision: "keep", rating: 3, colorLabel: "Blue", revision: 1)
        )

        try await store.restoreDecisions([
            CullingRestoreInput(sessionId: "s1", photoId: "p1", decision: "reject"),
            CullingRestoreInput(sessionId: "s1", photoId: "p2", decision: "reject"),
        ])
        #expect(try await store.decision(sessionId: "s1", photoId: "p1")?.decision == "reject")
        #expect(try await store.decision(sessionId: "s1", photoId: "p2")?.decision == "reject")
        #expect(try await store.decision(sessionId: "s1", photoId: "p2")?.rating == 3, "restore 只改 decision 列")
    }

    @Test func photoCascadeDeletesDecision() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertDecision(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try await database.run("DELETE FROM photos WHERE id = 'p1'")
        #expect(try await store.decision(sessionId: "s1", photoId: "p1") == nil)
    }

    // MARK: culling_history

    @Test func appendReturnsOperationAndRoundTrips() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        let operation = try await store.appendHistory(sessionId: "s1", entries: [entry()])
        #expect(operation.id == 1)
        #expect(operation.sessionId == "s1")
        #expect(operation.undone == false)
        #expect(operation.createdAt != "")

        let raw = try await database.queryOne("SELECT operation_json FROM culling_history WHERE id = 1")
        #expect(raw?.text("operation_json")?.contains("\"photoId\"") == true)
        #expect(raw?.text("operation_json")?.contains("\"pickState\"") == true)
        #expect(raw?.text("operation_json")?.contains("\"expectedRevision\"") == true)

        let fetched = try await store.historyOperation(sessionId: "s1", operationId: 1)
        #expect(fetched != nil)
        #expect(fetched?.entries == [entry()])
        #expect(fetched?.entries[0].after.rating == 5)
    }

    @Test func appendClearsPreviousUndoneRows() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        let op1 = try await store.appendHistory(sessionId: "s1", entries: [entry()])
        let op2 = try await store.appendHistory(sessionId: "s1", entries: [entry(photoId: "p2")])
        try await store.setHistoryUndone(sessionId: "s1", operationId: op2.id, undone: true)

        _ = try await store.appendHistory(sessionId: "s1", entries: [entry(photoId: "p3")])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM culling_history") == 2)
        #expect(try await store.historyOperation(sessionId: "s1", operationId: op1.id) != nil)
        #expect(try await store.historyOperation(sessionId: "s1", operationId: op2.id) == nil, "undone 行在下次 append 时被清除")
    }

    @Test func setUndoneRequiresLatestBoundary() async throws {
        let (store, _, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        let op1 = try await store.appendHistory(sessionId: "s1", entries: [entry()])
        let op2 = try await store.appendHistory(sessionId: "s1", entries: [entry(photoId: "p2")])

        await #expect(throws: CullingStoreError.undoNotLatest) {
            try await store.setHistoryUndone(sessionId: "s1", operationId: op1.id, undone: true)
        }
        try await store.setHistoryUndone(sessionId: "s1", operationId: op2.id, undone: true)
        #expect(try await store.historyOperation(sessionId: "s1", operationId: op2.id)?.undone == true)

        try await store.setHistoryUndone(sessionId: "s1", operationId: op2.id, undone: false)
        #expect(try await store.historyOperation(sessionId: "s1", operationId: op2.id)?.undone == false)
        await #expect(throws: CullingStoreError.redoOutOfOrder) {
            try await store.setHistoryUndone(sessionId: "s1", operationId: op1.id, undone: false)
        }
    }

    @Test func setUndoneStaleOrMissing() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        await #expect(throws: CullingStoreError.undoNotLatest) {
            try await store.setHistoryUndone(sessionId: "s1", operationId: 999, undone: true)
        }
        let op = try await store.appendHistory(sessionId: "s1", entries: [entry()])
        // 篡改：该行已被标记 undone=1，undo 的边界查询（MAX(id) WHERE undone=0）为空
        // → 边界校验先失败，抛 undoNotLatest（与旧 Repo 行为一致；historyStale 是
        // 边界通过但 UPDATE 未命中的防御分支）。
        try await database.run("UPDATE culling_history SET undone = 1 WHERE id = ?", [.int(Int64(op.id))])
        await #expect(throws: CullingStoreError.undoNotLatest) {
            try await store.setHistoryUndone(sessionId: "s1", operationId: op.id, undone: true)
        }
    }

    @Test func getUnknownReturnsNil() async throws {
        let (store, _, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }
        #expect(try await store.historyOperation(sessionId: "s1", operationId: 42) == nil)
    }

    @Test func corruptOperationJSONThrowsOnGetAndIsSkippedInList() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        _ = try await store.appendHistory(sessionId: "s1", entries: [entry()])
        try await database.run(
            """
            INSERT INTO culling_history (session_id, operation_json, undone, created_at)
            VALUES ('s1', '{not-json', 0, '2026-01-01T00:00:00.000Z')
            """
        )

        await #expect(throws: CullingStoreError.historyCorrupt) {
            _ = try await store.historyOperation(sessionId: "s1", operationId: 2)
        }
        #expect(try await store.historyList(sessionId: "s1").count == 1, "损坏行在 list 中被跳过")
    }

    @Test func listOrdersDescAndClampsLimit() async throws {
        let (store, _, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        for index in 0..<3 {
            _ = try await store.appendHistory(sessionId: "s1", entries: [entry(photoId: "p\(index)")])
        }
        #expect(try await store.historyList(sessionId: "s1").map(\.id) == [3, 2, 1])
        #expect(try await store.historyList(sessionId: "s1", limit: 0).count == 1, "limit 下限钳到 1")
        #expect(try await store.historyList(sessionId: "s1", limit: 1000).count == 3)
        #expect(try await store.historyList(sessionId: "s1", limit: 2).count == 2)
    }
}
