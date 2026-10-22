// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView+FaceAnalysis.swift
// Cut 4 / 4c-2d：人脸分析滑杆分组（常规 + 高级参数，原 SettingsView.swift 1775-1820 行）。
// 纯搬移：Slider 的 editing 回调仍在松手时提交（commitSlider），无障碍标签不变。
import SwiftUI
import GatherProtocol

extension SettingsView {

    // MARK: 人脸分析

    var faceAnalysisSection: some View {
        Section(l10n("人脸分析")) {
            ForEach(SettingsViewModel.generalSliders) { slider in
                sliderRow(slider)
            }
            ForEach(SettingsViewModel.advancedSliders) { slider in
                sliderRow(slider)
            }
        }
    }

    private func sliderRow(_ slider: SliderSetting) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { viewModel.sliderValue(for: slider.key, defaultValue: slider.defaultValue) },
                    set: { viewModel.sliderValues[slider.key] = $0 }
                ), in: slider.min...slider.max, step: slider.step) { editing in
                    if !editing { viewModel.commitSlider(slider, with: l10n) }
                }
                .accessibilityLabel(l10n(slider.zhLabel))
                .accessibilityValue(Text(sliderValueWithUnit(slider)))

                Text(sliderValueWithUnit(slider))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        } label: {
            settingLabel(slider.zhLabel, description: slider.zhDesc)
        }
    }

    private func sliderValueWithUnit(_ slider: SliderSetting) -> String {
        let value = viewModel.sliderValueText(slider)
        switch slider.key {
        case "max_detections", "default_min_samples":
            return l10n.format("%@ 张", value)
        case "onnx_threads":
            return l10n.format("%@ 线程", value)
        default:
            return value
        }
    }
}
