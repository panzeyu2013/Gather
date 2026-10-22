// 工作区子导航（原生版）。
//
// 旧实现是手搓的 7 个 Button + 选中下划线（Web 页签外观）；现改用系统
// 分段控件 Picker(.segmented)：圆角、选中高亮、键盘遍历、浅色/深色与
// 增强对比度全部由 AppKit 提供，粘贴到工具栏后自动获得玻璃材质。
import SwiftUI

/// 页签栏当前高亮项：browse=浏览（gallery），similarity=相似度，其余为 SessionTab。
enum SessionTabSelection: Hashable {
    case browse
    case similarity
    case tab(SessionTab)
}

struct SessionTabBar: View {
    /// 当前高亮页签（数据驱动，禁止硬编码）。
    let selection: SessionTabSelection
    let onBrowse: () -> Void
    let onSimilarity: () -> Void
    let onSelectTab: (SessionTab) -> Void

    /// Cut 4 / 4b-2l：标签在渲染期按当前界面语言解析（无 store 时默认中文）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        Picker("", selection: binding) {
            Text(l10n("浏览"))
                .tag(SessionTabSelection.browse)
            Text(l10n("相似度"))
                .tag(SessionTabSelection.similarity)
            ForEach(SessionTab.allCases) { tab in
                Text(SessionTabBar.tabTitle(tab, with: l10n))
                    .tag(SessionTabSelection.tab(tab))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(l10n("工作区页面"))
    }

    private var binding: Binding<SessionTabSelection> {
        Binding(
            get: { selection },
            set: { newValue in
                switch newValue {
                case .browse: onBrowse()
                case .similarity: onSimilarity()
                case .tab(let tab): onSelectTab(tab)
                }
            }
        )
    }

    /// 页签名：非 View 静态函数，语言由调用方显式传入（渲染期解析）。
    static func tabTitle(_ tab: SessionTab, with l10n: L10n) -> String {
        switch tab {
        case .control: return l10n("控制中心")
        case .faceKw: return l10n("人脸")
        case .duplicates: return l10n("重复")
        case .culling: return l10n("挑片")
        case .export: return l10n("导出")
        }
    }
}

// MARK: - 会话页统一窗口 chrome

extension View {
    /// 会话页（图库 / 相似度 / 控制中心 / 人脸 / 重复 / 挑片 / 导出）的窗口 chrome：
    /// 窗口标题副标题走系统，页面切换改为内容区顶部一条**紧凑页签行**。
    ///
    /// 为什么不再放 toolbar(.principal)（F01 / F06）：
    /// - 7 段 Picker 的固有宽度和「返回 + C1 胶囊 + 当前页主动作」抢同一份工具栏
    ///   预算，1180pt 默认窗口下会把「开始导出」挤进 » 溢出菜单；
    /// - 更关键的是，工具栏会在目的地切换的**同一轮**约束更新里改变固有宽度，
    ///   与 NavigationSplitView 列宽、.inspector 列宽协商叠加，是 AppKit
    ///   「more Update Constraints in Window passes than there are views」崩溃
    ///   （F01）的放大器。页签行留在内容区后，工具栏只服务当前页动作。
    ///
    /// 保留旧版没有的东西：工作区名（窗口标题）+ 功能名（窗口副标题）始终可见。
    func sessionPageChrome(
        subtitle: String?,
        selection: SessionTabSelection,
        onBrowse: @escaping () -> Void,
        onSimilarity: @escaping () -> Void,
        onSelectTab: @escaping (SessionTab) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            SessionPageTabStrip(
                selection: selection,
                onBrowse: onBrowse,
                onSimilarity: onSimilarity,
                onSelectTab: onSelectTab
            )
            Divider()
            self
        }
        .navigationSubtitle(subtitle ?? "")
    }
}

/// 内容区顶部的紧凑页签行。
///
/// **宽度策略（N01 崩溃的直接原因之一）**：7 段分段控件的**固有宽度实测 532pt**。
/// 它决定的不只是视觉宽度——NSHostingView 会把「内容最小宽度」经
/// SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:) 报给
/// NavigationSplitView；最小窗口（860pt）减掉侧栏（180pt）只剩 680pt 给内容区，
/// 而页签行 532pt 叠加 .inspector 列宽（300pt）= 876pt > 680pt，AppKit 于是
/// 反复重算约束直到抛 NSGenericException（SIGABRT）。
///
/// 因此这里用 ViewThatFits 做两档：宽窗口保留一眼看全的分段控件；
/// 窄窗口退化成菜单（固有宽度约 100pt），会话页的最小宽度不再被页签行顶住。
struct SessionPageTabStrip: View {
    let selection: SessionTabSelection
    let onBrowse: () -> Void
    let onSimilarity: () -> Void
    let onSelectTab: (SessionTab) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                SessionTabBar(
                    selection: selection,
                    onBrowse: onBrowse,
                    onSimilarity: onSimilarity,
                    onSelectTab: onSelectTab
                )
                .fixedSize()
                SessionTabMenu(
                    selection: selection,
                    onBrowse: onBrowse,
                    onSimilarity: onSimilarity,
                    onSelectTab: onSelectTab
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(GatherTheme.windowBackground)
    }
}

/// 窄窗口下的页签菜单：标签是**当前页面名**（仍然一眼看得出自己在哪一页），
/// 菜单里是同一组目的地，顺序与分段控件一致。
struct SessionTabMenu: View {
    let selection: SessionTabSelection
    let onBrowse: () -> Void
    let onSimilarity: () -> Void
    let onSelectTab: (SessionTab) -> Void

    /// Cut 4 / 4b-2l：窄窗菜单与分段控件同一语言源（渲染期解析）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var currentTitle: String {
        switch selection {
        case .browse: return l10n("浏览")
        case .similarity: return l10n("相似度")
        case .tab(let tab): return SessionTabBar.tabTitle(tab, with: l10n)
        }
    }

    var body: some View {
        Menu {
            Button(l10n("浏览")) { onBrowse() }
            Button(l10n("相似度")) { onSimilarity() }
            Divider()
            ForEach(SessionTab.allCases) { tab in
                Button(SessionTabBar.tabTitle(tab, with: l10n)) { onSelectTab(tab) }
            }
        } label: {
            Label(currentTitle, systemImage: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(l10n("工作区页面"))
        .help(l10n("切换工作区页面"))
    }
}
