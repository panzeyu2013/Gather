// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceAlignmentTests.swift
// 人脸 5 点对齐 + 质量评分（竞品对标改造）的单元测试。
// 覆盖：
//   · 相似变换闭式解（已知变换可还原、退化输入拒绝）；
//   · 模板/估算点的坐标语义（Vision 左下原点 → 左上原点像素）；
//   · 仿射重采样矩阵（S ∘ T ∘ F）——用像素级探针验证 y 方向无多余翻转；
//   · 质量评分构成与 IoU 配对。
import Foundation
import Testing
import CoreGraphics
@testable import GatherDomain
@testable import GatherProtocol
@testable import GatherAnalysis

struct FaceAlignmentTests {
    // MARK: - 相似变换

    @Test("已知相似变换可被闭式解精确还原")
    func similarityTransformRecoversKnownTransform() throws {
        let source: [(x: Double, y: Double)] = [
            (10, 20), (50, 22), (30, 45), (18, 70), (44, 71),
        ]
        // 绕原点旋转 20°、缩放 1.3、平移 (7, -3)。
        let scale = 1.3
        let theta = 20.0 * Double.pi / 180
        let a = scale * cos(theta)
        let b = scale * sin(theta)
        let tx = 7.0
        let ty = -3.0
        let target = source.map { point -> (x: Double, y: Double) in
            (a * point.x - b * point.y + tx, b * point.x + a * point.y + ty)
        }

        let recovered = try #require(FaceAligner.similarityTransform(from: source, to: target))
        #expect(abs(recovered.a - a) < 1e-9)
        #expect(abs(recovered.b - b) < 1e-9)
        #expect(abs(recovered.tx - tx) < 1e-9)
        #expect(abs(recovered.ty - ty) < 1e-9)
        #expect(abs(recovered.scale - scale) < 1e-9)
        #expect(abs(recovered.rollDegrees - 20) < 1e-9)
        for point in source {
            let mapped = recovered.apply(x: point.x, y: point.y)
            let expected = (a * point.x - b * point.y + tx, b * point.x + a * point.y + ty)
            #expect(abs(mapped.x - expected.0) < 1e-9)
            #expect(abs(mapped.y - expected.1) < 1e-9)
        }
    }

    @Test("退化输入返回 nil（点数不足 / 点重合 / 数量不匹配）")
    func similarityTransformRejectsDegenerateInput() {
        #expect(FaceAligner.similarityTransform(from: [(x: 1, y: 1)], to: [(x: 2, y: 2)]) == nil)
        let same = Array(repeating: (x: 5.0, y: 5.0), count: 5)
        #expect(FaceAligner.similarityTransform(from: same, to: FaceAlignmentTemplate.points) == nil)
        #expect(FaceAligner.similarityTransform(
            from: FaceAlignmentTemplate.points,
            to: Array(FaceAlignmentTemplate.points.prefix(3))) == nil)
    }

    @Test("模板点全部落在 112×112 画布内且双眼水平")
    func templateStaysInsideCanvas() {
        #expect(FaceAlignmentTemplate.size == 112)
        for point in FaceAlignmentTemplate.points {
            #expect(point.x >= 0 && point.x < 112)
            #expect(point.y >= 0 && point.y < 112)
        }
        let leftEye = FaceAlignmentTemplate.points[0]
        let rightEye = FaceAlignmentTemplate.points[1]
        #expect(abs(leftEye.y - rightEye.y) < 1)          // 双眼近乎水平
        #expect(rightEye.x - leftEye.x > 30)              // 眼距约 35px
        #expect(FaceAlignmentTemplate.points[2].y > leftEye.y)   // 鼻在眼下方
        #expect(FaceAlignmentTemplate.points[3].y > FaceAlignmentTemplate.points[2].y) // 嘴在鼻下方
    }

    // MARK: - 坐标语义（Vision 左下原点 → 左上原点像素）

    @Test("bbox 估算点使用左上原点像素坐标")
    func estimatedPointsUseTopLeftPixelSpace() {
        // Vision 归一化 bbox（左下原点）：x 0.25、y 0.25、宽高 0.5 → 图像 400×400 下
        // 左上原点像素：x0=100、（1 - (0.25+0.5)）×400 = 100 为顶边，宽高各 200。
        let points = FaceAligner.estimatedFivePoints(
            normalizedBoundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            imageWidth: 400,
            imageHeight: 400
        )
        #expect(points.count == 5)
        #expect(abs(points[0].x - 160) < 1e-9)   // 0.30·200 + 100
        #expect(abs(points[0].y - 172) < 1e-9)   // 0.36·200 + 100
        #expect(abs(points[1].x - 240) < 1e-9)
        #expect(abs(points[2].y - 210) < 1e-9)   // 鼻 0.55
        #expect(abs(points[3].y - 244) < 1e-9)   // 嘴 0.72
        // 左右对称：左嘴角与右嘴角关于 bbox 中线对称。
        #expect(abs((points[3].x + points[4].x) / 2 - 200) < 1e-9)
    }

    // MARK: - 仿射重采样（像素级）

    /// 构造 100×100 白底图，在"左上原点像素坐标 (px, py)"处画一个黑点。
    private func makeMarkerImage(side: Int = 100, marker: (x: Int, y: Int)) -> CGImage? {
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 255, count: bytesPerRow * side)
        for index in stride(from: 3, to: buffer.count, by: 4) { buffer[index] = 255 }
        let offset = marker.y * bytesPerRow + marker.x * 4
        buffer[offset] = 0
        buffer[offset + 1] = 0
        buffer[offset + 2] = 0
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// 读取图内某点的 RGB（用图像自己的 bytesPerRow，不假设方向）。
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        let r = bytes[offset]
        let g = bytes[offset + 1]
        let b = bytes[offset + 2]
        return (r, g, b)
    }

    @Test("恒等变换必须是像素级无操作（验证合成矩阵没有多余 y 翻转）")
    func identityTransformIsPixelNoOp() throws {
        let source = try #require(makeMarkerImage(marker: (x: 30, y: 40)))
        let identity = FaceSimilarityTransform(a: 1, b: 0, tx: 0, ty: 0)
        let output = try #require(FaceAligner.alignedCrop(source, transform: identity, size: 100))
        #expect(output.width == 100 && output.height == 100)
        // 标记点必须仍在读取器视角的同一行；若合成矩阵错翻一次，会出现在 99-40=59 行。
        let marker = try #require(pixel(output, x: 30, y: 40))
        #expect(marker.r < 40 && marker.g < 40 && marker.b < 40)
        let flipped = try #require(pixel(output, x: 30, y: 59))
        #expect(flipped.r > 200)
    }

    @Test("平移变换按左上原点语义移动像素")
    func translationMovesPixelsAsExpected() throws {
        let source = try #require(makeMarkerImage(marker: (x: 10, y: 10)))
        let shifted = FaceSimilarityTransform(a: 1, b: 0, tx: 12, ty: 25)
        let output = try #require(FaceAligner.alignedCrop(source, transform: shifted, size: 100))
        let expected = try #require(pixel(output, x: 22, y: 35))
        #expect(expected.r < 40)
        // 平移后源图覆盖 [12,112)×[25,125)：区域内远离标记处应为白色；
        // 区域外（如原点）是画布透明底，不能拿"白"来断言。
        let inside = try #require(pixel(output, x: 62, y: 75))
        #expect(inside.r > 200 && inside.g > 200 && inside.b > 200)
    }

    @Test("滚转角与缩放从变换中读出")
    func rollAndScaleReadout() {
        let transform = FaceSimilarityTransform(a: 0, b: 2, tx: 0, ty: 0)
        #expect(abs(transform.scale - 2) < 1e-12)
        #expect(abs(transform.rollDegrees - 90) < 1e-9)
        let aligned = FaceAlignmentOutcome(
            crop: Self.onePixelImage(),
            geometry: FaceLandmarkGeometry(fivePoints: [], usedLandmarks: false),
            transform: transform
        )
        // 回退路径（无关键点）不报告滚转，避免把估算点的假角度写进质量分。
        #expect(aligned.rollDegrees == 0)
    }

    private static func onePixelImage() -> CGImage {
        let bytesPerRow = 4
        var buffer = [UInt8](repeating: 255, count: bytesPerRow)
        for index in stride(from: 3, to: buffer.count, by: 4) { buffer[index] = 255 }
        let provider = CGDataProvider(data: Data(buffer) as CFData)!
        return CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

struct FaceQualityTests {
    @Test("尺寸分：短边 96px 满分，0 分下限")
    func sizeScore() {
        #expect(FaceQuality.sizeScore(faceSizePx: 0) == 0)
        #expect(FaceQuality.sizeScore(faceSizePx: -5) == 0)
        #expect(FaceQuality.sizeScore(faceSizePx: 48) == 0.5)
        #expect(FaceQuality.sizeScore(faceSizePx: 96) == 1)
        #expect(FaceQuality.sizeScore(faceSizePx: 400) == 1)
    }

    @Test("滚转分：≤15° 满分、≥45° 归零、中间线性")
    func rollScore() {
        #expect(FaceQuality.rollScore(rollDegrees: 0) == 1)
        #expect(FaceQuality.rollScore(rollDegrees: -15) == 1)
        #expect(abs(FaceQuality.rollScore(rollDegrees: 30) - 0.5) < 1e-9)
        #expect(FaceQuality.rollScore(rollDegrees: 45) == 0)
        #expect(FaceQuality.rollScore(rollDegrees: 90) == 0)
    }

    @Test("综合分：权重 0.4/0.4/0.2，且采集质量可用时取代检测置信度")
    func compositeScore() {
        let perfect = FaceQuality.composite(
            confidence: 1, faceSizePx: 96, rollDegrees: 0, captureQuality: nil)
        #expect(abs(perfect - 1) < 1e-12)

        // 只看置信度项：尺寸 0、滚转 90°（0 分）→ 0.4·conf。
        let confidenceOnly = FaceQuality.composite(
            confidence: 0.9, faceSizePx: 0, rollDegrees: 90, captureQuality: nil)
        #expect(abs(confidenceOnly - 0.36) < 1e-12)

        // captureQuality 优先于 confidence：0.4·0.8 + 0.4·1 + 0.2·1 = 0.92。
        let capture = FaceQuality.composite(
            confidence: 0, faceSizePx: 96, rollDegrees: 0, captureQuality: 0.8)
        #expect(abs(capture - 0.92) < 1e-12)

        // 越界输入被钳制。
        let clamped = FaceQuality.composite(
            confidence: 5, faceSizePx: 96, rollDegrees: 0, captureQuality: 3)
        #expect(clamped <= 1)
    }

    @Test("IoU：完全重合 1、完全分离 0、半重叠可算")
    func intersectionOverUnion() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        // 同框 IoU = 1（RGBA 浮点上会有 ~1e-16 级误差，用容差而非 ==）。
        #expect(abs(FaceQuality.intersectionOverUnion(box, box) - 1) < 1e-9)
        #expect(FaceQuality.intersectionOverUnion(
            box, CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1)) == 0)
        // 平移半个宽度：交 0.2×0.4 = 0.08，并 0.16 + 0.16 − 0.08 = 0.24 → 1/3。
        let shifted = CGRect(x: 0.4, y: 0.2, width: 0.4, height: 0.4)
        #expect(abs(FaceQuality.intersectionOverUnion(box, shifted) - 1.0 / 3) < 1e-9)
    }
}
