// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/MetadataOutboxRepoTests.swift
// TS 源: desktop/src/main/db/repositories/metadata-outbox.repo.ts

import Foundation
import Testing
@testable import GatherCore

struct MetadataOutboxRepoTests {
    private func makeRepo() throws -> (DBConnection, MetadataOutboxRepo) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertSession(db, "s2")
        return (db, MetadataOutboxRepo(connection: db))
    }

    @Test func getUnknownAndMergePatchCreate() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(try repo.get("/v/IMG_1.xmp") == nil)

        let patch = JSONValue.object([
            "source": JSONValue.string("face-keyword"),
            "keywords": JSONValue.array([JSONValue.string("a")]),
        ])
        let row = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: patch, dirtyFields: ["keywords"])
        #expect(row.status == "pending")
        #expect(row.revision == 1)
        #expect(row.persistedRevision == 0)
        #expect(row.sourceModule == "face-keyword")
        #expect(row.ownerSessionId == "s1")
        #expect(row.photoPath == "/v/IMG_1.jpg")
        #expect(row.dirty == ["keywords"])
        #expect(row.patch["keywords"]?.arrayValue == ["a"])
        #expect(try repo.getSessionIds("/v/IMG_1.xmp") == ["s1"])
    }

    @Test func mergePatchMergesWhenNotNewRevision() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_1.xmp",
            sessionId: "s1",
            photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("face-keyword"), "keywords": JSONValue.array([JSONValue.string("a")])]),
            dirtyFields: ["keywords"]
        )
        // 状态仍为 pending → 同 revision 内合并 patch/dirty
        let row = try repo.mergePatch(
            xmpPath: "/v/IMG_1.xmp",
            sessionId: "s1",
            photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["rating": JSONValue.int(4)]),
            dirtyFields: ["rating"]
        )
        #expect(row.revision == 2)
        #expect(row.dirty == ["keywords", "rating"], "dirty_fields 去重合并")
        #expect(row.patch["keywords"]?.arrayValue == ["a"])
        #expect(row.patch["rating"] == .number(4))
    }

    @Test func mergePatchStartsNewRevisionAfterWritten() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: ["rating"])
        try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1)
        try repo.markWritten(xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp", baseValues: .object([:]), backupPath: "/backup/xmp")

        // written 状态 → startsNewRevision → patch 不再合并
        let row = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["rating": JSONValue.int(5)]), dirtyFields: ["rating"])
        #expect(row.revision == 2)
        #expect(row.patch["rating"] == .number(5))
        #expect(row.dirty == ["rating"])
    }

    @Test func sessionScopedQueries() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p1 = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p1, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg", patch: p1, dirtyFields: [])
        // 同一 outbox 行再被 s2 观察（第二个 session 链接）
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s2", photoPath: "/v/IMG_1.jpg", patch: p1, dirtyFields: [])

        let bySession = try repo.getBySession("s1")
        #expect(bySession.count == 1)
        #expect(bySession[0].xmpPath == "/v/IMG_1.xmp")
        #expect(try repo.getSessionIds("/v/IMG_1.xmp") == ["s1", "s2"], "linked_at 排序")

        let summaries = try repo.getSummaryRowsBySession("s1")
        #expect(summaries.count == 1)
        #expect(summaries[0].xmpPath == "/v/IMG_1.xmp")
        #expect(summaries[0].revision == 2)
        #expect(summaries[0].status == "pending")

        let counts = try repo.countBySession("s1")
        #expect(counts["pending"] == 1)
        #expect(try repo.countBySession("other").isEmpty)
    }

    @Test func hasActiveOtherModuleGate() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        try repo.markStatus(xmpPath: "/v/IMG_1.xmp", status: "written")

        #expect(try repo.hasActiveOtherModule(sessionId: "s1", module: "similarity"), "其他批量模块的 written 行阻塞")
        #expect(!(try repo.hasActiveOtherModule(sessionId: "s1", module: "face-keyword")), "同模块不阻塞")
        #expect(!(try repo.hasActiveOtherModule(sessionId: "s2", module: "similarity")))

        // 非批量模块（culling/manual）不参与 gate
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg", patch: JSONValue.object(["source": JSONValue.string("culling")]), dirtyFields: [])
        try repo.markStatus(xmpPath: "/v/IMG_2.xmp", status: "written")
        #expect(!(try repo.hasActiveOtherModule(sessionId: "s2", module: "similarity")))
    }

    @Test func recoverableAndOrphanQueries() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        try repo.markStatus(xmpPath: "/v/IMG_1.xmp", status: "failed")
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])
        try repo.markStatus(xmpPath: "/v/IMG_2.xmp", status: "writing")
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg", patch: p, dirtyFields: [])
        try repo.markStatus(xmpPath: "/v/IMG_3.xmp", status: "synced")

        #expect(try repo.getRecoverable().map(\.xmpPath).sorted() == ["/v/IMG_1.xmp", "/v/IMG_2.xmp"], "pending/writing/failed")
        #expect(try repo.getRecoverableActive().map(\.xmpPath).sorted() == ["/v/IMG_1.xmp", "/v/IMG_2.xmp"])

        // 孤儿：删除 session 后 outbox 行保留、链接消失
        _ = try db.prepare("DELETE FROM sessions WHERE id = 's2'").run()
        let orphans = try repo.getOrphans()
        #expect(orphans.map(\.xmpPath) == ["/v/IMG_2.xmp"], "孤儿按 updated_at 降序")
        #expect(try repo.getRecoverableActive().map(\.xmpPath) == ["/v/IMG_1.xmp"], "孤儿不在 active 恢复集")
    }

    @Test func claimStateMachine() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])

        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        var row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "writing")
        #expect(row?.attemptCount == 1)
        #expect(!(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1)), "writing 不可重复认领")
        #expect(!(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 2)))

        try repo.recoverInterrupted()
        row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "pending")
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1), "恢复后可再认领")
        #expect(try repo.get("/v/IMG_1.xmp")?.attemptCount == 2)
    }

    @Test func markWrittenSetsRevisionAndFingerprint() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])

        try repo.markWritten(xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp-1", baseValues: JSONValue.object(["rating": JSONValue.int(3)]), backupPath: "/b/1")
        var row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "written", "revision 匹配 → written")
        #expect(row?.persistedRevision == 1)
        #expect(row?.baseFingerprint == "fp-1")
        #expect(row?.baseValuesJSON.contains("\"rating\"") == true)
        #expect(row?.backupPath == "/b/1")

        // revision 不匹配 → 保持 pending
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        try repo.markWritten(xmpPath: "/v/IMG_1.xmp", revision: 3, fingerprint: "fp-2", baseValues: .object([:]), backupPath: "/b/2")
        row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "pending", "写入的 revision 与当前行 revision 不匹配 → 保持 pending")
        #expect(row?.revision == 2)
        #expect(row?.persistedRevision == 3, "persisted_revision 仍按写入参数记录")
    }

    @Test func statusTransitionsAndGuardedUpdates() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1)

        try repo.markStatus(xmpPath: "/v/IMG_1.xmp", status: "failed", errorMessage: "boom")
        var row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "failed")
        #expect(row?.errorMessage == "boom")

        try repo.resetForRetry("/v/IMG_1.xmp")
        row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "pending")
        #expect(row?.attemptCount == 0)
        #expect(row?.errorMessage == "")

        // resetForRetry 只作用于 failed
        try repo.setBackupPath(xmpPath: "/v/IMG_1.xmp", backupPath: "/b/1")
        #expect(try repo.get("/v/IMG_1.xmp")?.backupPath == "/b/1")
        try repo.setBackupPath(xmpPath: "/v/IMG_1.xmp", backupPath: "/b/2")
        #expect(try repo.get("/v/IMG_1.xmp")?.backupPath == "/b/1", "backup_path 非空时不覆盖")

        try repo.initializeBaseline(xmpPath: "/v/IMG_1.xmp", baselineFingerprint: "bf", baselineValues: JSONValue.object(["a": JSONValue.bool(true)]))
        #expect(try repo.get("/v/IMG_1.xmp")?.baseFingerprint == "bf")
        try repo.initializeBaseline(xmpPath: "/v/IMG_1.xmp", baselineFingerprint: "bf2", baselineValues: .object([:]))
        #expect(try repo.get("/v/IMG_1.xmp")?.baseFingerprint == "bf", "base_fingerprint 非空时不覆盖")
    }

    @Test func resolveConflict() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("manual")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: ["rating"])
        try repo.markStatus(xmpPath: "/v/IMG_1.xmp", status: "conflict")

        // acceptRemote → 整行删除
        try repo.resolveConflict(xmpPath: "/v/IMG_1.xmp", patch: p, dirtyFields: [], baselineFingerprint: "", baselineValues: .object([:]), acceptRemote: true)
        #expect(try repo.get("/v/IMG_1.xmp") == nil)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 0, "会话链接随行级联删除")

        // 保留本地 → patch/dirty 替换、revision +1、status pending
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: ["rating"])
        try repo.markStatus(xmpPath: "/v/IMG_2.xmp", status: "conflict")
        try repo.resolveConflict(
            xmpPath: "/v/IMG_2.xmp",
            patch: JSONValue.object(["keywords": JSONValue.array([JSONValue.string("x")])]),
            dirtyFields: ["keywords"],
            baselineFingerprint: "bf",
            baselineValues: JSONValue.object(["k": JSONValue.string("v")]),
            acceptRemote: false
        )
        let row = try repo.get("/v/IMG_2.xmp")
        #expect(row?.status == "pending")
        #expect(row?.revision == 2)
        #expect(row?.dirty == ["keywords"])
        #expect(row?.patch["keywords"]?.arrayValue == ["x"])
        #expect(row?.baseFingerprint == "bf")
        #expect(try repo.getSessionIds("/v/IMG_2.xmp") != [])
    }

    @Test func markSessionSynced() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])
        for path in ["/v/IMG_1.xmp", "/v/IMG_2.xmp"] {
            _ = try repo.claim(xmpPath: path, expectedRevision: 1)
            try repo.markWritten(xmpPath: path, revision: 1, fingerprint: "f", baseValues: .object([:]), backupPath: "")
        }

        try repo.markSessionSynced(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "synced")
        #expect(try repo.get("/v/IMG_2.xmp")?.status == "synced")
        let confirmed = try db.prepare("SELECT confirmed_at FROM metadata_outbox_sessions WHERE xmp_path = '/v/IMG_1.xmp'").get()
        #expect(confirmed?[0].textValue != "")
    }

    @Test func markSessionSyncedRequiresAllConfirmed() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        // IMG_1 同时被 s1 和 s2 观察（两次 mergePatch 后 revision=2）
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s2", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        // IMG_2 只被 s1 观察（revision=1）
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])

        _ = try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 2)
        try repo.markWritten(xmpPath: "/v/IMG_1.xmp", revision: 2, fingerprint: "f", baseValues: .object([:]), backupPath: "")
        _ = try repo.claim(xmpPath: "/v/IMG_2.xmp", expectedRevision: 1)
        try repo.markWritten(xmpPath: "/v/IMG_2.xmp", revision: 1, fingerprint: "f", baseValues: .object([:]), backupPath: "")

        try repo.markSessionSynced(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "written", "s2 链接未确认 → 不 synced")
        #expect(try repo.get("/v/IMG_2.xmp")?.status == "synced", "s1 链接已确认 → synced")
        let confirmed = try db.prepare("SELECT confirmed_at FROM metadata_outbox_sessions WHERE xmp_path = '/v/IMG_1.xmp' AND session_id = 's1'").get()
        #expect(confirmed?[0].textValue != "", "s1 链接被确认")
    }

    @Test func deletesAndDiscard() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s2", photoPath: "/v/IMG_3.jpg", patch: p, dirtyFields: [])
        // IMG_3 属于另一个模块且 written（不被 discard）
        _ = try db.prepare("UPDATE metadata_outbox SET status = 'written', source_module = 'similarity' WHERE xmp_path = '/v/IMG_3.xmp'").run()

        try repo.discardModulePending(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try repo.get("/v/IMG_1.xmp") == nil)
        #expect(try repo.get("/v/IMG_2.xmp") == nil)
        #expect(try repo.get("/v/IMG_3.xmp") != nil, "written 行不丢弃")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_outbox_sessions") == 1, "链接随行级联删除")

        _ = try repo.mergePatch(xmpPath: "/v/IMG_4.xmp", sessionId: "s1", photoPath: "/v/IMG_4.jpg", patch: p, dirtyFields: [])
        try repo.clearBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/never")
        #expect(try repo.get("/v/IMG_4.xmp")?.backupPath == "")
        try repo.setBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/4")
        try repo.clearBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/4")
        #expect(try repo.get("/v/IMG_4.xmp")?.backupPath == "")

        try repo.deleteByRevision(xmpPath: "/v/IMG_4.xmp", revision: 999)
        #expect(try repo.get("/v/IMG_4.xmp") != nil, "revision 不匹配不删除")
        try repo.deleteByRevision(xmpPath: "/v/IMG_4.xmp", revision: 1)
        #expect(try repo.get("/v/IMG_4.xmp") == nil)

        _ = try repo.mergePatch(xmpPath: "/v/IMG_5.xmp", sessionId: "s1", photoPath: "/v/IMG_5.jpg", patch: p, dirtyFields: [])
        try repo.delete("/v/IMG_5.xmp")
        #expect(try repo.get("/v/IMG_5.xmp") == nil)
    }
}
