// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/CullingDecisionRepoTests.swift
// TS 源: desktop/src/main/db/repositories/culling-decision.repo.ts

import Foundation
import Testing
@testable import GatherCore

struct CullingDecisionRepoTests {
    private func makeRepo() throws -> (DBConnection, CullingDecisionRepo) {
        let db = try makeMigratedDB()
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

        // 同一 (session, photo) 重复 upsert 走 ON CONFLICT 更新，不新增行
        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g2", decision: "reject")
        row = try repo.getDecision(sessionId: "s1", photoId: "p1")
        #expect(row?.decision == "reject")
        #expect(row?.groupId == "g2")
        #expect(row?.updatedAt != row?.createdAt)
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

        #expect(try repo.getDecisionsFull("s1").count == 2)
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

    @Test func upsertManyRunsInTransaction() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let decisions = [
            CullingDecisionRepo.DecisionInput(photoId: "p1", groupId: "g1", decision: "keep"),
            CullingDecisionRepo.DecisionInput(photoId: "p2", groupId: "g1", decision: "reject"),
        ]
        try repo.upsertMany(sessionId: "s1", decisions: decisions)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM culling_decisions") == 2)

        // 再次 upsertMany 走 ON CONFLICT
        try repo.upsertMany(sessionId: "s1", decisions: [decisions[0]])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM culling_decisions") == 2)
    }

    @Test func resultPrefixQueries() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "42:0", decision: "keep")
        try repo.upsert(sessionId: "s1", photoId: "p2", groupId: "42:1", decision: "reject")
        try insertPhoto(db, id: "p3", sessionId: "s1")
        try repo.upsert(sessionId: "s1", photoId: "p3", groupId: "7:0", decision: "keep")

        let prefix = try repo.getByResultPrefix(sessionId: "s1", resultId: 42)
        #expect(prefix.count == 2)

        let counts = try repo.getCountsByResultPrefix(sessionId: "s1", resultId: 42)
        #expect(counts == [
            CullingDecisionCountRow(decision: "keep", cnt: 1),
            CullingDecisionCountRow(decision: "reject", cnt: 1),
        ])

        let total = try repo.getDecisionCounts("s1")
        #expect(total.contains(CullingDecisionCountRow(decision: "keep", cnt: 2)))
        #expect(total.contains(CullingDecisionCountRow(decision: "reject", cnt: 1)))
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

    @Test func batchRestoreDecisions() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        try repo.upsertState(
            sessionId: "s1",
            photoId: "p2",
            groupId: "g1",
            state: CullingDecisionStateInput(decision: "keep", rating: 3, colorLabel: "Blue", revision: 1)
        )

        try repo.batchRestoreDecisions(decisions: [
            CullingDecisionRepo.RestoreDecisionInput(sessionId: "s1", photoId: "p1", decision: "reject"),
            CullingDecisionRepo.RestoreDecisionInput(sessionId: "s1", photoId: "p2", decision: "reject"),
        ])
        #expect(try repo.getDecision(sessionId: "s1", photoId: "p1")?.decision == "reject")
        #expect(try repo.getDecision(sessionId: "s1", photoId: "p2")?.decision == "reject")
        #expect(try repo.getDecision(sessionId: "s1", photoId: "p2")?.rating == 3, "restore 只改 decision 列")
    }

    @Test func photoCascadeDeletesDecision() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(sessionId: "s1", photoId: "p1", groupId: "g1", decision: "keep")
        _ = try db.prepare("DELETE FROM photos WHERE id = 'p1'").run()
        #expect(try repo.getDecision(sessionId: "s1", photoId: "p1") == nil)
    }
}
