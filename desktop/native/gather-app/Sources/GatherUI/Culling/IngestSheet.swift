// desktop/native/gather-app/Sources/GatherUI/Culling/IngestSheet.swift
// P1 / D：摄取向导（复制/重命名/校验 → 登记进当前会话）。
//
// 只做"把卡里的照片搬进工作目录并登记"这一件事：不选片、不改元数据。
// 目标默认 <会话源目录>/_ingest（打开时由 session.get 补齐），源用系统面板选（支持多选目录）。
import SwiftUI
import AppKit
import GatherProtocol

struct IngestSheet: View {
    let viewModel: CullingViewModel


    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var sources: [String] = []
    @State private var destinationRoot = ""
    @State private var renameTemplate = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}"
    @State private var secondRoot = ""
    @State private var verifyChecksum = true
    /// Wave4a-L1：跨工作区重复的处置策略（随摄取输入下传，缺省与旧行为一致 = skip）。
    @State private var duplicatePolicy: IngestDuplicatePolicy = .skip
    /// Wave4a-L1：预检结果（只读；不复制文件）与进行中状态。
    @State private var preview: SessionIngestPreview?
    @State private var isPreviewing = false
    @State private var isRunning = false
    @State private var result: SessionIngestResult?
    @State private var errorText: String?
    /// P1-3：会话没有 sourcePath 时先修根，不引导用户手选一个必败的目标目录。
    @State private var rootMissing = false
    @State private var progress: (current: Int, total: Int)?
    @State private var progressTask: Task<Void, Never>?
    @State private var cancelling = false

    // Wave5 batch3（task-19）：导入预设 + 结果完整可见。
    @State private var presets: [IngestPreset] = []
    @State private var selectedPresetID = ""
    @State private var presetNameDraft = ""
    @State private var isNamingPreset = false
    @State private var presetError: String?
    @State private var showDeletePresetAlert = false
    @State private var showAllFailures = false
    @State private var retryNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("摄取到当前会话"))
                .font(.headline)

            // Wave5 batch3：预设行只在宿主注入了 SettingsAPI 时展示（预览/单测无设置域）。
            if IngestPresetBridge.settings != nil {
                presetControls
            }

            if rootMissing {
                HStack(spacing: GatherMetrics.Space.s) {
                    Text(l10n("当前工作区没有根目录，无法确定摄取目标。"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(l10n("设置根目录…")) { chooseSessionRoot() }
                        .gatherButton(.secondary, size: .small)
                }
            }

            LabeledContent(l10n("来源")) {
                HStack {
                    Text(sources.isEmpty ? l10n("未选择") : sources.joined(separator: "、"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(sources.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(l10n("选择…")) { chooseSources() }
                        .gatherButton(.secondary, size: .small)
                        .accessibilityLabel(l10n("来源"))
                }
            }

            LabeledContent(l10n("目标文件夹")) {
                HStack {
                    TextField(l10n("目标文件夹"), text: $destinationRoot)
                        .labelsHidden()
                    Button(l10n("选择…")) { chooseDestination() }
                        .gatherButton(.secondary, size: .small)
                        .accessibilityLabel(l10n("目标文件夹"))
                }
            }

            LabeledContent(l10n("重命名模板")) {
                TextField("{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}", text: $renameTemplate)
                    .labelsHidden()
                    .font(.body.monospaced())
            }
            Text(l10n("占位符：{yyyy} {MM} {dd} {HH} {mm} {ss} {orig} {ext} {seq:4} {camera}"))
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent(l10n("第二目的地")) {
                HStack {
                    TextField(l10n("可选"), text: $secondRoot)
                        .labelsHidden()
                    Button(l10n("选择…")) { chooseSecondDestination() }
                        .gatherButton(.secondary, size: .small)
                        .accessibilityLabel(l10n("第二目的地"))
                }
            }

            // Wave3 / G12：C1 若把目标目录设为 Hot Folder 会与摄取重复（检测不到，只提示）。
            // P2（Wave4b）：只在装了 C1 的机器展示（没装 C1 的用户看到的是噪音）。
            if viewModel.captureOne.c1Installed {
                C1HotFolderNotice()
            }

            Toggle(l10n("复制后校验校验和"), isOn: $verifyChecksum)

            // Wave4a-L1：重复处置三选一 + 只读预检（此前把库内重复静默跳过，用户看不到）。
            LabeledContent(l10n("重复处置")) {
                Picker(l10n("重复处置"), selection: $duplicatePolicy) {
                    Text(l10n("跳过库内已存在的照片")).tag(IngestDuplicatePolicy.skip)
                    Text(l10n("并存（再存一份）")).tag(IngestDuplicatePolicy.coexist)
                    Text(l10n("覆盖库内已存在的照片")).tag(IngestDuplicatePolicy.replace)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(l10n("按 SHA-256 命中全库已登记照片；覆盖仅限同一工作区且原路径在源根内，否则退化为跳过。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: GatherMetrics.Space.s) {
                Button(isPreviewing ? l10n("预检中…") : l10n("预检")) {
                    Task { await runPreview() }
                }
                .gatherButton(.secondary, size: .small)
                .disabled(isPreviewing || isRunning || sources.isEmpty
                          || destinationRoot.isEmpty || rootMissing)
                Spacer(minLength: 0)
            }
            if let preview {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                    Text(l10n.format(
                        "预检：新增 %lld 张，库内重复 %lld 张（会跳过 %lld 张 / 可覆盖 %lld 张），目标冲突 %lld 张，不可读 %lld 个",
                        preview.newCount, preview.libraryDuplicateCount,
                        preview.librarySkippedCount, preview.replaceableCount,
                        preview.conflictCount, preview.unreadableCount))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !preview.duplicateSamplePaths.isEmpty {
                        Text(l10n.format("重复样例：%@",
                            preview.duplicateSamplePaths.prefix(3).joined(separator: "、")))
                            .font(GatherFont.secondary)
                            .foregroundStyle(GatherTheme.secondaryText)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    // Wave5（F4）：不支持格式必须在"开始摄取"前可见（否则用户
                    // 以为卡里的文件全进来了，实际少了 GIF/视频/未知 RAW）。
                    if preview.unsupportedFormats.count > 0 {
                        Text(Self.unsupportedFormatsText(preview.unsupportedFormats, l10n: l10n))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if !preview.unsupportedFormats.samplePaths.isEmpty {
                            Text(l10n.format("示例：%@",
                                Self.sampleFileNames(preview.unsupportedFormats)))
                                .font(GatherFont.secondary)
                                .foregroundStyle(GatherTheme.secondaryText)
                                .lineLimit(3)
                                .truncationMode(.middle)
                        }
                    }
                    // Wave5 batch3：不只给计数——目标路径与冲突源的前 10 条样例可见。
                    if !preview.targetSamplePaths.isEmpty {
                        samplePathsSection(
                            title: l10n.format(
                                "目标路径（前 %lld 个）", preview.targetSamplePaths.count),
                            paths: preview.targetSamplePaths)
                    }
                    if !preview.conflictSamplePaths.isEmpty {
                        samplePathsSection(
                            title: l10n.format(
                                "冲突源文件（前 %lld 个）", preview.conflictSamplePaths.count),
                            paths: preview.conflictSamplePaths)
                    }
                }
            }

            if isRunning {
                HStack(spacing: GatherMetrics.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(progress.map { l10n.format("已复制 %lld/%lld", $0.current, $0.total) }
                         ?? l10n("正在摄取…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button(cancelling ? l10n("正在取消…") : l10n("取消摄取")) {
                        Task { await cancelIngest() }
                    }
                    .gatherButton(.secondary, size: .small)
                    .disabled(cancelling)
                }
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            if let result {
                Text(l10n.format("已登记 %lld 张，跳过 %lld 张，失败 %lld 张",
                                 result.registered, result.skipped.count, result.failed.count))
                    .font(.caption)
                if !result.unreadable.isEmpty {
                    Text(l10n.format("无法读取/越界被拒绝：%lld 个", result.unreadable.count))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // Wave5（F4）：不支持格式的跳过在结果区可见（含扩展名分组 + 样例）。
                if let unsupported = result.unsupportedFormats, unsupported.count > 0 {
                    Text(Self.unsupportedFormatsText(unsupported, l10n: l10n))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if !unsupported.samplePaths.isEmpty {
                        Text(l10n.format("示例：%@", Self.sampleFileNames(unsupported)))
                            .font(GatherFont.secondary)
                            .foregroundStyle(GatherTheme.secondaryText)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
                // Wave4a-L1：按 libraryDuplicates / librarySkipped / replaced 分类展示。
                if let duplicates = result.libraryDuplicateCount, duplicates > 0 {
                    Text(l10n.format("命中库内重复 %lld 张（跳过 %lld / 覆盖 %lld）",
                                     duplicates,
                                     result.libraryDuplicatesSkipped ?? 0,
                                     result.replaced ?? 0))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
                if let secondSkipped = result.secondDestinationSkipped, secondSkipped > 0 {
                    Text(l10n.format("第二目的地跳过 %lld 张（替换项无法按相对路径镜像）",
                                     secondSkipped))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
                // Wave5 batch3：第二目的地成功数也要可见（不再只报"跳过"）。
                if let secondCopied = result.secondDestinationCopied, secondCopied > 0 {
                    Text(l10n.format("第二目的地已复制 %lld 张（%@）", secondCopied,
                                     verifyChecksum ? l10n("已校验") : l10n("未校验")))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
                if !result.copiedButUnregistered.isEmpty {
                    Text(l10n.format("已复制但未登记：%lld 张", result.copiedButUnregistered.count))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // Wave5 batch3：失败不再只显示第一条——全量可展开 + 只重试失败项。
                if !result.failed.isEmpty {
                    Text(l10n.format("失败 %lld 张", result.failed.count))
                        .font(.caption)
                        .foregroundStyle(.red)
                    let failures = showAllFailures
                        ? result.failed : Array(result.failed.prefix(3))
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        let failureError = CommandError(
                            apiText: failure.code ?? "", diagnostic: failure.message)
                        Text(CommandErrorText.resolve(failureError, with: l10n))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: GatherMetrics.Space.s) {
                        if result.failed.count > 3 {
                            Button(showAllFailures
                                   ? l10n("收起失败")
                                   : l10n.format("查看全部 %lld 条失败", result.failed.count)) {
                                showAllFailures.toggle()
                            }
                            .gatherButton(.tertiary, size: .small)
                        }
                        Button(l10n("只重试失败项")) {
                            Task { await retryFailedItems() }
                        }
                        .gatherButton(.secondary, size: .small)
                        .disabled(isRunning)
                    }
                }
                if let retryNotice {
                    Text(retryNotice)
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
            }

            HStack {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                    .gatherButton(.secondary)
                    .disabled(isRunning)
                Button(l10n("开始摄取")) { Task { await run() } }
                    .gatherButton(.primary)
                    .disabled(isRunning || sources.isEmpty || destinationRoot.isEmpty || rootMissing)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 520)
        // 运行中禁止 Esc/点外部关闭：任务在后台继续但用户看不到进度会以为已取消。
        .interactiveDismissDisabled(isRunning)
        .task {
            // 调用点没传会话目录时从会话记录补：目标必须在会话源目录内（API 会校验）。
            guard destinationRoot.isEmpty else { return }
            guard let api = viewModel.sessionAPI else {
                errorText = l10n("摄取未接线（缺少 session API）")
                return
            }
            do {
                let session = try await api.get(viewModel.sessionId)
                // await 期间用户可能已经手选目录：不得用回填值覆盖。
                guard destinationRoot.isEmpty else { return }
                if !session.sourcePath.isEmpty {
                    destinationRoot = (session.sourcePath as NSString)
                        .appendingPathComponent("_ingest")
                    rootMissing = false
                } else {
                    rootMissing = true
                    errorText = l10n("当前工作区没有根目录，无法确定摄取目标。")
                }
            } catch {
                errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            }
        }
        // Wave5 batch3：预设加载与"最近使用回填"（宿主没注入 SettingsAPI 时 no-op）。
        .task { await loadPresets() }
        // 手动改任一字段 = 不再是某条预设（选中的预设会被清空并记住"未选择"）。
        .onChange(of: renameTemplate) { _, _ in markPresetAsCustomIfNeeded() }
        .onChange(of: secondRoot) { _, _ in markPresetAsCustomIfNeeded() }
        .onChange(of: verifyChecksum) { _, _ in markPresetAsCustomIfNeeded() }
        .onChange(of: duplicatePolicy) { _, _ in markPresetAsCustomIfNeeded() }
        .alert(
            l10n.format("删除预设「%@」？", selectedPresetName),
            isPresented: $showDeletePresetAlert
        ) {
            Button(l10n("删除"), role: .destructive) {
                Task { await deleteSelectedPreset() }
            }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(l10n("只删除预设，不改动照片或文件。"))
        }
    }

    // MARK: - 导入预设（Wave5 batch3）

    /// 预设区：Picker + 保存（内联命名）+ 删除。只在宿主注入 SettingsAPI 时出现。
    private var presetControls: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            LabeledContent(l10n("导入预设")) {
                HStack(spacing: GatherMetrics.Space.s) {
                    Picker(l10n("导入预设"), selection: presetSelection) {
                        Text(l10n("自定义（当前值）")).tag("")
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Button(l10n("保存当前为预设…")) {
                        presetNameDraft = suggestedPresetName
                        isNamingPreset = true
                        presetError = nil
                    }
                    .gatherButton(.secondary, size: .small)
                    Button(l10n("删除预设")) {
                        showDeletePresetAlert = true
                    }
                    .gatherButton(.tertiary, size: .small)
                    .disabled(selectedPresetID.isEmpty)
                }
            }
            Text(l10n("预设会保存改名模板、第二目的地、校验与重复处置。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            if isNamingPreset {
                HStack(spacing: GatherMetrics.Space.s) {
                    TextField(l10n("预设名称"), text: $presetNameDraft)
                        .labelsHidden()
                    Button(l10n("保存")) {
                        Task { await saveCurrentPreset() }
                    }
                    .gatherButton(.secondary, size: .small)
                    Button(l10n("取消")) {
                        isNamingPreset = false
                        presetNameDraft = ""
                    }
                    .gatherButton(.tertiary, size: .small)
                }
            }
            if let presetError {
                Text(presetError)
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Picker 绑定：选中预设即回填字段并记住"最近使用"；选"自定义"只清最近使用。
    private var presetSelection: Binding<String> {
        Binding(
            get: { selectedPresetID },
            set: { newValue in
                selectedPresetID = newValue
                if let preset = presets.first(where: { $0.id == newValue }) {
                    applyPreset(preset)
                    persistLastUsedPreset(newValue)
                } else if newValue.isEmpty {
                    persistLastUsedPreset(nil)
                }
            })
    }

    private var selectedPresetName: String {
        presets.first(where: { $0.id == selectedPresetID })?.name ?? ""
    }

    private var suggestedPresetName: String {
        selectedPresetName.isEmpty ? l10n.format("预设 %lld", presets.count + 1) : selectedPresetName
    }

    private func applyPreset(_ preset: IngestPreset) {
        renameTemplate = preset.renameTemplate
        secondRoot = preset.secondDestinationRoot ?? ""
        verifyChecksum = preset.verifyChecksum
        duplicatePolicy = preset.duplicatePolicy
    }

    /// 选中预设后手动改字段：与预设不再一致 → 切回"自定义（当前值）"。
    private func markPresetAsCustomIfNeeded() {
        guard !selectedPresetID.isEmpty,
              let preset = presets.first(where: { $0.id == selectedPresetID }) else { return }
        guard !IngestPresetStore.matches(
            preset,
            renameTemplate: renameTemplate,
            secondDestinationRoot: secondRoot.isEmpty ? nil : secondRoot,
            verifyChecksum: verifyChecksum,
            duplicatePolicy: duplicatePolicy) else { return }
        selectedPresetID = ""
        persistLastUsedPreset(nil)
    }

    private func loadPresets() async {
        guard let settings = IngestPresetBridge.settings else { return }
        let snapshot = await IngestPresetStore.load(settings)
        presets = snapshot.presets
        guard let lastUsed = snapshot.lastUsedPresetID,
              let preset = presets.first(where: { $0.id == lastUsed }) else { return }
        selectedPresetID = lastUsed
        applyPreset(preset)
    }

    private func persistLastUsedPreset(_ presetID: String?) {
        guard let settings = IngestPresetBridge.settings else { return }
        Task {
            do {
                try await IngestPresetStore.saveLastUsed(presetID, settings: settings)
            } catch {
                GatherLogger.log("ingest preset last-used persist failed: \(error)", level: .warn)
            }
        }
    }

    private func saveCurrentPreset() async {
        guard let settings = IngestPresetBridge.settings else {
            presetError = l10n("导入预设未接线（缺少 settings API）")
            return
        }
        let name = presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presetError = l10n("预设名称不能为空")
            return
        }
        let existingID = presets.first(where: { $0.name == name })?.id
        let preset = IngestPreset(
            id: existingID ?? UUID().uuidString.lowercased(),
            name: String(name.prefix(64)),
            renameTemplate: renameTemplate,
            secondDestinationRoot: secondRoot.isEmpty ? nil : secondRoot,
            verifyChecksum: verifyChecksum,
            duplicatePolicy: duplicatePolicy,
            // 元数据模板留给后续批次：保存当前选中预设里已有的值，不做编辑。
            metadataTemplateID: presets.first(where: { $0.id == selectedPresetID })?.metadataTemplateID)
        do {
            let next = try IngestPresetStore.upserting(preset, in: presets)
            // 先落盘再改内存：settings 写失败（value 超长/API 错误）时面板不能显示"已保存"。
            try await IngestPresetStore.save(
                IngestPresetSnapshot(presets: next, lastUsedPresetID: preset.id),
                settings: settings)
            presets = next
            selectedPresetID = preset.id
            isNamingPreset = false
            presetNameDraft = ""
            presetError = nil
        } catch IngestPresetStoreError.tooMany {
            presetError = l10n.format("最多保存 %lld 个导入预设",
                                      IngestPresetStore.maxPresets)
        } catch {
            presetError = l10n.format(
                "预设保存失败：%@",
                CommandErrorText.resolve(CommandError(error), with: l10n))
        }
    }

    private func deleteSelectedPreset() async {
        guard let settings = IngestPresetBridge.settings,
              !selectedPresetID.isEmpty else { return }
        let next = IngestPresetStore.removing(id: selectedPresetID, from: presets)
        do {
            try await IngestPresetStore.save(
                IngestPresetSnapshot(presets: next, lastUsedPresetID: nil),
                settings: settings)
            presets = next
            selectedPresetID = ""
            presetError = nil
        } catch {
            presetError = l10n.format(
                "预设保存失败：%@",
                CommandErrorText.resolve(CommandError(error), with: l10n))
        }
    }

    /// 目标路径 / 冲突源样例：每行一条，中间截断，避免长路径撑破 sheet。
    private func samplePathsSection(title: String, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            Text(title)
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(GatherTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    /// 只重试失败项：失败项的 `photoId` 字段就是源路径（runner 的映射口径），
    /// 直接以这些源重跑同一套摄取参数；成功项不会重复复制。
    private func retryFailedItems() async {
        guard let result else { return }
        let paths = IngestPresetStore.retrySourcePaths(from: result)
        guard !paths.isEmpty else {
            errorText = l10n("没有可重试的失败项")
            return
        }
        await run(sourcePathsOverride: paths, isRetryFailed: true)
    }

    /// Wave4a-L1：只读预检（不复制文件、不建 job），结果只用于展示。
    private func runPreview() async {
        guard let sessionAPI = viewModel.sessionAPI else {
            errorText = l10n("摄取未接线（缺少 session API）")
            return
        }
        isPreviewing = true
        errorText = nil
        preview = nil
        defer { isPreviewing = false }
        do {
            let input = try SessionIngestInput(
                sessionId: viewModel.sessionId,
                sourcePaths: sources,
                destinationRoot: destinationRoot,
                renameTemplate: renameTemplate,
                secondDestinationRoot: secondRoot.isEmpty ? nil : secondRoot,
                verifyChecksum: verifyChecksum,
                duplicatePolicy: duplicatePolicy
            )
            preview = try await sessionAPI.previewIngest(input)
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    /// 摄取执行。`sourcePathsOverride` 仅供「只重试失败项」用：不改用户当前选择。
    private func run(sourcePathsOverride: [String]? = nil, isRetryFailed: Bool = false) async {
        isRunning = true
        errorText = nil
        result = nil
        progress = nil
        retryNotice = nil
        startProgressPolling()
        defer {
            progressTask?.cancel()
            progressTask = nil
            isRunning = false
            cancelling = false
        }
        do {
            let input = try SessionIngestInput(
                sessionId: viewModel.sessionId,
                sourcePaths: sourcePathsOverride ?? sources,
                destinationRoot: destinationRoot,
                renameTemplate: renameTemplate,
                secondDestinationRoot: secondRoot.isEmpty ? nil : secondRoot,
                verifyChecksum: verifyChecksum,
                duplicatePolicy: duplicatePolicy
            )
            guard let sessionAPI = viewModel.sessionAPI else {
                errorText = l10n("摄取未接线（缺少 session API）")
                return
            }
            let outcome = try await sessionAPI.ingest(Confirmed(input, source: .userDialog))
            result = outcome
            if isRetryFailed {
                retryNotice = l10n.format("已重试失败项：新增登记 %lld 张", outcome.registered)
            }
            // #11：导入改变会话的照片集合与计数（侧栏/图库都读它），发 .library。
            // 本页动作：带 culling origin，避免挑片页把它当外部变更再整页刷一次（本页随后 loadPage）。
            GatherEventCenter.postDomainChange(
                .library, sessionId: nil, origin: CullingViewModel.changeOrigin)
            await viewModel.loadPage(reset: true)
        } catch {
            if error is any JobCancellationMarker {
                // 取消可能已登记部分照片：不报“未知错误”，并刷新列表让用户看到实况。
                errorText = l10n("已取消摄取；取消前已登记的照片会保留")
                await viewModel.loadPage(reset: true)
            } else {
                errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            }
        }
    }

    /// P1-3：摄取已 Job 化；取消按 session 找活跃 ingest.run 任务，不依赖局部 Task 句柄。
    private func cancelIngest() async {
        cancelling = true
        defer { cancelling = false }
        do {
            guard let job = await activeIngestJob() else {
                // 任务刚好结束/尚未入队：给可见反馈，不能“点了没反应”。
                errorText = l10n("没有进行中的摄取任务")
                return
            }
            _ = try await viewModel.jobAPI.cancel(job.id)
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    /// Wave5（F4）：不支持格式的一行摘要（按扩展名分组；调用方负责本地化）。
    static func unsupportedFormatsText(
        _ formats: IngestUnsupportedFormats, l10n: L10n
    ) -> String {
        let grouped = formats.extensions.sorted { $0.key < $1.key }
            .map { ".\($0.key)×\($0.value)" }
            .joined(separator: "、")
        return l10n.format("不支持格式 %lld 个（%@），已跳过", formats.count, grouped)
    }

    /// Wave5（F4）：样例只显示文件名，不泄漏源目录结构。
    static func sampleFileNames(_ formats: IngestUnsupportedFormats) -> String {
        formats.samplePaths.prefix(3)
            .map { ($0 as NSString).lastPathComponent }
            .joined(separator: "、")
    }

    /// 当前会话活跃的 ingest 任务（摄取复用 checksum.backfill 载体，按 checkpoint 判定）。
    private func activeIngestJob() async -> AnalysisJobData? {
        let jobs: [AnalysisJobData]
        do {
            // isIngestRun 只读 dedupeKey；不需要 checkpoint（导出 job 可达 MB）。
            jobs = try await viewModel.jobAPI.list(JobListFilter(includeCheckpoint: false))
        } catch {
            return nil
        }
        return jobs.first {
            $0.isIngestRun
                && $0.scopeId == viewModel.sessionId
                && [.queued, .running, .cancelling].contains($0.status)
        }
    }

    /// 复制阶段的服务端进度（1000 张以上必须能看到 N/M）。
    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                if let job = await activeIngestJob(), job.progressTotal > 0 {
                    let next = (current: job.progressCurrent, total: job.progressTotal)
                    if progress?.current != next.current || progress?.total != next.total {
                        progress = next
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// 没有根的会话：先修根（与「设置根目录…」同一 API），再回填目标目录。
    private func chooseSessionRoot() {
        guard let api = viewModel.sessionAPI else {
            errorText = l10n("摄取未接线（缺少 session API）")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let session = try await api.setSourceRoot(
                        Confirmed(try SessionSetSourceRootInput(
                            sessionId: viewModel.sessionId, sourceRoot: url.path)))
                    destinationRoot = (session.sourcePath as NSString)
                        .appendingPathComponent("_ingest")
                    rootMissing = false
                    errorText = nil
                } catch {
                    errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
                }
            }
        }
    }

    private func chooseSources() {
        pickPaths(canChooseFiles: true, allowsMultiple: true) { sources = $0 }
    }

    private func chooseDestination() {
        pickPaths(canChooseFiles: false) { if let path = $0.first { destinationRoot = path } }
    }

    private func chooseSecondDestination() {
        pickPaths(canChooseFiles: false) { if let path = $0.first { secondRoot = path } }
    }

    /// 三个选择面板共用：目录必选、文件可选；回调只在用户确认后执行。
    private func pickPaths(
        canChooseFiles: Bool,
        allowsMultiple: Bool = false,
        apply: @escaping ([String]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = allowsMultiple
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in apply(paths) }
        }
    }
}

// MARK: - 导入预设：宿主接缝 + 纯逻辑（Wave5 batch3 / task-19）

/// 导入预设的宿主接缝。
///
/// 为什么是桥而不是参数：GatherUI 不能 import GatherHost；CullingViewModel 也不持有
/// SettingsAPI（为它加一个参数要改 30+ 测试构造点）。宿主在启动装配时注入、
/// 停机时清空；nil = 未接线（单测 / 预览），预设区整体隐藏，不影响摄取主流程。
@MainActor
package enum IngestPresetBridge {
    package static var settings: (any SettingsAPI)?
}

/// 预设持久化快照：数组 + "最近使用"的预设 id（后者只用于下次打开 sheet 回填）。
struct IngestPresetSnapshot: Equatable, Sendable {
    var presets: [IngestPreset]
    var lastUsedPresetID: String?

    init(presets: [IngestPreset] = [], lastUsedPresetID: String? = nil) {
        self.presets = presets
        self.lastUsedPresetID = lastUsedPresetID
    }
}

enum IngestPresetStoreError: Error, Equatable {
    /// 预设数量超过上限（settings value 有 4096 字节上限，UI 也无法无限列）。
    case tooMany
}

/// 导入预设的纯逻辑 + settings 读写。与 UI 解耦，IngestSheetTests 直接驱动。
enum IngestPresetStore {
    /// 预设数量上限：8 条 × 约 400 字节仍远低于 settings value 的 4096 字节上限。
    static let maxPresets = 8
    static let presetsKey = SettingsKey.ingestPresets.rawValue
    static let lastUsedKey = SettingsKey.ingestLastPresetID.rawValue

    /// 解码预设数组：空串/损坏 JSON 一律回退空数组（损坏只记 warn，不阻断面板）。
    static func decodePresets(_ raw: String) -> [IngestPreset] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([IngestPreset].self, from: data)
            return Array(decoded.prefix(maxPresets))
        } catch {
            GatherLogger.log("ingest presets decode failed: \(error)", level: .warn)
            return []
        }
    }

    /// 编码预设数组：排序键保证同一份预设的字符串稳定（便于断言/对比）。
    static func encodePresets(_ presets: [IngestPreset]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(presets)
        } catch {
            GatherLogger.log("ingest presets encode failed: \(error)", level: .warn)
            return "[]"
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            GatherLogger.log("ingest presets encode produced invalid UTF-8", level: .warn)
            return "[]"
        }
        return raw
    }

    static func load(_ settings: any SettingsAPI) async -> IngestPresetSnapshot {
        do {
            let presetsRaw = try await settings.get(SettingsKeyInput(presetsKey))
            let lastRaw = try await settings.get(SettingsKeyInput(lastUsedKey))
            let presets = decodePresets(presetsRaw)
            let last = presets.contains(where: { $0.id == lastRaw }) ? lastRaw : nil
            return IngestPresetSnapshot(presets: presets, lastUsedPresetID: last)
        } catch {
            GatherLogger.log("ingest presets load failed: \(error)", level: .warn)
            return IngestPresetSnapshot()
        }
    }

    static func save(
        _ snapshot: IngestPresetSnapshot, settings: any SettingsAPI
    ) async throws {
        let presetsJSON = encodePresets(snapshot.presets)
        try await settings.set(try SettingsSetInput(key: presetsKey, value: presetsJSON))
        try await saveLastUsed(snapshot.lastUsedPresetID, settings: settings)
    }

    static func saveLastUsed(
        _ presetID: String?, settings: any SettingsAPI
    ) async throws {
        try await settings.set(try SettingsSetInput(
            key: lastUsedKey, value: presetID ?? ""))
    }

    /// 保存当前配置：同名覆盖（保留新传入的 id/字段），否则追加；超过上限抛 tooMany。
    static func upserting(
        _ preset: IngestPreset, in presets: [IngestPreset]
    ) throws -> [IngestPreset] {
        if let index = presets.firstIndex(where: { $0.name == preset.name }) {
            var next = presets
            next[index] = preset
            return next
        }
        guard presets.count < maxPresets else { throw IngestPresetStoreError.tooMany }
        return presets + [preset]
    }

    static func removing(id: String, from presets: [IngestPreset]) -> [IngestPreset] {
        presets.filter { $0.id != id }
    }

    /// 当前字段是否仍等于某条预设（用于"手动改字段后切回自定义"判定）。
    static func matches(
        _ preset: IngestPreset,
        renameTemplate: String,
        secondDestinationRoot: String?,
        verifyChecksum: Bool,
        duplicatePolicy: IngestDuplicatePolicy
    ) -> Bool {
        preset.renameTemplate == renameTemplate
            && (preset.secondDestinationRoot ?? "") == (secondDestinationRoot ?? "")
            && preset.verifyChecksum == verifyChecksum
            && preset.duplicatePolicy == duplicatePolicy
    }

    /// 「只重试失败项」：摄取失败项的 `photoId` 字段就是源路径（runner 的映射口径），
    /// 去重保序返回，空 id 过滤掉。
    static func retrySourcePaths(from result: SessionIngestResult) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for failure in result.failed where !failure.photoId.isEmpty {
            if seen.insert(failure.photoId).inserted { paths.append(failure.photoId) }
        }
        return paths
    }
}
