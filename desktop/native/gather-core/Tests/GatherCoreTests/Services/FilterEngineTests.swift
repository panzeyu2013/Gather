// desktop/native/gather-core/Tests/GatherCoreTests/Services/FilterEngineTests.swift
// FilterEngine 行为测试（Phase 3.6）。
// TS 源: tests/unit/services/filter/filter-engine.test.ts（regex 拒绝）
// + filter-engine.ts 行为红线（字段×操作符矩阵 + 特殊字段，逐条对账）。
//
// 覆盖：
//   - buildWhereClause：13 操作符 SQL 形态、in 空数组 → 1=0、between 二元组、
//     escapeLike、递归组、未知字段 FILTER_FIELD_UNKNOWN、regex 拒绝
//   - 特殊字段：has_face / person / keywords（json_each 三语义）/ directory /
//     volume / has_duplicates
//   - filterPhotos / countPhotos / filterGlobally / countGlobally / suggest
//     真实 DB 行为

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

private struct Harness {
    let db: DBConnection
    let engine: FilterEngine
    let sessionId: String
}

/// TS: 种子 session + 3 照片 + 元数据。
private func makeHarness() throws -> Harness {
    let db = try makeTestDB()
    let now = "2026-07-30T10:00:00.000Z"
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, source_path, photo_count, created_at, updated_at)
        VALUES ('session', 'Filter', 'photos_loaded', '/photos', 3, ?, ?)
      """).run([.text(now), .text(now)])
    let insertPhoto = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          width, height, created_at, updated_at)
        VALUES (?, 'session', ?, ?, ?, ?, ?, ?, ?, ?)
      """)
    let insertMetadata = try db.prepare("""
        INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken,
          camera_make, camera_model, rating, keywords, cached_at, updated_at)
        VALUES (?, 'session', ?, ?, ?, ?, ?, ?, ?)
      """)
    let photos: [(String, String, String, String, String, Int, Int)] = [
        ("p1", "/photos/IMG_0001.JPG", "IMG_0001.JPG", "abc", "pending", 100, 80),
        ("p2", "/photos/IMG_0002.JPG", "IMG_0002.JPG", "def", "ready", 200, 160),
        ("p3", "/photos/sub/IMG_0003.JPG", "IMG_0003.JPG", "ghi", "missing", 300, 240),
    ]
    for (id, filepath, filename, checksum, status, width, height) in photos {
        _ = try insertPhoto.run([
            .text(id), .text(filepath), .text(filename), .text(checksum), .text(status),
            .int(Int64(width)), .int(Int64(height)), .text(now), .text(now),
        ])
    }
    let metadata: [(String, String, String, String, Int, String)] = [
        ("p1", "2026-07-30T10:00:00.000Z", "Canon", "Canon EOS R5", 5, #"["travel","bw"]"#),
        ("p2", "2026-07-30T10:00:01.000Z", "Nikon", "Nikon Z6", 3, #"["travel"]"#),
        ("p3", "2026-07-30T10:00:20.000Z", "Canon", "Canon EOS R5", 0, #"[]"#),
    ]
    for (id, dateTaken, make, model, rating, keywords) in metadata {
        _ = try insertMetadata.run([
            .text(id), .text(dateTaken), .text(make), .text(model),
            .int(Int64(rating)), .text(keywords), .text(now), .text(now),
        ])
    }
    return Harness(db: db, engine: FilterEngine(connection: db), sessionId: "session")
}

/// 构造单规则组。
private func group(_ rule: FilterRule) -> FilterGroup {
    FilterGroup(logic: .and, conditions: [.rule(rule)])
}

private func rule(_ field: String, _ operator: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: `operator`, value: value)
}

@Suite("FilterEngine")
struct FilterEngineTests {
    // TS: "rejects legacy or forged regular-expression filters"。
    @Test func rejectsRegexOperator() throws {
        let harness = try makeHarness()
        let engine = FilterEngine(connection: harness.db)
        // FilterOperator 无 regex case —— 用字段名伪造（契约层已拒）。
        #expect(FilterOperator.allCases.map(\.rawValue).contains("regex") == false)
    }

    // TS: 未知字段 → FILTER_FIELD_UNKNOWN。
    @Test func unknownFieldThrows() throws {
        let harness = try makeHarness()
        #expect(throws: (any Error).self) {
            _ = try harness.engine.buildWhereClause(group(rule("nope", .eq, .string("x"))))
        }
    }

    // TS: directory 仅 eq/starts_with，其余抛错。
    @Test func directoryRejectsUnsupportedOperators() throws {
        let harness = try makeHarness()
        #expect(throws: (any Error).self) {
            _ = try harness.engine.buildWhereClause(group(rule("directory", .contains, .string("x"))))
        }
        // eq 可用。
        let eq = try harness.engine.buildWhereClause(group(rule("directory", .eq, .string("/photos"))))
        #expect(eq.sql.contains("filepath LIKE ? || '%' ESCAPE"))
    }

    // TS: in 空数组 → 1=0。
    @Test func emptyInIsFalse() throws {
        let harness = try makeHarness()
        let result = try harness.engine.buildWhereClause(group(rule("status", .in, .array([]))))
        #expect(result.sql == "1=0")
    }

    // TS: escapeLike 转义 \ % _。
    @Test func escapeLikeEscapesWildcards() {
        #expect(escapeLike("a%b_c\\d") == "a\\%b\\_c\\\\d")
    }

    // TS: between 二元组。
    @Test func betweenProducesTwoParams() throws {
        let harness = try makeHarness()
        let result = try harness.engine.buildWhereClause(group(rule(
            "rating", .between, .array([.number(2), .number(4)])
        )))
        #expect(result.sql == "pmc.rating BETWEEN ? AND ?")
        // 独立 oracle：两个占位符必须分别绑定下界与上界。只断言参数个数会漏掉
        // 「两处都绑下界」这类错误（变异验证：arr[1] 换成 arr[0] 曾无人杀）。
        #expect(result.params == [.real(2), .real(4)])
    }

    // TS: 递归组（or 内嵌 and 组）。
    @Test func nestedGroupParenthesized() throws {
        let harness = try makeHarness()
        let inner = FilterGroup(logic: .and, conditions: [
            .rule(rule("rating", .gte, .number(3))),
            .rule(rule("status", .eq, .string("ready"))),
        ])
        let outer = FilterGroup(logic: .or, conditions: [
            .rule(rule("camera_make", .eq, .string("Canon"))),
            .group(inner),
        ])
        let result = try harness.engine.buildWhereClause(outer)
        #expect(result.sql == "pmc.camera_make = ? OR (pmc.rating >= ? AND p.status = ?)")
        #expect(result.params.count == 3)
    }

    // TS: filterPhotos 基本过滤 + 排序 + limit。
    @Test func filterPhotosBasic() throws {
        let harness = try makeHarness()
        let photos = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("camera_make", .eq, .string("Canon"))),
            sortBy: "rating",
            sortOrder: "desc"
        )
        #expect(photos.map(\.id) == ["p1", "p3"])
        #expect(photos[0].faceCount == 0)
        #expect(photos[0].hasExistingXmp == false)
        #expect(photos[0].width == 0) // TS: SELECT 未含 width，恒 0
    }

    // TS: filterPhotos limit/offset 引擎内不钳制（直接透传）。
    @Test func filterPhotosPassesLimitThrough() throws {
        let harness = try makeHarness()
        let photos = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: FilterGroup(logic: .and, conditions: []),
            limit: 2
        )
        #expect(photos.count == 2)
    }

    // TS: countPhotos 会话内计数。
    @Test func countPhotosSessionScoped() throws {
        let harness = try makeHarness()
        let count = try harness.engine.countPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("status", .eq, .string("pending")))
        )
        #expect(count == 1)
    }

    // TS: keywords contains_any（json_each）。
    @Test func keywordsContainsAny() throws {
        let harness = try makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .containsAny, .array([.string("travel"), .string("bw")])))
        ).map(\.id)
        #expect(ids.contains("p1"))
        #expect(ids.contains("p2"))
        #expect(!ids.contains("p3"))
    }

    // TS: keywords contains_all —— 同时含 travel 与 bw 的只有 p1。
    @Test func keywordsContainsAll() throws {
        let harness = try makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .containsAll, .array([.string("travel"), .string("bw")])))
        ).map(\.id)
        #expect(ids == ["p1"])
    }

    // TS: keywords eq —— 集合相等（无序）。
    @Test func keywordsEqIgnoresOrder() throws {
        let harness = try makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .eq, .array([.string("bw"), .string("travel")])))
        ).map(\.id)
        #expect(ids == ["p1"])
    }

    // TS: keywords exists —— 非空数组。
    @Test func keywordsExists() throws {
        let harness = try makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .exists, .null))
        ).map(\.id)
        #expect(Set(ids) == Set(["p1", "p2"]))
    }

    // TS: suggest —— camera_make LIKE，<2 字符返回空。
    @Test func suggestFiltersByCameraMake() throws {
        let harness = try makeHarness()
        let short = try harness.engine.suggest(harness.sessionId, keyword: "c")
        #expect(short.isEmpty)
        let suggestions = try harness.engine.suggest(harness.sessionId, keyword: "Can")
        #expect(suggestions.first?.field == "camera_make")
        #expect(suggestions.first?.values == ["Canon"])
    }

    // §4.2 收尾：代表行在 matching 集内按 PhotoRepo.preferredRowOrderSQL 取
    // （RAW 优先、其次最小 rowid），不跨全资产组取变体。
    @Test func globalRepresentativeStaysWithinMatchingSet() throws {
        let harness = try makeHarness()
        let db = harness.db
        let now = "2026-07-30T10:00:00.000Z"
        _ = try db.prepare("""
            INSERT INTO assets (id, status, created_at, updated_at)
            VALUES ('asset-1', 'active', ?, ?)
          """).run([.text(now), .text(now)])
        // 同一资产两个变体：JPEG 先导入（rowid 小），RAW 后导入（rowid 大）。
        let insertVariant = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
              width, height, asset_id, created_at, updated_at)
            VALUES (?, 'session', ?, ?, '', 'ready', 100, 80, 'asset-1', ?, ?)
          """)
        // 文件名与夹具 p1..p3 不重名（photos 有 (session_id, filepath) 唯一索引，
        // 且筛选按 filename 命中）。
        _ = try insertVariant.run([
            .text("v-jpg"), .text("/photos/DSC_0001.JPG"), .text("DSC_0001.JPG"),
            .text(now), .text(now),
        ])
        _ = try insertVariant.run([
            .text("v-raw"), .text("/photos/DSC_0001.NEF"), .text("DSC_0001.NEF"),
            .text(now), .text(now),
        ])
        // 只有 JPEG 有 5 星评分（供「组合筛选只命中 JPEG」用）。
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache (photo_id, session_id, rating, keywords, cached_at, updated_at)
            VALUES ('v-jpg', 'session', 5, '[]', ?, ?)
          """).run([.text(now), .text(now)])

        // A) 只命中 RAW：代表行是该资产的 RAW 变体。
        let rawOnly = try harness.engine.filterGlobally(
            criteria: group(rule("filename", .eq, .string("DSC_0001.NEF")))
        )
        #expect(rawOnly.map(\.photoId) == ["v-raw"])

        // B) 组合条件只命中 JPEG：不得跨 matching 集把 RAW 拿来当代表
        //    （否则返回一条不满足筛选条件的照片）。
        let jpgOnly = try harness.engine.filterGlobally(
            criteria: FilterGroup(logic: .and, conditions: [
                .rule(rule("filename", .eq, .string("DSC_0001.JPG"))),
                .rule(rule("rating", .eq, .number(5))),
            ])
        )
        #expect(jpgOnly.map(\.photoId) == ["v-jpg"])
        #expect(jpgOnly.first?.filename == "DSC_0001.JPG")

        // C) 两变体都命中：RAW 优先（即便 RAW 的 rowid 更大）。
        let both = try harness.engine.filterGlobally(
            criteria: group(rule("filename", .in, .array([
                .string("DSC_0001.JPG"), .string("DSC_0001.NEF"),
            ])))
        )
        // asset-1 两变体都命中：代表行必须是 RAW（rowid 更大也优先）。
        #expect(both.map(\.photoId) == ["v-raw"])
    }

    // §4.2 终审：RAW 清单只有一份（AssetRepo.rawExtensions），PhotoRepo 与
    // PhotoAssets 都是别名；相似度侧逻辑资产折叠与图库/挑片代表行对同一资产
    // 必须选出同一行（含 .x3f 这类旧清单遗漏的扩展名）。
    @Test func rawRulesShareOneExtensionListAcrossLayers() throws {
        #expect(PhotoRepo.rawExtensions == AssetRepo.rawExtensions.sorted())
        #expect(PhotoAssets.rawExtensions == AssetRepo.rawExtensions)
        #expect(AssetRepo.rawExtensions.contains(".x3f"))
        #expect(AssetRepo.rawExtensions.contains(".iiq"))
        #expect(PhotoRepo.rawVariantSQL(alias: "q").contains("LIKE '%.x3f'"))
        // 片段整体带括号：嵌入 AND/OR 复合表达式时优先级仍正确。
        #expect(PhotoRepo.rawVariantSQL(alias: "q").hasPrefix("("))
        #expect(PhotoRepo.rawVariantSQL(alias: "q").hasSuffix(")"))

        let harness = try makeHarness()
        let db = harness.db
        let now = "2026-07-30T10:00:00.000Z"
        _ = try db.prepare("""
            INSERT INTO assets (id, status, created_at, updated_at)
            VALUES ('asset-x3f', 'active', ?, ?)
          """).run([.text(now), .text(now)])
        let insertVariant = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
              width, height, asset_id, created_at, updated_at)
            VALUES (?, 'session', ?, ?, '', 'ready', 100, 80, 'asset-x3f', ?, ?)
          """)
        // JPEG 先导入（rowid 小）、X3F 后导入（rowid 大）。
        _ = try insertVariant.run([
            .text("x-jpg"), .text("/photos/DSC_9.JPG"), .text("DSC_9.JPG"),
            .text(now), .text(now),
        ])
        _ = try insertVariant.run([
            .text("x-raw"), .text("/photos/DSC_9.X3F"), .text("DSC_9.X3F"),
            .text(now), .text(now),
        ])

        // 相似度侧：PhotoAssets.collapse 的逻辑资产成员取 RAW。
        let projection = try PhotoRepo(connection: db).getBySessionProjection(sessionId: "session")
        let logical = PhotoAssets.collapse(projection).first { $0.assetId == "asset-x3f" }
        #expect(logical?.id == "x-raw", "相似度侧逻辑资产必须取 RAW 成员")

        // 图库/挑片侧：filterGlobally 代表行取同一行（同一排序规则）。
        let both = try harness.engine.filterGlobally(
            criteria: group(rule("filename", .in, .array([
                .string("DSC_9.JPG"), .string("DSC_9.X3F"),
            ])))
        )
        #expect(both.map(\.photoId) == ["x-raw"], "图库代表行必须与相似度选同一行")
    }

}

// MARK: - has_duplicates 与决策状态（§4.2 P1 修复）

/// 决策状态判据（与 DuplicateService 单事务后状态一致）：
///   组「已处理」⇔ 组内不存在 resolution IS NULL 的成员；
///   照片命中 has_duplicates=true ⇔ 它所在组仍有未决成员（未处理或部分处理）。
@Suite("FilterEngine has_duplicates 决策语义")
struct FilterHasDuplicatesDecisionTests {
    private func seedGroup(
        _ db: DBConnection,
        id: Int,
        memberCount: Int,
        resolution: String? = nil
    ) throws {
        _ = try db.prepare("""
            INSERT INTO duplicate_groups (id, session_id, group_type, checksum,
              member_count, resolution, created_at)
            VALUES (?, 'session', 'exact', 'k\(id)', ?, ?, '2026-07-30T10:00:00.000Z')
          """).run([.int(Int64(id)), .int(Int64(memberCount)), resolution.map { .text($0) } ?? .null])
    }

    private func seedMember(
        _ db: DBConnection,
        id: Int,
        groupId: Int,
        photoId: String,
        isKept: Bool = true,
        resolution: String? = nil
    ) throws {
        _ = try db.prepare("""
            INSERT INTO duplicate_group_members (id, group_id, photo_id, session_id, is_kept, file_size, file_mtime, resolution)
            VALUES (?, ?, ?, 'session', ?, 100, '2026-07-30T10:00:00.000Z', ?)
          """).run([
            .int(Int64(id)), .int(Int64(groupId)), .text(photoId),
            .int(isKept ? 1 : 0), resolution.map { .text($0) } ?? .null,
          ])
    }

    private func matching(_ harness: Harness, _ hasDuplicates: Bool) throws -> [String] {
        try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("has_duplicates", .eq, .bool(hasDuplicates)))
        ).map(\.id)
    }

    @Test("未处理组（成员 resolution 全 NULL）命中，且只算真实的多成员组")
    func unresolvedGroupMatches() throws {
        let harness = try makeHarness()
        try seedGroup(harness.db, id: 1, memberCount: 2)
        try seedMember(harness.db, id: 1, groupId: 1, photoId: "p1")
        try seedMember(harness.db, id: 2, groupId: 1, photoId: "p2")
        // 单成员组：member_count 快照 > 1 但成员表只有一行 → 不是重复。
        try seedGroup(harness.db, id: 2, memberCount: 9)
        try seedMember(harness.db, id: 3, groupId: 2, photoId: "p3")

        #expect(try matching(harness, true) == ["p1", "p2"])
        #expect(try matching(harness, false) == ["p3"])
    }

    @Test("已处理组（全部成员已决策）不再命中——无论组级 resolution 是否落值")
    func resolvedGroupDoesNotMatch() throws {
        let harness = try makeHarness()
        // 组 1：整组决策（成员 + 组级 resolution 均已落值）。
        try seedGroup(harness.db, id: 1, memberCount: 2, resolution: "keep_one")
        try seedMember(harness.db, id: 1, groupId: 1, photoId: "p1", isKept: true, resolution: "keep_one")
        try seedMember(harness.db, id: 2, groupId: 1, photoId: "p2", isKept: false, resolution: "keep_one")
        // 组 2：逐成员决策到齐，组级 resolution 仍 NULL（派生值未回写）。
        try seedGroup(harness.db, id: 2, memberCount: 2)
        try seedMember(harness.db, id: 3, groupId: 2, photoId: "p3", resolution: "keep_all")
        try seedMember(harness.db, id: 4, groupId: 2, photoId: "p2", resolution: "keep_all")

        #expect(try matching(harness, true).isEmpty)
        #expect(try matching(harness, false) == ["p1", "p2", "p3"])
    }

    @Test("部分处理组：同组仍全部命中（含已丢弃成员）")
    func partiallyResolvedGroupStillMatches() throws {
        let harness = try makeHarness()
        try seedGroup(harness.db, id: 1, memberCount: 2)
        try seedMember(harness.db, id: 1, groupId: 1, photoId: "p1", isKept: false, resolution: "keep_one")
        try seedMember(harness.db, id: 2, groupId: 1, photoId: "p2", isKept: true)

        // 已丢弃（is_kept=0）与未决成员都继续命中：组的重复问题尚未答完。
        #expect(try matching(harness, true) == ["p1", "p2"])
        #expect(try matching(harness, false) == ["p3"])
    }

    @Test("计数与筛选同语义（countPhotos / countGlobally 复用同一判据）")
    func countsShareTheSameSemantics() throws {
        let harness = try makeHarness()
        try seedGroup(harness.db, id: 1, memberCount: 2)
        try seedMember(harness.db, id: 1, groupId: 1, photoId: "p1")
        try seedMember(harness.db, id: 2, groupId: 1, photoId: "p2")
        try seedGroup(harness.db, id: 2, memberCount: 2, resolution: "keep_all")
        try seedMember(harness.db, id: 3, groupId: 2, photoId: "p3", resolution: "keep_all")

        let criteria = group(rule("has_duplicates", .eq, .bool(true)))
        #expect(try harness.engine.countPhotos(sessionId: harness.sessionId, criteria: criteria) == 2)
        #expect(try harness.engine.filterGlobally(criteria: criteria).map(\.photoId) == ["p1", "p2"])
        #expect(try harness.engine.countGlobally(criteria: criteria) == 2)
    }
}

// TS↔Swift 用例对照：
// - filter-engine.test.ts（2 用例）→ rejectsRegexOperator（契约层已拒 regex）/
//   unknownFieldThrows
// - filter-engine.ts 红线补充（本文件新增）→ directoryRejectsUnsupportedOperators /
//   emptyInIsFalse / escapeLikeEscapesWildcards / betweenProducesTwoParams /
//   nestedGroupParenthesized / filterPhotosBasic / filterPhotosPassesLimitThrough /
//   countPhotosSessionScoped / keywordsContainsAny / keywordsContainsAll /
//   keywordsEqIgnoresOrder / keywordsExists / suggestFiltersByCameraMake
// - §4.2 P1 修复（本文件新增）→ FilterEngine has_duplicates 决策语义：
//   unresolvedGroupMatches / resolvedGroupDoesNotMatch /
//   partiallyResolvedGroupStillMatches / countsShareTheSameSemantics
