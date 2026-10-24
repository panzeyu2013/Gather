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
/// 原系统 `.pickerStyle(.segmented)` 在 macOS 26/27 会渲染成一条横跨窗口的
/// 灰色轨道 + 每段之间一条分隔线 + 品牌实底选中段：既像 iOS 控件，又在页签
/// 数量多时把内容挤到下面。这里改为原生底色的紧凑标签条：
///
/// - 中性轨道 + 选中片（浅色白 / 深色提亮一档），用层次而不是大面积品牌色；
/// - 去掉逐项分隔线，只在“查看（浏览/相似度）”与“处理（控制中心…）”之间
///   留一条有语义的组分隔线；
/// - 行高从 44pt 收到 40pt，标签片 24pt，靠近工具栏的密度；
/// - 窄窗仍退化为菜单（沿用 N01 的约束预算教训）。
struct GatherSessionTabStrip: View {
    let current: SessionPage
    let onBack: () -> Void
    let onSelect: (SessionPage) -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    @State private var backHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                Circle()
                    .fill(backHovered ? GatherTheme.surfaceMuted : Color.clear)
            )
            .onHover { backHovered = $0 }
            .help(l10n("返回到上一页"))
            .accessibilityLabel(l10n("返回"))
            .keyboardShortcut("[", modifiers: .command)

            // N01：ViewThatFits + fixedSize 会把分段控件的 593 报成最小宽度；
            // inspector（min 220）展开后 860 窗口会触发 AppKit 约束循环。
            // GeometryReader 的最小宽度是 0：窄窗按实际宽度选 menu，宽窗选标签条。
            GeometryReader { proxy in
                if proxy.size.width >= 620 {
                    tabBar
                        .fixedSize()
                } else {
                    compactMenu
                        .fixedSize()
                }
            }
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, GatherChromeMetrics.tabStripHorizontalPadding)
        .padding(.vertical, GatherChromeMetrics.tabStripVerticalPadding)
        .background(GatherTheme.canvas)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SessionPage.tabOrder, id: \.self) { page in
                if page == .control {
                    Rectangle()
                        .fill(GatherTheme.hairline)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                SessionTabButton(
                    title: l10n(page.titleKey),
                    isSelected: page == current
                ) {
                    onSelect(page)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(GatherTheme.surfaceMuted.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(GatherTheme.hairline.opacity(0.7), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n("工作区页面"))
    }

    /// 窄窗退化：当前页 + chevron，和宽窗的选中片保持同一圆角与表面。
    ///
    /// 与 GatherMenuField 同一策略：外观由我们画，Menu 只做透明命中层，
    /// 避免 macOS 26 的 borderlessButton 菜单样式抹掉底色、把指示符移到左边。
    private var compactMenu: some View {
        HStack(spacing: 6) {
            Text(l10n(current.titleKey))
                .font(GatherFont.labelRegular)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(GatherTheme.controlSelection)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(GatherTheme.hairline, lineWidth: 0.5)
        )
        .overlay {
            Menu {
                ForEach(SessionPage.tabOrder) { page in
                    if page == .control {
                        Divider()
                    }
                    Button(l10n(page.titleKey)) { onSelect(page) }
                }
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(l10n("工作区页面"))
            .help(l10n("切换工作区页面"))
        }
        .fixedSize()
    }
}

/// 单个页签：白底选中片 + 悬停底色；按钮仍是键盘可达的原生 Button。
private struct SessionTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            // 隐藏的 semibold 双胞胎把宽度锁在“选中态”的宽度上：切换页签时
            // 后面的标签不会因为 semibold 略宽而横向抖动。
            ZStack {
                Text(title)
                    .font(GatherFont.labelRegular)
                    .fontWeight(.semibold)
                    .opacity(0)
                Text(title)
                    .font(GatherFont.labelRegular)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .accessibilityHidden(true)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? GatherTheme.controlSelection
                          : (hovered ? GatherTheme.surface.opacity(0.55) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isSelected ? GatherTheme.hairline : Color.clear,
                                lineWidth: 0.5
                            )
                    )
                    .shadow(
                        color: isSelected ? GatherTheme.shadowCard : .clear,
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                hovered = hovering
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
    }
}
