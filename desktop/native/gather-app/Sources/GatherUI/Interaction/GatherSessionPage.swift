import SwiftUI

/// 会话页统一骨架：页签行 + 返回 + 背景 + 标题副标题 + 页面级可见性。
///
/// 页面只提供内容；工具栏/检查器仍由各页提供（C1/刷新等动作差异太大，
/// 等 toolbar 组件成熟后再收）。这已经删掉了 7 份 `sessionPageChrome` +
/// `onAppear/onDisappear` 的重复。
package struct GatherSessionPage<Content: View>: View {
    let page: SessionPage
    let workspace: SessionWorkspace
    let subtitle: String?
    private let content: Content

    @Environment(\.navigator) private var navigator

    package init(
        page: SessionPage,
        workspace: SessionWorkspace,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.page = page
        self.workspace = workspace
        self.subtitle = subtitle
        self.content = content()
    }

    package var body: some View {
        VStack(spacing: 0) {
            GatherSessionTabStrip(
                current: page,
                onBack: back,
                onSelect: open
            )
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .gatherSurface(.canvas)
        .modifier(GatherPageSubtitle(subtitle: subtitle))
        .onAppear {
            workspace.setPageVisible(page, true)
        }
        .onDisappear {
            workspace.setPageVisible(page, false)
        }
    }

    private func back() {
        switch page {
        case .gallery:
            navigator?.backFromGallery()
        case .similarity:
            navigator?.backFromSimilarity(sessionId: workspace.sessionId)
        default:
            navigator?.backFromSession(sessionId: workspace.sessionId)
        }
    }

    private func open(_ target: SessionPage) {
        switch target {
        case .gallery:
            navigator?.openGallery(workspace.sessionId)
        case .similarity:
            navigator?.openSimilarity(workspace.sessionId)
        default:
            navigator?.open(target, in: workspace.sessionId)
        }
    }
}

/// 7 段页签行（浏览 / 相似度 / 控制中心 / 人脸 / 重复 / 挑片 / 导出）。
///
/// 宽窗用分段控件，窄窗退化为菜单（沿用 N01 的约束预算教训）。
struct GatherSessionTabStrip: View {
    let current: SessionPage
    let onBack: () -> Void
    let onSelect: (SessionPage) -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(l10n("返回到上一页"))
            .accessibilityLabel(l10n("返回"))
            .keyboardShortcut("[", modifiers: .command)

            // N01：ViewThatFits + fixedSize 会把分段控件的 593 报成最小宽度；
            // inspector（min 220）展开后 860 窗口会触发 AppKit 约束循环。
            // GeometryReader 的最小宽度是 0：窄窗按实际宽度选 menu，宽窗选 picker。
            GeometryReader { proxy in
                if proxy.size.width >= 600 {
                    picker
                        .fixedSize()
                } else {
                    menu
                        .fixedSize()
                }
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, GatherChromeMetrics.tabStripHorizontalPadding)
        .padding(.vertical, GatherChromeMetrics.tabStripVerticalPadding)
        .background(GatherTheme.canvas)
    }

    private var picker: some View {
        Picker("", selection: Binding(
            get: { current },
            set: { onSelect($0) }
        )) {
            ForEach(SessionPage.tabOrder) { page in
                Text(l10n(page.titleKey)).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(l10n("工作区页面"))
    }

    private var menu: some View {
        Menu {
            ForEach(SessionPage.tabOrder) { page in
                if page == .control {
                    Divider()
                }
                Button(l10n(page.titleKey)) { onSelect(page) }
            }
        } label: {
            Label(l10n(current.titleKey), systemImage: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(l10n("工作区页面"))
        .help(l10n("切换工作区页面"))
    }
}
