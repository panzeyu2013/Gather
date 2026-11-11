// desktop/native/gather-core/Sources/GatherApplication/Services/Export/PrintLayout.swift
// Wave3 / task-20：打印版面**纯计算**层（单图适配 + 多页排版）。
//
// 设计取舍（与 ContactSheetRenderer 同口径）：
// - 这里只有几何与分页，不碰文件、不解码、不画 PDF —— 渲染层
//   （PrintDocumentRenderer）只消费本文件的输出，版面规则可单测；
// - 点 = 1/72 英寸：纸张预设与照片尺寸都按点给，渲染层不再做单位换算；
// - 与联系表共享分页语义（复用 ContactSheetLayout.paginate），避免两套
//   "第 N 页从哪张开始"的算法漂移。
//
// 本文件不依赖 GatherProtocol（只吃路径/尺寸/文本），App 层经
// PrintRenderingPort 把 UI 选项映射成这里的类型。
import Foundation
import CoreGraphics

// MARK: - 纸张与边距

/// 打印纸张预设。`pointSize` 为 nil 的只有 `.custom`（用调用方给的自定义尺寸）。
public enum PrintPaperPreset: String, CaseIterable, Sendable, Equatable {
    case a4
    case a5
    case letter
    case photo4x6
    case photo5x7
    case photo8x10
    case custom

    /// 点尺寸（1 点 = 1/72 英寸）。照片尺寸按英寸直接换算。
    public var pointSize: CGSize? {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .a5: return CGSize(width: 420, height: 595)
        case .letter: return CGSize(width: 612, height: 792)
        case .photo4x6: return CGSize(width: 4 * 72, height: 6 * 72)
        case .photo5x7: return CGSize(width: 5 * 72, height: 7 * 72)
        case .photo8x10: return CGSize(width: 8 * 72, height: 10 * 72)
        case .custom: return nil
        }
    }

    /// 实际页面尺寸：预设优先；自定义尺寸夹到"可打印"下限（≥1 英寸），
    /// 防止 0 宽/负宽导致 PDF mediaBox 非法。
    public func resolvedPageSize(custom: CGSize) -> CGSize {
        let raw = pointSize ?? custom
        return CGSize(
            width: max(72, raw.width.isFinite ? raw.width : 72),
            height: max(72, raw.height.isFinite ? raw.height : 72)
        )
    }
}

/// 页边距（点）。「离白」= 四边留白；负数按 0 处理。
public struct PrintMargins: Equatable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(
        top: CGFloat = 28,
        bottom: CGFloat = 28,
        leading: CGFloat = 28,
        trailing: CGFloat = 28
    ) {
        self.top = Self.clampMargin(top)
        self.bottom = Self.clampMargin(bottom)
        self.leading = Self.clampMargin(leading)
        self.trailing = Self.clampMargin(trailing)
    }

    public static let standard = PrintMargins()
    public static let none = PrintMargins(top: 0, bottom: 0, leading: 0, trailing: 0)

    public var horizontal: CGFloat { leading + trailing }
    public var vertical: CGFloat { top + bottom }

    private static func clampMargin(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

// MARK: - 单图打印

/// 单图摆放方式：适配页内可用区 / 自定义图像框尺寸。
public enum PrintSingleSizing: String, CaseIterable, Sendable, Equatable {
    case fitToPage
    case custom
}

/// 单图打印选项。
public struct SingleImagePrintOptions: Equatable, Sendable {
    public var paper: PrintPaperPreset
    /// `paper == .custom` 时的页面尺寸（点）。
    public var customPageSize: CGSize
    public var margins: PrintMargins
    public var sizing: PrintSingleSizing
    /// `sizing == .custom` 时的图像框尺寸（点）。
    public var customImageSize: CGSize
    /// 边框线宽（点）；0 = 无边框。边框画在图像框外沿。
    public var borderWidth: CGFloat

    public init(
        paper: PrintPaperPreset = .a4,
        customPageSize: CGSize = CGSize(width: 595, height: 842),
        margins: PrintMargins = .standard,
        sizing: PrintSingleSizing = .fitToPage,
        customImageSize: CGSize = CGSize(width: 288, height: 432),
        borderWidth: CGFloat = 0
    ) {
        self.paper = paper
        self.customPageSize = customPageSize
        self.margins = margins
        self.sizing = sizing
        self.customImageSize = customImageSize
        self.borderWidth = max(0, borderWidth.isFinite ? borderWidth : 0)
    }

    public var pageSize: CGSize {
        paper.resolvedPageSize(custom: customPageSize)
    }
}

/// 单图版面结果（渲染层只按这些矩形画）。
public struct SingleImagePrintLayout: Equatable, Sendable {
    public let pageSize: CGSize
    /// 页内可用区（页面去掉四边「离白」）。
    public let contentRect: CGRect
    /// 实际图像框（fit：按原图宽高比居中缩放；custom：自定义尺寸居中并夹进页内）。
    public let imageRect: CGRect
    /// 边框外框（borderWidth > 0 时 = imageRect 外扩 borderWidth；否则 nil）。
    public let borderRect: CGRect?

    public init(
        pageSize: CGSize,
        contentRect: CGRect,
        imageRect: CGRect,
        borderRect: CGRect?
    ) {
        self.pageSize = pageSize
        self.contentRect = contentRect
        self.imageRect = imageRect
        self.borderRect = borderRect
    }
}

public enum SingleImagePrintLayoutEngine {
    /// 纯几何：按选项把图像放进页面。
    ///
    /// - 非法源尺寸（0/NaN）时退化为"铺满可用区"，不返回 0 宽图像框
    ///   （宁可画大也不要产出一张空白 PDF）；
    /// - custom 尺寸夹进页内（允许覆盖离白区域，但不越出纸张）。
    public static func layout(
        imageSize: CGSize,
        options: SingleImagePrintOptions
    ) -> SingleImagePrintLayout {
        let pageSize = options.pageSize
        let content = contentRect(pageSize: pageSize, margins: options.margins)
        let imageRect: CGRect
        switch options.sizing {
        case .fitToPage:
            imageRect = aspectFit(source: imageSize, in: content)
        case .custom:
            let width = min(max(1, options.customImageSize.width), pageSize.width)
            let height = min(max(1, options.customImageSize.height), pageSize.height)
            imageRect = CGRect(
                x: (pageSize.width - width) / 2,
                y: (pageSize.height - height) / 2,
                width: width,
                height: height
            )
        }
        let border = options.borderWidth > 0
            ? imageRect.insetBy(dx: -options.borderWidth, dy: -options.borderWidth)
            : nil
        return SingleImagePrintLayout(
            pageSize: pageSize,
            contentRect: content,
            imageRect: imageRect,
            borderRect: border
        )
    }

    /// 页内可用区（页面去掉四边离白）；尺寸夹到 ≥1pt。
    public static func contentRect(pageSize: CGSize, margins: PrintMargins) -> CGRect {
        let width = max(1, pageSize.width - margins.horizontal)
        let height = max(1, pageSize.height - margins.vertical)
        return CGRect(x: margins.leading, y: margins.bottom, width: width, height: height)
    }

    /// 按源宽高比在容器内居中缩放（fit-inside）。
    static func aspectFit(source: CGSize, in container: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0,
              source.width.isFinite, source.height.isFinite,
              container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / source.width, container.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        )
    }
}

// MARK: - 多页排版

/// 多页打印选项：每页 N = columns × rows 张，页眉/页脚/页码。
public struct MultiPagePrintOptions: Equatable, Sendable {
    public var paper: PrintPaperPreset
    /// `paper == .custom` 时的页面尺寸（点）。
    public var customPageSize: CGSize
    public var margins: PrintMargins
    public var columns: Int
    public var rows: Int
    /// 格子间距（点）。
    public var cellSpacing: CGFloat
    /// 每张图下方 caption 区高度（点）；0 = 不画 caption。
    public var captionHeight: CGFloat
    public var headerHeight: CGFloat
    public var footerHeight: CGFloat
    public var headerText: String
    public var footerText: String
    public var showsPageNumbers: Bool

    public init(
        paper: PrintPaperPreset = .a4,
        customPageSize: CGSize = CGSize(width: 595, height: 842),
        margins: PrintMargins = .standard,
        columns: Int = 3,
        rows: Int = 3,
        cellSpacing: CGFloat = 8,
        captionHeight: CGFloat = 16,
        headerHeight: CGFloat = 32,
        footerHeight: CGFloat = 20,
        headerText: String = "",
        footerText: String = "",
        showsPageNumbers: Bool = true
    ) {
        self.paper = paper
        self.customPageSize = customPageSize
        self.margins = margins
        self.columns = min(12, max(1, columns))
        self.rows = min(20, max(1, rows))
        self.cellSpacing = max(0, cellSpacing.isFinite ? cellSpacing : 0)
        self.captionHeight = max(0, captionHeight.isFinite ? captionHeight : 0)
        self.headerHeight = max(0, headerHeight.isFinite ? headerHeight : 0)
        self.footerHeight = max(0, footerHeight.isFinite ? footerHeight : 0)
        self.headerText = headerText
        self.footerText = footerText
        self.showsPageNumbers = showsPageNumbers
    }

    public var pageSize: CGSize { paper.resolvedPageSize(custom: customPageSize) }
    public var perPage: Int { columns * rows }
}

/// 一张图的落位（全局序号 + 三个矩形）。
public struct PrintCellLayout: Equatable, Sendable {
    /// 全局照片序号（0 起）。
    public let itemIndex: Int
    /// 整格（含 caption 区）。
    public let cellRect: CGRect
    /// 图像区（格子去掉底部 caption 区）。
    public let imageRect: CGRect
    /// caption 区（格子底部）。
    public let captionRect: CGRect

    public init(itemIndex: Int, cellRect: CGRect, imageRect: CGRect, captionRect: CGRect) {
        self.itemIndex = itemIndex
        self.cellRect = cellRect
        self.imageRect = imageRect
        self.captionRect = captionRect
    }
}

/// 一页的落位。
public struct PrintPageLayout: Equatable, Sendable {
    /// 0 基页号。
    public let pageIndex: Int
    /// 本页覆盖的全局照片区间。
    public let itemRange: Range<Int>
    public let headerRect: CGRect?
    public let footerRect: CGRect?
    /// 页码区（页脚右侧）；不显示页码/无页脚时为 nil。
    public let pageNumberRect: CGRect?
    public let cells: [PrintCellLayout]

    public init(
        pageIndex: Int,
        itemRange: Range<Int>,
        headerRect: CGRect?,
        footerRect: CGRect?,
        pageNumberRect: CGRect?,
        cells: [PrintCellLayout]
    ) {
        self.pageIndex = pageIndex
        self.itemRange = itemRange
        self.headerRect = headerRect
        self.footerRect = footerRect
        self.pageNumberRect = pageNumberRect
        self.cells = cells
    }
}

public enum MultiPagePrintLayoutEngine {
    /// 每页格数（≥1；与 ContactSheetLayout 同语义）。
    public static func perPage(options: MultiPagePrintOptions) -> Int {
        max(1, options.perPage)
    }

    /// 页数（空输入 = 0 页）。
    public static func pageCount(itemCount: Int, options: MultiPagePrintOptions) -> Int {
        paginate(itemCount: itemCount, perPage: perPage(options: options)).count
    }

    /// 分页区间（复用联系表的分页实现，避免两套"页边界"算法漂移）。
    public static func paginate(itemCount: Int, perPage: Int) -> [Range<Int>] {
        ContactSheetLayout.paginate(count: itemCount, perPage: perPage)
    }

    /// 整页版面：每页的 header/footer/页码区 + 每格 cell/image/caption 矩形。
    public static func pages(
        itemCount: Int,
        options: MultiPagePrintOptions
    ) -> [PrintPageLayout] {
        let perPage = perPage(options: options)
        let ranges = paginate(itemCount: itemCount, perPage: perPage)
        guard !ranges.isEmpty else { return [] }
        let pageSize = options.pageSize
        let content = SingleImagePrintLayoutEngine.contentRect(
            pageSize: pageSize, margins: options.margins)
        let headerRect = options.headerHeight > 0
            ? CGRect(
                x: content.minX,
                y: content.maxY - options.headerHeight,
                width: content.width,
                height: options.headerHeight)
            : nil
        let footerRect = options.footerHeight > 0
            ? CGRect(
                x: content.minX,
                y: content.minY,
                width: content.width,
                height: options.footerHeight)
            : nil
        let pageNumberRect = (options.showsPageNumbers && options.footerHeight > 0)
            ? CGRect(
                x: content.maxX - min(120, content.width / 2),
                y: content.minY,
                width: min(120, content.width / 2),
                height: options.footerHeight)
            : nil
        // 网格区 = 可用区去掉页眉/页脚（高度夹到 ≥1）。
        let gridTop = content.maxY - options.headerHeight
        let gridBottom = content.minY + options.footerHeight
        let gridRect = CGRect(
            x: content.minX,
            y: gridBottom,
            width: content.width,
            height: max(1, gridTop - gridBottom)
        )
        let spacingCountX = CGFloat(options.columns - 1)
        let spacingCountY = CGFloat(options.rows - 1)
        let cellWidth = max(
            1, (gridRect.width - options.cellSpacing * spacingCountX) / CGFloat(options.columns))
        let cellHeight = max(
            1, (gridRect.height - options.cellSpacing * spacingCountY) / CGFloat(options.rows))
        let captionHeight = min(options.captionHeight, max(0, cellHeight - 1))

        return ranges.enumerated().map { pageIndex, range in
            let cells: [PrintCellLayout] = range.enumerated().map { offset, itemIndex in
                let column = offset % options.columns
                let row = offset / options.columns
                let originX = gridRect.minX + CGFloat(column) * (cellWidth + options.cellSpacing)
                let topY = gridRect.maxY - CGFloat(row) * (cellHeight + options.cellSpacing)
                let cellRect = CGRect(
                    x: originX, y: topY - cellHeight, width: cellWidth, height: cellHeight)
                let captionRect = CGRect(
                    x: cellRect.minX, y: cellRect.minY, width: cellRect.width, height: captionHeight)
                let imageRect = CGRect(
                    x: cellRect.minX,
                    y: cellRect.minY + captionHeight,
                    width: cellRect.width,
                    height: max(1, cellRect.height - captionHeight))
                return PrintCellLayout(
                    itemIndex: itemIndex,
                    cellRect: cellRect,
                    imageRect: imageRect,
                    captionRect: captionRect)
            }
            return PrintPageLayout(
                pageIndex: pageIndex,
                itemRange: range,
                headerRect: headerRect,
                footerRect: footerRect,
                pageNumberRect: pageNumberRect,
                cells: cells)
        }
    }
}
