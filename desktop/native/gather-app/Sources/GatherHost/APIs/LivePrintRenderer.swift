// desktop/native/gather-app/Sources/GatherHost/APIs/LivePrintRenderer.swift
// Wave3 / task-20：打印渲染端口的宿主实现。
//
// 只做「GatherUI 的 PrintJob* 值类型 → GatherApplication 的 Print* 选项」映射，
// 不含版面算法与绘制逻辑（分别在同目录 PrintLayout.swift / PrintDocumentRenderer.swift，
// 纯逻辑可单测）。async 方法在非 MainActor 执行体上跑：逐格 RAWDecoder 解码
// 几百毫秒，不能占主线程。
import Foundation
import GatherProtocol
import GatherUI
import GatherApplication

public struct LivePrintRenderer: PrintRenderingPort {
    public init() {}

    public func render(_ request: PrintJobRequest) async throws -> PrintJobOutcome {
        let items = request.items.map(Self.contactSheetItem)
        guard !items.isEmpty else { throw PrintRenderingError.failed("PRINT_EMPTY_DOCUMENT") }
        let url = URL(fileURLWithPath: request.outputPath)
        do {
            let result: PrintRenderResult
            switch request.options.mode {
            case .singleImage:
                guard let first = items.first else {
                    throw PrintRenderingError.failed("PRINT_EMPTY_DOCUMENT")
                }
                result = try PrintDocumentRenderer.renderSingleImage(
                    item: first,
                    options: Self.singleImageOptions(request.options),
                    to: url)
            case .multiPage:
                result = try PrintDocumentRenderer.renderMultiPage(
                    items: items,
                    options: Self.multiPageOptions(request.options),
                    to: url)
            }
            return PrintJobOutcome(
                pages: result.pages, bytes: result.bytes, failedImages: result.failedImages)
        } catch let error as PrintRenderError {
            throw PrintRenderingError.failed(error.description)
        } catch {
            throw PrintRenderingError.failed(String(describing: error))
        }
    }

    public func pageCount(for request: PrintJobRequest) -> Int {
        switch request.options.mode {
        case .singleImage:
            return 1
        case .multiPage:
            return MultiPagePrintLayoutEngine.pageCount(
                itemCount: request.items.count,
                options: Self.multiPageOptions(request.options))
        }
    }

    // MARK: - UI 值 → core 选项

    private static func contactSheetItem(_ item: PrintJobItem) -> ContactSheetItem {
        ContactSheetItem(
            presentation: DeliveryPresentationItem(
                photoId: item.filePath,
                filePath: item.filePath,
                filename: item.caption,
                rating: item.rating,
                label: item.label,
                pick: item.pick,
                keywords: item.keywords
            ),
            caption: item.caption
        )
    }

    private static func paper(_ paper: PrintJobPaper) -> PrintPaperPreset {
        switch paper {
        case .a4: return .a4
        case .a5: return .a5
        case .letter: return .letter
        case .photo4x6: return .photo4x6
        case .photo5x7: return .photo5x7
        case .photo8x10: return .photo8x10
        case .custom: return .custom
        }
    }

    private static func margins(_ margins: PrintJobMargins) -> PrintMargins {
        PrintMargins(
            top: margins.top, bottom: margins.bottom,
            leading: margins.leading, trailing: margins.trailing)
    }

    private static func singleImageOptions(
        _ options: PrintJobOptions
    ) -> SingleImagePrintOptions {
        SingleImagePrintOptions(
            paper: paper(options.paper),
            customPageSize: options.customPageSize,
            margins: margins(options.margins),
            sizing: options.sizing == .fitToPage ? .fitToPage : .custom,
            customImageSize: options.customImageSize,
            borderWidth: options.borderWidth)
    }

    private static func multiPageOptions(
        _ options: PrintJobOptions
    ) -> MultiPagePrintOptions {
        MultiPagePrintOptions(
            paper: paper(options.paper),
            customPageSize: options.customPageSize,
            margins: margins(options.margins),
            columns: options.columns,
            rows: options.rows,
            cellSpacing: options.cellSpacing,
            captionHeight: options.captionHeight,
            headerHeight: options.headerHeight,
            footerHeight: options.footerHeight,
            headerText: options.headerText,
            footerText: options.footerText,
            showsPageNumbers: options.showsPageNumbers)
    }
}
