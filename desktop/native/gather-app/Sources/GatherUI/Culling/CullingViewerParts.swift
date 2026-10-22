// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewerParts.swift
// Cut 4 / 4c-2a：查看器零件——深色徽标 / 对比单元格 / 人脸对齐与拖拽几何。
// 原 CullingView.swift 3070-3106（徽标/单元格）、3122-3148（FaceAlign/PanOffset）行。
// FaceAlign / PanOffset 被 ReviewFixTests 与 Gallery 直接引用，保持 internal。
import SwiftUI
import GatherProtocol

/// 查看器图片上的深色底徽标：照片背景不可控，内容色固定用 viewerTextPrimary、
/// 图标用语义色，底色用 viewerChrome，保证任何照片上都可读。
struct ViewerBadge: View {
    let text: String
    let systemImage: String
    var tone: Color = GatherTheme.viewerTextPrimary
    /// 质量告警标记：4b-2a 起独立渲染，不再把 " ⚠" 拼进已本地化的徽标文案。
    var showsWarning = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tone)
            Text(text)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
            if showsWarning {
                // 纯装饰标记：徽标文案本身已由 qualityHelpText 说明告警内容。
                Text("⚠")
                    .foregroundStyle(tone)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
        .accessibilityElement(children: .combine)
    }
}

/// 查看器对比网格单元格：按已加载顺序（order 0 = 当前照片）。
struct ViewerCell: Identifiable {
    let id: String
    let order: Int
    let asset: CullingAsset
}

enum FaceAlign {
    static func offset(imageSize: CGSize, cellSize: CGSize, face: [Double], zoom: Double) -> CGSize {
        guard face.count >= 4, cellSize.width > 0, cellSize.height > 0, zoom > 0 else { return .zero }
        let centerX = min(max(face[0] + face[2] / 2, 0), 1)
        let centerY = min(max(face[1] + face[3] / 2, 0), 1)
        let displayed: CGSize
        if imageSize.width > 0, imageSize.height > 0 {
            let fit = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
            displayed = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        } else {
            // 图像尺寸未知（老库/未索引）：退回单元格近似，保守且不放大误差。
            displayed = cellSize
        }
        return CGSize(
            width: zoom * (0.5 - centerX) * displayed.width,
            height: zoom * (0.5 - centerY) * displayed.height
        )
    }
}

/// 拖拽平移的累积（审计 B-C2）：手势 translation 相对**本次手势起点**，
/// 必须叠加本次手势开始时的位移，否则松手再拖会弹回原点。
enum PanOffset {
    static func apply(start: CGSize, translation: CGSize) -> CGSize {
        CGSize(width: start.width + translation.width, height: start.height + translation.height)
    }
}
