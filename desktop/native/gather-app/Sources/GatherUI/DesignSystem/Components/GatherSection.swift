import SwiftUI

/// 页面内分组：标题 + 内容，统一走 `gatherCard` 表面。
///
/// 用于 Dashboard / Library / Persons 这类内容页；检查器分组用后续的
/// `GatherInspectorSection`（它不使用 Form，避开 .inspector 的约束循环）。
public struct GatherSection<Content: View>: View {
    private let title: String?
    private let elevated: Bool
    private let content: Content

    public init(
        _ title: String? = nil,
        elevated: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.elevated = elevated
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            if let title {
                Text(title)
                    .gatherText(.sectionTitle)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.card, elevated: elevated)
    }
}
