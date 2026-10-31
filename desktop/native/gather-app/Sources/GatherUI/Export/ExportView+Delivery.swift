// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Delivery.swift
// W3：整套交付区（配方列表 + 联系表开关 + 运行 + 结果/打印）。
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

struct ExportDeliverySection: View {
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    @State private var showWebDAV = false
    @State private var pendingDelivery: PendingDeliveryConfirmation?
    /// 校样导入结果（v2：勾选 + 评分/色标 + 评论 + 冲突）。
    @State private var pendingProofImport: PendingProofImport?
    /// 最近一次导入报告（sheet 关闭后摘要行仍要能显示；不随 sheet 消失）。
    @State private var lastImportReport: ClientSelectionImportReport?
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
                recipeRow(recipe)
            }
            Toggle(l10n("包含联系表"), isOn: Binding(
                get: { viewModel.deliveryIncludeContactSheet },
                set: { viewModel.deliveryIncludeContactSheet = $0 }))
            Toggle(l10n("包含 Web 画廊与客户校样"), isOn: Binding(
                get: { viewModel.deliveryIncludeGallery },
                set: { viewModel.deliveryIncludeGallery = $0 }))
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
                        Text(publish.isSuccess
                             ? l10n.format("已发布 %lld 个文件", publish.uploaded)
                             : l10n.format("发布完成：成功 %lld，失败 %lld",
                                           publish.uploaded, publish.failed.count))
                            .font(GatherFont.secondary)
                            .foregroundStyle(publish.isSuccess ? GatherTheme.successText : GatherTheme.errorText)
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
        }
        .task { await viewModel.loadDeliveryRecipes() }
        .onChange(of: viewModel.deliveryRecipes) { _, _ in
            viewModel.schedulePersistDeliveryRecipes()
        }
        .onChange(of: viewModel.deliveryRoot) { _, _ in
            viewModel.persistDeliveryRoot()
        }
    }

    private func recipeRow(_ recipe: OutputRecipe) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack(spacing: GatherMetrics.Space.s) {
                TextField(l10n("配方名"), text: Binding(
                    get: { recipe.name },
                    set: { newValue in
                        guard let index = viewModel.deliveryRecipes.firstIndex(where: { $0.id == recipe.id })
                        else { return }
                        viewModel.deliveryRecipes[index].name = newValue
                    }))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80, idealWidth: 150, maxWidth: 180)
                Picker("", selection: Binding(
                    get: { recipe.format },
                    set: { newValue in
                        guard let index = viewModel.deliveryRecipes.firstIndex(where: { $0.id == recipe.id })
                        else { return }
                        viewModel.deliveryRecipes[index].format = newValue
                    })) {
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF").tag(ExportFormat.tiff)
                    Text(l10n("原图")).tag(ExportFormat.original)
                }
                .labelsHidden()
                .frame(width: 72)
                Spacer(minLength: 4)
                Button(role: .destructive) {
                    viewModel.removeDeliveryRecipe(id: recipe.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(l10n("删除配方"))
            }
            HStack(spacing: GatherMetrics.Space.s) {
                if let dimension = recipe.maxDimension {
                    Text(l10n.format("长边 %lld", dimension))
                }
                if recipe.artifacts.contains(.contactSheet) {
                    Text(l10n("含联系表"))
                }
            }
            .font(GatherFont.secondary)
            .foregroundStyle(.secondary)
        }
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
