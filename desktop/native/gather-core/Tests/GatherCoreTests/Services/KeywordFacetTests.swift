// desktop/native/gather-core/Tests/GatherCoreTests/Services/KeywordFacetTests.swift
// P1 下一波 §3.6.4/§3.7.1：keyword facet 与 criteria 分页。
//
// 三条红线（每一条都有对应用例）：
// 1. 计数口径与网格一致：按逻辑资产 COALESCE(NULLIF(asset_id,''), id) 去重；
// 2. 同维剔除：criteria 里的 keyword_path 规则不能给 keyword facet 自证；
// 3. 下钻 = 节点自身 + 子孙，桶名取"前缀之后的下一段"。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("关键词 facet 与 criteria 分页")
struct KeywordFacetTests {

    private struct Fixture {
        let db: DBConnection
        let sessionId: String
    }

    /// p1/p2 = 同一逻辑资产（asset a-1，RAW+JPEG 变体）；p3/p4 各自独立。
    private func makeDB() throws -> Fixture {
        let db = try makeTestDB()
        let sessionId = "s-1"
        _ = try db.prepare("""
            INSERT INTO sessions (id, name, status, created_at, updated_at)
            VALUES (?, '', 'photos_loaded', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([.text(sessionId)])
        // photos.asset_id 是指向 assets(id) 的外键（DDL 里 PRAGMA foreign_keys=ON），
        // 逻辑资产行必须先建，否则插入直接 FK 失败——这也是"按资产去重"测试的前提。
        for assetId in ["a-1", "a-2"] {
            _ = try db.prepare("""
                INSERT INTO assets (id, status, created_at, updated_at)
                VALUES (?, 'active', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([.text(assetId)])
        }
        let photos: [(id: String, asset: String?, camera: String)] = [
            ("p1", "a-1", "X-T5"),
            ("p2", "a-1", "X-T5"),
            ("p3", "a-2", "X-T5"),
            ("p4", nil, "X100"),
        ]
        for photo in photos {
            _ = try db.prepare("""
                INSERT INTO photos (id, session_id, filepath, filename, status, asset_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'ready', ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([
                    .text(photo.id), .text(sessionId), .text("/tmp/\(photo.id).CR3"),
                    .text("\(photo.id).CR3"), optDB(photo.asset),
                ])
            try MetadataCacheRepo(connection: db).upsert(
                photoId: photo.id, sessionId: sessionId,
                data: MetadataCacheInput(
                    dateTaken: "2026-10-25T10:00:00Z",
                    cameraModel: photo.camera,
                    iso: 200))
        }
        // p1/p2（同一资产）都带 Travel|Paris；p3 只带 Travel；p4 带 People|Alice + flat。
        try insertKeywords(db, photoId: "p1", paths: ["Travel|Paris"])
        try insertKeywords(db, photoId: "p2", paths: ["Travel|Paris"])
        try insertKeywords(db, photoId: "p3", paths: ["Travel"])
        try insertKeywords(db, photoId: "p4", paths: ["People|Alice", "flat"])
        return Fixture(db: db, sessionId: sessionId)
    }

    private func insertKeywords(_ db: DBConnection, photoId: String, paths: [String]) throws {
        let now = nowISOString()
        for path in paths {
            _ = try db.prepare("""
                INSERT INTO photo_keywords (photo_id, keyword_path, source, updated_at)
                VALUES (?, ?, 'xmp', ?)
                """).run([.text(photoId), .text(path), .text(now)])
        }
    }

    private var emptyCriteria: FilterGroup { FilterGroup(logic: .and, conditions: []) }

    @Test("顶级桶：首段聚合，按逻辑资产去重（RAW/JPEG 同一资产只计一次）")
    func countsTopLevelByLogicalAsset() throws {
        let fixture = try makeDB()
        let buckets = try FacetQuery(connection: fixture.db).buckets(
            sessionId: fixture.sessionId, criteria: emptyCriteria, dimension: .keyword)
        let counts = Dictionary(uniqueKeysWithValues: buckets.map { ($0.value, $0.count) })
        // Travel：p1+p2 是同一资产（1）+ p3（1）= 2；People：p4 = 1。
        #expect(counts["Travel"] == 2, "同一 asset 的两行只能计一次（与网格口径一致）")
        #expect(counts["People"] == 1)
        #expect(counts["flat"] == 1)
        #expect(buckets.first?.value == "Travel", "按计数降序")
    }

    @Test("下钻：桶名取前缀之后的下一段；只带该节点自身的照片不产生空桶")
    func drillsDownByPrefix() throws {
        let fixture = try makeDB()
        let query = FacetQuery(connection: fixture.db)
        let buckets = try query.buckets(
            sessionId: fixture.sessionId, criteria: emptyCriteria, dimension: .keyword,
            keywordPrefix: "Travel")
        let counts = Dictionary(uniqueKeysWithValues: buckets.map { ($0.value, $0.count) })
        // p1/p2 是同一逻辑资产（a-1）→ 只计 1；p3 只带 "Travel" 自身，没有下一段。
        #expect(counts["Paris"] == 1)
        #expect(buckets.count == 1, "p3 只带 \"Travel\" 自身，没有下一段 → 不进桶")
    }

    @Test("同维剔除：keyword_path 规则不影响 keyword facet 自身计数")
    func removesOwnDimension() throws {
        let fixture = try makeDB()
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath("Travel")),
        ])
        let query = FacetQuery(connection: fixture.db)
        let buckets = try query.buckets(
            sessionId: fixture.sessionId, criteria: criteria, dimension: .keyword)
        let counts = Dictionary(uniqueKeysWithValues: buckets.map { ($0.value, $0.count) })
        #expect(counts["Travel"] == 2, "不能因为已经按 Travel 筛过就只剩 Travel")
        #expect(counts["People"] == 1, "其它维的桶仍然完整")
    }

    @Test("跨维约束：相机条件仍然作用于 keyword facet")
    func appliesOtherDimensions() throws {
        let fixture = try makeDB()
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "camera_model", operator: .eq, value: .string("X100"))),
        ])
        let buckets = try FacetQuery(connection: fixture.db).buckets(
            sessionId: fixture.sessionId, criteria: criteria, dimension: .keyword)
        let counts = Dictionary(uniqueKeysWithValues: buckets.map { ($0.value, $0.count) })
        #expect(counts["People"] == 1)
        #expect(counts["Travel"] == nil, "X-T5 的照片被相机条件排除")
    }

    @Test("keyword_path 规则：starts_with 命中节点与子孙，eq 只命中节点")
    func filtersByKeywordPath() throws {
        let fixture = try makeDB()
        let filter = PhotoFilterQuery(connection: fixture.db)

        let drilldown = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath("Travel", drilldown: true)),
        ])
        let descendants = try filter.filterPhotos(
            sessionId: fixture.sessionId, criteria: drilldown)
        #expect(Set(descendants.map(\.id)) == ["p1", "p2", "p3"],
                "\"Travel\" 命中 Travel|Paris 的 p1/p2 与 Travel 自身 p3")

        let exact = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath("Travel", drilldown: false)),
        ])
        let onlyNode = try filter.filterPhotos(sessionId: fixture.sessionId, criteria: exact)
        #expect(Set(onlyNode.map(\.id)) == ["p3"], "eq 只命中该路径本身")
    }

    @Test("keyword_path 的 in / contains_any / contains_all / exists / neq")
    func supportsOperators() throws {
        let fixture = try makeDB()
        let filter = PhotoFilterQuery(connection: fixture.db)
        func ids(_ conditions: [FilterCondition]) throws -> Set<String> {
            let criteria = FilterGroup(logic: .and, conditions: conditions)
            let rows = try filter.filterPhotos(sessionId: fixture.sessionId, criteria: criteria)
            return Set(rows.map(\.id))
        }
        func keywordRule(_ op: FilterOperator, _ value: JSONValue) -> FilterCondition {
            .rule(FilterRule(field: "keyword_path", operator: op, value: value))
        }
        #expect(try ids([keywordRule(.in, .array([.string("Travel|Paris"), .string("flat")]))])
            == ["p1", "p2", "p4"])
        #expect(try ids([keywordRule(.containsAny, .array([.string("People|Alice")]))]) == ["p4"])
        #expect(try ids([keywordRule(.containsAll, .array([
            .string("Travel|Paris"), .string("People|Alice")]))]) == [],
            "没有任何照片同时带两个路径")
        #expect(try ids([keywordRule(.contains, .string("Paris"))]) == ["p1", "p2"])
        #expect(try ids([keywordRule(.neq, .string("Travel|Paris"))]) == ["p3", "p4"],
            "neq = 没有该路径（含完全不带关键词的照片）")
        #expect(try ids([keywordRule(.exists, .null)]) == ["p1", "p2", "p3", "p4"])
    }

    @Test("keyword_path 路径归一化：用户输入的多余空白/空段不导致零结果")
    func normalizesRulePath() throws {
        let fixture = try makeDB()
        let filter = PhotoFilterQuery(connection: fixture.db)
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath(" Travel | Paris ", drilldown: true)),
        ])
        let rows = try filter.filterPhotos(sessionId: fixture.sessionId, criteria: criteria)
        #expect(Set(rows.map(\.id)) == ["p1", "p2"])
    }

    @Test("criteria 分页：游标稳定、跨页无重复无漏项、组内变体一起返回")
    func pagesWithCriteriaStably() throws {
        let fixture = try makeDB()
        let filter = PhotoFilterQuery(connection: fixture.db)
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath("Travel")),
        ])
        var seen: [String] = []
        var cursor: Int64?
        for _ in 0..<5 {
            let page = try filter.assetPage(
                sessionId: fixture.sessionId, criteria: criteria,
                afterFirstRowid: cursor, limit: 2)
            seen.append(contentsOf: page.rows.map(\.id))
            guard let next = page.cursor else { break }
            cursor = next
        }
        #expect(seen == ["p1", "p2", "p3"],
                "同一资产的 RAW+JPEG 一起返回；按首行 rowid 稳定排序、无重复")
    }

    @Test("criteria 分页降序：从尾部开始，游标可继续")
    func pagesDescending() throws {
        let fixture = try makeDB()
        let filter = PhotoFilterQuery(connection: fixture.db)
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath("Travel")),
        ])
        let first = try filter.assetPage(
            sessionId: fixture.sessionId, criteria: criteria,
            afterFirstRowid: nil, limit: 1, descending: true)
        #expect(Set(first.rows.map(\.id)) == ["p3"], "最后导入的资产先出")
        let second = try filter.assetPage(
            sessionId: fixture.sessionId, criteria: criteria,
            afterFirstRowid: first.cursor, limit: 1, descending: true)
        #expect(Set(second.rows.map(\.id)) == ["p1", "p2"])
    }

    @Test("EXPLAIN：keyword_path 规则走 photo_keywords 的索引，不做全表扫描/临时排序")
    func explainUsesKeywordIndex() throws {
        let fixture = try makeDB()
        let clause = try PhotoFilterQuery(connection: fixture.db).whereClause(
            FilterGroup(logic: .and, conditions: [
                .rule(FilterRule.keywordPath("Travel")),
            ]))
        let rows = try fixture.db.prepare("""
            EXPLAIN QUERY PLAN
            SELECT p.id FROM photos p
            LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
            WHERE p.session_id = ? AND (\(clause.sql))
            """).query([.text(fixture.sessionId)] + clause.params)
        let plan = rows.compactMap { $0[3].textValue }.joined(separator: "\n")
        // 实测（SQLite 3.5x）：谓词被下推成相关子查询，按 photo_keywords 的主键
        // (photo_id, keyword_path) 做 SEARCH；若优化器改用路径索引也是合法形态。
        // 要守的是"不扫全表、不做临时排序"，而不是某一个具体索引名。
        #expect(plan.contains("USING INDEX") || plan.contains("USING COVERING INDEX"),
                "EXPLAIN 必须走索引，实际 plan:\n\(plan)")
        #expect(!plan.contains("SCAN photo_keywords"),
                "keyword_path 规则不得全表扫描 photo_keywords，实际 plan:\n\(plan)")
        #expect(!plan.uppercased().contains("TEMP B-TREE"),
                "keyword_path 规则不应引入临时 B-TREE，实际 plan:\n\(plan)")
    }

    @Test("PhotoPageQuery：criteria/sort 解码兼容，排序白名单显式失败")
    func pageQueryCompatibility() throws {
        // 旧客户端载荷（无 criteria/sort 字段）必须原样解码。
        let legacy = Data("""
        {"sessionId":"s-1","limit":50,"afterFirstRowid":7,"expandVariants":true}
        """.utf8)
        let query = try JSONDecoder().decode(PhotoPageQuery.self, from: legacy)
        #expect(query.criteria == nil)
        #expect(query.sortBy == nil)
        #expect(query.sortOrder == nil)
        #expect(query.afterFirstRowid == 7)
        #expect(!query.hasCriteria)

        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.keywordPath("Travel")),
        ])
        let withCriteria = try PhotoPageQuery(
            sessionId: "s-1", criteria: criteria, sortBy: "rowid", sortOrder: "DESC")
        #expect(withCriteria.hasCriteria)
        #expect(withCriteria.sortOrder == "desc", "方向归一化为小写")
        #expect(withCriteria.isDescending)

        #expect(throws: GatherError.self) {
            _ = try PhotoPageQuery(sessionId: "s-1", sortBy: "date_taken")
        }
        #expect(throws: GatherError.self) {
            _ = try PhotoPageQuery(sessionId: "s-1", sortOrder: "sideways")
        }
    }

    @Test("FacetInput：keyword 维在白名单里，keywordPrefix 归一化且非法值显式失败")
    func facetInputKeywordDimension() throws {
        let input = try PhotoFacetInput(
            sessionId: "s-1", criteria: emptyCriteria,
            dimensions: ["keyword", "KEYWORD", "camera"], keywordPrefix: " Travel | Paris ")
        #expect(input.dimensions == ["keyword", "camera"], "去重 + 小写")
        #expect(input.keywordPrefix == "Travel|Paris", "NFC + 段 trim + 丢空段")
        #expect(try PhotoFacetInput(sessionId: "s-1", criteria: emptyCriteria, keywordPrefix: "  ")
            .keywordPrefix == nil)
        #expect(throws: GatherError.self) {
            _ = try PhotoFacetInput(sessionId: "s-1", criteria: emptyCriteria, keywordPrefix: "|")
        }
        #expect(throws: GatherError.self) {
            _ = try PhotoFacetInput(sessionId: "s-1", criteria: emptyCriteria, dimensions: ["nope"])
        }
    }

    @Test("facet 维度字段名与 FilterEngine 的剔除字段一一对应")
    func dimensionFieldsMatchFilterFields() {
        #expect(FacetDimension.camera.field == FilterFields.cameraModel)
        #expect(FacetDimension.lens.field == FilterFields.lensModel)
        #expect(FacetDimension.iso.field == FilterFields.iso)
        #expect(FacetDimension.year.field == FilterFields.dateTaken)
        #expect(FacetDimension.label.field == FilterFields.label)
        #expect(FacetDimension.keyword.field == FilterFields.keywordPath)
        #expect(PhotoFacetInput.allowedDimensions.sorted()
            == FacetDimension.allCases.map(\.rawValue).sorted(),
            "Protocol 白名单与 Persistence 维度枚举必须一一对应")
    }
}
