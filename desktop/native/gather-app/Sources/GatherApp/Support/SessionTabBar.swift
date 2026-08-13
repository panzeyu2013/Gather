// 工作区公共页签栏：对齐旧版 SessionDetail/index.tsx 的 6 页签（浏览/相似度/
// 人脸/重复/挑片/导出），active 由页面传入（数据驱动），修复旧实现中
// "浏览"恒 active、其他工作区页无页签栏的差异。
import SwiftUI

/// 页签栏当前高亮项：browse=浏览（gallery），similarity=相似度，其余为 SessionTab。
enum SessionTabSelection: Equatable {
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

    @State private var hoveredKey: String?

    var body: some View {
        HStack(spacing: 2) {
            tabButton(key: "browse", title: GatherLocalization.l("浏览"), selected: selection == .browse, action: onBrowse)
            tabButton(key: "similarity", title: GatherLocalization.l("相似度"), selected: selection == .similarity, action: onSimilarity)
            ForEach(SessionTab.allCases) { tab in
                tabButton(key: tab.rawValue, title: tabTitle(tab), selected: selection == .tab(tab)) {
                    onSelectTab(tab)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func tabTitle(_ tab: SessionTab) -> String {
        switch tab {
        case .control: return GatherLocalization.l("控制中心")
        case .faceKw: return GatherLocalization.l("人脸")
        case .duplicates: return GatherLocalization.l("重复")
        case .culling: return GatherLocalization.l("挑片")
        case .export: return GatherLocalization.l("导出")
        }
    }

    private func tabButton(
        key: String,
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.gatherPrimary : Color.gatherTextPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? GatherTheme.primarySoft : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredKey == key && !selected
                      ? GatherTheme.primary.opacity(0.08)
                      : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if selected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(GatherTheme.primary)
                    .frame(height: 2)
            }
        }
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
    }
}
