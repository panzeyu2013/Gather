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
        HStack(spacing: GatherMetrics.Space.xs) {
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
        .padding(.horizontal, GatherMetrics.Space.s)
        .padding(.vertical, GatherMetrics.Space.xs)
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

/// 可见区细节贴片（tiled detail）的可见性策略（纯逻辑，可单测）。
///
/// Wave2（20-culling-browse #3）：旧实现只有当前格贴片——2 图并排判合焦时
/// 非当前格是 2560px 基准位图放大，"并排比哪张更实"根本做不了。
/// 新策略：1/2 图全给（判焦主战场）；3 图/4 图/Survey 只给当前 + hover
/// （同时解 N 块细节会打满解码闸门，而多点同屏判读靠 hover 已经够）。
enum CullingDetailTilePolicy {
    static func showsTile(compareCount: Int, isCurrent: Bool, isHovered: Bool) -> Bool {
        if compareCount <= 2 { return true }
        return isCurrent || isHovered
    }
}

/// 查看器裸键（+ 是否按着 ⇧）→ 叠加层/查看模式动作（纯逻辑，可单测）。
///
/// 键位来源：20-culling-browse #8 的 H/F/R/C。裸 F 在 Wave1 曾是「专注模式」，
/// Wave2 按评审的设计意图把裸 F 还给**合焦掩膜**、专注模式改为 ⇧F：
/// H = 直方图、F = 合焦掩膜、R = 设/取消参考、C = 对比模式循环（需已设参考）。
enum CullingViewerShortcutKey {
    enum Action: Equatable {
        case toggleHistogram
        case toggleFocusMask
        case toggleFocusMode
        case toggleReference
        case cycleReferenceMode
    }

    static func action(characters: String, shift: Bool) -> Action? {
        switch characters.lowercased() {
        case "h": return .toggleHistogram
        case "f": return shift ? .toggleFocusMode : .toggleFocusMask
        case "r": return .toggleReference
        case "c": return .cycleReferenceMode
        default: return nil
        }
    }
}
