// GatherInspectorSection.swift
// DesignSystem/Patterns：检查器分组卡片的唯一实现。
//
// 收口前 Culling 用 GroupBox、Gallery 用私有 inspectorSection、Library 用
// supportCard，三种卡片各自维护标题字体/卡片圆角/内边距。Phase 4 收口后
// 检查器只认这一个容器：标题（可带 SF Symbol / 副标题）+ 内容 + 统一卡片。
import SwiftUI

package struct GatherInspectorSection<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let systemImage: String?
    private let content: Content

    /// - Parameters:
    ///   - title: 分区标题；nil = 无标题（例如整块就是一个 DisclosureGroup）。
    ///   - subtitle: 标题下的说明行（相似组等场景）。
    ///   - systemImage: 标题左侧的 SF Symbol（Library 的管理功能卡使用）。
    package init(
        _ title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .font(GatherFont.cardTitle)
                } else {
                    Text(title)
                        .font(GatherFont.cardTitle)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.card, elevated: false)
    }
}
