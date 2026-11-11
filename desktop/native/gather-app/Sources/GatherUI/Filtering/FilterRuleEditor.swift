// desktop/native/gather-app/Sources/GatherUI/Filtering/FilterRuleEditor.swift
// P1 / C：规则编辑器（AND/OR + between/in）。
//
// 直接编辑 FilterGroup（不发明第二套筛选 DSL）：编辑器产出的就是引擎吃的结构，
// 保存智能相册 / 保存查询时也能原样回填。
//
// P1 下一波 §3.7.2：从 Library/ 移到共享的 Filtering/（Library 与 Gallery 共用同一份），
// 类型名与调用点签名逐字未变（同模块移动），因此 Library 的调用点无需修改。
import SwiftUI
import GatherProtocol

/// 可编辑字段目录：名称 + 类型（决定可选操作符与输入控件）。
enum FilterFieldCatalog {
    enum Kind { case text, number, date, list }

    struct Field: Identifiable {
        let id: String
        let label: String
        let kind: Kind
    }

    /// 字段 id 与服务端 PhotoFilterQuery.jsonFields 的 key 必须逐字一致
    /// （Wave2 task-13 起扩到描述性字段全集；PhotoFilterSearchFieldsTests 守两条
    /// 集合相等，新增字段漏改任意一边都会红）。
    static let fields: [Field] = [
        // 文件 / 挑选
        .init(id: "filename", label: "文件名", kind: .text),
        .init(id: "rating", label: "星级", kind: .number),
        .init(id: "label", label: "色标", kind: .text),
        .init(id: "camera_model", label: "相机", kind: .text),
        .init(id: "lens_model", label: "镜头", kind: .text),
        .init(id: "iso", label: "ISO", kind: .number),
        .init(id: "date_taken", label: "拍摄日期", kind: .date),
        .init(id: "created_at", label: "导入时间", kind: .date),
        // IPTC Core
        .init(id: "title", label: "标题", kind: .text),
        .init(id: "description", label: "说明", kind: .text),
        .init(id: "headline", label: "标题（Headline）", kind: .text),
        .init(id: "creator", label: "作者", kind: .list),
        .init(id: "creator_job_title", label: "作者职位", kind: .text),
        .init(id: "credit", label: "提供者（Credit）", kind: .text),
        .init(id: "source", label: "来源（Source）", kind: .text),
        .init(id: "copyright", label: "版权", kind: .text),
        .init(id: "usage_terms", label: "使用条款", kind: .text),
        .init(id: "web_statement", label: "权利声明网址", kind: .text),
        .init(id: "job_identifier", label: "任务标识", kind: .text),
        .init(id: "caption_writer", label: "说明撰写者", kind: .text),
        .init(id: "subject_code", label: "主题代码", kind: .list),
        .init(id: "scene", label: "场景", kind: .list),
        .init(id: "intellectual_genre", label: "类别（Genre）", kind: .text),
        .init(id: "date_created", label: "创作日期", kind: .date),
        .init(id: "location", label: "地点", kind: .text),
        .init(id: "city", label: "城市", kind: .text),
        .init(id: "state", label: "省/州", kind: .text),
        .init(id: "country", label: "国家/地区", kind: .text),
        .init(id: "country_code", label: "国家代码", kind: .text),
        // IPTC Extension
        .init(id: "person_in_image", label: "画面人物", kind: .list),
        .init(id: "organisation_in_image", label: "画面机构", kind: .list),
        .init(id: "event", label: "事件", kind: .text),
        .init(id: "sublocation", label: "地点细节", kind: .text),
        .init(id: "world_region", label: "世界区域", kind: .text),
        .init(id: "province_state", label: "省/州（Ext）", kind: .text),
        .init(id: "model_release_status", label: "模特释放状态", kind: .text),
        .init(id: "property_release_status", label: "财产释放状态", kind: .text),
        .init(id: "digital_source_type", label: "数字来源类型", kind: .text),
        .init(id: "additional_model_info", label: "补充模特信息", kind: .text),
        // 关键词
        .init(id: "keywords", label: "关键词", kind: .list),
        // P1 下一波 §3.6.4：层级关键词路径（photo_keywords）。
        // starts_with = 命中该节点及其子孙（facet 下钻等价规则）。
        .init(id: "keyword_path", label: "关键词层级", kind: .text),
    ]

    static func field(_ id: String) -> Field? { fields.first { $0.id == id } }

    static func operators(for kind: Kind) -> [FilterOperator] {
        switch kind {
        case .text: [.contains, .eq, .neq, .startsWith, .exists]
        case .list: [.containsAny, .containsAll, .exists]
        case .number, .date: [.eq, .gte, .lte, .between, .in]
        }
    }
}

struct FilterRuleEditor: View {
    @Binding var group: FilterGroup
    let l10n: L10n
    /// 规则变化后立即提交（调用方负责防抖/刷新）。
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            HStack(spacing: GatherMetrics.Space.s) {
                Picker("", selection: logicBinding) {
                    Text(l10n("满足全部")).tag(FilterLogic.and)
                    Text(l10n("满足任一")).tag(FilterLogic.or)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                Spacer(minLength: 0)
                Button(l10n("添加条件")) { appendRule() }
                    .gatherButton(.tertiary, size: .small)
            }

            if group.conditions.isEmpty {
                Text(l10n("还没有条件"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(group.conditions.enumerated()), id: \.offset) { index, condition in
                    if case .rule(let rule) = condition {
                        ruleRow(index: index, rule: rule)
                        if index < group.conditions.count - 1 {
                            Text(logicLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, GatherMetrics.Space.xxs)
                        }
                    }
                }
            }
        }
    }

    private var logicLabel: String {
        group.logic == .and ? l10n("且") : l10n("或")
    }

    private var logicBinding: Binding<FilterLogic> {
        Binding(
            get: { group.logic },
            set: { value in
                group.logic = value
                onChange()
            }
        )
    }

    private func ruleRow(index: Int, rule: FilterRule) -> some View {
        let field = FilterFieldCatalog.field(rule.field)
        let kind = field?.kind ?? .text
        let operators = FilterFieldCatalog.operators(for: kind)
        return HStack(spacing: GatherMetrics.Space.controlGap) {
            Picker("", selection: fieldBinding(index: index, rule: rule)) {
                ForEach(FilterFieldCatalog.fields) { item in
                    Text(l10n(item.label)).tag(item.id)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Picker("", selection: operatorBinding(index: index, rule: rule, operators: operators)) {
                ForEach(operators, id: \.rawValue) { op in
                    Text(operatorLabel(op)).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 96)

            valueEditor(index: index, rule: rule, kind: kind)

            Button {
                group.conditions.remove(at: index)
                onChange()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(l10n("删除条件"))
        }
    }

    @ViewBuilder
    private func valueEditor(index: Int, rule: FilterRule, kind: FilterFieldCatalog.Kind) -> some View {
        switch rule.operator {
        case .between:
            HStack(spacing: GatherMetrics.Space.xs) {
                TextField(l10n("下限"), text: betweenBinding(index: index, rule: rule, second: false))
                    .labelsHidden()
                    .frame(width: 70)
                Text("–").foregroundStyle(.secondary)
                TextField(l10n("上限"), text: betweenBinding(index: index, rule: rule, second: true))
                    .labelsHidden()
                    .frame(width: 70)
            }
        case .in:
            // 逗号分隔的枚举值；空项被忽略。
            TextField(l10n("值，用逗号分隔"), text: inBinding(index: index, rule: rule))
                .labelsHidden()
                .frame(minWidth: 120)
        case .exists:
            Text(l10n("存在"))
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            TextField(l10n("值"), text: textBinding(index: index, rule: rule, kind: kind))
                .labelsHidden()
                .frame(minWidth: 110)
        }
    }

    // MARK: - 绑定

    private func fieldBinding(index: Int, rule: FilterRule) -> Binding<String> {
        Binding(
            get: { rule.field },
            set: { newField in
                guard let newKind = FilterFieldCatalog.field(newField)?.kind else { return }
                var updated = rule
                updated.field = newField
                // 字段类型变了，旧操作符可能非法：回退到该类型的第一个操作符。
                if !FilterFieldCatalog.operators(for: newKind).contains(updated.operator) {
                    updated.operator = FilterFieldCatalog.operators(for: newKind)[0]
                    updated.value = .string("")
                }
                update(index: index, rule: updated)
            }
        )
    }

    private func operatorBinding(index: Int, rule: FilterRule, operators: [FilterOperator]) -> Binding<FilterOperator> {
        Binding(
            get: { rule.operator },
            set: { newOperator in
                var updated = rule
                updated.operator = newOperator
                if newOperator == .between {
                    updated.value = .array([.string(""), .string("")])
                } else if newOperator == .in {
                    updated.value = .array([])
                }
                update(index: index, rule: updated)
            }
        )
    }

    private func textBinding(index: Int, rule: FilterRule, kind: FilterFieldCatalog.Kind) -> Binding<String> {
        Binding(
            get: { rule.value.stringValue ?? "" },
            set: { text in
                var updated = rule
                switch kind {
                case .number: updated.value = Double(text).map(JSONValue.number) ?? .null
                default: updated.value = .string(text)
                }
                update(index: index, rule: updated)
            }
        )
    }

    private func betweenBinding(index: Int, rule: FilterRule, second: Bool) -> Binding<String> {
        Binding(
            get: {
                let array = rule.value.arrayElements ?? []
                let target = second ? 1 : 0
                guard array.count > target else { return "" }
                return array[target].stringValue ?? array[target].numberValue.map { String($0) } ?? ""
            },
            set: { text in
                var array = rule.value.arrayElements ?? [.string(""), .string("")]
                while array.count < 2 { array.append(.string("")) }
                array[second ? 1 : 0] = .string(text)
                var updated = rule
                updated.value = .array(array)
                update(index: index, rule: updated)
            }
        )
    }

    private func inBinding(index: Int, rule: FilterRule) -> Binding<String> {
        Binding(
            get: { (rule.value.arrayElements ?? []).compactMap(\.stringValue).joined(separator: ",") },
            set: { text in
                let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                var updated = rule
                updated.value = .array(items.map(JSONValue.string))
                update(index: index, rule: updated)
            }
        )
    }

    private func update(index: Int, rule: FilterRule) {
        guard index < group.conditions.count else { return }
        group.conditions[index] = .rule(rule)
        onChange()
    }

    private func appendRule() {
        group.conditions.append(.rule(FilterRule(field: "filename", operator: .contains, value: .string(""))))
        onChange()
    }

    private func operatorLabel(_ op: FilterOperator) -> String {
        switch op {
        case .eq: l10n("等于")
        case .neq: l10n("不等于")
        case .gt: l10n("大于")
        case .lt: l10n("小于")
        case .gte: l10n("不小于")
        case .lte: l10n("不大于")
        case .between: l10n("介于")
        case .in: l10n("属于")
        case .contains: l10n("包含")
        case .containsAny: l10n("含任一")
        case .containsAll: l10n("含全部")
        case .startsWith: l10n("开头是")
        case .exists: l10n("存在")
        }
    }
}
