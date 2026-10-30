// GatherCollapsibleSection.swift
// DesignSystem/Patterns：可折叠的检查器分区。
//
// 为什么需要：检查器里有 14 个分区一路竖排，"当前照片"的决定被元数据/模板/导入
// 等低频入口顶到第三屏。折叠不是隐藏功能，而是**按使用频率排序**：高频区默认
// 展开、低频区默认收起，用户点一下仍然一步可达。
//
// 与 GatherInspectorSection 同一张卡片（同圆角、同 padding、同描边），
// 只是标题行变成可点开的按钮，折叠不改变任何业务行为。

import SwiftUI

package struct GatherCollapsibleSection<Content: View>: View {
    private let title: String
    private let systemImage: String?
    private let content: Content

    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    package init(
        _ title: String,
        systemImage: String? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: GatherMetrics.Motion.standard)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: GatherMetrics.Space.s) {
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                            .font(GatherFont.cardTitle)
                            .foregroundStyle(.primary)
                    } else {
                        Text(title)
                            .font(GatherFont.cardTitle)
                            .foregroundStyle(.primary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(GatherFont.label)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? [.isSelected] : [])
            .help(expanded ? l10n("收起") : l10n("展开"))

            if expanded {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.card, padding: 12, elevated: false)
    }
}
