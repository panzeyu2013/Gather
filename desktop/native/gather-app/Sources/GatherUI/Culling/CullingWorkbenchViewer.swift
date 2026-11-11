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
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// Wave3 / task-20：第二屏镜像桥（nil = 未启用/预览）与开窗能力。
    @Environment(\.cullingSecondDisplay) private var secondDisplay
    @Environment(\.openWindow) private var openWindow

    @State private var scale = 1.0
    /// 底层整图位图（基准档）：细节由可见区域层提供，底层不随缩放抬高。
    @State private var detailBaseSize = PhotoDetailTier.baseDimension
    /// 每格最近一次布局尺寸（A-6：细节层几何必须按**各自**单元格算，不能共用）。
    @State private var cellSizes: [String: CGSize] = [:]
    /// 每格可见区域细节贴片（Wave2：#3 起非当前格也可能有；key = photoId）。
    @State private var detailTiles: [String: PhotoViewerGeometry.DetailTile] = [:]
    /// 每格贴片去抖任务（切图/缩放/切布局/离开时取消）。
    @State private var detailTileTasks: [String: Task<Void, Never>] = [:]
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    /// 本次拖拽开始时的位移基线（B-C2）：DragGesture.translation 是相对手势起点
    /// 的累计量，直接赋给 offset 会让每次新手势从 0 起算——松手再拖就弹回原点。
    @State private var dragStartOffset = CGSize.zero
    /// Wave4b / P2-7：当前是否处于「实际像素（1:1）」模式——窗口/布局尺寸变化时
    /// 据此重算 scale；任何手动缩放/复位都会退出该模式。
    @State private var actualPixelsMode = false
    @State private var hoveredCellId: String?
    /// Wave3 / task-20：打印版面面板。
    @State private var showingPrintSheet = false
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
            // ⌘⌥0 = 实际像素（⌘0 已修正为「适配窗口」；⌘1 另绑在可见按钮上）。
            // ⌘⌥ 组合不会被系统快捷键占用，因此能在 onKeyPress 里收口。
            if press.characters == "0",
               press.modifiers.contains(.command),
               press.modifiers.contains(.option) {
                zoomToActualPixels()
                return .handled
            }
            // 裸键决策：带 ⌘/⌥ 的组合交给系统（⌘X 不能变成“淘汰”）。
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.option) else { return .ignored }
            // Wave2（20-culling-browse #8）：叠加层/查看模式键位 H/F/R/C。
            // 裸 F = 合焦掩膜（评审设计意图），⇧F = 专注模式（Wave1 的 F 让位，
            // 「显示」菜单/查看器按钮的 help 同步标注 ⇧F）。
            if let action = CullingViewerShortcutKey.action(
                characters: press.characters,
                shift: press.modifiers.contains(.shift)
            ) {
                switch action {
                case .toggleHistogram:
                    toggleHistogram()
                case .toggleFocusMask:
                    toggleFocusMask()
                case .toggleFocusMode:
                    onToggleFocusMode()
                case .toggleReference:
                    toggleReference()
                case .cycleReferenceMode:
                    // C 只在已设参考时有意义（未设参考时对比模式组本来就不显示）。
                    guard overlayState.hasReference else { return .ignored }
                    overlayState.cycleReferenceMode()
                }
                return .handled
            }
            // B1：键盘决策统一走 commitDecision——对比/Survey 默认只写当前照片
            // （旧实现直接走 commit = 选择集优先，盯着 A 按 X 会标掉 B…I）。
            switch press.characters.lowercased() {
            case " ":
                commitDecision(CullingUpdatePatch(pickState: .picked))
                return .handled
            case "p":
                commitDecision(CullingUpdatePatch(pickState: .picked))
                return .handled
            case "x":
                commitDecision(CullingUpdatePatch(pickState: .rejected))
                return .handled
            case "u":
                // P2-3：U 统一不前进（与检查器/网格一致），避免跳走当前照片。
                commitDecision(CullingUpdatePatch(pickState: .unreviewed), shouldAdvance: false)
                return .handled
            case "0", "1", "2", "3", "4", "5":
                guard let value = Int(press.characters) else { return .ignored }
                commitDecision(CullingUpdatePatch(rating: Double(value)))
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
                commitDecision(CullingUpdatePatch(colorLabel: label), shouldAdvance: false)
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
    /// - Parameters:
    ///   - visibleCells: 同屏总格数（贴片预算/可见性策略按它算，而不是布局固定格数）。
    ///   - detailBudget: 本次同屏允许的单格解码档位上限。
    private func cellView(_ cell: ViewerCell, visibleCells: Int, detailBudget: Int) -> some View {
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
    private func groupCells(_ visible: [CullingAsset], columns: Int) -> [[ViewerCell]] {
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

    /// 本次键盘决策是否只写当前照片（B1）。
    ///
    /// 解析规则见 CullingDecisionScope.target：对比类布局默认只写当前照片，
    /// 只有用户显式打开「作用于全部选中 N 张」才退回批量分支（与网格/检查器一致）。
    private var decisionCurrentOnly: Bool {
        switch CullingDecisionScope.target(
            isComparisonLayout: CullingDecisionScope.isComparisonLayout(
                compareCount: compareCount, isSurvey: isSurvey),
            // 用 currentAsset（= commit 实际会写的那张）：currentPhotoId 若已失效，
            // currentAsset 会回退到页首，回显与写入必须同一口径。
            currentPhotoId: viewModel.currentAsset?.photo.id,
            selectedPhotoIds: viewModel.selectedPhotoIds,
            writesToSelection: writesDecisionToSelection
        ) {
        case .current:
            return true
        case .selection, nil:
            return false
        }
    }

    /// 提交一拍决策：在按键落下时就冻结「是否只写当前照片」（加载期间的排队拍
    /// 会原样重放这个收窄，不在 flush 时重新解析）。
    private func commitDecision(_ patch: CullingUpdatePatch, shouldAdvance: Bool = true) {
        let currentOnly = decisionCurrentOnly
        Task {
            await viewModel.commit(
                patch: patch, shouldAdvance: shouldAdvance, currentOnly: currentOnly)
        }
    }

    /// 单/2/3/4 图：显式选中的对应张数优先，否则当前照片 ± 相邻（避免第 100 张
    /// 对比列表第 1 张）。Survey（#6）：张数由选择集决定，选片规则见
    /// CullingComparison.surveyAssets（选择不足 2 张时回退当前 + 邻接补足）。
    private func comparisonAssets() -> [CullingAsset] {
        if isSurvey {
            return CullingComparison.surveyAssets(
                current: currentAsset,
                assets: assets,
                selectedIds: viewModel.selectedPhotoIds,
                limit: compareCount)
        }
        return CullingComparison.assets(
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
        actualPixelsMode = false
    }

    // MARK: - Wave3 / task-20：第二屏镜像 + 打印

    /// 把当前缩放/平移发布给第二屏（只读镜像；主窗口是唯一写入方）。
    private func publishViewerTransform() {
        secondDisplay?.publishViewerTransform(zoom: effectiveZoom, offset: offset)
    }

    /// 打印面板的数据：有选择集时按页内顺序给全部选中（多页排版），
    /// 否则给当前照片（单图打印）。只做字段映射，不解码、不写盘。
    ///
    /// Wave4b / P2-11：上限 200 张保留（避免一次渲染上千张），但超出部分必须
    /// 在面板里可见——printTruncatedCount 由 PrintOptionsSheet 展示提示。
    private var printItems: [PrintJobItem] {
        printSelectionAssets.prefix(CullingPrintSelection.limit).map(Self.printItem)
    }

    /// 未被打印的选中张数（0 = 没有截断）。
    private var printTruncatedCount: Int {
        CullingPrintSelection.truncatedCount(total: printSelectionAssets.count)
    }

    /// 打印的候选资产（选择集优先，跨页选择全不在当前页时退回当前照片）。
    private var printSelectionAssets: [CullingAsset] {
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

    private var currentPrintItem: PrintJobItem? {
        currentAsset.map(Self.printItem)
    }

    private static func printItem(_ asset: CullingAsset) -> PrintJobItem {
        PrintJobItem(
            filePath: asset.photo.filepath,
            caption: asset.photo.filename,
            rating: Int(asset.state.rating.rounded()),
            label: "",
            pick: asset.state.pickState,
            keywords: asset.keywords
        )
    }

    /// 缩放/平移/尺寸变化后重算**所有会显示贴片的格**的可见区域细节层
    /// （逐格 150ms 去抖：拖动过程不排重解码队列）。Wave2（#3）：不再只算当前格。
    private func scheduleDetailTileUpdateForVisibleCells() {
        let visible = comparisonAssets()
        let count = max(1, visible.count)
        for asset in visible {
            let isCurrent = asset.photo.id == currentAsset?.photo.id
            let isHovered = asset.photo.id == hoveredCellId
            guard CullingDetailTilePolicy.showsTile(
                compareCount: count,
                isCurrent: isCurrent,
                isHovered: isHovered
            ) else { continue }
            scheduleDetailTileUpdate(for: asset.photo.id)
        }
    }

    /// 为某一格重算细节贴片。几何用**该格自己的**单元格尺寸与该照片宽高；
    /// 缩放/平移仍是全屏共享的一套（同步缩放语义不变）。
    private func scheduleDetailTileUpdate(for photoId: String) {
        guard let size = cellSizes[photoId],
              size.width > 0, size.height > 0,
              let asset = assets.first(where: { $0.photo.id == photoId }) else { return }
        let imageSize = CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height))
        let zoom = effectiveZoom
        let align = faceAlign ? alignOffset(for: asset, imageSize: imageSize, cellSize: size) : .zero
        let pan = CGSize(width: offset.width + align.width, height: offset.height + align.height)
        detailTileTasks[photoId]?.cancel()
        detailTileTasks[photoId] = Task { @MainActor in
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
            detailTiles[photoId] = tile
        }
    }

    /// 清掉所有在途/已落地的贴片（切图、切布局、离开查看器时调用）。
    private func clearDetailTiles() {
        for task in detailTileTasks.values { task.cancel() }
        detailTileTasks.removeAll(keepingCapacity: true)
        detailTiles.removeAll(keepingCapacity: true)
    }

    /// 当前渲染用的缩放级（人脸对齐时会把倍率抬到至少 2×）。
    private var effectiveZoom: Double {
        faceAlign ? max(2, scale) : scale
    }

    /// 某一格的人脸对齐位移（与 cellView 内计算的是同一个模型）。
    private func alignOffset(for asset: CullingAsset, imageSize: CGSize, cellSize: CGSize) -> CGSize {
        guard faceAlign, let face = asset.faceBboxes.first else { return .zero }
        return FaceAlign.offset(
            imageSize: imageSize,
            cellSize: cellSize,
            face: face,
            zoom: max(2, scale)
        )
    }

    /// 当前格最近一次布局尺寸（缩放提示/1:1 换算用）。
    private var currentCellSize: CGSize? {
        guard let id = currentAsset?.photo.id, let size = cellSizes[id],
              size.width > 0, size.height > 0 else { return nil }
        return size
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
        actualPixelsMode = false
        let next = CullingViewerZoom.clamp(scale * 1.15, maximum: zoomMaximum)
        scale = next
        gestureScale = next
    }

    private func zoomOut() {
        actualPixelsMode = false
        let next = CullingViewerZoom.clamp(scale * (1 / 1.15), maximum: zoomMaximum)
        scale = next
        gestureScale = next
    }

    /// 真 1:1：按源像素 / fitPoints（含查看器窗口屏 backingScale）反算相对 fit 的倍率。
    /// 源图尺寸未知（老库/未索引）时不做换算，保持当前缩放。
    /// Wave4b / P2-7：进入 1:1 后记住模式，窗口 resize 由 reanchorActualPixelsIfNeeded() 重锚。
    private func zoomToActualPixels() {
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
    private func reanchorActualPixelsIfNeeded() {
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
    private var zoomMaximum: Double {
        guard let asset = currentAsset, let size = currentCellSize else {
            return CullingViewerZoom.baseMaximumScale
        }
        return CullingViewerZoom.maximumScale(
            sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height)),
            fitPoints: Self.fitPoints(imageSize: imageSize(of: asset), cellSize: size),
            backingScale: viewerBackingScale())
    }

    /// 缩放胶囊文案：fit 档**不显示**；其余按源像素口径（1:1 = 100%）。
    private var zoomHint: String? {
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

    private func imageSize(of asset: CullingAsset) -> CGSize {
        CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height))
    }

    /// 查看器窗口所在屏的物理像素/点（Wave4b / P2-6）。
    ///
    /// NSScreen.main 跟随"当前收键盘事件的窗口"，查看器在第二屏/非主屏时会取错屏；
    /// 窗口已解析时以窗口自己的 screen 为准，窗口还没出来才退回主屏。
    private func viewerBackingScale() -> Double {
        CullingViewerZoom.resolvedBackingScale(
            windowScale: viewerWindow.map { Double($0.backingScaleFactor) },
            screenScale: NSScreen.main.map { Double($0.backingScaleFactor) })
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
        let next = CullingViewerZoom.clamp(
            scale * (event.scrollingDeltaY < 0 ? 1.15 : 0.87),
            maximum: zoomMaximum)
        guard next != scale else { return }
        actualPixelsMode = false
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
        actualPixelsMode = false
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
        scheduleDetailTileUpdateForVisibleCells()
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
