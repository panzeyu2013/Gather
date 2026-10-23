// desktop/native/gather-core/Tests/GatherCoreTests/Queries/DuplicateGroupQueryTests.swift
// DuplicateGroupQuery 的 SQL 边界（真实 SQLite）：
// getGroups 的全列列序/排序/空输入、getMembers 的自然行序与 JOIN 投影、
// getMemberStates 的列序。DuplicateServiceTests 只覆盖服务语义，这里钉 Query 行形状。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherPersistence

@Suite("DuplicateGroupQuery SQL 边界")
struct DuplicateGroupQueryBoundaryTests {
    @Test("getGroups(sessionId:) 按 group_type,id 排序并完整映射全列")
    func groupsBySessionOrderAndMapping() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1")
        try queryInsertSession(db, id: "s2")
        let visual = try queryInsertDuplicateGroup(
            db, sessionId: "s1", groupType: "visual", hashHex: "hash", memberCount: 2
        )
        let exact1 = try queryInsertDuplicateGroup(
            db, sessionId: "s1", groupType: "exact", checksum: "sum",
            memberCount: 2, resolution: "keep_one"
        )
        let exact2 = try queryInsertDuplicateGroup(
            db, sessionId: "s1", groupType: "exact", checksum: "sum2", memberCount: 1
        )
        _ = try queryInsertDuplicateGroup(db, sessionId: "s2", groupType: "exact", checksum: "other")
        let query = DuplicateGroupQuery(connection: db)

        let rows = try query.getGroups(sessionId: "s1")
        #expect(rows.map(\.id) == [exact1, exact2, visual], "exact 在 visual 前，同类型按 id")
        #expect(rows.map(\.groupType) == ["exact", "exact", "visual"])

        let first = rows[0]
        #expect(first.sessionId == "s1")
        #expect(first.checksum == "sum")
        #expect(first.hashHex == nil)
        #expect(first.memberCount == 2)
        #expect(first.resolution == "keep_one")
        #expect(first.createdAt == "2026-01-01T00:00:00.000Z")

        let visualRow = rows[2]
        #expect(visualRow.checksum == nil)
        #expect(visualRow.hashHex == "hash")
        #expect(visualRow.resolution == nil)

        #expect(try query.getGroups(sessionId: "missing").isEmpty)
    }

    @Test("getGroups(ids:) 空输入短路、去重并按 id 升序")
    func groupsByIDsSortAndEmptyGuard() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        let g1 = try queryInsertDuplicateGroup(db, sessionId: "s", groupType: "exact", checksum: "1")
        let g2 = try queryInsertDuplicateGroup(db, sessionId: "s", groupType: "visual", hashHex: "2")
        let g3 = try queryInsertDuplicateGroup(db, sessionId: "s", groupType: "exact", checksum: "3")
        let query = DuplicateGroupQuery(connection: db)

        #expect(try query.getGroups(ids: []).isEmpty)
        #expect(try query.getGroups(ids: [g3, g1, g1]).map(\.id) == [g1, g3])
        #expect(try query.getGroups(ids: [g2]).map(\.id) == [g2])
        #expect(try query.getGroups(ids: [Int.max]).isEmpty)
    }

    @Test("getMembers(groupId:) 保持自然行序，NULL 列映射为 nil")
    func membersPreserveNaturalOrderAndNulls() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        for id in ["p1", "p2", "p3", "p4"] {
            try queryInsertPhoto(db, id: id, sessionId: "s", filepath: "/s/\(id).jpg")
        }
        let g1 = try queryInsertDuplicateGroup(
            db, sessionId: "s", groupType: "exact", checksum: "sum", memberCount: 3
        )
        let g2 = try queryInsertDuplicateGroup(
            db, sessionId: "s", groupType: "visual", hashHex: "hash", memberCount: 1
        )
        let m1 = try queryInsertDuplicateMember(
            db, groupId: g1, photoId: "p2", sessionId: "s",
            isKept: false, fileSize: 10,
            fileMtime: "2026-01-01T00:00:00.000Z", resolution: "keep_one"
        )
        let m2 = try queryInsertDuplicateMember(db, groupId: g1, photoId: "p1", sessionId: "s")
        let m3 = try queryInsertDuplicateMember(
            db, groupId: g1, photoId: "p3", sessionId: "s",
            isKept: true, fileSize: 0, fileMtime: "", resolution: "keep_all"
        )
        _ = try queryInsertDuplicateMember(db, groupId: g2, photoId: "p4", sessionId: "s")
        let query = DuplicateGroupQuery(connection: db)

        let rows = try query.getMembers(groupId: g1)
        #expect(rows.map(\.id) == [m1, m2, m3], "无 ORDER BY，必须保持插入行序（keep_one 平局规则依赖）")
        #expect(rows.map(\.photoId) == ["p2", "p1", "p3"])
        #expect(rows[0].isKept == false)
        #expect(rows[0].fileSize == 10)
        #expect(rows[0].fileMtime == "2026-01-01T00:00:00.000Z")
        #expect(rows[0].resolution == "keep_one")
        #expect(rows[1].isKept == true)
        #expect(rows[1].fileSize == nil)
        #expect(rows[1].fileMtime == nil)
        #expect(rows[1].resolution == nil)

        #expect(try query.getMembers(groupId: g2).map(\.photoId) == ["p4"])
        #expect(try query.getMembers(groupId: 999).isEmpty)
    }

    @Test("getMembers(groupIds:) JOIN photos 提供 filepath/filename，空组不产生键")
    func memberDetailsJoinAndGrouping() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertPhoto(db, id: "p1", sessionId: "s", filepath: "/lib/a.jpg")
        try queryInsertPhoto(db, id: "p2", sessionId: "s", filepath: "/lib/b.jpg")
        try queryInsertPhoto(db, id: "p3", sessionId: "s", filepath: "/lib/c.jpg")
        let g1 = try queryInsertDuplicateGroup(
            db, sessionId: "s", groupType: "exact", checksum: "sum", memberCount: 2
        )
        let g2 = try queryInsertDuplicateGroup(
            db, sessionId: "s", groupType: "visual", hashHex: "hash", memberCount: 1
        )
        let g3 = try queryInsertDuplicateGroup(
            db, sessionId: "s", groupType: "exact", checksum: "empty"
        )
        _ = try queryInsertDuplicateMember(db, groupId: g1, photoId: "p2", sessionId: "s")
        _ = try queryInsertDuplicateMember(db, groupId: g1, photoId: "p1", sessionId: "s")
        _ = try queryInsertDuplicateMember(db, groupId: g2, photoId: "p3", sessionId: "s")
        let query = DuplicateGroupQuery(connection: db)

        let details = try query.getMembers(groupIds: [g1, g2, g3])
        #expect(details.keys.sorted() == [g1, g2], "空组不产生空数组键")
        #expect(details[g1]?.map(\.member.photoId) == ["p2", "p1"], "按 dgm.id 排序")
        #expect(details[g1]?.map(\.filename) == ["b.jpg", "a.jpg"])
        #expect(details[g1]?.map(\.filepath) == ["/lib/b.jpg", "/lib/a.jpg"])
        #expect(details[g1]?.first?.member.groupId == g1)
        #expect(details[g2]?.map(\.member.photoId) == ["p3"])

        #expect(try query.getMembers(groupIds: []).isEmpty)
        #expect(try query.getMembers(groupIds: [g3]).isEmpty)
    }

    @Test("getMemberStates 按 id 读取 is_kept/resolution")
    func memberStatesProjection() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertPhoto(db, id: "p1", sessionId: "s", filepath: "/s/p1.jpg")
        try queryInsertPhoto(db, id: "p2", sessionId: "s", filepath: "/s/p2.jpg")
        let g = try queryInsertDuplicateGroup(
            db, sessionId: "s", groupType: "exact", checksum: "sum", memberCount: 2
        )
        _ = try queryInsertDuplicateMember(db, groupId: g, photoId: "p1", sessionId: "s", isKept: true)
        _ = try queryInsertDuplicateMember(
            db, groupId: g, photoId: "p2", sessionId: "s", isKept: false, resolution: "keep_all"
        )
        let query = DuplicateGroupQuery(connection: db)

        let states = try query.getMemberStates(groupId: g)
        #expect(states.count == 2)
        #expect(states[0].isKept == true)
        #expect(states[0].resolution == nil)
        #expect(states[1].isKept == false)
        #expect(states[1].resolution == "keep_all")
        #expect(try query.getMemberStates(groupId: 999).isEmpty)
    }
}
