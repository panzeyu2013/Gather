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

// MARK: - 缩放换算（纯逻辑，可单测）

/// 查看器缩放口径：`scale` 是**相对 fit** 的倍率（1 = 适配窗口）。
///
/// 旧实现把它当"百分比"用：fit 时也显示 100%、⌘0 写"实际大小"却执行 fit 复位
/// （20-culling-browse #2）。这里补上真 1:1 的换算——让 1 个源像素落在 1 个
/// 屏幕**物理**像素上（Retina 要除 backingScale），百分比也按这个口径显示。
enum CullingViewerZoom {
    /// fit 档（相对倍率 1.0）。
    static let fitScale = 1.0
    /// 既有缩放范围上限（fit 的 8 倍）：没有 1:1 需求时行为不变。
    static let baseMaximumScale = 8.0

    /// 实际像素（1:1）倍率：按「源像素 / (fit 点数 × 屏幕缩放)」反算。
    ///
    /// 图像本身小于 fit 尺寸时（小图放大到铺满）反算结果 < 1，收敛回 fit：
    /// 此时 fit 已经是"比 1:1 更大"，没有更小的合法档位。
    static func actualPixelsScale(
        sourceMaxDimension: Int,
        fitPoints: Double,
        backingScale: Double
    ) -> Double? {
        guard sourceMaxDimension > 0, fitPoints > 0, fitPoints.isFinite,
              backingScale > 0, backingScale.isFinite else { return nil }
        let raw = Double(sourceMaxDimension) / (fitPoints * backingScale)
        guard raw.isFinite, raw > 0 else { return nil }
        return max(fitScale, raw)
    }

    /// 缩放上限：至少保留既有 fit×8；实际像素档更高时抬高到它，
    /// 否则大图在窄窗口里永远碰不到 1:1（"真 1:1"名存实亡）。
    static func maximumScale(
        sourceMaxDimension: Int,
        fitPoints: Double,
        backingScale: Double
    ) -> Double {
        guard let actual = actualPixelsScale(
            sourceMaxDimension: sourceMaxDimension,
            fitPoints: fitPoints,
            backingScale: backingScale
        ) else { return baseMaximumScale }
        return max(baseMaximumScale, actual)
    }

    /// 查看器窗口所在屏的 backingScale（Wave4b / P2-6）。
    ///
    /// 优先窗口自己的屏幕：NSScreen.main 是"当前收键盘事件的窗口所在屏"，
    /// 查看器不在主屏/第二屏与主屏 scale 不同（1x + Retina 混用）时会错档；
    /// 窗口还没解析出来时退回主屏，最后按 2（Retina）保守兜底。
    static func resolvedBackingScale(windowScale: Double?, screenScale: Double?) -> Double {
        if let windowScale, windowScale.isFinite, windowScale > 0 { return windowScale }
        if let screenScale, screenScale.isFinite, screenScale > 0 { return screenScale }
        return 2
    }

    /// 1:1 模式在窗口尺寸变化后的重锚（Wave4b / P2-7）。
    ///
    /// 1:1 是"模式"而不是一次性换算：窗口 resize 后 fitPoints 变了，同一个
    /// scale 已经不再对应 1:1；调用方在尺寸变化时用它重算 scale。非 1:1 模式
    /// 返回 nil（保持用户当前缩放）。
    static func reanchoredScale(
        actualPixelsMode: Bool,
        sourceMaxDimension: Int,
        fitPoints: Double,
        backingScale: Double
    ) -> Double? {
        guard actualPixelsMode else { return nil }
        return actualPixelsScale(
            sourceMaxDimension: sourceMaxDimension,
            fitPoints: fitPoints,
            backingScale: backingScale)
    }

    /// 收敛到 [fitScale, maximum]；非法值回落到 fit。
    static func clamp(_ scale: Double, maximum: Double = baseMaximumScale) -> Double {
        guard scale.isFinite else { return fitScale }
        let upper = maximum.isFinite && maximum > fitScale ? maximum : baseMaximumScale
        return min(upper, max(fitScale, scale))
    }

    /// 当前缩放相对源像素的百分比（1:1 = 100%）；不可算时 nil（胶囊隐藏）。
    static func pixelPercent(
        scale: Double,
        sourceMaxDimension: Int,
        fitPoints: Double,
        backingScale: Double
    ) -> Int? {
        guard sourceMaxDimension > 0, fitPoints > 0, fitPoints.isFinite,
              backingScale > 0, backingScale.isFinite, scale.isFinite else { return nil }
        let ratio = scale * fitPoints * backingScale / Double(sourceMaxDimension)
        guard ratio.isFinite, ratio > 0 else { return nil }
        return Int((ratio * 100).rounded())
    }
}

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
    /// 是否 Survey 布局：选片规则从"当前 ± 邻接"改为"选择集驱动"（见 CullingComparison）。
    var isSurvey: Bool = false
    let faceAlign: Bool
    /// 专注模式是否开启（状态由页面持有：隐藏检查器/折叠胶片条/窗口全屏）。
    var isFocusMode: Bool = false
    /// 专注模式切换：F 裸键挂在查看器上（查看器是页面里唯一始终存在且持有焦点的
    /// 控件），实际的面板折叠/全屏动作由页面执行。
    var onToggleFocusMode: () -> Void = {}
    /// B1：用户是否显式打开「作用于全部选中 N 张」（默认关，页面持有）。
    /// 关着的时候对比/Survey 的键盘决策只写当前照片——多选在那里是构造画面的手段。
    var writesDecisionToSelection: Bool = false

    /// Cut 4 / 4b-1：质量失败原因在渲染期按当前语言解析。
    @Environment(\.languageStore) private var languageStore
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// Wave3 / task-20：第二屏镜像桥（nil = 未启用/预览）与开窗能力。
    @Environment(\.cullingSecondDisplay) var secondDisplay
    @Environment(\.openWindow) var openWindow

    @State var scale = 1.0
    /// 底层整图位图（基准档）：细节由可见区域层提供，底层不随缩放抬高。
    @State var detailBaseSize = PhotoDetailTier.baseDimension
    /// 每格最近一次布局尺寸（A-6：细节层几何必须按**各自**单元格算，不能共用）。
    @State var cellSizes: [String: CGSize] = [:]
    /// 每格可见区域细节贴片（Wave2：#3 起非当前格也可能有；key = photoId）。
    @State var detailTiles: [String: PhotoViewerGeometry.DetailTile] = [:]
    /// 每格贴片去抖任务（切图/缩放/切布局/离开时取消）。
    @State var detailTileTasks: [String: Task<Void, Never>] = [:]
    @State var gestureScale = 1.0
    @State var offset = CGSize.zero
    /// 本次拖拽开始时的位移基线（B-C2）：DragGesture.translation 是相对手势起点
    /// 的累计量，直接赋给 offset 会让每次新手势从 0 起算——松手再拖就弹回原点。
    @State var dragStartOffset = CGSize.zero
    /// Wave4b / P2-7：当前是否处于「实际像素（1:1）」模式——窗口/布局尺寸变化时
    /// 据此重算 scale；任何手动缩放/复位都会退出该模式。
    @State var actualPixelsMode = false
    @State var hoveredCellId: String?
    /// Wave3 / task-20：打印版面面板。
    @State var showingPrintSheet = false
    @State var wheelMonitor: Any?
    @State var viewerWindow: NSWindow?
    /// 查看器区域的 AppKit 代理视图（.background(WindowBridge)）。
    ///
    /// 约束循环修复（F01）：滚轮命中原先比较 GeometryReader 写回 @State 的
    /// .global frame——每帧重排都写观察状态，持续放大约束更新次数。
    /// 改为直接问代理视图「这个点在你 bounds 里吗」：位置由 AppKit 自己维护，
    /// 不产生任何布局反馈。
    @State var viewerProxy: NSView?
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
    @State var overlayState = CullingViewerOverlayState()
    @State var histogram: PreviewHistogram?
    @State var focusMask: FocusMask?
    /// crs:Crop* 只读裁剪框（nil = 无 sidecar/无裁剪，不画标记）。
    @State var cropFrame: CropFrame?
    /// Wave5 batch6 / G11：当前照片是否有 C1 调整（nil = 无/读不到 → 徽标静默隐藏）。
    @State private var c1AdjustmentHint: C1AdjustmentHint?

    /// 当前已加载列表（viewModel.page 变化经 @Observable 自动回流）。
    var assets: [CullingAsset] {
        viewModel.page?.assets ?? []
    }

    /// 当前项下标：按 photo.id 查找；找不到时回退 0（非空列表）。
    /// O(1)：复用 pageVersion 索引，不再逐帧扫已加载页。
    private var currentIndex: Int {
        viewModel.currentPageIndex() ?? 0
    }

    /// 越界保护的下标访问；列表为空时返回 nil。
    var currentAsset: CullingAsset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    /// 面部对齐时的有效缩放（旧版 faceAlign 下 scale 下限 2）。
    private var effectiveScale: Double {
        faceAlign ? max(2, scale) : scale
    }

    var body: some View {
        GeometryReader { geometry in
            viewerGrid(geometry: geometry)
        }
        .background(GatherTheme.viewerChrome)
        .clipped()
        .overlay(alignment: .top) {
            // 缩放提示（对齐旧版 zoomHint）：只在**离开 fit** 后显示，百分比按
            // 「1 源像素 = 1 屏幕像素 = 100%」口径换算——1:1 时正好 100%，
            // 不再出现「fit 也写 100%」的名不副实（20-culling-browse #2）。
            if let zoomHint {
                Text(zoomHint)
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.9))
                    .padding(.horizontal, GatherMetrics.Space.s)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(Capsule().fill(GatherTheme.viewerSurface.opacity(0.85)))
                    .padding(.top, GatherMetrics.Space.s)
                    .monospacedDigit()
                    .help(l10n("滚轮缩放 · 拖动平移 · 双击复位 · ⌘−/⌘= 缩放"))
            }
        }
        // Wave5 batch6 / G11：C1 有调整时给可见徽标。
        //
        // 为什么必须有：Gather 预览走 ImageIO/CIRAWFilter 渲染，**不含** C1 的色彩/曲线/
        // 局部调整；没有提示时用户会以为"C1 调好的效果就是现在这样"，判断失真。
        // 只读元数据、失败静默隐藏（提示是增强信息，绝不阻塞看图）。
        .overlay(alignment: .topLeading) {
            if let badge = C1AdjustmentBadge(hint: c1AdjustmentHint) {
                Label(l10n(C1RejectedColorTagCopy.badgeLabel), systemImage: "camera.filters")
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.9))
                    .padding(.horizontal, GatherMetrics.Space.s)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
                    .padding(GatherMetrics.Space.s)
                    .help(l10n.format(
                        C1RejectedColorTagCopy.badgeHelpTemplate, badge.attributeCount))
                    .accessibilityLabel(l10n(C1RejectedColorTagCopy.badgeLabel))
            }
        }
        .overlay(alignment: .bottomLeading) {
            viewerToolbar
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
        .onKeyPress(phases: .down) { handleViewerKeyPress($0) }
        .background(WindowBridge { window, view in
            // 只在身份真正变化时写状态：updateNSView 每次布局都会回调，
            // 无条件赋值等于每次布局都排一轮视图更新（又是新的反馈环）。
            if viewerWindow !== window { viewerWindow = window }
            if viewerProxy !== view { viewerProxy = view }
        })
        .onAppear {
            startWheelMonitor()
            // B3：参考槽随会话恢复（存档在 VM；已设参考时不覆盖）。
            restoreViewerReferenceIfNeeded()
            // P0-4：进入查看器即为当前照片调度邻张预取（去抖后只跑最后一次）。
            viewModel.scheduleNeighborPreload()
            // Wave3 / task-20：把当前缩放/平移发布给第二屏（只读镜像）。
            publishViewerTransform()
        }
        .onDisappear {
            stopWheelMonitor()
            // 离开查看器（切网格/离开页面）立即取消未完成的预取与贴片解码。
            viewModel.cancelNeighborPreload()
            clearDetailTiles()
        }
        // B3：会话存档异步注入（页面 .task 晚于查看器 onAppear 时也能恢复）。
        .onChange(of: viewModel.viewerReference) { _, _ in
            restoreViewerReferenceIfNeeded()
        }
        // 复用旧版 resetTransform 语义：对比模式切换 / 人脸对齐开关 / 翻页
        // 均显式复位缩放与位移（替代旧的 .id() 整树重建，避免焦点与监听扰动）。
        .onChange(of: compareCount) { _, _ in
            resetTransform()
            // 格数变化（切 2/3/4/Survey）后旧贴片几何全部作废。
            clearDetailTiles()
        }
        .onChange(of: faceAlign) { _, _ in
            resetTransform()
            clearDetailTiles()
            publishViewerTransform()
        }
        .onChange(of: viewModel.currentPhotoId) { _, _ in
            resetTransform()
            clearDetailTiles()
            publishViewerTransform()
            // 翻片/选片后重新调度 ±2 预取（去抖：连按只预热最后一张的邻张）。
            viewModel.scheduleNeighborPreload()
        }
        // Wave3 / task-20：打印版面面板（单图/多页；渲染经宿主打印端口）。
        .sheet(isPresented: $showingPrintSheet) {
            PrintOptionsSheet(
                items: printItems,
                currentItem: currentPrintItem,
                truncatedCount: printTruncatedCount)
        }
        // 页集合变化（筛选/排序/翻页/加载更多）才重算邻张；**决策回显不重算**：
        // pageVersion 每次决策都会 +1，用它当去抖键会让快速连按（<120ms/拍）时
        // 预取被反复取消，恰好饿死最需要预取的场景（Wave4b / P2-8）。
        .onChange(of: CullingPreloadPlanner.pageSignature(assets: assets)) { _, _ in
            viewModel.scheduleNeighborPreload()
        }
        // 窗口/布局尺寸变化：1:1 模式下按新 fitPoints 重锚（缩放档位保持有效）。
        .onChange(of: currentCellSize) { _, _ in
            reanchorActualPixelsIfNeeded()
        }
        // 可见区域细节层：缩放或平移停止 150ms 后重算每一格的「可见矩形」，
        // 只重解那一块（Wave2：2 图/当前格/hover 格各自有贴片）。
        .onChange(of: scale) { _, _ in
            scheduleDetailTileUpdateForVisibleCells()
            publishViewerTransform()
        }
        .onChange(of: offset) { _, _ in
            scheduleDetailTileUpdateForVisibleCells()
            publishViewerTransform()
        }
        // hover 进入新格：>2 图时要给它解贴片（当前+hover 策略）。
        .onChange(of: hoveredCellId) { _, _ in scheduleDetailTileUpdateForVisibleCells() }
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
            c1AdjustmentHint = nil
            guard let photoId = viewModel.currentPhotoId else { return }
            // G11：C1 调整提示（只读 XMP crs: 字段；失败/未接线即 nil → 徽标不显示）。
            if let path = viewModel.currentAsset?.photo.filepath, !path.isEmpty {
                let hint = await viewModel.c1AdjustmentHint(for: path)
                guard !Task.isCancelled, viewModel.currentPhotoId == photoId else { return }
                c1AdjustmentHint = hint
            }
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

}
