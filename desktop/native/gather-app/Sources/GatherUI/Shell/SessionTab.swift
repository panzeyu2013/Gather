// desktop/native/gather-app/Sources/GatherUI/Shell/SessionTab.swift
// Cut 4 / 4c-2c：会话页签枚举从 Gallery/GalleryView.swift 迁入 Shell（纯搬移）。
// 页签是会话页外壳的导航契约（RootView / SessionTabHost / SessionTabBar 共用），
// 不属于图库页面；页签文案仍由 SessionTabBar.tabTitle 提供，此处不持有。
/// 工作区页签（对齐 SessionDetail/index.tsx 的 NavLink；全部由 SwiftUI 承载）。
/// 页签文案统一由 SessionTabBar.tabTitle 提供（中英双语），此处不再持有。
package enum SessionTab: String, CaseIterable, Identifiable {
    case control = "control"
    case faceKw = "face-kw"
    case duplicates
    case culling
    case export

    package var id: String { rawValue }
}
