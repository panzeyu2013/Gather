// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellSidebar.swift
// Cut 4 / 4c-2k：侧栏（导航条目 / 选中语义 / 当前会话回退）从 RootView.swift 原样搬移。
//
// 侧栏仍是 NavigationSplitView + List(selection:).listStyle(.sidebar)；选中绑定
// 的读写语义、图库/相似度/会话页签落回「当前会话」的判定、lastSessionId 回退
// 全部逐字保留（4a-2c：lastSessionId 由 SessionStore.activate 唯一写入）。
import SwiftUI

// MARK: - 侧栏条目

private enum SidebarItem: Hashable {
    case dashboard
    case currentSession(String)
    case library
    case web(RootNavigation.WebPage)
}

// MARK: - 侧栏（原生）

extension RootView {
    var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            Section {
                Label(copy.workbench, systemImage: "house")
                    .tag(SidebarItem.dashboard)
                if let sessionId = currentSidebarSessionId {
                    Label(copy.currentSession, systemImage: "rectangle.stack")
                        .tag(SidebarItem.currentSession(sessionId))
                }
                Label(copy.globalLibrary, systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarItem.library)
                // F03：人物库是**全局一级目的地**（跨工作区人物管理），
                // 与工作区内的人脸审核对象范围不同，不能互相替代。
                Label(RootNavigation.WebPage.persons.title(with: l10n), systemImage: RootNavigation.WebPage.persons.systemImage)
                    .tag(SidebarItem.web(.persons))
            }
            // 设置不占侧栏条目：macOS 惯例是应用菜单里的「设置…」（⌘,）
            // 打开独立的设置窗口，与 Xcode / Safari / 访达一致。
        }
        .listStyle(.sidebar)
        .navigationTitle("Gather")
        .toolbar {
            rootSidebarToolbar
        }
    }

    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { currentSidebarItem },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
                case .dashboard: navigation.selectDashboard()
                case .currentSession(let id): navigation.openSession(id)
                case .library: navigation.selectLibrary()
                case .web(let page): navigation.selectWeb(page)
                }
            }
        )
    }

    private var currentSidebarItem: SidebarItem? {
        switch navigation.destination {
        case .dashboard: return .dashboard
        case .library: return .library
        case .page(let page): return .web(page)
        case .gallery, .similarity:
            // 图库/相似度页在侧栏不单列条目，落回「当前会话」。
            if let id = navigation.currentSessionId { return .currentSession(id) }
            return nil
        case .sessionTab:
            // F09：任一工作区子页（控制中心/人脸/重复/挑片/导出）都必须保持
            // 「当前会话」选中态——否则用户进入子页后侧栏无高亮，失去
            // 「我在哪个工作区」的稳定提示。
            if let id = navigation.currentSessionId { return .currentSession(id) }
            return nil
        }
    }

    /// 侧栏「当前会话」条目使用的工作区 id（当前优先，其次最近一次）。
    /// 4a-2c：lastSessionId 已迁 SessionStore（activate 唯一写入）。
    var currentSidebarSessionId: String? {
        navigation.currentSessionId ?? sessionStore.lastSessionId
    }
}
