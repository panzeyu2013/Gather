import SwiftUI

/// 内容区搜索框：把搜索限制在内容列内，避免系统 toolbar search 在
/// 打开 inspector 时横跨内容列和检查器两栏。
///
/// 视觉沿用 GatherMenuField 的中性表面：surfaceMuted + hairline，
/// 聚焦时用品牌 accent 描边；高度 28pt，左右 9pt 内边距。
public struct GatherSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let clearLabel: String

    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String, clearLabel: String) {
        self._text = text
        self.prompt = prompt
        self.clearLabel = clearLabel
    }

    public var body: some View {
        HStack(spacing: GatherMetrics.Space.controlGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(GatherFont.labelRegular)
                .focused($isFocused)
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, GatherChromeMetrics.fieldHorizontalPadding)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(GatherTheme.surfaceMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isFocused ? GatherTheme.accent.opacity(0.6) : GatherTheme.hairline,
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}
