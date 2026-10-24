import SwiftUI

/// 页面 / 容器的表面角色。
///
/// 这是“页面背景”的语义入口，不是卡片 API。卡片仍用 `gatherCard`；
/// 查看器使用固定暗色 `.viewer`，不跟随浅色 / 深色。
public enum GatherSurfaceRole: Sendable {
    case canvas
    case surface
    case surfaceMuted
    case viewer

    var color: Color {
        switch self {
        case .canvas: return GatherTheme.canvas
        case .surface: return GatherTheme.surface
        case .surfaceMuted: return GatherTheme.surfaceMuted
        case .viewer: return GatherTheme.viewerBackground
        }
    }
}

public extension View {
    /// 给页面或容器铺一层语义表面。不要用它替代 `gatherCard`。
    func gatherSurface(_ role: GatherSurfaceRole = .canvas) -> some View {
        background(role.color)
    }
}
