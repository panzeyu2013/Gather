// desktop/native/gather-app/Sources/GatherUI/Filtering/FilterEditorModel.swift
// Wave2 收尾 task-22：规则编辑器的纯逻辑入口（快捷规则/JSON 往返/测试共用）。
//
// 为什么单独一个文件：SwiftUI 视图里的编辑动作无法直接进测试；本类型把
// "编辑器加了什么规则"收敛成纯函数，UI 与 GatherAppTests 走**同一个入口**，
// 测试再把产出 JSON 解码回去交给 PhotoFilterQuery 执行，验证
// "UI 编辑 → JSON → 服务端执行" 三者一致。
import Foundation
import GatherProtocol

enum FilterEditorModel {
    // MARK: - 快捷规则（编辑器 Menu）

    static func addRule(_ rule: FilterRule, to group: inout FilterGroup) {
        group.conditions.append(.rule(rule))
    }

    /// NOT 组：组内子条件先 OR 再整体取反（与 FilterLogic.not 的 SQL 语义一致）。
    static func addNotGroup(
        to group: inout FilterGroup,
        seed: FilterRule = FilterRule(
            field: "filename", operator: .contains, value: .string(""))
    ) {
        group.conditions.append(.group(FilterGroup(logic: .not, conditions: [.rule(seed)])))
    }

    static func addRelativeDate(_ range: RelativeDateRange, to group: inout FilterGroup) {
        group.conditions.append(.rule(FilterRule.relativeDate(range)))
    }

    static func addCollectionMembership(
        ids: [String], anyOf: Bool, to group: inout FilterGroup
    ) {
        let cleaned = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = cleaned.first else { return }
        if cleaned.count == 1 {
            addRule(.inCollection(first), to: &group)
        } else if anyOf {
            addRule(.collectionMembership(anyOf: cleaned), to: &group)
        } else {
            addRule(.collectionMembership(allOf: cleaned), to: &group)
        }
    }

    static func addCollectionExclusion(id: String, to group: inout FilterGroup) {
        let cleaned = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        addRule(.notInCollection(cleaned), to: &group)
    }

    static func addStackMembership(id: String, to group: inout FilterGroup) {
        let cleaned = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        addRule(.inStack(cleaned), to: &group)
    }

    // MARK: - 结构化编辑（视图绑定共用）

    static func setLogic(_ logic: FilterLogic, in group: inout FilterGroup) {
        group.logic = logic
    }

    static func removeCondition(at index: Int, in group: inout FilterGroup) {
        guard group.conditions.indices.contains(index) else { return }
        group.conditions.remove(at: index)
    }

    static func updateRule(_ rule: FilterRule, at index: Int, in group: inout FilterGroup) {
        guard group.conditions.indices.contains(index) else { return }
        group.conditions[index] = .rule(rule)
    }

    // MARK: - JSON 往返（与保存查询/智能相册同一编码）

    static func encodeJSON(_ group: FilterGroup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(group)
    }

    static func decodeJSON(_ data: Data) throws -> FilterGroup {
        try JSONDecoder().decode(FilterGroup.self, from: data)
    }

    /// 规则数量（区分嵌套组的横幅提示用）。
    static func ruleCount(in group: FilterGroup) -> Int {
        group.conditions.reduce(0) { count, condition in
            switch condition {
            case .rule: return count + 1
            case .group(let nested): return count + ruleCount(in: nested)
            }
        }
    }
}
