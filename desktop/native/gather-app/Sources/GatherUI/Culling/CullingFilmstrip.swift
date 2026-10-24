// desktop/native/gather-app/Sources/GatherUI/Culling/CullingFilmstrip.swift
// Cut 4 / 4c-2a：底部胶片条 + 缩略图（原 CullingView.swift 2505-2574、2942-3068 行）。
// 约束不变：这一层只允许一个（横向）ScrollView；缩略图 onAppear 续页语义逐字保留。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: 胶片条（底部全宽横向条：100pt 缩略图 + 色标线 + 星级 + 决策圆点 + 文件名）。
// 约束：这一层只允许存在一个 ScrollView（横向滚动）。再套一层竖向 ScrollView
// 会在 AppKit 约束更新阶段抛异常（与 Form(.grouped) 进 .inspector 的崩溃同源），
// 所以缩略图必须留在同一条横向 LazyHStack 里。
struct CullingFilmstrip: View {
    let viewModel: CullingViewModel
    @Binding var isExpanded: Bool

    @Environment(\.languageStore) private var languageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                filmstrip
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isExpanded
               ? GatherMetrics.Chrome.filmstripExpanded
               : GatherMetrics.Chrome.filmstripCollapsed)
        .background(GatherTheme.surface)
        // 与上方 infoBar 的分隔线。
        .overlay(alignment: .top) { Divider() }
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(l10n("胶片"))
                .font(GatherFont.bodyStrong)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let page = viewModel.page {
                Text("\(page.assets.count)\(page.total > page.assets.count ? " / \(page.total)" : "")")
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(l10n.format("已载入 %lld 张，共 %lld 张", page.assets.count, page.total))
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: GatherMetrics.Motion.standard)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(isExpanded ? l10n("收起胶片条") : l10n("展开胶片条"))
            .accessibilityLabel(isExpanded ? l10n("收起胶片条") : l10n("展开胶片条"))
        }
        .padding(.horizontal, 12)
        .frame(height: GatherMetrics.Chrome.filmstripCollapsed)
        .background(GatherTheme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: GatherMetrics.Space.s) {
                    ForEach(Array((viewModel.page?.assets ?? []).enumerated()), id: \.element.photo.id) { index, asset in
                        CullingFilmThumbView(viewModel: viewModel, asset: asset)
                            .id(asset.photo.id)
                            // 横向滚动近尾自动续页：尾部 4 个缩略图出现即 loadMore。
                            .onAppear {
                                let count = viewModel.page?.assets.count ?? 0
                                if index >= count - 4, viewModel.page?.nextRowId != nil {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                    }
                    if viewModel.page?.nextRowId != nil {
                        Button(viewModel.isLoading ? l10n("加载中…") : l10n("加载更多")) {
                            Task { await viewModel.loadMore() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isLoading)
                        // 与缩略图等高的一格按钮，保持行尾出口。
                        .frame(width: 112, height: 100)
                    }
                }
                .padding(.horizontal, GatherMetrics.Space.s)
                .padding(.bottom, GatherMetrics.Space.s)
            }
            // 当前照片自动滚动；Reduce Motion 时不做动画。
            .onChange(of: viewModel.currentPhotoId) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: GatherMetrics.Motion.standard)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

/// 胶片缩略图：100pt 图 + 4pt 色标线 + 左上星级 + 右上决策圆点 + 底部文件名。
/// 点击选择当前照片；⌘/Ctrl/Shift 点击切换多选（对齐旧版 Culling.tsx:1509-1530）。
private struct CullingFilmThumbView: View {
    let viewModel: CullingViewModel
    let asset: CullingAsset

    /// Cut 4 / 4b-2a：上下文菜单/无障碍标签与页面同源（渲染期解析）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var isCurrent: Bool {
        viewModel.currentPhotoId == asset.photo.id
    }

    private var isSelected: Bool {
        viewModel.selectedPhotoIds.contains(asset.photo.id)
    }

    private var borderColor: Color {
        // 当前 = 品牌 accent；多选 = accent 半透明（不使用 warning 语义色）。
        if isCurrent { return GatherTheme.accent }
        if isSelected { return GatherTheme.accent.opacity(0.55) }
        return .clear
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.intersection([.command, .control, .shift]) != [] {
                viewModel.toggleSelection(asset.photo.id)
            } else {
                viewModel.selectCurrent(asset.photo.id)
            }
        } label: {
            ZStack(alignment: .bottom) {
                PhotoThumbnailView(
                    path: asset.photo.filepath,
                    size: 256,
                    placeholderSize: CGSize(width: 140, height: 100)
                )
                .frame(width: 140, height: 100)
                .clipped()
                if asset.state.colorLabel != .none {
                    Rectangle()
                        .fill(CullingDisplayFormat.dot(asset.state.colorLabel))
                        .frame(height: 4)
                }
                if asset.state.rating > 0 {
                    // 星级是内容语义（.callout），压在照片上时给深色底保证对比度。
                    Text("\(Int(asset.state.rating))★")
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.viewerTextPrimary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.8)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(4)
                }
                if asset.state.pickState != .unreviewed {
                    Circle()
                        .fill(asset.state.pickState == .picked ? GatherTheme.success : GatherTheme.error)
                        .frame(width: 9, height: 9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                        .accessibilityHidden(true)
                }
                Text(asset.photo.filename)
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.viewerTextPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(GatherTheme.viewerBackground.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(l10n("保留")) {
                Task {
                    await viewModel.update(
                        asset,
                        patch: CullingUpdatePatch(pickState: .picked),
                        nextPhotoId: viewModel.autoAdvance ? viewModel.nextPhotoId(after: asset.photo.id) : nil
                    )
                }
            }
            Button(l10n("淘汰")) {
                Task {
                    await viewModel.update(
                        asset,
                        patch: CullingUpdatePatch(pickState: .rejected),
                        nextPhotoId: viewModel.autoAdvance ? viewModel.nextPhotoId(after: asset.photo.id) : nil
                    )
                }
            }
            Button(l10n("未处理")) {
                Task { await viewModel.update(asset, patch: CullingUpdatePatch(pickState: .unreviewed)) }
            }
            if let url = finderURLForPath(asset.photo.filepath) {
                Divider()
                Button(l10n("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCurrent ? 2.5 : 2)
        )
        .help(asset.photo.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thumbAccessibilityLabel)
        .accessibilityValue(isSelected ? l10n("已选中") : l10n("未选中"))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// 三段式无障碍描述：三段都在渲染期解析（不缓存、不跨语言复用）。
    private var thumbAccessibilityLabel: String {
        let ratingText = asset.state.rating > 0
            ? l10n.format("%lld 星", Int(asset.state.rating))
            : l10n("未评级")
        let stateText = pickStateTitle(asset.state.pickState, with: l10n)
        return "\(asset.photo.filename)，\(ratingText)，\(stateText)"
    }
}
