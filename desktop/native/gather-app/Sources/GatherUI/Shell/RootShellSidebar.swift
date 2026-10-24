// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellSidebar.swift
// 侧栏：工作台 + 最近工作区 + 资料库。
//
// 设计决定（2026-10-23 第二轮）：
// - “当前会话”单条是瞬时上下文，不能支撑多工作区切换；改为最近工作区列表。
// - 工作台是页面，不再放进“工作区”分组；资料库只放全局图库 / 人脸库。
// - 最多 5 个最近会话；当前会话若不在列表中，用深链回退行补上。
// - 选中当前会话时不重新导航，保留当前页签。
import SwiftUI
import GatherProtocol

// MARK: - 侧栏条目

private enum SidebarItem: Hashable {
    case dashboard
    case session(String)
    case library
    case web(RootNavigation.WebPage)
}

// MARK: - 侧栏（原生）

extension RootView {
    var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            // 工作台是全局页面，置顶；不混进“工作区”分组。
            sidebarLabel(copy.workbench, systemImage: "house")
                .tag(SidebarItem.dashboard)

            Section {
                ForEach(recentSidebarSessions, id: \.id) { session in
                    sidebarSessionLabel(session)
                        .tag(SidebarItem.session(session.id))
                }
                if let fallbackSessionId {
                    sidebarSessionLabel(
                        fallbackSessionName(for: fallbackSessionId),
                        systemImage: "rectangle.stack"
                    )
                    .tag(SidebarItem.session(fallbackSessionId))
                    .help(fallbackSessionName(for: fallbackSessionId))
                }
                if recentSidebarSessions.isEmpty, fallbackSessionId == nil {
                    Text(l10n("暂无工作区"))
                        .font(GatherFont.labelRegular)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            } header: {
                Text(l10n("最近工作区"))
            }

            Section {
                sidebarLabel(copy.globalLibrary, systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarItem.library)
                // F03：人物库是**全局一级目的地**（跨工作区人物管理），
                // 与工作区内的人脸审核对象范围不同，不能互相替代。
                sidebarLabel(
                    RootNavigation.WebPage.persons.title(with: l10n),
                    systemImage: RootNavigation.WebPage.persons.systemImage
                )
                .tag(SidebarItem.web(.persons))
            } header: {
                Text(l10n("资料库"))
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

    /// 最近 5 个工作区；当前会话提前到首位，保证高亮行始终在列表里。
    private var recentSidebarSessions: [SessionData] {
        var list = viewModel.sessions
        if let currentId = currentSidebarSessionId,
           let index = list.firstIndex(where: { $0.id == currentId }) {
            let current = list.remove(at: index)
            list.insert(current, at: 0)
        }
        return Array(list.prefix(5))
    }

    /// 当前会话存在、但不在已加载列表里（深链/列表尚未刷新）时的回退 id。
    private var fallbackSessionId: String? {
        guard let currentId = currentSidebarSessionId,
              !recentSidebarSessions.contains(where: { $0.id == currentId }) else {
            return nil
        }
        return currentId
    }

    private func fallbackSessionName(for sessionId: String) -> String {
        let name = sessionStore.workspaces[sessionId]?.sessionName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? copy.currentSession : name
    }

    /// 重名工作区：同名时补一个短 id 次行，避免三行完全一样。
    private var duplicateSessionNames: Set<String> {
        let names = recentSidebarSessions.map(\.name)
        return Set(names.filter { name in names.filter { $0 == name }.count > 1 })
    }

    /// 会话行：原生 Label 保留系统选中态/图标着色；尾部照片数帮助区分重名工作区。
    private func sidebarSessionLabel(_ session: SessionData) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Label(session.name, systemImage: "rectangle.stack")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(session.photoCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if duplicateSessionNames.contains(session.name) {
                Text("#\(String(session.id.prefix(4)).uppercased())")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(sidebarSessionHelp(session))
    }

    private func sidebarSessionHelp(_ session: SessionData) -> String {
        let base = l10n.plural("%@ · %lld 张照片", count: session.photoCount, session.name)
        guard duplicateSessionNames.contains(session.name) else { return base }
        return "\(base) · #\(String(session.id.prefix(4)).uppercased())"
    }

    private func sidebarSessionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// 全局条目：交给系统 List 的选中态；不要给整行上品牌色。
    private func sidebarLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }

    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { currentSidebarItem },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
                case .dashboard: navigation.selectDashboard()
                case .session(let id):
                    // 已选中的当前会话不重新导航，避免把图库/检查器状态重置到控制中心。
                    if navigation.currentSessionId != id {
                        navigation.openSession(id)
                    }
                case .library: navigation.selectLibrary()
                case .web(let page): navigation.selectWeb(page)
                }
            }
        )
    }

    private var currentSidebarItem: SidebarItem? {
        switch navigation.route {
        case .dashboard: return .dashboard
        case .library: return .library
        case .persons: return .web(.persons)
        case .session(let id, _):
            // 任一工作区子页都必须保持当前会话高亮。
            return .session(id)
        }
    }

    /// 侧栏最近工作区使用的工作区 id（当前优先，其次最近一次）。
    /// 4a-2c：lastSessionId 已迁 SessionStore（activate 唯一写入）。
    var currentSidebarSessionId: String? {
        navigation.currentSessionId ?? sessionStore.lastSessionId
    }
}
