// desktop/native/gather-core/Tests/GatherCoreTests/Queries/CullingReadQueryTests.swift
// CullingReadQuery 的 SQL 边界（真实 SQLite）：
// existingPhotoIds 的会话过滤+800 分块、conflictPhotoPaths 的 DISTINCT+会话作用域。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherPersistence

@Suite("CullingReadQuery SQL 边界")
struct CullingReadQueryBoundaryTests {
    @Test("existingPhotoIds 按会话过滤、去重，并跨 800 分块找到最后一个 id")
    func existingPhotoIdsScopeAndChunk() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1")
        try queryInsertSession(db, id: "s2")
        try queryInsertPhoto(db, id: "p1", sessionId: "s1", filepath: "/s1/p1.jpg")
        try queryInsertPhoto(db, id: "p2", sessionId: "s1", filepath: "/s1/p2.jpg")
        try queryInsertPhoto(db, id: "p3", sessionId: "s2", filepath: "/s2/p3.jpg")
        let query = CullingReadQuery(connection: db)

        #expect(try query.existingPhotoIds(sessionId: "s1", photoIds: ["p2", "p1", "ghost", "p2"])
            == Set(["p1", "p2"]))
        #expect(try query.existingPhotoIds(sessionId: "s2", photoIds: ["p1"]).isEmpty)
        #expect(try query.existingPhotoIds(sessionId: "s1", photoIds: []).isEmpty)

        // 前 800 个不存在的 id 走完第一块，p1 在第二块。
        var many = (0..<800).map { "ghost-\($0)" }
        many.append("p1")
        #expect(try query.existingPhotoIds(sessionId: "s1", photoIds: many) == Set(["p1"]))
    }

    @Test("conflictPhotoPaths 按会话+status=conflict 取 DISTINCT photo_path")
    func conflictPathsAreDistinctAndScoped() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1")
        try queryInsertSession(db, id: "s2")
        try queryInsertDelivery(db, photoPath: "/shoot/dup.jpg", status: "conflict", sessionIds: ["s1"])
        try queryInsertDelivery(db, photoPath: "/shoot/dup.jpg", status: "conflict", sessionIds: ["s1"])
        try queryInsertDelivery(db, photoPath: "/shoot/other.jpg", status: "conflict", sessionIds: ["s2"])
        try queryInsertDelivery(db, photoPath: "/shoot/synced.jpg", status: "synced", sessionIds: ["s1"])
        try queryInsertDelivery(db, photoPath: "/shoot/both.jpg", status: "conflict", sessionIds: ["s1", "s2"])
        let query = CullingReadQuery(connection: db)

        #expect(try query.conflictPhotoPaths(sessionId: "s1")
            == Set(["/shoot/dup.jpg", "/shoot/both.jpg"]))
        #expect(try query.conflictPhotoPaths(sessionId: "s2")
            == Set(["/shoot/other.jpg", "/shoot/both.jpg"]))
        #expect(try query.conflictPhotoPaths(sessionId: "s3").isEmpty)
    }
}
