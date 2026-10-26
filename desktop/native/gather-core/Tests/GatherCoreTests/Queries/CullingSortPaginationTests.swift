// desktop/native/gather-core/Tests/GatherCoreTests/Queries/CullingSortPaginationTests.swift
// P0 / G0：排序资产组 keyset 分页（真实 SQLite + Schema V3）。
//
// 覆盖：capture/rating/triage 三种排序、NULL 归一、并列 first_rowid、
// 20 页无重漏、triage verdict 过滤、非法游标/筛选校验、nextCursor 往返。
import Foundation
import Testing
import GatherTestSupport
import GatherProtocol
@testable import GatherPersistence

private struct SortTestDB {
    let database: Database
    var db: DBConnection { database.connection }
}

private func makeSortTestDB() throws -> SortTestDB {
    SortTestDB(database: try Database.openInMemory())
}

private func seedAsset(
    _ db: DBConnection,
    sessionId: String = "s",
    assetId: String,
    date: String?,
    rating: Int?
) throws {
    try queryInsertAsset(db, id: assetId)
    try queryInsertPhoto(
        db, id: assetId, sessionId: sessionId,
        filepath: "/s/\(assetId).jpg", assetId: assetId
    )
    _ = try db.prepare("""
        INSERT INTO photo_metadata_cache
          (photo_id, session_id, date_taken, rating, keywords, cached_at, updated_at)
        VALUES (?, ?, ?, ?, '[]', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([
            .text(assetId), .text(sessionId),
            date.map { DBValue.text($0) } ?? .null,
            rating.map { DBValue.int(Int64($0)) } ?? .null,
        ])
}

private func insertTriage(
    _ db: DBConnection,
    sessionId: String = "s",
    photoId: String,
    verdict: String,
    confidence: Double,
    score: Double = 0.5,
    fingerprint: String = "fp",
    policyVersion: String = "triage-v1"
) throws {
    _ = try db.prepare("""
        INSERT INTO triage_suggestions
          (photo_id, session_id, verdict, score, confidence, reasons_json,
           group_id, policy_version, input_fingerprint, computed_at)
        VALUES (?, ?, ?, ?, ?, '[]', NULL, ?, ?, '2026-01-01T00:00:00.000Z')
        """).run([
            .text(photoId), .text(sessionId), .text(verdict),
            .real(score), .real(confidence),
            .text(policyVersion), .text(fingerprint),
        ])
}

private func day(_ index: Int) -> String {
    String(format: "2026-01-%02dT00:00:00.000Z", index)
}

@Suite("G0 排序资产组 keyset 分页")
struct CullingSortPaginationTests {
    @Test("capture_desc：20 页无重漏，nextCursor 可续页")
    func captureDescPagination() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        for index in 1...25 {
            try seedAsset(fixture.db, assetId: String(format: "a%02d", index), date: day(index), rating: index % 6)
        }
        let query = CullingAssetPageQuery(connection: fixture.db)

        var cursor: CullingPageCursor?
        var collected: [String] = []
        var pages = 0
        repeat {
            let page = try query.pageSorted(
                sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
                similarity: nil,
                sort: .captureDesc, cursor: cursor, limit: 3
            )
            pages += 1
            guard !page.rows.isEmpty else { break }
            collected.append(contentsOf: page.rows.map(\.id))
            cursor = page.cursor
            if cursor == nil { break }
        } while pages < 20

        #expect(pages <= 20)
        #expect(collected.count == 25)
        #expect(Set(collected).count == 25)
        #expect(collected == (1...25).reversed().map { String(format: "a%02d", $0) })
    }

    @Test("capture：无拍摄时间按空串，ASC 最前、DESC 最后")
    func nullDatesNormalizeToEmptyString() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "undated", date: nil, rating: nil)
        try seedAsset(fixture.db, assetId: "early", date: day(1), rating: 1)
        try seedAsset(fixture.db, assetId: "late", date: day(2), rating: 2)
        let query = CullingAssetPageQuery(connection: fixture.db)

        let asc = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureAsc, cursor: nil, limit: 10
        )
        #expect(asc.rows.map(\.id) == ["undated", "early", "late"])

        let desc = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureDesc, cursor: nil, limit: 10
        )
        #expect(desc.rows.map(\.id) == ["late", "early", "undated"])
    }

    @Test("rating_desc：并列按 first_rowid；无评分按 0")
    func ratingDescTiesUseRowid() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "five-a", date: day(1), rating: 5)
        try seedAsset(fixture.db, assetId: "five-b", date: day(2), rating: 5)
        try seedAsset(fixture.db, assetId: "three", date: day(3), rating: 3)
        try seedAsset(fixture.db, assetId: "none", date: day(4), rating: nil)
        let query = CullingAssetPageQuery(connection: fixture.db)

        let page = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .ratingDesc, cursor: nil, limit: 10
        )
        #expect(page.rows.map(\.id) == ["five-a", "five-b", "three", "none"])
        // 不足一页即末页：不再返回 cursor。
        #expect(page.cursor == nil)
    }

    @Test("triage verdict 过滤 + triageConfidenceAsc：只返回 review，按置信度升序")
    func triageFilterAndConfidenceSort() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "lowest", date: day(1), rating: nil)
        try seedAsset(fixture.db, assetId: "middle", date: day(2), rating: nil)
        try seedAsset(fixture.db, assetId: "highest", date: day(3), rating: nil)
        try seedAsset(fixture.db, assetId: "keep", date: day(4), rating: nil)
        try seedAsset(fixture.db, assetId: "no-suggestion", date: day(5), rating: nil)

        try insertTriage(fixture.db, photoId: "middle", verdict: "review", confidence: 0.3)
        try insertTriage(fixture.db, photoId: "lowest", verdict: "review", confidence: 0.1)
        try insertTriage(fixture.db, photoId: "highest", verdict: "review", confidence: 0.6)
        try insertTriage(fixture.db, photoId: "keep", verdict: "keep", confidence: 0.9)

        let query = CullingAssetPageQuery(connection: fixture.db)
        let filter = CullingPageFilter(triageVerdicts: ["review"])
        let page = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: filter,
            similarity: nil,
            sort: .triageConfidenceAsc, cursor: nil, limit: 2
        )
        #expect(page.rows.map(\.id) == ["lowest", "middle"])
        #expect(page.cursor?.numberKey == 0.3)
        #expect(try query.countFiltered(sessionId: "s", filter: filter) == 3)

        let rest = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: filter,
            similarity: nil,
            sort: .triageConfidenceAsc, cursor: page.cursor, limit: 2
        )
        #expect(rest.rows.map(\.id) == ["highest"])
        #expect(rest.cursor == nil)
    }

    @Test("triage 过滤排除人工决策资产（建议行仍在也不命中）")
    func triageFilterExcludesManualDecision() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "auto", date: day(1), rating: nil)
        try seedAsset(fixture.db, assetId: "manual", date: day(2), rating: nil)
        try insertTriage(fixture.db, photoId: "auto", verdict: "review", confidence: 0.5)
        try insertTriage(fixture.db, photoId: "manual", verdict: "review", confidence: 0.5)
        _ = try fixture.db.prepare("""
            INSERT INTO culling_decisions
              (session_id, photo_id, group_id, decision, rating, color_label,
               decision_source, revision, created_at, updated_at)
            VALUES ('s', 'manual', 'ungrouped', 'keep', 0, 'None', 'manual', 1, 't', 't')
            """).run([])

        let query = CullingAssetPageQuery(connection: fixture.db)
        let filter = CullingPageFilter(triageVerdicts: ["review"])
        let page = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: filter, similarity: nil,
            sort: .triageConfidenceAsc, cursor: nil, limit: 10)
        #expect(page.rows.map(\.id) == ["auto"])
        #expect(try query.countFiltered(sessionId: "s", filter: filter) == 1)
    }

    @Test("triageRows 页模式只取本页照片，不读整会话")
    func triageRowsPageScoped() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        for id in ["a1", "a2", "a3"] {
            try seedAsset(fixture.db, assetId: id, date: day(1), rating: nil)
            try insertTriage(fixture.db, photoId: id, verdict: "review", confidence: 0.5)
        }
        let rows = try CullingReadQuery(connection: fixture.db).triageRows(
            sessionId: "s", photoIds: ["a1", "a3"])
        #expect(Set(rows.map(\.gid)) == ["a1", "a3"])
        #expect(try CullingReadQuery(connection: fixture.db).triageRows(
            sessionId: "s", photoIds: []).isEmpty)
    }

    @Test("all scope 携带有谓词 filter 必须拒绝，不能静默忽略")
    func allScopeRejectsFilters() throws {
        #expect(throws: GatherError.self) {
            _ = try CullingPageQuery(
                sessionId: "s", scope: .all,
                filters: CullingFilters(ratings: [5]))
        }
    }

    @Test("all scope 也支持排序（不依赖 filtered 谓词）")
    func allScopeSorts() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "one", date: day(1), rating: 1)
        try seedAsset(fixture.db, assetId: "two", date: day(2), rating: 2)
        let query = CullingAssetPageQuery(connection: fixture.db)
        let page = try query.pageSorted(
            sessionId: "s", scope: .all, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureDesc, cursor: nil, limit: 10
        )
        #expect(page.rows.map(\.id) == ["two", "one"])
    }

    @Test("游标校验：sort 必须一致；键类型必须与 sort 匹配")
    func cursorValidation() throws {
        func expectCode(_ code: GatherErrorCode, _ body: () throws -> Void) {
            do {
                try body()
                Issue.record("expected \(code.rawValue)")
            } catch let error as GatherError {
                #expect(error.code == code)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        // sort 不一致
        expectCode(.CULLING_CURSOR_INVALID) {
            _ = try CullingPageQuery(
                sessionId: "s", scope: .filtered, sort: .captureDesc,
                cursor: CullingPageCursor(sort: .ratingDesc, numberKey: 1, rowId: 1)
            )
        }
        // import 游标带排序键
        expectCode(.CULLING_CURSOR_INVALID) {
            _ = try CullingPageQuery(
                sessionId: "s", scope: .filtered,
                cursor: CullingPageCursor(sort: .importOrder, numberKey: 1, rowId: 1)
            )
        }
        // capture 游标缺 dateKey
        expectCode(.CULLING_CURSOR_INVALID) {
            _ = try CullingPageQuery(
                sessionId: "s", scope: .filtered, sort: .captureDesc,
                cursor: CullingPageCursor(sort: .captureDesc, rowId: 1)
            )
        }
        // number 游标缺 numberKey
        expectCode(.CULLING_CURSOR_INVALID) {
            _ = try CullingPageQuery(
                sessionId: "s", scope: .filtered, sort: .ratingDesc,
                cursor: CullingPageCursor(sort: .ratingDesc, rowId: 1)
            )
        }
        expectCode(.CULLING_FILTER_INVALID) {
            _ = try CullingPageQuery(
                sessionId: "s", scope: .all,
                filters: CullingFilters(triageVerdicts: [.review])
            )
        }

        // 相似度 scope 也支持排序（不再有 import-only 限制）。
        let similaritySorted = try CullingPageQuery(
            sessionId: "s", scope: .similarityGroup, sort: .captureDesc)
        #expect(similaritySorted.sort == .captureDesc)
        let importCursor = try CullingPageQuery(
            sessionId: "s", scope: .all,
            cursor: CullingPageCursor(sort: .importOrder, rowId: 3)
        )
        #expect(importCursor.cursor?.rowId == 3)
    }

    @Test("nextCursor 编解码与续页不重不漏")
    func nextCursorRoundTrip() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "a", date: day(1), rating: nil)
        try seedAsset(fixture.db, assetId: "b", date: day(2), rating: nil)
        try seedAsset(fixture.db, assetId: "c", date: day(3), rating: nil)
        let query = CullingAssetPageQuery(connection: fixture.db)

        let first = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureAsc, cursor: nil, limit: 2
        )
        let cursor = try #require(first.cursor)
        let encoded = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(CullingPageCursor.self, from: encoded)
        #expect(decoded == cursor)

        let second = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureAsc, cursor: decoded, limit: 2
        )
        #expect(second.rows.map(\.id) == ["c"])
    }

    @Test("all scope + triageConfidenceAsc：无建议排最后（2.0 哨兵）")
    func allScopeTriageNullsLast() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "lowest", date: day(1), rating: nil)
        try seedAsset(fixture.db, assetId: "middle", date: day(2), rating: nil)
        try seedAsset(fixture.db, assetId: "no-suggestion", date: day(3), rating: nil)
        try insertTriage(fixture.db, photoId: "lowest", verdict: "review", confidence: 0.1)
        try insertTriage(fixture.db, photoId: "middle", verdict: "review", confidence: 0.5)

        let query = CullingAssetPageQuery(connection: fixture.db)
        let page = try query.pageSorted(
            sessionId: "s", scope: .all, filter: CullingPageFilter(),
            similarity: nil,
            sort: .triageConfidenceAsc, cursor: nil, limit: 10
        )
        #expect(page.rows.map(\.id) == ["lowest", "middle", "no-suggestion"])
        #expect(page.cursor == nil)
    }

    @Test("triageRows：只按代表行返回，变体映射到同一 gid")
    func triageRowsMapRepresentative() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try queryInsertAsset(fixture.db, id: "asset")
        try queryInsertPhoto(
            fixture.db, id: "raw", sessionId: "s",
            filepath: "/s/raw.NEF", assetId: "asset"
        )
        try queryInsertPhoto(
            fixture.db, id: "jpg", sessionId: "s",
            filepath: "/s/jpg.JPG", assetId: "asset"
        )
        try insertTriage(fixture.db, photoId: "raw", verdict: "review", confidence: 0.4, score: 0.6)

        let rows = try CullingReadQuery(connection: fixture.db).triageRows(sessionId: "s")
        #expect(rows.count == 1)
        #expect(rows.first?.gid == "asset")
        #expect(rows.first?.photoId == "raw")
        #expect(rows.first?.confidence == 0.4)
        #expect(rows.first?.reasonsJSON == "[]")
    }

    @Test("capture_desc/asc：EXIF 冒号日期与 ISO 混排时按真实时间序")
    func captureSortNormalizesExifDates() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "exif-old", date: "2024:05:01 10:20:30", rating: nil)
        try seedAsset(fixture.db, assetId: "iso-new", date: "2024-05-02T10:20:30.000Z", rating: nil)
        try seedAsset(fixture.db, assetId: "iso-old", date: "2024-05-01T10:20:30.000Z", rating: nil)
        try seedAsset(fixture.db, assetId: "exif-new", date: "2024:05:02 10:20:30", rating: nil)
        try seedAsset(fixture.db, assetId: "none", date: nil, rating: nil)
        let query = CullingAssetPageQuery(connection: fixture.db)

        let desc = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureDesc, cursor: nil, limit: 10)
        #expect(desc.rows.map(\.id) == ["iso-new", "exif-new", "exif-old", "iso-old", "none"])

        let asc = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
            similarity: nil,
            sort: .captureAsc, cursor: nil, limit: 10)
        #expect(asc.rows.map(\.id) == ["none", "exif-old", "iso-old", "iso-new", "exif-new"])
    }

    @Test("rating_desc：跨页游标覆盖 0-5 星，不重不漏")
    func ratingSortPaginatesAllRatings() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        var seeded: [String] = []
        for index in 0..<24 {
            let id = String(format: "r%02d", index)
            seeded.append(id)
            try seedAsset(fixture.db, assetId: id, date: day(index + 1), rating: index % 6)
        }
        let query = CullingAssetPageQuery(connection: fixture.db)
        var cursor: CullingPageCursor?
        var ids: [String] = []
        repeat {
            let page = try query.pageSorted(
                sessionId: "s", scope: .filtered, filter: CullingPageFilter(),
                similarity: nil,
                sort: .ratingDesc, cursor: cursor, limit: 5)
            ids.append(contentsOf: page.rows.map(\.id))
            cursor = page.cursor
            if page.rows.isEmpty { break }
        } while cursor != nil

        #expect(ids.count == seeded.count, "跨页累计必须覆盖全部资产：\(ids.count)")
        #expect(Set(ids).count == seeded.count, "跨页不得重复：\(ids.description)")
        let ratingOf = Dictionary(uniqueKeysWithValues: seeded.enumerated().map {
            ($0.element, Int64($0.offset % 6))
        })
        let ratings = ids.compactMap { ratingOf[$0] }
        #expect(ratings == ratings.sorted(by: >), "必须按评分降序：\(ratings.description)")
    }

    @Test("triage 门控：指纹/策略不匹配的行不参与过滤与排序")
    func triageGateFiltersStaleRows() throws {
        let fixture = try makeSortTestDB()
        defer { fixture.database.close() }
        try queryInsertSession(fixture.db, id: "s")
        try seedAsset(fixture.db, assetId: "current", date: day(1), rating: nil)
        try seedAsset(fixture.db, assetId: "stale", date: day(2), rating: nil)
        try insertTriage(fixture.db, photoId: "current", verdict: "review",
                         confidence: 0.2, fingerprint: "fp")
        try insertTriage(fixture.db, photoId: "stale", verdict: "review",
                         confidence: 0.9, fingerprint: "fp-old")

        let query = CullingAssetPageQuery(connection: fixture.db)
        let gated = CullingPageFilter(
            triageVerdicts: ["review"],
            triageFingerprint: "fp",
            triagePolicyVersion: "triage-v1")
        let page = try query.pageSorted(
            sessionId: "s", scope: .filtered, filter: gated,
            similarity: nil,
            sort: .triageConfidenceAsc, cursor: nil, limit: 10)
        #expect(page.rows.map(\.id) == ["current"])
        #expect(try query.countFiltered(sessionId: "s", filter: gated) == 1)

        // 未接门控的旧调用方保持历史行为（两条都在）。
        let legacy = CullingPageFilter(triageVerdicts: ["review"])
        #expect(try query.countFiltered(sessionId: "s", filter: legacy) == 2)
    }
}
