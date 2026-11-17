// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/CullingDecisionRepoTests.swift
// TS 源: desktop/src/main/db/repositories/culling-decision.repo.ts

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

struct CullingDecisionRepoTests {
    private func makeRepo() throws -> (DBConnection, CullingDecisionRepo) {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        return (db, CullingDecisionRepo(connection: db))
    }

    @Test func upsertCreatesThenUpdates() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        var row = try repo.getDecision(sessionId: "s1", photoId: "p1")
        #expect(row != nil)
        #expect(row?.decision == "keep")
        #expect(row?.groupId == "g1")
        #expect(row?.rating == 0)
        #expect(row?.decisionSource == "manual")
        #expect(row?.revision == 0)
        #expect(row?.createdAt != "")

        // 同一 (session, photo) 重复 upsert 走 ON CONFLICT 更新，不新增行。
        // 依赖墙钟毫秒分辨率（同毫秒两次写会让 updatedAt == createdAt）会引入
        // 2ms sleep；改为把 created_at 钉到固定旧时间戳——确定性验证 ON CONFLICT
        // 保留 created_at、只推进 updated_at。
        let pinnedCreatedAt = "2020-01-01T00:00:00.000Z"
        _ = try db.prepare(
            "UPDATE culling_decisions SET created_at = ? WHERE session_id = ? AND photo_id = ?"
        ).run([.text(pinnedCreatedAt), .text("s1"), .text("p1")])
        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g2", decision: "reject")
        row = try repo.getDecision(sessionId: "s1", photoId: "p1")
        #expect(row?.decision == "reject")
        #expect(row?.groupId == "g2")
        #expect(row?.createdAt == pinnedCreatedAt, "ON CONFLICT 必须保留 created_at")
        #expect(row?.updatedAt != row?.createdAt, "ON CONFLICT 必须推进 updated_at")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM culling_decisions") == 1)
    }

    @Test func gettersAndLiteProjection() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try repo.upsert(sessionId: "s1", photoId: "p2", groupId: "g1", decision: "reject")

        let lite = try repo.getDecisions("s1")
        #expect(lite.count == 2)
        #expect(lite.contains(CullingDecisionLiteRow(photoId: "p1", decision: "keep")))

        #expect(try repo.getBySession("s1").count == 2)
        #expect(try repo.getDecision(sessionId: "s1", photoId: "missing") == nil)
        #expect(try repo.getDecisions("other-session").isEmpty)
    }

    @Test func getByPhotoIdsEmptyAndChunked() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(try repo.getByPhotoIds(sessionId: "s1", photoIds: []).isEmpty)

        // 跨 800 分批边界：900 张照片各一条决策
        var photoIds: [String] = []
        for index in 0..<900 {
            let id = "bulk-\(index)"
            try insertPhoto(db, id: id, sessionId: "s1")
            photoIds.append(id)
            try repo.upsert(sessionId: "s1", photoId: id, groupId: "g", decision: "keep")
        }
        let rows = try repo.getByPhotoIds(sessionId: "s1", photoIds: photoIds)
        #expect(rows.count == 900)
        #expect(rows[899].photoId == "bulk-899")
    }

    @Test func upsertStatePersistsAllFields() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsertState(
            sessionId: "s1",
            photoId: "p1",
            groupId: "g1",
            state: CullingDecisionStateInput(decision: "keep", rating: 4, colorLabel: "Green", revision: 2)
        )
        let row = try repo.getDecision(sessionId: "s1", photoId: "p1")
        #expect(row?.rating == 4)
        #expect(row?.colorLabel == "Green")
        #expect(row?.revision == 2)
        #expect(row?.decisionSource == "manual")

        try repo.upsertState(
            sessionId: "s1",
            photoId: "p1",
            groupId: "g1",
            state: CullingDecisionStateInput(decision: "reject", rating: 1, colorLabel: "Red", revision: 3, source: "template")
        )
        let updated = try repo.getDecision(sessionId: "s1", photoId: "p1")
        #expect(updated?.rating == 1)
        #expect(updated?.revision == 3)
        #expect(updated?.decisionSource == "template")
    }

    @Test func upsertStateRejectsOutOfRangeRating() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        #expect(throws: DBError.self) {
            try repo.upsertState(
                sessionId: "s1",
                photoId: "p1",
                groupId: "g1",
                state: CullingDecisionStateInput(decision: "keep", rating: 6, colorLabel: "None", revision: 0)
            )
        }
    }

    @Test func deleteBySessionAndGroup() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try repo.upsert(sessionId: "s1", photoId: "p2", groupId: "g2", decision: "reject")

        try repo.deleteBySessionAndGroup(sessionId: "s1", groupId: "g1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM culling_decisions") == 1)

        try repo.deleteBySession("s1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM culling_decisions") == 0)
    }

    @Test func photoCascadeDeletesDecision() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        _ = try db.prepare("DELETE FROM photos WHERE id = 'p1'").run()
        #expect(try repo.getDecision(sessionId: "s1", photoId: "p1") == nil)
    }
}
