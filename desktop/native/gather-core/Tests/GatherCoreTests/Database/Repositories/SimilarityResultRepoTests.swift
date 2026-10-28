// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/SimilarityResultRepoTests.swift
// SimilarityResultRepo 测试：replace/replaceForThreshold、getLatest 排除
// precomputed 标记、阈值查询、成员映射缓存、组员 JOIN 查询。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

private func makeDB() throws -> DBConnection {
    let db = try makeTestDB()
    return db
}

private func insertSession(_ db: DBConnection, id: String) throws {
    _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id)])
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String, filepath: String) throws {
    _ = try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at) VALUES (?, ?, ?, 'f.jpg', 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id), .text(sessionId), .text(filepath)])
}

@Suite(.serialized)
struct SimilarityResultRepoTests {
    @Test func replaceInsertsResultWithMembersAndGetLatestFindsIt() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = SimilarityResultRepo(connection: db)

        let resultId = try repo.replace(
            sessionId: "s1", groupsJson: "{\"groups\":2}", statsJson: "{\"groupCount\":2}",
            threshold: 12, minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 1)]
        )
        #expect(resultId > 0)

        let latest = try repo.getLatest(sessionId: "s1")
        #expect(latest != nil)
        #expect(latest?.id == resultId)
        #expect(latest?.paramThreshold == 12)
        #expect(latest?.paramMinGroupSize == 2)
        #expect(latest?.groupsJson == "{\"groups\":2}")
        #expect(latest?.statsJson == "{\"groupCount\":2}")
        #expect(!latest!.createdAt.isEmpty)

        let byThreshold = try repo.getByThreshold(sessionId: "s1", threshold: 12)
        #expect(byThreshold?.id == resultId)
        #expect(try repo.getByThreshold(sessionId: "s1", threshold: 15) == nil)
    }

    @Test func replaceRemovesPreviousSessionResults() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        let repo = SimilarityResultRepo(connection: db)

        let first = try repo.replace(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: [])
        let second = try repo.replace(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: [])
        #expect(second > first)

        // 同会话只剩最新一条；旧阈值不可再查。
        let count = try db.prepare("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's1'").get()
        #expect(count?[0].intValue == 1)
        #expect(try repo.getByThreshold(sessionId: "s1", threshold: 10) == nil)
        #expect(try repo.getLatest(sessionId: "s1")?.id == second)
    }

    @Test func replaceForThresholdKeepsOtherThresholds() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        let repo = SimilarityResultRepo(connection: db)

        let t10 = try repo.replaceForThreshold(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: [])
        let t12 = try repo.replaceForThreshold(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: [])
        let t12again = try repo.replaceForThreshold(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: [])

        #expect(try repo.getByThreshold(sessionId: "s1", threshold: 10)?.id == t10)
        #expect(try repo.getByThreshold(sessionId: "s1", threshold: 12)?.id == t12again)
        // 同阈值替换后旧行删除。
        let count12 = try db.prepare("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's1' AND param_threshold = 12").get()
        #expect(count12?[0].intValue == 1)
    }

    @Test func getLatestExcludesPrecomputedTierRows() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        let repo = SimilarityResultRepo(connection: db)

        // precomputed 标记行先插入（id 更小），正常行后插入（id 更大）。
        _ = try db.prepare(
            "INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at) VALUES ('s1', '{}', '{\"precomputed\":true}', 10, 2, '2026-01-01T00:00:00.000Z')"
        ).run()
        let normalId = try repo.replace(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 14, minGroupSize: 2, memberships: [])

        let latest = try repo.getLatest(sessionId: "s1")
        #expect(latest?.id == normalId)
        #expect(latest?.paramThreshold == 14)
    }

    @Test func getPhotoGroupMapMapsPhotoToResultAndGroup() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s1", filepath: "/c.jpg")
        let repo = SimilarityResultRepo(connection: db)

        let resultId = try repo.replace(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0), (photoId: "p3", groupIndex: 1)]
        )

        let map = try repo.getPhotoGroupMap(sessionId: "s1", resultId: resultId)
        #expect(map == ["p1": "\(resultId):0", "p2": "\(resultId):0", "p3": "\(resultId):1"])

        // 未知 resultId → 空映射；缓存命中返回相同内容。
        #expect(try repo.getPhotoGroupMap(sessionId: "s1", resultId: 999).isEmpty)
        #expect(try repo.getPhotoGroupMap(sessionId: "s1", resultId: resultId) == map)
    }

    @Test func replaceInvalidatesCachedMapsForSession() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertSession(db, id: "s2")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = SimilarityResultRepo(connection: db)

        let oldId = try repo.replace(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: [(photoId: "p1", groupIndex: 0)])
        _ = try repo.getPhotoGroupMap(sessionId: "s1", resultId: oldId)
        _ = try repo.getPhotoGroupMap(sessionId: "s2", resultId: 1)

        // replace 使 s1 的缓存失效；s2 的缓存保留。
        let newId = try repo.replace(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2, memberships: [(photoId: "p2", groupIndex: 0)])
        #expect(newId != oldId)
        let map = try repo.getPhotoGroupMap(sessionId: "s1", resultId: newId)
        #expect(map == ["p2": "\(newId):0"])
    }

    @Test func getGroupMembersJoinsPhotosAndOrdersByRowid() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s1", filepath: "/c.jpg")
        let repo = SimilarityResultRepo(connection: db)

        let resultId = try repo.replace(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2,
            memberships: [(photoId: "p2", groupIndex: 1), (photoId: "p1", groupIndex: 0), (photoId: "p3", groupIndex: 0)]
        )

        let members = try repo.getGroupMembers(sessionId: "s1", resultId: resultId)
        #expect(members != nil)
        #expect(members?.count == 3)
        // ORDER BY m.rowid：保持成员表写入顺序。
        #expect(members?[0] == SimilarityGroupMember(groupIndex: 1, photoId: "p2", filepath: "/b.jpg"))
        #expect(members?[1] == SimilarityGroupMember(groupIndex: 0, photoId: "p1", filepath: "/a.jpg"))
        #expect(members?[2] == SimilarityGroupMember(groupIndex: 0, photoId: "p3", filepath: "/c.jpg"))

        // 无成员行 → nil（老数据只有 groups_json 的场景）。
        let emptyResultId = try repo.replace(sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 20, minGroupSize: 2, memberships: [])
        #expect(try repo.getGroupMembers(sessionId: "s1", resultId: emptyResultId) == nil)
    }

    @Test func archivedMembersAreHiddenButResultIsNotEmpty() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s1", filepath: "/c.jpg")
        try insertPhoto(db, id: "p4", sessionId: "s1", filepath: "/d.jpg")
        let repo = SimilarityResultRepo(connection: db)
        let resultId = try repo.replace(
            sessionId: "s1", groupsJson: "{}", statsJson: "{}", threshold: 12, minGroupSize: 2,
            memberships: [
                (photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0),
                (photoId: "p3", groupIndex: 1), (photoId: "p4", groupIndex: 1),
            ])
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id IN ('p3', 'p4')")
            .run([.text("2026-10-28T00:00:00.000Z")])

        // 有成员行但整组归档：返回 []（不能返回 nil，否则上层会回退 groups_json）。
        let members = try #require(try repo.getGroupMembers(sessionId: "s1", resultId: resultId))
        #expect(members.map(\.photoId) == ["p1", "p2"])
        // 原始组大小仍可读（供上层区分"归档导致不足"与"本来就小"）。
        #expect(try repo.groupMemberCounts(sessionId: "s1", resultId: resultId) == [0: 2, 1: 2])
    }
}
