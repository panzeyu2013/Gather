// desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbenchViewer.swift
// Cut 4 / 4c-2a：工作台查看器（1/2/4 张对比、缩放/平移、人脸对齐、滚轮、徽标）。
// 原 CullingView.swift 3108-3662、3664-3679、3708-3726 行，逐字搬移。
// 13 个 @State 必须随同一视图身份保留：调用点仍在 CullingWorkbench 原位置，不套 .id。
//
// 注：旧版为让窗口级 NSEvent 快捷键生效，曾对整个挑片页控件施加 focusable(false)；
// 快捷键已改为控件自身的 .keyboardShortcut + 查看器的 .onKeyPress，
// 焦点屏蔽全部移除，Tab 遍历恢复系统默认行为。
import SwiftUI
import GatherProtocol

/// 工作台内嵌查看器：对齐旧版查看器核心能力——1/2/4 张对比（4 张为 2x2 网格）、
/// 滚轮缩放（1.15/0.87，范围 1..8）+ 任意缩放级拖拽平移 + 双击复位 + zoomHint、
/// 每格字幕（文件名 + 来源 + 星级/未评级）+ 保留/淘汰徽标 + 无脸徽标 + 质量徽标。
/// 人脸对齐：把 bbox 中心搬到单元格中心所需的位移。
///
/// 坐标模型（必须与 cellView 的修饰符顺序一致）：
/// - 图像以 **aspect-fit 居中** 显示：显示尺寸 = fit(图像宽高比, 单元格)，两侧/上下留黑；
/// - 修饰符是 .scaleEffect(zoom).offset(d)，即先缩放后平移，d 处于**未缩放的
///   单元格空间**（不是图像空间）；
/// - 因此缩放后点 p 的渲染位置 = center + zoom·(p − center) + d。
/// 令 bbox 中心映射到 center，解得 d = zoom · (0.5 − face) ⊙ displayedFit。
///
/// 旧实现用 (0.5 − face) ⊙ cellSize 且不乘 zoom：竖构图欠平移约 1.6~2×，
/// 任何缩放级下脸都不在中心（审计 B-C1）。
struct CullingWorkbenchViewer: View {
    let viewModel: CullingViewModel
    let compareCount: Int
    let faceAlign: Bool

    /// Cut 4 / 4b-1：质量失败原因在渲染期按当前语言解析。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var scale = 1.0
    /// 底层整图位图（基准档）：细节由可见区域层提供，底层不随缩放抬高。
    @State private var detailBaseSize = PhotoDetailTier.baseDimension
    /// 最近一次单元格布局尺寸（A-6：细节层几何必须按单元格而非整窗计算）。
    @State private var lastCellSize: CGSize = .zero
    /// 可见区域细节层（去抖 150ms 后更新；缩放与平移都会改动它）。
    @State private var detailTileState: PhotoViewerGeometry.DetailTile?
    @State private var detailTileTask: Task<Void, Never>?
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    /// 本次拖拽开始时的位移基线（B-C2）：DragGesture.translation 是相对手势起点
    /// 的累计量，直接赋给 offset 会让每次新手势从 0 起算——松手再拖就弹回原点。
    @State private var dragStartOffset = CGSize.zero
    @State private var hoveredCellId: String?
    @State private var wheelMonitor: Any?
    @State private var viewerWindow: NSWindow?
    /// 查看器区域的 AppKit 代理视图（.background(WindowBridge)）。
    ///
    /// 约束循环修复（F01）：滚轮命中原先比较 GeometryReader 写回 @State 的
    /// .global frame——每帧重排都写观察状态，持续放大约束更新次数。
    /// 改为直接问代理视图「这个点在你 bounds 里吗」：位置由 AppKit 自己维护，
    /// 不产生任何布局反馈。
    @State private var viewerProxy: NSView?
    /// 初始焦点（L1 交互整改）：P/X/U、0–9、←/→ 都挂在本视图的 `.onKeyPress` 上，
    /// 而 `.onKeyPress` 只对持有焦点的视图生效。旧实现没有任何聚焦请求——用户
    /// 进页面后必须先点一下照片，裸键才"活过来"。这里在查看器出现时主动取焦点
    /// （网格布局挂的是 CullingGridView，两者互斥，不会互抢）。
    @FocusState private var viewerFocused: Bool

    // MARK: P1 下一波 §3.9：挑片可视化叠加层
    //
    // 三个 @State 分工：overlayState 是开关/参考槽的**纯值状态机**（快捷键不
    // 在此硬编码，见 ViewerOverlays 的 toggle 方法），histogram/focusMask 是
    // 宿主分析端口的返回结果。像素来源只有一处：查看器自己已经显示的预览
    // 位图（PhotoThumbnailCache），不为直方图/合焦图再解一次文件。
    @State private var overlayState = CullingViewerOverlayState()
    @State private var histogram: PreviewHistogram?
    @State private var focusMask: FocusMask?
    /// crs:Crop* 只读裁剪框（nil = 无 sidecar/无裁剪，不画标记）。
    @State private var cropFrame: CropFrame?

    /// 当前已加载列表（viewModel.page 变化经 @Observable 自动回流）。
    private var assets: [CullingAsset] {
        viewModel.page?.assets ?? []
    }

    /// 当前项下标：按 photo.id 查找；找不到时回退 0（非空列表）。
    private var currentIndex: Int {
        guard let id = viewModel.currentPhotoId,
              let found = assets.firstIndex(where: { $0.photo.id == id }) else { return 0 }
        return found
    }

    /// 越界保护的下标访问；列表为空时返回 nil。
    private var currentAsset: CullingAsset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    /// 面部对齐时的有效缩放（旧版 faceAlign 下 scale 下限 2）。
    private var effectiveScale: Double {
        faceAlign ? max(2, scale) : scale
    }

    var body: some View {
        GeometryReader { geometry in
            let visible = comparisonAssets()
            let cellGroups = groupCells(visible)
            let columns = visible.count > 1 ? 2 : 1
            let cellWidth = columns > 1 ? (geometry.size.width - 8) / 2 : geometry.size.width
            let cellHeight = cellGroups.count > 1 ? (geometry.size.height - 8) / 2 : geometry.size.height
            VStack(spacing: GatherMetrics.Space.s) {
                ForEach(0..<cellGroups.count, id: \.self) { rowIndex in
                    HStack(spacing: GatherMetrics.Space.s) {
                        ForEach(cellGroups[rowIndex]) { cell in
                            cellView(cell)
                                .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GatherTheme.viewerChrome)
        .clipped()
        .overlay(alignment: .top) {
            // 缩放提示（对齐旧版 zoomHint：居中胶囊，百分比 + 操作提示）。
            Text("\(Int(effectiveScale * 100))%")
                .font(GatherFont.label)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.9))
                .padding(.horizontal, GatherMetrics.Space.s)
                .padding(.vertical, 3)
                .background(Capsule().fill(GatherTheme.viewerSurface.opacity(0.85)))
                .padding(.top, GatherMetrics.Space.s)
                .help(l10n("滚轮缩放 · 拖动平移 · 双击复位 · ⌘−/⌘= 缩放"))
        }
        .overlay(alignment: .bottomLeading) {
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
                .help(l10n("实际大小（⌘0）"))
                .accessibilityLabel(l10n("实际大小"))

                Button { zoomIn() } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
                .help(l10n("放大（⌘=）"))
                .accessibilityLabel(l10n("放大"))

                Divider().frame(height: 12)

                // §3.9 叠加层开关：不绑定裸键（键位表在 Interaction/，
                // 与现有 P/X/U/0-5 冲突风险由后续键位表统一分配）。
                Button { toggleHistogram() } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .help(l10n("直方图（基于预览）"))
                .accessibilityLabel(l10n("直方图"))
                Button { toggleFocusMask() } label: {
                    Image(systemName: "scope")
                }
                .help(l10n("合焦提示"))
                .accessibilityLabel(l10n("合焦提示"))
                Button { toggleCropFrame() } label: {
                    Image(systemName: "crop")
                }
                .help(l10n("裁剪标记（只读）"))
                .accessibilityLabel(l10n("裁剪标记"))
                Button { toggleReference() } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .help(l10n("设为参考 / 取消参考"))
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
                    .help(l10n("对比模式"))
                    .accessibilityLabel(l10n("对比模式"))
                }
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
        // 空格 = 保留当前照片（裸键不该占用系统快捷键，交给聚焦查看器的 onKeyPress）。
        .focusable()
        .focused($viewerFocused)
        .focusEffectDisabled()
        .onAppear { viewerFocused = true }
        // 裸键（空格 / P / X / U / 0–5）统一挂在这里。
        //
        // 这些键原先注册在检查器里的按钮上，检查器一旦折叠就全部失效——
        // 而 P/X/U 是挑片的主力操作，不能依赖某个面板是否展开。
        // 查看器是本页唯一**始终存在**的控件，且已经为空格使用 onKeyPress。
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .leftArrow:
                guard !press.modifiers.contains(.command),
                      !press.modifiers.contains(.option) else { return .ignored }
                viewModel.retreatCurrent()
                return .handled
            case .rightArrow:
                guard !press.modifiers.contains(.command),
                      !press.modifiers.contains(.option) else { return .ignored }
                viewModel.advanceCurrent()
                return .handled
            default:
                break
            }
            // 裸键决策：带 ⌘/⌥ 的组合交给系统（⌘X 不能变成“淘汰”）。
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.option) else { return .ignored }
            switch press.characters.lowercased() {
            case " ":
                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
                return .handled
            case "p":
                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
                return .handled
            case "x":
                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected)) }
                return .handled
            case "u":
                // P2-3：U 统一不前进（与检查器/网格一致），避免跳走当前照片。
                Task {
                    await viewModel.commit(
                        patch: CullingUpdatePatch(pickState: .unreviewed),
                        shouldAdvance: false)
                }
                return .handled
            case "0", "1", "2", "3", "4", "5":
                guard let value = Int(press.characters) else { return .ignored }
                Task { await viewModel.commit(patch: CullingUpdatePatch(rating: Double(value))) }
                return .handled
            case "6", "7", "8", "9":
                // 对齐 Lightroom：6–9 = 红 / 黄 / 绿 / 蓝色标（橙/粉/紫只留在检查器菜单）。
                // 色标是"就地标注"，不触发自动前进（与星级刻意不同）。
                let label: CaptureOneColorLabel
                switch press.characters {
                case "6": label = .red
                case "7": label = .yellow
                case "8": label = .green
                default: label = .blue
                }
                Task {
                    await viewModel.commit(
                        patch: CullingUpdatePatch(colorLabel: label),
                        shouldAdvance: false)
                }
                return .handled
            default:
                return .ignored
            }
        }
        .background(WindowBridge { window, view in
            // 只在身份真正变化时写状态：updateNSView 每次布局都会回调，
            // 无条件赋值等于每次布局都排一轮视图更新（又是新的反馈环）。
            if viewerWindow !== window { viewerWindow = window }
            if viewerProxy !== view { viewerProxy = view }
        })
        .onAppear {
            startWheelMonitor()
        }
        .onDisappear {
            stopWheelMonitor()
        }
        // 复用旧版 resetTransform 语义：对比模式切换 / 人脸对齐开关 / 翻页
        // 均显式复位缩放与位移（替代旧的 .id() 整树重建，避免焦点与监听扰动）。
        .onChange(of: compareCount) { _, _ in
            resetTransform()
        }
        .onChange(of: faceAlign) { _, _ in
            resetTransform()
        }
        .onChange(of: viewModel.currentPhotoId) { _, _ in
            resetTransform()
        }
        // 可见区域细节层：缩放或平移停止 150ms 后重算「可见矩形」，只重解那一块。
        .onChange(of: scale) { _, _ in scheduleDetailTileUpdate() }
        .onChange(of: offset) { _, _ in scheduleDetailTileUpdate() }
        // P1 下一波 §3.9：直方图（右下角，160×80）。
        .overlay(alignment: .bottomTrailing) {
            if overlayState.histogramVisible {
                ViewerHistogramOverlay(
                    histogram: histogram,
                    showsChannels: overlayState.histogramChannels,
                    onToggleChannels: { overlayState.toggleHistogramChannels() }
                )
                .padding(GatherMetrics.Space.m)
            }
        }
        // 参考对比指示（左上角）：参考照片不在当前页也仍可加载（按需取预览）。
        // D9：**唯一**的参考徽标绘制点（ViewerReferenceOverlay 里那份重复的已删）。
        // 并排模式下 overlay 组件不渲染，只有这里能保证三种对比模式都有徽标。
        .overlay(alignment: .topLeading) {
            // 展示名缺失时整块不画：宁可没有胶囊，也不显示"参考："空标题。
            if overlayState.hasReference, let referenceName = overlayState.referenceFilename,
               !referenceName.isEmpty {
                HStack(spacing: GatherMetrics.Space.xs) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text(l10n.format("参考：%@", referenceName))
                    Text(l10n(overlayState.referenceMode.labelKey))
                        .foregroundStyle(GatherTheme.viewerTextSecondary)
                }
                .font(GatherFont.label)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
                .padding(.horizontal, GatherMetrics.Space.xs)
                .padding(.vertical, GatherMetrics.Space.xxs)
                .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
                .padding(GatherMetrics.Space.s)
            }
        }
        // 叠加层随照片/开关变化重算；.task(id:) 自动取消上一次（切页即取消）。
        .task(id: analysisKey) {
            await refreshPreviewAnalysis()
        }
        .task(id: viewModel.currentPhotoId) {
            cropFrame = nil
            guard let photoId = viewModel.currentPhotoId else { return }
            do {
                let frame = try await viewModel.cullingAPI.adjustmentHint(photoId: photoId)
                guard !Task.isCancelled, viewModel.currentPhotoId == photoId else { return }
                cropFrame = frame
            } catch {
                guard !Task.isCancelled, viewModel.currentPhotoId == photoId else { return }
                cropFrame = nil
            }
        }
    }

    /// 对比单元格：黑底 + 缩放/平移手势 + 底部字幕条 + 徽标 + hover 主色描边 + 双击复位。
    private func cellView(_ cell: ViewerCell) -> some View {
        let asset = cell.asset
        return GeometryReader { cellGeometry in
            // A-6：单元格尺寸只经生命周期回调写状态（**不在 body 求值期间写 @State**，
            // 否则触发 SwiftUI「Modifying state during view update」与额外布局循环）。
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    if cell.asset.photo.id == currentAsset?.photo.id { lastCellSize = cellGeometry.size }
                }
                .onChange(of: cellGeometry.size) { _, newSize in
                    if cell.asset.photo.id == currentAsset?.photo.id {
                        lastCellSize = newSize
                        // A-6 残余（第二轮验证）：尺寸变化（拖窗口/切对比模式）后
                        // 贴片几何也要重算，否则放大态下会错位到下次平移/缩放。
                        scheduleDetailTileUpdate()
                    }
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
            // 对比模式按格数收窄解码预算：4 格各解 8192px 会瞬时吃掉约 1GB。
            // 细节贴片与 onUnavailable 的整图高档位兜底必须共用同一个预算。
            let detailBudget = PhotoDetailTier.budget(forVisibleCells: max(1, compareCount))
            let referenceAsset = overlayState.referencePhotoId.flatMap { id in
                assets.first(where: { $0.photo.id == id })
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
                // 可见区域细节层：按同一套几何算出「真正可见的图像矩形」，
                // 只解码这一块（detailTileState 由缩放/平移变化去抖驱动）。
                // A-6 残余（第二轮验证）：detailTileState 是整页唯一状态，其几何来自
                // currentAsset；非当前格把「当前照片的可见区域」贴到别人的底图上会错位
                //（宽高比不同时明显）。只让当前格渲染贴片。
                if let tile = detailTileState, cell.asset.photo.id == currentAsset?.photo.id {
                    PhotoDetailTileView(
                        path: asset.photo.filepath,
                        normalizedRect: tile.normalizedRect,
                        targetPixel: PhotoViewerGeometry.tilePixelSize(
                            viewRect: tile.viewRect,
                            budgetDimension: detailBudget
                        ),
                        onUnavailable: {
                            // 区域解码不可用 → 退回整图高档位（渐进档位逻辑保留为兜底）。
                            detailBaseSize = PhotoDetailTier.target(
                                fitPoints: Self.fitPoints(
                                    imageSize: CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height)),
                                    cellSize: cellGeometry.size
                                ),
                                zoom: effectiveZoom,
                                backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2),
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
                        scale = min(8, max(1, gestureScale * value))
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

    /// 对比网格按行分组（2 列；4 张 = 2x2，3 张 = 2+1）。
    private func groupCells(_ visible: [CullingAsset]) -> [[ViewerCell]] {
        var groups: [[ViewerCell]] = []
        var row: [ViewerCell] = []
        for (order, asset) in visible.enumerated() {
            row.append(ViewerCell(id: asset.photo.id, order: order, asset: asset))
            if row.count == 2 {
                groups.append(row)
                row = []
            }
        }
        if !row.isEmpty { groups.append(row) }
        return groups
    }

    /// P2-3：显式选中的 2/4 张优先；否则当前照片 ± 相邻，避免第 100 张对比
    /// 列表第 1 张。
    private func comparisonAssets() -> [CullingAsset] {
        CullingComparison.assets(
            current: currentAsset,
            assets: assets,
            selectedIds: viewModel.selectedPhotoIds,
            compareCount: compareCount)
    }

    /// 来源标签（对齐 TS sourceLabel：template/face-keyword/similarity/AI/导入/人工）。
    private func sourceLabel(_ asset: CullingAsset) -> String {
        switch asset.metadataSource {
        case .template: return l10n("模板元数据")
        case .faceKeyword: return l10n("人脸关键词")
        case .similarity: return l10n("相似组关键词")
        case .manual, .culling: break
        case .none: break
        }
        if asset.quality?.status == .succeeded { return l10n("AI 技术分析") }
        // source=.imported 同时是「没有决策行」的哨兵值：只有真正落过决策（revision>0）
        // 的 imported 才是客户校样回传，否则仍是「人工调整」。
        if asset.state.source == .imported {
            return asset.state.revision > 0 ? l10n("客户选择") : l10n("导入元数据")
        }
        return l10n("人工调整")
    }

    /// 徽标正文（告警标记由 ViewerBadge.showsWarning 单独渲染，避免拼接）。
    private func qualityBadgeText(_ quality: CullingQuality) -> String {
        if quality.status == .failed { return l10n("分析失败") }
        return l10n.format("质量 %lld", Int(quality.score * 100))
    }

    private func qualityHelpText(_ quality: CullingQuality) -> String {
        if quality.status == .failed {
            // 上屏走错误码漏斗（原始诊断已由 logQualityFailures 写日志），
            // 不把分析器的结构化描述直接铺在 tooltip 里。
            guard let raw = quality.errorMessage, !raw.isEmpty else {
                return l10n("质量分析失败")
            }
            return CullingViewModel.funnelErrorText(raw, with: l10n)
        }
        let sharpness = Int((quality.subjectSharpness ?? quality.sharpness) * 100)
        let exposure = Int(quality.exposure * 100)
        return l10n.format("AI 技术分析：清晰度 %lld%%，曝光 %lld%%", sharpness, exposure)
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
        dragStartOffset = .zero
    }

    /// 缩放/平移停止后重算可见区域细节层（150ms 去抖：拖动过程不排重解码队列）。
    private func scheduleDetailTileUpdate() {
        // A-6（性能审计）：几何必须用**当前单元格**的尺寸与**当前照片**的宽高。
        // 旧实现取 viewerProxy 整窗尺寸 + page.assets.first：2×2 对比时可见区域
        // 按整窗算（面积最多 4 倍），并把第一张照片的宽高套到其它格（贴片错位）。
        let size = lastCellSize
        guard size.width > 0, size.height > 0, let asset = currentAsset else { return }
        let imageSize = CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height))
        let zoom = effectiveZoom
        let pan = CGSize(
            width: offset.width + (faceAlign ? currentAlignOffset(imageSize: imageSize, cellSize: size).width : 0),
            height: offset.height + (faceAlign ? currentAlignOffset(imageSize: imageSize, cellSize: size).height : 0)
        )
        detailTileTask?.cancel()
        detailTileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let tile = PhotoViewerGeometry.detailTile(
                imageSize: imageSize,
                viewSize: size,
                zoom: Double(zoom),
                panOffset: pan,
                backingPixelBudget: detailBaseSize
            )
            // 缩回 1× 或细节层不再需要时清掉（避免留下过期贴片）。
            detailTileState = tile
        }
    }

    /// 当前渲染用的缩放级（人脸对齐时会把倍率抬到至少 2×）。
    private var effectiveZoom: Double {
        faceAlign ? max(2, scale) : scale
    }

    /// 当前人脸对齐位移（与 cellView 内计算的是同一个模型）。
    private func currentAlignOffset(imageSize: CGSize, cellSize: CGSize) -> CGSize {
        guard let asset = currentAsset, let face = asset.faceBboxes.first else { return .zero }
        return FaceAlign.offset(
            imageSize: imageSize,
            cellSize: cellSize,
            face: face,
            zoom: max(2, scale)
        )
    }

    /// 适配显示尺寸的最长边（pt）——与 contentMode .fit 的几何一致。
    /// 用于「区域解码不可用」时的整图高档位兜底（见 cellView 的 onUnavailable）。
    /// .fit 图像在缩放/平移后的显示矩形（归一化叠加层映射的唯一几何源）。
    static func displayedImageRect(
        imageSize: CGSize, cellSize: CGSize, zoom: CGFloat, offset: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              cellSize.width > 0, cellSize.height > 0 else { return .zero }
        let fitScale = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
        let width = imageSize.width * fitScale * zoom
        let height = imageSize.height * fitScale * zoom
        return CGRect(
            x: cellSize.width / 2 - width / 2 + offset.width,
            y: cellSize.height / 2 - height / 2 + offset.height,
            width: width, height: height)
    }

    static func fitPoints(imageSize: CGSize, cellSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, cellSize.width > 0, cellSize.height > 0 else { return 0 }
        let fitScale = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
        return Double(max(imageSize.width, imageSize.height) * fitScale)
    }

    // （原「整图渐进档位」的调度已由可见区域细节层取代；整图高档位仅在区域解码
    //   不可用时作为兜底，见 cellView 的 onUnavailable 回调。）

    private func zoomIn() {
        let next = min(8, max(1, scale * 1.15))
        scale = next
        gestureScale = next
    }

    private func zoomOut() {
        let next = min(8, max(1, scale * (1 / 1.15)))
        scale = next
        gestureScale = next
    }

    // MARK: 滚轮缩放（对齐旧版 onWheel：向上 1.15、向下 0.87，范围 1..8）
    private func startWheelMonitor() {
        stopWheelMonitor()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            self.handleWheel(event)
            return event
        }
    }

    private func stopWheelMonitor() {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    private func handleWheel(_ event: NSEvent) {
        // 仅响应查看器窗口内、指针位于查看器区域上的滚动事件。
        // 命中区域直接取代理视图的 bounds（AppKit 维护），不再读写
        // GeometryReader 的坐标（见 viewerProxy 注）。
        guard let window = viewerWindow, event.window === window,
              let proxy = viewerProxy, proxy.window === window else { return }
        let point = proxy.convert(event.locationInWindow, from: nil)
        guard proxy.bounds.contains(point) else { return }
        let next = min(8, max(1, scale * (event.scrollingDeltaY < 0 ? 1.15 : 0.87)))
        guard next != scale else { return }
        scale = next
        gestureScale = next
    }
    // MARK: - §3.9 叠加层：状态与调度

    /// 预览分析的触发键：照片或开关一变就重算（.task(id:) 自动取消上一次）。
    private var analysisKey: String {
        "\(viewModel.currentPhotoId ?? "-")|\(overlayState.histogramVisible)|\(overlayState.focusMaskVisible)"
    }

    /// 重算直方图/合焦掩膜/AF 点。
    ///
    /// 像素来源：查看器自己已经显示的那张预览（PhotoThumbnailCache 里的 NSImage）。
    /// 缓存未命中时最多等 6×150ms（图片解码是异步的），仍没有就保持空态——
    /// 不为叠加层单独解码一张图（§3.9 开头"不新增解码"）。
    private func refreshPreviewAnalysis() async {
        guard overlayState.histogramVisible || overlayState.focusMaskVisible else {
            histogram = nil
            focusMask = nil
            return
        }
        guard let asset = currentAsset else {
            histogram = nil
            focusMask = nil
            return
        }
        guard let port = PreviewAnalysisRegistry.current() else {
            // 宿主未注册分析端口：保持空态（叠加层自己会画"无数据"提示）。
            histogram = nil
            focusMask = nil
            return
        }
        // 先清空上一张的叠加数据，避免取消/取不到预览时继续显示旧照片的直方图与合焦图。
        histogram = nil
        focusMask = nil
        guard let image = await waitForPreviewImage(path: asset.photo.filepath) else { return }
        guard !Task.isCancelled, viewModel.currentPhotoId == asset.photo.id else { return }
        // 栅格化在主线程完成（NSImage 非 Sendable）；只有纯像素计算下放到后台。
        let rasterized = PreviewPixelRasterizer.rgbaPixels(
            from: image,
            maxDimension: Self.analysisSampleDimension
        )
        guard let pixels = rasterized, pixels.isWellFormed else { return }
        let wantsHistogram = overlayState.histogramVisible
        let wantsFocus = overlayState.focusMaskVisible
        let computed = await Task.detached(priority: .utility) {
            () -> (PreviewHistogram?, FocusMask?) in
            let histogramValue = wantsHistogram
                ? port.histogram(pixels, bins: PreviewHistogram.defaultBins)
                : nil
            let mask = wantsFocus
                ? port.focusMask(pixels, parameters: FocusMaskParameters())
                : nil
            return (histogramValue, mask)
        }.value
        guard !Task.isCancelled else { return }
        histogram = computed.0
        focusMask = computed.1
    }

    /// 分析用像素的长边上限（§3.9.2：1280）。与 PhotoDetailTier 无关，只用于降采样。
    private static let analysisSampleDimension = 1280

    /// 等查看器自己的预览进入内存缓存（不触发第二次解码）。
    private func waitForPreviewImage(path: String) async -> NSImage? {
        guard !path.isEmpty else { return nil }
        let candidateSizes = [PhotoDetailTier.baseDimension, 2048, 1280, 1024, 512]
        for attempt in 0..<6 {
            for size in candidateSizes {
                let key = PhotoThumbnailCache.key(path: path, size: size, preview: true)
                if let image = PhotoThumbnailCache.image(for: key) { return image }
            }
            if attempt == 5 { break }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return nil
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// 裁剪标记的数据源：CullingAPI.adjustmentHint 读 sidecar 的 crs:Crop*。
    /// 无 sidecar/无裁剪 → nil（不画），绘制路径本身不变。
    private var currentCrop: CropFrame? { cropFrame }

    /// AF 点：camera_model 已透传；AF 索引仍无 ExifAux/MakerNote 数据源，
    /// 机型表为空时只走"人脸中心"回退——设计里明确的降级路径，不伪造相机 AF。
    private func currentAFPoint() -> AFPoint? {
        guard let port = PreviewAnalysisRegistry.current(), let asset = currentAsset else {
            return nil
        }
        let camera = asset.photo.metadata["camera_model"]?.stringValue ?? ""
        return port.afPoint(faceBoxes: asset.faceBboxes, cameraModel: camera, afIndex: nil)
    }

    // MARK: 开关方法（供工具栏与后续键位表调用；本文件不硬编码裸键）

    /// 直方图开关（键位表将来分配 H）。
    func toggleHistogram() {
        overlayState.toggleHistogram()
    }

    /// 合焦提示开关（键位表将来分配 F）。
    func toggleFocusMask() {
        overlayState.toggleFocusMask()
    }

    /// 裁剪标记开关（键位表将来分配 C/O 之外的位置；O 是"显示全图"）。
    func toggleCropFrame() {
        overlayState.toggleCropFrame()
    }

    /// "显示全图"（临时去掉裁剪蒙版）。
    func toggleFullFrame() {
        overlayState.toggleFullFrame()
    }

    /// 把当前照片设为参考 / 取消参考（R）。
    func toggleReference() {
        guard let asset = currentAsset else { return }
        overlayState.toggleReference(
            photoId: asset.photo.id,
            filepath: asset.photo.filepath,
            filename: asset.photo.filename
        )
    }

    /// 参考对比模式循环（C：并排 → 分割 → 叠加）。
    func cycleReferenceMode() {
        overlayState.cycleReferenceMode()
    }

    /// 交换主/参考（\）。
    func swapReference() {
        overlayState.swapReference()
    }

    /// 点击 AF 框：以该点为中心、100% 查看（复用 FaceAlign 的坐标模型）。
    private func focus(on point: AFPoint, cellSize: CGSize) {
        guard let asset = currentAsset, cellSize.width > 0, cellSize.height > 0 else { return }
        scale = 1
        gestureScale = 1
        offset = FaceAlign.offset(
            imageSize: CGSize(
                width: Double(asset.photo.width),
                height: Double(asset.photo.height)
            ),
            cellSize: cellSize,
            face: [point.x, point.y, 0, 0],
            zoom: 1
        )
        dragStartOffset = offset
        scheduleDetailTileUpdate()
    }
}

/// 获取承载视图的 NSWindow（滚轮事件监听的窗口归属判断用）。
private struct WindowBridge: NSViewRepresentable {
    /// (window, proxyView)：proxyView 即本 representable 的宿主视图，
    /// 其 bounds 就是查看器区域（滚轮命中的坐标系来源）。
    let onResolve: (NSWindow?, NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window, view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window, nsView) }
    }
}

// MARK: - 查看器缩放控件的功能层材质

/// 缩放控件浮在照片之上，属于 Liquid Glass 的**功能层**：用 `.glass(.clear)`。
private struct ViewerZoomChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .gatherFunctionalCapsule(clear: true)
            .padding(.leading, GatherMetrics.Space.m)
            .padding(.bottom, 40)
    }
}
