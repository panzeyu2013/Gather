// desktop/native/gather-app/Sources/GatherUI/Culling/ViewerOverlays.swift
// P1 下一波 §3.9：挑片可视化的查看器叠加层（直方图 / 合焦 / 裁剪 / AF / 参考对比）。
//
// 分工（layering 门禁）：
// - 像素与几何算法在 GatherAnalysis/Preview（UI 不得 import 分析层）；
// - 本文件只做三件事：把已加载预览栅格化成 PreviewPixels、经
//   PreviewAnalysisRegistry（宿主启动时注册 PreviewAnalysisAdapter）取结果、
//   用 SwiftUI Canvas 画出来。
//
// "不新增解码"的边界：像素来自 PhotoThumbnailCache 里**已经解码并显示**的
// NSImage（查看器自己的那张），只是把它画进一块 RGBA8 位图以取像素值；
// 不再从磁盘读第二遍，也不会为直方图申请更高档位的解码。
//
// 快捷键：按任务要求**不在本文件硬编码**（避免与 Interaction/ 键位表冲突）。
// 状态机只暴露 toggle 方法，由上层（CullingWorkbenchViewer / 后续键位表）调用。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 预览分析注册表（宿主 install，UI 只读）

/// PreviewAnalysisPort 的进程级注册表（与 ImageDecodingRegistry 同构）。
///
/// 未注册时 current() 返回 nil：叠加层显示"分析不可用"而不是崩或静默空图，
/// 预览/单元测试也不需要宿主。
public enum PreviewAnalysisRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var port: (any PreviewAnalysisPort)?

    public static func install(_ port: any PreviewAnalysisPort) {
        lock.lock()
        self.port = port
        lock.unlock()
    }

    public static func current() -> (any PreviewAnalysisPort)? {
        lock.lock()
        let port = self.port
        lock.unlock()
        return port
    }
}

// MARK: - 叠加层状态（查看器持有；快捷键不在此绑定）

/// 参考对比模式（C 键循环；与现有 compare2/compare4 正交）。
public enum ReferenceCompareMode: String, CaseIterable, Sendable {
    /// 并排（复用现有 compare2 的平铺语义）。
    case sideBySide
    /// 分割线（可拖动，左右各半）。
    case split
    /// 50% 叠加。
    case overlay

    public var next: ReferenceCompareMode {
        switch self {
        case .sideBySide: return .split
        case .split: return .overlay
        case .overlay: return .sideBySide
        }
    }

    /// 本地化键（视图层用 l10n 解析，枚举不持有中文文案）。
    public var labelKey: String {
        switch self {
        case .sideBySide: return "并排"
        case .split: return "分割"
        case .overlay: return "叠加"
        }
    }
}

/// 查看器叠加层状态机（纯值类型 + 纯方法：可单测，不依赖 @State 生命周期）。
public struct CullingViewerOverlayState: Equatable, Sendable {
    /// 直方图可见（H）。
    public var histogramVisible = false
    /// 合焦掩膜可见（F）。
    public var focusMaskVisible = false
    /// 裁剪框可见（默认开：读到 crs:Crop* 才画，读不到什么都不画）。
    public var cropVisible = true
    /// "显示全图"（O）：临时去掉裁剪蒙版。
    public var showFullFrame = false
    /// 直方图是否显示 RGB 三通道（点直方图 / 再按一次切换）。
    public var histogramChannels = true

    /// 参考槽：photoId + 预览路径 + 展示名（同会话内保持，切页不丢）。
    public var referencePhotoId: String?
    public var referenceFilepath: String?
    public var referenceFilename: String?
    public var referenceMode: ReferenceCompareMode = .sideBySide
    /// 分割线位置（归一化 0...1；0.5 = 正中）。
    public var splitFraction: Double = 0.5

    public init() {}

    public var hasReference: Bool { referencePhotoId != nil }

    // MARK: 开关（供键位表/工具栏调用）

    public mutating func toggleHistogram() { histogramVisible.toggle() }
    public mutating func toggleFocusMask() { focusMaskVisible.toggle() }
    public mutating func toggleCropFrame() { cropVisible.toggle() }
    public mutating func toggleFullFrame() { showFullFrame.toggle() }
    public mutating func toggleHistogramChannels() { histogramChannels.toggle() }

    /// 把当前照片设为参考；再次对同一张调用则清除（R 的双态语义）。
    public mutating func toggleReference(
        photoId: String,
        filepath: String,
        filename: String
    ) {
        if referencePhotoId == photoId {
            clearReference()
            return
        }
        referencePhotoId = photoId
        referenceFilepath = filepath
        referenceFilename = filename
    }

    public mutating func clearReference() {
        referencePhotoId = nil
        referenceFilepath = nil
        referenceFilename = nil
    }

    /// 循环对比模式（C）。
    public mutating func cycleReferenceMode() {
        referenceMode = referenceMode.next
    }

    /// 交换主/参考（反斜杠）：分割线镜像，避免视觉位置跳变。
    public mutating func swapReference() {
        splitFraction = ReferenceCompareGeometry.mirroredSplit(splitFraction)
    }

    /// 拖动分割线（视图坐标 → 归一化）。
    public mutating func updateSplit(dragX: Double, viewWidth: Double) {
        splitFraction = ReferenceCompareGeometry.splitFraction(dragX: dragX, viewWidth: viewWidth)
    }
}

// MARK: - 像素栅格化（已加载 NSImage → RGBA8，不触盘）

/// 把查看器**已经显示**的 NSImage 画进 RGBA8 缓冲。
///
/// 只做位图填充（interpolationQuality = .low），不重新解码文件；长边上限
/// maxDimension（合焦图 1280、直方图内部还会再降到 256）。
public enum PreviewPixelRasterizer {
    public static func rgbaPixels(from image: NSImage, maxDimension: Int) -> PreviewPixels? {
        guard maxDimension > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        var pixels = PreviewPixels(
            width: outWidth,
            height: outHeight,
            rgba: [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: outWidth,
                    height: outHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: outWidth * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            return true
        }
        guard drawn else { return nil }
        return pixels
    }
}

// MARK: - 直方图（160×80 Canvas，右下角）

/// 预览直方图：亮度折线 + RGB 叠加，附带死黑/溢出百分比。
///
/// 语义标注「基于预览」是必需的：这是 8bit 显示预览的分布，不能当曝光工具。
struct ViewerHistogramOverlay: View {
    let histogram: PreviewHistogram?
    let showsChannels: Bool
    let onToggleChannels: () -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private static let panelWidth: CGFloat = 160
    private static let panelHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Text(l10n("直方图"))
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextPrimary)
                Text(l10n("基于预览"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.viewerTextSecondary)
                Spacer(minLength: 0)
                Button(action: onToggleChannels) {
                    Text(showsChannels ? "RGB" : l10n("亮度"))
                        .font(GatherFont.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GatherTheme.accent)
                .help(l10n("切换仅亮度 / 三通道"))
            }
            Canvas { context, size in
                draw(histogram: histogram, in: context, size: size, showsChannels: showsChannels)
            }
            .frame(width: Self.panelWidth, height: Self.panelHeight)
            .background(GatherTheme.viewerBackground.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                    .stroke(GatherTheme.viewerSurface, lineWidth: 1)
            )
            if let histogram, !histogram.isEmpty {
                Text(clippingText(histogram))
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextSecondary)
                    .monospacedDigit()
            }
        }
        .padding(GatherMetrics.Space.s)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                .fill(GatherTheme.viewerChrome.opacity(0.9))
        )
    }

    private func clippingText(_ histogram: PreviewHistogram) -> String {
        let shadow = Int((histogram.shadowClip * 100).rounded())
        let highlight = Int((histogram.highlightClip * 100).rounded())
        return l10n.format("死黑 %lld%% · 溢出 %lld%%", shadow, highlight)
    }

    private func draw(
        histogram: PreviewHistogram?,
        in context: GraphicsContext,
        size: CGSize,
        showsChannels: Bool
    ) {
        guard let histogram, !histogram.isEmpty, size.width > 0, size.height > 0 else {
            // 无数据（分析未注册/未算出）：画中线 + 提示，不画假分布。
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height))
            line.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(
                line,
                with: .color(GatherTheme.viewerTextSecondary.opacity(0.25)),
                lineWidth: 1
            )
            return
        }
        if showsChannels {
            stroke(histogram.red, color: GatherTheme.error, in: context, size: size)
            stroke(histogram.green, color: GatherTheme.success, in: context, size: size)
            stroke(histogram.blue, color: GatherTheme.info, in: context, size: size)
        }
        stroke(histogram.luminance, color: GatherTheme.viewerTextPrimary, in: context, size: size)
    }

    private func stroke(
        _ values: [Double],
        color: Color,
        in context: GraphicsContext,
        size: CGSize
    ) {
        guard values.count >= 2 else { return }
        // 归一化到峰值：直方图看形状，不看绝对计数（与系统直方图一致）。
        let peak = max(values.max() ?? 0, 1e-9)
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height * (1 - CGFloat(min(1, value / peak)))
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1)
    }
}

// MARK: - 合焦掩膜（红色 35% 叠加，无位图文件）

/// 合焦提示：把 320px 二值掩膜画成红色半透明格。
///
/// 文案叫「合焦提示」而不是「焦点掩膜」：这是 3×3 局部方差的启发式，
/// 不是相机 AF 数据。
struct ViewerFocusMaskOverlay: View {
    let mask: FocusMask

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        Canvas { context, size in
            guard !mask.isEmpty, size.width > 0, size.height > 0 else { return }
            let cellWidth = size.width / CGFloat(mask.width)
            let cellHeight = size.height / CGFloat(mask.height)
            var path = Path()
            for y in 0..<mask.height {
                for x in 0..<mask.width where mask.values[y * mask.width + x] != 0 {
                    path.addRect(CGRect(
                        x: CGFloat(x) * cellWidth,
                        y: CGFloat(y) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    ))
                }
            }
            context.fill(path, with: .color(GatherTheme.error.opacity(0.35)))
        }
        .allowsHitTesting(false)
        .accessibilityLabel(l10n("合焦提示"))
    }
}

// MARK: - 裁剪框 / AF 框

/// 裁剪标记：虚线裁剪框 + 角度徽标（只读，不提供编辑）。
struct ViewerCropOverlay: View {
    let crop: CropFrame
    let showFullFrame: Bool

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        GeometryReader { geometry in
            let rect = displayedRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                if !showFullFrame {
                    Path { path in
                        path.addRect(rect)
                    }
                    .stroke(
                        GatherTheme.viewerTextPrimary.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    // 框外压暗：让"预览与 C1 构图差异"一眼可见。
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(rect)
                    }
                    .fill(GatherTheme.viewerBackground.opacity(0.35), style: FillStyle(eoFill: true))
                }
                HStack(spacing: GatherMetrics.Space.xs) {
                    Text(l10n("已裁剪"))
                    if crop.isRotated {
                        Text("\(Int(crop.angle.rounded()))°")
                            .monospacedDigit()
                    }
                }
                .font(GatherFont.label)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
                .padding(.horizontal, GatherMetrics.Space.xs)
                .padding(.vertical, GatherMetrics.Space.xxs)
                .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
                .offset(x: rect.minX, y: max(0, rect.minY - GatherMetrics.Space.l))
            }
        }
        .allowsHitTesting(false)
    }

    /// 归一化裁剪矩形 → 视图矩形（fit 居中：裁剪值本身就是相对全图的归一化坐标，
    /// 与查看器的 aspect-fit 缩放无关，故按视图尺寸直接映射）。
    private func displayedRect(in size: CGSize) -> CGRect {
        let geometry = crop.showingFullFrame(showFullFrame)
        return CGRect(
            x: size.width * CGFloat(geometry.left),
            y: size.height * CGFloat(geometry.top),
            width: size.width * CGFloat(geometry.width),
            height: size.height * CGFloat(geometry.height)
        )
    }
}

/// AF 框：白色 1px + 角标；点击 → 以该点为中心 100% 缩放（回调交给查看器）。
struct ViewerAFPointOverlay: View {
    let point: AFPoint
    let onTap: () -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(
                x: geometry.size.width * CGFloat(point.x),
                y: geometry.size.height * CGFloat(point.y)
            )
            let side = max(18, min(geometry.size.width, geometry.size.height) * 0.08)
            let rect = CGRect(
                x: center.x - side / 2,
                y: center.y - side / 2,
                width: side,
                height: side
            )
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(rect)
                    // 四角标记（相机 AF 框的视觉语言）。
                    let corner = side / 4
                    for cornerRect in [
                        CGRect(x: rect.minX, y: rect.minY, width: corner, height: 1),
                        CGRect(x: rect.minX, y: rect.minY, width: 1, height: corner),
                        CGRect(x: rect.maxX - corner, y: rect.maxY - 1, width: corner, height: 1),
                        CGRect(x: rect.maxX - 1, y: rect.maxY - corner, width: 1, height: corner),
                    ] {
                        path.addRect(cornerRect)
                    }
                }
                .stroke(GatherTheme.viewerTextPrimary, lineWidth: 1)
                Text(point.source == .face ? l10n("人脸") : "AF")
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextPrimary)
                    .padding(.horizontal, GatherMetrics.Space.xs)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
                    .offset(x: rect.minX, y: max(0, rect.minY - GatherMetrics.Space.l))
                Color.clear
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
                    .offset(x: rect.minX, y: rect.minY)
                    .onTapGesture(perform: onTap)
                    .help(point.source == .face ? l10n("以人脸中心 100% 查看") : l10n("以对焦点 100% 查看"))
            }
        }
    }
}

// MARK: - 参考对比（分割线 + 参考图；徽标由查看器绘制）

/// 分割线拖动条 + 参考图（分割 / 叠加两种模式）。
///
/// 参考图直接复用 PhotoThumbnailView（与主图同一个缓存键空间），
/// 因此"参考照片不在当前页"时仍按需取预览，且不再多一条解码路径。
///
/// D9：这里**不画**参考徽标（"参考：X · 模式"）——由 CullingWorkbenchViewer
/// 在 topLeading 统一绘制一次（并排模式下本组件根本不渲染，只有查看器那层
/// 能保证三种模式都有徽标）。因此本类型也不再需要语言环境。
struct ViewerReferenceOverlay: View {
    let state: CullingViewerOverlayState
    let cellSize: CGSize
    let onSplitChange: (Double, Double) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.referenceMode == .overlay || state.referenceMode == .split {
                if let path = state.referenceFilepath, !path.isEmpty {
                    // 分割模式只显示参考图左半；叠加模式整张半透明。
                    referenceImage(path: path)
                        .opacity(state.referenceMode == .overlay ? 0.5 : 1)
                        .clipShape(SplitMask(
                            fraction: state.referenceMode == .split ? state.splitFraction : 1
                        ))
                        .allowsHitTesting(false)
                }
            }
            // 徽标不在这里画（见类型注释 D9）：本组件只负责参考图与分割线。
            if state.referenceMode == .split {
                splitHandle
            }
        }
    }

    private func referenceImage(path: String) -> some View {
        PhotoThumbnailView(
            path: path,
            size: PhotoDetailTier.baseDimension,
            preview: true,
            contentMode: .fit,
            placeholderSurface: GatherTheme.viewerSurface,
            placeholderTextColor: GatherTheme.viewerTextSecondary
        )
        .frame(width: cellSize.width, height: cellSize.height)
    }

    /// 分割线：1px 竖线 + 可拖动命中带（宽度放大到 12pt 便于抓取）。
    private var splitHandle: some View {
        let x = ReferenceCompareGeometry.splitX(
            fraction: state.splitFraction,
            viewWidth: Double(cellSize.width)
        )
        return ZStack {
            Rectangle()
                .fill(GatherTheme.viewerTextPrimary.opacity(0.75))
                .frame(width: 1)
            Color.clear
                .frame(width: 12)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onSplitChange(Double(value.location.x), Double(cellSize.width))
                        }
                )
        }
        .frame(height: max(0, cellSize.height))
        .offset(x: CGFloat(x) - 6)
    }
}

/// 分割遮罩（左半 = 参考图）。
private struct SplitMask: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let width = rect.width * CGFloat(ReferenceCompareGeometry.clampedSplit(fraction))
        return Path(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
    }
}
