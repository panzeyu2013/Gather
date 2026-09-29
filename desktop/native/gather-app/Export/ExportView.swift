// Phase 3.6：导出、预览、取消和报告 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/Export/index.tsx + export.ipc.ts。
// UI 对齐（§十一 11.4）：实时进度、命名预览、空间不足警告、原图格式控件门控。
import SwiftUI
import AppKit
import GatherCore

@MainActor
@Observable
public final class ExportViewModel {
    private let client: NativeCommandClient
    public let sessionId: String
    private(set) public var preview: ExportPreview?
    private(set) public var result: ExportResult?
    private(set) public var report: ReportData?
    private(set) public var isWorking = false
    private(set) public var isPreviewing = false
    private(set) public var isExporting = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    // 实时导出进度（events.job-progress 驱动）。
    private(set) public var exportProgress: (current: Int, total: Int)?
    // 当前导出文件名（从事件 checkpoint 的 destinations/completedPhotoIds 推导，
    // 路由只透传 current/total/message/checkpoint，未直接带 fileName）。
    private(set) public var currentFileName: String?
    // 行内错误定位（旧版行内红字；Banner 之外在对应字段附近重复提示）。
    public enum ExportFieldError: Equatable {
        case destination
        case quality
        case maxDimension
        case watermark
    }
    private(set) public var fieldError: ExportFieldError?
    // {session} 占位符的会话名（session.get 可选加载；失败保持「工作区」）。
    private(set) public var sessionName: String?

    public var format: ExportFormat = .original
    public var variantPolicy: ExportVariantPolicy = .preferred
    public var quality = "85"
    public var maxDimension = ""
    public var includeXmp = true
    public var namingPattern = "{original}"
    public var tiffCompression: ExportTiffCompression = .lzw
    public var watermarkEnabled = false
    public var watermarkText = ""
    public var watermarkPosition: ExportWatermarkPosition = .bottomRight
    public var watermarkOpacity = 0.5
    public var watermarkFontSize = "24"
    public var destination = ""

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    public var destinationIsEmpty: Bool {
        destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 对齐 TS：仅非原图格式参与尺寸/水印（原图格式下控件不渲染，UI 不可触达
    /// EXPORT_ORIGINAL_NO_TRANSFORM）。
    public var transformsAllowed: Bool { format != .original }

    /// TS export.tsx namingPreview：占位符实时替换预览 + 扩展名。
    public var namingPreview: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"
        let time = timeFormatter.string(from: Date())
        var name = namingPattern
        name = name.replacingOccurrences(of: "{date}", with: date)
        name = name.replacingOccurrences(of: "{time}", with: time)
        name = name.replacingOccurrences(of: "{counter}", with: "0001")
        name = name.replacingOccurrences(of: "{original}", with: "IMG_1234")
        // 会话名可取则用之；取不到（session.get 失败）保持「工作区」。
        name = name.replacingOccurrences(of: "{session}", with: sessionName ?? GatherLocalization.l("工作区"))
        switch format {
        case .jpeg: name += ".jpg"
        case .tiff: name += ".tiff"
        case .original: name += GatherLocalization.l(".扩展名")
        }
        return name
    }

    /// 预览空间不足（TS export.tsx:320-325 红色警告）；freeSpaceBytes<0 时
    /// 服务端未测得可用空间，不误报。
    public var spaceInsufficient: Bool {
        guard let preview, preview.freeSpaceBytes >= 0 else { return false }
        return preview.totalSizeBytes > preview.freeSpaceBytes
    }

    /// 对齐 TS export.tsx：progressPercent = Math.round(current/total*100)。
    public var progressPercent: Int? {
        guard let progress = exportProgress, progress.total > 0 else { return nil }
        return Int((Double(progress.current) / Double(progress.total) * 100).rounded())
    }

    /// 加载会话名供命名预览 {session} 占位（session.get 失败静默保持 nil）。
    public func loadSessionName() {
        guard sessionName == nil else { return }
        sessionName = try? client.execute("session.get", params: [
            "sessionId": .string(sessionId),
        ]).decoded(as: SessionData.self).name
    }

    /// events.job-progress 消费：仅当前工作区 export.execute 任务的进度帧。
    /// export.execute 的 checkpoint 携带 destinations（photoId → 导出文件名）
    /// 与按完成顺序追加的 completedPhotoIds；最近完成的 photoId 即当前文件。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .exportExecute,
              event.job.scopeId == sessionId else { return }
        if let current = event.update.current, let total = event.update.total {
            exportProgress = (current, total)
            currentFileName = Self.fileName(from: event.update.checkpoint)
        }
        if event.isTerminal {
            exportProgress = nil
            currentFileName = nil
            if event.job.status == .succeeded {
                notice = GatherLocalization.l("导出任务已完成")
            }
        }
    }

    private static func fileName(from checkpoint: [String: GatherCore.JSONValue]?) -> String? {
        guard let checkpoint,
              let photoId = checkpoint["completedPhotoIds"]?.arrayElements?.last?.stringValue,
              !photoId.isEmpty else { return nil }
        return checkpoint["destinations"]?.objectValue?[photoId]?.stringValue
    }

    public func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = GatherLocalization.l("选择导出目录")
        panel.message = GatherLocalization.l("请勿选择工作区导入目录或其子目录，否则导出的文件会被重新导入当前工作区")
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
            errorMessage = nil
            fieldError = nil
        }
    }

    /// 拖放设置导出目录（与 chooseDestination 一致：写入并清除行内/横幅错误）。
    public func setDestinationPath(_ path: String) {
        destination = path
        errorMessage = nil
        fieldError = nil
    }

    public func previewExport() async {
        await run(isPreviewing: true) {
            let data = try await self.client.executeAsync("export.preview", params: try self.parameters())
            self.preview = try data.decoded(as: ExportPreview.self)
            self.result = nil
            self.notice = GatherLocalization.l("预览已更新")
        }
    }

    /// 组装「开始导出」确认载荷：先跑与 executeExport 同一套参数校验，
    /// 失败就地写行内错误并返回 nil（不弹确认、不发命令）。
    public func exportConfirmation() -> ExportConfirmation? {
        do {
            _ = try parameters()
        } catch {
            fieldError = Self.fieldError(for: error)
            errorMessage = NativeCommandClient.message(for: error)
            return nil
        }
        return ExportConfirmation(destination: destination, fileCount: preview?.files.count ?? 0)
    }

    /// 确认弹窗取消：写可见文案（不静默 return），不发命令。
    public func reportExportCancelled() {
        notice = GatherLocalization.l("已取消导出")
        fieldError = nil
    }

    /// 执行导出。confirmed 只能由视图确认分支传 true；未确认时不下发确认载荷，
    /// 由路由门禁拒绝（EXPORT_CONFIRMATION_REQUIRED）——UI 不得自证确认。
    public func executeExport(confirmed: Bool) async {
        exportProgress = nil
        currentFileName = nil
        await run {
            self.isExporting = true
            defer { self.isExporting = false }
            var params = try self.parameters()
            if confirmed {
                params["confirmed"] = .bool(true)
            }
            let data = try await self.client.executeAsync("export.execute", params: params)
            self.result = try data.decoded(as: ExportResult.self)
            self.notice = GatherLocalization.l("导出任务已完成")
        }
        exportProgress = nil
        currentFileName = nil
    }

    public func cancelExport() {
        do {
            // export.cancel 在路由端恒返回 true（SessionCommandRouter.swift:1408-1412），
            // 无法区分 no-op（无导出任务时同样返回 true），因此保持提示展示。
            _ = try client.execute("export.cancel", params: [
                "sessionId": .string(sessionId),
            ])
            notice = GatherLocalization.l("已请求取消导出")
            fieldError = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = nil
        }
    }

    public func generateReport(format: ReportFormat) {
        do {
            report = try client.execute("export.report", params: [
                "sessionId": .string(sessionId),
                "reportType": .string("session_summary"),
                "format": .string(format.rawValue),
            ]).decoded(as: ReportData.self)
            notice = String(format: GatherLocalization.l("报告已生成：%@"), report?.path ?? "")
            fieldError = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = nil
        }
    }

    /// 对齐旧版 export.tsx:251 的 min=1：提交（回车/失焦）时把最长边钳制到 ≥1；
    /// 非数字前缀保持原值，交由现有字段校验提示。
    public func commitMaxDimension() {
        let trimmed = maxDimension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed.prefix(while: \.isNumber)) else { return }
        maxDimension = String(max(1, value))
    }

    /// 对齐旧版 export.tsx:277：字号输入 min=8 max=200，非法输入回退 24。
    public func commitWatermarkFontSize() {
        guard let value = Int(watermarkFontSize.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            watermarkFontSize = "24"
            return
        }
        watermarkFontSize = String(min(max(value, 8), 200))
    }

    /// 对齐 TS translateErrorLine：`filename: <错误码>` 行尾错误码翻译。
    /// 无法解析结构的行也整体走 errorText（未知诊断回退通用文案），
    /// 原始细节由 ExportService/日志承载，不经 UI 直显。
    public static func translateErrorLine(_ line: String) -> String {
        guard let separator = line.range(of: ": ") else {
            return GatherLocalization.errorText(line)
        }
        let tail = line[separator.upperBound...]
        return "\(line[..<separator.lowerBound]): \(GatherLocalization.errorText(String(tail)))"
    }

    private func parameters() throws -> [String: GatherCore.JSONValue] {
        guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportServiceError.destinationInvalid
        }
        let parsedQuality: Double?
        if format == .jpeg {
            guard let value = Double(quality), value.rounded() == value else {
                throw ExportServiceError.qualityInvalid
            }
            parsedQuality = value
        } else {
            parsedQuality = nil
        }
        let parsedDimension: Int?
        if format == .original {
            parsedDimension = nil
        } else if maxDimension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedDimension = nil
        } else if let value = Int(maxDimension.prefix(while: \.isNumber)), value > 0 {
            // 对齐 TS parseInt(maxDimension, 10)：小数截断（"12.5"→12）；
            // 非数字前缀 → nil → maxDimensionInvalid，保持安全路径。
            parsedDimension = value
        } else {
            throw ExportServiceError.maxDimensionInvalid
        }
        let options = ExportOptions(
            scope: .session,
            variantPolicy: variantPolicy,
            format: format,
            quality: parsedQuality,
            maxDimension: parsedDimension,
            tiffCompression: format == .tiff ? tiffCompression : nil,
            // 对齐 TS export.tsx:67-75：watermarkEnabled && watermarkText 才发送；
            // 勾选但文本为空时不发 watermark，不再以 EXPORT_WATERMARK_TEXT_EMPTY 阻断。
            watermark: transformsAllowed && watermarkEnabled && !watermarkText.isEmpty ? try watermark() : nil,
            // TS export.tsx:60-61：counterStart 1 / dateFormat YYYY-MM-DD。
            naming: ExportNaming(pattern: namingPattern, counterStart: 1, dateFormat: "YYYY-MM-DD"),
            includeXmp: includeXmp,
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return [
            "sessionId": .string(sessionId),
            "options": try GatherCore.JSONValue(from: options),
        ]
    }

    private func watermark() throws -> ExportWatermark {
        let text = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExportServiceError.watermarkTextEmpty }
        guard let fontSize = Double(watermarkFontSize), fontSize > 0 else {
            throw ExportServiceError.watermarkFontSizeInvalid
        }
        return ExportWatermark(
            type: .text,
            content: text,
            position: watermarkPosition,
            opacity: watermarkOpacity,
            fontSize: fontSize
        )
    }

    /// 对齐旧版行内错误定位：参数校验错误映射到对应字段附近展示。
    private static func fieldError(for error: Error) -> ExportFieldError? {
        switch error {
        case ExportServiceError.destinationInvalid,
             ExportServiceError.destinationAbsoluteRequired,
             ExportServiceError.destinationRootForbidden,
             ExportServiceError.destinationInsideSession:
            return .destination
        case ExportServiceError.qualityInvalid:
            return .quality
        case ExportServiceError.maxDimensionInvalid:
            return .maxDimension
        case ExportServiceError.watermarkTextEmpty,
             ExportServiceError.watermarkFontSizeInvalid,
             ExportServiceError.watermarkOpacityInvalid:
            return .watermark
        default:
            break
        }
        // 路由/桥接层错误按错误码前缀兜底（如 EXPORT_DIR_INSIDE_SESSION）。
        // 注：Error 到 CustomStringConvertible 的条件转换恒成功（编译器 #alwaysSucceeds），
        // 且 String(describing:) 对实现了 description 的类型即取该 description，语义等价。
        let text = String(describing: error)
        if text.contains("EXPORT_DIR") || text.contains("DESTINATION") { return .destination }
        if text.contains("QUALITY") { return .quality }
        if text.contains("MAX_DIMENSION") { return .maxDimension }
        if text.contains("WATERMARK") { return .watermark }
        return nil
    }

    private func run(isPreviewing: Bool = false, _ operation: @escaping () async throws -> Void) async {
        isWorking = true
        if isPreviewing { self.isPreviewing = true }
        errorMessage = nil
        fieldError = nil
        defer {
            isWorking = false
            if isPreviewing { self.isPreviewing = false }
        }
        do {
            try await operation()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = Self.fieldError(for: error)
        }
    }
}

/// 8px 自绘导出进度条（对齐旧版 export.module.css .progressBar/.progressFill：
/// 8px 高、4px 圆角、primary 填充、0.3s ease 过渡）。
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GatherProgressBar(
            fraction: fraction,
            track: Color.gatherBorder.opacity(0.7),
            accessibilityText: GatherLocalization.l("导出进度")
        )
    }
}

/// 「开始导出」确认载荷：弹窗文案的事实来源（目的地 + 本次将写入的文件数）。
public struct ExportConfirmation: Equatable, Identifiable {
    public var destination: String
    public var fileCount: Int
    public var id: String { destination }

    public init(destination: String, fileCount: Int) {
        self.destination = destination
        self.fileCount = fileCount
    }
}

public struct ExportView: View {
    @State private var viewModel: ExportViewModel
    /// 非空即弹确认；confirmed 载荷只在确认分支写出（UI 不得自证确认）。
    @State private var pendingExport: ExportConfirmation?
    @FocusState private var maxDimensionFocused: Bool
    @FocusState private var watermarkFontSizeFocused: Bool
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: ExportViewModel(sessionId: sessionId, router: router))
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            actionBar
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            // 行内字段错误已就近定位（fieldError），横幅仅展示行内不可见的一般错误，
            // 避免同源重复提示。
            if let error = viewModel.errorMessage, viewModel.fieldError == nil {
                NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error)
            }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    exportProgressCard
                    optionsCard
                    previewCard
                    resultCard
                }
                .padding(24)
            }
        }
        .background(Color.gatherBackground)
        .task { viewModel.loadSessionName() }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .gatherDestructiveConfirm(
            pending: $pendingExport,
            title: GatherLocalization.l("开始导出？"),
            confirmLabel: { _ in GatherLocalization.l("开始导出") },
            message: { request in
                String(
                    format: GatherLocalization.l("将向「%@」写入 %lld 个文件；重名文件会自动改名，不会覆盖已有文件。"),
                    request.destination,
                    request.fileCount
                )
            },
            onConfirm: { _ in
                // confirmed: true 只能从这个确认分支到达。
                Task { await viewModel.executeExport(confirmed: true) }
            },
            onCancel: { _ in viewModel.reportExportCancelled() }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(GatherLocalization.l("返回"), systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(GatherLocalization.l("批量导出")).font(.largeTitle.weight(.bold))
                    Text(String(format: GatherLocalization.l("工作区 %@ · 按统一格式、命名规则导出照片及元数据"), String(viewModel.sessionId.prefix(8))))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings)
            }
            SessionTabBar(
                selection: .tab(.export),
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
        }
        .padding(24)
        .background(Color.gatherSurface)
    }

    /// 顶部固定操作栏（对齐旧版 sticky actionBar：格式摘要 + 目标目录 + 预览/
    /// 开始导出/取消导出三按钮），替代原先沉底于选项卡底部的按钮行。
    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatSummary)
                    .font(.callout.weight(.semibold))
                Text(viewModel.destination.isEmpty ? GatherLocalization.l("未选择导出目录") : viewModel.destination)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 300, alignment: .leading)
            Spacer()
            Button(viewModel.isPreviewing ? GatherLocalization.l("正在计算…") : GatherLocalization.l("预览"), systemImage: "eye") {
                Task { await viewModel.previewExport() }
            }
            .disabled(viewModel.isWorking || viewModel.destinationIsEmpty)
            // 对齐旧版 export.tsx:192：仅导出进行中禁用，预览不互斥（旧版可并发）。
            Button(viewModel.isExporting ? GatherLocalization.l("正在导出…") : GatherLocalization.l("开始导出"), systemImage: "square.and.arrow.up.fill") {
                // 参数校验通过才弹确认；确认载荷只在 onConfirm 分支下发。
                pendingExport = viewModel.exportConfirmation()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExporting || viewModel.destinationIsEmpty)
            // 对齐旧版 export.tsx:195：取消仅在导出进行中可用（预览期间禁用）。
            Button(GatherLocalization.l("取消导出"), systemImage: "stop.circle") {
                viewModel.cancelExport()
            }
            .disabled(!viewModel.isExporting)
        }
        .padding(12)
        .background(Color.gatherSurface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gatherBorder.opacity(0.8), lineWidth: 1)
        )
    }

    private var formatSummary: String {
        switch viewModel.format {
        case .original: return GatherLocalization.l("原图")
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }

    /// 导出中实时进度（TS export.tsx:334-346）：8px 自绘进度条 + 百分比 +
    /// `第 N/N 张 · 文件名`；executeExport 进行中但首帧进度未到（exportProgress
    /// == nil）时显示「正在准备导出…」。
    @ViewBuilder
    private var exportProgressCard: some View {
        if let progress = viewModel.exportProgress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(GatherLocalization.l("正在导出照片…")).font(.headline)
                    Spacer()
                    if let percent = viewModel.progressPercent {
                        Text("\(percent)%")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(GatherTheme.primary)
                    }
                }
                ProgressBar(
                    fraction: Double(progress.current) / Double(max(1, progress.total))
                )
                Text(String(format: GatherLocalization.l("第 %lld/%lld 张%@"), progress.current, progress.total, currentFileSuffix))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .gatherCard()
        } else if viewModel.isExporting {
            VStack(alignment: .leading, spacing: 8) {
                Text(GatherLocalization.l("正在准备导出…")).font(.headline)
                ProgressBar(fraction: 0)
            }
            .gatherCard()
        }
    }

    private var currentFileSuffix: String {
        guard let name = viewModel.currentFileName, !name.isEmpty else { return "" }
        return " · \(name)"
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("导出选项")).font(.title3.weight(.semibold))
            HStack {
                HStack(spacing: 6) {
                    Text(GatherLocalization.l("格式")).font(.callout).frame(width: 60, alignment: .trailing)
                    Picker(GatherLocalization.l("格式"), selection: $viewModel.format) {
                        Text(GatherLocalization.l("原图")).tag(ExportFormat.original)
                        Text("JPEG").tag(ExportFormat.jpeg)
                        Text("TIFF").tag(ExportFormat.tiff)
                    }
                    .frame(width: 180)
                }
                HStack(spacing: 6) {
                    Text(GatherLocalization.l("变体")).font(.callout).frame(width: 60, alignment: .trailing)
                    Picker(GatherLocalization.l("变体"), selection: $viewModel.variantPolicy) {
                        Text(GatherLocalization.l("首选")).tag(ExportVariantPolicy.preferred)
                        Text("RAW").tag(ExportVariantPolicy.raw)
                        Text("JPEG").tag(ExportVariantPolicy.jpeg)
                        Text(GatherLocalization.l("全部")).tag(ExportVariantPolicy.all)
                    }
                    .frame(width: 180)
                }
            }
            if viewModel.format == .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(GatherLocalization.l("JPEG 质量"))
                        Slider(value: Binding(
                            get: { Double(viewModel.quality) ?? 85 },
                            set: { viewModel.quality = String(Int($0)) }
                        ), in: 1...100, step: 1)
                        .accessibilityLabel(GatherLocalization.l("JPEG 质量"))
                        Text(String(format: GatherLocalization.l("质量： %@"), viewModel.quality))
                            .font(.footnote.monospacedDigit())
                            .frame(width: 70)
                    }
                    fieldError(.quality)
                }
            }
            if viewModel.transformsAllowed {
                VStack(alignment: .leading, spacing: 4) {
                    // 对齐旧版 export.tsx:251：placeholder「不限制」、min=1（提交时钳制）。
                    TextField(GatherLocalization.l("不限制"), text: $viewModel.maxDimension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .accessibilityLabel(GatherLocalization.l("最长边"))
                        .focused($maxDimensionFocused)
                        .onSubmit { viewModel.commitMaxDimension() }
                        .onChange(of: maxDimensionFocused) { _, isFocused in
                            if !isFocused { viewModel.commitMaxDimension() }
                        }
                    fieldError(.maxDimension)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField(GatherLocalization.l("命名模式（{date}/{time}/{counter}/{original}/{session}）"), text: $viewModel.namingPattern)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(GatherLocalization.l("命名模式"))
                Text(String(format: GatherLocalization.l("示例：%@"), viewModel.namingPreview))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            if viewModel.format == .tiff {
                Picker(GatherLocalization.l("TIFF 压缩"), selection: $viewModel.tiffCompression) {
                    Text(GatherLocalization.l("无压缩")).tag(ExportTiffCompression.none)
                    Text("LZW").tag(ExportTiffCompression.lzw)
                    Text("Deflate").tag(ExportTiffCompression.deflate)
                }
                .frame(width: 220)
            }
            Toggle(GatherLocalization.l("复制 XMP 侧车文件"), isOn: $viewModel.includeXmp)
            if viewModel.transformsAllowed {
                Toggle(GatherLocalization.l("添加文字水印"), isOn: $viewModel.watermarkEnabled)
                if viewModel.watermarkEnabled {
                    HStack {
                        TextField(GatherLocalization.l("水印文字"), text: $viewModel.watermarkText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(GatherLocalization.l("水印文字"))
                        HStack(spacing: 6) {
                            Text(GatherLocalization.l("位置")).font(.callout)
                            Picker(GatherLocalization.l("位置"), selection: $viewModel.watermarkPosition) {
                                Text(GatherLocalization.l("居中")).tag(ExportWatermarkPosition.center)
                                Text(GatherLocalization.l("右下")).tag(ExportWatermarkPosition.bottomRight)
                                Text(GatherLocalization.l("左下")).tag(ExportWatermarkPosition.bottomLeft)
                            }
                            .frame(width: 140)
                        }
                        HStack(spacing: 6) {
                            Text(GatherLocalization.l("字号")).font(.callout)
                            TextField(GatherLocalization.l("字号"), text: $viewModel.watermarkFontSize)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .accessibilityLabel(GatherLocalization.l("字号"))
                                .focused($watermarkFontSizeFocused)
                                .onSubmit { viewModel.commitWatermarkFontSize() }
                                .onChange(of: watermarkFontSizeFocused) { _, isFocused in
                                    if !isFocused { viewModel.commitWatermarkFontSize() }
                                }
                        }
                    }
                    HStack {
                        Text(GatherLocalization.l("透明度"))
                        Slider(value: $viewModel.watermarkOpacity, in: 0.1...1, step: 0.1)
                            .accessibilityLabel(GatherLocalization.l("透明度"))
                        Text("\(Int(viewModel.watermarkOpacity * 100))%")
                            .font(.footnote.monospacedDigit())
                            .frame(width: 42)
                    }
                    fieldError(.watermark)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField(GatherLocalization.l("导出目录（不要选择导入目录）"), text: $viewModel.destination)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(GatherLocalization.l("导出目录"))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first(where: { isDirectoryURL($0) }) else { return false }
                            viewModel.setDestinationPath(url.path)
                            return true
                        }
                    Button(GatherLocalization.l("选择…"), action: viewModel.chooseDestination)
                }
                // 对齐旧版 export.folderHint 警告（TS L301-303）。
                Text(GatherLocalization.l("请选择导出文件夹。不要选择工作区导入目录，否则导出的文件会被重新导入当前工作区。"))
                    .font(.footnote).foregroundStyle(.secondary)
                fieldError(.destination)
            }
        }
        .gatherCard()
    }

    /// 行内错误（旧版 export.module.css .error 行内红字）；Banner 保留，
    /// 对应字段附近再重复提示一次以就近定位。
    @ViewBuilder
    private func fieldError(_ field: ExportViewModel.ExportFieldError) -> some View {
        if viewModel.fieldError == field, let message = viewModel.errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(GatherTheme.error)
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        if let preview = viewModel.preview {
            VStack(alignment: .leading, spacing: 10) {
                Text(GatherLocalization.l("预览")).font(.title3.weight(.semibold))
                HStack(spacing: 22) {
                    LabeledContent(GatherLocalization.l("文件"), value: "\(preview.totalFiles)")
                    LabeledContent(GatherLocalization.l("大小"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.totalSizeBytes), countStyle: .file))
                    // TS export.tsx:320-325：freeSpaceBytes<0 时隐藏该行且无警告。
                    if preview.freeSpaceBytes >= 0 {
                        LabeledContent(GatherLocalization.l("可用空间"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.freeSpaceBytes), countStyle: .file))
                    }
                }
                if viewModel.spaceInsufficient {
                    Text(GatherLocalization.l("导出文件所需空间超过磁盘可用空间，请更换目标目录"))
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(GatherTheme.warning)
                }
                ForEach(preview.files.prefix(8), id: \.photoId) { file in
                    Text("\(file.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if preview.files.count > 8 {
                    Text(String(format: GatherLocalization.l("还有 %lld 个文件…"), preview.files.count - 8)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .gatherCard()
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if let result = viewModel.result {
            VStack(alignment: .leading, spacing: 10) {
                Text(GatherLocalization.l("结果")).font(.title3.weight(.semibold))
                Text(String(format: GatherLocalization.l("导出完成：成功 %lld，失败 %lld，跳过 %lld"), result.exported, result.failed, result.skipped))
                    .foregroundStyle(result.failed > 0 ? GatherTheme.error : GatherTheme.success)
                // 对齐 TS export.tsx:91：错误明细最多 3 条。
                ForEach(result.errors.prefix(3), id: \.self) { error in
                    Text(ExportViewModel.translateErrorLine(error)).font(.footnote).foregroundStyle(GatherTheme.error)
                }
                HStack(spacing: 8) {
                    Button(GatherLocalization.l("生成 CSV 报告")) { viewModel.generateReport(format: .csv) }
                    Button(GatherLocalization.l("生成 Markdown 报告")) { viewModel.generateReport(format: .md) }
                }
                if let report = viewModel.report {
                    Text(report.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .gatherCard()
        }
    }
}
