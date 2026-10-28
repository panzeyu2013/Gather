// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Delivery.swift
// W3：整套交付区（配方列表 + 联系表开关 + 运行 + 结果/打印）。
import AppKit
import SwiftUI
import GatherProtocol

struct ExportDeliverySection: View {
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    @State private var showWebDAV = false
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
                Spacer()
                if viewModel.isDelivering {
                    Button(l10n("取消交付")) {
                        Task { await viewModel.cancelDelivery() }
                    }
                }
                Button(viewModel.isDelivering ? l10n("正在交付…") : l10n("开始整套交付")) {
                    Task { await viewModel.runDelivery() }
                }
                .gatherPrimaryActionButton()
                .disabled(viewModel.isDelivering || viewModel.deliveryRecipes.isEmpty)
            }
            if viewModel.cullingAPI != nil {
                HStack(spacing: GatherMetrics.Space.s) {
                    Button(viewModel.isImportingSelection
                           ? l10n("正在导入…") : l10n("导入客户选择…")) {
                        importSelection()
                    }
                    .disabled(viewModel.isImportingSelection)
                    if let imported = viewModel.clientSelectionImport {
                        let text = imported.failed > 0
                            ? l10n.format("已导入 %lld 张（跳过 %lld，失败 %lld）",
                                         imported.applied, imported.skipped, imported.failed)
                            : l10n.format("已导入 %lld 张（跳过 %lld）",
                                         imported.applied, imported.skipped)
                        Text(text)
                            .font(GatherFont.secondary)
                            .foregroundStyle(imported.failed > 0
                                ? GatherTheme.errorText : GatherTheme.secondaryText)
                    }
                }
            }
            if let summary = viewModel.deliverySummary {
                deliveryResult(summary)
                HStack(spacing: GatherMetrics.Space.s) {
                    Button(l10n("发布到 WebDAV…")) { showWebDAV = true }
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
                    // 发布整个 run 根目录（含所有配方 + manifest + 画廊），而不是只发第一个配方。
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
                await viewModel.importClientSelection(json: json)
            }
        }
    }

    /// 只发布本次交付的**精确产物**（manifest.files）+ 画廊目录（缩略图/大图不在
    /// files 清单里）。旧 summary 没有 files 或配方落在 run 根时退回整目录。
    static func publishPrefixes(for summary: OutputRunSummary) -> [String]? {
        let root = URL(fileURLWithPath: summary.manifestPath)
            .deletingLastPathComponent().standardizedFileURL.path
        // manifest 含本机绝对路径（recipe.destination / contactSheetPath），只用于本地审计，
        // 不进发布白名单：客户在服务器上不该看到摄影师的本机目录结构。
        var paths: Set<String> = []
        for recipe in summary.recipes {
            let destination = URL(fileURLWithPath: recipe.destination).standardizedFileURL.path
            if destination == root { return nil }
            guard destination.hasPrefix(root + "/") else { return nil }
            let relDestination = String(destination.dropFirst(root.count + 1))
            guard let files = recipe.files else { return nil }
            for file in files {
                paths.insert(relDestination + "/" + file.name)
            }
            if let gallery = recipe.galleryPath {
                let galleryDir = URL(fileURLWithPath: gallery).deletingLastPathComponent().path
                if galleryDir.hasPrefix(root + "/") {
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
                    .buttonStyle(.borderless)
                    if let sheet = recipe.contactSheetPath {
                        Button(l10n("打印联系表")) {
                            if !PrintSupport.printPDF(at: sheet, jobTitle: recipe.name) {
                                viewModel.errorMessage = CommandError.localized("无法打开联系表 PDF")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    if let gallery = recipe.galleryPath {
                        Button(l10n("打开画廊")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: gallery))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let first = recipe.errors.first {
                    Text(first).font(GatherFont.secondary).foregroundStyle(GatherTheme.errorText)
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
}
