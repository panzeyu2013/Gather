// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryGrid.swift
// Cut 4 / 4c-2c：justified 网格、行预取 .onAppear（哨兵行 + 近末行）与单元按钮，
// 原 GalleryView.swift 35-48、494-497、705-820、940-947 行逐字搬移。
// 行内 .onAppear 的位置（哨兵 Color.clear / rowView 末尾）与判定式不变。
import SwiftUI
import AppKit
import GatherProtocol

/// 网格行布局缓存（引用语义盒子）。
///
/// justified 布局在 body 求值期间计算；把结果写回 @State 会触发 SwiftUI 的
/// 「Modifying state during view update」。写入引用盒子不经过 SwiftUI 状态机，
/// 缓存语义（key 命中即复用）与旧实现完全一致。
final class GalleryLayoutCache {
    var key = ""
    var rows: [JustifiedLayoutRow] = []

    func reset() {
        key = ""
        rows = []
    }
}

extension GalleryView {
    /// 右键「在 Finder 中显示」的 URL：路径为空/不可用时返回 nil（跳过该项）。
    private static func finderURL(for photo: GalleryPhotoData) -> URL? {
        finderURLForPath(photo.filepath)
    }

    func gridView(_ filtered: [GalleryPhotoData]) -> some View {
        GeometryReader { geometry in
            // 行区域实际内容宽度 = 全宽 − LazyVStack 水平 padding 24×2。
            let rows = layoutRows(filtered: filtered, width: max(1, geometry.size.width - 48))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        rowView(row, filtered: filtered)
                            .frame(height: row.height)
                    }
                    // TS 哨兵：滚近末尾触发下一页（键集游标）。
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded() }
                        }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
    }

    /// TS: layoutJustifiedRows 的结果缓存（key 覆盖 filtered 身份 + 宽度 + 密度）。
    /// filtered 数据变化时由 .onChange(of: filteredPhotos) 整体失效；key 内
    /// 再叠首尾 id 折叠哈希，双保险防止同 count 复用错位行。
    private func layoutRows(filtered: [GalleryPhotoData], width: Double) -> [JustifiedLayoutRow] {
        // D-3：用数据代数替代每次 body 对全部 id 的 O(n) 哈希；**但必须带上
        // filtered 指纹**（第二轮验证）：仅用 代数|条数|宽|密度 时，「搜索词变化但
        // 命中数相同」会复用上一组照片的行高（照片集合正确、几何错位）。
        let key = "\(viewModel.layoutGeneration)|\(viewModel.filteredFingerprint)|\(filtered.count)|\(width)|\(density)"
        if layoutCache.key == key {
            return layoutCache.rows
        }
        let source = filtered.map { GalleryAspectItem(width: Double(max(1, $0.width)), height: Double(max(1, $0.height))) }
        let rawRows = layoutJustifiedRows(source: source, containerWidth: width, targetRowHeight: density, gap: 8)
        // 单张照片不再被 justified 铺满整行：大图网格里一张 16:10 照片会被拉到
        // 650pt 宽，像 Lightbox 卡片。单行单张统一压到 480×360 内，保持图库密度。
        let rows = rawRows.map { row -> JustifiedLayoutRow in
            guard row.items.count == 1,
                  let item = row.items.first,
                  let photo = filtered[safe: item.index] else { return row }
            let ratio = Double(max(1, photo.width)) / Double(max(1, photo.height))
            var itemWidth = min(Self.singleItemMaxWidth, Self.singleItemMaxHeight * ratio)
            var itemHeight = itemWidth / ratio
            if itemHeight > Self.singleItemMaxHeight {
                itemHeight = Self.singleItemMaxHeight
                itemWidth = itemHeight * ratio
            }
            return JustifiedLayoutRow(
                height: itemHeight,
                items: [JustifiedLayoutItem(index: item.index, width: itemWidth)],
                justified: false
            )
        }
        layoutCache.key = key
        layoutCache.rows = rows
        return rows
    }

    private static let singleItemMaxWidth = 480.0
    private static let singleItemMaxHeight = 360.0

    /// 距行末的预取窗口（项数）：旧版 IntersectionObserver rootMargin
    /// 1600px ≈ 数屏；LazyVStack 行进入视口即触发，此窗口约 1-2 屏。
    private static let prefetchRemaining = 20

    private func rowView(_ row: JustifiedLayoutRow, filtered: [GalleryPhotoData]) -> some View {
        HStack(spacing: 8) {
            ForEach(row.items, id: \.index) { item in
                // 越界保护：布局缓存/数据刷新后 index 可能指向旧数组。
                if let photo = filtered[safe: item.index] {
                    photoButton(photo, item: item, rowHeight: row.height)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // P11：滚近末尾（距末行 20 项内）即预取下一页（loadMoreIfNeeded 内部
        // hasNextPage/isFetchingNextPage 去重），快滚到底不白屏。
        .onAppear {
            let lastIndex = row.items.last?.index ?? 0
            if lastIndex >= max(0, filtered.count - Self.prefetchRemaining) {
                Task { await viewModel.loadMoreIfNeeded() }
            }
        }
    }

    private func photoButton(_ photo: GalleryPhotoData, item: JustifiedLayoutItem, rowHeight: Double) -> some View {
        Button {
            // TS：Ctrl/⌘ 多选；普通点击打开 Lightbox。
            if NSEvent.modifierFlags.contains(.control) || NSEvent.modifierFlags.contains(.command) {
                viewModel.toggleSelection(photo.id)
            } else {
                lightboxIndex = item.index
            }
        } label: {
            GalleryCellView(
                photo: photo,
                isSelected: viewModel.selectedIds.contains(photo.id),
                thumbnailSize: viewModel.thumbnailSize
            )
            .frame(width: item.width, height: rowHeight)
        }
        .buttonStyle(.plain)
        // HIG：上下文菜单描述指针下的对象（旧版在选中集非空时变成空菜单）。
        .contextMenu {
            if let url = GalleryView.finderURL(for: photo) {
                Button(l10n("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button(viewModel.selectedIds.contains(photo.id) ? l10n("取消选择") : l10n("选择")) {
                viewModel.toggleSelection(photo.id)
            }
            if !viewModel.selectedIds.isEmpty {
                Button(l10n("取消选择")) {
                    viewModel.clearSelection()
                }
            }
        }
        .help(photo.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(photo.filename)
        .accessibilityValue(cellAccessibilityValue(photo))
        .accessibilityAddTraits(viewModel.selectedIds.contains(photo.id) ? [.isSelected] : [])
    }

    private func cellAccessibilityValue(_ photo: GalleryPhotoData) -> String {
        var parts = ["\(photo.width) × \(photo.height)"]
        if photo.faceCount > 0 {
            parts.append("\(l10n("人脸")) \(photo.faceCount)")
        }
        if photo.status == "missing" {
            parts.append(l10n("离线"))
        }
        return parts.joined(separator: "，")
    }
}

/// 越界安全的数组取值（网格行/预览共用）。
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
