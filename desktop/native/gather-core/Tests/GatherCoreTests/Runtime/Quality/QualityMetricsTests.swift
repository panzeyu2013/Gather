// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Quality/QualityMetricsTests.swift
// W2c：QualityMetrics 纯函数测试（无数据库、无解码）。
//
// 语义对照旧 Services/QualityServiceTests.swift:130-158 的 technical quality
// metrics 三个用例（flat/edges/degenerate），另补 regionPixels 的 floor/ceil、
// 钳制与 <2x2 返回 nil 的边界守护。
//
// 命名注记：旧测试文件（Services/QualityServiceTests.swift）仍有同名顶层
// suite \`QualityMetricsTests\`，同模块不可重名，故本 suite 命名
// RuntimeQualityMetricsTests（filter 子串仍匹配 QualityMetricsTests）。

import Foundation
import Testing
@testable import GatherCore

@Suite("quality metrics（W2c 纯函数）")
struct RuntimeQualityMetricsTests {
    @Test("scores a flat image as low sharpness but valid exposure")
    func flatImage() {
        let result = QualityMetrics.metricFromPixels(data: [UInt8](repeating: 128, count: 16), width: 4, height: 4)
        #expect(result.sharpness == 0)
        #expect(result.exposure == 1)
    }

    @Test("detects both edges and exposure problems deterministically")
    func edgesAndExposure() {
        let pixels: [UInt8] = [
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
        ]
        let result = QualityMetrics.metricFromPixels(data: pixels, width: 4, height: 4)
        #expect(result.sharpness > 0)
        #expect(abs(result.exposure - 0.996) < 0.001)
    }

    @Test("returns zero metrics for degenerate sizes")
    func degenerateSizes() {
        let oneByOne = QualityMetrics.metricFromPixels(data: [128], width: 1, height: 1)
        #expect(oneByOne.sharpness == 0)
        #expect(oneByOne.exposure == 0)

        let emptyData = QualityMetrics.metricFromPixels(data: [], width: 4, height: 4)
        #expect(emptyData.sharpness == 0)
        #expect(emptyData.exposure == 0)

        let thinRow = QualityMetrics.metricFromPixels(data: [0, 255, 0, 255], width: 4, height: 1)
        #expect(thinRow.sharpness == 0)
        #expect(thinRow.exposure == 0)
    }

    @Test("归一化常数 510：4x4 棋盘格横向梯度恰为 0.5")
    func sharpnessNormalizationConstant() {
        let pixels: [UInt8] = [
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
        ]
        let result = QualityMetrics.metricFromPixels(data: pixels, width: 4, height: 4)
        // 每行 3 条横向边 × 255，纵向梯度 0；3 行 → 3*3*255 / (3*3*510) = 0.5。
        #expect(abs(result.sharpness - 0.5) < 0.0001)
    }

    // MARK: regionPixels

    @Test("regionPixels 裁剪指定区域（floor/ceil 钳制内）")
    func regionPixelsCrops() throws {
        let data: [UInt8] = [
            0, 1, 2, 3,
            10, 11, 12, 13,
            20, 21, 22, 23,
            30, 31, 32, 33,
        ]
        let region = try #require(QualityMetrics.regionPixels(
            data: data, width: 4, height: 4,
            box: (x: 1, y: 1, width: 2, height: 2)
        ))
        #expect(region.width == 2)
        #expect(region.height == 2)
        #expect(region.pixels == [11, 12, 21, 22])
    }

    @Test("regionPixels floor/ceil：小数框扩展到整数边界")
    func regionPixelsFloorCeil() throws {
        let data: [UInt8] = [
            0, 1, 2, 3,
            10, 11, 12, 13,
            20, 21, 22, 23,
            30, 31, 32, 33,
        ]
        // left=floor(0.9)=0, top=floor(0.9)=0, right=ceil(2.0)=2, bottom=ceil(2.0)=2。
        let region = try #require(QualityMetrics.regionPixels(
            data: data, width: 4, height: 4,
            box: (x: 0.9, y: 0.9, width: 1.1, height: 1.1)
        ))
        #expect(region.width == 2)
        #expect(region.height == 2)
        #expect(region.pixels == [0, 1, 10, 11])
    }

    @Test("regionPixels 越界钳制到整图")
    func regionPixelsClamps() throws {
        let data: [UInt8] = (0..<16).map(UInt8.init)
        let region = try #require(QualityMetrics.regionPixels(
            data: data, width: 4, height: 4,
            box: (x: -5, y: -5, width: 100, height: 100)
        ))
        #expect(region.width == 4)
        #expect(region.height == 4)
        #expect(region.pixels == data)
    }

    @Test("regionPixels 区域 < 2x2 返回 nil")
    func regionPixelsTooSmall() {
        let data: [UInt8] = (0..<16).map(UInt8.init)
        #expect(QualityMetrics.regionPixels(
            data: data, width: 4, height: 4,
            box: (x: 0, y: 0, width: 1, height: 1)
        ) == nil)
        #expect(QualityMetrics.regionPixels(
            data: data, width: 4, height: 4,
            box: (x: 0, y: 0, width: 2, height: 1)
        ) == nil)
        #expect(QualityMetrics.regionPixels(
            data: data, width: 4, height: 4,
            box: (x: 0, y: 0, width: 1, height: 2)
        ) == nil)
    }

    // MARK: 模型常量

    @Test("QualityModel 常量与旧 QualityService 逐字一致")
    func modelConstants() {
        #expect(QualityModel.modelId == "technical-quality")
        #expect(QualityModel.modelVersion == "1")
        #expect(QualityModel.analyzeConcurrency == 6)
        #expect(QualityModel.inChunkSize == 400)
    }
}
