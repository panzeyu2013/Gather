// desktop/native/gather-app/Tests/GatherAppTests/CullingViewerZoomTests.swift
// P1（Wave1 20-culling-browse #2）：查看器缩放换算的纯逻辑用例。
//
// 旧实现的 scale 是"相对 fit 的 1..8 倍"，没有真 1:1：⌘0 标着"实际大小"却执行
// fit 复位、fit 时胶囊也写 100%。本用例钉住新的换算口径：
// - 实际像素（1:1）倍率 = 源像素 /（fit 点数 × 屏幕 backingScale）；
// - 缩放上限至少保留既有 fit×8，大图/窄窗口时抬到实际像素档；
// - 百分比按「1 源像素 = 1 屏幕物理像素 = 100%」显示。
import Foundation
import Testing
@testable import GatherUI

@Suite("查看器缩放换算（1:1 / 适配窗口）")
struct CullingViewerZoomTests {
    @Test("Retina 下的实际像素倍率 = 源像素 / (fit 点数 × 2)")
    func actualPixelsScaleOnRetina() throws {
        let scale = try #require(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 6000, fitPoints: 800, backingScale: 2))
        #expect(abs(scale - 3.75) < 0.0001, "6000px 源图在 800pt 的 fit 下，1:1 需要 3.75×")
    }

    @Test("非 Retina 屏没有 backingScale 折半，倍率是 Retina 的两倍")
    func actualPixelsScaleOnNonRetina() throws {
        let scale = try #require(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 6000, fitPoints: 800, backingScale: 1))
        #expect(abs(scale - 7.5) < 0.0001)
    }

    @Test("源图小于 fit 显示尺寸时收敛回 fit（fit 已比 1:1 更大）")
    func actualPixelsScaleBelowFitClampsToFit() throws {
        let scale = try #require(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 500, fitPoints: 800, backingScale: 2))
        #expect(scale == CullingViewerZoom.fitScale)
    }

    @Test("实际像素百分比：1:1 档正好 100%")
    func pixelPercentAtActualPixels() throws {
        let actual = try #require(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 6000, fitPoints: 800, backingScale: 2))
        let percent = try #require(CullingViewerZoom.pixelPercent(
            scale: actual, sourceMaxDimension: 6000, fitPoints: 800, backingScale: 2))
        #expect(percent == 100)
    }

    @Test("fit 档不是 100%（旧实现的名不副实由此改正）")
    func pixelPercentAtFitIsNotHundred() throws {
        let percent = try #require(CullingViewerZoom.pixelPercent(
            scale: CullingViewerZoom.fitScale, sourceMaxDimension: 6000, fitPoints: 800, backingScale: 2))
        #expect(percent == 27, "6000px 源图在 800pt×2 的 fit 下约 27%")
        #expect(percent != 100)
    }

    @Test("缩放上限：至少保留既有 fit×8")
    func maximumScaleKeepsLegacyEight() {
        let maximum = CullingViewerZoom.maximumScale(
            sourceMaxDimension: 6000, fitPoints: 800, backingScale: 2)
        #expect(maximum == CullingViewerZoom.baseMaximumScale)
    }

    @Test("缩放上限：大图窄窗口时抬到实际像素档，1:1 真的能到")
    func maximumScaleRaisesForLargeSource() {
        // 16000px 源图在 500pt（×2）的窗口里，1:1 需要 16× —— 旧上限 8× 到不了。
        let maximum = CullingViewerZoom.maximumScale(
            sourceMaxDimension: 16000, fitPoints: 500, backingScale: 2)
        #expect(abs(maximum - 16) < 0.0001)
    }

    @Test("clamp：越界与非法值都收敛回合法区间")
    func clampGuards() {
        #expect(CullingViewerZoom.clamp(0.2) == CullingViewerZoom.fitScale)
        #expect(CullingViewerZoom.clamp(99) == CullingViewerZoom.baseMaximumScale)
        #expect(CullingViewerZoom.clamp(.nan) == CullingViewerZoom.fitScale)
        #expect(CullingViewerZoom.clamp(.infinity) == CullingViewerZoom.fitScale)
        #expect(CullingViewerZoom.clamp(3, maximum: 12) == 3)
        #expect(CullingViewerZoom.clamp(20, maximum: 12) == 12)
    }

    @Test("源尺寸/几何非法时返回 nil（胶囊隐藏，不显示假的百分比）")
    func invalidGeometryReturnsNil() {
        #expect(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 0, fitPoints: 800, backingScale: 2) == nil)
        #expect(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 6000, fitPoints: 0, backingScale: 2) == nil)
        #expect(CullingViewerZoom.actualPixelsScale(
            sourceMaxDimension: 6000, fitPoints: 800, backingScale: 0) == nil)
        #expect(CullingViewerZoom.pixelPercent(
            scale: 2, sourceMaxDimension: 0, fitPoints: 800, backingScale: 2) == nil)
    }
}
