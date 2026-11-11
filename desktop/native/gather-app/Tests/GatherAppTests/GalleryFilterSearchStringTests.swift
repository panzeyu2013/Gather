// desktop/native/gather-app/Tests/GatherAppTests/GalleryFilterSearchStringTests.swift
// D4：保存查询恢复时，把 searchCriteria 组还原成搜索框里的搜索词。
//
// 为什么必须成对测：searchCriteria 产出五字段 OR（filename/title/description/
// keywords/keyword_path），而 searchString 靠一份独立的字段集合判定"这是一个搜索组"。
// 旧 searchString 只认"每条规则都是 filename contains"，于是恢复保存查询后搜索框
// 恒为空（再点保存，新查询就把原搜索词丢了）。这组用例把"生成"与"识别"两侧锁在
// 一起：任何一侧改了字段集，往返用例先红。

import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

/// 构造"某字段 contains 某值"的条件（本文件所有用例共用，省掉五行样板）。
private func searchRule(_ field: String, _ value: String) -> FilterCondition {
    .rule(FilterRule(field: field, operator: .contains, value: .string(value)))
}

@Suite("Gallery 保存查询：搜索词还原（D4）")
@MainActor
struct GalleryFilterSearchStringTests {
    /// searchCriteria 用到的字段名（写死而不是引用生产私有集合：用例守的是
    /// **契约**——搜索组认哪些字段；生产侧那份 private 常量是实现细节）。
    /// Wave2 / task-13：检索面从 5 字段扩到 17 字段（IPTC 描述性字段全集）。
    private static let searchFields = [
        "filename", "title", "description", "headline", "creator",
        "copyright", "credit", "source", "usage_terms",
        "instructions", "event_identifier", "model_release_id", "property_release_id",
        "city", "state", "country", "event", "sublocation", "person_in_image",
        FilterFields.keywords, FilterFields.keywordPath,
    ]

    @Test("searchCriteria 生成的五字段 OR 组能还原出原搜索词")
    func roundTripsSearchCriteria() {
        let group = GalleryViewModel.searchCriteria("日落")
        // 五个字段一个不多一个不少（顺序 = searchCriteria 的声明顺序）。
        let fields = group.conditions.compactMap { condition -> String? in
            guard case .rule(let rule) = condition else { return nil }
            return rule.field
        }
        #expect(group.logic == .or)
        #expect(group.conditions.count == Self.searchFields.count)
        #expect(fields == Self.searchFields)
        #expect(GalleryViewModel.searchString(in: group) == "日落")
    }

    @Test("五个字段各取不同值 → 不是同一个搜索词，返回 nil")
    func distinctValuesReturnNil() {
        let group = FilterGroup(logic: .or, conditions: [
            searchRule("filename", "a"),
            searchRule("title", "b"),
            searchRule("description", "c"),
            searchRule(FilterFields.keywords, "d"),
            searchRule(FilterFields.keywordPath, "e"),
        ])
        #expect(group.conditions.count == 5)
        #expect(GalleryViewModel.searchString(in: group) == nil)
        // 同样的五字段、同一个值 → 才认（证明 nil 来自"值不同"，不是"字段不认识"）。
        let sameValue = FilterGroup(logic: .or, conditions: [
            searchRule("filename", "x"),
            searchRule("title", "x"),
            searchRule("description", "x"),
            searchRule(FilterFields.keywords, "x"),
            searchRule(FilterFields.keywordPath, "x"),
        ])
        #expect(GalleryViewModel.searchString(in: sameValue) == "x")
    }

    @Test("算子不是 contains（eq / starts_with / contains_any）→ nil")
    func nonContainsOperatorsReturnNil() {
        for op in [FilterOperator.eq, .startsWith, .containsAny, .containsAll] {
            let group = FilterGroup(logic: .or, conditions: [
                .rule(FilterRule(field: "filename", operator: op, value: .string("日落"))),
            ])
            #expect(
                GalleryViewModel.searchString(in: group) == nil,
                "算子 \(op.rawValue) 不该被还原成搜索词")
        }
    }

    @Test("单条 filename contains → 该值")
    func singleFilenameRuleReturnsValue() {
        let orGroup = FilterGroup(logic: .or, conditions: [searchRule("filename", "日落")])
        let value = GalleryViewModel.searchString(in: orGroup)
        #expect(value == "日落")
        #expect(value?.isEmpty == false)
        // 同样的单条规则但顶层是 AND：不是"任意命中"的搜索组，不能还原。
        let andGroup = FilterGroup(logic: .and, conditions: [searchRule("filename", "日落")])
        #expect(GalleryViewModel.searchString(in: andGroup) == nil)
    }

    @Test("非搜索组的形状（空组 / 未知字段 / 空值 / 嵌套组）→ nil")
    func nonSearchShapesReturnNil() {
        let emptyOr = FilterGroup(logic: .or, conditions: [])
        let emptyAnd = FilterGroup(logic: .and, conditions: [])
        // 未知识别字段（facet 规则等）：整组落回规则编辑器，不得吞成搜索词。
        let unknownField = FilterGroup(logic: .or, conditions: [
            .rule(FilterRule(
                field: FilterFields.cameraModel, operator: .contains, value: .string("X2D"))),
        ])
        // 空搜索词没有意义（searchCriteria 只对非空 search 调用）。
        let emptyValue = FilterGroup(logic: .or, conditions: [searchRule("filename", "")])
        // 嵌套组不是 .rule：宁可多一行规则，也不丢语义。
        let nested = FilterGroup(logic: .or, conditions: [
            .group(FilterGroup(logic: .or, conditions: [searchRule("filename", "日落")])),
        ])

        #expect(GalleryViewModel.searchString(in: emptyOr) == nil)
        #expect(GalleryViewModel.searchString(in: emptyAnd) == nil)
        #expect(GalleryViewModel.searchString(in: unknownField) == nil)
        #expect(GalleryViewModel.searchString(in: emptyValue) == nil)
        #expect(GalleryViewModel.searchString(in: nested) == nil)
    }
}

// MARK: - Wave5 batch4：Gallery person facet（50-ai-similarity §2 P1-6）

/// 最小 Gallery 数据源替身：person facet 测试不触网/不建库。
private struct PersonFacetGalleryProviderStub: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? { nil }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }
}

@Suite("Gallery person facet（Wave5 batch4）")
@MainActor
struct GalleryPersonFacetTests {
    private func makeViewModel() -> GalleryViewModel {
        GalleryViewModel(
            sessionId: "s1",
            provider: PersonFacetGalleryProviderStub(),
            job: B5bJobAPIStub(),
            debounceDelay: .milliseconds(1))
    }

    @Test("请求维度包含 person（服务端 FacetQuery.personBuckets 供数）")
    func personDimensionRequested() {
        #expect(GalleryViewModel.facetDimensions.contains("person"))
    }

    @Test("选中 person facet → person eq 规则（精确匹配，不是 contains）")
    func personFacetBuildsExactRule() throws {
        let viewModel = makeViewModel()
        viewModel.selectFacet(dimension: "person", value: "Ann")

        let criteria = try #require(viewModel.activeCriteria)
        let rule = criteria.conditions.compactMap { condition -> FilterRule? in
            guard case .rule(let rule) = condition else { return nil }
            return rule
        }.first { $0.field == "person" }
        #expect(rule?.operator.rawValue == "eq")
        #expect(rule?.value.stringValue == "Ann")
    }

    @Test("保存查询恢复：person eq 规则还原成 person facet 选中态")
    func savedSearchRestoresPersonFacet() {
        let viewModel = makeViewModel()
        viewModel.restore(criteria: FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "person", operator: .eq, value: .string("Ann"))),
        ]))
        #expect(viewModel.facetSelection["person"] == "Ann")
    }

    @Test("清除 person facet：选中态与条件同时清空")
    func clearPersonFacet() {
        let viewModel = makeViewModel()
        viewModel.selectFacet(dimension: "person", value: "Ann")
        viewModel.selectFacet(dimension: "person", value: "")
        #expect(viewModel.facetSelection["person"] == "")
        #expect(viewModel.activeCriteria == nil)
    }
}
