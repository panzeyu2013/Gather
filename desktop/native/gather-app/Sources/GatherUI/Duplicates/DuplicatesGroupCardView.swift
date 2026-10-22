// desktop/native/gather-app/Sources/GatherUI/Duplicates/DuplicatesGroupCardView.swift
// Cut 4 / 4c-2g：从 DuplicatesView.swift 第 775-904 行移出分组卡（private -> internal）。
// 纯搬移：卡片层级、成员上限/展开、推荐徽章、保留/丢弃描边与无障碍标签逐字未动；
// 处置动作仍只上抛意图，确认弹窗与命令由 DuplicatesView 统一门控。
// 改名为 DuplicatesGroupCardView：SimilarityView.swift 里也有 file-private 的
// GroupCardView，internal 版同名会让对方的调用点解析到本类型（编译失败）。
import SwiftUI
import GatherProtocol

private let defaultMemberLimit = 12

/// 分组卡（对齐旧版 .groupCard：surface + 1px 边框 + radius-md + hover 反馈）。
/// 处置动作只上抛意图，确认弹窗与命令由 DuplicatesView 统一门控。
struct DuplicatesGroupCardView: View {
    let group: DuplicateGroup
    let viewModel: DuplicatesViewModel
    let onResolve: (DuplicateGroup, DupResolution) -> Void
    let onSetMemberKept: (DuplicateGroupMember, Bool) -> Void
    /// 打开成员照片（第三轮审计 E）：成员卡原先只有「保留/丢弃」，
    /// 用户看不到照片本体，无法判断该保留哪一张。
    var onOpenPhoto: ((String) -> Void)? = nil

    // Cut 4 / 4b-2j：卡片是独立 View，语言源同样从 environment 取（与页面同源）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        let recommendedId = DuplicatesViewModel.recommendation(in: group)?.id
        let members = viewModel.isExpanded(group.id) ? group.members : Array(group.members.prefix(defaultMemberLimit))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(groupTitle(with: l10n))
                    .font(.headline)
                if let resolution = group.resolution {
                    GatherBadge(
                        resolution == DupResolution.keepOne.rawValue
                            ? l10n("保留最佳")
                            : l10n("全部保留"),
                        tone: .success
                    )
                }
                Spacer()
                Menu(l10n("处理")) {
                    Button(l10n("保留最佳")) { onResolve(group, .keepOne) }
                    Button(l10n("保留全部")) { onResolve(group, .keepAll) }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(members, id: \.id) { member in
                    memberCard(member, recommended: member.id == recommendedId)
                }
            }
            if group.members.count > defaultMemberLimit {
                HStack {
                    Spacer()
                    Button(
                        viewModel.isExpanded(group.id)
                            ? l10n("收起")
                            : l10n.format("展开全部（共 %lld 张）", group.members.count)
                    ) {
                        viewModel.toggleExpanded(group.id)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
        .gatherCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupTitle(with: l10n))
    }

    private func groupTitle(with l10n: L10n) -> String {
        let type = group.groupType == .exact ? l10n("完全重复") : l10n("视觉相似")
        return l10n.plural("%@ · %lld 张照片", count: group.memberCount, type)
    }

    private func memberCard(_ member: DuplicateGroupMember, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // 对齐旧版 .memberThumb：1:1 方形、256 解码、10px 圆角（css:319-325）。
            PhotoThumbnailView(path: member.filepath, size: 256, placeholderSize: CGSize(width: 150, height: 150))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous))
                .accessibilityLabel(Text(member.filename))
                .overlay(alignment: .topTrailing) {
                    if recommended {
                        GatherBadge(l10n("推荐"), tone: .accent)
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 保留/丢弃文字徽标：红绿描边之外的冗余指示，
                    // 色弱/色盲用户可辨（复用成员按钮「保留/丢弃」词）。
                    GatherBadge(
                        member.isKept ? l10n("保留") : l10n("丢弃"),
                        tone: member.isKept ? .success : .error
                    )
                    .padding(4)
                }
            Text(member.filename).font(.callout).lineLimit(1)
            if let fileSize = member.fileSize {
                // %.1f 是本地化的单位模板；l10n.format 不传 locale（与全仓既有输出一致）。
                Text(l10n.format("%.1f MB", Double(fileSize) / 1024 / 1024))
                    .font(.callout).foregroundStyle(.secondary)
            }
            // 按钮文案 = 点击后执行的动作（不再显示当前状态，避免标签与动作相反）。
            HStack(spacing: 6) {
                if let onOpenPhoto {
                    Button(l10n("查看照片")) { onOpenPhoto(member.photoId) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(l10n("在图库中打开这张照片"))
                }
                Button(member.isKept ? l10n("丢弃") : l10n("保留")) {
                    onSetMemberKept(member, !member.isKept)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(member.isKept ? l10n("丢弃此照片") : l10n("保留此照片"))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .fill(member.isKept ? GatherTheme.contentBackground : GatherTheme.secondaryContentBackground)
        )
        .overlay(
            // 保留/排除用语义色描边区分；排除态不靠整卡降透明（可读性）。
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .strokeBorder((member.isKept ? GatherTheme.success : GatherTheme.error).opacity(0.5), lineWidth: 1)
        )
        .contextMenu {
            Button(l10n("保留")) {
                if !member.isKept { onSetMemberKept(member, true) }
            }
            Button(l10n("丢弃")) {
                if member.isKept { onSetMemberKept(member, false) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(member.filename)，\(member.isKept ? l10n("保留") : l10n("丢弃"))")
    }
}
