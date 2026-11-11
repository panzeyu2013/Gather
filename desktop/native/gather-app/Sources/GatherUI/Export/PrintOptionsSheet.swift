// desktop/native/gather-app/Sources/GatherUI/Export/PrintOptionsSheet.swift
// Wave3 / task-20：打印版面面板（单图打印 / 多页排版）。
//
// 边界（layering）：本文件只做「收集选项 → 经 PrintRenderingPort 渲染 PDF →
// 复用 PrintSupport 打开系统打印面板」。版面算法与矢量绘制在
// GatherApplication/Services/Export/Print*（纯逻辑，单测覆盖）；UI 不 import 分析层。
//
// 打印是独占资源：整段「渲染 → 打印面板」由 PrintSessionGate 串行化，
// PrintSupport 里还有一道 NSPrintOperation 闸（联系表打印也走它）。
// 已有打印进行中时必须给明确提示，不静默吞掉、不并排打开两个打印面板。
import AppKit
import SwiftUI

struct PrintOptionsSheet: View {
    /// 多页排版的照片（调用方按页内顺序给；单图模式用 currentItem）。
    let items: [PrintJobItem]
    /// 单图模式默认打印的当前照片（nil 时用 items.first）。
    let currentItem: PrintJobItem?

    @Environment(\.languageStore) private var languageStore
    @Environment(\.dismiss) private var dismiss
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    // 模式与纸张
    @State private var mode: PrintJobMode
    @State private var paper: PrintJobPaper = .a4
    /// 自定义页面尺寸（厘米，仅 paper == .custom 用）。
    @State private var customPageWidthCM = "21.0"
    @State private var customPageHeightCM = "29.7"
    // 通用
    /// 离白/页边距（厘米，四边同值；0 = 无边距）。
    @State private var marginCM = "1.0"
    // 单图
    @State private var sizing: PrintJobSizing = .fitToPage
    @State private var customImageWidthCM = "10.0"
    @State private var customImageHeightCM = "15.0"
    @State private var borderEnabled = false
    @State private var borderWidthPoints = "1.0"
    // 多页
    @State private var columns = 3
    @State private var rows = 3
    @State private var showsCaption = true
    @State private var headerText = ""
    @State private var footerText = ""
    @State private var showsPageNumbers = true
    // 运行时状态
    @State private var isRendering = false
    @State private var errorText: String?
    @State private var noticeText: String?

    /// 1 厘米 = 72/2.54 点。
    private static let pointsPerCM: CGFloat = 72 / 2.54

    init(items: [PrintJobItem], currentItem: PrintJobItem?) {
        self.items = items
        self.currentItem = currentItem
        _mode = State(initialValue: items.count > 1 ? .multiPage : .singleImage)
    }

    /// 单图模式实际要打印的那一张。
    private var singleItem: PrintJobItem? { currentItem ?? items.first }

    private var canPrint: Bool {
        guard !isRendering else { return false }
        switch mode {
        case .singleImage: return singleItem != nil
        case .multiPage: return !items.isEmpty
        }
    }

    /// 面板内展示的页数：已注册打印端口时以 core 的分页引擎为准
    /// （与真正渲染同源）；宿主未接线时按同一公式给保守估计。
    private var displayedPageCount: Int {
        switch mode {
        case .singleImage:
            return 1
        case .multiPage:
            if let port = PrintRenderingRegistry.current() {
                return max(1, port.pageCount(for: makeRequest()))
            }
            let perPage = max(1, min(12, max(1, columns)) * min(20, max(1, rows)))
            return max(1, (items.count + perPage - 1) / perPage)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("打印版面"))
                .font(GatherFont.pageTitle)
            Text(l10n("打印不会写入工作区或修改照片；版面选项只在本次打印生效。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
                    Picker(l10n("布局"), selection: $mode) {
                        Text(l10n("单图打印")).tag(PrintJobMode.singleImage)
                        Text(l10n("多页排版")).tag(PrintJobMode.multiPage)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    paperSection
                    marginSection
                    if mode == .singleImage {
                        singleImageSection
                    } else {
                        multiPageSection
                    }
                    if mode == .multiPage {
                        LabeledContent(l10n("预计页数")) {
                            Text(l10n.format("预计 %lld 页", displayedPageCount))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 420)

            if let noticeText {
                NativeBanner(text: noticeText, color: GatherTheme.success)
            }
            if let errorText {
                NativeBanner(text: errorText, color: GatherTheme.error)
            }
            HStack {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .gatherButton(.secondary)
                    .disabled(isRendering)
                Button(isRendering ? l10n("正在生成打印 PDF…") : l10n("打印")) {
                    startPrint()
                }
                .keyboardShortcut(.defaultAction)
                .gatherButton(.primary)
                .disabled(!canPrint)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 460)
    }

    // MARK: - 选项区块

    private var paperSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            LabeledContent(l10n("纸张")) {
                Picker(l10n("纸张"), selection: $paper) {
                    Text("A4").tag(PrintJobPaper.a4)
                    Text("A5").tag(PrintJobPaper.a5)
                    Text("Letter").tag(PrintJobPaper.letter)
                    Text(l10n("4 × 6 英寸")).tag(PrintJobPaper.photo4x6)
                    Text(l10n("5 × 7 英寸")).tag(PrintJobPaper.photo5x7)
                    Text(l10n("8 × 10 英寸")).tag(PrintJobPaper.photo8x10)
                    Text(l10n("自定义")).tag(PrintJobPaper.custom)
                }
            }
            if paper == .custom {
                HStack(spacing: GatherMetrics.Space.s) {
                    TextField(l10n("页面宽度（厘米）"), text: $customPageWidthCM)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField(l10n("页面高度（厘米）"), text: $customPageHeightCM)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }
        }
    }

    private var marginSection: some View {
        LabeledContent(l10n("离白（厘米）")) {
            TextField(l10n("离白（厘米）"), text: $marginCM)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 90)
        }
        .help(l10n("四边留白；0 = 不留白，边框会贴到纸张边缘。"))
    }

    private var singleImageSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            LabeledContent(l10n("摆放方式")) {
                Picker(l10n("摆放方式"), selection: $sizing) {
                    Text(l10n("适配页面")).tag(PrintJobSizing.fitToPage)
                    Text(l10n("自定义尺寸")).tag(PrintJobSizing.custom)
                }
                .labelsHidden()
            }
            if sizing == .custom {
                HStack(spacing: GatherMetrics.Space.s) {
                    TextField(l10n("图像宽度（厘米）"), text: $customImageWidthCM)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    TextField(l10n("图像高度（厘米）"), text: $customImageHeightCM)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
            }
            Toggle(l10n("边框"), isOn: $borderEnabled)
            if borderEnabled {
                LabeledContent(l10n("边框宽度（点）")) {
                    TextField(l10n("边框宽度（点）"), text: $borderWidthPoints)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                }
            }
            Text(l10n.format("将打印：%@", singleItem?.caption ?? l10n("没有可打印的照片")))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var multiPageSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            LabeledContent(l10n("每页张数")) {
                HStack(spacing: GatherMetrics.Space.s) {
                    Stepper(l10n.format("列数：%lld", columns), value: $columns, in: 1...6)
                    Stepper(l10n.format("行数：%lld", rows), value: $rows, in: 1...8)
                }
            }
            Toggle(l10n("显示文件名"), isOn: $showsCaption)
            LabeledContent(l10n("页眉")) {
                TextField(l10n("页眉文字"), text: $headerText)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent(l10n("页脚")) {
                TextField(l10n("页脚文字"), text: $footerText)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle(l10n("显示页码"), isOn: $showsPageNumbers)
            Text(l10n.format("共 %lld 张照片", items.count))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 打印

    private func startPrint() {
        guard canPrint else { return }
        guard PrintSessionGate.begin() else {
            errorText = l10n("已有打印任务在进行中，请先关闭打印面板。")
            return
        }
        guard let port = PrintRenderingRegistry.current() else {
            PrintSessionGate.end()
            errorText = l10n("打印渲染不可用（宿主未接线）。")
            return
        }
        guard !PrintSupport.isPrinting else {
            PrintSessionGate.end()
            errorText = l10n("已有打印任务在进行中，请先关闭打印面板。")
            return
        }
        let request = makeRequest()
        guard !request.items.isEmpty else {
            PrintSessionGate.end()
            errorText = l10n("没有可打印的照片")
            return
        }
        isRendering = true
        errorText = nil
        noticeText = nil
        Task { @MainActor in
            defer {
                isRendering = false
                PrintSessionGate.end()
            }
            do {
                let outcome = try await port.render(request)
                // 渲染期间用户可能从联系表那条路打开了打印面板：再确认一次。
                guard !PrintSupport.isPrinting else {
                    errorText = l10n("已有打印任务在进行中，请先关闭打印面板。")
                    return
                }
                guard PrintSupport.printPDF(at: request.outputPath, jobTitle: l10n("打印版面")) else {
                    errorText = l10n("无法打开打印面板（PDF 生成失败或已有打印任务）。")
                    return
                }
                if outcome.failedImages > 0 {
                    // 已交给打印系统但有坏图：留在面板里把数字说清楚，
                    // 用户看完再关（自动关闭会把这条唯一可见的提示吞掉）。
                    noticeText = l10n.format(
                        "已发送打印；%lld 张图片无法解码，已用空框代替。", outcome.failedImages)
                } else {
                    dismiss()
                }
            } catch is CancellationError {
                return
            } catch let error as PrintRenderingError {
                switch error {
                case .rendererUnavailable:
                    errorText = l10n("打印渲染不可用（宿主未接线）。")
                case .failed(let reason):
                    errorText = l10n.format("打印失败：%@", reason)
                }
            } catch {
                errorText = l10n.format("打印失败：%@", String(describing: error))
            }
        }
    }

    /// 收集面板选项 → 端口请求（临时 PDF 路径由这里分配）。
    private func makeRequest() -> PrintJobRequest {
        let options = PrintJobOptions(
            mode: mode,
            paper: paper,
            customPageSize: CGSize(
                width: cmValue(customPageWidthCM, fallback: 21) * Self.pointsPerCM,
                height: cmValue(customPageHeightCM, fallback: 29.7) * Self.pointsPerCM),
            margins: PrintJobMargins(
                top: marginPoints, bottom: marginPoints,
                leading: marginPoints, trailing: marginPoints),
            sizing: sizing,
            customImageSize: CGSize(
                width: cmValue(customImageWidthCM, fallback: 10) * Self.pointsPerCM,
                height: cmValue(customImageHeightCM, fallback: 15) * Self.pointsPerCM),
            borderWidth: borderEnabled
                ? CGFloat(max(0, Double(borderWidthPoints) ?? 1)) : 0,
            columns: columns,
            rows: rows,
            cellSpacing: 8,
            captionHeight: showsCaption ? 16 : 0,
            headerHeight: headerText.isEmpty ? 0 : 32,
            footerHeight: (footerText.isEmpty && !showsPageNumbers) ? 0 : 20,
            headerText: headerText,
            footerText: footerText,
            showsPageNumbers: showsPageNumbers)
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gather-Print-\(UUID().uuidString).pdf").path
        return PrintJobRequest(
            options: options,
            items: mode == .singleImage ? [singleItem].compactMap { $0 } : items,
            outputPath: outputPath)
    }

    private var marginPoints: CGFloat {
        cmValue(marginCM, fallback: 1) * Self.pointsPerCM
    }

    private func cmValue(_ text: String, fallback: Double) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value >= 0 else {
            return CGFloat(fallback)
        }
        return CGFloat(value)
    }
}
