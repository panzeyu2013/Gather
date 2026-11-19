// desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbenchViewer+ViewerGrid.swift
// M13（Wave5 / task-9）后续：CullingWorkbenchViewer 的扩展——对比网格渲染
//（viewerGrid / cellView / groupCells，从 +ViewerOverlay.swift 再拆出）。
//
// 纯搬移：成员实现逐行未改，语义与原文件一致。
import SwiftUI
import GatherProtocol

extension CullingWorkbenchViewer {
    /// 对比网格：列/行/格尺寸/贴片预算按同屏张数计算（原 body 内联区域，M6 纯拆分）。
    @ViewBuilder
    func viewerGrid(geometry: GeometryProxy) -> some View {
        let visible = comparisonAssets()
        // Wave2（#6/#7）：列/行由同屏张数决定（1/2/3 列并排、4 图 2×2、
        // Survey 最多 9 格 3 列）；所有格共用同一尺寸与一套 scale/offset，
        // 同步缩放/平移语义不变。
        let columns = CullingViewerGridLayout.columns(for: visible.count)
        let rows = CullingViewerGridLayout.rows(for: visible.count, columns: columns)
        let cellGroups = groupCells(visible, columns: columns)
        let cellSize = CullingViewerGridLayout.cellSize(
            container: geometry.size,
            columns: columns,
            rows: rows
        )
        // 预算/贴片策略按**实际同屏张数**（Survey 选择 9 张但页内只加载 3 张时，
        // 按 3 格而不是 9 格给预算）。
        let visibleCells = max(1, visible.count)
        let detailBudget = PhotoDetailTier.budget(forVisibleCells: visibleCells)
        VStack(spacing: GatherMetrics.Space.s) {
            ForEach(0..<cellGroups.count, id: \.self) { rowIndex in
                HStack(spacing: GatherMetrics.Space.s) {
                    ForEach(cellGroups[rowIndex]) { cell in
                        cellView(cell, visibleCells: visibleCells, detailBudget: detailBudget)
                            .frame(width: cellSize.width, height: cellSize.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 对比单元格：黑底 + 缩放/平移手势 + 底部字幕条 + 徽标 + hover 主色描边 + 双击复位。
    /// - Parameters:
    ///   - visibleCells: 同屏总格数（贴片预算/可见性策略按它算，而不是布局固定格数）。
    ///   - detailBudget: 本次同屏允许的单格解码档位上限。
    func cellView(_ cell: ViewerCell, visibleCells: Int, detailBudget: Int) -> some View {
        let asset = cell.asset
        return GeometryReader { cellGeometry in
            // A-6：单元格尺寸只经生命周期回调写状态（**不在 body 求值期间写 @State**，
            // 否则触发 SwiftUI「Modifying state during view update」与额外布局循环）。
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    cellSizes[cell.asset.photo.id] = cellGeometry.size
                    scheduleDetailTileUpdate(for: cell.asset.photo.id)
                }
                .onChange(of: cellGeometry.size) { _, newSize in
                    cellSizes[cell.asset.photo.id] = newSize
                    // A-6 残余（第二轮验证）：尺寸变化（拖窗口/切布局）后贴片
                    // 几何也要重算，否则放大态下会错位到下次平移/缩放。
                    scheduleDetailTileUpdate(for: cell.asset.photo.id)
                }
            // B-C1：人脸对齐必须按「fit 后的图像显示尺寸」算，并乘上缩放级。
            // 旧实现用单元格尺寸且漏乘 zoom → 竖构图两轴欠平移 1.6~2×，
            // 任何缩放级下脸都不在中心。
            let alignOffset: CGSize = {
                guard faceAlign, let face = asset.faceBboxes.first else { return .zero }
                return FaceAlign.offset(
                    imageSize: CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height)),
                    cellSize: cellGeometry.size,
                    face: face,
                    zoom: max(2, scale)
                )
            }()
            // 细节贴片与 onUnavailable 的整图高档位兜底共用同一个预算（由 body 按
            // 实际同屏张数分配：4 格各解 8192px 会瞬时吃掉约 1GB）。
            let referenceAsset = overlayState.referencePhotoId.flatMap { id in
                viewModel.pageAsset(forPhotoId: id)
            }
            // 叠加层坐标系：与 .fit 图像 + scaleEffect/offset 完全一致，而不是单元格矩形。
            let imageRect = Self.displayedImageRect(
                imageSize: CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height)),
                cellSize: cellGeometry.size,
                zoom: effectiveZoom,
                offset: CGSize(
                    width: offset.width + alignOffset.width,
                    height: offset.height + alignOffset.height))
            ZStack(alignment: .bottom) {
                // 整图适配（对齐旧版 .viewerImage object-fit: contain）：窄容器
                // 时整体缩放而非裁切，缩放级作用于完整画面。
                // allowsHitTesting(false)：scaleEffect 放大后命中区域会外溢到
                // 单元格之外（.clipped() 只裁剪渲染不裁剪命中），吞掉工具栏/
                // 工具列/胶片条的点击——人脸对齐开启后必须把命中限定在单元格内。
                // 底层：整图低分辨率位图（基准档），负责构图与手势，立即显示不闪。
                // 放大后的真实细节由下面的**可见区域细节层**负责（只解可见区域，
                // 不整图重解——Bridge / Capture One 的 tiled detail 语义）。
                PhotoThumbnailView(
                    path: asset.photo.filepath,
                    size: detailBaseSize,
                    preview: true,
                    contentMode: .fit,
                    placeholderSurface: GatherTheme.viewerSurface,
                    placeholderTextColor: GatherTheme.viewerTextSecondary
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(effectiveZoom)
                    .offset(x: offset.width + alignOffset.width, y: offset.height + alignOffset.height)
                    .allowsHitTesting(false)
                // 并排对比：右半格显示参考图，左半格保留当前图（分割线可拖动时用 overlay 版本）。
                if overlayState.hasReference,
                   overlayState.referenceMode == .sideBySide,
                   let referenceAsset,
                   referenceAsset.photo.id != asset.photo.id {
                    HStack(spacing: CGFloat.zero) {
                        Color.clear
                        PhotoThumbnailView(
                            path: referenceAsset.photo.filepath,
                            size: 1024,
                            preview: true,
                            contentMode: .fit,
                            placeholderSurface: GatherTheme.viewerSurface,
                            placeholderTextColor: GatherTheme.viewerTextSecondary
                        )
                        .frame(width: cellGeometry.size.width / 2)
                        .clipped()
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(GatherTheme.viewerTextPrimary.opacity(0.6))
                                .frame(width: 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
                // 可见区域细节层：按**该格自己的**单元格尺寸与照片宽高算出「真正
                // 可见的图像矩形」，只解码这一块（缩放/平移/尺寸变化去抖后更新）。
                // Wave2（#3）：2 图并排时非当前格也贴片——否则并排判合焦在高倍下
                // 只有当前格清晰，"哪张更实"根本没法比；3/4/Survey 只给当前+hover
                // （见 CullingDetailTilePolicy，避免同时解 N 块细节打满解码闸门）。
                if let tile = detailTiles[cell.asset.photo.id],
                   CullingDetailTilePolicy.showsTile(
                       compareCount: visibleCells,
                       isCurrent: cell.asset.photo.id == currentAsset?.photo.id,
                       isHovered: hoveredCellId == cell.id),
                   tile.viewRect.width > 0, tile.viewRect.height > 0 {
                    PhotoDetailTileView(
                        path: asset.photo.filepath,
                        normalizedRect: tile.normalizedRect,
                        targetPixel: PhotoViewerGeometry.tilePixelSize(
                            viewRect: tile.viewRect,
                            budgetDimension: detailBudget
                        ),
                        // 整图高档位兜底只对当前格做：detailBaseSize 是全局基准，
                        // 非当前格替换它会把所有格的底图一起抬高（内存失控）。
                        onUnavailable: {
                            guard cell.asset.photo.id == currentAsset?.photo.id else { return }
                            detailBaseSize = PhotoDetailTier.target(
                                fitPoints: Self.fitPoints(
                                    imageSize: CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height)),
                                    cellSize: cellGeometry.size
                                ),
                                zoom: effectiveZoom,
                                backingScale: viewerBackingScale(),
                                sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height)),
                                budgetDimension: detailBudget
                            )
                        }
                    )
                    .frame(width: max(0, tile.viewRect.width), height: max(0, tile.viewRect.height))
                    .position(x: tile.viewRect.midX, y: tile.viewRect.midY)
                    .allowsHitTesting(false)
                }
                // §3.9 叠加层：只画在当前格（非当前格套用当前照片的掩膜会错位）。
                if cell.asset.photo.id == currentAsset?.photo.id {
                    if overlayState.focusMaskVisible, let focusMask, !focusMask.isEmpty {
                        ViewerFocusMaskOverlay(mask: focusMask)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    }
                    if overlayState.cropVisible, let crop = currentCrop {
                        ViewerCropOverlay(
                            crop: crop,
                            showFullFrame: overlayState.showFullFrame
                        )
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    }
                    if let afPoint = currentAFPoint() {
                        ViewerAFPointOverlay(point: afPoint) {
                            focus(on: afPoint, cellSize: cellGeometry.size)
                        }
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    }
                    if overlayState.hasReference,
                       overlayState.referencePhotoId != cell.asset.photo.id,
                       overlayState.referenceMode != .sideBySide {
                        ViewerReferenceOverlay(
                            state: overlayState,
                            cellSize: cellGeometry.size,
                            onSplitChange: { x, width in
                                overlayState.updateSplit(dragX: x, viewWidth: width)
                            }
                        )
                        .allowsHitTesting(true)
                    }
                }
                // 底部字幕条（文件名 / 来源 / 星级）。
                HStack(spacing: GatherMetrics.Space.s) {
                    Text(asset.photo.filename).lineLimit(1)
                    Spacer()
                    Text(sourceLabel(asset))
                        .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                    Text(asset.state.rating > 0 ? "\(Int(asset.state.rating))★" : l10n("未评级"))
                }
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.92))
                .padding(.horizontal, 9)
                .padding(.vertical, GatherMetrics.Space.controlGap)
                .frame(maxWidth: .infinity)
                .background(GatherTheme.viewerSurface.opacity(0.9))
                // 右上保留/淘汰徽标。
                if asset.state.pickState != .unreviewed {
                    ViewerBadge(
                        text: asset.state.pickState == .picked ? l10n("保留") : l10n("淘汰"),
                        systemImage: asset.state.pickState == .picked ? "checkmark" : "xmark",
                        tone: asset.state.pickState == .picked ? GatherTheme.success : GatherTheme.error
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                }
                // 左上无脸徽标（仅人脸对齐开启且该照片无检测结果时）。
                if faceAlign && asset.faceBboxes.isEmpty {
                    ViewerBadge(
                        text: l10n("未检测到人脸"),
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                }
                // 右下质量徽标（对齐旧版 qualityBadge + warnings ⚠）。
                if let quality = asset.quality {
                    ViewerBadge(
                        text: qualityBadgeText(quality),
                        systemImage: "sparkles",
                        tone: GatherTheme.info,
                        showsWarning: !quality.warnings.isEmpty
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(GatherMetrics.Space.s)
                    .help(qualityHelpText(quality))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .background(GatherTheme.viewerBackground)
            .overlay(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                    .stroke(hoveredCellId == cell.id ? GatherTheme.accent.opacity(0.65) : GatherTheme.viewerSurface, lineWidth: 1)
            )
            .onHover { hovering in
                hoveredCellId = hovering ? cell.id : nil
            }
            // 手势挂在单元格容器上（图片已 allowsHitTesting(false)，命中限定在
            // 单元格边界内；缩放/平移手势与双击复位语义不变）。
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        actualPixelsMode = false
                        scale = CullingViewerZoom.clamp(gestureScale * value, maximum: zoomMaximum)
                    }
                    .onEnded { _ in
                        gestureScale = scale
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // 对齐旧版 onPointerDown：任意缩放级均可拖拽平移。
                        offset = PanOffset.apply(start: dragStartOffset, translation: value.translation)
                    }
                    .onEnded { _ in
                        // 提交本次位移作为下次拖拽的基线（累积平移）。
                        dragStartOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                resetTransform()
            }
        }
    }

    /// 按给定的列数把同屏资产切成行（列数来自 CullingViewerGridLayout：
    /// 2 图 = 2 列、3 图 = 3 列、4 图 = 2 列、Survey 最多 3 列）。
    func groupCells(_ visible: [CullingAsset], columns: Int) -> [[ViewerCell]] {
        let safeColumns = max(1, columns)
        var groups: [[ViewerCell]] = []
        var row: [ViewerCell] = []
        for (order, asset) in visible.enumerated() {
            row.append(ViewerCell(id: asset.photo.id, order: order, asset: asset))
            if row.count == safeColumns {
                groups.append(row)
                row = []
            }
        }
        if !row.isEmpty { groups.append(row) }
        return groups
    }
}
