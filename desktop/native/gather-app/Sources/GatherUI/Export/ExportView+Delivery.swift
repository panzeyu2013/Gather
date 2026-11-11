// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Delivery.swift
// W3：整套交付区（配方列表 + 联系表开关 + 运行 + 结果/打印）。
// P0-6（Wave2）：配方编辑器（OutputRecipe 全部输出参数可改）与联系表/画廊参数可配；
// 新增的编辑器控件只写 ExportViewModel 的 update 系列方法，落盘仍走 output.recipes 通道。
import AppKit
import SwiftUI
import GatherProtocol

struct PendingDeliveryConfirmation: Identifiable {
    let id = UUID()
    let input: OutputRunInput
    let preflight: DeliveryPreflightSummary
}

/// 校样导入结果（sheet item 包装：报告本身不带 id）。
struct PendingProofImport: Identifiable {
    let id = UUID()
    let report: ClientSelectionImportReport
}

/// Wave5：独立发布目标（本地已生成目录 + 顶层产物白名单）。
struct StandalonePublishSelection: Identifiable {
    let id = UUID()
    let localPath: String
    let includePrefixes: [String]
}

struct ExportDeliverySection: View {
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    @State private var showWebDAV = false
    /// Wave5：独立发布入口（不依赖本次交付内存结果）。
    @State private var standalonePublish: StandalonePublishSelection?
    @State private var pendingDelivery: PendingDeliveryConfirmation?
    /// 校样导入结果（v2：勾选 + 评分/色标 + 评论 + 冲突）。
    @State private var pendingProofImport: PendingProofImport?
    /// 最近一次导入报告（sheet 关闭后摘要行仍要能显示；不随 sheet 消失）。
    @State private var lastImportReport: ClientSelectionImportReport?
    // Wave2：联系表/画廊参数随配方持久化（OutputRecipe.contactSheet/gallery），
    // 页面不再持有 run 级草稿状态。
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        Section(l10n("整套交付")) {
            HStack(spacing: GatherMetrics.Space.s) {
                TextField(
                    "",
                    text: Binding(
                        get: { viewModel.deliveryRoot },
                        set: { viewModel.deliveryRoot = $0 }),
                    prompt: Text(l10n("交付目录")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button(l10n("选择…")) { chooseDeliveryRoot() }
                    .gatherButton(.secondary, size: .small)
            }

            ForEach(viewModel.deliveryRecipes) { recipe in
                DeliveryRecipeRow(viewModel: viewModel, recipe: recipe)
            }
            // Wave2：联系表/画廊是**配方级**产物开关（见每个配方编辑器），
            // 页面级不再有"包含联系表/画廊"的全局开关。
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("添加配方")) { viewModel.addDeliveryRecipe() }
                    .gatherButton(.tertiary)
                Spacer()
                if viewModel.isDelivering {
                    Button(l10n("取消交付")) {
                        Task { await viewModel.cancelDelivery() }
                    }
                    .gatherButton(.secondary)
                }
                Button(viewModel.isDelivering
                       ? l10n("正在交付…")
                       : viewModel.isPreflighting ? l10n("正在预检…") : l10n("开始整套交付")) {
                    Task {
                        if let input = await viewModel.prepareDeliveryInput() {
                            let preflight = await viewModel.deliveryPreflight(for: input)
                            pendingDelivery = PendingDeliveryConfirmation(
                                input: input, preflight: preflight)
                        }
                    }
                }
                // 页面唯一 primary 在工具栏「开始导出」；整套交付是独立工作流，
                // 用 secondary 让用户先选主路径，避免同页两个实心 CTA 竞争。
                .gatherButton(.secondary)
                // 交付与单张导出共用会话级取消：运行期间互斥，避免互相误杀。
                .disabled(viewModel.isDelivering || viewModel.isExporting
                          || viewModel.isPreflighting || viewModel.deliveryRecipes.isEmpty)
                .sheet(item: $pendingDelivery) { pending in
                    DeliveryConfirmSheet(input: pending.input, preflight: pending.preflight) { input in
                        // 确认分支：Confirmed 只在这里构造（D-011）。
                        Task {
                            await viewModel.executeDelivery(
                                Confirmed(input, source: .userDialog))
                        }
                    }
                }
            }
            if let progress = viewModel.deliveryProgress {
                // 长交付此前只有"正在交付…"按钮文案，像卡死；这里给进度 + 相位。
                HStack(spacing: GatherMetrics.Space.s) {
                    ProgressView(
                        value: Double(progress.current),
                        total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text(l10n.progressPhaseText(viewModel.deliveryPhase))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                    Text("\(progress.current)/\(progress.total)")
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if viewModel.cullingAPI != nil {
                HStack(spacing: GatherMetrics.Space.s) {
                    Button(viewModel.isImportingSelection
                           ? l10n("正在导入…") : l10n("导入客户反馈…")) {
                        importSelection()
                    }
                    .gatherButton(.secondary, size: .small)
                    .disabled(viewModel.isImportingSelection)
                    if let report = lastImportReport {
                        Text(Self.importSummaryText(report, with: l10n))
                            .font(GatherFont.secondary)
                            .foregroundStyle(report.failed > 0 || !report.conflicts.isEmpty
                                ? GatherTheme.errorText : GatherTheme.secondaryText)
                    } else if let imported = viewModel.clientSelectionImport {
                        // 兼容：本轮之前导入过（没有完整报告）时仍显示 v1 摘要。
                        Text(l10n.format("已导入 %lld 张（跳过 %lld，失败 %lld）",
                                         imported.applied, imported.skipped, imported.failed))
                            .font(GatherFont.secondary)
                            .foregroundStyle(imported.failed > 0
                                ? GatherTheme.errorText : GatherTheme.secondaryText)
                    }
                }
                .sheet(item: $pendingProofImport) { pending in
                    ProofImportResultSheet(report: pending.report)
                }
            }
            if let summary = viewModel.deliverySummary {
                deliveryResult(summary)
                HStack(spacing: GatherMetrics.Space.s) {
                    Button(l10n("发布到 WebDAV…")) { showWebDAV = true }
                        .gatherButton(.secondary, size: .small)
                        .disabled(viewModel.isPublishing)
                    if let publish = viewModel.webDAVPublish {
                        SharePublishResultView(publish: publish)
                    }
                }
                .sheet(isPresented: $showWebDAV) {
                    // 只发布本次交付的**精确产物**（白名单必填）：各配方成品 + 联系表 +
                    // 画廊目录；manifest 不在其中（含本机绝对路径，见 publishPrefixes）。
                    // allowDownload 由面板决定是否再加 large/成片。
                    WebDAVPublishSheet(
                        viewModel: viewModel,
                        localPath: URL(fileURLWithPath: summary.manifestPath)
                            .deletingLastPathComponent().path,
                        includePrefixes: Self.publishPrefixes(for: summary))
                }
            }
            // Wave5：独立发布入口——不依赖本次交付的内存结果；选任意已生成目录即可
            // 重新发布（读取该目录的发布记录做 HEAD 差分/历史）。
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("发布已生成的交付包…")) { chooseStandalonePublish() }
                    .gatherButton(.secondary, size: .small)
                    .disabled(viewModel.isPublishing)
                Spacer()
            }
            .sheet(item: $standalonePublish) { selection in
                WebDAVPublishSheet(
                    viewModel: viewModel,
                    localPath: selection.localPath,
                    includePrefixes: selection.includePrefixes,
                    standalone: true)
            }
        }
        .task { await viewModel.loadDeliveryRecipes() }
        .onChange(of: viewModel.deliveryRecipes) { _, _ in
            viewModel.schedulePersistDeliveryRecipes()
        }
        .onChange(of: viewModel.deliveryRoot) { _, _ in
            viewModel.persistDeliveryRoot()
        }
    }

    /// Wave5：独立发布——选择本地已生成的交付/画廊目录，交给同一发布面板。
    private func chooseStandalonePublish() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = l10n("选择已生成的交付目录（例如 gallery 目录）")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let prefixes = Self.publishPrefixes(forLocalDirectory: url.path)
            Task { @MainActor in
                guard !prefixes.isEmpty else {
                    viewModel.errorMessage = CommandError.localized("这个目录里没有可发布的文件")
                    return
                }
                standalonePublish = StandalonePublishSelection(
                    localPath: url.path, includePrefixes: prefixes)
            }
        }
    }

    /// Wave5：独立发布的白名单 = 目录顶层条目（文件/目录名）。
    ///
    /// 跳过隐藏文件（含 `.gather-share-publish.json` 发布记录）与 `manifest-*`
    /// （manifest 含本机绝对路径，按既有约定绝不外发）。
    static func publishPrefixes(forLocalDirectory path: String) -> [String] {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return []
        }
        return entries.filter { name in
            if name.hasPrefix(".") { return false }
            if name.hasPrefix("manifest") { return false }
            return true
        }.sorted()
    }

    /// 选择交付目录（异步面板：不阻塞主线程、不开嵌套 runloop）。
    private func chooseDeliveryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in viewModel.deliveryRoot = url.path }
        }
    }

    /// 选择 selection.json → 交给 VM（解析与落决策都在服务端）。
    private func importSelection() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // 异步面板：runModal 会阻塞主线程并开嵌套 runloop（本仓已弃用）。
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let json = await Task.detached(priority: .userInitiated) {
                    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
                }.value
                guard let json else { return }
                if let report = await viewModel.importClientSelection(json: json) {
                    lastImportReport = report
                    pendingProofImport = PendingProofImport(report: report)
                }
            }
        }
    }

    /// 本次交付的发布白名单（精确产物；**永不返回 nil**）。
    ///
    /// 旧实现"拿不准就返回 nil"，而 nil 等于「上传整个 run 根目录」——历史 manifest、
    /// 成片目录、用户放在交付根里的杂物会一起上服务器。现在的规则：
    /// - 每张成品按 manifest.files 精确列出（含联系表）；
    /// - 画廊只给目录前缀（thumbs/large/html/css/js/data.json 全在里面）；
    /// - manifest（OutputRunSummary）**不进**白名单：它含本机绝对路径
    ///   （manifestPath、每配方 destination、contactSheetPath），只用于本地审计；
    ///   上传等于把摄影师的目录结构暴露给客户/审计（D2 回退）。
    ///   如需给客户看"交付了什么"，另生成脱敏副本再发布（后续任务，不能在
    ///   这里直接传原始 manifest）；
    /// - 落不到 run 根下的配方**直接跳过**，绝不退化成整根目录；
    /// - 结果为空 = 上层禁用发布按钮（面板里给原因），而不是"发整个目录"。
    static func publishPrefixes(for summary: OutputRunSummary) -> [String] {
        let root = URL(fileURLWithPath: summary.manifestPath)
            .deletingLastPathComponent().standardizedFileURL.path
        // 合并前这里有一条注释明确写着"manifest 含本机绝对路径，不进发布白名单"；
        // feat 合入时被反过来（无条件 insert 了 manifest 文件名）且注释被删。
        // 现在恢复原判定与理由：白名单只收**可公开的成片/画廊产物**。
        var paths: Set<String> = []
        for recipe in summary.recipes {
            let destination = URL(fileURLWithPath: recipe.destination).standardizedFileURL.path
            let prefix: String
            if destination == root {
                prefix = ""
            } else if destination.hasPrefix(root + "/") {
                prefix = String(destination.dropFirst(root.count + 1))
            } else {
                // 配方写到 run 根之外：不猜，跳过（宁少传不误传）。
                continue
            }
            for file in recipe.files ?? [] {
                paths.insert(prefix.isEmpty ? file.name : prefix + "/" + file.name)
            }
            if let gallery = recipe.galleryPath {
                let galleryDir = URL(fileURLWithPath: gallery)
                    .deletingLastPathComponent().standardizedFileURL.path
                if galleryDir == root {
                    paths.insert("gallery")
                } else if galleryDir.hasPrefix(root + "/") {
                    paths.insert(String(galleryDir.dropFirst(root.count + 1)))
                }
            }
        }
        return paths.sorted()
    }

    private func deliveryResult(_ summary: OutputRunSummary) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Text(l10n.format("交付完成：成功 %lld，失败 %lld",
                             summary.totalExported, summary.totalFailed))
                .font(GatherFont.labelRegular)
                .foregroundStyle(summary.totalFailed > 0 ? GatherTheme.errorText : GatherTheme.successText)
            ForEach(summary.recipes, id: \.recipeId) { recipe in
                HStack(spacing: GatherMetrics.Space.s) {
                    Text(recipe.name).font(GatherFont.secondary)
                    Text(l10n.format("%lld 张", recipe.exported))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                    Button(l10n("在 Finder 中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: recipe.destination)])
                    }
                    .gatherButton(.tertiary, size: .small)
                    if let sheet = recipe.contactSheetPath {
                        Button(l10n("打印联系表")) {
                            if !PrintSupport.printPDF(at: sheet, jobTitle: recipe.name) {
                                viewModel.errorMessage = CommandError.localized("无法打开联系表 PDF")
                            }
                        }
                        .gatherButton(.tertiary, size: .small)
                    }
                    if let gallery = recipe.galleryPath {
                        Button(l10n("打开画廊")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: gallery))
                        }
                        .gatherButton(.tertiary, size: .small)
                    }
                }
                if let first = recipe.errors.first {
                    // 错误串由 ExportService+Run 拼成 "<文件名>: CODE: 散文"；
                    // 直接上屏会把英文码丢给用户，码段必须过 L10n。
                    Text(Self.deliveryErrorText(first, with: l10n))
                        .font(GatherFont.secondary).foregroundStyle(GatherTheme.errorText)
                }
            }
            Text(summary.manifestPath)
                .font(GatherFont.secondary)
                .foregroundStyle(summary.manifestError == nil ? .secondary : GatherTheme.errorText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if summary.manifestError != nil {
                Text(l10n("交付清单写入失败，但成片已写出。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
            }
        }
    }

    /// 交付项错误串 → 本地化文案。
    ///
    /// ExportService+Run 拼的是 "<文件名>: CODE: 散文"；直接上屏会把英文码丢给用户。
    /// 这里只拆第一段冒号（文件名），其余整段交给 L10n 解析 "CODE: 散文" 形态。
    static func deliveryErrorText(_ raw: String, with l10n: L10n) -> String {
        guard let colon = raw.firstIndex(of: ":") else { return l10n.errorText(raw) }
        let file = raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return file }
        return file + "：" + l10n.errorText(rest)
    }
}

/// 单个交付配方的编辑器（P0-6）。
///
/// 旧实现每个配方只有「名字 + 格式」两个可写控件，质量/长边/水印/命名/子目录/
/// 色彩空间/DPI/锐化全部不可设；这里把 OutputRecipe 的全部字段摆出来，写回统一走
/// ExportViewModel 的 update 系列方法（落盘仍由交付区的 .onChange 防抖触发）。
private struct DeliveryRecipeRow: View {
    let viewModel: ExportViewModel
    let recipe: OutputRecipe
    @Environment(\.languageStore) private var languageStore
    @State private var isExpanded = false
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    private var issues: [String] { viewModel.deliveryRecipeIssues(recipe) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            editor
                .padding(.top, GatherMetrics.Space.xs)
        } label: {
            header
        }
    }

    // MARK: - 行头（摘要 + 名字/格式/删除）

    private var header: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            HStack(spacing: GatherMetrics.Space.s) {
                TextField(l10n("配方名"), text: Binding(
                    get: { recipe.name },
                    set: { newValue in
                        viewModel.updateDeliveryRecipe(id: recipe.id) { $0.name = newValue }
                    }))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80, idealWidth: 150, maxWidth: 180)
                Picker("", selection: Binding(
                    get: { recipe.format },
                    set: { newValue in
                        viewModel.setDeliveryRecipeFormat(id: recipe.id, format: newValue)
                    })) {
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF").tag(ExportFormat.tiff)
                    Text(l10n("原图")).tag(ExportFormat.original)
                }
                .labelsHidden()
                .frame(width: 72)
                Spacer(minLength: 4)
                if !issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GatherTheme.errorText)
                        .help(l10n(issues[0]))
                        .accessibilityLabel(l10n("配方参数有误"))
                }
                Button(role: .destructive) {
                    viewModel.removeDeliveryRecipe(id: recipe.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(l10n("删除配方"))
            }
            Text(summaryText)
                .font(GatherFont.secondary)
                .foregroundStyle(issues.isEmpty ? GatherTheme.secondaryText : GatherTheme.errorText)
                .lineLimit(2)
        }
    }

    /// 摘要：一行说清该配方的输出规格（出问题时直接显示第一条中文原因）。
    private var summaryText: String {
        guard issues.isEmpty else { return l10n(issues[0]) }
        var parts: [String] = []
        switch recipe.format {
        case .jpeg: parts.append("JPEG")
        case .tiff: parts.append("TIFF")
        case .original: parts.append(l10n("原图"))
        }
        if let quality = recipe.quality {
            parts.append(l10n.format("质量 %lld", Int(quality.rounded())))
        }
        if let dimension = recipe.maxDimension {
            parts.append(l10n.format("长边 %lld", dimension))
        }
        if let colorSpace = recipe.colorSpace {
            switch colorSpace {
            case .sRGB: parts.append("sRGB")
            case .displayP3: parts.append("Display P3")
            case .adobeRGB1998: parts.append("Adobe RGB (1998)")
            }
        }
        if let dpi = recipe.dpi { parts.append("\(dpi) DPI") }
        if recipe.sharpening != nil { parts.append(l10n("输出锐化")) }
        if let watermark = recipe.watermark {
            parts.append(watermark.type == .text ? l10n("文字水印") : l10n("图片水印"))
        }
        // Wave2：子目录规则是 token 模板（{yyyy}/{MM}/{dd}/{client}/{event}/{orig}）。
        if let subdirectory = recipe.subdirectory, !subdirectory.template.isEmpty {
            parts.append(l10n.format("子目录 %@", subdirectory.template))
        }
        if recipe.artifacts.contains(.contactSheet) { parts.append(l10n("含联系表")) }
        if recipe.artifacts.contains(.gallery) { parts.append(l10n("含画廊")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 编辑器

    private var editor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            if recipe.format == .jpeg {
                SliderInputIntView(
                    title: l10n("JPEG 质量"),
                    value: Binding(
                        get: { Int((recipe.quality ?? 85).rounded()) },
                        set: { newValue in
                            viewModel.updateDeliveryRecipe(id: recipe.id) {
                                $0.quality = Double(newValue)
                            }
                        }),
                    range: 1...100)
            }
            if recipe.format != .original {
                transformEditor
            }
            namingEditor
            subdirectoryEditor
            artifactsEditor
            Toggle(l10n("复制 XMP 附属文件"), isOn: Binding(
                get: { recipe.includeXmp },
                set: { newValue in
                    viewModel.updateDeliveryRecipe(id: recipe.id) { $0.includeXmp = newValue }
                }))
            Toggle(l10n("携带评分与关键词等元数据"), isOn: Binding(
                get: { recipe.includeMetadata },
                set: { newValue in
                    viewModel.updateDeliveryRecipe(id: recipe.id) {
                        $0.includeMetadata = newValue
                    }
                }))
        }
    }

    /// 转换类参数：最长边 / 色彩空间 / DPI / 输出锐化 / 文字水印。
    /// 原图格式（字节复制）下整组隐藏 —— 与 ExportService.validate 的拒绝口径一致。
    private var transformEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Toggle(l10n("限制最长边"), isOn: Binding(
                get: { recipe.maxDimension != nil },
                set: { isOn in
                    viewModel.updateDeliveryRecipe(id: recipe.id) {
                        $0.maxDimension = isOn ? 2048 : nil
                    }
                }))
            if recipe.maxDimension != nil {
                SliderInputIntView(
                    title: l10n("最长边"),
                    value: Binding(
                        get: { recipe.maxDimension ?? 2048 },
                        set: { newValue in
                            viewModel.updateDeliveryRecipe(id: recipe.id) {
                                $0.maxDimension = newValue
                            }
                        }),
                    range: 256...8192)
            }
            LabeledContent(l10n("色彩空间")) {
                Picker(l10n("色彩空间"), selection: Binding<ExportColorSpace?>(
                    get: { recipe.colorSpace },
                    set: { newValue in
                        viewModel.updateDeliveryRecipe(id: recipe.id) {
                            $0.colorSpace = newValue
                        }
                    })) {
                    Text(l10n("不转换")).tag(ExportColorSpace?.none)
                    Text("sRGB").tag(Optional(ExportColorSpace.sRGB))
                    Text("Display P3").tag(Optional(ExportColorSpace.displayP3))
                    Text("Adobe RGB (1998)").tag(Optional(ExportColorSpace.adobeRGB1998))
                }
                .labelsHidden()
            }
            Toggle(l10n("写入 DPI"), isOn: Binding(
                get: { recipe.dpi != nil },
                set: { isOn in
                    viewModel.updateDeliveryRecipe(id: recipe.id) {
                        $0.dpi = isOn ? 300 : nil
                    }
                }))
            if recipe.dpi != nil {
                SliderInputIntView(
                    title: l10n("DPI"),
                    value: Binding(
                        get: { recipe.dpi ?? 300 },
                        set: { newValue in
                            viewModel.updateDeliveryRecipe(id: recipe.id) {
                                $0.dpi = newValue
                            }
                        }),
                    range: 72...1200)
            }
            Toggle(l10n("输出锐化"), isOn: Binding(
                get: { recipe.sharpening != nil },
                set: { isOn in
                    viewModel.updateDeliveryRecipe(id: recipe.id) {
                        $0.sharpening = isOn
                            ? ExportSharpening(radius: 1, intensity: 0.5)
                            : nil
                    }
                }))
            if recipe.sharpening != nil {
                SliderInputView(
                    title: l10n("锐化半径"),
                    value: Binding(
                        get: { recipe.sharpening?.radius ?? 1 },
                        set: { newValue in
                            viewModel.updateDeliverySharpening(id: recipe.id) {
                                $0.radius = newValue
                            }
                        }),
                    range: 0.5...3, step: 0.5)
                SliderInputView(
                    title: l10n("锐化强度"),
                    value: Binding(
                        get: { recipe.sharpening?.intensity ?? 0.5 },
                        set: { newValue in
                            viewModel.updateDeliverySharpening(id: recipe.id) {
                                $0.intensity = newValue
                            }
                        }),
                    range: 0.1...1.5, step: 0.1)
            }
            watermarkEditor
        }
    }

    /// 配方级水印（Wave2）：文字 / 图片 logo 两种类型，共享位置与透明度。
    private var watermarkEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Toggle(l10n("水印"), isOn: Binding(
                get: { recipe.watermark != nil },
                set: { isOn in
                    viewModel.updateDeliveryRecipe(id: recipe.id) {
                        $0.watermark = isOn
                            ? ExportWatermark(
                                type: .text, content: "", position: .bottomRight,
                                opacity: 0.5, fontSize: 24)
                            : nil
                    }
                }))
            if let watermark = recipe.watermark {
                LabeledContent(l10n("水印类型")) {
                    Picker(l10n("水印类型"), selection: Binding(
                        get: { watermark.type },
                        set: { newType in
                            viewModel.updateDeliveryRecipe(id: recipe.id) { target in
                                guard var value = target.watermark,
                                      value.type != newType else { return }
                                value.type = newType
                                if newType == .image {
                                    value.imageScale = value.imageScale ?? 0.2
                                    value.imageMargin = value.imageMargin ?? 0.02
                                } else {
                                    value.fontSize = value.fontSize ?? 24
                                }
                                target.watermark = value
                            }
                        })) {
                        Text(l10n("文字")).tag(ExportWatermarkType.text)
                        Text(l10n("图片 logo")).tag(ExportWatermarkType.image)
                    }
                    .labelsHidden()
                }
                if watermark.type == .text {
                    TextField(l10n("水印文字"), text: Binding(
                        get: { watermark.content },
                        set: { newValue in
                            viewModel.updateDeliveryWatermark(id: recipe.id) {
                                $0.content = newValue
                            }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(l10n("水印文字"))
                    SliderInputIntView(
                        title: l10n("字号"),
                        value: Binding(
                            get: { Int((watermark.fontSize ?? 24).rounded()) },
                            set: { newValue in
                                viewModel.updateDeliveryWatermark(id: recipe.id) {
                                    $0.fontSize = Double(newValue)
                                }
                            }),
                        range: 8...200)
                } else {
                    LabeledContent(l10n("水印图片")) {
                        HStack(spacing: GatherMetrics.Space.s) {
                            TextField(l10n("水印图片"), text: Binding(
                                get: { watermark.content },
                                set: { newValue in
                                    viewModel.updateDeliveryWatermark(id: recipe.id) {
                                        $0.content = newValue
                                    }
                                }))
                                .labelsHidden()
                                .accessibilityLabel(l10n("水印图片"))
                            Button(l10n("选择…")) {
                                Task {
                                    guard let path = await viewModel.chooseWatermarkImage(with: l10n)
                                    else { return }
                                    viewModel.updateDeliveryWatermark(id: recipe.id) {
                                        $0.content = path
                                    }
                                }
                            }
                            .gatherButton(.secondary, size: .small)
                        }
                    }
                    Text(l10n("建议使用带透明背景的 PNG logo"))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                    SliderInputView(
                        title: l10n("宽度比例"),
                        value: Binding(
                            get: { watermark.imageScale ?? 0.2 },
                            set: { newValue in
                                viewModel.updateDeliveryWatermark(id: recipe.id) {
                                    $0.imageScale = newValue
                                }
                            }),
                        range: 0.02...1, step: 0.01)
                    SliderInputView(
                        title: l10n("边距"),
                        value: Binding(
                            get: { watermark.imageMargin ?? 0.02 },
                            set: { newValue in
                                viewModel.updateDeliveryWatermark(id: recipe.id) {
                                    $0.imageMargin = newValue
                                }
                            }),
                        range: 0...0.25, step: 0.005)
                }
                LabeledContent(l10n("位置")) {
                    Picker(l10n("位置"), selection: Binding(
                        get: { watermark.position },
                        set: { newValue in
                            viewModel.updateDeliveryWatermark(id: recipe.id) {
                                $0.position = newValue
                            }
                        })) {
                        Text(l10n("居中")).tag(ExportWatermarkPosition.center)
                        Text(l10n("右下")).tag(ExportWatermarkPosition.bottomRight)
                        Text(l10n("左下")).tag(ExportWatermarkPosition.bottomLeft)
                    }
                    .labelsHidden()
                }
                SliderInputView(
                    title: l10n("透明度"),
                    value: Binding(
                        get: { watermark.opacity },
                        set: { newValue in
                            viewModel.updateDeliveryWatermark(id: recipe.id) {
                                $0.opacity = newValue
                            }
                        }),
                    range: 0.1...1, step: 0.1)
            }
        }
    }

    private var namingEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            LabeledContent(l10n("命名模式")) {
                TextField(
                    l10n("命名模式"),
                    text: Binding(
                        get: { recipe.naming.pattern },
                        set: { newValue in
                            viewModel.updateDeliveryNaming(id: recipe.id) {
                                $0.pattern = newValue
                            }
                        }),
                    prompt: Text("{original}"))
                    .labelsHidden()
            }
            Text(l10n("可用占位符：{date} {time} {counter} {original} {filename} {session}"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
        }
    }

    /// 输出子目录规则（Wave2）：token 模板 + {client}/{event} 取值，逐张解析。
    private var subdirectoryEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            LabeledContent(l10n("子目录规则")) {
                TextField(
                    l10n("子目录规则"),
                    text: Binding(
                        get: { recipe.subdirectory?.template ?? "" },
                        set: { newValue in
                            viewModel.setDeliverySubdirectoryTemplate(
                                id: recipe.id, template: newValue)
                        }),
                    prompt: Text("{yyyy}/{MM}/{dd}"))
                    .labelsHidden()
                    .accessibilityLabel(l10n("子目录规则"))
            }
            if let subdirectory = recipe.subdirectory,
               !subdirectory.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LabeledContent(l10n("客户名称")) {
                    TextField(
                        l10n("客户名称"),
                        text: Binding(
                            get: { subdirectory.client ?? "" },
                            set: { newValue in
                                viewModel.updateDeliverySubdirectory(id: recipe.id) {
                                    $0.client = newValue
                                }
                            }))
                        .labelsHidden()
                        .accessibilityLabel(l10n("客户名称"))
                }
                LabeledContent(l10n("活动名称")) {
                    TextField(
                        l10n("活动名称"),
                        text: Binding(
                            get: { subdirectory.event ?? "" },
                            set: { newValue in
                                viewModel.updateDeliverySubdirectory(id: recipe.id) {
                                    $0.event = newValue
                                }
                            }))
                        .labelsHidden()
                        .accessibilityLabel(l10n("活动名称"))
                }
                if let preview = subdirectory.resolved(originalFilename: "IMG_1234.NEF") {
                    Text(l10n.format("示例：%@", preview))
                        .font(GatherFont.secondary.monospaced())
                        .foregroundStyle(GatherTheme.secondaryText)
                }
            }
            Text(l10n("留空 = 直接写到导出目录；可用 token：{yyyy} {MM} {dd} {client} {event} {orig}"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
        }
    }

    // MARK: - 配方级产物（Wave2：联系表/画廊参数随配方保存）

    private func artifactBinding(_ kind: OutputArtifactKind) -> Binding<Bool> {
        Binding(
            get: { recipe.artifacts.contains(kind) },
            set: { isOn in
                viewModel.setDeliveryRecipeArtifact(id: recipe.id, kind, isEnabled: isOn)
            })
    }

    private var artifactsEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Toggle(l10n("生成联系表"), isOn: artifactBinding(.contactSheet))
            if recipe.artifacts.contains(.contactSheet) {
                contactSheetEditor
            }
            Toggle(l10n("生成 Web 画廊"), isOn: artifactBinding(.gallery))
            if recipe.artifacts.contains(.gallery) {
                galleryEditor
            }
        }
    }

    /// 联系表参数（配方级）：标题/副标题/页脚/行列/边距/caption 模板/展示字段。
    private var contactSheetEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n("联系表参数"))
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
            textRow(l10n("标题"), text: contactSheetText(\.title), prompt: l10n("留空使用工作区名"))
            textRow(l10n("副标题"), text: contactSheetText(\.subtitle))
            textRow(l10n("页脚"), text: contactSheetText(\.footer))
            SliderInputIntView(
                title: l10n("列数"), value: contactSheetInt(\.columns), range: 1...12)
            SliderInputIntView(
                title: l10n("行数"), value: contactSheetInt(\.rows), range: 1...20)
            SliderInputView(
                title: l10n("页面边距"), value: contactSheetDouble(\.margin), range: 0...200, step: 1)
            textRow(l10n("Caption 模板"), text: contactSheetText(\.captionTemplate),
                    prompt: "{filename}")
            Text(l10n("可用占位符：{filename} {title} {rating} {label} {keywords} {date}"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            contactSheetFieldsEditor
            Toggle(l10n("显示色标圆点"), isOn: contactSheetToggle(\.showLabelChip))
            Toggle(l10n("显示取舍边框"), isOn: contactSheetToggle(\.showPickBorder))
        }
    }

    private var contactSheetFieldsEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            Text(l10n("联系表字段"))
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                alignment: .leading,
                spacing: GatherMetrics.Space.xxs
            ) {
                contactSheetFieldToggle(.filename, l10n("文件名"))
                contactSheetFieldToggle(.title, l10n("标题"))
                contactSheetFieldToggle(.rating, l10n("评分"))
                contactSheetFieldToggle(.label, l10n("色标"))
                contactSheetFieldToggle(.pick, l10n("取舍"))
                contactSheetFieldToggle(.keywords, l10n("关键词"))
                contactSheetFieldToggle(.captureTime, l10n("拍摄时间"))
                contactSheetFieldToggle(.triage, l10n("三档建议"))
            }
        }
    }

    /// 画廊参数（配方级）：标题/副标题/页脚/缩略图与大图长边/展示字段。
    private var galleryEditor: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n("画廊参数"))
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
            textRow(l10n("标题"), text: galleryText(\.title), prompt: l10n("留空使用工作区名"))
            textRow(l10n("副标题"), text: galleryText(\.subtitle))
            textRow(l10n("页脚"), text: galleryText(\.footer))
            SliderInputIntView(
                title: l10n("缩略图长边"),
                value: galleryInt(\.thumbnailMaxDimension), range: 160...2048)
            SliderInputIntView(
                title: l10n("大图长边"),
                value: galleryInt(\.largeMaxDimension), range: 320...8192)
            VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                Text(l10n("画廊字段"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
                galleryFieldToggle(.rating, l10n("星级"))
                galleryFieldToggle(.label, l10n("色标"))
                galleryFieldToggle(.pick, l10n("取舍"))
            }
        }
    }

    // MARK: - 配方字段 Binding（nil = 默认参数，编辑时物化）

    private func contactSheetText(
        _ keyPath: WritableKeyPath<OutputContactSheetOptions, String>
    ) -> Binding<String> {
        Binding(
            get: { (recipe.contactSheet ?? OutputContactSheetOptions())[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateDeliveryContactSheet(id: recipe.id) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func contactSheetInt(
        _ keyPath: WritableKeyPath<OutputContactSheetOptions, Int>
    ) -> Binding<Int> {
        Binding(
            get: { (recipe.contactSheet ?? OutputContactSheetOptions())[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateDeliveryContactSheet(id: recipe.id) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func contactSheetDouble(
        _ keyPath: WritableKeyPath<OutputContactSheetOptions, Double?>
    ) -> Binding<Double> {
        Binding(
            get: { (recipe.contactSheet ?? OutputContactSheetOptions())[keyPath: keyPath] ?? 36 },
            set: { newValue in
                viewModel.updateDeliveryContactSheet(id: recipe.id) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func contactSheetToggle(
        _ keyPath: WritableKeyPath<OutputContactSheetOptions, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { (recipe.contactSheet ?? OutputContactSheetOptions())[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateDeliveryContactSheet(id: recipe.id) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func contactSheetFieldToggle(
        _ field: ContactSheetFields, _ title: String
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { (recipe.contactSheet ?? OutputContactSheetOptions()).fields.contains(field) },
            set: { isOn in
                viewModel.updateDeliveryContactSheet(id: recipe.id) {
                    if isOn {
                        $0.fields.insert(field)
                    } else {
                        $0.fields.remove(field)
                    }
                }
            }))
    }

    private func galleryText(
        _ keyPath: WritableKeyPath<OutputGalleryOptions, String>
    ) -> Binding<String> {
        Binding(
            get: { (recipe.gallery ?? OutputGalleryOptions())[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateDeliveryGallery(id: recipe.id) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func galleryInt(
        _ keyPath: WritableKeyPath<OutputGalleryOptions, Int>
    ) -> Binding<Int> {
        Binding(
            get: { (recipe.gallery ?? OutputGalleryOptions())[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateDeliveryGallery(id: recipe.id) {
                    $0[keyPath: keyPath] = newValue
                }
            })
    }

    private func galleryFieldToggle(
        _ field: ContactSheetFields, _ title: String
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { (recipe.gallery ?? OutputGalleryOptions()).fields.contains(field) },
            set: { isOn in
                viewModel.updateDeliveryGallery(id: recipe.id) {
                    if isOn {
                        $0.fields.insert(field)
                    } else {
                        $0.fields.remove(field)
                    }
                }
            }))
    }

    /// 表单行：左标签 + 圆角输入框（与导出页的 LabeledContent 行保持一致）。
    private func textRow(
        _ title: String, text: Binding<String>, prompt: String? = nil
    ) -> some View {
        LabeledContent(title) {
            TextField("", text: text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}

/// 校样导入摘要（单行；徽标与 sheet 共用同一口径）。
extension ExportDeliverySection {
    static func importSummaryText(
        _ report: ClientSelectionImportReport, with l10n: L10n
    ) -> String {
        if report.alreadyImported {
            return l10n("这份反馈之前已导入过，未做任何修改")
        }
        var parts: [String] = [
            l10n.format("已导入 %lld 张（跳过 %lld，失败 %lld）",
                        report.applied, report.skipped, report.failed),
        ]
        if report.ratingApplied > 0 {
            parts.append(l10n.format("评分 %lld", report.ratingApplied))
        }
        if report.labelApplied > 0 {
            parts.append(l10n.format("色标 %lld", report.labelApplied))
        }
        if report.comments > 0 {
            parts.append(l10n.format("评论 %lld", report.comments))
        }
        if !report.conflicts.isEmpty {
            parts.append(l10n.format("冲突 %lld", report.conflicts.count))
        }
        return parts.joined(separator: " · ")
    }
}

/// 客户校样导入结果：勾选数、评分/色标/评论数、冲突列表（本地值 → 客户值）。
///
/// 冲突默认保留本地（客户值只有在"客户提交更新"时才自动采用）；这里逐条只读展示，
/// "用客户值"需要单张写回 API（本波未接线，见交付报告）。
struct ProofImportResultSheet: View {
    let report: ClientSelectionImportReport
    @Environment(\.languageStore) private var languageStore
    @Environment(\.dismiss) private var dismiss
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("客户反馈导入结果")).font(GatherFont.sectionTitle)
            if report.alreadyImported {
                Text(l10n("这份反馈之前已导入过，未做任何修改。"))
                    .foregroundStyle(.secondary)
            } else {
                summaryRow(l10n("勾选"), report.applied)
                summaryRow(l10n("评分"), report.ratingApplied)
                summaryRow(l10n("色标"), report.labelApplied)
                summaryRow(l10n("评论"), report.comments)
                summaryRow(l10n("跳过"), report.skipped)
                if report.failed > 0 {
                    summaryRow(l10n("失败"), report.failed)
                        .foregroundStyle(GatherTheme.errorText)
                }
                if report.conflicts.isEmpty {
                    Text(l10n("没有与本地值冲突的项。"))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    Text(l10n.format("保留本地的冲突项（%lld）", report.conflicts.count))
                        .font(GatherFont.labelRegular)
                    ScrollView {
                        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                            ForEach(report.conflicts, id: \.photoId) { conflict in
                                conflictRow(conflict)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    Text(l10n("冲突默认保留本地值；客户值可在检查器里逐张确认。"))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(l10n("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .gatherButton(.primary)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 420)
    }

    private func summaryRow(_ title: String, _ value: Int) -> some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Text(title).font(GatherFont.secondary).foregroundStyle(.secondary)
            Text(String(value)).font(GatherFont.secondary).monospacedDigit()
        }
    }

    private func conflictRow(_ conflict: ProofFeedbackConflict) -> some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Text(conflict.photoId)
                .font(GatherFont.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(localText(conflict)).font(GatherFont.secondary)
            Text("→").foregroundStyle(.secondary)
            Text(clientText(conflict)).font(GatherFont.secondary)
        }
    }

    private func localText(_ conflict: ProofFeedbackConflict) -> String {
        var parts: [String] = []
        if conflict.localRating > 0 { parts.append(String(conflict.localRating) + "★") }
        if !conflict.localLabel.isEmpty { parts.append(conflict.localLabel) }
        return parts.isEmpty ? l10n("未设置") : parts.joined(separator: " ")
    }

    private func clientText(_ conflict: ProofFeedbackConflict) -> String {
        var parts: [String] = []
        if let rating = conflict.clientRating, rating > 0 { parts.append(String(rating) + "★") }
        if let label = conflict.clientLabel, !label.isEmpty { parts.append(label) }
        return parts.isEmpty ? l10n("未设置") : parts.joined(separator: " ")
    }
}
