// desktop/native/gather-core/Sources/GatherApplication/Services/Export/ContactSheetRenderer.swift
// 交付联系表：把一组照片按网格排成 PDF（每页 header/footer + 图 + 标题行）。
//
// 设计取舍：
// - 布局是纯函数（paginate），PDF 渲染只做绘制，二者分开测试；
// - 逐页取缩略图（内存上界 = 一页格子数），不预先解码整批；
// - 单张损坏只留空框 + 文件名，不中断整本。
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import GatherAnalysis
import GatherProtocol

/// 联系表单张。展示字段走共享模型 DeliveryPresentationItem（与画廊同一份），
/// 同时保留 path / caption 两个只读兼容入口 —— 既有调用点与测试一字不改。
public struct ContactSheetItem: Equatable, Sendable {
    public var presentation: DeliveryPresentationItem
    /// 第一行文字（已由 CaptionFormatter 渲染；旧调用点直接给文件名）。
    public var caption: String

    /// 成片路径（只读兼容属性）。
    public var path: String { presentation.filePath }

    /// 兼容旧调用点：只有路径 + caption，没有任何元数据（渲染与升级前一致）。
    public init(path: String, caption: String) {
        self.presentation = DeliveryPresentationItem(
            photoId: "", filePath: path, filename: (path as NSString).lastPathComponent)
        self.caption = caption
    }

    public init(presentation: DeliveryPresentationItem, caption: String? = nil) {
        self.presentation = presentation
        self.caption = caption ?? presentation.filename
    }
}

public struct ContactSheetOptions: Equatable, Sendable {
    public var pageSize: CGSize
    public var columns: Int
    public var rows: Int
    public var margin: CGFloat
    public var headerHeight: CGFloat
    public var footerHeight: CGFloat
    /// 一行文字的基准高度（默认 18 = 升级前的值）。多行由 fields 追加。
    public var captionHeight: CGFloat
    public var title: String
    public var subtitle: String
    public var footerText: String
    /// 要绘制的展示字段；默认 [.filename] = 与升级前完全一致的版式。
    public var fields: ContactSheetFields
    /// 色标圆点开关（还要 fields 含 .label）。
    public var showLabelChip: Bool
    /// 取舍边框开关（还要 fields 含 .pick）。
    public var showPickBorder: Bool

    public init(
        pageSize: CGSize = CGSize(width: 595, height: 842),  // A4 @ 72dpi
        columns: Int = 4,
        rows: Int = 5,
        margin: CGFloat = 36,
        headerHeight: CGFloat = 48,
        footerHeight: CGFloat = 24,
        captionHeight: CGFloat = 18,
        title: String = "",
        subtitle: String = "",
        footerText: String = "",
        fields: ContactSheetFields = .legacy,
        showLabelChip: Bool = true,
        showPickBorder: Bool = true
    ) {
        self.pageSize = pageSize
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.margin = margin
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.captionHeight = captionHeight
        self.title = title
        self.subtitle = subtitle
        self.footerText = footerText
        self.fields = fields
        self.showLabelChip = showLabelChip
        self.showPickBorder = showPickBorder
    }

    /// caption 区的行数：1（文字）+ 徽标行（星/色标/取舍）+ 关键词行。
    public var captionRows: Int {
        1 + (fields.needsBadgeRow ? 1 : 0) + (fields.needsKeywordRow ? 1 : 0)
    }

    /// 实际占位高度：默认字段 = 18（与升级前一致）；两行 30；三行 42。
    public var resolvedCaptionHeight: CGFloat {
        captionHeight + CGFloat(captionRows - 1) * 12
    }
}

public enum ContactSheetError: Error, Equatable, CustomStringConvertible {
    case cannotCreateContext
    case writeFailed(String)

    public var code: String {
        switch self {
        case .cannotCreateContext: "CONTACT_SHEET_CONTEXT_FAILED"
        case .writeFailed: "CONTACT_SHEET_WRITE_FAILED"
        }
    }

    public var description: String {
        switch self {
        case .cannotCreateContext: "CONTACT_SHEET_CONTEXT_FAILED"
        case .writeFailed(let reason): "CONTACT_SHEET_WRITE_FAILED: " + reason
        }
    }
}

public struct ContactSheetResult: Equatable, Sendable {
    public let pages: Int
    public let bytes: Int
    public let failedImages: Int

    public init(pages: Int, bytes: Int, failedImages: Int) {
        self.pages = pages
        self.bytes = bytes
        self.failedImages = failedImages
    }
}

public enum ContactSheetLayout {
    public static func perPage(columns: Int, rows: Int) -> Int {
        max(1, columns) * max(1, rows)
    }

    /// 纯分页：返回每页覆盖的区间（空输入返回空数组）。
    public static func paginate(count: Int, perPage: Int) -> [Range<Int>] {
        guard count > 0, perPage > 0 else { return [] }
        return stride(from: 0, to: count, by: perPage).map {
            $0..<min($0 + perPage, count)
        }
    }
}

public enum ContactSheetRenderer {
    public static func render(
        items: [ContactSheetItem],
        options: ContactSheetOptions,
        to url: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> ContactSheetResult {
        let perPage = ContactSheetLayout.perPage(columns: options.columns, rows: options.rows)
        let pages = ContactSheetLayout.paginate(count: items.count, perPage: perPage)
        var failed = 0
        var info = [String: Any]()
        info[kCGPDFContextTitle as String] = options.title
        info[kCGPDFContextCreator as String] = "Gather"
        // 先写临时文件，成功后原子替换：取消/崩溃不会在交付目录留下半截 PDF。
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).partial-\(UUID().uuidString.lowercased())")
        func discardTemp() {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                return
            }
        }
        guard let consumer = CGDataConsumer(url: tempURL as CFURL),
              var mediaBox = Optional(CGRect(origin: .zero, size: options.pageSize)),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else {
            discardTemp()
            throw ContactSheetError.cannotCreateContext
        }

        let cellWidth = (options.pageSize.width - options.margin * 2
            - CGFloat(options.columns - 1) * 8) / CGFloat(options.columns)
        let cellHeight = (options.pageSize.height - options.margin * 2
            - options.headerHeight - options.footerHeight
            - CGFloat(options.rows - 1) * 8) / CGFloat(options.rows)

        for (pageIndex, range) in pages.enumerated() {
            context.beginPDFPage(nil)
            drawHeader(
                context: context, options: options,
                pageIndex: pageIndex, pageCount: pages.count)
            for (offset, itemIndex) in range.enumerated() {
                if isCancelled() {
                    discardTemp()
                    throw CancellationError()
                }
                let column = offset % options.columns
                let row = offset / options.columns
                let originX = options.margin + CGFloat(column) * (cellWidth + 8)
                let topY = options.pageSize.height - options.margin - options.headerHeight
                    - CGFloat(row) * (cellHeight + 8)
                let cell = CGRect(x: originX, y: topY - cellHeight, width: cellWidth, height: cellHeight)
                // caption 区高度由 fields 决定：默认一路 18（升级前一致），
                // 有星条/关键词时变 30/42，避免文字压在图上。
                let captionSpace = options.resolvedCaptionHeight
                let imageRect = CGRect(
                    x: cell.minX, y: cell.minY + captionSpace,
                    width: cell.width, height: max(1, cell.height - captionSpace))
                if !drawThumbnail(items[itemIndex].path, in: imageRect, context: context) {
                    failed += 1
                    drawPlaceholder(imageRect, context: context)
                }
                drawCaption(
                    item: items[itemIndex], options: options,
                    cell: cell, imageRect: imageRect, context: context)
            }
            drawFooter(context: context, options: options, pageIndex: pageIndex, pageCount: pages.count)
            context.endPDFPage()
        }
        if pages.isEmpty {
            context.beginPDFPage(nil)
            drawHeader(context: context, options: options, pageIndex: 0, pageCount: 0)
            drawFooter(context: context, options: options, pageIndex: 0, pageCount: 0)
            context.endPDFPage()
        }
        context.closePDF()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            discardTemp()
            throw ContactSheetError.writeFailed(String(describing: error))
        }
        let bytes: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            bytes = 0
        }
        return ContactSheetResult(pages: max(1, pages.count), bytes: bytes, failedImages: failed)
    }

    // MARK: - 绘制

    private static func drawHeader(
        context: CGContext, options: ContactSheetOptions, pageIndex: Int, pageCount: Int
    ) {
        let baseline = options.pageSize.height - options.margin - 18
        drawText(
            options.title, in: context, at: CGPoint(x: options.margin, y: baseline),
            fontSize: 14, bold: true, color: CGColor(gray: 0.1, alpha: 1),
            maxWidth: options.pageSize.width - options.margin * 2)
        if !options.subtitle.isEmpty {
            drawText(
                options.subtitle, in: context,
                at: CGPoint(x: options.margin, y: baseline - 15),
                fontSize: 9, color: CGColor(gray: 0.35, alpha: 1),
                maxWidth: options.pageSize.width - options.margin * 2)
        }
        context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: options.margin, y: baseline - 22))
        context.addLine(to: CGPoint(x: options.pageSize.width - options.margin, y: baseline - 22))
        context.strokePath()
    }

    private static func drawFooter(
        context: CGContext, options: ContactSheetOptions, pageIndex: Int, pageCount: Int
    ) {
        let y = options.margin - 10
        if !options.footerText.isEmpty {
            drawText(
                options.footerText, in: context, at: CGPoint(x: options.margin, y: y),
                fontSize: 8, color: CGColor(gray: 0.45, alpha: 1),
                maxWidth: options.pageSize.width / 2)
        }
        let label = pageCount > 0 ? "\(pageIndex + 1) / \(pageCount)" : ""
        if !label.isEmpty {
            drawText(
                label, in: context,
                at: CGPoint(x: options.pageSize.width - options.margin - 40, y: y),
                fontSize: 8, color: CGColor(gray: 0.45, alpha: 1), maxWidth: 40)
        }
    }

    /// caption 区：第一行文字 + 可选徽标行（星/色标/取舍）+ 可选关键词行。
    ///
    /// 所有额外绘制都由 fields 开关：默认 fields=[.filename] 时本函数只画一行文字，
    /// PDF 内容流与升级前逐字节一致。
    private static func drawCaption(
        item: ContactSheetItem,
        options: ContactSheetOptions,
        cell: CGRect,
        imageRect: CGRect,
        context: CGContext
    ) {
        let presentation = item.presentation
        drawText(
            item.caption, in: context,
            at: CGPoint(x: cell.minX, y: cell.minY + 4),
            fontSize: 8, color: CGColor(gray: 0.25, alpha: 1),
            maxWidth: cell.width)

        let badgeBaseline = cell.minY + 16
        if options.fields.needsBadgeRow {
            var cursorX = cell.minX
            if options.fields.contains(.rating), presentation.rating > 0 {
                let stars = presentation.ratingStars
                drawText(
                    stars, in: context, at: CGPoint(x: cursorX, y: badgeBaseline),
                    fontSize: 9, color: CGColor(gray: 0.2, alpha: 1), maxWidth: cell.width)
                cursorX += approxWidth(stars, fontSize: 9) + 5
            }
            if options.showLabelChip, options.fields.contains(.label),
               let label = presentation.effectiveLabel,
               let rgb = ColorLabelPalette.rgb(for: label),
               cell.width > 60 {
                // 色点固定贴在右侧，避免依赖字体度量计算星条宽度。
                let dotSize: CGFloat = 8
                let dotRect = CGRect(
                    x: cell.maxX - dotSize, y: badgeBaseline + 1,
                    width: dotSize, height: dotSize)
                context.setFillColor(CGColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1))
                context.fillEllipse(in: dotRect)
                drawText(
                    label, in: context,
                    at: CGPoint(x: cell.maxX - dotSize - 4 - approxWidth(label, fontSize: 7),
                                y: badgeBaseline),
                    fontSize: 7, color: CGColor(gray: 0.35, alpha: 1),
                    maxWidth: max(1, cell.width / 2))
            }
            if options.fields.contains(.triage), let verdict = presentation.triageVerdict {
                let text = "AI " + verdict.rawValue
                drawText(
                    text, in: context,
                    at: CGPoint(x: cursorX + 6, y: badgeBaseline),
                    fontSize: 7, color: CGColor(gray: 0.5, alpha: 1),
                    maxWidth: max(1, cell.width - (cursorX - cell.minX) - 40))
            }
            if options.showPickBorder, options.fields.contains(.pick),
               presentation.pick != .unreviewed {
                let color: CGColor = presentation.pick == .picked
                    ? CGColor(red: 0.25, green: 0.65, blue: 0.30, alpha: 1)
                    : CGColor(red: 0.65, green: 0.35, blue: 0.35, alpha: 1)
                context.setStrokeColor(color)
                context.setLineWidth(1.5)
                context.stroke(imageRect)
            }
        }
        if options.fields.needsKeywordRow, !presentation.keywords.isEmpty {
            // 关键词行在徽标行上方；没有徽标行时紧贴文字行。
            let keywordBaseline = options.fields.needsBadgeRow
                ? cell.minY + 28 : cell.minY + 16
            drawText(
                presentation.keywords.joined(separator: ", "), in: context,
                at: CGPoint(x: cell.minX, y: keywordBaseline),
                fontSize: 7, color: CGColor(gray: 0.45, alpha: 1),
                maxWidth: cell.width)
        }
    }

    /// 粗略文字宽度（只用于排版定位与截断，与 truncate 同一经验系数）。
    static func approxWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        CGFloat(text.count) * fontSize * 0.55
    }

    private static func drawThumbnail(_ path: String, in rect: CGRect, context: CGContext) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let target = max(1, Int(max(rect.width, rect.height) * 2))  // 2x for print
        let decoded: RAWDecodeResult
        do {
            decoded = try RAWDecoder.getThumbnail(path: path, size: target)
        } catch {
            return false
        }
        guard let source = CGImageSourceCreateWithData(decoded.buffer as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
            width: drawSize.width, height: drawSize.height)
        context.draw(image, in: drawRect)
        return true
    }

    private static func drawPlaceholder(_ rect: CGRect, context: CGContext) {
        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(rect)
    }

    private static func drawText(
        _ text: String, in context: CGContext, at point: CGPoint,
        fontSize: CGFloat, bold: Bool = false,
        color: CGColor, maxWidth: CGFloat
    ) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateWithName(
            (bold ? "Helvetica-Bold" : "Helvetica") as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let truncated = truncate(text, fontSize: fontSize, maxWidth: maxWidth)
        guard let string = CFAttributedStringCreate(
            nil, truncated as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func truncate(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> String {
        guard maxWidth > 0 else { return text }
        // 粗略估算：Helvetica 平均字宽 ≈ 0.55 em；只用于视觉截断，不参与语义。
        let perCharacter = fontSize * 0.55
        let limit = max(1, Int(maxWidth / max(1, perCharacter)))
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit - 1))) + "…"
    }
}
