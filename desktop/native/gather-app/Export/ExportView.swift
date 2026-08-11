// Phase 3.6：导出、预览、取消和报告 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/Export/index.tsx + export.ipc.ts。
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
    private(set) public var errorMessage: String?
    private(set) public var notice: String?

    public var format: ExportFormat = .jpeg
    public var variantPolicy: ExportVariantPolicy = .preferred
    public var quality = "85"
    public var maxDimension = ""
    public var includeXmp = true
    public var namingPattern = "{original}"
    public var tiffCompression: ExportTiffCompression = .lzw
    public var watermarkEnabled = false
    public var watermarkText = ""
    public var watermarkPosition: ExportWatermarkPosition = .bottomRight
    public var watermarkOpacity = 0.65
    public var watermarkFontSize = "32"
    public var destination = ""

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    public func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择导出目录"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
            errorMessage = nil
        }
    }

    public func previewExport() async {
        await run {
            let data = try await self.client.executeAsync("export.preview", params: self.parameters())
            self.preview = try data.decoded(as: ExportPreview.self)
            self.result = nil
            self.notice = "预览已更新"
        }
    }

    public func executeExport() async {
        await run {
            var params = try self.parameters()
            params["confirmed"] = .bool(true)
            let data = try await self.client.executeAsync("export.execute", params: params)
            self.result = try data.decoded(as: ExportResult.self)
            self.notice = "导出任务已完成"
        }
    }

    public func cancelExport() {
        do {
            _ = try client.execute("export.cancel", params: [
                "sessionId": .string(sessionId),
            ])
            notice = "已请求取消导出"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func generateReport(format: ReportFormat) {
        do {
            report = try client.execute("export.report", params: [
                "sessionId": .string(sessionId),
                "reportType": .string("session_summary"),
                "format": .string(format.rawValue),
            ]).decoded(as: ReportData.self)
            notice = "报告已生成：\(report?.path ?? "")"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
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
        if maxDimension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedDimension = nil
        } else if let value = Int(maxDimension), value > 0 {
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
            watermark: watermarkEnabled ? try watermark() : nil,
            naming: ExportNaming(pattern: namingPattern),
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

    private func run(_ operation: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }
}

public struct ExportView: View {
    @State private var viewModel: ExportViewModel
    private let onBack: () -> Void

    public init(sessionId: String, router: CommandRouter, onBack: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: ExportViewModel(sessionId: sessionId, router: router))
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: error, color: .red) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: .green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    optionsCard
                    previewCard
                    resultCard
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text("导出").font(.system(size: 24, weight: .bold))
                Text("工作区 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消导出", systemImage: "stop.circle") { viewModel.cancelExport() }
                .disabled(viewModel.isWorking == false)
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出选项").font(.title3.weight(.semibold))
            HStack {
                Picker("格式", selection: $viewModel.format) {
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF").tag(ExportFormat.tiff)
                    Text("原图").tag(ExportFormat.original)
                }
                .frame(width: 180)
                Picker("变体", selection: $viewModel.variantPolicy) {
                    Text("首选").tag(ExportVariantPolicy.preferred)
                    Text("RAW").tag(ExportVariantPolicy.raw)
                    Text("JPEG").tag(ExportVariantPolicy.jpeg)
                    Text("全部").tag(ExportVariantPolicy.all)
                }
                .frame(width: 180)
            }
            HStack {
                if viewModel.format == .jpeg {
                    TextField("质量 1–100", text: $viewModel.quality)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                TextField("最长边（可选）", text: $viewModel.maxDimension)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                TextField("命名模式", text: $viewModel.namingPattern)
                    .textFieldStyle(.roundedBorder)
            }
            if viewModel.format == .tiff {
                Picker("TIFF 压缩", selection: $viewModel.tiffCompression) {
                    Text("无压缩").tag(ExportTiffCompression.none)
                    Text("LZW").tag(ExportTiffCompression.lzw)
                    Text("Deflate").tag(ExportTiffCompression.deflate)
                }
                .frame(width: 220)
            }
            Toggle("复制 XMP 侧车文件", isOn: $viewModel.includeXmp)
            Toggle("添加文字水印", isOn: $viewModel.watermarkEnabled)
            if viewModel.watermarkEnabled {
                HStack {
                    TextField("水印文字", text: $viewModel.watermarkText)
                        .textFieldStyle(.roundedBorder)
                    Picker("位置", selection: $viewModel.watermarkPosition) {
                        Text("居中").tag(ExportWatermarkPosition.center)
                        Text("右下").tag(ExportWatermarkPosition.bottomRight)
                        Text("左下").tag(ExportWatermarkPosition.bottomLeft)
                    }
                    .frame(width: 140)
                    TextField("字号", text: $viewModel.watermarkFontSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                HStack {
                    Text("透明度")
                    Slider(value: $viewModel.watermarkOpacity, in: 0.05...1)
                    Text("\(Int(viewModel.watermarkOpacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 42)
                }
            }
            HStack {
                TextField("导出目录", text: $viewModel.destination)
                    .textFieldStyle(.roundedBorder)
                Button("选择…", action: viewModel.chooseDestination)
            }
            HStack {
                Spacer()
                Button("预览", systemImage: "eye") { Task { await viewModel.previewExport() } }
                Button("开始导出", systemImage: "square.and.arrow.up.fill") { Task { await viewModel.executeExport() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isWorking)
            }
        }
        .nativeCard()
    }

    @ViewBuilder
    private var previewCard: some View {
        if let preview = viewModel.preview {
            VStack(alignment: .leading, spacing: 10) {
                Text("预览").font(.title3.weight(.semibold))
                HStack(spacing: 22) {
                    LabeledContent("文件", value: "\(preview.totalFiles)")
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(preview.totalSizeBytes), countStyle: .file))
                    LabeledContent("可用空间", value: ByteCountFormatter.string(fromByteCount: Int64(preview.freeSpaceBytes), countStyle: .file))
                }
                ForEach(preview.files.prefix(8), id: \.photoId) { file in
                    Text("\(file.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if preview.files.count > 8 {
                    Text("还有 \(preview.files.count - 8) 个文件…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .nativeCard()
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if let result = viewModel.result {
            VStack(alignment: .leading, spacing: 10) {
                Text("结果").font(.title3.weight(.semibold))
                Text("总计 \(result.totalFiles) · 成功 \(result.exported) · 失败 \(result.failed) · 跳过 \(result.skipped)")
                ForEach(result.errors.prefix(10), id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("生成 CSV 报告") { viewModel.generateReport(format: .csv) }
                    Button("生成 Markdown 报告") { viewModel.generateReport(format: .md) }
                    if let report = viewModel.report {
                        Text(report.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .nativeCard()
        }
    }
}
