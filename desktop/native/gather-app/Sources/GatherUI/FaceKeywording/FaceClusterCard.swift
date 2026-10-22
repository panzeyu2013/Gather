// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceClusterCard.swift
// Cut 4 / 4c-2b：簇卡片/蒙太奇（原 1629-1696 行）与簇计数文案（原 2137-2158 行）。
import SwiftUI
import GatherProtocol

extension FaceKeywordingView {
    /// TS ClusterCard：2x2 蒙太奇 + label + 成员数 + 绑定角色徽标。
    /// 选中/悬停不再用 translateY + 外发光（Web 惯用法），改为系统选中填充 + 描边，
    /// 并补右键菜单（绑定/解除绑定）。
    func clusterCard(_ cluster: FaceClusterData) -> some View {
        let isSelected = viewModel.selectedClusterId == cluster.id
        let isHovered = hoveredClusterId == cluster.id
        return Button {
            viewModel.select(cluster)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                clusterMontage(cluster)
                Text(cluster.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                // F13：size 是**人脸样本数**（face_cluster_members 行数），不是照片数；
                // 同一张照片里的两张脸是两个样本。只有成员未被截断时才敢报照片数。
                Text(cluster.sampleCountText(with: l10n))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let binding = cluster.binding {
                    GatherBadge(binding.roleName, tone: .success)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.group, style: .continuous)
                    .fill(isSelected
                        ? GatherTheme.selectionFill
                        : (isHovered ? GatherTheme.secondaryContentBackground : GatherTheme.contentBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.group, style: .continuous)
                    .strokeBorder(isSelected ? GatherTheme.accent : GatherTheme.separator, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredClusterId = cluster.id
            } else if hoveredClusterId == cluster.id {
                hoveredClusterId = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button(l10n("查看成员")) { viewModel.select(cluster) }
            if cluster.binding != nil {
                Button(l10n("解除绑定"), role: .destructive) {
                    pendingUnbind = PendingFaceUnbind(cluster: cluster)
                }
            }
        }
    }

    /// TS ClusterThumb：2x2 蒙太奇网格（前 4 成员，gap 2，圆角 8），
    /// 空成员时显示簇大小。
    /// 代表图：交给 FaceClusterMontage（显式正方形网格）。
    ///
    /// N02 回归点：原先这里是 LazyVGrid + 每个单元 .aspectRatio(1, .fit)。
    /// 单元里的 FaceCropThumbnailView 由 GeometryReader 驱动、没有固有高度，
    /// 网格行的理想高度于是退化成 GeometryReader 的默认值（约 10pt），
    /// 蒙太奇塌成一条色带。正方形边长必须在**外层**算好再下发给单元。
    private func clusterMontage(_ cluster: FaceClusterData) -> some View {
        FaceClusterMontage(cluster: cluster)
    }
}

// MARK: - 人脸簇计数文案（F13）

extension FaceClusterData {
    /// 精确照片数：仅当成员**未被截断**（members.count == size）时可计算，
    /// 截断时返回 nil —— 不猜数字。
    var distinctPhotoCount: Int? {
        guard members.count == size else { return nil }
        return Set(members.map(\.photoPath)).count
    }

    /// 「N 个人脸样本」/「N 个人脸样本 · M 张照片」。
    ///
    /// size 的真相源是 face_cluster_members 行数（人脸观测数），不是照片数：
    /// 同一张照片里的两张脸算两个样本（F13：计数单位不能误导）。
    /// Cut 4 / 4b-2b：文案在渲染期解析；`%lld` 数值格式原样保留，
    /// `l10n.format` 不传 locale（不引入千分位）。
    func sampleCountText(with l10n: L10n) -> String {
        let samples = l10n.plural("%lld 个人脸样本", count: size)
        guard let photos = distinctPhotoCount, photos != size else { return samples }
        return l10n.plural("%@ · %lld 张照片", count: photos, samples)
    }
}
