// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/FilterGroupPruningTests.swift
// P1 / C：facet 的前置能力——按字段剪枝条件树（同维多选取并集、跨维取交集的基础）。

import Foundation
import Testing
import GatherProtocol

@Suite("FilterGroup 剪枝")
struct FilterGroupPruningTests {
    private func rule(_ field: String, _ value: String) -> FilterCondition {
        .rule(FilterRule(field: field, operator: .contains, value: .string(value)))
    }

    @Test("剔除同字段规则，保留其它字段")
    func removesOnlyMatchingField() {
        let group = FilterGroup(logic: .and, conditions: [
            rule("camera_model", "X-T5"),
            rule("lens_model", "XF23"),
        ])
        let pruned = group.removing(field: "camera_model")
        #expect(pruned.conditions.count == 1)
        #expect(pruned.references(field: "camera_model") == false)
        #expect(pruned.references(field: "lens_model"))
    }

    @Test("AND 嵌套组递归剪枝，空组折叠掉")
    func prunesNestedAndCollapsesEmpty() {
        let nested = FilterGroup(logic: .and, conditions: [rule("camera_model", "A"), rule("lens_model", "B")])
        let group = FilterGroup(logic: .and, conditions: [
            .group(nested),
            rule("iso", "400"),
        ])
        let pruned = group.removing(field: "camera_model")
        #expect(pruned.references(field: "camera_model") == false)
        #expect(pruned.references(field: "lens_model"))
        #expect(pruned.references(field: "iso"))
    }

    @Test("OR 子树不剪同维条件：删分支会放宽语义，facet 会出现 0 张桶")
    func keepsSameFieldInsideOr() {
        let nested = FilterGroup(logic: .or, conditions: [rule("camera_model", "A"), rule("label", "Red")])
        let group = FilterGroup(logic: .and, conditions: [
            .group(nested),
            rule("iso", "400"),
        ])
        let pruned = group.removing(field: "camera_model")
        #expect(pruned.references(field: "camera_model"), "OR 内的相机条件必须保留")
        #expect(pruned.references(field: "label"))
    }

    @Test("references 能看穿嵌套；无关字段剪枝是恒等变换")
    func referencesAndNoop() {
        let group = FilterGroup(logic: .and, conditions: [
            .group(FilterGroup(logic: .or, conditions: [rule("label", "Red")])),
        ])
        #expect(group.references(field: "label"))
        #expect(group.references(field: "iso") == false)
        #expect(group.removing(field: "iso").conditions.count == 1)
    }
}
