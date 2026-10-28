// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Options.swift
// Cut 4 / 4c-2f：导出五段之三（原 ExportView.swift 939-1069）。
// 纯搬移：格式/变体/质量/最长边/命名/TIFF/XMP/水印/目录各行与校验顺序不变。
// 两个 @FocusState 由壳以 FocusState<Bool>.Binding 下传（同一个焦点状态）。
import SwiftUI
import GatherProtocol

struct ExportOptionsSection: View {
    @Bindable var viewModel: ExportViewModel
    @FocusState.Binding var maxDimensionFocused: Bool
    @FocusState.Binding var watermarkFontSizeFocused: Bool
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 导出选项：系统分组表单。每行一个 LabeledContent，标签由系统对齐；
    /// Picker 自带标签一律 .labelsHidden()，避免「Text("格式") + Picker("格式")」重复。
    var body: some View {
        Section(l10n("导出选项")) {
            LabeledContent(l10n("格式")) {
                Picker(l10n("格式"), selection: $viewModel.format) {
                    Text(l10n("原图")).tag(ExportFormat.original)
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF").tag(ExportFormat.tiff)
                }
                .labelsHidden()
            }
            LabeledContent(l10n("变体")) {
                Picker(l10n("变体"), selection: $viewModel.variantPolicy) {
                    Text(l10n("首选")).tag(ExportVariantPolicy.preferred)
                    Text("RAW").tag(ExportVariantPolicy.raw)
                    Text("JPEG").tag(ExportVariantPolicy.jpeg)
                    Text(l10n("全部")).tag(ExportVariantPolicy.all)
                }
                .labelsHidden()
            }
            if viewModel.format == .jpeg {
                LabeledContent(l10n("JPEG 质量")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(viewModel.quality) ?? 85 },
                            set: { viewModel.quality = String(Int($0)) }
                        ), in: 1...100, step: 1)
                        .accessibilityLabel(l10n("JPEG 质量"))
                        Text(l10n.format("质量： %@", viewModel.quality))
                            .font(.callout.monospacedDigit())
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                ExportFieldErrorText(field: .quality, viewModel: viewModel)
            }
            if viewModel.transformsAllowed {
                LabeledContent(l10n("最长边")) {
                    // 对齐旧版 export.tsx:251：placeholder「不限制」、min=1（提交时钳制）。
                    TextField(l10n("不限制"), text: $viewModel.maxDimension)
                        .labelsHidden()
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(l10n("最长边"))
                        .focused($maxDimensionFocused)
                        .onSubmit { viewModel.commitMaxDimension() }
                        .onChange(of: maxDimensionFocused) { _, isFocused in
                            if !isFocused { viewModel.commitMaxDimension() }
                        }
                }
                ExportFieldErrorText(field: .maxDimension, viewModel: viewModel)
            }
            LabeledContent(l10n("命名模式")) {
                TextField(
                    l10n("命名模式"),
                    text: $viewModel.namingPattern,
                    prompt: Text("{date}/{time}/{counter}/{original}/{session}")
                )
                .labelsHidden()
            }
            Text(l10n.format("示例：%@", viewModel.namingPreview(with: l10n)))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if viewModel.format == .tiff {
                LabeledContent(l10n("TIFF 压缩")) {
                    Picker(l10n("TIFF 压缩"), selection: $viewModel.tiffCompression) {
                        Text(l10n("无压缩")).tag(ExportTiffCompression.none)
                        Text("LZW").tag(ExportTiffCompression.lzw)
                        Text("Deflate").tag(ExportTiffCompression.deflate)
                    }
                    .labelsHidden()
                }
            }
            Toggle(l10n("复制 XMP 附属文件"), isOn: $viewModel.includeXmp)
            if viewModel.transformsAllowed {
                Toggle(l10n("添加文字水印"), isOn: $viewModel.watermarkEnabled)
                if viewModel.watermarkEnabled {
                    TextField(l10n("水印文字"), text: $viewModel.watermarkText)
                        .accessibilityLabel(l10n("水印文字"))
                    LabeledContent(l10n("位置")) {
                        Picker(l10n("位置"), selection: $viewModel.watermarkPosition) {
                            Text(l10n("居中")).tag(ExportWatermarkPosition.center)
                            Text(l10n("右下")).tag(ExportWatermarkPosition.bottomRight)
                            Text(l10n("左下")).tag(ExportWatermarkPosition.bottomLeft)
                        }
                        .labelsHidden()
                    }
                    LabeledContent(l10n("字号")) {
                        TextField(l10n("字号"), text: $viewModel.watermarkFontSize)
                            .labelsHidden()
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(l10n("字号"))
                            .focused($watermarkFontSizeFocused)
                            .onSubmit { viewModel.commitWatermarkFontSize() }
                            .onChange(of: watermarkFontSizeFocused) { _, isFocused in
                                if !isFocused { viewModel.commitWatermarkFontSize() }
                            }
                    }
                    LabeledContent(l10n("透明度")) {
                        HStack(spacing: 10) {
                            Slider(value: $viewModel.watermarkOpacity, in: 0.1...1, step: 0.1)
                                .accessibilityLabel(l10n("透明度"))
                            Text("\(Int(viewModel.watermarkOpacity * 100))%")
                                .font(.callout.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    ExportFieldErrorText(field: .watermark, viewModel: viewModel)
                }
            }
            LabeledContent(l10n("导出目录")) {
                HStack(spacing: 8) {
                    // E 报告：占位与下方脚注重复，且过长会在窄窗口被截断。
                    TextField(l10n("选择导出目录"), text: $viewModel.destination)
                        .labelsHidden()
                        .accessibilityLabel(l10n("导出目录"))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first(where: { isDirectoryURL($0) }) else { return false }
                            viewModel.setDestinationPath(url.path)
                            return true
                        }
                    Button(l10n("选择…")) { viewModel.chooseDestination(with: l10n) }
                }
            }
            // 对齐旧版 export.folderHint 警告（TS L301-303）。
            Text(l10n("请选择导出文件夹。不要选择工作区导入目录，否则导出的文件会被重新导入当前工作区。"))
                .font(.callout).foregroundStyle(.secondary)
            ExportFieldErrorText(field: .destination, viewModel: viewModel)
        }
    }
}
