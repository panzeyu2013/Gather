// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/filter.ts。
// FilterGroup 的 conditions 为 FilterRule | FilterGroup 递归判别联合。

import Foundation
import Testing
@testable import GatherProtocol

struct FilterContractTests {

    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并，含可选字段省略）

    @Test("Filter 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func filterDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(FilterRule(field: "rating", operator: .gte, value: .number(4)),
                            keys: ["field", "operator", "value"])
        try assertRoundTrip(FilterGroup(
            logic: .and,
            conditions: [
                .rule(FilterRule(field: "rating", operator: .gte, value: .number(4))),
                .rule(FilterRule(field: "pickState", operator: .eq, value: .string("picked"))),
            ]),
            keys: ["logic", "conditions"])
        try assertRoundTrip(AlbumCreateParams(
            name: "街头", criteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "taken_at", sortOrder: "asc", description: "d", icon: "📷"),
            keys: ["name", "criteria", "sortBy", "sortOrder", "description", "icon"])
        try assertRoundTrip(AlbumUpdateParams(albumId: "a1", name: "新名字",
                                              criteria: FilterGroup(logic: .and, conditions: [])),
                            keys: ["albumId", "name", "criteria"])
        try assertRoundTrip(FilterSuggestion(field: "keywords", values: ["街头", "夜景"]),
                            keys: ["field", "values"])
        try assertRoundTrip(GlobalPhotoResult(
            photoId: "p1", assetId: "a1", sessionId: "s1", sessionName: "2025 街头",
            sessionIds: ["s1"], sessionNames: ["2025 街头"],
            filename: "a.jpg", filepath: "/u/a.jpg", status: "indexed",
            rating: 4, label: "L", keywords: ["街头"]),
            keys: [
                "photoId", "assetId", "sessionId", "sessionName", "sessionIds", "sessionNames",
                "filename", "filepath", "status", "rating", "label", "keywords",
            ],
            forbiddenKeys: ["session_ids", "photo_id"])
        try assertRoundTrip(SmartAlbumData(
            id: "a1", schemaVersion: 1, name: "街头", description: "d",
            filterCriteria: FilterGroup(logic: .and, conditions: [
                .rule(FilterRule(field: "keywords", operator: .contains, value: .string("街头"))),
            ]),
            sortBy: "rating", sortOrder: "desc", icon: "📷",
            createdAt: "t", updatedAt: "t", validationError: "boom"),
            keys: [
                "id", "schemaVersion", "name", "description", "filterCriteria", "sortBy",
                "sortOrder", "icon", "createdAt", "updatedAt", "validationError",
            ],
            forbiddenKeys: ["schema_version", "filter_criteria"])
        let detailData = try assertRoundTrip(SmartAlbumDetailData(
            id: "a1", schemaVersion: 1, name: "n", description: "",
            filterCriteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "", sortOrder: "", icon: "", createdAt: "t", updatedAt: "t", photoCount: 42))
        // 原用例只断言 photoCount 键存在（未锁完整键集合），保留原断言强度。
        #expect(try jsonKeys(of: detailData).contains("photoCount"))
        // validationError? 未设置时省略 key。
        try assertJSONKeys(SmartAlbumData(
            id: "a1", schemaVersion: 1, name: "n", description: "",
            filterCriteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "", sortOrder: "", icon: "", createdAt: "t", updatedAt: "t"),
            name: "SmartAlbumData(nil validationError)", forbiddenKeys: ["validationError"])
    }

    @Test func filterRuleOperatorRawValuesMatchTS() {
        let cases: [(FilterOperator, String)] = [
            (.eq, "eq"), (.neq, "neq"), (.gte, "gte"), (.lte, "lte"),
            (.gt, "gt"), (.lt, "lt"), (.between, "between"),
            (.in, "in"), (.contains, "contains"),
            (.containsAny, "contains_any"), (.containsAll, "contains_all"),
            (.startsWith, "starts_with"), (.exists, "exists"),
        ]
        for (op, raw) in cases {
            #expect(op.rawValue == raw, "FilterOperator 必须与 TS 字符串一致")
        }
    }

    @Test func filterRuleValueRoundTripsJSONValues() throws {
        let rules = [
            FilterRule(field: "rating", operator: .eq, value: .number(4)),
            FilterRule(field: "keywords", operator: .containsAny, value: .array([.string("街头"), .string("夜景")])),
            FilterRule(field: "label", operator: .exists, value: .bool(true)),
            FilterRule(field: "notes", operator: .exists, value: .null),
            FilterRule(field: "meta", operator: .eq, value: .object(["x": .number(1)])),
            FilterRule(field: "title", operator: .eq, value: .string("t")),
        ]
        for rule in rules {
            let data = try JSONEncoder().encode(rule)
            #expect(try JSONDecoder().decode(FilterRule.self, from: data) == rule)
        }
    }

    @Test func filterGroupNestedConditionsRoundTrip() throws {
        let original = FilterGroup(
            logic: .or,
            conditions: [
                .rule(FilterRule(field: "rating", operator: .gte, value: .number(4))),
                .group(FilterGroup(
                    logic: .and,
                    conditions: [
                        .rule(FilterRule(field: "keywords", operator: .contains, value: .string("街头"))),
                        .rule(FilterRule(field: "rating", operator: .lt, value: .number(2))),
                    ]
                )),
            ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: data)
        #expect(decoded == original)
        if case .group(let nested) = decoded.conditions[1] {
            #expect(nested.logic == .and)
            #expect(nested.conditions.count == 2)
        } else {
            Issue.record("嵌套 FilterGroup 应解码为 .group")
        }
    }

    @Test func filterLogicRawValuesMatchTS() {
        #expect(FilterLogic.and.rawValue == "and")
        #expect(FilterLogic.or.rawValue == "or")
    }
}
