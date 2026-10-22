// 共享参数控件：对齐旧版 SliderInput.tsx —— 滑块 + 数字输入框双向联动，
// 键入精确值 blur/回车时钳制到范围，拖动滑块实时更新。
import SwiftUI

public struct SliderInputView: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var text: String = ""
    @FocusState private var focused: Bool

    /// Cut 4 / 4b-2l：范围 tooltip 在渲染期解析；模板走 l10n.format（4 个参数按序配对）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        format: @escaping (Double) -> String = { String(format: "%.2f", $0) }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 10) {
            // 标签自适应（旧版是 110pt 固定列宽 = CSS 栅格直译）。
            Text(title)
                .font(.body)
                .lineLimit(1)
                .layoutPriority(1)
            Slider(value: $value, in: range, step: step ?? 0)
                .accessibilityLabel(title)
                .accessibilityValue(Text(format(value)))
                .onChange(of: value) { _, newValue in
                    syncText(from: newValue)
                }
            TextField(format(value), text: $text)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityLabel(title)
                .focused($focused)
                .onSubmit { commitText() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitText() }
                }
                .onAppear { syncText(from: value) }
        }
        .help(l10n.format("%@：%@（范围 %@–%@）", title, format(value), format(range.lowerBound), format(range.upperBound)))
    }

    private func syncText(from newValue: Double) {
        let newText = format(newValue)
        if text != newText { text = newText }
    }

    /// 输入框提交：解析失败或越界时回退为当前滑块值（blur clamp）。
    private func commitText() {
        if let parsed = Double(text.replacingOccurrences(of: "，", with: ".")) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        } else {
            value = value // 触发 onChange 同步回原始值
            syncText(from: value)
        }
    }
}

public struct SliderInputIntView: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    @State private var text: String = ""
    @FocusState private var focused: Bool

    /// Cut 4 / 4b-2l：整数滑杆范围 tooltip 同样在渲染期解析。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public init(title: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title
        self._value = value
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .lineLimit(1)
                .layoutPriority(1)
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(Text("\(value)"))
            TextField("\(value)", text: $text)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
                .focused($focused)
                .onSubmit { commitText() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitText() }
                }
                .onAppear { text = "\(value)" }
                .onChange(of: value) { _, newValue in
                    if text != "\(newValue)" { text = "\(newValue)" }
                }
        }
        .help(l10n.format("%@：%lld（范围 %lld–%lld）", title, value, range.lowerBound, range.upperBound))
    }

    private func commitText() {
        if let parsed = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        } else {
            text = "\(value)"
        }
    }
}
