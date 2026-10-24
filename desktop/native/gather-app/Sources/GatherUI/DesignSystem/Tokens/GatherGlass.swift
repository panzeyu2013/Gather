import SwiftUI

/// Liquid Glass（macOS 26 / macOS 27）适配层。
///
/// ## 为什么需要这一层
///
/// app 的**自动**外观切换是由 Mach-O 里记录的 SDK 版本决定的
/// （见 `Package.swift` 里 `LC_BUILD_VERSION.sdk` 的说明）——只要链接的是
/// macOS 26+ SDK，系统组件就自动获得 Liquid Glass。这一层只负责 Apple 要求的
/// **手工接入**部分。
///
/// ## 铁律：内容层不用玻璃
///
/// Apple HIG《Materials》：
///
/// > Liquid Glass forms a distinct functional layer for controls and navigation
/// > elements … **Don't use Liquid Glass in the content layer.** … Instead, use
/// > standard materials for elements in the content layer, such as app backgrounds.
///
/// 所以：
/// - **卡片、列表行、表单行、正文背景 → 一律标准材质**（`GatherTheme.contentBackground`），
///   这里不提供任何「把卡片变玻璃」的入口，避免被误用。
/// - **只有浮在内容之上的功能层**（toast、查看器控制条、浮动选择栏）用玻璃。
///
/// 唯一有据可循的例外是「瞬时交互控件」（滑杆/开关的滑块），那由系统自己处理。
///
/// ## 可用性
///
/// app 仍部署到 macOS 14，所以每个 26.0 / 26.1 / 27.0 的 API 都必须门控；
/// 低版本回退到改造前的等价实现，行为不降级。
extension View {
    /// **功能层**表面：浮在内容之上的控件容器（toast / 查看器控制条 / 浮动选择栏）。
    ///
    /// - macOS 26+：真正的 Liquid Glass。
    /// - macOS 14–15：`.regularMaterial` + 分隔线描边（改造前的实现）。
    ///
    /// - Parameters:
    ///   - cornerRadius: 容器圆角。
    ///   - clear: 浮在照片/视频**媒体**之上时传 `true`。Apple 规定 `.clear` 只用于
    ///     媒体背景，且媒体偏亮时要自己叠一层暗化（调用方负责，例如挑片查看器
    ///     本来就有深色底）。
    ///   - bordered: 低版本回退时是否画一圈分隔线。
    @ViewBuilder
    func gatherFunctionalSurface(
        cornerRadius: CGFloat = GatherTheme.Radius.group,
        clear: Bool = false,
        bordered: Bool = true
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(clear ? .clear : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background(.regularMaterial, in: shape)
                .overlay {
                    if bordered {
                        shape.strokeBorder(GatherTheme.hairline, lineWidth: 1)
                    }
                }
        }
    }

    /// 内容区的**主要动作**按钮。
    ///
    /// macOS 26+ 用系统的 glass 按钮样式（Apple：「Instead of creating buttons with
    /// custom Liquid Glass effects, you can adopt the look and feel of the material
    /// with minimal code」）；低版本回退 `.borderedProminent`。
    @ViewBuilder
    package func gatherPrimaryActionButton() -> some View {
        if #available(macOS 26.0, *) {
            self.tint(GatherTheme.accentFill)
                .buttonStyle(.glassProminent)
        } else {
            self.tint(GatherTheme.accentFill)
                .buttonStyle(.borderedProminent)
        }
    }

    /// 内容区的**次要动作**按钮：macOS 26+ 用 glass，低版本回退 bordered。
    @ViewBuilder
    package func gatherSecondaryActionButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

}
