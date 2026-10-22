// desktop/native/gather-app/Tests/GatherAppTests/JustifiedLayoutTests.swift
// Phase 3.2 justified-layout 移植对账：逐用例对齐 TS 行为。
// TS 源: desktop/src/renderer/pages/SessionDetail/justified-layout.ts
// 期望值由真实 TS 算法（node 运行同源函数）生成，见测试内注释的 JSON。

import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost

@Suite("JustifiedLayout")
struct JustifiedLayoutTests {
    // TS: 空输入 / 非法容器宽度 / 非法目标高度 → []。
    @Test func emptyOrInvalidInputsReturnEmpty() {
        #expect(layoutJustifiedRows(source: [], containerWidth: 900, targetRowHeight: 200).isEmpty)
        #expect(layoutJustifiedRows(source: [GalleryAspectItem(width: 100, height: 100)], containerWidth: 0, targetRowHeight: 200).isEmpty)
        #expect(layoutJustifiedRows(source: [GalleryAspectItem(width: 100, height: 100)], containerWidth: 900, targetRowHeight: 0).isEmpty)
    }

    // TS fixture: singleWide —— 单张超宽照片，投影不足一行 → 末行
    // [{"height":200,"justified":false,"items":[{"index":0,"width":400}]}]。
    @Test func singleWideItemStaysUnjustified() {
        let rows = layoutJustifiedRows(
            source: [GalleryAspectItem(width: 2000, height: 1000)],
            containerWidth: 900,
            targetRowHeight: 200
        )
        #expect(rows.count == 1)
        #expect(rows[0].justified == false)
        #expect(rows[0].height == 200)
        #expect(rows[0].items.map(\.index) == [0])
        #expect(rows[0].items[0].width == 400)
    }

    // TS fixture: fiveSquares —— 4 张凑满（219 高，去尾更接近目标）+ 末行 1 张。
    // [{"height":219,"justified":true,"items":[{0,219},{1,219},{2,219},{3,219}]},
    //  {"height":200,"justified":false,"items":[{4,200}]}]
    @Test func fiveSquaresFillFourThenTrailingOne() {
        let squares = Array(repeating: GalleryAspectItem(width: 100, height: 100), count: 5)
        let rows = layoutJustifiedRows(source: squares, containerWidth: 900, targetRowHeight: 200)
        #expect(rows.count == 2)
        #expect(rows[0].justified == true)
        #expect(rows[0].height == 219)
        #expect(rows[0].items.map(\.index) == [0, 1, 2, 3])
        #expect(rows[0].items.allSatisfy { $0.width == 219 })
        #expect(rows[1].justified == false)
        #expect(rows[1].height == 200)
        #expect(rows[1].items.map(\.index) == [4])
        #expect(rows[1].items[0].width == 200)
    }

    // TS fixture: fiveSquaresGap0 —— gap=0 时 5 张恰好 1000 宽 → 整行铺满。
    // [{"height":200,"justified":true,"items":[0..4 各 200]}]
    @Test func fiveSquaresWithZeroGapFillOneRow() {
        let squares = Array(repeating: GalleryAspectItem(width: 100, height: 100), count: 5)
        let rows = layoutJustifiedRows(source: squares, containerWidth: 1000, targetRowHeight: 200, gap: 0)
        #expect(rows.count == 1)
        #expect(rows[0].justified == true)
        #expect(rows[0].height == 200)
        #expect(rows[0].items.count == 5)
    }

    // TS fixture: fourToOneRow —— 4 张 1:1 在 900 宽容器投影 824 < 900 →
    // 全程不结算 → 末行 min(200, 446)。
    // [{"height":200,"justified":false,"items":[0..3 各 200]}]
    @Test func fourSquaresBecomeTrailingRow() {
        let squares = Array(repeating: GalleryAspectItem(width: 100, height: 100), count: 4)
        let rows = layoutJustifiedRows(source: squares, containerWidth: 900, targetRowHeight: 200)
        #expect(rows.count == 1)
        #expect(rows[0].justified == false)
        #expect(rows[0].height == 200)
        #expect(rows[0].items.map(\.index) == [0, 1, 2, 3])
    }

    // TS fixture: mixedAspects —— 宽高比 [2,1,0.5,1.5] + 两行尾。
    // [{height:235.2, justified, items:[470.4,235.2,117.6,352.8]},
    //  {height:220, justified:false, items:[220,660]}]
    @Test func mixedAspectsMatchTSFixture() {
        let source = [
            GalleryAspectItem(width: 2000, height: 1000),
            GalleryAspectItem(width: 1000, height: 1000),
            GalleryAspectItem(width: 500, height: 1000),
            GalleryAspectItem(width: 1500, height: 1000),
            GalleryAspectItem(width: 800, height: 800),
            GalleryAspectItem(width: 3000, height: 1000),
        ]
        let rows = layoutJustifiedRows(source: source, containerWidth: 1200, targetRowHeight: 220)
        #expect(rows.count == 2)
        #expect(rows[0].justified == true)
        #expect(abs(rows[0].height - 235.2) < 0.001)
        #expect(rows[0].items.map(\.index) == [0, 1, 2, 3])
        let widths = rows[0].items.map(\.width)
        #expect(abs(widths[0] - 470.4) < 0.001)
        #expect(abs(widths[1] - 235.2) < 0.001)
        #expect(abs(widths[2] - 117.6) < 0.001)
        #expect(abs(widths[3] - 352.8) < 0.001)
        #expect(rows[1].justified == false)
        #expect(rows[1].height == 220)
        #expect(rows[1].items.map(\.index) == [4, 5])
        #expect(abs(rows[1].items[0].width - 220) < 0.001)
        #expect(abs(rows[1].items[1].width - 660) < 0.001)
    }

    // TS fixture: invalidRatio —— 非法尺寸（宽或高 ≤ 0）回退宽高比 1。
    // [{"height":200,"justified":false,"items":[0,1 各 200]}]
    @Test func invalidDimensionsFallBackToSquare() {
        let source = [
            GalleryAspectItem(width: 0, height: 100),
            GalleryAspectItem(width: 100, height: 0),
        ]
        let rows = layoutJustifiedRows(source: source, containerWidth: 900, targetRowHeight: 200)
        #expect(rows.count == 1)
        #expect(rows[0].justified == false)
        #expect(rows[0].items.map(\.index) == [0, 1])
        #expect(rows[0].items.allSatisfy { $0.width == 200 })
    }

    // TS fixture: tallThenWide —— 4 张 1:3 竖图 + 4 张 4:1 横图：
    // 行1 = 4 竖 + 1 横（181.5）；行2 = 2 横（124）；末行 1 横（180 未铺满）。
    // [{height:181.5, justified, [60.5×4, 726]},
    //  {height:124, justified, [496,496]},
    //  {height:180, justified:false, [720]}]
    @Test func tallAndWideRowsMatchTSFixture() {
        let tall = GalleryAspectItem(width: 100, height: 300)
        let wide = GalleryAspectItem(width: 400, height: 100)
        let source = [tall, tall, tall, tall, wide, wide, wide, wide]
        let rows = layoutJustifiedRows(source: source, containerWidth: 1000, targetRowHeight: 180)
        #expect(rows.count == 3)
        #expect(rows[0].justified == true)
        #expect(abs(rows[0].height - 181.5) < 0.001)
        #expect(rows[0].items.map(\.index) == [0, 1, 2, 3, 4])
        #expect(abs(rows[0].items[0].width - 60.5) < 0.001)
        #expect(abs(rows[0].items[4].width - 726) < 0.001)
        #expect(rows[1].justified == true)
        #expect(abs(rows[1].height - 124) < 0.001)
        #expect(rows[1].items.map(\.index) == [5, 6])
        #expect(abs(rows[1].items[0].width - 496) < 0.001)
        #expect(rows[2].justified == false)
        #expect(rows[2].height == 180)
        #expect(rows[2].items.map(\.index) == [7])
        #expect(abs(rows[2].items[0].width - 720) < 0.001)
    }

    // TS fixture: singlePhotoExact —— 单张 2:1 于 900 宽容器。
    // [{"height":200,"justified":false,"items":[{"index":0,"width":400}]}]
    @Test func singlePhotoWidthScalesWithTargetHeight() {
        let rows = layoutJustifiedRows(
            source: [GalleryAspectItem(width: 900, height: 450)],
            containerWidth: 900,
            targetRowHeight: 200
        )
        #expect(rows.count == 1)
        #expect(rows[0].height == 200)
        #expect(rows[0].items[0].width == 400)
    }

    // TS fixture: tenSquares —— 800 宽容器：5 张一行（153.6），末行 5 张。
    // [{height:153.6, justified, [153.6×5]}, {height:150, justified:false, [150×5]}]
    @Test func tenSquaresSplitFiveAndFive() {
        let squares = Array(repeating: GalleryAspectItem(width: 100, height: 100), count: 10)
        let rows = layoutJustifiedRows(source: squares, containerWidth: 800, targetRowHeight: 150)
        #expect(rows.count == 2)
        #expect(rows[0].justified == true)
        #expect(abs(rows[0].height - 153.6) < 0.001)
        #expect(rows[0].items.count == 5)
        #expect(rows[1].justified == false)
        #expect(rows[1].height == 150)
        #expect(rows[1].items.count == 5)
        #expect(rows[1].items.map(\.index) == [5, 6, 7, 8, 9])
    }

    // safeAspectRatio 单独对账（TS 逐分支）。
    @Test func safeAspectRatioBranches() {
        #expect(safeAspectRatio(GalleryAspectItem(width: 200, height: 100)) == 2)
        #expect(safeAspectRatio(GalleryAspectItem(width: 0, height: 100)) == 1)
        #expect(safeAspectRatio(GalleryAspectItem(width: 100, height: 0)) == 1)
        #expect(safeAspectRatio(GalleryAspectItem(width: -5, height: 100)) == 1)
    }
}
