// desktop/native/gather-app/Sources/GatherApp/Support/FaceClusterMontage.swift
// 人脸簇代表图：2x2 人脸裁切蒙太奇（F05 / N02）。
//
// 为什么不再用 LazyVGrid + aspectRatio：
// 单元格里的 FaceCropThumbnailView 是 GeometryReader 驱动的、**没有固有高度**；
// 放进 LazyVGrid 后，行的理想高度退化成 GeometryReader 的默认值（约 10pt），
// 蒙太奇就塌成一条色带（验收报告 N02 的「左侧只剩极窄图条」）。
// 这里改成由外层 GeometryReader 显式算出正方形网格：单元边长恒为
// (边长 − 间距) / 2，高度不再依赖任何子视图的固有尺寸。
import SwiftUI
import GatherCore

struct FaceClusterMontage: View {
    let cluster: FaceClusterData
    var gap: CGFloat = 2

    init(cluster: FaceClusterData, gap: CGFloat = 2) {
        self.cluster = cluster
        self.gap = gap
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width, geometry.size.height))
            let cell = max(0, (side - gap) / 2)
            Group {
                if cluster.members.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: GatherTheme.Radius.panel)
                            .fill(GatherTheme.secondaryContentBackground)
                        Text("\(cluster.size)")
                            .font(.title.weight(.semibold))
                            .foregroundStyle(GatherTheme.accent)
                    }
                    .frame(width: side, height: side)
                } else {
                    let members = Array(cluster.members.prefix(4))
                    VStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: gap) {
                                ForEach(0..<2, id: \.self) { column in
                                    let index = row * 2 + column
                                    if index < members.count {
                                        FaceCropThumbnailView(
                                            path: members[index].photoPath,
                                            bbox: members[index].bbox,
                                            loadSize: 512
                                        )
                                        .frame(width: cell, height: cell)
                                        .clipped()
                                    } else {
                                        Rectangle()
                                            .fill(GatherTheme.secondaryContentBackground.opacity(0.5))
                                            .frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: side, height: side, alignment: .topLeading)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.panel))
        .accessibilityHidden(true)
    }
}
