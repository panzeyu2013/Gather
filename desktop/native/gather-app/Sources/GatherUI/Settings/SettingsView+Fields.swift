// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView+Fields.swift
// Cut 4 / 4c-2d：分组字段行（文本/数字/下拉）与保存语义（离开输入框或回车提交），
// 原 SettingsView.swift 1822-1928 行。纯搬移：两处 focusedFieldKey.onChange 原样保留，
// 仍作用在同一 FocusState 上（不新增视图身份、不改变提交时机）。
import SwiftUI
import GatherProtocol

extension SettingsView {

    // MARK: 分组设置（缓存 / 图片处理 / 数据库 / C1 集成 / 元数据）

    @ViewBuilder
    func settingsSection(_ group: SettingGroup) -> some View {
        Section(l10n(group.titleZh)) {
            ForEach(group.fields) { field in
                fieldRow(field)
            }
        }
    }

    /// 标签列：标题 + 次要说明（说明在标签下方，不再把控件推到窗口最右）。
    func settingLabel(_ title: String, description: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(l10n(title))
            if let description, !description.isEmpty {
                Text(l10n(description))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 回车提交：先结束焦点（触发同一套失焦提交逻辑），再显式保存一次——
    /// 空值/越界等非法输入仍由 saveField 给出错误并保留编辑值。
    private func commitFieldOnSubmit(_ field: SettingField) {
        focusedFieldKey = nil
        viewModel.saveField(field, with: l10n)
    }

    /// 模型路径的回车提交（与普通字段同一套语义，N06）。
    func commitModelPath(key: String) {
        focusedFieldKey = nil
        viewModel.saveModelPath(key: key, with: l10n)
    }

    private func fieldBinding(_ field: SettingField) -> Binding<String> {
        Binding(
            get: { viewModel.edits[field.key] ?? viewModel.values[field.key] ?? "" },
            set: { viewModel.edits[field.key] = $0 }
        )
    }

    @ViewBuilder
    func fieldRow(_ field: SettingField) -> some View {
        let isPathField = field.key.contains("dir") || field.key.contains("path")
        LabeledContent {
            switch field.type {
            case .text:
                HStack(spacing: 6) {
                    TextField("", text: fieldBinding(field))
                        .font(isPathField ? .body.monospaced() : .body)
                        .focused($focusedFieldKey, equals: field.key)
                        .onSubmit { commitFieldOnSubmit(field) }
                        // F11：失焦即提交。旧实现只在回车时保存，用户 Tab 走开时
                        // 输入看起来已经生效、实际没写库（而下拉选择立即保存）——
                        // 同一屏两套保存语义。
                        .onChange(of: focusedFieldKey) { previous, current in
                            if previous == field.key, current != field.key {
                                viewModel.saveField(field, with: l10n)
                            }
                        }
                        .frame(minWidth: 160, maxWidth: isPathField ? 280 : 220)
                    if isPathField {
                        Button(l10n("选择…")) { pickingField = field }
                    }
                }
            case .number:
                TextField("", text: fieldBinding(field))
                    .multilineTextAlignment(.trailing)
                    .focused($focusedFieldKey, equals: field.key)
                    .onSubmit { commitFieldOnSubmit(field) }
                    .onChange(of: focusedFieldKey) { previous, current in
                        if previous == field.key, current != field.key {
                            viewModel.saveField(field, with: l10n)
                        }
                    }
                    .frame(width: 110)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(GatherTheme.surfaceMuted)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(GatherTheme.hairline, lineWidth: 1)
                    )
            case .select(let options):
                // 对齐旧版 Settings/index.tsx:623：select 带 disabled 的
                // 「请选择」占位 option（value=""，映射 nil）。当前值缺失/未知
                // 时展示占位；占位不可重新选中（set(nil) 不落库），对齐旧版
                // disabled 语义，避免静默回退到第一个选项。
                Picker("", selection: Binding<String?>(
                    get: {
                        let current = viewModel.values[field.key] ?? ""
                        return options.contains(where: { $0.value == current }) ? current : nil
                    },
                    set: { selected in
                        guard let selected else { return }
                        viewModel.saveSelect(field, value: selected, with: l10n)
                    }
                )) {
                    Text(l10n("请选择")).tag(String?.none)
                    ForEach(options) { option in
                        Text(l10n(option.labelZh))
                            .tag(String?.some(option.value))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        } label: {
            settingLabel(field.zhLabel, description: field.zhDesc)
        }
    }
}
