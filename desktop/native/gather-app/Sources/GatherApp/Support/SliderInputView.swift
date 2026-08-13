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
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .frame(width: GatherTheme.formLabelWidth, alignment: .leading)
            Slider(value: $value, in: range, step: step ?? 0)
                .accessibilityLabel(title)
                .accessibilityValue(Text(format(value)))
                .onChange(of: value) { _, newValue in
                    syncText(from: newValue)
                }
            TextField(format(value), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .accessibilityLabel(title)
                .focused($focused)
                .onSubmit { commitText() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitText() }
                }
                .onAppear { syncText(from: value) }
        }
        .help(String(format: GatherLocalization.l("%@：%@（范围 %@–%@）"), title, format(value), format(range.lowerBound), format(range.upperBound)))
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

    public init(title: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title
        self._value = value
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .frame(width: GatherTheme.formLabelWidth, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(Text("\(value)"))
            TextField("\(value)", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.center)
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
        .help(String(format: GatherLocalization.l("%@：%lld（范围 %lld–%lld）"), title, value, range.lowerBound, range.upperBound))
    }

    private func commitText() {
        if let parsed = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        } else {
            text = "\(value)"
        }
    }
}
