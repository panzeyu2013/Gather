// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataTemplateSheet.swift
// P1 / B2：元数据模板的批量套用面板（preview → confirm → undo）。
//
// 交互契约：
// - 预览只读：显示"将写 N 张 / M 个字段 / K 处冲突"，不写文件；
// - 应用是破坏性动作：按钮本身即确认（Confirmed 只能由这里构造），逐张独立提交；
// - 撤销按批次 id 反向写，失败时保留批次可重试。
import SwiftUI
import GatherProtocol

/// 未解析变量的一行（逐字段展示；id 仅用于 ForEach 稳定身份）。
private struct UnresolvedVariableRow: Identifiable {
    let id: String
    let photoId: String
    let field: String
    let variable: String
}

struct MetadataTemplateSheet: View {
    let viewModel: CullingViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var templates: [MetadataTemplateSummary] = []
    @State private var selectedId: String?
    /// Wave2 收尾 task-22：模板级客户名（{client} 变量作用域；空 = 未设置）。
    @State private var clientText = ""
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
    /// 撤销整批写回同样是破坏性动作：必须走确认弹窗后再构造 Confirmed。
    @State private var showUndoConfirm = false
    /// Wave2 task-13：多选批量直改（与模板并列的入口；变量文案在批量面板内）。
    @State private var showBatchEditor = false

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
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
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
                    .gatherButton(.secondary)
                    .disabled(selectedId == nil || editorFields == nil || isBusy)
                Button(l10n("删除")) { showDeleteConfirm = true }
                    .gatherButton(.destructive)
                    .disabled(selectedId == nil || isBusy)
                Button(l10n("批量编辑字段…")) { showBatchEditor = true }
                    .gatherButton(.secondary)
                    .disabled(targetPhotoIds.isEmpty || isBusy)
            }

            HStack {
                TextField(l10n("新模板名称"), text: $name)
                    .labelsHidden()
                Button(l10n("从当前照片保存为模板")) { Task { await saveFromCurrent() } }
                    .gatherButton(.secondary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            }

            // Wave2 收尾 task-22：模板级客户名（{client}）。改完点“保存模板变量”写入
            // 当前模板；预览会按新 client 重新展开（预览令牌包含 client）。
            HStack {
                TextField(l10n("客户名（模板变量 {client}）"), text: $clientText)
                    .labelsHidden()
                Button(l10n("保存模板变量")) { Task { await saveTemplateVariables() } }
                    .gatherButton(.secondary)
                    .disabled(selectedId == nil || isBusy)
            }
            Text(l10n("留空 = 未设置：模板里的 {client} 会被判为未解析，预览会逐字段列出并禁止应用。"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
            Text(l10n.format("当前照片已填写 %lld 个描述性字段",
                             viewModel.metadataDetail?.filledDescriptiveCount ?? 0))
                .font(GatherFont.label)
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
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
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
                            .font(GatherFont.label)
                            .foregroundStyle(.secondary)
                    }
                    if preview.hasReadFailures {
                        Text(l10n.format("%lld 张照片读盘失败，预览不完整，禁止应用：",
                                         preview.readFailureCount))
                            .font(GatherFont.label)
                            .foregroundStyle(GatherTheme.warningText)
                        ForEach((preview.failed ?? []).prefix(8), id: \.photoId) { failure in
                            Text(l10n.format("%@：%@", failure.photoId, failure.message))
                                .font(GatherFont.label)
                                .foregroundStyle(GatherTheme.warningText)
                        }
                    }
                    if preview.hasUnresolvedVariables {
                        Text(l10n.format("%lld 处模板变量未解析，禁止应用：",
                                         preview.unresolvedVariableCount))
                            .font(GatherFont.label)
                            .foregroundStyle(GatherTheme.warningText)
                        ForEach(Array(unresolvedRows.prefix(8))) { row in
                            Text(unresolvedLine(photoId: row.photoId, field: row.field,
                                                variable: row.variable))
                                .font(GatherFont.label)
                                .foregroundStyle(GatherTheme.warningText)
                        }
                    }
                }
                .font(GatherFont.secondary)
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
                    .gatherButton(.secondary)
                    .disabled(selectedTemplate == nil || targetPhotoIds.isEmpty || isBusy)
                Button(l10n("应用到选中照片")) { Task { await runApply() } }
                    .gatherButton(.primary)
                    .disabled(preview == nil || (preview?.changedFields ?? 0) == 0
                              || (preview?.hasUnresolvedVariables ?? false)
                              || (preview?.hasReadFailures ?? false) || isBusy)
                Spacer()
                if let appliedBatchId {
                    Button(l10n("撤销此次套用")) { showUndoConfirm = true }
                        .gatherButton(.tertiary)
                        .disabled(isBusy)
                        .confirmationDialog(
                            l10n("撤销这次写回？"),
                            isPresented: $showUndoConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(l10n("撤销"), role: .destructive) {
                                Task { await runUndo(batchId: appliedBatchId) }
                            }
                            Button(l10n("取消"), role: .cancel) {}
                        } message: {
                            Text(l10n("还原这批照片的描述性字段；冲突字段按套用前快照恢复。"))
                        }
                }
                Button(l10n("关闭")) { dismiss() }
                    .gatherButton(.secondary)
            }
        }
        .padding(GatherMetrics.Space.l)
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
        .sheet(isPresented: $showBatchEditor) {
            MetadataBatchEditorSheet(viewModel: viewModel, photoIds: targetPhotoIds)
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
            // 旧批次的失败红字不能常驻：换模板后它描述的是另一件事。
            errorText = nil
            // 模板级 client 随模板切换（旧模板没有 client 字段 = ""）。
            clientText = selectedTemplate?.client ?? ""
        }
        .onChange(of: policy) {
            preview = nil
        }
        // client 改了但没保存 = 模板未变，旧预览不能代表新输入；清了让用户重跑预览。
        .onChange(of: clientText) {
            preview = nil
        }
        // 目标集变化后旧预览不再对应当前照片（确认计数会骗人）。
        .onChange(of: viewModel.selectedPhotoIds) {
            preview = nil
            outcome = nil
            appliedBatchId = nil
            errorText = nil
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
            clientText = selectedTemplate?.client ?? ""
        } catch {
            guard selectedId == id else { return }
            editorFields = nil
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    private func reload() async {
        do {
            templates = try await viewModel.metadataAPI.templates()
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    /// 模板级 client 的归一化值（空白 = nil）。
    private var clientValue: String? {
        let trimmed = clientText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 未解析变量行（逐字段；照片可能不在当前页，名字回退到 photoId）。
    private var unresolvedRows: [UnresolvedVariableRow] {
        guard let preview else { return [] }
        return preview.photos.flatMap { photo in
            photo.unresolved.map { item in
                UnresolvedVariableRow(
                    id: photo.photoId + "|" + item.field + "|" + item.variable,
                    photoId: photo.photoId,
                    field: item.field,
                    variable: item.variable)
            }
        }
    }

    /// 未解析变量的一行文案（照片名 + 字段标题 + 占位符）。
    private func unresolvedLine(photoId: String, field: String, variable: String) -> String {
        let fieldTitle: String
        if let field = DescriptiveField(rawValue: field) {
            fieldTitle = MetadataDisplay.fieldTitle(field)
        } else {
            fieldTitle = field
        }
        let filename = viewModel.page?.assets.first { $0.photo.id == photoId }?.photo.filename
            ?? photoId
        return l10n.format("%@ · %@ · 缺少变量 %@", filename, fieldTitle, variable)
    }

    /// 把 client 写回当前模板（字段体不变；旧 JSON 兼容由 Optional 解码保证）。
    ///
    /// 模板定义变更不是照片元数据：不发域事件（见 deleteSelected 同口径）。
    // DOMAIN-EVENT: none — 模板定义/客户名不是照片元数据，不改任何照片的 XMP
    private func saveTemplateVariables() async {
        guard let summary = selectedTemplate else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let fields = try await viewModel.metadataAPI.templateFields(id: summary.id)
            _ = try await viewModel.metadataAPI.saveTemplate(
                MetadataTemplateSaveInput(
                    id: summary.id, name: summary.name, fields: fields,
                    client: clientValue))
            await reload()
            preview = nil
            outcome = nil
            errorText = nil
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
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
                MetadataTemplateSaveInput(
                    id: nil, name: name, fields: fields, client: clientValue))
            name = ""
            await reload()
            selectedId = summary.id
            clientText = summary.client ?? ""
            errorText = nil
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    // DOMAIN-EVENT: none — 模板定义不是照片元数据；删模板不影响任何页面的照片数据
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
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
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
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    private func runApply() async {
        guard let id = selectedId else { return }
        // 服务端会拒绝（二次校验），这里先拦一层：预览已逐字段列出未解析变量。
        if preview?.hasReadFailures == true {
            errorText = l10n.format("%lld 张照片读盘失败，预览不完整，禁止应用：",
                                    preview?.readFailureCount ?? 0)
            return
        }
        if preview?.hasUnresolvedVariables == true {
            errorText = l10n.format("%lld 处模板变量未解析，禁止应用：",
                                    preview?.unresolvedVariableCount ?? 0)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await viewModel.metadataAPI.applyTemplate(
                Confirmed(try MetadataTemplateApplyInput(
                    templateId: id, photoIds: targetPhotoIds, policy: policy,
                    expectedPreviewToken: preview?.previewToken),
                    source: .userDialog))
            outcome = result
            // #11：模板套用写的是 XMP，常驻页要立刻知道
            // 本页动作：带 culling origin，避免挑片页再整页刷一次（sheet 自己会 reload）。
            GatherEventCenter.postDomainChange(
                .metadata, sessionId: nil, origin: CullingViewModel.changeOrigin)
            // P1：失败原因必须可见。JPEG 内嵌字段无法清空时只显示"失败 N 张"，
            // 用户会误以为清空完成；首条失败的码/参数由渲染期本地化。
            errorText = result.failed.first.map { failure in
                MetadataDisplay.localizedFailure(failure.message, with: l10n)
            }
            // 只有真的留下可撤销快照才给撤销入口：写前就失败（批次未入库）时
            // 点撤销只会得到"批次不存在"。
            appliedBatchId = result.undoAvailable ? result.batchId : nil
            preview = nil
            await viewModel.loadPage(reset: true)
            viewModel.loadMetadataDetail()
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    private func runUndo(batchId: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await viewModel.metadataAPI.undoTemplate(
                Confirmed(try MetadataTemplateUndoInput(batchId: batchId), source: .userDialog))
            outcome = result
            // #11：撤销同样是写盘
            // 本页动作：带 culling origin，避免挑片页再整页刷一次（sheet 自己会 reload）。
            GatherEventCenter.postDomainChange(
                .metadata, sessionId: nil, origin: CullingViewModel.changeOrigin)
            // 部分失败时保留 batchId，表内可重试；批次仍是 undone=false。
            if result.failed.isEmpty {
                appliedBatchId = nil
                // 撤销成功 = 上一轮的失败原因已过期。
                errorText = nil
            } else {
                errorText = l10n.format("撤销有 %lld 张失败，可重试", result.failed.count)
            }
            await viewModel.loadPage(reset: true)
            viewModel.loadMetadataDetail()
        } catch {
            // 撤销失败也走码表本地化，不把 "批次不存在：<uuid>" 这类内部文本上屏。
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            // 撤销入口在当前批次上已无意义（批次缺失/已撤销），收回按钮。
            appliedBatchId = nil
        }
    }
}
