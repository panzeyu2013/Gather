// desktop/native/gather-app/Sources/GatherUI/Gallery/JustifiedLayout.swift
// TS 源: desktop/src/renderer/pages/SessionDetail/justified-layout.ts（逐行移植）。
// Flickr/Google Photos 式排版：同一行照片等高，宽度按原始宽高比分配；
// 已凑满的行铺满容器，最后一行左对齐停留在目标高度。
import Foundation

/// TS: GalleryAspectItem（原始尺寸输入）。
public struct GalleryAspectItem: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// TS: JustifiedLayoutItem（行内单元格）。
public struct JustifiedLayoutItem: Equatable, Sendable {
    public let index: Int
    public let width: Double

    public init(index: Int, width: Double) {
        self.index = index
        self.width = width
    }
}

/// TS: JustifiedLayoutRow。
public struct JustifiedLayoutRow: Equatable, Sendable {
    public let height: Double
    public let items: [JustifiedLayoutItem]
    public let justified: Bool

    public init(height: Double, items: [JustifiedLayoutItem], justified: Bool) {
        self.height = height
        self.items = items
        self.justified = justified
    }
}

/// TS: PendingItem。
private struct PendingItem: Equatable {
    let index: Int
    let aspectRatio: Double
}

/// TS: safeAspectRatio —— 非法尺寸（≤0 / 非有限 / 非正）回退 1。
public func safeAspectRatio(_ item: GalleryAspectItem) -> Double {
    if item.width <= 0 || item.height <= 0 { return 1 }
    let ratio = item.width / item.height
    return ratio.isFinite && ratio > 0 ? ratio : 1
}

/// TS: rowHeight —— 扣掉行内间隙后按宽高比和分摊容器宽度。
private func rowHeight(
    items: [PendingItem],
    containerWidth: Double,
    gap: Double
) -> Double {
    let availableWidth = containerWidth - gap * Double(max(0, items.count - 1))
    let aspectRatioSum = items.reduce(0) { $0 + $1.aspectRatio }
    return availableWidth / aspectRatioSum
}

/// TS: makeRow。
private func makeRow(
    items: [PendingItem],
    height: Double,
    justified: Bool
) -> JustifiedLayoutRow {
    JustifiedLayoutRow(
        height: height,
        items: items.map { JustifiedLayoutItem(index: $0.index, width: $0.aspectRatio * height) },
        justified: justified
    )
}

/// TS: layoutJustifiedRows —— 流式攒行：候选行投影宽度 ≥ 容器宽度时结算。
/// 单元素超宽行直接整行结算；多元素时比较「去尾」与「含尾」两种高度与目标
/// 高度的偏差，取更接近者（保证下一行起点尽量贴近目标行高）。
public func layoutJustifiedRows(
    source: [GalleryAspectItem],
    containerWidth: Double,
    targetRowHeight: Double,
    gap: Double = 8
) -> [JustifiedLayoutRow] {
    if source.isEmpty || containerWidth <= 0 || targetRowHeight <= 0 {
        return []
    }

    var rows: [JustifiedLayoutRow] = []
    var pending: [PendingItem] = []

    func finalize(_ items: [PendingItem]) {
        guard !items.isEmpty else { return }
        rows.append(makeRow(items: items, height: rowHeight(items: items, containerWidth: containerWidth, gap: gap), justified: true))
    }

    for (index, item) in source.enumerated() {
        pending.append(PendingItem(index: index, aspectRatio: safeAspectRatio(item)))

        let projectedWidth = pending.reduce(0) { sum, pendingItem in
            sum + pendingItem.aspectRatio * targetRowHeight
        } + gap * Double(max(0, pending.count - 1))
        if projectedWidth < containerWidth { continue }

        if pending.count == 1 {
            finalize(pending)
            pending = []
            continue
        }

        let withoutLast = Array(pending.dropLast())
        let heightWithLast = rowHeight(items: pending, containerWidth: containerWidth, gap: gap)
        let heightWithoutLast = rowHeight(items: withoutLast, containerWidth: containerWidth, gap: gap)

        if abs(heightWithoutLast - targetRowHeight) < abs(heightWithLast - targetRowHeight) {
            finalize(withoutLast)
            pending = [pending[pending.count - 1]]
        } else {
            finalize(pending)
            pending = []
        }
    }

    if !pending.isEmpty {
        let naturalHeight = rowHeight(items: pending, containerWidth: containerWidth, gap: gap)
        let finalHeight = min(targetRowHeight, naturalHeight)
        rows.append(makeRow(items: pending, height: finalHeight, justified: false))
    }

    return rows
}
