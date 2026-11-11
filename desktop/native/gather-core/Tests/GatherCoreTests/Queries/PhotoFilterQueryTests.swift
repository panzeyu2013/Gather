// desktop/native/gather-core/Tests/GatherCoreTests/Queries/PhotoFilterQueryTests.swift
// PhotoFilterQuery 的 SQL 边界（真实 SQLite）。
// 与 Services/FilterEngineTests 的分工：那边通过 FilterEngine 断言端到端行为；
// 这里只钉 Query 层新增/未被覆盖的边界：21 个字段的别名矩阵、递归组的参数
// 顺序、空组/空数组/单界 between、session 参数与 limit/offset 的拼接顺序、
// 全局资产去重计数、limit 钳制、directory 的 LIKE 转义真实执行、suggest 上限。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

private func emptyGroup() -> FilterGroup {
    FilterGroup(logic: .and, conditions: [])
}

private func group(_ rule: FilterRule) -> FilterGroup {
    FilterGroup(logic: .and, conditions: [.rule(rule)])
}

private func rule(_ field: String, _ op: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: op, value: value)
}

@Suite("PhotoFilterQuery SQL 边界")
struct PhotoFilterQueryBoundaryTests {
    @Test("简单/元数据字段解析到 p/pmc 别名，未知字段报 FILTER_FIELD_UNKNOWN")
    func fieldResolutionMatrix() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let simple: [(String, String)] = [
            ("filename", "p.filename"), ("filepath", "p.filepath"), ("checksum", "p.checksum"),
            ("status", "p.status"), ("created_at", "p.created_at"),
        ]
        let metadata: [(String, String)] = [
            ("camera_make", "pmc.camera_make"),
            ("camera_model", "pmc.camera_model"), ("lens_model", "pmc.lens_model"),
            ("focal_length", "pmc.focal_length"), ("f_number", "pmc.f_number"),
            ("exposure_time", "pmc.exposure_time"), ("iso", "pmc.iso"),
            ("rating", "pmc.rating"), ("gps_latitude", "pmc.gps_latitude"),
            ("gps_longitude", "pmc.gps_longitude"), ("width", "pmc.width"),
            ("height", "pmc.height"), ("file_size", "pmc.file_size"),
            ("file_mtime", "pmc.file_mtime"), ("label", "pmc.label"),
        ]
        #expect(PhotoFilterQuery.simpleFields.count == simple.count)
        #expect(PhotoFilterQuery.metadataFields.count == metadata.count + 1)
        #expect(PhotoFilterQuery.simpleFields.union(PhotoFilterQuery.metadataFields).count == 21)
        for (field, column) in simple + metadata {
            let clause = try query.whereClause(group(rule(field, .eq, .string("v"))))
            // #10 Step 2：rating / label 的 eq 会套空值规范化（与挑片同口径），
            // 其余字段仍是裸列比较。规范化只在 eq/in 上生效。
            let expected: String
            switch field {
            case "rating": expected = "\(FilterFieldSQL.rating(column)) = ?"
            case "label": expected = "\(FilterFieldSQL.label(column)) = ?"
            default: expected = "\(column) = ?"
            }
            #expect(clause.sql == expected, "字段 \(field) 必须解析到 \(column)（含 #10 规范化）")
            #expect(clause.params == [.text("v")])
        }
        let dateClause = try query.whereClause(group(rule("date_taken", .eq, .string("v"))))
        #expect(dateClause.sql == "\(PhotoFilterQuery.normalizedDateTaken) = ?")
        #expect(throws: PhotoFilterQueryError.fieldUnknown("notes")) {
            _ = try query.whereClause(group(rule("notes", .eq, .string("x"))))
        }
    }

    @Test("date_taken 混合 EXIF/ISO：between 与排序按归一化文本")
    func dateTakenMixedFormats() throws {
        let db = try makeQueryTestDB()
        let sessionId = "s-date"
        try queryInsertSession(db, id: sessionId)
        for id in ["p1", "p2"] {
            try queryInsertPhoto(db, id: id, sessionId: sessionId)
            try queryInsertCache(db, photoId: id, sessionId: sessionId)
        }
        _ = try db.prepare("UPDATE photo_metadata_cache SET date_taken = ? WHERE photo_id = 'p1'")
            .run([.text("2024:05:01 10:00:00")])
        _ = try db.prepare("UPDATE photo_metadata_cache SET date_taken = ? WHERE photo_id = 'p2'")
            .run([.text("2023-12-31T23:00:00")])
        let query = PhotoFilterQuery(connection: db)
        let between = [JSONValue.string("2024-01-01"), .string("2024-12-31")]
        let hit = try query.filterPhotos(
            sessionId: sessionId,
            criteria: group(rule("date_taken", .between, .array(between))),
            sortBy: "date_taken", sortOrder: "asc"
        )
        #expect(hit.map(\.id) == ["p1"], "EXIF 冒号日期必须与 ISO 同口径比较")
        let all = try query.filterPhotos(
            sessionId: sessionId, criteria: emptyGroup(),
            sortBy: "date_taken", sortOrder: "asc")
        #expect(all.map(\.id) == ["p2", "p1"], "排序也必须按归一化时间")
    }

    @Test("neq 保留未填写行；关键词 contains 走子串匹配")
    func neqKeepsNullsAndKeywordSubstring() throws {
        let db = try makeQueryTestDB()
        let sessionId = "s-neq"
        try queryInsertSession(db, id: sessionId)
        for id in ["p1", "p2"] {
            try queryInsertPhoto(db, id: id, sessionId: sessionId)
            try queryInsertCache(db, photoId: id, sessionId: sessionId)
        }
        _ = try db.prepare("UPDATE photo_metadata_cache SET label = NULL, keywords = ? WHERE photo_id = 'p1'")
            .run([.text(#"["日落 海边"]"#)])
        _ = try db.prepare("UPDATE photo_metadata_cache SET label = 'Red', keywords = ? WHERE photo_id = 'p2'")
            .run([.text(#"["城市"]"#)])

        let query = PhotoFilterQuery(connection: db)
        func ids(_ rule: FilterRule) throws -> [String] {
            try query.filterPhotos(sessionId: sessionId, criteria: group(rule)).map(\.id).sorted()
        }
        #expect(try ids(rule("label", .neq, .string("Red"))) == ["p1"], "未填色标的照片不能被 neq 丢掉")
        #expect(try ids(rule("keywords", .contains, .string("日落"))) == ["p1"], "关键词搜索应为子串")
    }

    @Test("多字段搜索：IPTC title/creator 数组/country/city 都走 json_extract 且语义正确")
    func iptcJsonMultiFieldSearch() throws {
        let db = try makeQueryTestDB()
        let sessionId = "s-iptc"
        try queryInsertSession(db, id: sessionId)
        try queryInsertPhoto(db, id: "p1", sessionId: sessionId)
        try queryInsertPhoto(db, id: "p2", sessionId: sessionId)
        try queryInsertCache(db, photoId: "p1", sessionId: sessionId)
        try queryInsertCache(db, photoId: "p2", sessionId: sessionId)
        let p1 = #"{"title":"落日","creator":["张三","李四"],"city":"上海","country":"中国"}"#
        let p2 = #"{"title":"城市夜景","creator":["王五"],"city":"北京","country":"中国"}"#
        _ = try db.prepare("UPDATE photo_metadata_cache SET iptc_json = ? WHERE photo_id = 'p1'")
            .run([.text(p1)])
        _ = try db.prepare("UPDATE photo_metadata_cache SET iptc_json = ? WHERE photo_id = 'p2'")
            .run([.text(p2)])

        let query = PhotoFilterQuery(connection: db)
        func ids(_ rule: FilterRule) throws -> [String] {
            try query.filterPhotos(sessionId: sessionId, criteria: group(rule))
                .map(\.id).sorted()
        }
        #expect(try ids(rule("title", .contains, .string("落日"))) == ["p1"])
        #expect(try ids(rule("creator", .eq, .string("张三"))) == ["p1"], "数组字段按元素判定")
        #expect(try ids(rule("creator", .eq, .string("王五"))) == ["p2"])
        #expect(try ids(rule("city", .contains, .string("上海"))) == ["p1"])
        #expect(try ids(rule("country", .eq, .string("中国"))) == ["p1", "p2"])
        #expect(try ids(rule("creator", .exists, .bool(true))) == ["p1", "p2"])
    }

    @Test("递归组的 SQL 括号与参数保持遍历顺序")
    func nestedGroupParameterOrder() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let criteria = FilterGroup(logic: .or, conditions: [
            .rule(rule("filename", .eq, .string("a.jpg"))),
            .group(FilterGroup(logic: .and, conditions: [
                .rule(rule("rating", .gte, .number(4))),
                .rule(rule("status", .in, .array([.string("ready"), .string("missing")]))),
                .group(emptyGroup()),
            ])),
            .rule(rule("iso", .between, .array([.number(100), .number(400)]))),
        ])
        let clause = try query.whereClause(criteria)
        #expect(clause.sql == "p.filename = ? OR (pmc.rating >= ? AND p.status IN (?, ?)) OR pmc.iso BETWEEN ? AND ?")
        #expect(clause.params == [
            .text("a.jpg"), .real(4), .text("ready"), .text("missing"), .real(100), .real(400),
        ])
    }

    @Test("空组/空 IN/空 contains_any/单值 between 的退化为安全常量")
    func degenerateConditions() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let empty = try query.whereClause(emptyGroup())
        #expect(empty == FilterWhereClause(sql: "", params: []))
        let onlyEmpty = try query.whereClause(FilterGroup(logic: .or, conditions: [.group(emptyGroup())]))
        #expect(onlyEmpty == FilterWhereClause(sql: "", params: []))

        let emptyIn = try query.whereClause(group(rule("status", .in, .array([]))))
        #expect(emptyIn.sql == "1=0")
        #expect(emptyIn.params.isEmpty)

        let emptyAny = try query.whereClause(group(rule("keywords", .containsAny, .array([]))))
        #expect(emptyAny.sql == "1=0")
        #expect(emptyAny.params.isEmpty)

        let emptyAll = try query.whereClause(group(rule("status", .containsAll, .array([]))))
        #expect(emptyAll.sql == "1=0")
        #expect(emptyAll.params.isEmpty)

        // 标量 between：不足二元组时上下界都绑同一个值。
        let oneBound = try query.whereClause(group(rule("rating", .between, .number(3))))
        #expect(oneBound.sql == "pmc.rating BETWEEN ? AND ?")
        #expect(oneBound.params == [.real(3), .real(3)])
    }

    @Test("filterPhotos 先绑 session 再绑 where 参数，limit/offset 透传且排序回退 filename")
    func filterPhotosParameterOrderAndPagination() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1", name: "One")
        try queryInsertSession(db, id: "s2", name: "Two")
        try queryInsertAsset(db, id: "asset-shared")
        try queryInsertPhoto(db, id: "p1", sessionId: "s1", filepath: "/s1/a.jpg", assetId: "asset-shared")
        try queryInsertPhoto(db, id: "p2", sessionId: "s1", filepath: "/s1/b.jpg")
        try queryInsertPhoto(db, id: "p3", sessionId: "s1", filepath: "/s1/c.jpg")
        try queryInsertPhoto(db, id: "p4", sessionId: "s2", filepath: "/s2/d.jpg", assetId: "asset-shared")
        try queryInsertCache(db, photoId: "p1", sessionId: "s1", rating: 5)
        try queryInsertCache(db, photoId: "p2", sessionId: "s1", rating: 4)
        try queryInsertCache(db, photoId: "p3", sessionId: "s1", rating: 3)
        try queryInsertCache(db, photoId: "p4", sessionId: "s2", rating: 5)

        let query = PhotoFilterQuery(connection: db)
        let high = group(rule("rating", .gte, .number(4)))

        // 元数据排序 + 第二页：sessionId 插在 clause 参数之前，offset/limit 依序追加。
        let second = try query.filterPhotos(
            sessionId: "s1", criteria: high, sortBy: "rating", sortOrder: "desc",
            limit: 1, offset: 1
        )
        #expect(second.map(\.id) == ["p2"])

        // 未知 sortBy 回退 p.filename。
        let fallback = try query.filterPhotos(
            sessionId: "s1", criteria: high, sortBy: "not_a_field", sortOrder: "asc"
        )
        #expect(fallback.map(\.id) == ["p1", "p2"])

        // __global__ 去掉 session 参数，跨会话返回（每物理行一条）。
        let global = try query.filterPhotos(
            sessionId: "__global__", criteria: high, sortBy: "filename", sortOrder: "desc"
        )
        #expect(global.map(\.id) == ["p4", "p2", "p1"])

        // limit 0 透传（引擎层不钳制）。
        let none = try query.filterPhotos(sessionId: "s1", criteria: high, limit: 0)
        #expect(none.isEmpty)

        // 会话内按照片去重；__global__ 按资产去重。
        #expect(try query.countPhotos(sessionId: "s1", criteria: high) == 2)
        #expect(try query.countPhotos(sessionId: "__global__", criteria: high) == 2)
    }

    @Test("filterGlobally 代表行、limit 钳制 1...500 与 offset 下限 0")
    func filterGloballyLimitClamp() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s", name: "Global")
        for i in 1...501 {
            try queryInsertAsset(db, id: "ga\(i)")
            try queryInsertPhoto(db, id: "gp\(i)", sessionId: "s",
                                 filepath: "/global/\(i).jpg", assetId: "ga\(i)")
        }
        let query = PhotoFilterQuery(connection: db)
        let criteria = emptyGroup()

        let clamped = try query.filterGlobally(criteria: criteria, limit: 999)
        #expect(clamped.count == 500)
        #expect(clamped.first?.photoId == "gp1")
        #expect(clamped.last?.photoId == "gp500")

        let zero = try query.filterGlobally(criteria: criteria, limit: 0)
        #expect(zero.map(\.photoId) == ["gp1"], "limit 0 必须钳到 1")

        let last = try query.filterGlobally(criteria: criteria, limit: 1, offset: 500)
        #expect(last.map(\.photoId) == ["gp501"])

        let negativeOffset = try query.filterGlobally(criteria: criteria, limit: 1, offset: -5)
        #expect(negativeOffset.map(\.photoId) == ["gp1"], "负 offset 必须钳到 0")

        let pastEnd = try query.filterGlobally(criteria: criteria, limit: 1, offset: 999)
        #expect(pastEnd.isEmpty)

        #expect(try query.countGlobally(criteria: criteria) == 501)
    }

    @Test("directory 的 LIKE 转义在 SQL 中真实生效（_ 与 % 不作通配符）")
    func directoryEscapesWildcardsInSQL() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertPhoto(db, id: "p1", sessionId: "s", filepath: "/shoot/a_b/one.jpg")
        try queryInsertPhoto(db, id: "p2", sessionId: "s", filepath: "/shoot/axb/two.jpg")
        try queryInsertPhoto(db, id: "p3", sessionId: "s", filepath: "/shoot/a%b/three.jpg")
        let query = PhotoFilterQuery(connection: db)

        let underscore = try query.filterPhotos(
            sessionId: "s", criteria: group(rule("directory", .eq, .string("/shoot/a_b")))
        )
        #expect(underscore.map(\.id) == ["p1"])

        let percent = try query.filterPhotos(
            sessionId: "s", criteria: group(rule("directory", .startsWith, .string("/shoot/a%")))
        )
        #expect(percent.map(\.id) == ["p3"])

        #expect(throws: PhotoFilterQueryError.unsupportedOperatorForField(field: "directory", op: "contains")) {
            _ = try query.whereClause(group(rule("directory", .contains, .string("/shoot"))))
        }
    }

    @Test("suggest 先 trim 再卡 2 字符下限，DISTINCT 结果最多 5 条")
    func suggestTrimAndLimit() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        for i in 1...6 {
            try queryInsertPhoto(db, id: "p\(i)", sessionId: "s", filepath: "/s/\(i).jpg")
            try queryInsertCache(db, photoId: "p\(i)", sessionId: "s", cameraMake: "Canon \(i)")
        }
        let query = PhotoFilterQuery(connection: db)

        #expect(try query.suggest("s", keyword: "  c  ").isEmpty)
        #expect(try query.suggest("s", keyword: "  ").isEmpty)

        let suggestions = try query.suggest("s", keyword: " canon ")
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.field == "camera_make")
        #expect(suggestions.first?.values.count == 5, "SQL LIMIT 5")
        #expect(suggestions.first?.values.allSatisfy { $0.hasPrefix("Canon ") } == true)
    }

    @Test("filterGlobally 读取 INTEGER rating（不能只认 REAL）")
    func filterGloballyReadsIntegerRating() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s", name: "Global")
        try queryInsertAsset(db, id: "a1")
        try queryInsertPhoto(db, id: "p1", sessionId: "s", assetId: "a1")
        try queryInsertCache(db, photoId: "p1", sessionId: "s", rating: 4)

        let rows = try PhotoFilterQuery(connection: db).filterGlobally(criteria: emptyGroup())
        #expect(rows.map(\.rating) == [4])
    }

    @Test("filterPhotos 只传 offset 时补 LIMIT -1，SQLite 合法且分页正确")
    func filterPhotosOffsetWithoutLimit() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        for i in 1...3 {
            try queryInsertPhoto(db, id: "p\(i)", sessionId: "s", filepath: "/s/\(i).jpg")
        }

        let rows = try PhotoFilterQuery(connection: db).filterPhotos(
            sessionId: "s", criteria: emptyGroup(),
            sortBy: "filename", sortOrder: "asc", offset: 1)
        #expect(rows.map(\.id) == ["p2", "p3"])
    }
}

// MARK: - Wave5（batch2）：关键词同义词检索

@Suite("关键词同义词检索（Wave5 batch2）")
struct PhotoFilterSynonymSearchTests {
    private struct Fixture {
        let db: DBConnection
        let sessionId: String
    }

    /// 词库：Travel（父）→ Travel|Paris（同义词 Paris / 巴黎）、故宫（同义词 Gugong）、
    /// Tokyo（无同义词）。
    /// 照片（pmc.keywords 用**叶子**形态，与 keyword_dc_style=leaf 的现实数据一致；
    /// photo_keywords 用**规范路径**）：
    /// p1 = Travel|Paris / ["Paris"]、p2 = 故宫 / ["故宫"]、p3 = Tokyo / ["Tokyo"]、
    /// p4 = 无关键词。
    private func makeDB() throws -> Fixture {
        let db = try makeQueryTestDB()
        let sessionId = "s-syn"
        try queryInsertSession(db, id: sessionId)
        let photos: [(id: String, keywords: String)] = [
            ("p1", #"["Paris"]"#),
            ("p2", #"["故宫"]"#),
            ("p3", #"["Tokyo"]"#),
            ("p4", "[]"),
        ]
        for photo in photos {
            try queryInsertPhoto(db, id: photo.id, sessionId: sessionId)
            try queryInsertCache(
                db, photoId: photo.id, sessionId: sessionId, keywords: photo.keywords)
        }
        let now = "2026-01-01T00:00:00.000Z"
        let keywordRows: [(path: String, name: String, parent: String?)] = [
            ("Travel", "Travel", nil),
            ("Travel|Paris", "Paris", "Travel"),
            ("故宫", "故宫", nil),
            ("Tokyo", "Tokyo", nil),
        ]
        for row in keywordRows {
            _ = try db.prepare("""
                INSERT INTO keywords (path, name, parent_path, usage_count, created_at)
                VALUES (?, ?, ?, 0, ?)
                """).run([
                    .text(row.path), .text(row.name),
                    row.parent.map(DBValue.text) ?? .null, .text(now),
                ])
        }
        let synonyms: [(path: String, synonym: String)] = [
            ("Travel|Paris", "Paris"),
            ("Travel|Paris", "巴黎"),
            ("故宫", "Gugong"),
        ]
        for row in synonyms {
            _ = try db.prepare(
                "INSERT INTO keyword_synonyms (keyword_path, synonym) VALUES (?, ?)")
                .run([.text(row.path), .text(row.synonym)])
        }
        let joined: [(photoId: String, path: String)] = [
            ("p1", "Travel|Paris"), ("p2", "故宫"), ("p3", "Tokyo"),
        ]
        for row in joined {
            _ = try db.prepare("""
                INSERT INTO photo_keywords (photo_id, keyword_path, source, updated_at)
                VALUES (?, ?, 'xmp', ?)
                """).run([.text(row.photoId), .text(row.path), .text(now)])
        }
        return Fixture(db: db, sessionId: sessionId)
    }

    private func ids(_ fixture: Fixture, _ rule: FilterRule) throws -> [String] {
        try PhotoFilterQuery(connection: fixture.db)
            .filterPhotos(sessionId: fixture.sessionId, criteria: group(rule))
            .map(\.id).sorted()
    }

    @Test("keyword_path eq：按同义词命中规范路径；无同义词时行为不变")
    func keywordPathEqExpandsSynonyms() throws {
        let fixture = try makeDB()
        #expect(try ids(fixture, rule("keyword_path", .eq, .string("Gugong"))) == ["p2"])
        #expect(try ids(fixture, rule("keyword_path", .eq, .string("故宫"))) == ["p2"])
        #expect(try ids(fixture, rule("keyword_path", .eq, .string("巴黎"))) == ["p1"],
                "同义词「巴黎」→ 规范路径 Travel|Paris")
        #expect(try ids(fixture, rule("keyword_path", .eq, .string("Tokyo"))) == ["p3"])
        #expect(try ids(fixture, rule("keyword_path", .eq, .string("Nowhere"))).isEmpty)
    }

    @Test("keyword_path neq：同义词命中的照片同样被排除")
    func keywordPathNeqExcludesSynonymMatches() throws {
        let fixture = try makeDB()
        #expect(try ids(fixture, rule("keyword_path", .neq, .string("Gugong")))
                == ["p1", "p3", "p4"])
        #expect(try ids(fixture, rule("keyword_path", .neq, .string("Tokyo")))
                == ["p1", "p2", "p4"])
    }

    @Test("keyword_path contains：同义词整词映射做子串命中（不做子串反查）")
    func keywordPathContainsExpandsSynonyms() throws {
        let fixture = try makeDB()
        #expect(try ids(fixture, rule("keyword_path", .contains, .string("Gugong"))) == ["p2"])
        #expect(try ids(fixture, rule("keyword_path", .contains, .string("Paris"))) == ["p1"])
        // 边界：只有整词命中才展开，输入 "Gug" 不命中任何照片。
        #expect(try ids(fixture, rule("keyword_path", .contains, .string("Gug"))).isEmpty)
    }

    @Test("keyword_path contains_any/all 与 starts_with：同义词与规范路径混合")
    func keywordPathAnyAllAndStartsWith() throws {
        let fixture = try makeDB()
        #expect(try ids(fixture, rule("keyword_path", .containsAny,
            .array([.string("Gugong"), .string("Tokyo")]))) == ["p2", "p3"])
        #expect(try ids(fixture, rule("keyword_path", .containsAll,
            .array([.string("Gugong"), .string("Tokyo")]))).isEmpty,
                "不同照片的关键词不能同时满足 contains_all")
        #expect(try ids(fixture, rule("keyword_path", .containsAll,
            .array([.string("Gugong"), .string("故宫")]))) == ["p2"],
                "同一规范路径的两种写法算同一个词")
        #expect(try ids(fixture, rule("keyword_path", .startsWith, .string("巴黎"))) == ["p1"])
        #expect(try ids(fixture, rule("keyword_path", .startsWith, .string("Travel"))) == ["p1"])
    }

    @Test("keywords（dc:subject JSON）contains / any / all / eq 走同义词")
    func keywordsJsonExpandsSynonyms() throws {
        let fixture = try makeDB()
        #expect(try ids(fixture, rule("keywords", .contains, .string("Gugong"))) == ["p2"])
        #expect(try ids(fixture, rule("keywords", .containsAny,
            .array([.string("Gugong")]))) == ["p2"])
        #expect(try ids(fixture, rule("keywords", .containsAny,
            .array([.string("Gugong"), .string("Tokyo")]))) == ["p2", "p3"])
        #expect(try ids(fixture, rule("keywords", .containsAll,
            .array([.string("Gugong"), .string("Tokyo")]))).isEmpty)
        // eq（整表相等）命中同义词时退化为「每个词都有等价命中」。
        #expect(try ids(fixture, rule("keywords", .eq, .array([.string("Gugong")]))) == ["p2"])
        // 无同义词时 eq 仍是整表相等。
        #expect(try ids(fixture, rule("keywords", .eq, .array([.string("Tokyo")]))) == ["p3"])
    }

    @Test("无同义词时不改 SQL 形状（既有索引计划/契约不回归）")
    func noSynonymKeepsLegacySQLShape() throws {
        let fixture = try makeDB()
        let query = PhotoFilterQuery(connection: fixture.db)
        let pathClause = try query.whereClause(group(rule("keyword_path", .eq, .string("Tokyo"))))
        #expect(pathClause.sql ==
            "EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = p.id AND (pk.keyword_path = ?))")
        #expect(pathClause.params == [.text("Tokyo")])
        let keywordsClause = try query.whereClause(group(rule("keywords", .contains, .string("海滩"))))
        #expect(keywordsClause.sql.hasPrefix(
            "EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value LIKE"))
        #expect(keywordsClause.params == [.text("海滩")])
    }

    @Test("Wave5 新字段的检索 id 契约（id → iptc_json key）")
    func newFieldIdsContract() {
        #expect(PhotoFilterQuery.jsonFields["instructions"] == "instructions")
        #expect(PhotoFilterQuery.jsonFields["event_identifier"] == "eventIdentifier")
        #expect(PhotoFilterQuery.jsonFields["model_release_id"] == "modelReleaseID")
        #expect(PhotoFilterQuery.jsonFields["property_release_id"] == "propertyReleaseID")
        #expect(PhotoFilterQuery.jsonArrayFields.contains("event_identifier"))
        #expect(PhotoFilterQuery.jsonArrayFields.contains("model_release_id"))
        #expect(PhotoFilterQuery.jsonArrayFields.contains("property_release_id"))
    }

    @Test("Wave5 新字段可检索：instructions / event_identifier / release id")
    func newIPTCFieldsAreSearchable() throws {
        let db = try makeQueryTestDB()
        let sessionId = "s-iptc5"
        try queryInsertSession(db, id: sessionId)
        for id in ["p1", "p2"] {
            try queryInsertPhoto(db, id: id, sessionId: sessionId)
            try queryInsertCache(db, photoId: id, sessionId: sessionId)
        }
        let metadata = DescriptiveMetadata(
            instructions: "Embargo until 2026-12-01",
            eventIdentifier: ["urn:event:acme-2026"],
            modelReleaseID: ["MR-0001"])
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        _ = try db.prepare(
            "UPDATE photo_metadata_cache SET iptc_json = ? WHERE photo_id = 'p1'")
            .run([.text(json)])
        let query = PhotoFilterQuery(connection: db)
        func hit(_ rule: FilterRule) throws -> [String] {
            try query.filterPhotos(sessionId: sessionId, criteria: group(rule)).map(\.id).sorted()
        }
        #expect(try hit(rule("instructions", .contains, .string("Embargo"))) == ["p1"])
        #expect(try hit(rule("instructions", .eq, .string("Embargo until 2026-12-01"))) == ["p1"])
        #expect(try hit(rule("event_identifier", .containsAny,
            .array([.string("acme-2026")]))) == ["p1"])
        #expect(try hit(rule("event_identifier", .eq,
            .string("urn:event:acme-2026"))) == ["p1"])
        #expect(try hit(rule("model_release_id", .contains, .string("MR-0001"))) == ["p1"])
        #expect(try hit(rule("property_release_id", .exists, .bool(true))).isEmpty,
                "未填写的列表字段 exists=false（p2 连 iptc_json 都没有）")
    }
}

// MARK: - Wave5（batch2）：搜索串覆盖新字段

@Suite("搜索串覆盖 Wave5 新字段")
struct PhotoFilterSearchStringWave5Tests {
    @Test("搜索串 OR 组（Gallery searchCriteria 形态）命中 instructions / event id / release id")
    func searchStringOrGroupCoversWave5Fields() throws {
        let db = try makeQueryTestDB()
        let sessionId = "s-search-wave5"
        try queryInsertSession(db, id: sessionId)
        for id in ["p1", "p2"] {
            try queryInsertPhoto(db, id: id, sessionId: sessionId)
            try queryInsertCache(db, photoId: id, sessionId: sessionId)
        }
        let metadata = DescriptiveMetadata(
            instructions: "Embargo until 2026-12-01",
            eventIdentifier: ["urn:event:acme-2026"],
            modelReleaseID: ["MR-0001"],
            propertyReleaseID: ["PR-0001"])
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        _ = try db.prepare(
            "UPDATE photo_metadata_cache SET iptc_json = ? WHERE photo_id = 'p1'")
            .run([.text(json)])
        // 与 GalleryViewModel+Filters.searchCriteria 同形：顶层 OR + 每字段 contains。
        let fields = [
            "filename", "instructions", "event_identifier",
            "model_release_id", "property_release_id",
        ]
        let query = PhotoFilterQuery(connection: db)
        func hit(_ needle: String) throws -> [String] {
            let group = FilterGroup(logic: .or, conditions: fields.map { field -> FilterCondition in
                .rule(FilterRule(field: field, operator: .contains, value: .string(needle)))
            })
            return try query.filterPhotos(sessionId: sessionId, criteria: group)
                .map(\.id).sorted()
        }
        #expect(try hit("Embargo") == ["p1"])
        #expect(try hit("acme-2026") == ["p1"])
        #expect(try hit("MR-0001") == ["p1"])
        #expect(try hit("PR-0001") == ["p1"])
        #expect(try hit("没有这个值").isEmpty)
    }
}


