// desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbenchViewer+ViewerChrome.swift
// M13（Wave5 / task-9）：CullingWorkbenchViewer 的扩展——工具条 / 缩放 / 第二屏镜像 / 打印面板数据。
//
// 纯搬移：成员实现逐行未改；仅去掉 private 以便跨文件（同 target）访问，逐条见报告。
import SwiftUI
import GatherProtocol

extension CullingWorkbenchViewer {
    /// 左下角缩放/叠加层/专注模式/打印工具条（原 body 内联区域，M6 纯拆分）。
    var viewerToolbar: some View {
        // 可见缩放控件承载 ⌘−/⌘0/⌘= 快捷键（取代零尺寸全透明的隐藏按钮）。
        HStack(spacing: GatherMetrics.Space.xs) {
            Button { zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help(l10n("缩小（⌘−）"))
            .accessibilityLabel(l10n("缩小"))

            Button { resetTransform() } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(l10n("适配窗口（⌘0）"))
            .accessibilityLabel(l10n("适配窗口"))

            // 真 1:1：裸 1 已是「1 星」评级（见 onKeyPress），不能占；因此绑 ⌘1，
            // ⌘⌥0 在 onKeyPress 里作为同一动作的第二入口。
            Button { zoomToActualPixels() } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .keyboardShortcut("1", modifiers: .command)
            .help(l10n("实际像素（⌘1 或 ⌘⌥0）"))
            .accessibilityLabel(l10n("实际像素"))

            Button { zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .help(l10n("放大（⌘=）"))
            .accessibilityLabel(l10n("放大"))

            Divider().frame(height: 12)

            // §3.9 叠加层开关：不绑定裸键（键位表在 Interaction/，
            // 与现有 P/X/U/0-5 冲突风险由后续键位表统一分配）。
            // Wave2（#8）：按钮 help 里写清键位（裸键只在查看器持焦点时生效）。
            Button { toggleHistogram() } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .help(l10n("直方图（H）· 基于预览"))
            // 无障碍标签保留既有「基于预览」措辞：直方图口径仍是 8bit 预览，
            // 不能把它说成 RAW 口径（参考 20-culling-browse §2.2）。
            .accessibilityLabel(l10n("直方图（基于预览）"))
            Button { toggleFocusMask() } label: {
                Image(systemName: "scope")
            }
            .help(l10n("合焦提示（F）"))
            .accessibilityLabel(l10n("合焦提示"))
            Button { toggleCropFrame() } label: {
                Image(systemName: "crop")
            }
            .help(l10n("裁剪标记（只读）"))
            .accessibilityLabel(l10n("裁剪标记"))
            Button { toggleReference() } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .help(l10n("设为参考 / 取消参考（R）"))
            .accessibilityLabel(l10n("参考对比"))
            if overlayState.hasReference {
                Menu {
                    Button(l10n("切换对比模式")) { overlayState.cycleReferenceMode() }
                    Button(l10n("交换参考")) { overlayState.swapReference() }
                    Toggle(isOn: $overlayState.showFullFrame) {
                        Text(l10n("全图显示"))
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .help(l10n("对比模式（C）"))
                .accessibilityLabel(l10n("对比模式"))
            }
            // 键位可见性（#8「并在菜单/帮助中可见」）：一个只读的快捷键菜单，
            // 与 onKeyPress 的分发同源（CullingViewerShortcutKey），不另造入口。
            Menu {
                Button(l10n("直方图（H）· 基于预览")) { toggleHistogram() }
                Button(l10n("合焦提示（F）")) { toggleFocusMask() }
                Button(l10n("设为参考 / 取消参考（R）")) { toggleReference() }
                    .accessibilityLabel(l10n("设为参考 / 取消参考"))
                Button(l10n("对比模式（C）")) { overlayState.cycleReferenceMode() }
                    .disabled(!overlayState.hasReference)
                Divider()
                Button(l10n("适配窗口（⌘0）")) { resetTransform() }
                Button(l10n("实际像素（⌘1 或 ⌘⌥0）")) { zoomToActualPixels() }
            } label: {
                Image(systemName: "keyboard")
            }
            .help(l10n("查看器快捷键"))
            .accessibilityLabel(l10n("查看器快捷键"))

            Divider().frame(height: 12)

            // 专注模式（P1 无干扰单图）：隐藏检查器 + 折叠胶片条 + 窗口全屏。
            // Wave2：裸 F 已还给合焦掩膜，专注模式改为 ⇧F（onKeyPress/菜单同入口）。
            Button { onToggleFocusMode() } label: {
                Image(systemName: isFocusMode
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
            }
            .help(l10n(isFocusMode ? "退出专注模式（⇧F）" : "专注模式（⇧F）"))
            .accessibilityLabel(l10n(isFocusMode ? "退出专注模式" : "专注模式"))

            Divider().frame(height: 12)

            // Wave3 / task-20：打印版面（单图/多页）与第二屏镜像入口。
            // 打印面板负责选项 + 渲染；第二屏只读镜像当前会话/布局/缩放。
            Button { showingPrintSheet = true } label: {
                Image(systemName: "printer")
            }
            .help(l10n("打印…"))
            .accessibilityLabel(l10n("打印"))
            Button { openWindow(id: CullingSecondDisplayWindowID.id) } label: {
                Image(systemName: "display")
            }
            .help(l10n("在第二屏显示"))
            .accessibilityLabel(l10n("在第二屏显示"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, GatherMetrics.Space.s)
        .padding(.vertical, GatherMetrics.Space.xs)
        // 浮在照片之上的功能层控件：macOS 26+ 用 **clear** 玻璃
        // （Apple：clear 专用于浮在照片/视频等媒体之上的组件），
        // 下面本来就有 viewerChrome 深色底，满足「亮媒体需暗化」的前提。
        // 低版本回退到原来的深色胶囊。
        .modifier(ViewerZoomChrome())
    }

    func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
        dragStartOffset = .zero
        actualPixelsMode = false
    }

    // MARK: - Wave3 / task-20：第二屏镜像 + 打印

    /// 把当前缩放/平移发布给第二屏（只读镜像；主窗口是唯一写入方）。
    func publishViewerTransform() {
        secondDisplay?.publishViewerTransform(zoom: effectiveZoom, offset: offset)
    }

    /// 打印面板的数据：有选择集时按页内顺序给全部选中（多页排版），
    /// 否则给当前照片（单图打印）。只做字段映射，不解码、不写盘。
    ///
    /// Wave4b / P2-11：上限 200 张保留（避免一次渲染上千张），但超出部分必须
    /// 在面板里可见——printTruncatedCount 由 PrintOptionsSheet 展示提示。
    var printItems: [PrintJobItem] {
        printSelectionAssets.prefix(CullingPrintSelection.limit).map(Self.printItem)
    }

    /// 未被打印的选中张数（0 = 没有截断）。
    var printTruncatedCount: Int {
        CullingPrintSelection.truncatedCount(total: printSelectionAssets.count)
    }

    /// 打印的候选资产（选择集优先，跨页选择全不在当前页时退回当前照片）。
    var printSelectionAssets: [CullingAsset] {
        let source: [CullingAsset]
        if !viewModel.selectedPhotoIds.isEmpty {
            let selected = assets.filter { viewModel.selectedPhotoIds.contains($0.photo.id) }
            // 跨页选择可能一张都不在当前页：此时退回当前照片（单图打印），
            // 而不是给一个空面板（"没有可打印的照片"应只在真的没选中时出现）。
            if let currentAsset, selected.isEmpty {
                source = [currentAsset]
            } else {
                source = selected
            }
        } else if let currentAsset {
            source = [currentAsset]
        } else {
            source = []
        }
        return source
    }

    var currentPrintItem: PrintJobItem? {
        currentAsset.map(Self.printItem)
    }

    static func printItem(_ asset: CullingAsset) -> PrintJobItem {
        PrintJobItem(
            filePath: asset.photo.filepath,
            caption: asset.photo.filename,
            rating: Int(asset.state.rating.rounded()),
            label: "",
            pick: asset.state.pickState,
            keywords: asset.keywords
        )
    }

    /// 当前格最近一次布局尺寸（缩放提示/1:1 换算用）。
    var currentCellSize: CGSize? {
        guard let id = currentAsset?.photo.id, let size = cellSizes[id],
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    static func fitPoints(imageSize: CGSize, cellSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, cellSize.width > 0, cellSize.height > 0 else { return 0 }
        let fitScale = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
        return Double(max(imageSize.width, imageSize.height) * fitScale)
    }

    func zoomIn() {
        actualPixelsMode = false
        let next = CullingViewerZoom.clamp(scale * 1.15, maximum: zoomMaximum)
        scale = next
        gestureScale = next
    }

    func zoomOut() {
        actualPixelsMode = false
        let next = CullingViewerZoom.clamp(scale * (1 / 1.15), maximum: zoomMaximum)
        scale = next
        gestureScale = next
    }

    /// 真 1:1：按源像素 / fitPoints（含查看器窗口屏 backingScale）反算相对 fit 的倍率。
    /// 源图尺寸未知（老库/未索引）时不做换算，保持当前缩放。
    /// Wave4b / P2-7：进入 1:1 后记住模式，窗口 resize 由 reanchorActualPixelsIfNeeded() 重锚。
    func zoomToActualPixels() {
        guard let asset = currentAsset, let size = currentCellSize,
              let actual = CullingViewerZoom.actualPixelsScale(
                  sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height)),
                  fitPoints: Self.fitPoints(imageSize: imageSize(of: asset), cellSize: size),
                  backingScale: viewerBackingScale())
        else { return }
        let next = CullingViewerZoom.clamp(actual, maximum: zoomMaximum)
        scale = next
        gestureScale = next
        actualPixelsMode = true
        // 1:1 的语义是"看这张图的正中真实像素"：平移复位，避免沿用上一张的位移。
        offset = .zero
        dragStartOffset = .zero
        scheduleDetailTileUpdateForVisibleCells()
    }

    /// 1:1 模式下的尺寸重锚：窗口/布局变化后 fitPoints 变了，按新模式重算 scale；
    /// 非 1:1 模式不做任何事（保持用户当前缩放）。
    func reanchorActualPixelsIfNeeded() {
        guard let asset = currentAsset, let size = currentCellSize else { return }
        guard let next = CullingViewerZoom.reanchoredScale(
            actualPixelsMode: actualPixelsMode,
            sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height)),
            fitPoints: Self.fitPoints(imageSize: imageSize(of: asset), cellSize: size),
            backingScale: viewerBackingScale())
        else { return }
        scale = CullingViewerZoom.clamp(next, maximum: zoomMaximum)
        gestureScale = scale
        scheduleDetailTileUpdateForVisibleCells()
    }

    /// 缩放上限（fit 相对倍率）：既有 fit×8，必要时抬到实际像素档。
    var zoomMaximum: Double {
        guard let asset = currentAsset, let size = currentCellSize else {
            return CullingViewerZoom.baseMaximumScale
        }
        return CullingViewerZoom.maximumScale(
            sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height)),
            fitPoints: Self.fitPoints(imageSize: imageSize(of: asset), cellSize: size),
            backingScale: viewerBackingScale())
    }

    /// 缩放胶囊文案：fit 档**不显示**；其余按源像素口径（1:1 = 100%）。
    var zoomHint: String? {
        guard effectiveZoom != CullingViewerZoom.fitScale else { return nil }
        guard let asset = currentAsset, let size = currentCellSize,
              let percent = CullingViewerZoom.pixelPercent(
                  scale: effectiveZoom,
                  sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height)),
                  fitPoints: Self.fitPoints(imageSize: imageSize(of: asset), cellSize: size),
                  backingScale: viewerBackingScale())
        else { return "\(Int(effectiveZoom * 100))%" }
        return "\(percent)%"
    }

    func imageSize(of asset: CullingAsset) -> CGSize {
        CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height))
    }

    /// 查看器窗口所在屏的物理像素/点（Wave4b / P2-6）。
    ///
    /// NSScreen.main 跟随"当前收键盘事件的窗口"，查看器在第二屏/非主屏时会取错屏；
    /// 窗口已解析时以窗口自己的 screen 为准，窗口还没出来才退回主屏。
    func viewerBackingScale() -> Double {
        CullingViewerZoom.resolvedBackingScale(
            windowScale: viewerWindow.map { Double($0.backingScaleFactor) },
            screenScale: NSScreen.main.map { Double($0.backingScaleFactor) })
    }

// MARK: - 查看器缩放控件的功能层材质

}

/// 缩放控件浮在照片之上，属于 Liquid Glass 的**功能层**：用 `.glass(.clear)`。
private struct ViewerZoomChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .gatherFunctionalCapsule(clear: true)
            .padding(.leading, GatherMetrics.Space.m)
            .padding(.bottom, 40)
    }
}
