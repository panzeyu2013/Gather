// desktop/native/gather-app/Tests/GatherAppTests/FilterRuleRoundTripTests.swift
// Wave2 收尾 task-22：规则编辑器 "UI 编辑 → JSON → PhotoFilterQuery 执行" 往返。
//
// 编辑器动作走 FilterEditorModel（与 FilterRuleEditor 快捷菜单同一入口）；
// 断言三件事：
// 1. 编辑器产出的 FilterGroup 编码 JSON 后仍能按协议解码（保存查询/智能相册同构）；
// 2. NOT 组（子条件 OR 后取反）在服务端 SQL 语义下真的排除照片；
// 3. 集合成员 / 堆栈成员 / 相对日期三类入口执行结果与 UI 勾选一致。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherUI

@Suite("规则编辑器往返（UI 编辑 → JSON → SQL）")
struct FilterRuleRoundTripTests {

    private struct Fixture {
        let db: DBConnection
        let photoQuery: PhotoFilterQuery
    }

    private func dateString(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return formatter.string(from: date)
    }

    private func makeFixture() throws -> Fixture {
        let db = try makeTestDB()
        try insertSession(db, "s-1")
        for id in ["p1", "p2", "p3"] {
            try insertPhoto(db, id: id, sessionId: "s-1", filepath: "/tmp/rule/\(id).jpg")
        }
        let cacheSql = """
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, date_taken, rating, keywords, iptc_json, cached_at)
            VALUES (?, 's-1', ?, ?, '[]', '{}', '2026-01-01T00:00:00Z')
            """
        _ = try db.prepare(cacheSql).run([.text("p1"), .text(dateString(daysAgo: 0)), .int(3)])
        _ = try db.prepare(cacheSql).run([.text("p2"), .text(dateString(daysAgo: 1)), .int(5)])
        // p3 老照片：不满足"最近 7 天"，但属于集合 c1。
        _ = try db.prepare(cacheSql).run([.text("p3"), .text(dateString(daysAgo: 40)), .int(1)])

        _ = try db.prepare("""
            INSERT INTO collections (id, session_id, name, sort_order, created_at, updated_at)
            VALUES ('c1', 's-1', '客户精选', 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run()
        for (index, photoId) in ["p1", "p2", "p3"].enumerated() {
            _ = try db.prepare("""
                INSERT INTO collection_items (collection_id, photo_id, position, added_at)
                VALUES ('c1', ?, ?, '2026-01-01T00:00:00Z')
                """).run([.text(photoId), .int(Int64(index + 1) * 1024)])
        }
        _ = try db.prepare("""
            INSERT INTO photo_stacks (id, session_id, name, created_at, updated_at)
            VALUES ('st1', 's-1', '连拍 A', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run()
        _ = try db.prepare("""
            INSERT INTO photo_stack_members (stack_id, photo_id, position)
            VALUES ('st1', 'p2', 0)
            """).run()
        return Fixture(db: db, photoQuery: PhotoFilterQuery(connection: db))
    }

    private func execute(_ group: FilterGroup, fixture: Fixture) throws -> [String] {
        let data = try FilterEditorModel.encodeJSON(group)
        let decoded = try FilterEditorModel.decodeJSON(data)
        let rows = try fixture.photoQuery.filterPhotos(sessionId: "s-1", criteria: decoded)
        return rows.map(\.id).sorted()
    }

    @Test func notGroupExcludesMatchingPhoto() throws {
        let fixture = try makeFixture()
        var group = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addCollectionMembership(ids: ["c1"], anyOf: false, to: &group)
        FilterEditorModel.addNotGroup(
            to: &group,
            seed: FilterRule(field: "filename", operator: .eq, value: .string("p1.jpg")))
        // NOT 组内再叠加一条或条件：子条件 OR 后整体取反（p1/p2 都不满足才算）——
        // 这里只放一条，等价于"排除 p1"。
        #expect(group.conditions.count == 2)
        #expect(try execute(group, fixture: fixture) == ["p2", "p3"])
    }

    @Test func collectionMembershipAnyOfAndExclusion() throws {
        let fixture = try makeFixture()
        var group = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addRule(
            FilterRule.collectionMembership(anyOf: ["c1"]), to: &group)
        #expect(try execute(group, fixture: fixture) == ["p1", "p2", "p3"])

        var excluded = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addCollectionExclusion(id: "c1", to: &excluded)
        #expect(try execute(excluded, fixture: fixture) == [])
    }

    @Test func stackMembership() throws {
        let fixture = try makeFixture()
        var group = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addStackMembership(id: "st1", to: &group)
        #expect(try execute(group, fixture: fixture) == ["p2"])
    }

    @Test func relativeDateLastSevenDays() throws {
        let fixture = try makeFixture()
        var group = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addRelativeDate(.last7, to: &group)
        #expect(try execute(group, fixture: fixture) == ["p1", "p2"])

        var thisMonth = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addRelativeDate(.thisMonth, to: &thisMonth)
        let monthIds = try execute(thisMonth, fixture: fixture)
        #expect(monthIds.contains("p1"), "今天拍摄的必定在本月窗口内")
        #expect(!monthIds.contains("p3"), "40 天前不在本月窗口")
    }

    @Test func editorJSONRoundTripKeepsNestedNotShape() throws {
        let fixture = try makeFixture()
        var group = FilterGroup(logic: .and, conditions: [])
        FilterEditorModel.addRelativeDate(.last30, to: &group)
        FilterEditorModel.addNotGroup(
            to: &group,
            seed: FilterRule(field: "rating", operator: .eq, value: .number(5)))

        let data = try FilterEditorModel.encodeJSON(group)
        // 用类型化解码断言嵌套结构（legacy boundary 门禁：应用/测试都不用裸字典解析）。
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: data)
        #expect(decoded.logic == .and)
        #expect(decoded.conditions.count == 2)
        let lastCondition = try #require(decoded.conditions.last)
        guard case .group(let notGroup) = lastCondition else {
            Issue.record("最后一个条件应是 NOT 组")
            return
        }
        #expect(notGroup.logic == .not)
        let firstInner = try #require(notGroup.conditions.first)
        guard case .rule(let ratingRule) = firstInner else {
            Issue.record("NOT 组内应是 rating 规则")
            return
        }
        #expect(ratingRule.field == "rating")
        #expect(ratingRule.value == .number(5))

        // 解码后执行：最近 30 天 且 非五星 → p1/p2（p2 五星被 NOT 排除）。
        #expect(try execute(group, fixture: fixture) == ["p1"])
    }

    @Test func catalogCoversRestoreLeftoverFields() {
        // restore 会把未识别规则塞进 rules（GalleryViewModel+Filters.swift）；这些
        // 字段必须在目录里，否则高级编辑器呈现为空白且无法修复。
        for field in ["person", "volume", "directory", "has_duplicates", "has_face"] {
            #expect(FilterFieldCatalog.field(field) != nil, "缺字段 \(field)")
        }
        #expect(FilterFieldCatalog.operators(
            forField: "has_duplicates", kind: .boolean) == [.eq])
        #expect(FilterFieldCatalog.operators(
            forField: "has_face", kind: .boolean).contains(.neq))
        #expect(FilterFieldCatalog.operators(
            forField: "person", kind: .text).contains(.containsAny))
        // 未知字段返回 nil → 视图走"保留原条件 + 提示"的只读分支。
        #expect(FilterFieldCatalog.field("legacy_unknown_field") == nil)
    }

    @Test func removeConditionKeepsGroupConsistent() throws {
        var group = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "filename", operator: .contains, value: .string("a"))),
            .rule(FilterRule(field: "rating", operator: .eq, value: .number(3))),
        ])
        FilterEditorModel.removeCondition(at: 1, in: &group)
        #expect(group.conditions.count == 1)
        FilterEditorModel.removeCondition(at: 9, in: &group)
        #expect(group.conditions.count == 1, "越界删除是 no-op，不崩")
    }
}
