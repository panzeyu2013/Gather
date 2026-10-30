// desktop/native/gather-core/Tests/GatherCoreTests/Services/PreviewAnalysisTests.swift
// P1 下一波 §3.9：挑片可视化纯函数的金样（直方图 / 合焦图 / AF 几何 / 裁剪 / 参考对比）。
//
// 全部用**合成像素**做金样：不读任何图片 fixture，也不依赖 ImageIO——
// 这既是设计里"只吃已加载预览像素"的直接结果，也让用例在 CI 上稳定。
//
// 覆盖（§3.9.7）：
// - 直方图：全黑 / 全白 / 棋盘 / 渐变 → bin 分布与 clipping 百分比；
// - 合焦图：纯色 → 全 0；棋盘 → 高频全 1；阈值边界；
// - AF：网格点几何 + 人脸中心回退 + 无数据；
// - 裁剪框：角度 0/90/负角度归一、越界夹取、全画幅判定；
// - 参考对比：分割线位置 ↔ 视图坐标、镜像、缩放同步。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherAnalysis

// MARK: - 像素夹具

private func solid(_ value: UInt8, width: Int = 8, height: Int = 8) -> PreviewPixels {
    var rgba = [UInt8](repeating: value, count: width * height * 4)
    // alpha 恒不透明（直方图/合焦图都不读 alpha，这里只求像素缓冲合法）。
    for index in 0..<(width * height) {
        rgba[index * 4 + 3] = 255
    }
    return PreviewPixels(width: width, height: height, rgba: rgba)
}

private func checkerboard(_ width: Int = 8, _ height: Int = 8) -> PreviewPixels {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value: UInt8 = (x + y) % 2 == 0 ? 0 : 255
            let base = (y * width + x) * 4
            rgba[base] = value
            rgba[base + 1] = value
            rgba[base + 2] = value
            rgba[base + 3] = 255
        }
    }
    return PreviewPixels(width: width, height: height, rgba: rgba)
}

private func horizontalGradient(width: Int = 256) -> PreviewPixels {
    var rgba = [UInt8](repeating: 0, count: width * 4)
    for x in 0..<width {
        let value = UInt8(min(255, x))
        let base = x * 4
        rgba[base] = value
        rgba[base + 1] = value
        rgba[base + 2] = value
        rgba[base + 3] = 255
    }
    return PreviewPixels(width: width, height: 1, rgba: rgba)
}

// MARK: - 直方图

@Suite("PreviewHistogram 金样")
struct PreviewHistogramTests {
    @Test("全黑：全部落在第 0 bin，死黑 100%")
    func allBlack() {
        let histogram = PreviewAnalysis.histogram(solid(0), bins: 64)
        #expect(histogram.bins == 64)
        #expect(histogram.sampleCount == 64)
        #expect(histogram.luminance.first == 1)
        #expect(histogram.luminance.dropFirst().allSatisfy { $0 == 0 })
        #expect(histogram.shadowClip == 1)
        #expect(histogram.highlightClip == 0)
    }

    @Test("全白：全部落在最后一 bin，溢出 100%")
    func allWhite() {
        let histogram = PreviewAnalysis.histogram(solid(255), bins: 64)
        #expect(histogram.luminance.last == 1)
        #expect(histogram.highlightClip == 1)
        #expect(histogram.shadowClip == 0)
    }

    @Test("棋盘：死黑 + 溢出 = 100%，其余 bin 为空")
    func checkerboardClips() {
        let histogram = PreviewAnalysis.histogram(checkerboard(), bins: 64)
        #expect(abs(histogram.shadowClip + histogram.highlightClip - 1) < 1e-9)
        #expect(abs(histogram.shadowClip - 0.5) < 1e-9)
        #expect(histogram.luminance.first == 0.5)
        #expect(histogram.luminance.last == 0.5)
    }

    @Test("渐变：每个 bin 均匀（256 像素 / 64 bin）")
    func gradientUniform() {
        let histogram = PreviewAnalysis.histogram(horizontalGradient(), bins: 64)
        #expect(histogram.sampleCount == 256)
        let expected = 1.0 / 64.0
        for value in histogram.luminance {
            #expect(abs(value - expected) < 1e-9)
        }
        // 渐变包含 0 与 255 两个端点像素：它们本来就算溢出/死黑（1/256）。
        #expect(abs(histogram.shadowClip - 1.0 / 256.0) < 1e-9)
        #expect(abs(histogram.highlightClip - 1.0 / 256.0) < 1e-9)
    }

    @Test("RGB 三通道分别统计")
    func channels() {
        var rgba = [UInt8](repeating: 0, count: 4 * 4)
        // 4 个像素：纯红 / 纯绿 / 纯蓝 / 黑。
        rgba[0] = 255; rgba[3] = 255
        rgba[5] = 255; rgba[7] = 255
        rgba[10] = 255; rgba[11] = 255
        rgba[15] = 255
        let pixels = PreviewPixels(width: 4, height: 1, rgba: rgba)
        let histogram = PreviewAnalysis.histogram(pixels, bins: 64)
        #expect(abs((histogram.red.last ?? 0) - 0.25) < 1e-9)
        #expect(abs((histogram.green.last ?? 0) - 0.25) < 1e-9)
        #expect(abs((histogram.blue.last ?? 0) - 0.25) < 1e-9)
        // 纯红/纯绿/纯蓝都触顶（任一通道 255）→ 溢出 75%。
        #expect(abs(histogram.highlightClip - 0.75) < 1e-9)
    }

    @Test("非法像素尺寸：返回空直方图而不是崩")
    func malformedPixels() {
        let pixels = PreviewPixels(width: 4, height: 4, rgba: [0, 0, 0])
        #expect(PreviewAnalysis.histogram(pixels).isEmpty)
        #expect(PreviewAnalysis.focusMap(pixels).isEmpty)
    }

    @Test("降采样不放大")
    func downsampleNeverUpscales() {
        let pixels = solid(10, width: 4, height: 3)
        let sampled = PreviewAnalysis.downsample(pixels, maxDimension: 256)
        #expect(sampled.width == 4)
        #expect(sampled.height == 3)
    }
}

// MARK: - 合焦图

@Suite("FocusMap / FocusMask 金样")
struct FocusMapTests {
    @Test("纯色：局部方差恒 0 → 全 0")
    func solidHasZeroVariance() {
        for value in [UInt8(0), 128, 255] {
            let map = PreviewAnalysis.focusMap(solid(value, width: 16, height: 16))
            #expect(map.width == 16)
            #expect(map.height == 16)
            #expect(map.values.allSatisfy { $0 == 0 })
            #expect(map.normalization == 0)
            let mask = PreviewAnalysis.focusMask(
                map, parameters: FocusMaskParameters(threshold: 0.55, maxDimension: 320)
            )
            #expect(mask.focusedFraction == 0)
        }
    }

    @Test("棋盘：高频区域归一化后接近 1，掩膜全开")
    func checkerboardIsFocused() {
        let map = PreviewAnalysis.focusMap(checkerboard(16, 16))
        #expect(map.isEmpty == false)
        #expect(map.normalization > 0)
        #expect(map.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect((map.values.max() ?? 0) > 0.99)
        let mask = PreviewAnalysis.focusMask(
            map, parameters: FocusMaskParameters(threshold: 0.55, maxDimension: 320)
        )
        #expect(mask.width == 16)
        #expect(mask.height == 16)
        #expect(mask.focusedFraction == 1)
    }

    @Test("阈值边界：0 全开，1 只留满分像素")
    func thresholdBoundary() {
        let map = PreviewAnalysis.focusMap(checkerboard(8, 8))
        let zero = PreviewAnalysis.focusMask(
            map, parameters: FocusMaskParameters(threshold: 0, maxDimension: 320)
        )
        #expect(zero.focusedFraction == 1)
        let high = PreviewAnalysis.focusMask(
            map, parameters: FocusMaskParameters(threshold: 1, maxDimension: 1)
        )
        // maxDimension 被夹到下限 16，仍只有满分格子算 1。
        #expect(high.focusedFraction <= 1)
        #expect(high.threshold == 1)
    }

    @Test("掩膜按区域取最大值降采样：细碎合焦区不被采样漏掉")
    func maskUsesMaxPooling() {
        // 64×64 全 0，只有中心一个亮点。
        var values = [Double](repeating: 0, count: 64 * 64)
        values[32 * 64 + 32] = 1
        let map = FocusMap(width: 64, height: 64, values: values, normalization: 1)
        // maxDimension 下限 16（掩膜分辨率不能被调用方压到无意义的大小）。
        let mask = PreviewAnalysis.focusMask(
            map, parameters: FocusMaskParameters(threshold: 0.55, maxDimension: 16)
        )
        #expect(mask.width == 16)
        #expect(mask.height == 16)
        #expect(mask.focusedFraction > 0)
        #expect(mask.focusedFraction < 0.1)
    }
}

// MARK: - AF 几何

@Suite("AFPoint 几何与回退")
struct AFPointTests {
    @Test("网格索引 → 格中心；镜像按列翻转")
    func gridPoint() {
        let grid = AFGrid(columns: 3, rows: 3)
        let first = AFPointExtractor.gridPoint(index: 0, grid: grid)
        #expect(abs((first?.x ?? 0) - 1.0 / 6.0) < 1e-9)
        #expect(abs((first?.y ?? 0) - 1.0 / 6.0) < 1e-9)
        let center = AFPointExtractor.gridPoint(index: 4, grid: grid)
        #expect(abs((center?.x ?? 0) - 0.5) < 1e-9)
        #expect(abs((center?.y ?? 0) - 0.5) < 1e-9)
        let last = AFPointExtractor.gridPoint(index: 8, grid: grid)
        #expect(abs((last?.y ?? 0) - 5.0 / 6.0) < 1e-9)
        let mirrored = AFGrid(columns: 3, rows: 3, mirrored: true)
        let point = AFPointExtractor.gridPoint(index: 0, grid: mirrored)
        #expect(abs((point?.x ?? 0) - (1 - 1.0 / 6.0)) < 1e-9)
        #expect(AFPointExtractor.gridPoint(index: 9, grid: grid) == nil)
        #expect(AFPointExtractor.gridPoint(index: -1, grid: grid) == nil)
    }

    @Test("人脸中心回退（并夹取到 0...1）")
    func faceFallback() {
        let point = AFPointExtractor.faceCenter(faceBoxes: [[0.1, 0.2, 0.4, 0.4]])
        #expect(abs((point?.x ?? 0) - 0.3) < 1e-9)
        #expect(abs((point?.y ?? 0) - 0.4) < 1e-9)
        // 非法框跳过，取下一个合法框。
        let second = AFPointExtractor.faceCenter(faceBoxes: [[0.1, 0.1, 0, 0], [0.6, 0.6, 0.2, 0.2]])
        #expect(abs((second?.x ?? 0) - 0.7) < 1e-9)
        #expect(AFPointExtractor.faceCenter(faceBoxes: []) == nil)
    }

    @Test("有 AF 索引 + 已登记机型 → camera；否则回退人脸")
    func resolvePrefersCamera() {
        // 用随机机型名做隔离，避免并行用例看到彼此登记的网格。
        let camera = "TestCam-\(UUID().uuidString)"
        AFPointProfiles.install(AFGrid(columns: 3, rows: 3), for: camera)
        defer { AFPointProfiles.removeAll() }

        let cameraPoint = AFPointExtractor.resolve(
            faceBoxes: [[0.1, 0.1, 0.2, 0.2]],
            cameraModel: camera,
            afIndex: 4
        )
        #expect(cameraPoint?.source == .camera)
        #expect(cameraPoint?.x == 0.5)

        let facePoint = AFPointExtractor.resolve(
            faceBoxes: [[0.1, 0.1, 0.2, 0.2]],
            cameraModel: "UnknownCam",
            afIndex: 4
        )
        #expect(facePoint?.source == .face)

        #expect(AFPointExtractor.resolve(faceBoxes: [], cameraModel: "", afIndex: nil) == nil)
    }

    @Test("AF 点居中位移")
    func centeringOffset() {
        let point = AFPoint(x: 0.25, y: 0.75, source: .face)
        #expect(point.centeringOffset().x == 0.25)
        #expect(point.centeringOffset().y == -0.25)
    }
}

// MARK: - 裁剪

@Suite("CropFrame（crs:Crop* 只读）")
struct CropFrameTests {
    @Test("正常裁剪值原样保留，角度归一")
    func fromLightroom() {
        let crop = CropFrame.fromLightroom(
            angle: 90, left: 0.1, top: 0.2, right: 0.9, bottom: 0.8
        )
        #expect(crop?.left == 0.1)
        #expect(crop?.top == 0.2)
        #expect(abs((crop?.width ?? 0) - 0.8) < 1e-9)
        #expect(abs((crop?.height ?? 0) - 0.6) < 1e-9)
        #expect(crop?.angle == 90)
        #expect(crop?.isRotated == true)
    }

    @Test("越界夹取到 0...1")
    func clamps() {
        // 保留非全画幅，才能观察夹取结果（全画幅且未旋转按设计返回 nil）。
        let crop = CropFrame.fromLightroom(
            angle: nil, left: -2, top: 0.3, right: 5, bottom: 0.9
        )
        #expect(crop?.left == 0)
        #expect(crop?.top == 0.3)
        #expect(crop?.right == 1)
        #expect(crop?.bottom == 0.9)
    }

    @Test("缺字段 / 退化矩形 / 全画幅 → nil（无裁剪标记）")
    func rejectsDegenerate() {
        #expect(CropFrame.fromLightroom(
            angle: nil, left: nil, top: 0, right: 1, bottom: 1
        ) == nil)
        #expect(CropFrame.fromLightroom(
            angle: nil, left: 0.5, top: 0.5, right: 0.5, bottom: 0.5
        ) == nil)
        #expect(CropFrame.fromLightroom(
            angle: 0, left: 0, top: 0, right: 1, bottom: 1
        ) == nil)
        // 全画幅但有角度 → 保留（要显示角度徽标）。
        #expect(CropFrame.fromLightroom(
            angle: -3.5, left: 0, top: 0, right: 1, bottom: 1
        )?.angle == -3.5)
    }

    @Test("负角度 / 大于 180 的角度归一到 (-180, 180]")
    func angleNormalization() {
        #expect(CropFrame.normalizedAngle(0) == 0)
        #expect(CropFrame.normalizedAngle(180) == 180)
        #expect(CropFrame.normalizedAngle(181) == -179)
        #expect(CropFrame.normalizedAngle(-180) == 180)
        #expect(CropFrame.normalizedAngle(540) == 180)
        #expect(CropFrame.normalizedAngle(.nan) == 0)
    }

    @Test("显示全图：矩形回到全画幅，角度保留")
    func showingFullFrame() {
        let crop = CropFrame(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9, angle: 4)
        let full = crop.showingFullFrame(true)
        #expect(full.isFullFrame)
        #expect(full.angle == 4)
        #expect(crop.showingFullFrame(false) == crop)
    }
}

// MARK: - 参考对比几何

@Suite("ReferenceCompareGeometry")
struct ReferenceCompareGeometryTests {
    @Test("分割线夹取与映射")
    func splitMapping() {
        #expect(ReferenceCompareGeometry.clampedSplit(0.5) == 0.5)
        #expect(ReferenceCompareGeometry.clampedSplit(-1) == 0.05)
        #expect(ReferenceCompareGeometry.clampedSplit(2) == 0.95)
        #expect(ReferenceCompareGeometry.splitFraction(dragX: 400, viewWidth: 800) == 0.5)
        #expect(ReferenceCompareGeometry.splitFraction(dragX: 100, viewWidth: 0) == 0.5)
        #expect(ReferenceCompareGeometry.splitX(fraction: 0.5, viewWidth: 800) == 400)
        #expect(ReferenceCompareGeometry.splitX(fraction: 0.5, viewWidth: 0) == 0)
    }

    @Test("主/参考交换与缩放同步")
    func swapAndZoom() {
        #expect(ReferenceCompareGeometry.mirroredSplit(0.25) == 0.75)
        #expect(ReferenceCompareGeometry.synchronizedZoom(0.5) == 1)
        #expect(ReferenceCompareGeometry.synchronizedZoom(3) == 3)
        #expect(ReferenceCompareGeometry.synchronizedZoom(12) == 8)
        #expect(ReferenceCompareGeometry.synchronizedZoom(.nan) == 1)
    }
}

// MARK: - 端口适配

@Suite("PreviewAnalysisAdapter")
struct PreviewAnalysisAdapterTests {
    @Test("适配器与纯函数结果一致")
    func adapterMatchesPureFunctions() {
        let adapter = PreviewAnalysisAdapter()
        let pixels = checkerboard(8, 8)
        let viaAdapter = adapter.histogram(pixels, bins: 64)
        let direct = PreviewAnalysis.histogram(pixels, bins: 64)
        #expect(viaAdapter == direct)

        let mask = adapter.focusMask(
            pixels, parameters: FocusMaskParameters(threshold: 0.55, maxDimension: 320)
        )
        let expected = PreviewAnalysis.focusMask(
            PreviewAnalysis.focusMap(pixels),
            parameters: FocusMaskParameters(threshold: 0.55, maxDimension: 320)
        )
        #expect(mask == expected)

        let point = adapter.afPoint(
            faceBoxes: [[0.2, 0.4, 0.2, 0.2]], cameraModel: "", afIndex: nil
        )
        #expect(point?.source == .face)
    }
}
