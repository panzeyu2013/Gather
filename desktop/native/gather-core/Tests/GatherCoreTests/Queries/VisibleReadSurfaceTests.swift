// desktop/native/gather-core/Tests/GatherCoreTests/Queries/VisibleReadSurfaceTests.swift
// P2：本轮"可见性谓词收敛"改到的三处**查询形态**必须有行为测试——
// 静态门禁只能防"手写裸谓词"，防不住 LEFT JOIN 变成 JOIN、SUM(CASE …) 写反、
// 嵌套代表行子查询漏过滤这类语义错误。
//
// 覆盖：人脸簇成员计数（LEFT JOIN 孤儿语义）、相似度组的全归档判定、
// 重复组可见成员/可见状态（嵌套 rep 子查询同源）。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("可见性查询形态（簇/相似度/重复组）")
struct VisibleReadSurfaceTests {
    private func archived(_ db: DBConnection, _ ids: [String]) throws {
        let list = ids.map { "'\($0)'" }.joined(separator: ",")
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id IN (\(list))")
            .run([.text("2026-10-28T00:00:00.000Z")])
    }

    @Test("人脸簇成员计数排除归档件；全部归档时簇不可见，孤儿绑定仍可见")
    func faceClusterCountsRespectVisibility() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/v/p2.jpg")
        let repo = FaceRepo(connection: db)
        _ = try repo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(
                    photoId: "p1", photoPath: "/v/p1.jpg", bbox: [0, 0, 1, 1], confidence: 0.9),
                FaceClusterMemberInput(
                    photoId: "p2", photoPath: "/v/p2.jpg", bbox: [0, 0, 1, 1], confidence: 0.8),
            ]),
        ])
        let clusterId = try #require(try repo.getClusters("s1").first?.id)

        try archived(db, ["p1"])
        var rows = try repo.getClusters("s1", includeMembers: true)
        #expect(rows.count == 1)
        #expect(rows[0].memberCount == 1, "归档件不贡献簇大小")
        #expect(rows[0].members?.map(\.photoId) == ["p2"], "成员清单也不得列出归档件")

        // 全部归档：簇从列表消失（没有可见成员且没有角色绑定）。
        try archived(db, ["p2"])
        rows = try repo.getClusters("s1", includeMembers: true)
        #expect(rows.isEmpty, "全部成员已移出的簇不得继续出现在人脸库")

        // 有角色绑定的孤儿簇仍可读（清理/解绑入口）。
        try repo.updateBinding(clusterId: clusterId, roleName: "Alice", keywords: ["kw"])
        rows = try repo.getClusters("s1", includeMembers: true)
        #expect(rows.count == 1, "孤儿绑定不得变成读不到的幽灵")
        #expect(rows[0].memberCount == 0)
    }

    @Test("相似度组：成员计数/成员清单排除归档，全归档组按 fully-archived 计")
    func similarityGroupsRespectVisibility() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/v/p2.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s1", filepath: "/v/p3.jpg")
        // 组 0：p1（可见）+ p2（归档）；组 1：p3（归档）。
        let resultId = try queryInsertSimilarityResult(
            db, sessionId: "s1",
            members: [("p1", 0), ("p2", 0), ("p3", 1)])
        try archived(db, ["p2", "p3"])
        let repo = SimilarityResultRepo(connection: db)

        // groupMemberCounts 的语义是"原始成员数"（用于区分"本来只有 1 张"），
        // 可见性由 countFullyArchivedGroups / getGroupMembers 负责。
        let counts = try repo.groupMemberCounts(sessionId: "s1", resultId: resultId)
        #expect(counts[0] == 2, "原始成员数含归档行")
        #expect(counts[1] == 1)

        let members = try #require(try repo.getGroupMembers(sessionId: "s1", resultId: resultId))
        #expect(members.map(\.photoId) == ["p1"], "成员清单不得列出归档件")

        #expect(try repo.countFullyArchivedGroups(sessionId: "s1", resultId: resultId) == 1,
                "只有组 1 的成员全部已移出")
    }

    @Test("重复组：可见成员与可见状态排除归档件，组详情同样不列归档")
    func duplicateGroupMembersRespectVisibility() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/v/p2.jpg")
        let groupId = try queryInsertDuplicateGroup(db, sessionId: "s1", memberCount: 2)
        try queryInsertDuplicateMember(db, groupId: groupId, photoId: "p1", sessionId: "s1", isKept: true)
        try queryInsertDuplicateMember(db, groupId: groupId, photoId: "p2", sessionId: "s1", isKept: false)
        try archived(db, ["p2"])
        let query = DuplicateGroupQuery(connection: db)

        #expect(try query.getVisibleMembers(groupId: groupId).map(\.photoId) == ["p1"])
        #expect(try query.getVisibleMemberStates(groupId: groupId).count == 1)
        #expect(try query.getMembers(groupIds: [groupId])[groupId]?.map(\.member.photoId) == ["p1"],
                "组详情的嵌套查询不得把归档件重新列出来")
        // 全表成员读取保留归档行（resolveGroup 的回收/审计路径需要看到它们）。
        #expect(try query.getMembers(groupId: groupId).count == 2)
    }
}
