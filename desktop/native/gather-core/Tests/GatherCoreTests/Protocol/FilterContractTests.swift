// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/filter.ts。
// FilterGroup 的 conditions 为 FilterRule | FilterGroup 递归判别联合。

import Foundation
import Testing
@testable import GatherCore

struct FilterContractTests {

    // MARK: - FilterRule / FilterGroup（递归判别联合）

    @Test func filterRuleRoundTripAndKeys() throws {
        let original = FilterRule(field: "rating", operator: .gte, value: .number(4))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FilterRule.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["field", "operator", "value"])
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

    @Test func filterGroupRoundTripWithRules() throws {
        let original = FilterGroup(
            logic: .and,
            conditions: [
                .rule(FilterRule(field: "rating", operator: .gte, value: .number(4))),
                .rule(FilterRule(field: "pickState", operator: .eq, value: .string("picked"))),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: data)
        #expect(decoded == original)
        #expect(Set(try jsonKeys(of: data)) == ["logic", "conditions"])
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
            ]
        )

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

    // MARK: - Params

    @Test func filterPhotosParamsRoundTrip() throws {
        let params = FilterPhotosParams(
            sessionId: "s1",
            criteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "rating",
            sortOrder: "desc"
        )
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(FilterPhotosParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "criteria", "sortBy", "sortOrder"])
    }

    @Test func filterPhotosGlobalParamsOptionality() throws {
        let full = FilterPhotosGlobalParams(
            criteria: FilterGroup(logic: .or, conditions: []),
            sessionId: "s1", limit: 50, offset: 0
        )
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(full))) == ["criteria", "sessionId", "limit", "offset"])

        let minimal = FilterPhotosGlobalParams(criteria: FilterGroup(logic: .or, conditions: []))
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimal))) == ["criteria"])
    }

    @Test func filterSuggestParamsRoundTrip() throws {
        let params = FilterSuggestParams(sessionId: "s1", keyword: "街")
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(FilterSuggestParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "keyword"])
    }

    // MARK: - Album params

    @Test func albumCreateParamsRoundTrip() throws {
        let params = AlbumCreateParams(
            name: "街头",
            criteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "taken_at", sortOrder: "asc",
            description: "d", icon: "📷"
        )
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(AlbumCreateParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["name", "criteria", "sortBy", "sortOrder", "description", "icon"])
    }

    @Test func albumListParamsEncodesEmptyObject() throws {
        let data = try JSONEncoder().encode(AlbumListParams())
        #expect(try jsonKeys(of: data).isEmpty, "AlbumListParams 必须编码为 {}")
        #expect(try JSONDecoder().decode(AlbumListParams.self, from: data) == AlbumListParams())
    }

    @Test func albumGetUpdateDeleteParamsRoundTrip() throws {
        let get = AlbumGetParams(albumId: "a1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(get))) == ["albumId"])

        let update = AlbumUpdateParams(albumId: "a1", name: "新名字", criteria: FilterGroup(logic: .and, conditions: []))
        let updateData = try JSONEncoder().encode(update)
        #expect(try JSONDecoder().decode(AlbumUpdateParams.self, from: updateData) == update)
        #expect(Set(try jsonKeys(of: updateData)) == ["albumId", "name", "criteria"])

        let delete = AlbumDeleteParams(albumId: "a1", confirmed: true)
        #expect(try JSONDecoder().decode(AlbumDeleteParams.self, from: JSONEncoder().encode(delete)) == delete)

        let photos = AlbumGetPhotosParams(albumId: "a1", limit: 20, offset: 0)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(photos))) == ["albumId", "limit", "offset"])
    }

    // MARK: - FilterSuggestion

    @Test func filterSuggestionRoundTrip() throws {
        let suggestion = FilterSuggestion(field: "keywords", values: ["街头", "夜景"])
        let data = try JSONEncoder().encode(suggestion)
        #expect(try JSONDecoder().decode(FilterSuggestion.self, from: data) == suggestion)
        #expect(Set(try jsonKeys(of: data)) == ["field", "values"])
    }

    // MARK: - GlobalPhotoResult

    @Test func globalPhotoResultRoundTripAndKeys() throws {
        let original = GlobalPhotoResult(
            photoId: "p1", assetId: "a1", sessionId: "s1", sessionName: "2025 街头",
            sessionIds: ["s1"], sessionNames: ["2025 街头"],
            filename: "a.jpg", filepath: "/u/a.jpg", status: "indexed",
            rating: 4, label: "L", keywords: ["街头"]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(GlobalPhotoResult.self, from: data) == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "photoId", "assetId", "sessionId", "sessionName", "sessionIds", "sessionNames",
            "filename", "filepath", "status", "rating", "label", "keywords",
        ]
        #expect(Set(keys) == Set(expected))
        #expect(!keys.contains("session_ids"))
        #expect(!keys.contains("photo_id"))
    }

    // MARK: - SmartAlbumData / SmartAlbumDetailData

    @Test func smartAlbumDataRoundTripAndKeys() throws {
        let original = SmartAlbumData(
            id: "a1", schemaVersion: 1, name: "街头", description: "d",
            filterCriteria: FilterGroup(logic: .and, conditions: [
                .rule(FilterRule(field: "keywords", operator: .contains, value: .string("街头"))),
            ]),
            sortBy: "rating", sortOrder: "desc", icon: "📷",
            createdAt: "t", updatedAt: "t", validationError: "boom"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SmartAlbumData.self, from: data) == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "id", "schemaVersion", "name", "description", "filterCriteria", "sortBy",
            "sortOrder", "icon", "createdAt", "updatedAt", "validationError",
        ]
        #expect(Set(keys) == Set(expected))
        #expect(!keys.contains("schema_version"))
        #expect(!keys.contains("filter_criteria"))
    }

    @Test func smartAlbumDataValidationErrorOmittedWhenNil() throws {
        let album = SmartAlbumData(
            id: "a1", schemaVersion: 1, name: "n", description: "",
            filterCriteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "", sortOrder: "", icon: "", createdAt: "t", updatedAt: "t"
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(album))
        #expect(!keys.contains("validationError"))
    }

    @Test func smartAlbumDetailDataRoundTrip() throws {
        let original = SmartAlbumDetailData(
            id: "a1", schemaVersion: 1, name: "n", description: "",
            filterCriteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "", sortOrder: "", icon: "",
            createdAt: "t", updatedAt: "t",
            photoCount: 42
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SmartAlbumDetailData.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)).contains("photoCount"))
    }

    // MARK: - helpers

    private func jsonKeys(of data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractTestError.invalidJSON
        }
        return Array(object.keys)
    }

    private enum ContractTestError: Error {
        case invalidJSON
    }
}
