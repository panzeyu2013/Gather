// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataBatchEditorSheet.swift
// Wave2 task-13：多选照片的批量直改面板（变量文案 + <mixed> 语义 + 逐张预检）。
//
// 与单张编辑器的差别：
// - 初值取"多张共同值"：不同字段显示占位"多个值"，不默认覆盖（mixed 不猜）；
// - 文案支持变量（{seq}/{client}/{year}/{month}/{day}/{filename}/{name}/{ext}/{camera}），
//   每张按照片上下文展开；未解析变量在预览里逐张列出并**禁止提交**；
// - 预检用 MetadataBatchEditPlanner（Protocol 纯逻辑，与写入载荷同源）：
//   逐张显示 write/clear/conflict，把"哪张哪个字段会被覆盖"摆出来；
// - 提交按补丁分组：同补丁的照片一次 applyDescriptive（一个撤销批次），
//   不同补丁（变量/冲突/清空差异）分别提交；结果按批汇总。
//
// 数据来源：metadata(photoId) 缓存投影 + diskDescriptive(photoId) 盘上值（外部
// 改过的字段在 keepExternal 下转 conflict，不静默覆盖）。
import SwiftUI
import GatherProtocol

struct MetadataBatchEditorSheet: View {
    let viewModel: CullingViewModel
    let photoIds: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private static let maxPhotos = 200

    /// 盘上值的可信度：availability 为 nil（未接线/读不到）→ 未知；没有 sidecar
    /// 且盘上描述性为空 → 未知（导入包的照片 cache 有 IPTC，不代表盘上有值）；
    /// 其余（有 sidecar，或 JPEG 内嵌有值）→ 已知。
    struct DiskState: Sendable {
        let descriptive: DescriptiveMetadata
        let known: Bool
    }

    nonisolated static func diskState(
        availability: DiskDescriptiveAvailability?,
        fallback: DescriptiveMetadata
    ) -> DiskState {
        guard let availability else {
            return DiskState(descriptive: fallback, known: false)
        }
        if availability.sidecarExists || !availability.descriptive.isEmpty {
            return DiskState(descriptive: availability.descriptive, known: true)
        }
        // 未知时仍把缓存当基线（清空/写值要能看出"当前值"），但 known=false
        // 让 planner 不把 cache≠disk 误判成外部改动。
        return DiskState(descriptive: fallback, known: false)
    }

    @State private var loaded: [LoadedPhoto] = []
    @State private var isLoading = true
    @State private var loadWarning: String?
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var resultText: String?

    @State private var values: [DescriptiveField: String] = [:]
    @State private var mixedFields: Set<DescriptiveField> = []
    @State private var touched: Set<DescriptiveField> = []
    @State private var cleared: Set<DescriptiveField> = []
    @State private var client = ""
    @State private var sequenceStart = 1
    @State private var policy: MetadataConflictPolicy = .keepExternal
    @State private var pendingApply = false

    struct LoadedPhoto: Sendable {
        let photoId: String
        let cache: DescriptiveMetadata
        let disk: DescriptiveMetadata
        let diskKnown: Bool
        let filename: String
        let camera: String?
        let dateTaken: String?
    }

    private var targetIds: [String] {
        Array(photoIds.sorted().prefix(Self.maxPhotos))
    }

    private var photos: [MetadataBatchPhotoInput] {
        loaded.enumerated().map { index, photo in
            MetadataBatchPhotoInput(
                photoId: photo.photoId,
                cache: photo.cache,
                disk: photo.disk,
                diskKnown: photo.diskKnown,
                filename: photo.filename,
                camera: photo.camera,
                dateTaken: photo.dateTaken,
                sequence: max(1, sequenceStart) + index)
        }
    }

    private var scope: MetadataVariableScope {
        MetadataVariableScope(client: client, sequenceStart: sequenceStart)
    }

    private var edits: [DescriptiveField: MetadataBatchFieldEdit] {
        var result: [DescriptiveField: MetadataBatchFieldEdit] = [:]
        for field in touched {
            if cleared.contains(field) {
                result[field] = .clear
                continue
            }
            let raw = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                result[field] = .clear
            } else if XMPFieldDescriptor.descriptor(for: field)?.isList == true {
                let items = raw.split(whereSeparator: { $0 == "、" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                result[field] = .set(.list(items))
            } else {
                result[field] = .set(.text(raw))
            }
        }
        return result
    }

    private var plan: MetadataBatchEditPlan {
        MetadataBatchEditPlanner.plan(
            edits: edits, photos: photos, scope: scope, policy: policy)
    }

    private var fields: [DescriptiveField] {
        DescriptiveField.allCases.filter { $0 != .contactInfo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n("批量编辑元数据"))
                    .font(GatherFont.cardTitle)
                Spacer()
                Text(l10n.format("目标 %lld 张", targetIds.count))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(l10n("关闭")) { dismiss() }
                    .gatherButton(.secondary)
                    .disabled(isBusy)
            }
            Text(l10n("只写入改动过的字段；留空或勾选“清空”会删除该字段。外部改过的字段默认保留（冲突策略可改）。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                HStack(alignment: .top, spacing: GatherMetrics.Space.m) {
                    fieldList
                    previewPane
                }
                .frame(maxHeight: 460)
            }

            if let loadWarning {
                Text(loadWarning)
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Text(errorText)
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resultText {
                Text(resultText)
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 880)
        .task { await load() }
        .confirmationDialog(
            l10n("写入这批照片的元数据？"),
            isPresented: $pendingApply,
            titleVisibility: .visible
        ) {
            Button(l10n("写入"), role: .destructive) {
                Task { await apply() }
            }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(l10n.format("将写 %lld 张 · %lld 个字段动作 · %lld 处冲突；按补丁分 %lld 批提交，可在“最近套用与写回”撤销。",
                             plan.groups.reduce(0) { $0 + $1.photoIds.count },
                             plan.writeCount + plan.clearCount,
                             plan.conflictCount,
                             plan.groups.count))
        }
    }

    // MARK: - 字段列

    private var fieldList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                    Text("{seq} {client} {year} {month} {day} {filename} {name} {ext} {camera}")
                        .font(GatherFont.label)
                        .foregroundStyle(.secondary)
                    Text(l10n("序号按目标照片 id 升序、从“序号起”逐张 +1；{seq:3} 会补零到 3 位。"))
                        .font(GatherFont.label)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(l10n("客户（{client}）"))
                        .font(GatherFont.label)
                        .frame(width: 96, alignment: .leading)
                    TextField(l10n("留空则 {client} 视为未解析"), text: $client)
                        .textFieldStyle(.roundedBorder)
                    Stepper(value: $sequenceStart, in: 1...9999) {
                        Text(l10n.format("序号起 %lld", sequenceStart))
                            .font(GatherFont.label)
                            .monospacedDigit()
                    }
                }
                Divider()
                ForEach(fields, id: \.self) { field in
                    fieldRow(field)
                }
            }
        }
        .frame(width: 430)
    }

    private func fieldRow(_ field: DescriptiveField) -> some View {
        HStack(alignment: .center, spacing: GatherMetrics.Space.s) {
            Text(l10n(MetadataDisplay.fieldTitle(field)))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            TextField(
                mixedFields.contains(field) ? l10n("多个值") : l10n("未填写"),
                text: Binding(
                    get: { values[field] ?? "" },
                    set: { newValue in
                        values[field] = newValue
                        touched.insert(field)
                        cleared.remove(field)
                    })
            )
            .textFieldStyle(.roundedBorder)
            .disabled(cleared.contains(field))
            Toggle(l10n("清空"), isOn: Binding(
                get: { cleared.contains(field) },
                set: { isOn in
                    if isOn {
                        cleared.insert(field)
                        touched.insert(field)
                    } else {
                        cleared.remove(field)
                    }
                }))
                .toggleStyle(.checkbox)
                .font(GatherFont.label)
        }
    }

    // MARK: - 预检

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n("预检"))
                .font(GatherFont.label)
            Text(l10n.format("写入 %lld · 清空 %lld · 冲突 %lld · 未解析变量 %lld",
                             plan.writeCount, plan.clearCount,
                             plan.conflictCount, plan.unresolved.count))
                .font(GatherFont.secondary)
                .foregroundStyle(plan.unresolved.isEmpty ? .secondary : GatherTheme.warningText)
                .monospacedDigit()
            if !plan.unresolved.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                        ForEach(Array(plan.unresolved.prefix(20).enumerated()), id: \.offset) { _, item in
                            Text(unresolvedText(item))
                                .font(GatherFont.label)
                                .foregroundStyle(GatherTheme.warningText)
                        }
                    }
                }
                .frame(maxHeight: 90)
            }
            Picker(l10n("冲突策略"), selection: $policy) {
                Text(l10n("保留外部改动")).tag(MetadataConflictPolicy.keepExternal)
                Text(l10n("覆盖外部改动")).tag(MetadataConflictPolicy.overwrite)
            }
            .pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                    ForEach(plan.photos.filter(\.changed), id: \.photoId) { photo in
                        photoRow(photo)
                    }
                    if plan.photos.allSatisfy({ !$0.changed }) {
                        Text(l10n("还没有改动：编辑左侧字段后这里显示逐张预检。"))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func photoRow(_ photo: MetadataBatchPhotoPlan) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            Text(displayName(photo.photoId))
                .font(GatherFont.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Text(actionsText(photo))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
        }
        .padding(GatherMetrics.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                .fill(GatherTheme.surfaceMuted))
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Text(l10n.format("补丁分组 %lld · 已改动照片 %lld",
                             plan.groups.count, plan.photos.filter(\.changed).count))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button(l10n("写入…")) { pendingApply = true }
                .gatherButton(.primary)
                .disabled(isBusy || isLoading || !plan.canApply)
        }
    }

    // MARK: - 显示辅助

    private func displayName(_ photoId: String) -> String {
        loaded.first { $0.photoId == photoId }?.filename ?? photoId
    }

    private func unresolvedText(_ item: MetadataBatchUnresolved) -> String {
        l10n.format("%@ · %@ · 缺少变量 %@",
                    displayName(item.photoId),
                    l10n(MetadataDisplay.fieldTitle(item.field)),
                    item.variable.raw)
    }

    private func actionsText(_ photo: MetadataBatchPhotoPlan) -> String {
        let parts = photo.fields.compactMap { fieldPlan -> String? in
            switch fieldPlan.action {
            case .write:
                return l10n.format("写入 %@", l10n(MetadataDisplay.fieldTitle(fieldPlan.field)))
            case .clear:
                return l10n.format("清空 %@", l10n(MetadataDisplay.fieldTitle(fieldPlan.field)))
            case .conflict:
                return l10n.format("冲突 %@", l10n(MetadataDisplay.fieldTitle(fieldPlan.field)))
            case .unchanged:
                return nil
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 加载 / 应用

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let ids = targetIds
        if ids.count < photoIds.count {
            loadWarning = l10n.format("一次最多批量编辑 %lld 张，其余 %lld 张已忽略。",
                                     Self.maxPhotos, photoIds.count - ids.count)
        }
        let api = viewModel.metadataAPI
        struct LoadResult: Sendable {
            let index: Int
            let detail: PhotoMetadataDetail?
            let disk: DescriptiveMetadata
            let diskKnown: Bool
            let error: String?
        }
        // 有界并发（8）：每批一次 TaskGroup，避免 200 张同时读盘把 IO 队列打满。
        var results: [LoadResult] = []
        let batchSize = 8
        var start = 0
        while start < ids.count {
            let end = min(start + batchSize, ids.count)
            let chunk = Array(ids[start..<end])
            let chunkStart = start
            let batchResults = await withTaskGroup(of: LoadResult.self) { group in
                for (offset, photoId) in chunk.enumerated() {
                    let index = chunkStart + offset
                    group.addTask {
                        do {
                            let detail = try await api.metadata(photoId)
                            let availability = try await api.diskDescriptiveAvailability(
                                photoId: photoId)
                            let state = Self.diskState(
                                availability: availability, fallback: detail.descriptive)
                            return LoadResult(
                                index: index, detail: detail, disk: state.descriptive,
                                diskKnown: state.known, error: nil)
                        } catch {
                            return LoadResult(
                                index: index, detail: nil,
                                disk: DescriptiveMetadata(), diskKnown: false,
                                error: String(describing: error))
                        }
                    }
                }
                var collected: [LoadResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: batchResults)
            start = end
        }
        results.sort { $0.index < $1.index }
        var loadedPhotos: [LoadedPhoto] = []
        var failures = 0
        for result in results {
            guard let detail = result.detail else {
                failures += 1
                continue
            }
            loadedPhotos.append(LoadedPhoto(
                photoId: detail.photoId,
                cache: detail.descriptive,
                disk: result.disk,
                diskKnown: result.diskKnown,
                filename: detail.filename,
                camera: detail.exif.cameraModel,
                dateTaken: detail.exif.dateTaken))
        }
        loaded = loadedPhotos
        if failures > 0 {
            loadWarning = l10n.format("有 %lld 张读取失败，未纳入本次批量编辑。", failures)
        }
        initialiseFieldValues()
    }

    private func initialiseFieldValues() {
        let caches = loaded.map(\.cache)
        var newValues: [DescriptiveField: String] = [:]
        var newMixed: Set<DescriptiveField> = []
        for field in fields {
            let text = MetadataFieldMix.commonText(field, across: caches)
            if let text {
                newValues[field] = text
            } else {
                newValues[field] = ""
                newMixed.insert(field)
            }
        }
        values = newValues
        mixedFields = newMixed
        touched = []
        cleared = []
    }

    private func apply() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let groups = plan.groups
        guard !groups.isEmpty else { return }
        var written = 0
        var skipped = 0
        var conflicts = 0
        var failures: [String] = []
        for group in groups {
            do {
                let input = try MetadataInlineApplyInput(
                    photoIds: group.photoIds, fields: group.patch, policy: policy)
                let outcome = try await viewModel.metadataAPI.applyDescriptive(
                    Confirmed(input, source: .userDialog))
                written += outcome.written.count
                skipped += outcome.skipped.count
                conflicts += outcome.conflicts.count
                failures.append(contentsOf: outcome.failed.map(\.message))
            } catch {
                failures.append(CommandErrorText.resolve(CommandError(error), with: l10n))
            }
        }
        resultText = l10n.format("已写 %lld 张 · 跳过 %lld · 冲突 %lld · 失败 %lld",
                                 written, skipped, conflicts, failures.count)
        if let first = failures.first {
            errorText = first
        }
        // #11：批量直改写的是 XMP，常驻页/检查器要立刻知道（与模板套用同一出口）。
        GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
        viewModel.loadMetadataDetail()
        await viewModel.loadPage(reset: true)
    }
}
