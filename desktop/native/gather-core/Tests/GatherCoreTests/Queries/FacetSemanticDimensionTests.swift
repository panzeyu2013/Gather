// desktop/native/gather-core/Tests/GatherCoreTests/Queries/FacetSemanticDimensionTests.swift
// Wave2 / task-14：scene/person facet 的计数口径（新维度必须沿用"同维剔除自身条件、
// 跨维取交集、按逻辑资产去重"三条既有红线，否则面板数字与网格对不上）。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("facet 场景/人物维")
struct FacetSemanticDimensionTests {
    private let sessionId = "s-semantic"

    /// 4 张照片：p3/p4 共享同一个 asset（去重口径用），关键词在 AI|场景 子树下，
    /// 人物归属 p1/p2 → 张三、p3/p4 → 李四。
    private func makeDB() throws -> DBConnection {
        let db = try makeTestDB()
        _ = try db.prepare("""
            INSERT INTO sessions (id, name, status, created_at, updated_at)
            VALUES (?, '', 'photos_loaded', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([.text(sessionId)])
        // p3/p4 共享一个逻辑资产：assets 行必须先于 photos（asset_id 有 FK）。
        _ = try db.prepare("""
            INSERT INTO assets (id, status, created_at, updated_at)
            VALUES ('asset-shared', 'active', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([])
        let photos: [(String, String?)] = [
            ("p1", nil), ("p2", nil), ("p3", "asset-shared"), ("p4", "asset-shared"),
        ]
        for (id, assetId) in photos {
            _ = try db.prepare("""
                INSERT INTO photos (id, session_id, asset_id, filepath, filename, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'ready', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([
                    .text(id), .text(sessionId),
                    assetId.map(DBValue.text) ?? .null,
                    .text("/tmp/\(id).CR3"), .text("\(id).CR3"),
                ])
        }
        // 场景标签：beach = p1/p2/p4；wedding = p3/p4（p3/p4 同 asset → 计 1）。
        // 注意 p4 同时带两个标签（李四的人像片横跨两个场景）：跨维收窄的"排除"
        // 断言因此放在 wedding 反例里（张三没有 wedding），避免 fixture 歧义。
        let keywordRows: [(String, String)] = [
            ("p1", "AI|场景|beach"),
            ("p2", "AI|场景|beach"),
            ("p3", "AI|场景|wedding"),
            ("p4", "AI|场景|beach"),
            ("p4", "AI|场景|wedding"),
        ]
        for (photoId, path) in keywordRows {
            _ = try db.prepare("""
                INSERT INTO photo_keywords (photo_id, keyword_path, source, updated_at)
                VALUES (?, ?, 'xmp', '2026-01-01T00:00:00Z')
                """).run([.text(photoId), .text(path)])
        }
        for (personId, name) in [("per-1", "张三"), ("per-2", "李四")] {
            _ = try db.prepare("""
                INSERT INTO persons (id, name, keywords, thumbnail_base64, notes, created_at, updated_at)
                VALUES (?, ?, '[]', '', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([.text(personId), .text(name)])
        }
        let personPhotos: [(String, String)] = [
            ("per-1", "p1"), ("per-1", "p2"), ("per-2", "p3"), ("per-2", "p4"),
        ]
        for (personId, photoId) in personPhotos {
            _ = try db.prepare("""
                INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
                VALUES (?, ?, ?, '{}', 0.9, '2026-01-01T00:00:00Z')
                """).run([.text(personId), .text(photoId), .text(sessionId)])
        }
        return db
    }

    private func counts(_ buckets: [FacetBucket]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: buckets.map { ($0.value, $0.count) })
    }

    @Test("scene 维按 AI|场景 子树取下一段，并按逻辑资产去重")
    func sceneBuckets() throws {
        let db = try makeDB()
        let query = FacetQuery(connection: db)
        let empty = FilterGroup(logic: .and, conditions: [])

        let buckets = try query.buckets(sessionId: sessionId, criteria: empty, dimension: .scene)
        let map = counts(buckets)
        #expect(map["beach"] == 3)
        #expect(map["wedding"] == 1, "p3/p4 共享同一个 asset，计数必须是 1 张而不是 2 张")
    }

    @Test("scene 维剔除自身条件：选了 beach 之后仍列出 wedding，person 维按 beach 收窄")
    func sceneExcludesOwnDimension() throws {
        let db = try makeDB()
        let query = FacetQuery(connection: db)
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: FilterFields.keywordPath, operator: .startsWith,
                value: .string("AI|场景|beach"))),
        ])

        let scene = counts(try query.buckets(
            sessionId: sessionId, criteria: criteria, dimension: .scene))
        #expect(scene["beach"] == 3, "同维规则必须剔除，否则多选取退化成单选")
        #expect(scene["wedding"] == 1)

        let persons = counts(try query.buckets(
            sessionId: sessionId, criteria: criteria, dimension: .person))
        #expect(persons["张三"] == 2, "人物维受 scene 条件约束（p1/p2 有 beach）")
        // p4 同时带 beach 与 wedding，所以"李四"在 beach 视图里**合法**出现 1 张。
        // 这条断言只证明"带上收窄条件"，区分度断言在下面的 wedding 反例里。
        #expect(persons["李四"] == 1, "p4 同时有 beach：李四出现 1 张是正确的收窄结果")

        // 反向收窄（有区分度）：只选 wedding 时，只有李四的照片出现（p3/p4）；
        // 张三的照片（p1/p2）没有 wedding，person 维必须看不到他。
        // 如果 personBuckets 丢掉 criteria，这里会退化成全量（张三 2）→ 直接变红。
        let weddingCriteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: FilterFields.keywordPath, operator: .startsWith,
                value: .string("AI|场景|wedding"))),
        ])
        let weddingPersons = counts(try query.buckets(
            sessionId: sessionId, criteria: weddingCriteria, dimension: .person))
        #expect(weddingPersons["李四"] == 1, "p3/p4 同 asset，按逻辑资产计 1")
        #expect(weddingPersons["张三"] == nil, "张三没有 wedding 照片：person 维必须按 criteria 收窄")
    }

    @Test("person 维剔除自身条件，并与 scene 维交叉收窄")
    func personBuckets() throws {
        let db = try makeDB()
        let query = FacetQuery(connection: db)
        let empty = FilterGroup(logic: .and, conditions: [])

        let all = counts(try query.buckets(
            sessionId: sessionId, criteria: empty, dimension: .person))
        #expect(all["张三"] == 2)
        #expect(all["李四"] == 1, "p3/p4 同 asset → 1")

        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "person", operator: .contains, value: .string("张三"))),
        ])
        let persons = counts(try query.buckets(
            sessionId: sessionId, criteria: criteria, dimension: .person))
        #expect(persons["张三"] == 2)
        #expect(persons["李四"] == 1, "person 维必须剔除自身规则")

        let scene = counts(try query.buckets(
            sessionId: sessionId, criteria: criteria, dimension: .scene))
        #expect(scene["beach"] == 2)
        #expect(scene["wedding"] == nil)
    }

    @Test("多维一次取回：scene/person 同时出现且各自计数独立")
    func multiDimension() throws {
        let db = try makeDB()
        let query = FacetQuery(connection: db)
        let result = try query.buckets(
            sessionId: sessionId,
            criteria: FilterGroup(logic: .and, conditions: []),
            dimensions: [.scene, .person, .camera])
        #expect(result[.scene]?.isEmpty == false)
        #expect(result[.person]?.isEmpty == false)
        #expect(result[.camera] == [])
    }

    @Test("person 维精确口径：facet 数与 eq 网格数一致，contains 会多带同前缀姓名（E3）")
    func personFacetMatchesGridCount() throws {
        let db = try makeDB()
        // 追加"张三丰"（与"张三"同前缀）：p5 只有张三丰，没有任何其它人会命中。
        _ = try db.prepare("""
            INSERT INTO persons (id, name, keywords, thumbnail_base64, notes, created_at, updated_at)
            VALUES ('per-3', '张三丰', '[]', '', '', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([])
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, asset_id, filepath, filename, status, created_at, updated_at)
            VALUES ('p5', ?, NULL, '/tmp/p5.CR3', 'p5.CR3', 'ready',
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([.text(sessionId)])
        _ = try db.prepare("""
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES ('per-3', 'p5', ?, '{}', 0.9, '2026-01-01T00:00:00Z')
            """).run([.text(sessionId)])

        let query = FacetQuery(connection: db)
        let empty = FilterGroup(logic: .and, conditions: [])
        let buckets = counts(try query.buckets(
            sessionId: sessionId, criteria: empty, dimension: .person))
        #expect(buckets["张三"] == 2)
        #expect(buckets["张三丰"] == 1, "facet 桶按完整姓名精确分组")

        // facet 选择走精确匹配（LibraryFacetBar → personFacet → .eq）：网格数必须等于桶数。
        let eqCriteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: FacetDimension.person.field, operator: .eq, value: .string("张三"))),
        ])
        let eqRows = try query.filterQuery.filterPhotos(
            sessionId: sessionId, criteria: eqCriteria)
        #expect(eqRows.count == buckets["张三"], "facet 数 ≠ 网格数就是回归")

        // 旧行为（自由文本 contains / LIKE 子串）会把"张三丰"一起带出来——正是 E3 的错位来源；
        // 保留这条断言，防止有人把 facet 选择改回 contains。
        let containsCriteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: FacetDimension.person.field, operator: .contains, value: .string("张三"))),
        ])
        let containsRows = try query.filterQuery.filterPhotos(
            sessionId: sessionId, criteria: containsCriteria)
        #expect(containsRows.count == 3, "contains 会命中张三(2)+张三丰(1)")
    }

    @Test("维度与图库字段的映射固定（scene → keyword_path，person → person）")
    func dimensionFields() {
        #expect(FacetDimension.scene.field == FilterFields.keywordPath)
        #expect(FacetDimension.person.field == "person")
    }
}
