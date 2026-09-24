// Tests/GatherCoreTests/Store/WritebackStoreTests.swift
// R1：WritebackStore（metadata_outbox 部分）测试（端口自 MetadataOutboxRepoTests）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/WritebackStore (R1)")
struct WritebackStoreTests {
    private func makeStore() async throws -> (SQLiteWritebackStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "writeback")
        // metadata_outbox_sessions.session_id 引用 sessions(id)：FK 开启下需先建会话
        // （旧测试基座同样插入 s1/s2）。
        for id in ["s1", "s2"] {
            try await database.run(
                """
                INSERT INTO sessions (id, name, created_at, updated_at)
                VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(id)]
            )
        }
        return (SQLiteWritebackStore(database: database), database, path)
    }

    private func rowCount(_ database: SQLiteDatabase, _ sql: String) async throws -> Int64 {
        try await database.scalarInt(sql) ?? -1
    }

    @Test func getUnknownAndMergePatchCreate() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp") == nil)

        let patch = JSONValue.object([
            "source": JSONValue.string("face-keyword"),
            "keywords": JSONValue.array([JSONValue.string("a")]),
        ])
        let row = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: patch, dirtyFields: ["keywords"]
        )
        #expect(row.status == "pending")
        #expect(row.revision == 1)
        #expect(row.persistedRevision == 0)
        #expect(row.sourceModule == "face-keyword")
        #expect(row.ownerSessionId == "s1")
        #expect(row.photoPath == "/v/IMG_1.jpg")
        #expect(row.dirty == ["keywords"])
        #expect(row.patch["keywords"]?.arrayValue == ["a"])
        #expect(try await store.outboxSessionIds(xmpPath: "/v/IMG_1.xmp") == ["s1"])
    }

    @Test func mergePatchMergesWhenNotNewRevision() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object([
                "source": JSONValue.string("face-keyword"),
                "keywords": JSONValue.array([JSONValue.string("a")]),
            ]),
            dirtyFields: ["keywords"]
        )
        let row = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["rating": JSONValue.int(4)]),
            dirtyFields: ["rating"]
        )
        #expect(row.revision == 2)
        #expect(row.dirty == ["keywords", "rating"], "dirty_fields 去重合并")
        #expect(row.patch["keywords"]?.arrayValue == ["a"])
        #expect(row.patch["rating"] == .number(4))
    }

    @Test func mergePatchStartsNewRevisionAfterWritten() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: ["rating"]
        )
        _ = try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1)
        try await store.markOutboxWritten(
            xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp", baseValues: .object([:]), backupPath: "/backup/xmp"
        )

        let row = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["rating": JSONValue.int(5)]), dirtyFields: ["rating"]
        )
        #expect(row.revision == 2)
        #expect(row.patch["rating"] == .number(5))
        #expect(row.dirty == ["rating"])
    }

    @Test func sessionScopedQueries() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p1 = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p1, dirtyFields: [])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg", patch: p1, dirtyFields: [])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s2", photoPath: "/v/IMG_1.jpg", patch: p1, dirtyFields: [])

        let bySession = try await store.outboxEntries(sessionId: "s1")
        #expect(bySession.count == 1)
        #expect(bySession[0].xmpPath == "/v/IMG_1.xmp")
        #expect(try await store.outboxSessionIds(xmpPath: "/v/IMG_1.xmp") == ["s1", "s2"], "linked_at 排序")

        let summaries = try await store.outboxSummaries(sessionId: "s1")
        #expect(summaries.count == 1)
        #expect(summaries[0].xmpPath == "/v/IMG_1.xmp")
        #expect(summaries[0].revision == 2)
        #expect(summaries[0].status == "pending")

        let counts = try await store.outboxCounts(sessionId: "s1")
        #expect(counts["pending"] == 1)
        #expect(try await store.outboxCounts(sessionId: "other").isEmpty)
    }

    @Test func hasActiveOtherModuleGate() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        try await store.markOutboxStatus(xmpPath: "/v/IMG_1.xmp", status: "written")

        #expect(try await store.hasActiveOtherModule(sessionId: "s1", module: "similarity"), "其他批量模块的 written 行阻塞")
        #expect(try await store.hasActiveOtherModule(sessionId: "s1", module: "face-keyword") == false, "同模块不阻塞")
        #expect(try await store.hasActiveOtherModule(sessionId: "s2", module: "similarity") == false)

        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling")]), dirtyFields: []
        )
        try await store.markOutboxStatus(xmpPath: "/v/IMG_2.xmp", status: "written")
        #expect(try await store.hasActiveOtherModule(sessionId: "s2", module: "similarity") == false)
    }

    @Test func recoverableAndOrphanQueries() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        try await store.markOutboxStatus(xmpPath: "/v/IMG_1.xmp", status: "failed")
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])
        try await store.markOutboxStatus(xmpPath: "/v/IMG_2.xmp", status: "writing")
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg", patch: p, dirtyFields: [])
        try await store.markOutboxStatus(xmpPath: "/v/IMG_3.xmp", status: "synced")

        #expect(try await store.recoverableOutbox().map(\.xmpPath).sorted() == ["/v/IMG_1.xmp", "/v/IMG_2.xmp"], "pending/writing/failed")
        #expect(try await store.recoverableActiveOutbox().map(\.xmpPath).sorted() == ["/v/IMG_1.xmp", "/v/IMG_2.xmp"])

        try await database.run("DELETE FROM sessions WHERE id = 's2'")
        let orphans = try await store.orphanOutbox()
        #expect(orphans.map(\.xmpPath) == ["/v/IMG_2.xmp"], "孤儿按 updated_at 降序")
        #expect(try await store.recoverableActiveOutbox().map(\.xmpPath) == ["/v/IMG_1.xmp"], "孤儿不在 active 恢复集")
    }

    @Test func claimStateMachine() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])

        #expect(try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        var row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == "writing")
        #expect(row?.attemptCount == 1)
        #expect(try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1) == false, "writing 不可重复认领")
        #expect(try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 2) == false)

        try await store.recoverInterruptedOutbox()
        row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == "pending")
        #expect(try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1), "恢复后可再认领")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.attemptCount == 2)
    }

    @Test func markWrittenSetsRevisionAndFingerprint() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])

        try await store.markOutboxWritten(
            xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp-1",
            baseValues: JSONValue.object(["rating": JSONValue.int(3)]), backupPath: "/b/1"
        )
        var row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == "written", "revision 匹配 → written")
        #expect(row?.persistedRevision == 1)
        #expect(row?.baseFingerprint == "fp-1")
        #expect(row?.baseValuesJSON.contains("\"rating\"") == true)
        #expect(row?.backupPath == "/b/1")

        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        try await store.markOutboxWritten(
            xmpPath: "/v/IMG_1.xmp", revision: 3, fingerprint: "fp-2", baseValues: .object([:]), backupPath: "/b/2"
        )
        row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == "pending", "写入的 revision 与当前行 revision 不匹配 → 保持 pending")
        #expect(row?.revision == 2)
        #expect(row?.persistedRevision == 3, "persisted_revision 仍按写入参数记录")
    }

    @Test func statusTransitionsAndGuardedUpdates() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1)

        try await store.markOutboxStatus(xmpPath: "/v/IMG_1.xmp", status: "failed", errorMessage: "boom")
        var row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == "failed")
        #expect(row?.errorMessage == "boom")

        try await store.resetOutboxForRetry(xmpPath: "/v/IMG_1.xmp")
        row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == "pending")
        #expect(row?.attemptCount == 0)
        #expect(row?.errorMessage == "")

        try await store.setOutboxBackupPath(xmpPath: "/v/IMG_1.xmp", backupPath: "/b/1")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.backupPath == "/b/1")
        try await store.setOutboxBackupPath(xmpPath: "/v/IMG_1.xmp", backupPath: "/b/2")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.backupPath == "/b/1", "backup_path 非空时不覆盖")

        try await store.initializeOutboxBaseline(
            xmpPath: "/v/IMG_1.xmp", baselineFingerprint: "bf", baselineValues: JSONValue.object(["a": JSONValue.bool(true)])
        )
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.baseFingerprint == "bf")
        try await store.initializeOutboxBaseline(xmpPath: "/v/IMG_1.xmp", baselineFingerprint: "bf2", baselineValues: .object([:]))
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.baseFingerprint == "bf", "base_fingerprint 非空时不覆盖")
    }

    @Test func resolveConflict() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: ["rating"])
        try await store.markOutboxStatus(xmpPath: "/v/IMG_1.xmp", status: "conflict")

        try await store.resolveOutboxConflict(
            xmpPath: "/v/IMG_1.xmp", patch: p, dirtyFields: [], baselineFingerprint: "",
            baselineValues: .object([:]), acceptRemote: true
        )
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp") == nil)
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 0, "会话链接随行级联删除")

        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: ["rating"])
        try await store.markOutboxStatus(xmpPath: "/v/IMG_2.xmp", status: "conflict")
        try await store.resolveOutboxConflict(
            xmpPath: "/v/IMG_2.xmp",
            patch: JSONValue.object(["keywords": JSONValue.array([JSONValue.string("x")])]),
            dirtyFields: ["keywords"],
            baselineFingerprint: "bf",
            baselineValues: JSONValue.object(["k": JSONValue.string("v")]),
            acceptRemote: false
        )
        let row = try await store.outboxEntry(xmpPath: "/v/IMG_2.xmp")
        #expect(row?.status == "pending")
        #expect(row?.revision == 2)
        #expect(row?.dirty == ["keywords"])
        #expect(row?.patch["keywords"]?.arrayValue == ["x"])
        #expect(row?.baseFingerprint == "bf")
        #expect(try await store.outboxSessionIds(xmpPath: "/v/IMG_2.xmp") != [])
    }

    @Test func markSessionSynced() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        for index in 1...2 {
            _ = try await store.mergeOutboxPatch(
                xmpPath: "/v/IMG_\(index).xmp", sessionId: "s1", photoPath: "/v/IMG_\(index).jpg", patch: p, dirtyFields: []
            )
        }
        for index in 1...2 {
            _ = try await store.claimOutbox(xmpPath: "/v/IMG_\(index).xmp", expectedRevision: 1)
            try await store.markOutboxWritten(
                xmpPath: "/v/IMG_\(index).xmp", revision: 1, fingerprint: "f", baseValues: .object([:]), backupPath: ""
            )
        }

        try await store.markSessionSynced(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.status == "synced")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_2.xmp")?.status == "synced")
        let confirmed = try await database.queryOne(
            "SELECT confirmed_at FROM metadata_outbox_sessions WHERE xmp_path = '/v/IMG_1.xmp'"
        )
        #expect(confirmed?.text("confirmed_at") != "")
    }

    @Test func markSessionSyncedRequiresAllConfirmed() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s2", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])

        _ = try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 2)
        try await store.markOutboxWritten(xmpPath: "/v/IMG_1.xmp", revision: 2, fingerprint: "f", baseValues: .object([:]), backupPath: "")
        _ = try await store.claimOutbox(xmpPath: "/v/IMG_2.xmp", expectedRevision: 1)
        try await store.markOutboxWritten(xmpPath: "/v/IMG_2.xmp", revision: 1, fingerprint: "f", baseValues: .object([:]), backupPath: "")

        try await store.markSessionSynced(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.status == "written", "s2 链接未确认 → 不 synced")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_2.xmp")?.status == "synced", "s1 链接已确认 → synced")
        let confirmed = try await database.queryOne(
            "SELECT confirmed_at FROM metadata_outbox_sessions WHERE xmp_path = '/v/IMG_1.xmp' AND session_id = 's1'"
        )
        #expect(confirmed?.text("confirmed_at") != "", "s1 链接被确认")
    }

    @Test func deletesAndDiscard() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])
        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s2", photoPath: "/v/IMG_3.jpg", patch: p, dirtyFields: [])
        try await database.run("UPDATE metadata_outbox SET status = 'written', source_module = 'similarity' WHERE xmp_path = '/v/IMG_3.xmp'")

        try await store.discardModulePending(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp") == nil)
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_2.xmp") == nil)
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_3.xmp") != nil, "written 行不丢弃")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 1, "链接随行级联删除")

        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_4.xmp", sessionId: "s1", photoPath: "/v/IMG_4.jpg", patch: p, dirtyFields: [])
        try await store.clearOutboxBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/never")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_4.xmp")?.backupPath == "")
        try await store.setOutboxBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/4")
        try await store.clearOutboxBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/4")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_4.xmp")?.backupPath == "")

        try await store.deleteOutboxByRevision(xmpPath: "/v/IMG_4.xmp", revision: 999)
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_4.xmp") != nil, "revision 不匹配不删除")
        try await store.deleteOutboxByRevision(xmpPath: "/v/IMG_4.xmp", revision: 1)
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_4.xmp") == nil)

        _ = try await store.mergeOutboxPatch(xmpPath: "/v/IMG_5.xmp", sessionId: "s1", photoPath: "/v/IMG_5.jpg", patch: p, dirtyFields: [])
        try await store.deleteOutbox(xmpPath: "/v/IMG_5.xmp")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_5.xmp") == nil)
    }

    // MARK: CAS markOutboxStatus / recoverInterruptedOutbox

    @Test func markOutboxStatusCASUpdatesMatchingRevision() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: []
        )

        let updated = try await store.markOutboxStatus(
            xmpPath: "/v/IMG_1.xmp", expectedRevision: 1, status: .failed, errorMessage: "boom"
        )
        #expect(updated == true, "revision 命中 → true")
        let row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.status == OutboxStatus.failed.rawValue)
        #expect(row?.errorMessage == "boom")
        #expect(row?.revision == 1, "CAS 不推进 revision")
    }

    @Test func markOutboxStatusCASRejectsStaleRevision() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        for _ in 1...2 {
            _ = try await store.mergeOutboxPatch(
                xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: []
            )
        }
        try await store.markOutboxStatus(xmpPath: "/v/IMG_1.xmp", status: "conflict")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.revision == 2)

        let updated = try await store.markOutboxStatus(
            xmpPath: "/v/IMG_1.xmp", expectedRevision: 1, status: .synced, errorMessage: "stale"
        )
        #expect(updated == false, "stale revision → false")
        let row = try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")
        #expect(row?.revision == 2, "行保持最新 revision")
        #expect(row?.status == "conflict", "stale CAS 不改 DB")
        #expect(row?.errorMessage == "", "stale CAS 不改 error_message")
    }

    @Test func recoverInterruptedOutboxOnlyResetsWritingRows() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        for index in 1...3 {
            _ = try await store.mergeOutboxPatch(
                xmpPath: "/v/IMG_\(index).xmp", sessionId: "s1", photoPath: "/v/IMG_\(index).jpg", patch: p, dirtyFields: []
            )
        }
        #expect(try await store.claimOutbox(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1), "IMG_1 → writing")
        try await store.markOutboxStatus(xmpPath: "/v/IMG_2.xmp", status: "failed")

        let recovered = try await store.recoverInterruptedOutbox()
        #expect(recovered == 1, "只计 writing 行的受影响数")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp")?.status == "pending")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_2.xmp")?.status == "failed", "failed 行不动")
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_3.xmp")?.status == "pending", "pending 行不动")

        #expect(try await store.recoverInterruptedOutbox() == 0, "无 writing 行 → 0")
    }

    // MARK: W4-1b：批量与投影命令

    private func insertPhoto(
        _ database: SQLiteDatabase,
        id: String,
        sessionId: String,
        filepath: String
    ) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at)
            VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text(filepath)]
        )
    }

    /// 批量 merge：1000 条小样本，revision 单调、dirty 合并、结果顺序与入参一致。
    @Test func mergeOutboxPatchesMergesBatchWithMonotonicRevisions() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let requests = (0..<1000).map { index in
            OutboxMergeRequest(
                xmpPath: "/v/IMG_\(index).xmp",
                sessionId: "s1",
                photoPath: "/v/IMG_\(index).jpg",
                patch: JSONValue.object(["source": JSONValue.string("face-keyword")]),
                dirtyFields: ["keywords"]
            )
        }
        let records = try await store.mergeOutboxPatches(requests)
        #expect(records.count == 1000)
        #expect(records.allSatisfy { $0.revision == 1 })
        #expect(records.first?.xmpPath == "/v/IMG_0.xmp", "返回顺序与入参一致")
        #expect(records.last?.xmpPath == "/v/IMG_999.xmp")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox") == 1000)
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 1000)

        let second = try await store.mergeOutboxPatches([
            OutboxMergeRequest(
                xmpPath: "/v/IMG_0.xmp", sessionId: "s1", photoPath: "/v/IMG_0.jpg",
                patch: JSONValue.object(["rating": JSONValue.int(5)]), dirtyFields: ["rating"]
            ),
        ])
        #expect(second.count == 1)
        #expect(second[0].revision == 2, "既有路径 revision+1")
        #expect(second[0].dirty == ["keywords", "rating"], "dirty_fields 去重合并")
        #expect(second[0].patch["source"]?.stringValue == "face-keyword", "旧 patch 保留")
        #expect(second[0].patch["rating"] == .number(5))
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox") == 1000)
    }

    /// 单事务证明：第 2 条注入失败后，第 1 条（以及 sessions 边）也必须回滚。
    @Test func mergeOutboxPatchesRollsBackWholeBatchOnFailure() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await database.execute(
            """
            CREATE TRIGGER reject_second_merge BEFORE INSERT ON metadata_outbox
            WHEN NEW.xmp_path = '/v/IMG_2.xmp'
            BEGIN SELECT RAISE(ABORT, 'injected merge failure'); END
            """
        )
        await #expect(throws: SQLiteFailure.self) {
            _ = try await store.mergeOutboxPatches((1...3).map { index in
                OutboxMergeRequest(
                    xmpPath: "/v/IMG_\(index).xmp", sessionId: "s1", photoPath: "/v/IMG_\(index).jpg",
                    patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: []
                )
            })
        }
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox") == 0, "第 1 条同事务回滚")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 0)
        #expect(await database.currentTransactionDepth == 0)
    }

    /// 空参数：三个批量命令都返回空/0，且不开事务。
    @Test func batchCommandsReturnEmptyForEmptyInput() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        #expect(try await store.mergeOutboxPatches([]).isEmpty)
        #expect(try await store.outboxEntries(xmpPaths: []).isEmpty)
        #expect(try await store.reconcileWritebackProjection(sessionId: "s1", module: "m", snapshot: [:]) == 0)
        #expect(await database.currentTransactionDepth == 0)
    }

    /// 批量读跨 400 分块、去重、忽略缺失路径。
    @Test func outboxEntriesByPathsChunksAndDedupes() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let requests = (0..<450).map { index in
            OutboxMergeRequest(
                xmpPath: "/v/IMG_\(index).xmp", sessionId: "s1", photoPath: "/v/IMG_\(index).jpg",
                patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: []
            )
        }
        _ = try await store.mergeOutboxPatches(requests)
        let paths = requests.map(\.xmpPath)
        let all = try await store.outboxEntries(xmpPaths: paths + [paths[0], "/v/missing.xmp"])
        #expect(all.count == 450, "重复路径不重复返回，缺失路径忽略")
        #expect(Set(all.map(\.xmpPath)) == Set(paths))
        #expect(try await store.outboxEntries(xmpPaths: ["/v/missing.xmp"]).isEmpty)
    }

    /// reconcile 幂等：重复调用返回 0；只写 xmp_status，不动 attempt_count/error_message。
    @Test func reconcileWritebackProjectionIsIdempotentAndKeepsAttemptCount() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/v/IMG_1.jpg")
        try await database.run(
            """
            INSERT INTO writeback_items
              (photo_id, photo_path, session_id, module, xmp_path, xmp_status, error_message, attempt_count, last_attempt_at)
            VALUES ('p1', '/v/IMG_1.jpg', 's1', 'face-keyword', '/v/IMG_1.xmp', 'pending', 'boom', 7, '2026-01-01T00:00:00.000Z')
            """
        )

        let first = try await store.reconcileWritebackProjection(
            sessionId: "s1", module: "face-keyword",
            snapshot: ["/v/IMG_1.xmp": .written, "/v/missing.xmp": .failed]
        )
        #expect(first == 1, "只计实际存在的行")
        let second = try await store.reconcileWritebackProjection(
            sessionId: "s1", module: "face-keyword",
            snapshot: ["/v/IMG_1.xmp": .written]
        )
        #expect(second == 0, "幂等：已是目标状态不再计入")

        let item = try await store.writebackItem(itemId: 1)
        #expect(item?.xmpStatus == "written")
        #expect(item?.attemptCount == 7, "投影不得改 attempt_count")
        #expect(item?.errorMessage == "boom", "投影只写 xmp_status")
        #expect(
            try await store.reconcileWritebackProjection(
                sessionId: "s1", module: "other", snapshot: ["/v/IMG_1.xmp": .failed]
            ) == 0,
            "module 不匹配不写"
        )
    }

    /// 接受远端值：缓存 upsert + 决策更新 + 清理 pending 投影与 outbox 行。
    @Test func applyAcceptedRemoteValuesUpdatesCacheDecisionAndCleansRows() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/v/IMG_1.jpg")
        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: ["rating"]
        )
        try await store.saveWritebackItems(
            sessionId: "s1", module: "metadata",
            items: [
                WritebackItemInput(
                    photoId: "p1", photoPath: "/v/IMG_1.jpg", module: "metadata",
                    keywords: [], xmpPath: "/v/IMG_1.xmp", backupPath: ""
                ),
            ]
        )
        try await database.run(
            """
            INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating, color_label, updated_at)
            VALUES ('s1', 'p1', 'g1', 'pending', 0, 'None', '2026-01-01T00:00:00.000Z')
            """
        )

        let processed = try await store.applyAcceptedRemoteValues(
            sessionId: "s1", xmpPath: "/v/IMG_1.xmp", rating: 4, label: "Green", keywords: ["k1", "k2"]
        )
        #expect(processed == 1)
        #expect(try await store.outboxEntry(xmpPath: "/v/IMG_1.xmp") == nil, "outbox 行删除")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 0, "sessions 边 CASCADE")
        #expect(
            try await rowCount(database, "SELECT COUNT(*) FROM writeback_items WHERE xmp_path = '/v/IMG_1.xmp'") == 0,
            "pending 投影行删除"
        )
        let cache = try await database.queryOne(
            "SELECT keywords, rating, label FROM photo_metadata_cache WHERE photo_id = 'p1'"
        )
        #expect((try? JSONValue.parse(cache?.text("keywords") ?? ""))?.arrayValue == ["k1", "k2"])
        #expect(cache?.int("rating") == 4)
        #expect(cache?.text("label") == "Green")
        let decision = try await database.queryOne(
            "SELECT rating, color_label FROM culling_decisions WHERE photo_id = 'p1'"
        )
        #expect(decision?.int("rating") == 4)
        #expect(decision?.text("color_label") == "Green")
    }

    /// nil 字段（未被接受）不得覆盖缓存/决策中的原值。
    @Test func applyAcceptedRemoteValuesKeepsUnacceptedFields() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/v/IMG_1.jpg")
        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: ["rating"]
        )
        try await database.run(
            """
            INSERT INTO photo_metadata_cache (photo_id, session_id, keywords, rating, label, cached_at)
            VALUES ('p1', 's1', '[\"old\"]', 2, 'Red', '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run(
            """
            INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating, color_label, updated_at)
            VALUES ('s1', 'p1', 'g1', 'keep', 2, 'Red', '2026-01-01T00:00:00.000Z')
            """
        )

        let processed = try await store.applyAcceptedRemoteValues(
            sessionId: "s1", xmpPath: "/v/IMG_1.xmp", rating: nil, label: nil, keywords: ["new"]
        )
        #expect(processed == 1)
        let cache = try await database.queryOne(
            "SELECT keywords, rating, label FROM photo_metadata_cache WHERE photo_id = 'p1'"
        )
        #expect((try? JSONValue.parse(cache?.text("keywords") ?? ""))?.arrayValue == ["new"])
        #expect(cache?.int("rating") == 2, "rating=nil 保持原值")
        #expect(cache?.text("label") == "Red", "label=nil 保持原值")
        let decision = try await database.queryOne(
            "SELECT rating, color_label FROM culling_decisions WHERE photo_id = 'p1'"
        )
        #expect(decision?.int("rating") == 2)
        #expect(decision?.text("color_label") == "Red")
    }

    /// 单事务整批回滚：决策更新被注入失败后，先前照片的缓存 upsert 与清理都必须回滚。
    @Test func applyAcceptedRemoteValuesRollsBackWholeBatchOnFailure() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/v/IMG_1.jpg")
        _ = try await store.mergeOutboxPatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: ["rating"]
        )
        try await store.saveWritebackItems(
            sessionId: "s1", module: "metadata",
            items: [
                WritebackItemInput(
                    photoId: "p1", photoPath: "/v/IMG_1.jpg", module: "metadata",
                    keywords: [], xmpPath: "/v/IMG_1.xmp", backupPath: ""
                ),
            ]
        )
        try await database.run(
            """
            INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating, color_label, updated_at)
            VALUES ('s1', 'p1', 'g1', 'pending', 0, 'None', '2026-01-01T00:00:00.000Z')
            """
        )
        // 缓存 upsert 先执行成功，随后决策更新被注入失败：整批必须回滚缓存写入。
        try await database.execute(
            """
            CREATE TRIGGER reject_decision_update BEFORE UPDATE ON culling_decisions
            WHEN NEW.photo_id = 'p1'
            BEGIN SELECT RAISE(ABORT, 'injected decision failure'); END
            """
        )

        await #expect(throws: SQLiteFailure.self) {
            _ = try await store.applyAcceptedRemoteValues(
                sessionId: "s1", xmpPath: "/v/IMG_1.xmp", rating: 3, label: "Blue", keywords: ["x"]
            )
        }
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM photo_metadata_cache") == 0, "缓存 upsert 回滚")
        #expect(
            try await rowCount(database, "SELECT COUNT(*) FROM metadata_outbox WHERE xmp_path = '/v/IMG_1.xmp'") == 1,
            "outbox 行保留"
        )
        #expect(
            try await rowCount(
                database,
                "SELECT COUNT(*) FROM writeback_items WHERE xmp_path = '/v/IMG_1.xmp' AND xmp_status = 'pending'"
            ) == 1,
            "pending 投影行保留"
        )
        let decision = try await database.queryOne(
            "SELECT rating, color_label FROM culling_decisions WHERE photo_id = 'p1'"
        )
        #expect(decision?.int("rating") == 0, "被注入失败的决策未被修改")
        #expect(decision?.text("color_label") == "None")
        #expect(await database.currentTransactionDepth == 0)
    }
}
