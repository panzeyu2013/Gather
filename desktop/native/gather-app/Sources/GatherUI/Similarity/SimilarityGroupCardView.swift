// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityGroupCardView.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出分组卡（原 820-942 行，private -> internal）。
// 纯搬移：DisclosureGroup / 选择行 / 代表缩略图 / 展开成员与 hover 描边逐字未动；
// 改名为 SimilarityGroupCardView：Duplicates 侧已占用 internal 的
// DuplicatesGroupCardView，原 file-private 的 GroupCardView 同名易误解析。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 分组卡片（TS GroupCard：代表缩略图 + 标签 + 计数 + 展开成员）

/// 原生容器（.gatherCard()）+ 原生 DisclosureGroup；选中态用品牌 accent 描边
/// （强调色语义），不再自绘卡片底色与灰色边框。
struct SimilarityGroupCardView: View {
    let group: SimilarityGroup
    let selected: Bool
    let expanded: Bool
    let showAllMembers: Bool
    let onToggleSelected: () -> Void
    let onToggleExpanded: () -> Void
    let onToggleShowAll: () -> Void
    /// 打开成员照片（透传给 MemberCellView）。
    var onOpenPhoto: ((String) -> Void)? = nil

    private static let truncatedMemberLimit = 24
    /// 代表缩略图 64pt。
    private static let representativeThumbSize = 64.0

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Cut 4 / 4b-2c：语言源由外壳经 environment 下发（与页面同一来源），
    // 分组卡片不再读进程级语言。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: expansionBinding) {
                memberArea
                    .padding(.top, 8)
            } label: {
                cardLabel
            }
            // 选择行单独一行：勾选框不落在 DisclosureGroup 的标签点击区里，
            // 展开/选择互不误触。
            Toggle(isOn: selectionBinding) {
                Text(l10n.format("选择分组 %lld 张", group.count))
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .help(l10n("选择分组"))
        }
        .gatherCard()
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.group, style: .continuous)
                .strokeBorder(ringColor, lineWidth: selected ? 2 : 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var cardLabel: some View {
        HStack(spacing: 10) {
            PhotoThumbnailView(
                path: representative.path,
                size: 256,
                placeholderSize: CGSize(width: Self.representativeThumbSize, height: Self.representativeThumbSize)
            )
            .frame(width: Self.representativeThumbSize, height: Self.representativeThumbSize)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(l10n.plural("%lld 张照片", count: group.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var memberArea: some View {
        // 原生分隔线（旧版是 1pt Rectangle 手绘边框）。
        Divider()
        let visibleMembers = showAllMembers ? group.images : Array(group.images.prefix(Self.truncatedMemberLimit))
        let hasMore = group.images.count > Self.truncatedMemberLimit
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(visibleMembers, id: \.path) { image in
                SimilarityMemberCellView(path: image.path, onOpenPhoto: onOpenPhoto)
            }
        }
        if hasMore {
            HStack {
                Spacer(minLength: 0)
                Button(showAllMembers ? l10n("收起") : l10n.format("显示全部（共 %lld 张）", group.images.count)) {
                    onToggleShowAll()
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded },
            set: { _ in onToggleExpanded() }
        )
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { selected },
            set: { _ in onToggleSelected() }
        )
    }

    private var ringColor: Color {
        if selected { return GatherTheme.accent }
        // 悬停反馈用中性色，不占用品牌色做表面。
        return isHovered ? GatherTheme.separator : Color.clear
    }

    /// TS: rep = images.find(representative) ?? images[0]。
    private var representative: SimilarityImage {
        group.images.first { $0.representative == true } ?? group.images[0]
    }
}
