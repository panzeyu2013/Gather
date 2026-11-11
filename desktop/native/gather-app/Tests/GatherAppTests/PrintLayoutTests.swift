// desktop/native/gather-app/Tests/GatherAppTests/PrintLayoutTests.swift
// Wave3 / task-20：打印版面纯逻辑（单图适配 + 多页排版）单测。
//
// 版面引擎在 GatherApplication/Services/Export/PrintLayout.swift（不碰文件/不解码），
// 渲染层只消费这些矩形；本文件钉住四点：
// 1) 单图 fit：按源宽高比在「离白」后的可用区内居中；
// 2) 单图 custom：自定义图像框居中并夹进页内；边框 = 图像框外扩 borderWidth；
// 3) 多页：每页格数/页数/分页区间、页眉页脚与页码区、cell/image/caption 落位；
// 4) 退化输入（0 宽源图、超大边距、非法行列）有确定兜底，不产出 0 尺寸矩形。
import CoreGraphics
import Foundation
import Testing
import GatherApplication

@Suite("打印版面：单图适配与多页排版（Wave3）", .serialized)
struct PrintLayoutTests {
    // MARK: - 单图

    private func singleOptions(
        paper: PrintPaperPreset = .a4,
        margins: PrintMargins = PrintMargins(top: 28, bottom: 28, leading: 28, trailing: 28),
        sizing: PrintSingleSizing = .fitToPage,
        customImageSize: CGSize = CGSize(width: 288, height: 432),
        borderWidth: CGFloat = 0
    ) -> SingleImagePrintOptions {
        SingleImagePrintOptions(
            paper: paper,
            margins: margins,
            sizing: sizing,
            customImageSize: customImageSize,
            borderWidth: borderWidth)
    }

    @Test("单图 fit：按原图宽高比在可用区内居中，四边不越界")
    func singleFitCentersAspectRatio() {
        let options = singleOptions()
        let layout = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000), options: options)

        #expect(layout.pageSize == CGSize(width: 595, height: 842))
        #expect(layout.contentRect == CGRect(x: 28, y: 28, width: 539, height: 786))
        // 横构图限制在宽度：539 × 404.25，水平贴边、垂直居中。
        #expect(abs(layout.imageRect.width - 539) < 0.001)
        #expect(abs(layout.imageRect.height - 404.25) < 0.001)
        #expect(abs(layout.imageRect.midX - layout.contentRect.midX) < 0.001)
        #expect(abs(layout.imageRect.midY - layout.contentRect.midY) < 0.001)
        #expect(abs(layout.imageRect.width / layout.imageRect.height - 4.0 / 3.0) < 0.001)
        #expect(layout.borderRect == nil, "无边框时不给边框矩形")
    }

    @Test("单图 fit：窄长竖构图限制在高度，图像始终在可用区内")
    func singleFitPortraitUsesHeight() {
        // 2400×4000（aspect 0.6）比 A4 可用区（539×786，aspect 0.686）更窄长：
        // 此时受高度限制，高度正好等于可用区高度。
        let layout = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 2400, height: 4000), options: singleOptions())
        #expect(abs(layout.imageRect.height - 786) < 0.001)
        #expect(layout.imageRect.width <= layout.contentRect.width + 0.001)
        #expect(layout.contentRect.contains(layout.imageRect))
    }

    @Test("单图 custom：自定义图像框居中；超大尺寸被夹进「离白」后的可用区")
    func singleCustomSizeClamped() {
        let centered = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            options: singleOptions(
                sizing: .custom, customImageSize: CGSize(width: 288, height: 432)))
        #expect(centered.imageRect == CGRect(x: 153.5, y: 205, width: 288, height: 432))

        // Wave4a / B2：custom 也必须尊重「离白」，超大框夹到 contentRect 而不是纸张。
        let oversized = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            options: singleOptions(
                sizing: .custom, customImageSize: CGSize(width: 2000, height: 2000)))
        #expect(oversized.imageRect == oversized.contentRect,
                "自定义尺寸再大也只能铺满可用区，不能压过页边距")
        #expect(oversized.imageRect.minX >= 28 && oversized.imageRect.minY >= 28)
    }

    @Test("单图 custom：大边距下小框仍夹在 contentRect 内（B2 回归）")
    func singleCustomRespectsLargeMargins() {
        let margins = PrintMargins(top: 100, bottom: 100, leading: 100, trailing: 100)
        let layout = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            options: SingleImagePrintOptions(
                margins: margins,
                sizing: .custom,
                customImageSize: CGSize(width: 1000, height: 1000)))
        #expect(layout.contentRect == CGRect(x: 100, y: 100, width: 395, height: 642))
        #expect(layout.imageRect == layout.contentRect,
                "1000×1000 超出可用区时必须夹到 contentRect")
        #expect(layout.imageRect.minX >= 100 && layout.imageRect.maxY <= 742)

        // 小框在可用区内居中（不贴纸张边）。
        let small = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            options: SingleImagePrintOptions(
                margins: margins,
                sizing: .custom,
                customImageSize: CGSize(width: 200, height: 200)))
        let content = layout.contentRect
        #expect(small.imageRect == CGRect(
            x: content.midX - 100, y: content.midY - 100,
            width: 200, height: 200))
    }

    @Test("单图边框：中心线外扩 borderWidth/2，可见框贴图像外沿、厚度 = 输入值")
    func singleBorderOutset() {
        let layout = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            options: singleOptions(borderWidth: 4))
        let border = layout.borderRect
        #expect(border != nil)
        // Wave4b / P2-15：描边以路径为中心；路径外扩 w/2 后整条线正好落在
        // 图像外侧 0..w，可见厚度等于用户输入值（旧实现外扩 w → 厚 1.5w 且有缝）。
        #expect(abs((border?.width ?? 0) - (layout.imageRect.width + 4)) < 0.001)
        #expect(abs((border?.height ?? 0) - (layout.imageRect.height + 4)) < 0.001)
        #expect(abs((border?.midX ?? 0) - layout.imageRect.midX) < 0.001)
        let innerEdge = (border?.minX ?? 0) + 2
        #expect(abs(innerEdge - layout.imageRect.minX) < 0.001,
                "边框内沿必须贴住图像外沿（不再留 w/2 空隙）")
    }

    @Test("单图退化输入：源尺寸非法时铺满可用区；超大边距把可用区钳到 ≥1pt")
    func singleDegenerateInputs() {
        let invalid = SingleImagePrintLayoutEngine.layout(
            imageSize: .zero, options: singleOptions())
        #expect(invalid.imageRect == invalid.contentRect, "源尺寸未知时不能产出 0 尺寸图像框")

        let hugeMargins = PrintMargins(top: 400, bottom: 400, leading: 400, trailing: 400)
        let clamped = SingleImagePrintLayoutEngine.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            options: SingleImagePrintOptions(paper: .a4, margins: hugeMargins))
        #expect(clamped.contentRect.width >= 1)
        #expect(clamped.contentRect.height >= 1)
    }

    @Test("纸张：预设优先；custom 用调用方尺寸并夹到可打印下限")
    func paperResolution() {
        #expect(PrintPaperPreset.photo4x6.pointSize == CGSize(width: 288, height: 432))
        #expect(PrintPaperPreset.a4.resolvedPageSize(custom: CGSize(width: 10, height: 10))
                == CGSize(width: 595, height: 842), "预设忽略 custom 尺寸")
        #expect(PrintPaperPreset.custom.resolvedPageSize(custom: CGSize(width: 500, height: 700))
                == CGSize(width: 500, height: 700))
        #expect(PrintPaperPreset.custom.resolvedPageSize(custom: CGSize(width: 10, height: 10))
                == CGSize(width: 72, height: 72), "自定义尺寸不得小于 1 英寸")
    }

    // MARK: - 多页

    private func multiOptions(
        columns: Int = 3,
        rows: Int = 2,
        headerHeight: CGFloat = 32,
        footerHeight: CGFloat = 20,
        captionHeight: CGFloat = 16,
        showsPageNumbers: Bool = true
    ) -> MultiPagePrintOptions {
        MultiPagePrintOptions(
            paper: .a4,
            margins: PrintMargins(top: 28, bottom: 28, leading: 28, trailing: 28),
            columns: columns,
            rows: rows,
            cellSpacing: 8,
            captionHeight: captionHeight,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            headerText: "Shoot",
            footerText: "Gather",
            showsPageNumbers: showsPageNumbers)
    }

    @Test("多页：每页格数与页数（14 张 / 3×2 = 3 页）")
    func multiPerPageAndPageCount() {
        let options = multiOptions()
        #expect(MultiPagePrintLayoutEngine.perPage(options: options) == 6)
        #expect(MultiPagePrintLayoutEngine.pageCount(itemCount: 14, options: options) == 3)
        #expect(MultiPagePrintLayoutEngine.paginate(itemCount: 14, perPage: 6).map(\.count) == [6, 6, 2])

        let pages = MultiPagePrintLayoutEngine.pages(itemCount: 14, options: options)
        #expect(pages.map(\.pageIndex) == [0, 1, 2])
        #expect(pages.map { $0.itemRange } == [0..<6, 6..<12, 12..<14])
        #expect(pages.map { $0.cells.count } == [6, 6, 2])
        #expect(pages[2].cells.map(\.itemIndex) == [12, 13])
    }

    @Test("多页：页眉/页脚/页码区与「离白」对齐")
    func multiHeaderFooterRects() {
        let options = multiOptions()
        let page = MultiPagePrintLayoutEngine.pages(itemCount: 2, options: options)[0]

        // 可用区 = 595-56 × 842-56；页眉贴可用区顶部，页脚贴底部。
        #expect(page.headerRect == CGRect(x: 28, y: 814 - 32, width: 539, height: 32))
        #expect(page.footerRect == CGRect(x: 28, y: 28, width: 539, height: 20))
        let numberRect = page.pageNumberRect
        #expect(numberRect != nil)
        #expect(abs((numberRect?.maxX ?? 0) - (28 + 539)) < 0.001, "页码靠右")
        #expect(numberRect?.minY == 28)
        #expect(page.headerRect?.maxY == CGFloat(842 - 28), "页眉不侵入上边距")

        let withoutNumbers = MultiPagePrintLayoutEngine.pages(
            itemCount: 2, options: multiOptions(showsPageNumbers: false))[0]
        #expect(withoutNumbers.pageNumberRect == nil)

        let withoutFooter = MultiPagePrintLayoutEngine.pages(
            itemCount: 2, options: multiOptions(footerHeight: 0))[0]
        #expect(withoutFooter.footerRect == nil)
        #expect(withoutFooter.pageNumberRect == nil, "没有页脚区时不画页码")
    }

    @Test("多页：格子的 cell/image/caption 落位（caption 在格底、图像占其余高度）")
    func multiCellRects() {
        let options = multiOptions()
        let page = MultiPagePrintLayoutEngine.pages(itemCount: 6, options: options)[0]
        let first = page.cells[0]
        let second = page.cells[1]
        let secondRowFirst = page.cells[3]

        // 网格：y = 28+20 = 48，高 842-56-32-20 = 734；3 列 × 2 行，间距 8。
        let cellWidth: CGFloat = (539 - 8 * 2) / 3
        let cellHeight: CGFloat = (734 - 8) / 2
        #expect(abs(first.cellRect.minX - 28) < 0.001)
        #expect(abs(first.cellRect.width - cellWidth) < 0.001)
        #expect(abs(first.cellRect.height - cellHeight) < 0.001)
        #expect(abs(first.cellRect.maxY - 782) < 0.001, "首行贴网格上沿")
        #expect(abs(second.cellRect.minX - (28 + cellWidth + 8)) < 0.001)
        #expect(abs(secondRowFirst.cellRect.minY - 48) < 0.001, "末行贴网格下沿")

        // caption 在格底 16pt；图像区 = 格子剩余高度。
        #expect(first.captionRect == CGRect(x: first.cellRect.minX, y: first.cellRect.minY,
                                           width: cellWidth, height: 16))
        #expect(abs(first.imageRect.maxY - first.cellRect.maxY) < 0.001)
        #expect(abs(first.imageRect.minY - (first.cellRect.minY + 16)) < 0.001)

        // caption 高度为 0 时图像占满整格。
        let noCaption = MultiPagePrintLayoutEngine.pages(
            itemCount: 1, options: multiOptions(captionHeight: 0))[0].cells[0]
        #expect(noCaption.captionRect.height == 0)
        #expect(abs(noCaption.imageRect.height - noCaption.cellRect.height) < 0.001)
    }

    @Test("多页：极小自定义纸 + 大页眉页脚时行列被收窄，格子不越出纸张/离白")
    func multiTinyPaperClampsGrid() {
        let options = MultiPagePrintOptions(
            paper: .custom,
            customPageSize: CGSize(width: 100, height: 100),
            // 20pt 离白 + 24pt 页眉 + 16pt 页脚：网格区只剩 20pt，4 行装不下。
            margins: PrintMargins(top: 20, bottom: 20, leading: 20, trailing: 20),
            columns: 4,
            rows: 4,
            cellSpacing: 8,
            captionHeight: 16,
            headerHeight: 24,
            footerHeight: 16,
            headerText: "H",
            footerText: "F")

        // Wave4b / P2-14：请求 4×4 在这张纸上装不下 → 行列收窄，但分页口径一致。
        let grid = MultiPagePrintLayoutEngine.fittedGrid(options: options)
        #expect(grid.columns < 4 || grid.rows < 4)
        let perPage = MultiPagePrintLayoutEngine.perPage(options: options)
        #expect(perPage == grid.columns * grid.rows)

        let pages = MultiPagePrintLayoutEngine.pages(itemCount: 10, options: options)
        let expectedPages = (10 + perPage - 1) / perPage
        #expect(pages.count == expectedPages)

        let content = SingleImagePrintLayoutEngine.contentRect(
            pageSize: options.pageSize, margins: options.margins)
        for page in pages {
            for cell in page.cells {
                #expect(cell.cellRect.minX >= content.minX - 0.001)
                #expect(cell.cellRect.maxX <= content.maxX + 0.001,
                        "格子不得画到纸张/离白之外（旧实现会排到负坐标）")
                #expect(cell.cellRect.minY >= content.minY - 0.001)
                #expect(cell.cellRect.maxY <= content.maxY + 0.001)
            }
        }
    }

    @Test("多页：正常纸张的请求行列不被收窄（回归）")
    func multiFittedGridKeepsNormalLayout() {
        let grid = MultiPagePrintLayoutEngine.fittedGrid(options: multiOptions())
        #expect(grid.columns == 3)
        #expect(grid.rows == 2)
        #expect(MultiPagePrintLayoutEngine.perPage(options: multiOptions()) == 6)
    }

    @Test("多页：空输入 0 页；行列非法值被收敛")
    func multiDegenerateInputs() {
        #expect(MultiPagePrintLayoutEngine.pages(itemCount: 0, options: multiOptions()).isEmpty)
        #expect(MultiPagePrintLayoutEngine.pageCount(itemCount: 0, options: multiOptions()) == 0)

        let clamped = MultiPagePrintOptions(columns: 0, rows: 99)
        #expect(clamped.columns == 1)
        #expect(clamped.rows == 20)
        #expect(MultiPagePrintLayoutEngine.perPage(options: clamped) == 20)
    }
}
