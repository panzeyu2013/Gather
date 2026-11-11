// desktop/native/gather-core/Sources/GatherApplication/Services/Export/PrintDocumentRenderer.swift
// Wave3 / task-20：打印 PDF 渲染（单图 / 多页）。只消费 PrintLayout 的纯计算结果，
// 不再自己算版面 —— 单测钉版面，这里只负责往 CGPDFContext 里画。
//
// 复用：
// - 栅格化沿用联系表那条路（RAWDecoder.getThumbnail → CGImageSource → CGContext.draw），
//   逐格解码，内存上界 = 一页格数；
// - 打印面板复用 app 层的 PrintSupport（PDFDocument → NSPrintOperation），
//   Host 侧只把本文件的输出路径交给 UI。
//
// 与联系表相同的失败纪律：单张损坏只留空框 + caption，不中断整本；
// 先写临时文件、成功后再原子替换，取消/崩溃不会留下半截 PDF。
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import GatherAnalysis

/// 一次打印渲染的结果。
public struct PrintRenderResult: Equatable, Sendable {
    public let pages: Int
    public let bytes: Int
    public let failedImages: Int

    public init(pages: Int, bytes: Int, failedImages: Int) {
        self.pages = pages
        self.bytes = bytes
        self.failedImages = failedImages
    }
}

public enum PrintRenderError: Error, Equatable, CustomStringConvertible {
    case cannotCreateContext
    case writeFailed(String)
    case emptyDocument

    public var code: String {
        switch self {
        case .cannotCreateContext: return "PRINT_CONTEXT_FAILED"
        case .writeFailed: return "PRINT_WRITE_FAILED"
        case .emptyDocument: return "PRINT_EMPTY_DOCUMENT"
        }
    }

    public var description: String {
        switch self {
        case .cannotCreateContext: return "PRINT_CONTEXT_FAILED"
        case .writeFailed(let reason): return "PRINT_WRITE_FAILED: " + reason
        case .emptyDocument: return "PRINT_EMPTY_DOCUMENT"
        }
    }
}

public enum PrintDocumentRenderer {
    // MARK: - 单图

    /// 单图打印：一页，按 SingleImagePrintLayout 的矩形画图像（+ 可选边框）。
    public static func renderSingleImage(
        item: ContactSheetItem,
        options: SingleImagePrintOptions,
        to url: URL
    ) throws -> PrintRenderResult {
        let layout = SingleImagePrintLayoutEngine.layout(
            imageSize: imagePixelSize(item.path),
            options: options
        )
        var failed = 0
        let result = try withPDFContext(url: url, pageSize: layout.pageSize) { context in
            context.beginPDFPage(nil)
            if let border = layout.borderRect {
                context.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
                context.setLineWidth(max(0.5, options.borderWidth))
                context.stroke(border)
            }
            if !drawImage(item.path, in: layout.imageRect.integral, context: context) {
                failed += 1
                drawPlaceholder(layout.imageRect, context: context)
            }
            context.endPDFPage()
            return 1
        }
        return PrintRenderResult(pages: result.pages, bytes: result.bytes, failedImages: failed)
    }

    // MARK: - 多页

    /// 多页排版打印：每页 columns × rows 张，页眉/页脚/页码由版面引擎决定。
    ///
    /// - Parameter isCancelled: 逐张解码前检查（长打印可取消，取消抛 CancellationError
    ///   且不留下半截 PDF）。
    public static func renderMultiPage(
        items: [ContactSheetItem],
        options: MultiPagePrintOptions,
        to url: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> PrintRenderResult {
        guard !items.isEmpty else { throw PrintRenderError.emptyDocument }
        let pageLayouts = MultiPagePrintLayoutEngine.pages(
            itemCount: items.count, options: options)
        let pageCount = max(1, pageLayouts.count)
        var failed = 0
        let result = try withPDFContext(url: url, pageSize: options.pageSize) { context in
            for page in pageLayouts {
                context.beginPDFPage(nil)
                drawHeader(page: page, options: options, pageCount: pageCount, context: context)
                for cell in page.cells {
                    if isCancelled() { throw CancellationError() }
                    guard items.indices.contains(cell.itemIndex) else { continue }
                    let item = items[cell.itemIndex]
                    if !drawImage(item.path, in: cell.imageRect.integral, context: context) {
                        failed += 1
                        drawPlaceholder(cell.imageRect, context: context)
                    }
                    drawCaption(item: item, cell: cell, context: context)
                }
                drawFooter(page: page, options: options, pageCount: pageCount, context: context)
                context.endPDFPage()
            }
            return pageLayouts.count
        }
        return PrintRenderResult(pages: result.pages, bytes: result.bytes, failedImages: failed)
    }

    // MARK: - PDF 上下文（临时文件 + 原子替换）

    private struct PDFWriteResult {
        let pages: Int
        let bytes: Int
    }

    private static func withPDFContext(
        url: URL,
        pageSize: CGSize,
        body: (CGContext) throws -> Int
    ) throws -> PDFWriteResult {
        // 与联系表同款：先写同目录临时文件，成功后原子替换。
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).partial-\(UUID().uuidString.lowercased())")
        func discardTemp() {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                return
            }
        }
        var info: [String: Any] = [kCGPDFContextCreator as String: "Gather"]
        info[kCGPDFContextTitle as String] = "Gather Print"
        guard let consumer = CGDataConsumer(url: tempURL as CFURL),
              var mediaBox = Optional(CGRect(
                origin: .zero,
                size: CGSize(width: max(72, pageSize.width), height: max(72, pageSize.height))
              )),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else {
            discardTemp()
            throw PrintRenderError.cannotCreateContext
        }
        let pages: Int
        do {
            pages = try body(context)
        } catch {
            context.closePDF()
            discardTemp()
            throw error
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
            throw PrintRenderError.writeFailed(String(describing: error))
        }
        let bytes: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            bytes = 0
        }
        return PDFWriteResult(pages: max(1, pages), bytes: bytes)
    }

    // MARK: - 绘制

    private static func drawHeader(
        page: PrintPageLayout,
        options: MultiPagePrintOptions,
        pageCount: Int,
        context: CGContext
    ) {
        guard let header = page.headerRect else { return }
        let title = options.headerText
        if !title.isEmpty {
            drawText(
                title, in: context,
                at: CGPoint(x: header.minX, y: header.minY + 4),
                fontSize: 13, bold: true, color: CGColor(gray: 0.1, alpha: 1),
                maxWidth: header.width)
        }
        // 页眉分隔线：有页眉区就画，保证多页的版式骨架一致。
        context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: header.minX, y: header.minY + 1))
        context.addLine(to: CGPoint(x: header.maxX, y: header.minY + 1))
        context.strokePath()
    }

    private static func drawFooter(
        page: PrintPageLayout,
        options: MultiPagePrintOptions,
        pageCount: Int,
        context: CGContext
    ) {
        if let footer = page.footerRect, !options.footerText.isEmpty {
            drawText(
                options.footerText, in: context,
                at: CGPoint(x: footer.minX, y: footer.minY + 4),
                fontSize: 8, color: CGColor(gray: 0.45, alpha: 1),
                maxWidth: max(1, footer.width / 2))
        }
        if let numberRect = page.pageNumberRect {
            let label = "\(page.pageIndex + 1) / \(pageCount)"
            drawText(
                label, in: context,
                at: CGPoint(x: numberRect.minX, y: numberRect.minY + 4),
                fontSize: 8, color: CGColor(gray: 0.45, alpha: 1),
                maxWidth: numberRect.width)
        }
    }

    private static func drawCaption(
        item: ContactSheetItem,
        cell: PrintCellLayout,
        context: CGContext
    ) {
        guard cell.captionRect.height >= 6 else { return }
        var text = item.caption
        let rating = item.presentation.rating
        if rating > 0 {
            text += "  " + String(repeating: "\u{2605}", count: max(0, min(5, rating)))
        }
        drawText(
            text, in: context,
            at: CGPoint(x: cell.captionRect.minX + 1, y: cell.captionRect.minY + 3),
            fontSize: 8, color: CGColor(gray: 0.25, alpha: 1),
            maxWidth: max(1, cell.captionRect.width - 2))
    }

    /// 按 rect 的宽高比解码并居中绘制（打印 2x 目标尺寸，与联系表一致）。
    private static func drawImage(_ path: String, in rect: CGRect, context: CGContext) -> Bool {
        guard rect.width > 0, rect.height > 0,
              FileManager.default.fileExists(atPath: path) else { return false }
        let target = max(1, Int(max(rect.width, rect.height) * 2))
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
        let drawSize = CGSize(
            width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height)
        context.draw(image, in: drawRect)
        return true
    }

    private static func imagePixelSize(_ path: String) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return .zero }
        var width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation >= 5 && orientation <= 8 { swap(&width, &height) }
        guard width > 0, height > 0 else { return .zero }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func drawPlaceholder(_ rect: CGRect, context: CGContext) {
        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(rect)
    }

    private static func drawText(
        _ text: String,
        in context: CGContext,
        at point: CGPoint,
        fontSize: CGFloat,
        bold: Bool = false,
        color: CGColor,
        maxWidth: CGFloat
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

    /// 与联系表同一经验系数（Helvetica ≈ 0.55 em）；只用于视觉截断。
    private static func truncate(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> String {
        guard maxWidth > 0 else { return text }
        let perCharacter = fontSize * 0.55
        let limit = max(1, Int(maxWidth / max(1, perCharacter)))
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit - 1))) + "…"
    }
}
