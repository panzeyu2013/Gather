// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataTemplateFieldsSheet.swift
// P1 / B2：模板字段编辑（文本赋值 + 显式清空），服务端仍用三态字段落盘。
import SwiftUI
import GatherProtocol

struct MetadataTemplateFieldsSheet: View {
    let viewModel: CullingViewModel
    let template: MetadataTemplateSummary
    let fields: DescriptiveMetadata

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var selected = Set<DescriptiveField>()
    @State private var values: [DescriptiveField: String]
    @State private var initialValues: [DescriptiveField: String]
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var showDiscardConfirm = false

    init(viewModel: CullingViewModel, template: MetadataTemplateSummary,
         fields: DescriptiveMetadata) {
        self.viewModel = viewModel
        self.template = template
        self.fields = fields
        var initial: [DescriptiveField: String] = [:]
        for field in DescriptiveField.allCases {
            switch fields.value(for: field) {
            case .text(let text): initial[field] = text
            case .list(let items): initial[field] = items.joined(separator: "、")
            default: break
            }
        }
        _values = State(initialValue: initial)
        _initialValues = State(initialValue: initial)
    }

    private var isDirty: Bool {
        !selected.isEmpty || values != initialValues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n.format("编辑模板字段：%@", template.name))
                .font(GatherFont.cardTitle)
            Text(l10n("直接修改文本；勾选“清空”后套用模板会删除目标字段。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                    ForEach(DescriptiveField.allCases, id: \.self) { field in
                        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                            HStack {
                                Text(l10n(MetadataDisplay.fieldTitle(field)))
                                Spacer()
                                Text(status(for: field))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(l10n("清空"), isOn: Binding(
                                    get: { selected.contains(field) },
                                    set: { on in
                                        if on { selected.insert(field) } else { selected.remove(field) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                            if isEditable(field) {
                                TextField(l10n("值"), text: Binding(
                                    get: { values[field] ?? "" },
                                    set: { values[field] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .disabled(selected.contains(field))
                            } else {
                                Text(contactSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 440)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text(l10n.format("将清空 %lld 个字段", selected.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(l10n("取消")) {
                    if isDirty { showDiscardConfirm = true } else { dismiss() }
                }
                .gatherButton(.secondary)
                Button(l10n("保存")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .gatherButton(.primary)
                    .disabled(isBusy)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 560)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog(
            l10n("放弃未保存的改动？"),
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(l10n("放弃并关闭"), role: .destructive) { dismiss() }
            Button(l10n("继续编辑"), role: .cancel) {}
        } message: {
            Text(l10n("关闭后本次修改不会保存。"))
        }
    }

    private var contactSummary: String {
        guard let contact = fields.contactInfo else { return l10n("未设置") }
        return MetadataDisplay.contactSummary(contact)
    }

    private func descriptor(_ field: DescriptiveField) -> XMPFieldDescriptor? {
        XMPFieldDescriptor.descriptor(for: field)
    }

    private func isEditable(_ field: DescriptiveField) -> Bool {
        descriptor(field)?.shape != .structure
    }

    private func status(for field: DescriptiveField) -> String {
        guard let value = fields.value(for: field) else { return l10n("未设置") }
        return value.isEmptyValue ? l10n("已清空") : l10n("已设置")
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        var edited = fields
        for field in DescriptiveField.allCases {
            if selected.contains(field) {
                edited.clear(field)
                continue
            }
            guard isEditable(field) else { continue }
            let text = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                // 空文本 = 从模板移除；要显式清空必须勾选。
                if fields.value(for: field) != nil { edited.set(nil, for: field) }
            } else if descriptor(field)?.shape == .bag || descriptor(field)?.shape == .seq {
                // 同时接受中文顿号与逗号：英文输入法下 "," 是自然分隔符，
                // 只认顿号会把 "a, b" 当成一个关键词整体写入。
                let items = text.split(whereSeparator: { $0 == "、" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                edited.set(items.isEmpty ? nil : .list(items), for: field)
            } else {
                edited.set(.text(text), for: field)
            }
        }
        do {
            _ = try await viewModel.metadataAPI.saveTemplate(
                try MetadataTemplateSaveInput(
                    id: template.id, name: template.name, fields: edited))
            dismiss()
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }
}
