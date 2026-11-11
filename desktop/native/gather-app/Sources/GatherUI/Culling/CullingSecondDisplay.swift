// desktop/native/gather-app/Sources/GatherUI/Culling/CullingSecondDisplay.swift
// Wave3 / task-20：第二显示器窗口（挑片页「在第二屏显示」）。
//
// 结构（不破坏现有单窗口假设）：
// - GatherApp 仍是 `Window(main)` 单窗口语义，第二屏是**另一个 Window 场景**
//   （独立窗口 id），不改成 WindowGroup；⌘W/Window 菜单行为不变；
// - 两个窗口共享同一个 App 级 @Observable `CullingSecondDisplayCoordinator`：
//   主窗口的挑片页 attach 当前会话与布局，主查看器发布 scale/offset；
// - 第二屏**只读镜像**：读取同一个 CullingViewModel 实例（选择/当前照片天然一致），
//   不调用任何写方法、不改 VM 可见性状态机（避免两边 setVisible 造成 Job 轮询抖动），
//   也不触发 SessionStore.workspace(for:)（那会 active/淘汰 workspace）。
//
// 关闭策略（任务要求的"明确策略"）：第二屏独立保留；主窗口关闭时
// GatherApp 把 coordinator 置为 detached，第二屏转而显示"主窗口已关闭"空态，
// 而不是跟着消失，也不会留下悬空引用。
import AppKit
import SwiftUI
import GatherProtocol

// MARK: - 窗口 id

/// 第二屏窗口的稳定 id（GatherApp 的 Window 场景与挑片页按钮共用同一常量）。
package enum CullingSecondDisplayWindowID {
    package static let id = "culling-second-display"
}

// MARK: - 主窗口 → 第二屏的镜像桥

/// App 级单向镜像桥（主窗口写、第二屏读）。
///
/// 只承载展示状态（会话/布局/缩放/位移），不承载任何写操作或生命周期控制。
@MainActor
@Observable
package final class CullingSecondDisplayCoordinator {
    /// 主窗口当前挑片页的会话 id（nil = 还没进过挑片页）。
    package private(set) var sessionId: String?
    /// 主窗口当前布局的 rawValue（CullingLayoutMode.rawValue）。
    package private(set) var layoutRaw: String?
    /// 查看器相对 fit 的缩放级（含人脸对齐下限）。
    package private(set) var zoom: Double = 1
    /// 查看器平移量（点为单位的单元格空间位移）。
    package private(set) var offset: CGSize = .zero
    /// 主窗口是否仍在提供数据；false 时第二屏显示空态（主窗口已关闭/未就绪）。
    package private(set) var isSourceAttached = false

    package init() {}

    /// 主窗口挑片页出现/切会话：登记会话与布局。
    package func attach(sessionId: String, layoutRaw: String) {
        self.sessionId = sessionId
        self.layoutRaw = layoutRaw
        isSourceAttached = true
    }

    /// 主窗口布局切换（单图/2/3/4 图/网格/Survey）：第二屏跟随。
    package func updateLayoutRaw(_ raw: String) {
        layoutRaw = raw
        if !raw.isEmpty { isSourceAttached = true }
    }

    /// 主查看器发布缩放/平移（只读镜像用）。
    package func publishViewerTransform(zoom: Double, offset: CGSize) {
        self.zoom = zoom.isFinite ? max(1, zoom) : 1
        self.offset = offset
    }

    /// 主窗口关闭（GatherApp 主 Window 内容 onDisappear）：第二屏保留窗口、转空态。
    package func detach() {
        isSourceAttached = false
    }
}

// MARK: - Environment

private struct CullingSecondDisplayEnvironmentKey: EnvironmentKey {
    static var defaultValue: CullingSecondDisplayCoordinator? { nil }
}

package extension EnvironmentValues {
    /// 第二屏镜像桥（App 级注入；预览/测试默认 nil，行为退化为原样）。
    var cullingSecondDisplay: CullingSecondDisplayCoordinator? {
        get { self[CullingSecondDisplayEnvironmentKey.self] }
        set { self[CullingSecondDisplayEnvironmentKey.self] = newValue }
    }
}

// MARK: - 第二屏窗口内容

package struct CullingSecondDisplayWindow: View {
    let sessionStore: SessionStore
    let coordinator: CullingSecondDisplayCoordinator

    @Environment(\.languageStore) private var languageStore
    @Environment(\.dismissWindow) private var dismissWindow
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    package init(sessionStore: SessionStore, coordinator: CullingSecondDisplayCoordinator) {
        self.sessionStore = sessionStore
        self.coordinator = coordinator
    }

    package var body: some View {
        VStack(spacing: .zero) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Image(systemName: "display")
                .foregroundStyle(GatherTheme.accent)
                .accessibilityHidden(true)
            Text(l10n("第二屏 · 挑片查看器"))
                .font(GatherFont.bodyStrong)
            Text(l10n("跟随主窗口（只读）"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(l10n("关闭第二屏")) {
                dismissWindow(id: CullingSecondDisplayWindowID.id)
            }
            .gatherButton(.secondary, size: .small)
            .help(l10n("关闭第二屏窗口；主窗口不受影响"))
        }
        .padding(.horizontal, GatherMetrics.Space.l)
        .padding(.vertical, GatherMetrics.Space.s)
        .background(GatherTheme.surface)
    }

    @ViewBuilder
    private var content: some View {
        if let sessionId = coordinator.sessionId,
           let workspace = sessionStore.workspaces[sessionId] {
            if !coordinator.isSourceAttached {
                detachedState
            } else {
                CullingSecondDisplayCanvas(
                    viewModel: workspace.culling,
                    layoutRaw: coordinator.layoutRaw,
                    zoom: coordinator.zoom,
                    offset: coordinator.offset)
            }
        } else if coordinator.sessionId == nil {
            // 还没进过挑片页：这是"未就绪"而不是"主窗口已关闭"。
            GatherEmptyState(
                icon: "display",
                title: l10n("主窗口尚未打开挑片页"),
                message: l10n("在主窗口进入挑片页后，第二屏会自动跟随当前照片与对比布局。"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 会话已被关闭/淘汰（workspaces 里没有）：同样按 detached 处理。
            detachedState
        }
    }

    private var detachedState: some View {
        GatherEmptyState(
            icon: "exclamationmark.triangle",
            title: l10n("主窗口已关闭"),
            message: l10n("重新打开主窗口并进入挑片页后，第二屏会自动恢复；本窗口可保持打开。"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 只读镜像画布

/// 第二屏的只读查看画布：布局/选片规则与主查看器一致，缩放与平移镜像主窗口。
///
/// 刻意不提供手势与任何写操作（评级/写回/淘汰只在主窗口做）。
private struct CullingSecondDisplayCanvas: View {
    let viewModel: CullingViewModel
    let layoutRaw: String?
    let zoom: Double
    let offset: CGSize

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var layout: CullingLayoutMode {
        guard let layoutRaw, let mode = CullingLayoutMode(rawValue: layoutRaw) else {
            return .single
        }
        return mode
    }

    private var assets: [CullingAsset] { viewModel.page?.assets ?? [] }

    private var currentAsset: CullingAsset? {
        guard let id = viewModel.currentPhotoId else { return assets.first }
        return assets.first { $0.photo.id == id } ?? assets.first
    }

    /// 与主查看器同一套选片规则（2/3/4 图显式选择优先；Survey 由选择集决定）。
    private var visibleAssets: [CullingAsset] {
        let selection = viewModel.selectedPhotoIds
        let count = layout.effectiveCompareCount(selectionCount: selection.count)
        if layout == .survey {
            return CullingComparison.surveyAssets(
                current: currentAsset,
                assets: assets,
                selectedIds: selection,
                limit: count)
        }
        if layout == .grid {
            // 第二屏不做网格（网格是主窗口的编辑态）；退回单图避免 200 张缩略图。
            return currentAsset.map { [$0] } ?? []
        }
        return CullingComparison.assets(
            current: currentAsset,
            assets: assets,
            selectedIds: selection,
            compareCount: count)
    }

    var body: some View {
        Group {
            if assets.isEmpty {
                GatherEmptyState(
                    icon: "photo.on.rectangle.angled",
                    title: l10n("主窗口尚未载入挑片页"),
                    message: l10n("在主窗口进入挑片页并载入照片后，第二屏会显示当前照片。"))
            } else {
                canvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GatherTheme.viewerBackground)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let visible = visibleAssets
            let columns = CullingViewerGridLayout.columns(for: visible.count)
            let rows = CullingViewerGridLayout.rows(for: visible.count, columns: columns)
            let groups = groupCells(visible, columns: columns)
            // 底部状态栏先扣掉，避免格子按整窗高度算后被 footer 顶出可视区。
            let footerHeight = GatherMetrics.Chrome.infoBar
            let gridHeight = max(1, geometry.size.height - footerHeight)
            let cellSize = CullingViewerGridLayout.cellSize(
                container: CGSize(width: geometry.size.width, height: gridHeight),
                columns: columns,
                rows: rows)
            // Wave4a / B3：第二屏也按同屏格数分配细节贴片预算（与主查看器同源）。
            let visibleCount = max(1, visible.count)
            let detailBudget = PhotoDetailTier.budget(forVisibleCells: visibleCount)
            VStack(spacing: .zero) {
                VStack(spacing: GatherMetrics.Space.s) {
                    ForEach(0..<groups.count, id: \.self) { rowIndex in
                        HStack(spacing: GatherMetrics.Space.s) {
                            ForEach(groups[rowIndex]) { cell in
                                CullingMirrorCell(
                                    asset: cell.asset,
                                    isCurrent: cell.asset.photo.id == currentAsset?.photo.id,
                                    cellSize: cellSize,
                                    zoom: zoom,
                                    offset: offset,
                                    visibleCount: visibleCount,
                                    detailBudget: detailBudget)
                                    .frame(width: cellSize.width, height: cellSize.height)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                footer
                    .frame(height: footerHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Text(l10n("第二屏只读：请回主窗口操作选择与标记"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let page = viewModel.page {
                Text(l10n.format("第 %lld / %lld 张 · 已选 %lld 张",
                                 currentIndex + 1, page.total, viewModel.selectedPhotoIds.count))
                    .font(GatherFont.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, GatherMetrics.Space.l)
        .padding(.vertical, GatherMetrics.Space.xs)
        .background(GatherTheme.surface)
    }

    private var currentIndex: Int {
        guard let id = viewModel.currentPhotoId,
              let index = assets.firstIndex(where: { $0.photo.id == id }) else { return 0 }
        return index
    }

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
}
// MARK: - 第二屏镜像贴片（Wave4a / B3）

/// 第二屏镜像贴片的纯逻辑（可单测）。
///
/// 与主查看器共用同一套几何与预算来源：`PhotoViewerGeometry.detailTile`（可见区
/// 归一化矩形 + 视图落位）、`PhotoViewerGeometry.tilePixelSize`（目标像素）、
/// `PhotoDetailTier.budget(forVisibleCells:)`（同屏格数收窄预算）。
///
/// 与主查看器的唯一差别来自第二屏的只读语义：没有 hover/手势，因此 >2 格时只给
/// 当前格贴片（主查看器是"当前 + hover"），避免镜像窗口一次解 N 块细节。
enum CullingSecondDisplayMirror {
    static func showsTile(visibleCount: Int, isCurrent: Bool) -> Bool {
        CullingDetailTilePolicy.showsTile(
            compareCount: max(1, visibleCount),
            isCurrent: isCurrent,
            isHovered: false)
    }

    /// 该格在当前 zoom/offset 下的可见区贴片；nil = 2560 基准位图已够（fit 档）。
    static func tile(
        asset: CullingAsset,
        cellSize: CGSize,
        zoom: Double,
        offset: CGSize
    ) -> PhotoViewerGeometry.DetailTile? {
        PhotoViewerGeometry.detailTile(
            imageSize: CGSize(
                width: Double(asset.photo.width),
                height: Double(asset.photo.height)),
            viewSize: cellSize,
            zoom: zoom,
            panOffset: offset,
            backingPixelBudget: PhotoDetailTier.baseDimension)
    }

    /// 区域解码目标像素（随同屏格数收窄，与主查看器的 detailBudget 同源）。
    static func targetPixel(
        tile: PhotoViewerGeometry.DetailTile,
        budgetDimension: Int
    ) -> Int {
        PhotoViewerGeometry.tilePixelSize(
            viewRect: tile.viewRect,
            budgetDimension: budgetDimension)
    }
}

/// 第二屏只读画布的单格：基准位图 + 共享 zoom/offset + 可见区细节贴片。
///
/// 细节贴片用 `.task(id:)` 做 150ms 去抖（缩放/平移过程中不排重解码，键变化自动
/// 取消上一次任务）；贴片只画不接手势，第二屏仍然是纯展示。
private struct CullingMirrorCell: View {
    let asset: CullingAsset
    let isCurrent: Bool
    let cellSize: CGSize
    let zoom: Double
    let offset: CGSize
    /// 同屏总格数（贴片可见性与预算按它算，与主查看器一致）。
    let visibleCount: Int
    /// 本次同屏允许的单格解码档位上限。
    let detailBudget: Int

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    @State private var tile: PhotoViewerGeometry.DetailTile?

    init(
        asset: CullingAsset,
        isCurrent: Bool,
        cellSize: CGSize,
        zoom: Double,
        offset: CGSize,
        visibleCount: Int,
        detailBudget: Int
    ) {
        self.asset = asset
        self.isCurrent = isCurrent
        self.cellSize = cellSize
        self.zoom = zoom
        self.offset = offset
        self.visibleCount = visibleCount
        self.detailBudget = detailBudget
    }

    /// 贴片任务键：路径/几何/缩放/平移/布局任一变化都重算并取消旧任务。
    private struct TileTaskKey: Hashable {
        let path: String
        let width: Double
        let height: Double
        let zoom: Double
        let offsetWidth: Double
        let offsetHeight: Double
        let visibleCount: Int
        let isCurrent: Bool
    }

    private var tileTaskKey: TileTaskKey {
        TileTaskKey(
            path: asset.photo.filepath,
            width: Double(cellSize.width),
            height: Double(cellSize.height),
            zoom: zoom,
            offsetWidth: Double(offset.width),
            offsetHeight: Double(offset.height),
            visibleCount: visibleCount,
            isCurrent: isCurrent)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 基准位图：立即显示、负责构图；放大后的真实像素由下面的细节层补。
            PhotoThumbnailView(
                path: asset.photo.filepath,
                size: PhotoDetailTier.baseDimension,
                preview: true,
                contentMode: .fit,
                placeholderSurface: GatherTheme.viewerSurface,
                placeholderTextColor: GatherTheme.viewerTextSecondary
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(zoom)
            .offset(offset)
            .allowsHitTesting(false)
            // 可见区细节层：只在需要（zoom>1 且超过基准位图分辨率）且策略允许时渲染。
            if let tile,
               CullingSecondDisplayMirror.showsTile(
                   visibleCount: visibleCount, isCurrent: isCurrent) {
                PhotoDetailTileView(
                    path: asset.photo.filepath,
                    normalizedRect: tile.normalizedRect,
                    targetPixel: CullingSecondDisplayMirror.targetPixel(
                        tile: tile, budgetDimension: detailBudget),
                    onUnavailable: nil
                )
                .frame(width: max(0, tile.viewRect.width), height: max(0, tile.viewRect.height))
                .position(x: tile.viewRect.midX, y: tile.viewRect.midY)
                .allowsHitTesting(false)
            }
            HStack(spacing: GatherMetrics.Space.s) {
                Text(asset.photo.filename).lineLimit(1)
                Spacer(minLength: 0)
                Text(asset.state.rating > 0
                     ? "\(Int(asset.state.rating))★"
                     : l10n("未评级"))
            }
            .font(GatherFont.secondary)
            .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.92))
            .padding(.horizontal, GatherMetrics.Space.xs)
            .padding(.vertical, GatherMetrics.Space.xxs)
            .frame(maxWidth: .infinity)
            .background(GatherTheme.viewerSurface.opacity(0.9))
            if isCurrent {
                Text(l10n("当前"))
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextPrimary)
                    .padding(.horizontal, GatherMetrics.Space.xs)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(Capsule().fill(GatherTheme.accent.opacity(0.85)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(GatherMetrics.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(GatherTheme.viewerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.media, style: .continuous)
                .stroke(isCurrent ? GatherTheme.accent.opacity(0.65) : GatherTheme.viewerSurface, lineWidth: 1)
        )
        .task(id: tileTaskKey) {
            await updateTile()
        }
    }

    /// 与主查看器一致的 150ms 去抖：平移/缩放过程不排重解码；任务取消即退出。
    private func updateTile() async {
        guard CullingSecondDisplayMirror.showsTile(
            visibleCount: visibleCount, isCurrent: isCurrent) else {
            tile = nil
            return
        }
        // 回到 fit 档立即清掉细节层，避免旧贴片在新缩放级上多显示 150ms。
        guard zoom > 1 else {
            tile = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        tile = CullingSecondDisplayMirror.tile(
            asset: asset, cellSize: cellSize, zoom: zoom, offset: offset)
    }
}
