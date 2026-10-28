// desktop/native/gather-core/Tests/GatherCoreTests/Queries/PhotoVisibilityTests.swift
// P0 / A1：archived_at 的可见性门禁——淘汰移出后，所有面向用户的读面都必须当它不存在。
//
// 覆盖：挑片网格（pageSorted）、挑片计数（countFiltered）、摘要（summaryCounts）、
// 跨页选择集（representativeIds）、图库检索（filterPhotos/filterGlobally/countGlobally）、
// facet 计数。用真实 SQL 与真实 SchemaCurrent.ddl，不 mock 查询。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("照片可见性（archived_at）")
struct PhotoVisibilityTests {
    private func makeDB() throws -> DBConnection {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p-visible", sessionId: "s1", filepath: "/shoot/visible.CR3")
        try insertPhoto(db, id: "p-archived", sessionId: "s1", filepath: "/shoot/_rejects/moved.CR3")
        try insertPhoto(db, id: "p-archived-jpg", sessionId: "s1", filepath: "/shoot/_rejects/moved.JPG")
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id IN ('p-archived', 'p-archived-jpg')")
            .run([.text("2026-10-28T00:00:00.000Z")])
        return db
    }

    @Test("挑片网格/计数/摘要/选择集都排除已归档")
    func cullingSurfacesExcludeArchived() throws {
        let db = try makeDB()
        defer { db.close() }
        let query = CullingAssetPageQuery(connection: db)

        let page = try query.pageSorted(
            sessionId: "s1", scope: .all, filter: CullingPageFilter(), similarity: nil,
            sort: .importOrder, cursor: nil, limit: 50)
        #expect(page.rows.map(\.id) == ["p-visible"])
        #expect(page.cursor == nil, "只有一条可见记录，不应再翻页")
        #expect(try query.countFiltered(sessionId: "s1", filter: CullingPageFilter()) == 1)

        let ids = try query.representativeIds(
            sessionId: "s1", scope: .all, filter: CullingPageFilter(),
            similarity: nil, limit: 50)
        #expect(ids.ids == ["p-visible"])
        #expect(!ids.truncated)

        let summary = try CullingReadQuery(connection: db).summaryCounts(
            sessionId: "s1", colorLabels: ["Red"])
        #expect(summary.totalPhotos == 1, "摘要总数必须与网格同口径")
    }

    @Test("部分移出：RAW 归档、JPEG 仍可见时，资产不得从筛选/选择集消失")
    func partiallyArchivedAssetStaysVisible() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s1")
        try insertPhoto(db, id: "raw", sessionId: "s1", filepath: "/shoot/A.CR3")
        try insertPhoto(db, id: "jpg", sessionId: "s1", filepath: "/shoot/A.JPG")
        _ = try db.prepare("""
            INSERT INTO assets (id, status, created_at, updated_at)
            VALUES ('a1', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([])
        _ = try db.prepare("UPDATE photos SET asset_id = 'a1' WHERE id IN ('raw', 'jpg')")
            .run([])
        // 首选行规则是"RAW 优先"：归档 RAW 后，代表行子查询若不过滤归档，
        // 会把 JPEG 这一行也判成非代表行，整个资产从 filtered 网格里消失。
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id = 'raw'")
            .run([.text("2026-10-28T00:00:00.000Z")])

        let query = CullingAssetPageQuery(connection: db)
        let page = try query.pageSorted(
            sessionId: "s1", scope: .filtered, filter: CullingPageFilter(), similarity: nil,
            sort: .importOrder, cursor: nil, limit: 50)
        #expect(page.rows.map(\.id) == ["jpg"], "可见的 JPEG 必须成为代表行")
        #expect(try query.countFiltered(sessionId: "s1", filter: CullingPageFilter()) == 1)

        let ids = try query.representativeIds(
            sessionId: "s1", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil, limit: 50)
        #expect(ids.ids == ["jpg"], "全选必须能选中仍可见的资产")
    }

    @Test("跨页：120 张可见 + 30 张已归档，两页都不出现归档项")
    func paginationNeverLeaksArchived() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s1")
        for index in 0..<120 {
            try insertPhoto(db, id: String(format: "v-%03d", index), sessionId: "s1",
                            filepath: "/shoot/v-\(index).CR3")
        }
        for index in 0..<30 {
            try insertPhoto(db, id: String(format: "a-%03d", index), sessionId: "s1",
                            filepath: "/shoot/_rejects/a-\(index).CR3")
        }
        _ = try db.prepare("UPDATE photos SET archived_at = ? WHERE id LIKE 'a-%'")
            .run([.text("2026-10-28T00:00:00.000Z")])

        let query = CullingAssetPageQuery(connection: db)
        let first = try query.pageSorted(
            sessionId: "s1", scope: .all, filter: CullingPageFilter(), similarity: nil,
            sort: .importOrder, cursor: nil, limit: 100)
        #expect(first.rows.count == 100)
        #expect(first.rows.allSatisfy { !$0.id.hasPrefix("a-") })
        let cursor = try #require(first.cursor, "可见 120 张，首页满 100 才给 cursor")

        let second = try query.pageSorted(
            sessionId: "s1", scope: .all, filter: CullingPageFilter(), similarity: nil,
            sort: .importOrder, cursor: cursor, limit: 100)
        #expect(second.rows.count == 20)
        #expect(second.rows.allSatisfy { $0.id.hasPrefix("v-") })
        #expect(second.cursor == nil)

        #expect(try query.countFiltered(sessionId: "s1", filter: CullingPageFilter()) == 120)
        let ids = try query.representativeIds(
            sessionId: "s1", scope: .all, filter: CullingPageFilter(),
            similarity: nil, limit: 100)
        #expect(ids.ids.count == 100)
        #expect(ids.truncated, "120 > 100：全选必须显式告知被截断")
    }

    @Test("图库检索与 facet 排除已归档")
    func libraryAndFacetsExcludeArchived() throws {
        let db = try makeDB()
        defer { db.close() }
        let cache = MetadataCacheRepo(connection: db)
        try cache.upsert(
            photoId: "p-visible", sessionId: "s1",
            data: MetadataCacheInput(cameraModel: "X-T5", rating: 5))
        // 归档照片也写同样的相机/星级/色标：若谓词漏了，facet 计数会变成 3/2。
        for id in ["p-archived", "p-archived-jpg"] {
            try cache.upsert(
                photoId: id, sessionId: "s1",
                data: MetadataCacheInput(cameraModel: "X-T5", rating: 5, label: "Red"))
        }

        let criteria = FilterGroup(logic: .and, conditions: [])
        let filter = PhotoFilterQuery(connection: db)
        let photos = try filter.filterPhotos(sessionId: "s1", criteria: criteria)
        #expect(photos.map(\.id) == ["p-visible"])
        #expect(try filter.countGlobally(criteria: criteria, sessionId: "s1") == 1)
        #expect(try filter.filterGlobally(criteria: criteria).map(\.photoId) == ["p-visible"])

        let facets = FacetQuery(connection: db)
        let cameras = try facets.buckets(
            sessionId: "s1", criteria: criteria, dimension: .camera)
        #expect(cameras.map(\.value) == ["X-T5"])
        #expect(cameras.first?.count == 1)

        let labels = try facets.buckets(
            sessionId: "s1", criteria: criteria, dimension: .label)
        #expect(labels.isEmpty, "归档照片不得贡献 facet 桶")
    }
}
