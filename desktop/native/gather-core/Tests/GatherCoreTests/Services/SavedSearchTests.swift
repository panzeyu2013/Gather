// desktop/native/gather-core/Tests/GatherCoreTests/Services/SavedSearchTests.swift
// P1 下一波 §3.7.3/§3.7.4：保存查询的落库、覆盖、作用域与 criteria 往返。
//
// 上限（gallery_saved_search_limit）由 API 层判断（读设置），这里只验证 repo 的计数口径；
// 这样设置默认值变化不会打挂这批用例。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("保存查询")
struct SavedSearchTests {

    private func makeDB() throws -> (DBConnection, String, String) {
        let db = try makeTestDB()
        let s1 = "s-1"
        let s2 = "s-2"
        for id in [s1, s2] {
            _ = try db.prepare("""
                INSERT INTO sessions (id, name, status, created_at, updated_at)
                VALUES (?, '', 'draft', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([.text(id)])
        }
        return (db, s1, s2)
    }

    private var sampleCriteria: FilterGroup {
        FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "has_face", operator: .eq, value: .bool(true))),
            .rule(FilterRule.keywordPath("Travel|Paris")),
            .group(FilterGroup(logic: .or, conditions: [
                .rule(FilterRule(field: "rating", operator: .gte, value: .number(3))),
                .rule(FilterRule(field: "label", operator: .eq, value: .string("Red"))),
            ])),
        ])
    }

    @Test("保存 / 读取：criteria 结构完整往返（含嵌套 OR 与 keyword_path）")
    func roundTripsCriteria() throws {
        let (db, s1, _) = try makeDB()
        let repo = SavedSearchRepo(connection: db)
        let saved = try repo.upsert(name: "旅行精选", sessionId: s1, criteria: sampleCriteria)
        #expect(saved.name == "旅行精选")
        #expect(saved.sessionId == s1)
        #expect(saved.criteria == sampleCriteria, "criteria_json 往返必须逐条件相等")
        #expect(!saved.createdAt.isEmpty)
        #expect(saved.updatedAt == saved.createdAt, "新建时两个时间戳一致")

        let fetched = try #require(try repo.get(id: saved.id))
        #expect(fetched.criteria == sampleCriteria)
    }

    @Test("同作用域同名 = 覆盖（不新增行），criteria 随之更新")
    func overwritesSameNameInScope() throws {
        let (db, s1, _) = try makeDB()
        let repo = SavedSearchRepo(connection: db)
        let first = try repo.upsert(name: "精选", sessionId: s1, criteria: sampleCriteria)
        let second = try repo.upsert(
            name: "精选", sessionId: s1,
            criteria: FilterGroup(logic: .and, conditions: []))
        #expect(first.id == second.id, "覆盖必须复用同一行")
        #expect(try repo.count() == 1)
        #expect(try #require(try repo.get(id: second.id)).criteria.conditions.isEmpty)
    }

    @Test("全局查询与同名的会话查询是两行（session_id 参与作用域）")
    func globalAndSessionAreDistinct() throws {
        let (db, s1, s2) = try makeDB()
        let repo = SavedSearchRepo(connection: db)
        _ = try repo.upsert(name: "精选", sessionId: nil, criteria: sampleCriteria)
        _ = try repo.upsert(name: "精选", sessionId: s1, criteria: sampleCriteria)
        _ = try repo.upsert(name: "精选", sessionId: s2, criteria: sampleCriteria)
        #expect(try repo.count() == 3, "SQLite 的 UNIQUE(session_id,name) 对 NULL 不生效，覆盖要显式做")
        #expect(try repo.count(sessionId: s1) == 2, "本会话可见 = 全局 + 本会话")
        #expect(try repo.count(sessionId: nil) == 1, "只列全局")

        let scoped = try repo.list(sessionId: s1)
        #expect(scoped.count == 2)
        #expect(scoped.contains { $0.sessionId == nil })
        #expect(scoped.contains { $0.sessionId == s1 })
        #expect(!scoped.contains { $0.sessionId == s2 }, "别的会话的查询不可见")
    }

    @Test("删除：存在返回 true，缺失返回 false（调用方转 INVALID_PARAM）")
    func deletesById() throws {
        let (db, s1, _) = try makeDB()
        let repo = SavedSearchRepo(connection: db)
        let saved = try repo.upsert(name: "待删", sessionId: s1, criteria: sampleCriteria)
        #expect(try repo.delete(id: saved.id))
        #expect(try repo.delete(id: saved.id) == false)
        #expect(try repo.count() == 0)
    }

    @Test("损坏的 criteria_json 显式失败（不静默丢行）")
    func reportsCorruptedCriteria() throws {
        let (db, s1, _) = try makeDB()
        _ = try db.prepare("""
            INSERT INTO saved_searches (id, name, session_id, criteria_json, created_at, updated_at)
            VALUES ('bad', '坏行', ?, '{not json}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([.text(s1)])
        let repo = SavedSearchRepo(connection: db)
        #expect(throws: SavedSearchRepoError.self) {
            _ = try repo.list(sessionId: s1)
        }
    }

    @Test("列表按 updated_at 倒序（最新保存的排在前面）")
    func listsNewestFirst() throws {
        let (db, s1, _) = try makeDB()
        let repo = SavedSearchRepo(connection: db)
        let older = try repo.upsert(name: "旧", sessionId: s1, criteria: sampleCriteria)
        // 直接改时间戳：两次插入可能落在同一毫秒（ISO8601 只到毫秒）。
        _ = try db.prepare(
            "UPDATE saved_searches SET updated_at = '2026-01-01T00:00:00.000Z' WHERE id = ?")
            .run([.text(older.id)])
        let newer = try repo.upsert(name: "新", sessionId: s1, criteria: sampleCriteria)
        _ = try db.prepare(
            "UPDATE saved_searches SET updated_at = '2026-02-01T00:00:00.000Z' WHERE id = ?")
            .run([.text(newer.id)])
        #expect(try repo.list(sessionId: s1).map(\.name) == ["新", "旧"])
    }

    @Test("会话删除级联：saved_searches.session_id 是 CASCADE")
    func cascadesOnSessionDelete() throws {
        let (db, s1, _) = try makeDB()
        let repo = SavedSearchRepo(connection: db)
        _ = try repo.upsert(name: "会话内", sessionId: s1, criteria: sampleCriteria)
        _ = try repo.upsert(name: "全局", sessionId: nil, criteria: sampleCriteria)
        _ = try db.prepare("DELETE FROM sessions WHERE id = ?").run([.text(s1)])
        let remaining = try repo.list(sessionId: nil)
        #expect(remaining.map(\.name) == ["全局"], "会话级查询随会话删除，全局保留")
    }

    @Test("SaveSearchInput 校验：空名/超长名/空会话 id 显式失败")
    func validatesInput() throws {
        let criteria = FilterGroup(logic: .and, conditions: [])
        #expect(throws: GatherError.self) {
            _ = try SaveSearchInput(name: "   ", criteria: criteria)
        }
        #expect(throws: GatherError.self) {
            _ = try SaveSearchInput(
                name: String(repeating: "a", count: SaveSearchInput.maxNameLength + 1),
                criteria: criteria)
        }
        #expect(throws: GatherError.self) {
            _ = try SaveSearchInput(name: "ok", sessionId: "  ", criteria: criteria)
        }
        let input = try SaveSearchInput(name: "  前后空白  ", criteria: criteria)
        #expect(input.name == "前后空白", "名字落库前 trim")
    }

    @Test("SavedSearchData 编解码稳定（wire 字段名与协议一致）")
    func encodesWireShape() throws {
        let data = SavedSearchData(
            id: "id-1", name: "精选", sessionId: nil,
            criteria: FilterGroup(logic: .and, conditions: []),
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z")
        let json = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(SavedSearchData.self, from: json)
        #expect(decoded == data)
        let object = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) ==
            ["id", "name", "criteria", "createdAt", "updatedAt"],
            "sessionId 为 nil 时不编码（与可选字段约定一致）")
    }
}
