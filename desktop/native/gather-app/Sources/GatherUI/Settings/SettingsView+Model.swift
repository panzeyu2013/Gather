// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView+Model.swift
// Cut 4 / 4c-2d：高级设置折叠面板与模型推理行（存在性/路径/安装缺模型横幅/后端/目录），
// 原 SettingsView.swift 1454-1650 行。纯搬移：折叠默认收起（F11）、模型路径行仍保留
// focused + onSubmit + onChange 三件套（onChange 读写壳里的同一个 @FocusState）。
import SwiftUI
import AppKit
import GatherProtocol

extension SettingsView {

    // MARK: 高级设置（F11：默认收起）

    /// 高级设置：模型与推理 + 数据库 + 人脸算法参数。
    /// 这些是**实现细节**，摄影工作流里几乎不需要在首屏看到。
    var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvancedSettings) {
                VStack(alignment: .leading, spacing: 14) {
                    modelRows
                    ForEach(SettingsViewModel.advancedGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(l10n(group.titleZh))
                                .font(.headline)
                            ForEach(group.fields) { field in
                                fieldRow(field)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label(l10n("模型、推理与性能参数"), systemImage: "gearshape.2")
            }
        }
    }

    // MARK: 模型与推理

    /// 模型与推理行（由 advancedSection 在折叠面板内渲染，不再自带 Section 头）。
    @ViewBuilder
    private var modelRows: some View {
        Group {
            if let model = viewModel.modelStatus {
                presenceRow(l10n("检测模型"), presence: model.detectorModel)
                presenceRow(l10n("编码模型"), presence: model.encoderModel)

                modelPathRow(key: SettingsViewModel.faceEmbeddingModelSettingKey, label: l10n("专用人脸模型路径"))

                if !model.detectorModel.exists || !model.encoderModel.exists {
                    installBlock(model)
                }

                LabeledContent(l10n("模型信息")) {
                    Text(modelInfoText(model))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent(l10n("推理后端")) {
                    Picker("", selection: Binding(
                        get: { viewModel.backend },
                        set: { viewModel.setBackend($0) }
                    )) {
                        Text(l10n("自动")).tag("auto")
                        ForEach(model.availableBackends, id: \.value) { backend in
                            Text(backend.label).tag(backend.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                LabeledContent(l10n("模型目录")) {
                    HStack(spacing: 8) {
                        Text(model.modelResourcesDir)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(l10n("在访达中显示")) {
                            viewModel.openModelDirectory()
                        }
                    }
                }
            } else {
                LabeledContent(l10n("模型状态")) {
                    Text(l10n("正在读取模型状态…"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func modelInfoText(_ model: MLStatusData) -> String {
        if model.modelInfo.embeddingDim > 0 {
            return l10n.format(
                "Vision 人脸检测 · CoreML 身份识别 · 112×112 对齐输入 · %lld 维特征",
                Int64(model.modelInfo.embeddingDim)
            )
        }
        return l10n("Vision 人脸检测 · CoreML 身份识别 · 112×112 对齐输入 · 自定义模型")
    }

    /// 模型存在性：Label + SF Symbol + 语义色（不再是 ✓/✗ 字形 + 纯颜色信号）。
    private func presenceRow(_ label: String, presence: MLModelPresence) -> some View {
        LabeledContent(label) {
            Label(
                presence.exists ? l10n("可用") : l10n("未找到"),
                systemImage: presence.exists ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(presence.exists ? GatherTheme.success : GatherTheme.error)
            .accessibilityValue(presence.exists ? l10n("可用") : l10n("未找到"))
        }
    }

    private func modelPathRow(key: String, label: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { viewModel.edits[key] ?? viewModel.values[key] ?? "" },
                    set: { viewModel.edits[key] = $0 }
                ))
                .font(.body.monospaced())
                // N06：模型路径原先只响应回车，与首屏「文本与数字在离开输入框
                // 或按回车时保存」的承诺不一致（Tab 走开看起来改了、其实没写库）。
                // 这里与普通字段同一套语义：失焦提交 + 回车提交。
                .focused($focusedFieldKey, equals: key)
                .onSubmit { commitModelPath(key: key) }
                .onChange(of: focusedFieldKey) { previous, current in
                    if previous == key, current != key {
                        viewModel.saveModelPath(key: key, with: l10n)
                    }
                }
                .frame(minWidth: 180, maxWidth: 280)

                Button(l10n("选择…")) { pickingModelPathKey = key }
                Button(l10n("打开")) { viewModel.openModelPathDirectory(key: key) }
                    .help(l10n("在访达中显示该模型所在目录"))
            }
        }
    }

    /// 模型缺失横幅：SF Symbol + 语义色底 + 原生进度条。
    private func installBlock(_ model: MLStatusData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                l10n("人脸模型未找到。请恢复内置 SFace，或选择有效的 CoreML 模型。"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(GatherTheme.warning)

            Text(model.modelResourcesDir)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(l10n("打开模型文件夹")) {
                    viewModel.openModelDirectory()
                }
                Button(l10n("使用内置 SFace")) {
                    viewModel.save(key: SettingsViewModel.faceEmbeddingModelSettingKey, value: "", with: l10n)
                }
            }

            switch viewModel.downloadPhase {
            case .downloading(let filename, let percent, let step):
                ProgressView(value: min(1, max(0, percent / 100))) {
                    Text(step == .extracting
                        ? l10n("正在解压…")
                        : l10n.format("已下载 %d%%（%@）", Int(percent), filename))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .done:
                Label(l10n("人脸模型已安装"), systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(GatherTheme.success)
                    .font(.callout)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .fill(GatherTheme.warning.opacity(0.10))
        )
    }
}
