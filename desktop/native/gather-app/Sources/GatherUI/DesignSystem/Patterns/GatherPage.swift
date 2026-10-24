import SwiftUI

/// 全局页的页面骨架：标题、副标题、背景。
///
/// 不强制内容容器（List / Form / HSplitView 都能用）；也不接管 toolbar / inspector，
/// 这两类 chrome 在后续 `GatherChrome` 中统一。这里先把“页面背景 + 标题”的重复收口。
public extension View {
    func gatherPage(
        title: String,
        subtitle: String? = nil,
        surface: GatherSurfaceRole = .canvas
    ) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gatherSurface(surface)
            .navigationTitle(title)
            .modifier(GatherPageSubtitle(subtitle: subtitle))
    }
}

/// 空副标题不要写进导航栏：`.navigationSubtitle("")` 在 Settings 等页面
/// 会引入一个没有语义的空 modifier。
struct GatherPageSubtitle: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

/// 显式容器形式，便于新页面从零开始按“页面配方”写。
public struct GatherPage<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let surface: GatherSurfaceRole
    private let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        surface: GatherSurfaceRole = .canvas,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.surface = surface
        self.content = content()
    }

    public var body: some View {
        content.gatherPage(title: title, subtitle: subtitle, surface: surface)
    }
}
