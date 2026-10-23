// desktop/native/gather-core/Tests/GatherCoreTests/Queries/CullingAssetPageQueryTests.swift
// CullingAssetPageQuery 的 SQL 边界（真实 SQLite）。
// 服务层 CullingPaginationTests 已覆盖端到端装配；这里只钉 Query 的 SQL 契约：
// 整组装配/严格游标、空数组与 false 选项不下推、COALESCE 兜底、冲突交付作用域、
// similarity 成员+首选行、800 参数分块边界。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherPersistence

@Suite("CullingAssetPageQuery SQL 边界")
struct CullingAssetPageQueryBoundaryTests {
    @Test("filtered 页取整组变体，游标严格大于首选行 rowid")
    func filteredPageKeepsWholeAssetAndCursor() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertAsset(db, id: "a1")
        try queryInsertAsset(db, id: "a2")
        try queryInsertAsset(db, id: "a3")
        try queryInsertPhoto(db, id: "a1-jpg", sessionId: "s", filepath: "/s/a1.jpg", assetId: "a1")
        try queryInsertPhoto(db, id: "a1-raw", sessionId: "s", filepath: "/s/a1.NEF", assetId: "a1")
        try queryInsertPhoto(db, id: "a2", sessionId: "s", filepath: "/s/a2.jpg", assetId: "a2")
        try queryInsertPhoto(db, id: "a3", sessionId: "s", filepath: "/s/a3.jpg", assetId: "a3")
        let query = CullingAssetPageQuery(connection: db)
        let emptyFilter = CullingPageFilter()

        let first = try query.pageFiltered(sessionId: "s", filter: emptyFilter, afterRowId: nil, limit: 2)
        #expect(first.rows.map(\.id) == ["a1-jpg", "a1-raw", "a2"])
        #expect(first.cursor == 3)
        #expect(try query.countFiltered(sessionId: "s", filter: emptyFilter) == 3)

        let second = try query.pageFiltered(
            sessionId: "s", filter: emptyFilter, afterRowId: first.cursor, limit: 2
        )
        #expect(second.rows.map(\.id) == ["a3"])
        #expect(second.cursor == 4)

        let third = try query.pageFiltered(
            sessionId: "s", filter: emptyFilter, afterRowId: second.cursor, limit: 2
        )
        #expect(third.rows.isEmpty)
        #expect(third.cursor == nil)

        let zero = try query.pageFiltered(sessionId: "s", filter: emptyFilter, afterRowId: nil, limit: 0)
        #expect(zero.rows.isEmpty)
        #expect(zero.cursor == nil)
    }

    @Test("空数组/false 选项不下推；缺失决策按 pending，rating/label 用 COALESCE 兜底")
    func filterNullAndEmptySemantics() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        for id in ["a", "b", "c", "d"] {
            try queryInsertPhoto(db, id: id, sessionId: "s", filepath: "/s/\(id).jpg")
        }
        try queryInsertDecision(db, sessionId: "s", photoId: "a", decision: "keep")
        try queryInsertDecision(db, sessionId: "s", photoId: "b", decision: "reject")
        try queryInsertDecision(db, sessionId: "s", photoId: "d", decision: "keep")
        try queryInsertCache(db, photoId: "a", sessionId: "s", rating: 5, label: "Red")
        try queryInsertCache(db, photoId: "b", sessionId: "s", rating: 0, label: "")
        try queryInsertCache(db, photoId: "d", sessionId: "s", label: "None")

        let query = CullingAssetPageQuery(connection: db)
        func ids(_ filter: CullingPageFilter) throws -> [String] {
            try query.pageFiltered(sessionId: "s", filter: filter, afterRowId: nil, limit: 50).rows.map(\.id)
        }

        let ignored = CullingPageFilter(
            decisions: [], ratings: [], colorLabels: [],
            unreviewedOnly: false, metadataConflictOnly: false
        )
        #expect(try ids(ignored) == ["a", "b", "c", "d"])
        #expect(try query.countFiltered(sessionId: "s", filter: ignored) == 4)

        #expect(try ids(CullingPageFilter(decisions: ["pending"])) == ["c"])
        #expect(try ids(CullingPageFilter(unreviewedOnly: true)) == ["c"])
        #expect(try ids(CullingPageFilter(decisions: ["keep", "pending"], unreviewedOnly: true)) == ["c"])

        #expect(try ids(CullingPageFilter(ratings: [0.0])) == ["b", "c", "d"])
        #expect(try ids(CullingPageFilter(colorLabels: ["None"])) == ["b", "c", "d"])
    }

    @Test("metadataConflictOnly 只认同会话的 conflict 交付行，synced/他会话都不行")
    func metadataConflictScope() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertSession(db, id: "other")
        try queryInsertPhoto(db, id: "p-conflict", sessionId: "s", filepath: "/s/conflict.jpg")
        try queryInsertPhoto(db, id: "p-other", sessionId: "s", filepath: "/s/other.jpg")
        try queryInsertPhoto(db, id: "p-synced", sessionId: "s", filepath: "/s/synced.jpg")
        try queryInsertDelivery(db, photoPath: "/s/conflict.jpg", status: "conflict", sessionIds: ["s"])
        try queryInsertDelivery(db, photoPath: "/s/other.jpg", status: "conflict", sessionIds: ["other"])
        try queryInsertDelivery(db, photoPath: "/s/synced.jpg", status: "synced", sessionIds: ["s"])

        let query = CullingAssetPageQuery(connection: db)
        let filter = CullingPageFilter(metadataConflictOnly: true)
        let page = try query.pageFiltered(sessionId: "s", filter: filter, afterRowId: nil, limit: 10)
        #expect(page.rows.map(\.id) == ["p-conflict"])
        #expect(try query.countFiltered(sessionId: "s", filter: filter) == 1)
    }

    @Test("similarity 组页限定成员与首选行，latest 选最新非预计算结果")
    func similarityPagesUseMembershipAndPreferredRow() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertAsset(db, id: "a1")
        try queryInsertPhoto(db, id: "a1-jpg", sessionId: "s", filepath: "/s/a1.jpg", assetId: "a1")
        try queryInsertPhoto(db, id: "a1-raw", sessionId: "s", filepath: "/s/a1.NEF", assetId: "a1")
        try queryInsertPhoto(db, id: "b", sessionId: "s", filepath: "/s/b.jpg")
        try queryInsertPhoto(db, id: "c", sessionId: "s", filepath: "/s/c.jpg")

        let older = try queryInsertSimilarityResult(db, sessionId: "s", members: [
            (photoId: "a1-raw", groupIndex: 0),
            (photoId: "a1-jpg", groupIndex: 1),
            (photoId: "b", groupIndex: 0),
        ])
        _ = try queryInsertSimilarityResult(db, sessionId: "s", members: [
            (photoId: "b", groupIndex: 0),
            (photoId: "c", groupIndex: 0),
        ])

        let query = CullingAssetPageQuery(connection: db)
        let group0 = CullingSimilarityScope.group(resultId: older, groupIndex: 0)

        let first = try query.pageSimilarity(sessionId: "s", similarity: group0, afterRowId: nil, limit: 1)
        #expect(first.rows.map(\.id) == ["a1-jpg", "a1-raw"], "组内变体整组返回")
        #expect(first.cursor == 2)

        let second = try query.pageSimilarity(
            sessionId: "s", similarity: group0, afterRowId: first.cursor, limit: 1
        )
        #expect(second.rows.map(\.id) == ["b"])
        #expect(second.cursor == 3)
        #expect(try query.countSimilarity(sessionId: "s", similarity: group0) == 2)

        let group1 = CullingSimilarityScope.group(resultId: older, groupIndex: 1)
        let group1Page = try query.pageSimilarity(
            sessionId: "s", similarity: group1, afterRowId: nil, limit: 10
        )
        // group1 只含 a1-jpg，而 a1 的首选变体是 a1-raw：非首选变体被排除 → 空组。
        #expect(group1Page.rows.isEmpty)
        #expect(try query.countSimilarity(sessionId: "s", similarity: group1) == 0)

        let latestPage = try query.pageSimilarity(
            sessionId: "s", similarity: .latest, afterRowId: nil, limit: 10
        )
        #expect(latestPage.rows.map(\.id) == ["b", "c"])
        #expect(try query.countSimilarity(sessionId: "s", similarity: .latest) == 2)
    }

    @Test("资产行装配跨 800 参数分块边界：801 个资产一次取回")
    func assetMaterializationChunkBoundary() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        for i in 1...801 {
            try queryInsertAsset(db, id: "ca\(i)")
            try queryInsertPhoto(db, id: "cp\(i)", sessionId: "s",
                                 filepath: "/chunk/\(i).jpg", assetId: "ca\(i)")
        }
        let query = CullingAssetPageQuery(connection: db)
        let filter = CullingPageFilter()
        let page = try query.pageFiltered(sessionId: "s", filter: filter, afterRowId: nil, limit: 801)
        #expect(page.rows.count == 801)
        #expect(page.rows.first?.id == "cp1")
        #expect(page.rows.last?.id == "cp801")
        #expect(page.cursor == 801)
        #expect(Set(page.rows.map(\.id)).count == 801)
        #expect(try query.countFiltered(sessionId: "s", filter: filter) == 801)
    }
}
