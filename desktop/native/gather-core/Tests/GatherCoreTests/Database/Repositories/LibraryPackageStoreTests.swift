// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/LibraryPackageStoreTests.swift
// Wave5（Batch3 / task-20）：目录包**组织资产导出投影**的库侧契约。
//
// 覆盖：
// 1. personBindingRows：只返回本工作区、仍在工作区（archived_at IS NULL）的人物绑定，带身份名；
// 2. duplicateGroupRows / duplicateGroupMemberRows：显式列读出组键与成员裁决，已移出照片不进成员；
// 3. 无组织资产时返回空数组（不抛错）。
//
// 边界：只测导出投影（读）；包格式/导入编排在 Maintenance/LibraryPackageServiceTests。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

struct LibraryPackageStoreTests {
    @Test("personBindingRows：只取本工作区可见照片的绑定，并带身份名")
    func personBindingsExcludeArchivedAndOtherSessions() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertSession(db, "s2")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s2")
        try insertPhoto(db, id: "p3", sessionId: "s1")
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id = ?")
            .run([.text("2026-01-01T00:00:00.000Z"), .text("p3")])
        let persons = PersonRepo(connection: db)
        let bride = try persons.upsertByName(name: "新娘")
        let groom = try persons.upsertByName(name: "新郎")
        try persons.addPhotos(personId: bride, sessionId: "s1", photos: [
            PersonPhotoInput(photoId: "p1", faceBbox: [], confidence: 0.9),
            // 已移出工作区的照片绑定不进包。
            PersonPhotoInput(photoId: "p3", faceBbox: [], confidence: 0.5),
        ])
        try persons.addPhotos(personId: groom, sessionId: "s2", photos: [
            PersonPhotoInput(photoId: "p2", faceBbox: [], confidence: 0.7),
        ])

        let rows = try LibraryPackageStore(connection: db).personBindingRows(sessionId: "s1")
        #expect(rows.count == 1)
        #expect(rows[0].photoId == "p1")
        #expect(rows[0].personId == bride)
        #expect(rows[0].personName == "新娘")
        #expect(rows[0].confidence == 0.9)
    }

    @Test("duplicateGroup 投影：显式列读出组键/组裁决，成员按可见性过滤")
    func duplicateGroupsExposePortableColumns() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id = ?")
            .run([.text("2026-01-01T00:00:00.000Z"), .text("p2")])
        let duplicates = DuplicateRepo(connection: db)
        let groupIds = try duplicates.insertGroups([DuplicateGroupInsert(
            sessionId: "s1", groupType: "visual", checksum: nil, hashHex: "abc123",
            memberCount: 2, createdAt: "2026-01-01T00:00:00.000Z")])
        #expect(groupIds.count == 1)
        try duplicates.setGroupResolutions([
            DuplicateGroupResolutionWrite(groupId: groupIds[0], resolution: "keep_one"),
        ])
        try duplicates.insertMembers([
            DuplicateMemberInsert(
                groupId: groupIds[0], photoId: "p1", sessionId: "s1",
                isKept: true, fileSize: 1, fileMtime: nil, resolution: "keep_all"),
            DuplicateMemberInsert(
                groupId: groupIds[0], photoId: "p2", sessionId: "s1",
                isKept: false, fileSize: 2, fileMtime: nil, resolution: nil),
        ])

        let store = LibraryPackageStore(connection: db)
        let groups = try store.duplicateGroupRows(sessionId: "s1")
        #expect(groups.count == 1)
        #expect(groups[0].groupType == "visual")
        #expect(groups[0].hashHex == "abc123")
        #expect(groups[0].checksum == nil)
        #expect(groups[0].resolution == "keep_one")
        let members = try store.duplicateGroupMemberRows(sessionId: "s1")
        #expect(members.count == 1, "已移出工作区的成员不进包")
        #expect(members[0].photoId == "p1")
        #expect(members[0].isKept)
        #expect(members[0].resolution == "keep_all")
        #expect(members[0].groupId == groups[0].id)
    }

    @Test("无组织资产：投影返回空数组（不抛错）")
    func emptyLibraryReturnsEmptyProjections() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let store = LibraryPackageStore(connection: db)
        #expect(try store.personBindingRows(sessionId: "s1").isEmpty)
        #expect(try store.duplicateGroupRows(sessionId: "s1").isEmpty)
        #expect(try store.duplicateGroupMemberRows(sessionId: "s1").isEmpty)
    }
}
