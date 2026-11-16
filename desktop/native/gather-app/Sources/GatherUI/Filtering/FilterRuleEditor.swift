// desktop/native/gather-app/Sources/GatherUI/Filtering/FilterRuleEditor.swift
// P1 / C：规则编辑器（AND/OR + Wave2 收尾 task-22：NOT 组 / 集合·堆栈成员 /
// 相对日期）。
//
// 契约：
// - 直接编辑 FilterGroup（不发明第二套筛选 DSL）：编辑器产出的就是
//   PhotoFilterQuery 吃的结构；保存智能相册/保存查询可原样回填；
// - 顶层的 AND/OR 由调用方决定（Library/Gallery 组合搜索串/四档/facet 后再进来）；
//   嵌套组只从本编辑器的快捷入口产生：NOT 组（子条件 OR 后整体取反）；
// - 集合/堆栈成员是 task-15 的服务端字段（FilterFields.collection/stack），
//   本轮 UI 是"手填 ID + 剪贴板粘贴"入口，帮助文案写清 ID 从哪来；
// - 相对日期（最近 7/30 天、本月）保存 token 而不是绝对日期，规则长期有效；
// - 快捷规则与结构化编辑都走 FilterEditorModel（纯函数），测试复用同一入口做
//   "UI 编辑 → JSON → PhotoFilterQuery 执行"的往返验证。
import AppKit
import SwiftUI
import GatherProtocol

/// 可编辑字段目录：名称 + 类型（决定可选操作符与输入控件）。
enum FilterFieldCatalog {
    enum Kind {
        case text
        case number
        case date
        case list
        /// 集合/堆栈成员（FilterFields.collection / stack）：值 = 容器 UUID。
        case membership
        /// 相对日期（FilterFields.relativeDate）：值 = RelativeDateRange.rawValue。
        case relativeDate
        /// 布尔字段（has_face/has_duplicates）：值 = JSON bool。
        case boolean
    }

    struct Field: Identifiable {
        let id: String
        let label: String
        let kind: Kind
    }

    /// 字段 id 与服务端 PhotoFilterQuery.jsonFields / 特殊分支的 key 必须逐字一致。
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
        .init(id: "person", label: "人物", kind: .text),
        .init(id: "has_face", label: "有人脸", kind: .boolean),
        .init(id: "has_duplicates", label: "有重复", kind: .boolean),
        .init(id: "directory", label: "目录路径前缀", kind: .text),
        .init(id: "volume", label: "存储卷", kind: .text),
        // 容器 / 相对日期（服务端特殊分支）
        .init(id: FilterFields.collection, label: "集合成员", kind: .membership),
        .init(id: FilterFields.stack, label: "堆栈成员", kind: .membership),
        .init(id: FilterFields.relativeDate, label: "相对日期", kind: .relativeDate),
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
        // Wave5（batch2）：IPTC Core Instructions（与 PhotoFilterQuery.jsonFields 同 id）。
        .init(id: "instructions", label: "使用说明", kind: .text),
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
        // Wave5（batch2）：Event Id（multi → 列表语义）。
        .init(id: "event_identifier", label: "事件标识", kind: .list),
        .init(id: "sublocation", label: "地点细节", kind: .text),
        .init(id: "world_region", label: "世界区域", kind: .text),
        .init(id: "province_state", label: "省/州（Ext）", kind: .text),
        .init(id: "model_release_status", label: "模特释放状态", kind: .text),
        // Wave5（batch2）：PLUS release id（multi → 列表语义）。
        .init(id: "model_release_id", label: "肖像权释放编号", kind: .list),
        .init(id: "property_release_status", label: "财产释放状态", kind: .text),
        .init(id: "property_release_id", label: "物权释放编号", kind: .list),
        .init(id: "digital_source_type", label: "数字来源类型", kind: .text),
        .init(id: "additional_model_info", label: "补充模特信息", kind: .text),
        // 关键词
        .init(id: "keywords", label: "关键词", kind: .list),
        .init(id: "keyword_path", label: "关键词层级", kind: .text),
    ]

    static func field(_ id: String) -> Field? { fields.first { $0.id == id } }

    static func operators(for kind: Kind) -> [FilterOperator] {
        switch kind {
        case .text: [.contains, .eq, .neq, .startsWith, .exists]
        case .list: [.containsAny, .containsAll, .exists]
        case .number, .date: [.eq, .gte, .lte, .between, .in]
        case .membership: [.eq, .neq, .in, .containsAny, .containsAll, .exists]
        case .relativeDate, .boolean: [.eq]
        }
    }

    /// 服务端特殊字段的操作符与通用 Kind 不完全一致（person 不是 JSON 列、
    /// directory 只支持前缀、has_face 支持 eq/neq）。按字段 id 覆盖，避免编辑器
    /// 给出服务端会拒绝的操作符。
    static func operators(forField field: String, kind: Kind) -> [FilterOperator] {
        switch field {
        case "person": [.eq, .neq, .contains, .containsAny, .in]
        case "has_face": [.eq, .neq]
        case "has_duplicates": [.eq]
        case "directory": [.startsWith, .eq]
        case "volume": [.eq]
        default: operators(for: kind)
        }
    }

    /// 切换字段类型时的初值（避免旧值形状与新类型冲突）。
    static func defaultValue(for kind: Kind) -> JSONValue {
        switch kind {
        case .number: .null
        case .list: .array([])
        case .membership: .string("")
        case .relativeDate: .string(RelativeDateRange.last7.rawValue)
        case .boolean: .bool(false)
        case .text, .date: .string("")
        }
    }
}

struct FilterRuleEditor: View {
    @Binding var group: FilterGroup
    let l10n: L10n
    /// 规则变化后立即提交（调用方负责防抖/刷新）。
    let onChange: () -> Void

    var body: some View {
        FilterGroupEditor(
            group: $group, l10n: l10n, onChange: onChange, depth: 0, onRemove: nil)
    }
}

/// 单组编辑器：顶层与嵌套 NOT 组共用（递归）。
private struct FilterGroupEditor: View {
    @Binding var group: FilterGroup
    let l10n: L10n
    let onChange: () -> Void
    let depth: Int
    /// 嵌套组由父级删除（子视图拿不到父数组索引）；顶层为 nil。
    let onRemove: (() -> Void)?

    private static let maxDepth = 2

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            header
            if group.conditions.isEmpty {
                Text(l10n("还没有条件"))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(group.conditions.enumerated()), id: \.offset) { index, condition in
                    switch condition {
                    case .rule(let rule):
                        ruleRow(index: index, rule: rule)
                    case .group(let nested):
                        nestedGroupRow(index: index, nested: nested)
                    }
                    if index < group.conditions.count - 1 {
                        Text(logicLabel)
                            .font(GatherFont.label)
                            .foregroundStyle(.secondary)
                            .padding(.leading, GatherMetrics.Space.xxs)
                    }
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            if group.logic == .not {
                Label(l10n("排除以下任一条件（NOT）"), systemImage: "nosign")
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.warningText)
            } else {
                Picker("", selection: logicBinding) {
                    Text(l10n("满足全部")).tag(FilterLogic.and)
                    Text(l10n("满足任一")).tag(FilterLogic.or)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            Spacer(minLength: 0)
            if depth == 0 {
                quickRulesMenu
            }
            Button(l10n("添加条件")) { appendRule() }
                .gatherButton(.tertiary, size: .small)
            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(l10n("删除这个 NOT 组"))
                .accessibilityLabel(l10n("删除这个 NOT 组"))
            }
        }
    }

    /// 快捷规则（只在顶层显示）：NOT 组、相对日期、集合/堆栈成员。
    private var quickRulesMenu: some View {
        Menu {
            Section {
                Button(l10n("添加 NOT 组（排除）")) {
                    if depth < Self.maxDepth {
                        FilterEditorModel.addNotGroup(to: &group)
                        onChange()
                    }
                }
                .disabled(depth >= Self.maxDepth)
            } header: {
                Text(l10n("逻辑取反"))
            }
            Section {
                Button(l10n("最近 7 天")) { addRelativeDate(.last7) }
                Button(l10n("最近 30 天")) { addRelativeDate(.last30) }
                Button(l10n("本月")) { addRelativeDate(.thisMonth) }
            } header: {
                Text(l10n("相对日期"))
            }
            Section {
                Button(l10n("属于集合…")) { addCollectionMembership() }
                Button(l10n("不属于集合…")) { addCollectionExclusion() }
                Button(l10n("属于堆栈…")) { addStackMembership() }
            } header: {
                Text(l10n("集合 / 堆栈"))
            }
        } label: {
            Label(l10n("快捷规则"), systemImage: "wand.and.stars")
                .font(GatherFont.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - 规则行

    @ViewBuilder
    private func ruleRow(index: Int, rule: FilterRule) -> some View {
        // P2（task-31 review）：保存查询/智能相册可能带当前目录不认识的字段
        //（person/volume/directory/has_duplicates…）。已知字段给编辑器；未知字段
        // 原样保留并提示，绝不在用户没动它时静默丢弃整条规则。
        if FilterFieldCatalog.field(rule.field) == nil {
            unknownRuleRow(index: index, rule: rule)
        } else {
            knownRuleRow(index: index, rule: rule)
        }
    }

    private func knownRuleRow(index: Int, rule: FilterRule) -> some View {
        let field = FilterFieldCatalog.field(rule.field)
        let kind = field?.kind ?? .text
        let operators = FilterFieldCatalog.operators(forField: rule.field, kind: kind)
        return VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            HStack(spacing: GatherMetrics.Space.controlGap) {
                Picker("", selection: fieldBinding(index: index, rule: rule)) {
                    ForEach(FilterFieldCatalog.fields) { item in
                        Text(l10n(item.label)).tag(item.id)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                Picker("", selection: operatorBinding(index: index, rule: rule, kind: kind, operators: operators)) {
                    ForEach(operators, id: \.rawValue) { op in
                        Text(operatorLabel(op)).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 96)

                valueEditor(index: index, rule: rule, kind: kind)

                removeButton(index: index)
            }
            if kind == .membership {
                membershipHelp(index: index, rule: rule)
            }
        }
    }

    private func unknownRuleRow(index: Int, rule: FilterRule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
            Image(systemName: "questionmark.circle")
                .font(GatherFont.label)
                .foregroundStyle(GatherTheme.warningText)
            VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                Text(l10n.format("未知筛选字段：%@", rule.field))
                    .font(GatherFont.label)
                Text(l10n("该条件来自保存查询/智能相册；编辑器原样保留，不会静默丢弃。删除后可重新添加。"))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            removeButton(index: index)
        }
    }

    private func removeButton(index: Int) -> some View {
        Button {
            FilterEditorModel.removeCondition(at: index, in: &group)
            onChange()
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(l10n("删除条件"))
        .accessibilityLabel(l10n("删除条件"))
    }

    @ViewBuilder
    private func valueEditor(index: Int, rule: FilterRule, kind: FilterFieldCatalog.Kind) -> some View {
        if kind == .boolean {
            Picker("", selection: boolBinding(index: index, rule: rule)) {
                Text(l10n("是")).tag(true)
                Text(l10n("否")).tag(false)
            }
            .labelsHidden()
            .frame(width: 88)
        } else if kind == .relativeDate {
            Picker("", selection: relativeDateBinding(index: index, rule: rule)) {
                Text(l10n("最近 7 天")).tag(RelativeDateRange.last7)
                Text(l10n("最近 30 天")).tag(RelativeDateRange.last30)
                Text(l10n("本月")).tag(RelativeDateRange.thisMonth)
            }
            .labelsHidden()
            .frame(width: 120)
        } else if kind == .membership {
            membershipValueEditor(index: index, rule: rule)
        } else {
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
                TextField(l10n("值，用逗号分隔"), text: inBinding(index: index, rule: rule))
                    .labelsHidden()
                    .frame(minWidth: 120)
            case .exists:
                Text(l10n("存在"))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
            default:
                TextField(l10n("值"), text: textBinding(index: index, rule: rule, kind: kind))
                    .labelsHidden()
                    .frame(minWidth: 110)
            }
        }
    }

    @ViewBuilder
    private func membershipValueEditor(index: Int, rule: FilterRule) -> some View {
        switch rule.operator {
        case .in, .containsAny, .containsAll:
            TextField(l10n("ID，用逗号分隔"), text: inBinding(index: index, rule: rule))
                .labelsHidden()
                .frame(minWidth: 140)
        case .exists:
            Text(l10n("属于任意容器"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
        default:
            TextField(l10n("集合/堆栈 UUID"), text: textBinding(index: index, rule: rule, kind: .membership))
                .labelsHidden()
                .frame(minWidth: 180)
        }
    }

    /// 集合/堆栈 ID 的来源帮助 + 剪贴板粘贴（本轮手填入口，下一波接选择器）。
    private func membershipHelp(index: Int, rule: FilterRule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
            Text(l10n("集合/堆栈 ID 是创建时生成的 UUID：可从保存查询/智能相册的 criteria JSON（collection/stack 规则的 value）复制；本轮为手填入口，粘贴可避免手打 UUID。"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(l10n("从剪贴板粘贴 ID")) {
                pasteMembershipID(index: index, rule: rule)
            }
            .gatherButton(.tertiary, size: .small)
            .disabled(NSPasteboard.general.string(forType: .string) == nil)
        }
    }

    // MARK: - 嵌套 NOT 组

    private func nestedGroupRow(index: Int, nested: FilterGroup) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Image(systemName: "arrow.turn.down.right")
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                Text(nested.logic == .not
                     ? l10n("排除（NOT）：以下条件先按“任一”组合再整体取反")
                     : l10n("子条件组"))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
            }
            FilterGroupEditor(
                group: nestedBinding(index: index),
                l10n: l10n,
                onChange: onChange,
                depth: depth + 1,
                onRemove: {
                    FilterEditorModel.removeCondition(at: index, in: &group)
                    onChange()
                })
                .padding(.leading, GatherMetrics.Space.m)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(GatherTheme.hairline)
                        .frame(width: 1)
                }
        }
    }

    private func nestedBinding(index: Int) -> Binding<FilterGroup> {
        Binding(
            get: {
                guard group.conditions.indices.contains(index),
                      case .group(let nested) = group.conditions[index] else {
                    return FilterGroup(logic: .and, conditions: [])
                }
                return nested
            },
            set: { newValue in
                guard group.conditions.indices.contains(index),
                      case .group = group.conditions[index] else { return }
                group.conditions[index] = .group(newValue)
                onChange()
            }
        )
    }

    // MARK: - 绑定

    private var logicLabel: String {
        group.logic == .and ? l10n("且") : l10n("或")
    }

    private var logicBinding: Binding<FilterLogic> {
        Binding(
            get: { group.logic },
            set: { value in
                FilterEditorModel.setLogic(value, in: &group)
                onChange()
            }
        )
    }

    private func fieldBinding(index: Int, rule: FilterRule) -> Binding<String> {
        Binding(
            get: { rule.field },
            set: { newField in
                guard let newKind = FilterFieldCatalog.field(newField)?.kind else { return }
                var updated = rule
                updated.field = newField
                let operators = FilterFieldCatalog.operators(
                    forField: newField, kind: newKind)
                if !operators.contains(updated.operator) {
                    updated.operator = operators[0]
                }
                updated.value = FilterFieldCatalog.defaultValue(for: newKind)
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
            }
        )
    }

    private func operatorBinding(
        index: Int, rule: FilterRule, kind: FilterFieldCatalog.Kind,
        operators: [FilterOperator]
    ) -> Binding<FilterOperator> {
        Binding(
            get: { rule.operator },
            set: { newOperator in
                var updated = rule
                updated.operator = newOperator
                switch newOperator {
                case .between:
                    updated.value = .array([.string(""), .string("")])
                case .in, .containsAny, .containsAll:
                    updated.value = .array([])
                default:
                    if kind == .relativeDate {
                        updated.value = .string(RelativeDateRange.last7.rawValue)
                    } else if kind == .membership {
                        updated.value = .string("")
                    }
                }
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
            }
        )
    }

    private func textBinding(
        index: Int, rule: FilterRule, kind: FilterFieldCatalog.Kind
    ) -> Binding<String> {
        Binding(
            get: {
                if kind == .relativeDate {
                    return rule.value.stringValue ?? RelativeDateRange.last7.rawValue
                }
                return rule.value.stringValue ?? ""
            },
            set: { text in
                var updated = rule
                switch kind {
                case .number:
                    updated.value = Double(text).map(JSONValue.number) ?? .null
                default:
                    updated.value = .string(text)
                }
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
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
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
            }
        )
    }

    private func inBinding(index: Int, rule: FilterRule) -> Binding<String> {
        Binding(
            get: {
                (rule.value.arrayElements ?? []).compactMap(\.stringValue)
                    .joined(separator: ",")
            },
            set: { text in
                let items = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                var updated = rule
                updated.value = .array(items.map(JSONValue.string))
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
            }
        )
    }

    private func boolBinding(index: Int, rule: FilterRule) -> Binding<Bool> {
        Binding(
            get: { rule.value.boolValue ?? false },
            set: { value in
                var updated = rule
                updated.value = .bool(value)
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
            }
        )
    }

    private func relativeDateBinding(index: Int, rule: FilterRule) -> Binding<RelativeDateRange> {
        Binding(
            get: {
                rule.value.stringValue.flatMap(RelativeDateRange.init(rawValue:)) ?? .last7
            },
            set: { range in
                var updated = rule
                updated.operator = .eq
                updated.value = .string(range.rawValue)
                FilterEditorModel.updateRule(updated, at: index, in: &group)
                onChange()
            }
        )
    }

    // MARK: - 快捷动作

    private func appendRule() {
        FilterEditorModel.addRule(
            FilterRule(field: "filename", operator: .contains, value: .string("")),
            to: &group)
        onChange()
    }

    private func addRelativeDate(_ range: RelativeDateRange) {
        FilterEditorModel.addRelativeDate(range, to: &group)
        onChange()
    }

    /// 快捷入口：先落一条空值成员规则，用户在该行内手填 ID（不会点击无反应）。
    private func addCollectionMembership() {
        FilterEditorModel.addRule(FilterRule.inCollection(""), to: &group)
        onChange()
    }

    private func addCollectionExclusion() {
        FilterEditorModel.addRule(FilterRule.notInCollection(""), to: &group)
        onChange()
    }

    private func addStackMembership() {
        FilterEditorModel.addRule(FilterRule.inStack(""), to: &group)
        onChange()
    }

    private func pasteMembershipID(index: Int, rule: FilterRule) {
        guard let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else { return }
        var updated = rule
        updated.value = .string(pasted)
        FilterEditorModel.updateRule(updated, at: index, in: &group)
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
