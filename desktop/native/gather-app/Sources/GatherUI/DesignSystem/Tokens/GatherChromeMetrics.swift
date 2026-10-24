import Foundation

/// 窗口 / 侧栏 / 检查器 / 内容区的共享尺寸预算。
///
/// 这里只放**布局预算**，不放具体页面的固定宽度。页面应引用这些常量，
/// 不要在各自文件里重复 220/260/360 之类的字面量。
public enum GatherChromeMetrics {
    public static let windowMinWidth: CGFloat = 860
    public static let windowMinHeight: CGFloat = 560

    public static let sidebarMinWidth: CGFloat = 180
    public static let sidebarIdealWidth: CGFloat = 220
    public static let sidebarMaxWidth: CGFloat = 260

    /// 内容区最小宽度预算：窗口最小宽度 − 侧栏最小宽度。
    public static var contentMinWidth: CGFloat { windowMinWidth - sidebarMinWidth }
    public static var contentMinHeight: CGFloat { windowMinHeight }

    /// 会话页签行内边距（宽/高），与页面内容 gutter 区分。
    public static let tabStripHorizontalPadding: CGFloat = 16
    public static let tabStripVerticalPadding: CGFloat = 8

    public static let inspectorMinWidth: CGFloat = 220
    /// 860 最小窗口：内容区 680 − 页签行最小 61 − Culling 内容最小 382
    /// 只剩 237；ideal 必须 ≤ 237，否则展开检查器会触发 N01 约束循环。
    public static let inspectorIdealWidth: CGFloat = 220
    public static let inspectorMaxWidth: CGFloat = 360
    /// Library 检查器允许更宽（目录管理内容更长）。
    public static let inspectorWideMaxWidth: CGFloat = 400
}
