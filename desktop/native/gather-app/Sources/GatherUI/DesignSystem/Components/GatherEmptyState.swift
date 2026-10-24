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

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actions {
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
