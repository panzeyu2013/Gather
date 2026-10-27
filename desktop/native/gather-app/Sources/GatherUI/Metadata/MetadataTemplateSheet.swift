// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataTemplateSheet.swift
// P1 / B2：元数据模板的批量套用面板（preview → confirm → undo）。
//
// 交互契约：
// - 预览只读：显示"将写 N 张 / M 个字段 / K 处冲突"，不写文件；
// - 应用是破坏性动作：按钮本身即确认（Confirmed 只能由这里构造），逐张独立提交；
// - 撤销按批次 id 反向写，失败时保留批次可重试。
import SwiftUI
import GatherProtocol

struct MetadataTemplateSheet: View {
    let viewModel: CullingViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var templates: [MetadataTemplateSummary] = []
    @State private var selectedId: String?
    @State private var name = ""
    @State private var policy: MetadataConflictPolicy = .keepExternal
    @State private var preview: MetadataTemplatePreviewResult?
    @State private var outcome: MetadataTemplateApplyOutcome?
    /// 可撤销的批次（应用成功后设置；撤销成功/切换模板后清空，避免重复回滚）。
    @State private var appliedBatchId: String?
    @State private var errorText: String?
    @State private var isBusy = false
    /// 当前模板字段（清空编辑器用）。
    @State private var editorFields: DescriptiveMetadata?
    @State private var showClearEditor = false
    @State private var showDeleteConfirm = false

    /// 目标：多选优先，否则当前照片。
    private var targetPhotoIds: [String] {
        if !viewModel.selectedPhotoIds.isEmpty {
            return viewModel.selectedPhotoIds.sorted()
        }
        if let id = viewModel.currentAsset?.photo.id { return [id] }
        return []
    }

    private var selectedTemplate: MetadataTemplateSummary? {
        templates.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("元数据模板"))
                .font(.headline)

            HStack {
                Picker(l10n("模板"), selection: $selectedId) {
                    Text(l10n("选择模板")).tag(String?.none)
                    ForEach(templates, id: \.id) { template in
                        Text(l10n.format("%@（%lld 个字段）", template.name, template.fieldCount))
                            .tag(Optional(template.id))
                    }
                }
                .disabled(isBusy)
                Button(l10n("清空字段…")) { showClearEditor = true }
                    .disabled(selectedId == nil || editorFields == nil || isBusy)
                Button(l10n("删除")) { showDeleteConfirm = true }
                    .disabled(selectedId == nil || isBusy)
            }

            HStack {
                TextField(l10n("新模板名称"), text: $name)
                    .labelsHidden()
                Button(l10n("从当前照片保存为模板")) { Task { await saveFromCurrent() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            }
            Text(l10n.format("当前照片已填写 %lld 个描述性字段",
                             viewModel.metadataDetail?.filledDescriptiveCount ?? 0))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(l10n("冲突策略"), selection: $policy) {
                Text(l10n("保留外部改动")).tag(MetadataConflictPolicy.keepExternal)
                Text(l10n("覆盖外部改动")).tag(MetadataConflictPolicy.overwrite)
            }
            .pickerStyle(.segmented)

            Text(l10n.plural("目标：%lld 张照片", count: targetPhotoIds.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    let clears = preview.photos.reduce(0) { $0 + $1.clears.count }
                    Text(l10n.format("将写 %lld 张 / %lld 个字段；%lld 处冲突",
                                     preview.changedPhotos, preview.changedFields,
                                     preview.conflictFields))
                    if clears > 0 {
                        Text(l10n.format("其中 %lld 个字段会被清空", clears))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if preview.conflictFields > 0 {
                        Text(policy == .keepExternal
                             ? l10n("冲突字段保留外部改动，不会覆盖。")
                             : l10n("冲突字段将按“覆盖外部改动”写入。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }

            if let outcome {
                Text(l10n.format("已写 %lld 张，跳过 %lld 张，失败 %lld 张",
                                 outcome.written.count, outcome.skipped.count,
                                 outcome.failed.count))
                    .font(.caption)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(l10n("预览")) { Task { await runPreview() } }
                    .disabled(selectedTemplate == nil || targetPhotoIds.isEmpty || isBusy)
                Button(l10n("应用到选中照片")) { Task { await runApply() } }
                    .disabled(preview == nil || (preview?.changedFields ?? 0) == 0 || isBusy)
                Spacer()
                if let appliedBatchId {
                    Button(l10n("撤销此次套用")) { Task { await runUndo(batchId: appliedBatchId) } }
                        .disabled(isBusy)
                }
                Button(l10n("关闭")) { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 560)
        .task { await reload() }
        .task(id: selectedId) { await loadFields() }
        .confirmationDialog(
            l10n("删除这个模板？"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(l10n("删除"), role: .destructive) { Task { await deleteSelected() } }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(l10n("删除后不可恢复；已套用的照片不会回滚。"))
        }
        .sheet(isPresented: $showClearEditor) {
            if let template = selectedTemplate, let fields = editorFields {
                MetadataTemplateFieldsSheet(
                    viewModel: viewModel, template: template, fields: fields)
                    .onDisappear {
                        Task {
                            await loadFields()
                            await reload()
                        }
                    }
            } else {
                EmptyView()
            }
        }
        .onChange(of: selectedId) {
            preview = nil
            outcome = nil
        }
        .onChange(of: policy) {
            preview = nil
        }
        // 目标集变化后旧预览不再对应当前照片（确认计数会骗人）。
        .onChange(of: viewModel.selectedPhotoIds) {
            preview = nil
            outcome = nil
            appliedBatchId = nil
        }
    }

    private func loadFields() async {
        guard let id = selectedId else { editorFields = nil; return }
        do {
            let fields = try await viewModel.metadataAPI.templateFields(id: id)
            // latest-wins：await 期间用户可能已切换模板，旧响应写进 editorFields
            // 会让保存把 A 的字段写进 B（静默覆盖模板体）。
            guard selectedId == id else { return }
            editorFields = fields
        } catch {
            guard selectedId == id else { return }
            editorFields = nil
            errorText = String(describing: error)
        }
    }

    private func reload() async {
        do {
            templates = try await viewModel.metadataAPI.templates()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func saveFromCurrent() async {
        guard let detail = viewModel.metadataDetail else {
            errorText = l10n("尚未加载当前照片的元数据")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            // 只保存有值的字段：模板里的空值代表"清空"，不能把未填写字段带进去。
            var fields = DescriptiveMetadata()
            for field in DescriptiveField.allCases {
                if let value = detail.descriptive.value(for: field), !value.isEmptyValue {
                    fields.set(value, for: field)
                }
            }
            guard !fields.isEmpty else {
                errorText = l10n("当前照片没有可保存的描述性元数据")
                return
            }
            let summary = try await viewModel.metadataAPI.saveTemplate(
                MetadataTemplateSaveInput(id: nil, name: name, fields: fields))
            name = ""
            await reload()
            selectedId = summary.id
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    private func deleteSelected() async {
        guard let id = selectedId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await viewModel.metadataAPI.deleteTemplate(
                Confirmed(try MetadataTemplateDeleteInput(templateId: id), source: .userDialog))
            selectedId = nil
            preview = nil
            outcome = nil
            await reload()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func runPreview() async {
        guard let id = selectedId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            preview = try await viewModel.metadataAPI.previewTemplate(
                try MetadataTemplatePreviewInput(
                    templateId: id, photoIds: targetPhotoIds, policy: policy))
            outcome = nil
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    private func runApply() async {
        guard let id = selectedId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await viewModel.metadataAPI.applyTemplate(
                Confirmed(try MetadataTemplateApplyInput(
                    templateId: id, photoIds: targetPhotoIds, policy: policy),
                    source: .userDialog))
            outcome = result
            // 失败也可能已入队/已写盘（批次已记录），保留撤销入口。
            appliedBatchId = (result.written.isEmpty && result.failed.isEmpty)
                ? nil : result.batchId
            preview = nil
            await viewModel.loadPage(reset: true)
            viewModel.loadMetadataDetail()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func runUndo(batchId: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await viewModel.metadataAPI.undoTemplate(
                Confirmed(try MetadataTemplateUndoInput(batchId: batchId), source: .userDialog))
            outcome = result
            // 部分失败时保留 batchId，表内可重试；批次仍是 undone=false。
            if result.failed.isEmpty {
                appliedBatchId = nil
            } else {
                errorText = l10n.format("撤销有 %lld 张失败，可重试", result.failed.count)
            }
            await viewModel.loadPage(reset: true)
            viewModel.loadMetadataDetail()
        } catch {
            errorText = String(describing: error)
        }
    }
}
