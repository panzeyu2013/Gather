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
    case compare4
    case grid

    var compareCount: Int {
        switch self {
        case .single, .grid: return 1
        case .compare2: return 2
        case .compare4: return 4
        }
    }

    var titleKey: String {
        switch self {
        case .single: return "单图"
        case .compare2: return "2 图"
        case .compare4: return "4 图"
        case .grid: return "网格"
        }
    }

    var systemImage: String {
        switch self {
        case .single: return "rectangle"
        case .compare2: return "rectangle.split.2x1"
        case .compare4: return "rectangle.split.2x2"
        case .grid: return "square.grid.3x3"
        }
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
                                            cell(assets[item.index])
                                                .frame(width: item.width, height: row.height)
                                                .id(assets[item.index].photo.id)
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
                                .buttonStyle(.bordered)
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
            Text(l10n.format("%lld 张", viewModel.page?.total ?? assets.count))
                .gatherText(.secondary)
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

    private func cell(_ asset: CullingAsset) -> some View {
        CullingGridCell(
            asset: asset,
            isSelected: viewModel.selectedPhotoIds.contains(asset.photo.id),
            isCurrent: viewModel.currentPhotoId == asset.photo.id,
            thumbnailSize: density.thumbnailSize,
            l10n: l10n
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
            Task { await viewModel.commit(patch: CullingUpdatePatch(colorLabel: label)) }
        case .keep:
            Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
        case .previous:
            viewModel.retreatCurrent()
        case .next:
            viewModel.advanceCurrent()
        case .selectAll:
            viewModel.selectAllLoaded()
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
        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
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
