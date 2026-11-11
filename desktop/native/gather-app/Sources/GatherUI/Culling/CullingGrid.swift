// desktop/native/gather-app/Sources/GatherUI/Culling/CullingGrid.swift
// P0 / G0：挑片页第 4 种布局（网格）。
//
// 只消费 CullingViewModel.page 与既有 commit/选择方法；不做写回/同步。
// 信息层级固定为四角 + 底部条 + 最多 2 枚 chip（见 docs/design/p0/g0-grid-cull.md §3）。
import AppKit
import SwiftUI
import GatherProtocol

// MARK: - 布局与密度

enum CullingLayoutMode: String, CaseIterable, Equatable {
    case single
    case compare2
    /// 3 列并排（20-culling-browse #7：三选一时不再退化成 2+1 不对称布局）。
    case compare3
    case compare4
    /// Survey（#6）：N 张同屏，N 由当前选择集决定（2...9）；选择不足 2 张时
    /// 回退"当前照片 + 邻接"补足，见 `effectiveCompareCount(selectionCount:)`。
    case survey
    case grid

    /// Survey 一次最多同屏的张数：超过 9 格单格就小于判读阈值，应该回网格。
    static let surveyMaxCount = 9

    /// 固定格数布局的格数；survey 的格数由选择集决定（nil = 需调用方给选择集）。
    var fixedCompareCount: Int? {
        switch self {
        case .single, .grid: return 1
        case .compare2: return 2
        case .compare3: return 3
        case .compare4: return 4
        case .survey: return nil
        }
    }

    /// 兼容旧调用点（没有选择集信息时的兜底）：survey 至少 2 张。
    var compareCount: Int { fixedCompareCount ?? 2 }

    /// 该布局的首页大小（G0）：网格 200（密铺缩略图），其余布局 500（查看器翻片窗口）。
    ///
    /// 单一来源：页面 binding 与首屏 .task 都读它，避免两处各写一遍三元表达式
    /// 漂移（B2 的续页计划也以它为新页大小）。
    var pageLimit: Int {
        switch self {
        case .grid: return 200
        case .single, .compare2, .compare3, .compare4, .survey: return 500
        }
    }

    /// 有效对比格数：survey = 当前选择集张数（夹在 2...surveyMaxCount），
    /// 其余布局按固定格数（选择集不影响单/2/3/4 图/网格）。
    func effectiveCompareCount(selectionCount: Int) -> Int {
        switch self {
        case .survey: return min(Self.surveyMaxCount, max(2, selectionCount))
        default: return compareCount
        }
    }

    var titleKey: String {
        switch self {
        case .single: return "单图"
        case .compare2: return "2 图"
        case .compare3: return "3 图"
        case .compare4: return "4 图"
        case .survey: return "多图对比"
        case .grid: return "网格"
        }
    }

    var systemImage: String {
        switch self {
        case .single: return "rectangle"
        case .compare2: return "rectangle.split.2x1"
        case .compare3: return "rectangle.split.3x1"
        case .compare4: return "rectangle.split.2x2"
        case .survey: return "square.grid.2x2"
        case .grid: return "square.grid.3x3"
        }
    }
}

/// 查看器格子网格换算（纯逻辑，可单测）：column/row 只由同屏张数决定，
/// 与共享 scale/offset 无关——同步缩放语义不变。
enum CullingViewerGridLayout {
    /// 列数：1 张 1 列；2 张 2 列（并排）；3 张 3 列（真正 3 图）；4 张 2×2；
    /// 5–9 张 3 列（Survey：每行 3 格，末行不满留空）。
    static func columns(for count: Int) -> Int {
        switch count {
        case ..<2: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 2
        default: return 3
        }
    }

    static func rows(for count: Int, columns: Int? = nil) -> Int {
        let safeCount = max(1, count)
        let safeColumns = max(1, columns ?? Self.columns(for: safeCount))
        return max(1, (safeCount + safeColumns - 1) / safeColumns)
    }

    /// 单格尺寸：容器减去 (列-1)/(行-1) 条间距后均分；退化输入钳到 ≥1pt。
    static func cellSize(
        container: CGSize,
        columns: Int,
        rows: Int,
        spacing: CGFloat = GatherMetrics.Space.s
    ) -> CGSize {
        let safeColumns = max(1, columns)
        let safeRows = max(1, rows)
        let gap = max(0, spacing)
        let width = (container.width - gap * CGFloat(safeColumns - 1)) / CGFloat(safeColumns)
        let height = (container.height - gap * CGFloat(safeRows - 1)) / CGFloat(safeRows)
        return CGSize(width: max(1, width), height: max(1, height))
    }
}

enum CullingGridDensity: String, CaseIterable, Equatable {
    case s
    case m
    case l

    var rowHeight: Double {
        switch self {
        case .s: return 128
        case .m: return 168
        case .l: return 220
        }
    }

    var thumbnailSize: Int {
        switch self {
        case .s: return 512
        case .m: return 1024
        case .l: return 1024
        }
    }

    var titleKey: String {
        switch self {
        case .s: return "小图"
        case .m: return "中图"
        case .l: return "大图"
        }
    }
}

// MARK: - 键盘映射（纯函数，便于单测）

enum CullingGridKeyAction: Equatable {
    case rating(Int)
    case pick(PickState)
    case color(CaptureOneColorLabel)
    case keep
    case previous
    case next
    case selectAll
    case clearSelection
    case openSingle
}

enum CullingGridKeyMapper {
    static func action(
        characters: String,
        command: Bool,
        option: Bool
    ) -> CullingGridKeyAction? {
        let lower = characters.lowercased()
        // 裸键映射：任何 ⌘ 组合（除 ⌘A）都必须让给系统菜单，不能当挑片决策。
        if command { return lower == "a" ? .selectAll : nil }
        if option {
            if lower == "0" { return .color(.none) }
            if let index = Int(lower), (1...7).contains(index) {
                return .color(colorLabels[index - 1])
            }
            return nil
        }
        if let rating = Int(lower), (0...5).contains(rating), lower.count == 1 {
            return .rating(rating)
        }
        // 裸 6–9 = 红/黄/绿/蓝色标（与查看器同一口径；色标不自动前进）。
        // 不能取 colorLabels 前缀：那套 ⌥ 列表 7/8/9 是橙/黄/绿。
        if let digit = Int(lower), (6...9).contains(digit), lower.count == 1 {
            switch digit {
            case 6: return .color(.red)
            case 7: return .color(.yellow)
            case 8: return .color(.green)
            default: return .color(.blue)
            }
        }
        switch lower {
        case "p": return .pick(.picked)
        case "x": return .pick(.rejected)
        case "u": return .pick(.unreviewed)
        case " ": return .keep
        default: return nil
        }
    }

    static let colorLabels: [CaptureOneColorLabel] = [
        .red, .orange, .yellow, .green, .blue, .pink, .purple,
    ]
}

// MARK: - 行布局缓存

/// 网格的一行（justified layout 结果）。
struct CullingGridRow: Identifiable {
    let offset: Int
    let height: Double
    let items: [JustifiedLayoutItem]
    var id: Int { offset }
}

/// 只依赖（资产数、容器宽度、目标行高）的布局缓存：
/// body 每帧对全部已加载资产重跑 justified layout 在已加载上千张时是 O(n) 热点。
@MainActor
final class CullingGridLayoutCache {
    private var key = ""
    private var cached: [CullingGridRow] = []

    func rows(
        assets: [CullingAsset],
        version: Int,
        containerWidth: Double,
        targetRowHeight: Double,
        gap: Double
    ) -> [CullingGridRow] {
        // 键含 pageVersion：排序/筛选后“数量相同但内容不同”时必须重算，
        // 否则行宽会套在上一次的结果上。选择变化不改变 pageVersion，仍命中缓存。
        let newKey = "\(version)|\(assets.count)|\(Int(containerWidth))|\(Int(targetRowHeight))"
        if newKey == key { return cached }
        let source = assets.map {
            GalleryAspectItem(
                width: Double(max(1, $0.photo.width)),
                height: Double(max(1, $0.photo.height))
            )
        }
        cached = layoutJustifiedRows(
            source: source,
            containerWidth: containerWidth,
            targetRowHeight: targetRowHeight,
            gap: gap
        ).enumerated().map {
            CullingGridRow(offset: $0.offset, height: $0.element.height, items: $0.element.items)
        }
        key = newKey
        return cached
    }
}

// MARK: - 网格

struct CullingGridView: View {
    let viewModel: CullingViewModel
    let density: CullingGridDensity
    let onOpenSingle: () -> Void

    @Environment(\.languageStore) private var languageStore
    @FocusState private var isFocused: Bool
    @State private var layoutCache = CullingGridLayoutCache()

    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    private var assets: [CullingAsset] { viewModel.page?.assets ?? [] }
    /// Wave5 batch4：折叠计数（photoId → 所属导航组组员数），每次渲染算一次。
    private var groupSizes: [String: Int] { viewModel.navigationGroupSizeByPhotoID }

    var body: some View {
        VStack(spacing: .zero) {
            header
            Divider()
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                            ForEach(rows(containerWidth: max(1, geometry.size.width - 48)), id: \.offset) { row in
                                HStack(spacing: GatherMetrics.Space.s) {
                                    ForEach(row.items, id: \.index) { item in
                                        if assets.indices.contains(item.index) {
                                            let asset = assets[item.index]
                                            cell(
                                                asset,
                                                // 组视图内只标最佳；普通网格标「组 N 张」折叠计数。
                                                groupSize: viewModel.isNavigationGroupViewActive
                                                    ? nil : groupSizes[asset.photo.id],
                                                isGroupBest: viewModel.isNavigationGroupViewActive
                                                    && viewModel.navigationGroupViewLeadPhotoId
                                                        == asset.photo.id)
                                                .frame(width: item.width, height: row.height)
                                                .id(asset.photo.id)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: row.height)
                            }
                            Color.clear
                                .frame(height: 1)
                                .onAppear { Task { await viewModel.loadMore() } }
                            if viewModel.loadMoreFailed, viewModel.hasMore {
                                Button(l10n("加载失败，重试")) {
                                    Task { await viewModel.loadMore() }
                                }
                                .gatherButton(.secondary, size: .small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, GatherMetrics.Space.s)
                            }
                        }
                        .padding(EdgeInsets(top: 0, leading: GatherMetrics.Space.xl, bottom: 0, trailing: GatherMetrics.Space.xl))
                        .padding(EdgeInsets(top: GatherMetrics.Space.m, leading: 0, bottom: GatherMetrics.Space.m, trailing: 0))
                    }
                    .onChange(of: viewModel.currentPhotoId) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    // Wave5 batch4：决策/外部刷新会把投影页换回服务端页；
                    // pageVersion 变化时做幂等重投影（matches 已投影则 no-op）。
                    .onChange(of: viewModel.pageVersion) { _, _ in
                        Task { await viewModel.reprojectIfNeeded() }
                    }
                    // B2 / 浏览连续性：进网格时先把视口定位到当前照片。旧实现只在
                    // onChange 里滚——从单图第 300 张切到网格，看到的是列表顶部。
                    // LazyVStack 首帧只实例化视口内的行，先让出一帧再滚，目标格的
                    // id 才进滚动坐标系。
                    .task {
                        await Task.yield()
                        guard let id = viewModel.currentPhotoId else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(GatherTheme.canvas)
        .focusable()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { isFocused = true }
    }

    private var header: some View {
        HStack(spacing: GatherMetrics.Space.m) {
            if let group = viewModel.navigationGroupViewGroup {
                Text(l10n.format(
                    "%@ · %lld 张（页内 %lld，最佳置顶）",
                    group.type == .burst ? l10n("连拍组") : l10n("场景组"),
                    Int64(group.photoIds.count),
                    Int64(assets.count)))
                    .gatherText(.secondaryStrong)
            } else {
                Text(l10n.format("%lld 张", viewModel.page?.total ?? assets.count))
                    .gatherText(.secondary)
            }
            if let person = viewModel.personFilter {
                Text(l10n.format("人物：%@（已加载 %lld 张内）", person, Int64(assets.count)))
                    .gatherText(.secondary)
            }
            if !viewModel.selectedPhotoIds.isEmpty {
                Text(l10n.format("已选 %lld 张", viewModel.selectedPhotoIds.count))
                    .gatherText(.secondaryStrong)
            }
            Spacer(minLength: 0)
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(l10n("全屏"))
            .accessibilityLabel(l10n("全屏"))
        }
        .padding(EdgeInsets(top: 0, leading: GatherMetrics.Space.xl, bottom: 0, trailing: GatherMetrics.Space.xl))
        .padding(EdgeInsets(top: GatherMetrics.Space.s, leading: 0, bottom: GatherMetrics.Space.s, trailing: 0))
    }

    private func cell(
        _ asset: CullingAsset,
        groupSize: Int? = nil,
        isGroupBest: Bool = false
    ) -> some View {
        CullingGridCell(
            asset: asset,
            isSelected: viewModel.selectedPhotoIds.contains(asset.photo.id),
            isCurrent: viewModel.currentPhotoId == asset.photo.id,
            thumbnailSize: density.thumbnailSize,
            l10n: l10n,
            groupSize: groupSize,
            isGroupBest: isGroupBest
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.gridClick(asset.photo.id, modifiers: NSEvent.modifierFlags)
            isFocused = true
        }
        .contextMenu {
            // P1：右键菜单必须先以该 cell 为目标，否则会作用到旧 current/selection。
            Button(l10n("在单图中打开")) {
                viewModel.gridClick(asset.photo.id, modifiers: [])
                onOpenSingle()
            }
            Divider()
            Button(l10n("保留")) {
                viewModel.gridClick(asset.photo.id, modifiers: [])
                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
            }
            Button(l10n("淘汰")) {
                viewModel.gridClick(asset.photo.id, modifiers: [])
                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected)) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: asset))
        .accessibilityAddTraits(viewModel.selectedPhotoIds.contains(asset.photo.id) ? [.isSelected] : [])
    }

    private func accessibilityLabel(for asset: CullingAsset) -> String {
        var parts = [asset.photo.filename]
        switch asset.state.pickState {
        case .picked: parts.append(l10n("保留"))
        case .rejected: parts.append(l10n("淘汰"))
        case .unreviewed: parts.append(l10n("未处理"))
        }
        if asset.state.rating > 0 {
            parts.append(l10n.format("%lld 星", Int(asset.state.rating)))
        }
        if let triage = asset.triage {
            parts.append(CullingDisplayFormat.triageVerdictTitle(triage.verdict, with: l10n))
        }
        return parts.joined(separator: "，")
    }

    // MARK: 布局

    private func rows(containerWidth: Double) -> [CullingGridRow] {
        layoutCache.rows(
            assets: assets,
            version: viewModel.pageVersion,
            containerWidth: containerWidth,
            targetRowHeight: density.rowHeight,
            gap: 8
        )
    }

    // MARK: 键盘

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Option 会改写 characters（⌥1 → ¡）；色标快捷键必须取物理键位。
        let characters = press.modifiers.contains(.option)
            ? String(press.key.character)
            : press.characters
        if let action = CullingGridKeyMapper.action(
            characters: characters,
            command: press.modifiers.contains(.command),
            option: press.modifiers.contains(.option)
        ) {
            perform(action)
            return .handled
        }
        switch press.key {
        case .leftArrow, .upArrow:
            viewModel.retreatCurrent()
            return .handled
        case .rightArrow, .downArrow:
            viewModel.advanceCurrent()
            return .handled
        case .escape:
            // 先退出全屏；不在全屏时才清空选择。
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                viewModel.clearSelection()
            }
            return .handled
        case .return:
            onOpenSingle()
            return .handled
        default:
            return .ignored
        }
    }

    private func perform(_ action: CullingGridKeyAction) {
        switch action {
        case .rating(let value):
            Task { await viewModel.commit(patch: CullingUpdatePatch(rating: Double(value))) }
        case .pick(let state):
            Task {
                await viewModel.commit(
                    patch: CullingUpdatePatch(pickState: state),
                    shouldAdvance: state != .unreviewed
                )
            }
        case .color(let label):
            // 色标是"就地标注"：与查看器 6–9 一致，不触发自动前进。
            Task {
                await viewModel.commit(
                    patch: CullingUpdatePatch(colorLabel: label),
                    shouldAdvance: false)
            }
        case .keep:
            Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
        case .previous:
            viewModel.retreatCurrent()
        case .next:
            viewModel.advanceCurrent()
        case .selectAll:
            Task { await viewModel.selectAllInScope() }
        case .clearSelection:
            viewModel.clearSelection()
        case .openSingle:
            onOpenSingle()
        }
    }
}

// MARK: - 单元

private struct CullingGridCell: View {
    let asset: CullingAsset
    let isSelected: Bool
    let isCurrent: Bool
    let thumbnailSize: Int
    let l10n: L10n
    /// Wave5 batch4：所属导航组组员数（>1 才显示「组 N 张」折叠计数）。
    let groupSize: Int?
    /// Wave5 batch4：组视图下的最佳帧徽标。
    let isGroupBest: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            PhotoThumbnailView(path: asset.photo.filepath, size: thumbnailSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.72), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                HStack(spacing: GatherMetrics.Space.xs) {
                    decisionBadge
                    if isGroupBest {
                        chip(text: l10n("最佳"), systemImage: "crown.fill")
                    } else if let groupSize {
                        chip(
                            text: l10n.format("组 %lld 张", Int64(groupSize)),
                            systemImage: "rectangle.stack")
                    }
                    if asset.photo.status == "missing" {
                        chip(text: l10n("离线"), systemImage: "exclamationmark.triangle.fill")
                    }
                    Spacer(minLength: 0)
                    if let triage = asset.triage {
                        triageChip(triage)
                    }
                    if let quality = asset.quality, quality.status == .failed
                        || quality.warnings.contains("motion_blur")
                        || quality.warnings.contains("exposure_issue") {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(GatherMetrics.Space.xs)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .help(quality.warnings.joined(separator: ", "))
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: GatherMetrics.Space.xs) {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                        Text(asset.photo.filename)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: GatherMetrics.Space.xs) {
                            if asset.state.rating > 0 {
                                Text("\(Int(asset.state.rating))★")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if asset.state.colorLabel != .none {
                                Circle()
                                    .fill(color(asset.state.colorLabel))
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if !asset.faceBboxes.isEmpty {
                        Label("\(asset.faceBboxes.count)", systemImage: "person.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                            .labelStyle(.titleAndIcon)
                    }
                    if let variants = asset.photo.variantCount, variants > 1 {
                        Text("\(variants)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(GatherMetrics.Space.xs)
                            .background(Capsule().fill(.black.opacity(0.35)))
                            .help(l10n("变体"))
                    }
                }
            }
            .padding(GatherMetrics.Space.s)
        }
        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.media, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.media, style: .continuous)
                .strokeBorder(
                    isSelected ? GatherTheme.selection : (isCurrent ? GatherTheme.accent.opacity(0.7) : .clear),
                    lineWidth: isSelected ? 2 : 1.5
                )
        )
    }

    private var decisionBadge: some View {
        Group {
            switch asset.state.pickState {
            case .picked:
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .padding(GatherMetrics.Space.xs)
                    .background(Circle().fill(GatherTheme.success.opacity(0.9)))
            case .rejected:
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
                    .padding(GatherMetrics.Space.xs)
                    .background(Circle().fill(GatherTheme.error.opacity(0.9)))
            case .unreviewed:
                EmptyView()
            }
        }
        .font(.caption2.weight(.bold))
    }

    private func triageChip(_ triage: TriageSuggestion) -> some View {
        Text(CullingDisplayFormat.triageVerdictTitle(triage.verdict, with: l10n))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(GatherMetrics.Space.xs)
            .background(Capsule().fill(CullingDisplayFormat.triageColor(triage.verdict).opacity(0.9)))
            .help(
                triage.reasons.prefix(2)
                    .map { CullingDisplayFormat.triageReasonTitle($0.code, with: l10n) }
                    .joined(separator: "\n")
            )
    }

    private func chip(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(GatherMetrics.Space.xs)
            .background(Capsule().fill(.black.opacity(0.45)))
    }

    private func color(_ label: CaptureOneColorLabel) -> Color {
        CullingDisplayFormat.dot(label)
    }
}
