// desktop/native/gather-app/Tests/GatherAppTests/PrintDocumentRendererTests.swift
// Wave4b / P2-17（§6 第 4 条硬性缺口）：PrintDocumentRenderer 的首个回归套件。
//
// 此前只测 PrintLayout 纯数学，真正生成 PDF 的渲染器零测试（页数/坏图占位/取消
// 清理都是"看代码自信"）。本套件用真实 JPEG + 真实 CGPDFContext 钉住：
// - 单图渲染产出 1 页 PDF（PDFKit 读回页数，字节数 > 0）；
// - 多页分页与版面引擎同源（2×2 → 2 页），坏图计 failedImages 且不中断整本；
// - 取消时抛 CancellationError 且不留下最终 PDF 或 .partial 临时文件。
import AppKit
import Foundation
import PDFKit
import Testing
import ImageIO
@testable import GatherApplication

@Suite("打印 PDF 渲染（PrintDocumentRenderer）", .serialized)
@MainActor
struct PrintDocumentRendererTests {
    // MARK: - 夹具

    private final class TempDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("print-renderer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(_ name: String) -> URL { url.appendingPathComponent(name) }

        func cleanup() {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // 临时目录清理失败不影响断言（系统会回收）。
            }
        }
    }

    /// 写一张真实 JPEG（渲染器走 ImageIO 解码，不能拿空文件糊弄）。
    /// 用 ImageIO 直接生成：AppKit 的 NSBitmapImageRep/NSGraphicsContext 在无窗口
    /// 的测试进程里编码会失败（NSCocoaError 512），这里不用 UI 栈。
    private func writeJPEG(to url: URL, gray: CGFloat) throws {
        let size = 48
        let level = UInt8(max(0, min(255, Int(gray * 255))))
        let pixels = Data(repeating: level, count: size * size)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.jpeg" as CFString, 1, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    private func singleOptions(borderWidth: CGFloat = 0) -> SingleImagePrintOptions {
        SingleImagePrintOptions(
            paper: .a4,
            margins: PrintMargins(top: 28, bottom: 28, leading: 28, trailing: 28),
            sizing: .fitToPage,
            customImageSize: CGSize(width: 288, height: 432),
            borderWidth: borderWidth)
    }

    private func multiOptions() -> MultiPagePrintOptions {
        MultiPagePrintOptions(
            paper: .a4,
            margins: PrintMargins(top: 28, bottom: 28, leading: 28, trailing: 28),
            columns: 2,
            rows: 2,
            cellSpacing: 8,
            captionHeight: 16,
            headerHeight: 24,
            footerHeight: 18,
            headerText: "Shoot",
            footerText: "Gather",
            showsPageNumbers: true)
    }

    // MARK: - 用例

    @Test("单图渲染：产出 1 页 PDF，坏图计数为 0")
    func renderSingleImageProducesOnePagePDF() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }
        let image = temp.file("a.jpg")
        try writeJPEG(to: image, gray: 0.5)
        let output = temp.file("single.pdf")

        let result = try PrintDocumentRenderer.renderSingleImage(
            item: ContactSheetItem(path: image.path, caption: "a.jpg"),
            options: singleOptions(borderWidth: 2),
            to: output)

        #expect(result.pages == 1)
        #expect(result.bytes > 0)
        #expect(result.failedImages == 0)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let document = PDFDocument(url: output)
        #expect(document?.pageCount == 1)
    }

    @Test("多页渲染：分页与版面引擎同源（5 张 / 2×2 = 2 页）")
    func renderMultiPageMatchesLayoutPagination() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }
        var items: [ContactSheetItem] = []
        for index in 0..<4 {
            // 每轮写一张真实 JPEG：ImageIO 编码产生的自动释放对象放进局部池，
            // 4 轮生成不会把上一轮的 CGImage/ImageIO 临时对象攒到用例收尾。
            try autoreleasepool {
                let image = temp.file("p\(index).jpg")
                try writeJPEG(to: image, gray: 0.2 + Double(index) * 0.2)
                items.append(ContactSheetItem(path: image.path, caption: "p\(index).jpg"))
            }
        }
        let missing = temp.file("gone.jpg")
        items.append(ContactSheetItem(path: missing.path, caption: "gone.jpg"))

        let options = multiOptions()
        let expectedPages = MultiPagePrintLayoutEngine.pageCount(
            itemCount: items.count, options: options)
        #expect(expectedPages == 2)

        let output = temp.file("multi.pdf")
        let result = try PrintDocumentRenderer.renderMultiPage(
            items: items, options: options, to: output)

        #expect(result.pages == expectedPages)
        #expect(result.failedImages == 1, "缺失文件必须计入坏图，而不是中断整本或静默丢张")
        #expect(result.bytes > 0)
        let document = PDFDocument(url: output)
        #expect(document?.pageCount == expectedPages)
    }

    @Test("空输入：抛 emptyDocument（不产出空 PDF）")
    func renderMultiPageRejectsEmptyInput() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }
        let output = temp.file("empty.pdf")
        do {
            _ = try PrintDocumentRenderer.renderMultiPage(
                items: [], options: multiOptions(), to: output)
            Issue.record("空输入必须抛 PRINT_EMPTY_DOCUMENT")
        } catch let error as PrintRenderError {
            #expect(error == .emptyDocument)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("取消：抛 CancellationError，且不留下 PDF / .partial 临时文件")
    func renderMultiPageCancellationCleansUp() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }
        var items: [ContactSheetItem] = []
        for index in 0..<4 {
            // 同上：每轮生成一张真实 JPEG，用局部 autoreleasepool 控制 ImageIO 峰值。
            try autoreleasepool {
                let image = temp.file("c\(index).jpg")
                try writeJPEG(to: image, gray: 0.5)
                items.append(ContactSheetItem(path: image.path, caption: "c\(index).jpg"))
            }
        }
        let output = temp.file("cancelled.pdf")
        var checks = 0

        do {
            _ = try PrintDocumentRenderer.renderMultiPage(
                items: items,
                options: multiOptions(),
                to: output,
                isCancelled: {
                    checks += 1
                    return checks >= 2   // 第一格画完再取消：覆盖"页面已 begin"的清理路径
                })
            Issue.record("取消必须抛 CancellationError")
        } catch is CancellationError {
            // 期望路径
        }

        #expect(!FileManager.default.fileExists(atPath: output.path),
                "取消后不得留下最终 PDF")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
            .filter { $0.contains("partial") }
        #expect(leftovers.isEmpty, "取消后不得留下 .partial 临时文件：\(leftovers)")
    }
}
