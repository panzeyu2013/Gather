import SwiftUI

/// 统一空态 / 无结果态：系统 `ContentUnavailableView` 的薄包装。
///
/// 之前 `GatherCommonViews` 里的自定义空态有 0 个调用点，页面直接用了 31 个
/// `ContentUnavailableView`。这里保留系统外观，只统一初始化和占位布局。
public struct GatherEmptyState: View {
    public let icon: String
    public let title: String
    public let message: String?
    private let actions: AnyView?

    public init(icon: String, title: String, message: String? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = nil
    }

    public init(
        icon: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> some View
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = AnyView(actions())
    }

    /// 空态不是"系统告警"，而是"这里还什么都没有"。
    ///
    /// 因此不再直接用系统空态视图（灰图标 + 系统排版，读起来像报错页），
    /// 改成：品牌色细线图标 + 一句标题 + 至多两行说明 + 主动作。
    /// 仍然居中、仍然用系统字号，只把语气从"错误提示"换成"邀请"。
    public var body: some View {
        VStack(spacing: GatherMetrics.Space.m) {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(GatherTheme.accent)
                .accessibilityHidden(true)
            VStack(spacing: GatherMetrics.Space.xs) {
                Text(title)
                    .font(GatherFont.sectionTitle)
                if let message {
                    Text(message)
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            if let actions {
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GatherMetrics.Space.xl)
    }
}
