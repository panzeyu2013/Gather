// desktop/native/gather-core/Sources/GatherCore/Face/Preprocessing.swift
// Face 预处理移植（Phase 1 任务 1.5「对账测试框架」第二批）。
//
// TS 源（三个纯函数，行号见各函数注释）：
//   desktop/src/main/services/face-kw/face-detector.ts
//     resolveScrfdLayout（118-134，SCRFD 输出布局解析）
//   desktop/src/main/services/face-kw/face-encoder.ts
//     estimateSimilarityTransform（76-113，五点最小二乘相似变换）
//     alignedArcFaceInput（140-183 核心循环：模板缩放 + 相似变换 +
//       双线性采样 + (pixel - 127.5) / 127.5 归一化；ARCFACE_TEMPLATE 68-74）
// 解码层（sharp / Buffer / onnxruntime）不属于本模块范围：输入直接给像素数组。
//
// 移植说明：
//   - 数值全程用 Double（等价 TS 的 number 双精度运算），仅 alignedArcFaceInput
//     的输出在 Float32Array 语义处收敛到 Float（TS 的 Float32Array 赋值）。
//     运算顺序逐语句一致，可位级对齐（IEEE-754 双精度跨语言确定）。
//   - Number.EPSILON == 2^-52 == Double.ulpOfOne，逐位一致。
//   - 偏差：TS 对 channels<3 的输入会越界读出 undefined → NaN（face-encoder.ts
//     生产路径经 sharp removeAlpha 恒为 3 通道，不触发）；Swift 数组越界会
//     直接崩溃，故此处显式抛错（insufficientChannels）而非复刻 NaN 行为。

import Foundation

public enum FacePreprocessing {
    // face-detector.ts:36-41
    public struct ScrfdLayout: Equatable, Sendable {
        public let featureMaps: Int
        public let strides: [Int]
        public let anchorsPerCell: Int
        public let hasLandmarks: Bool

        public init(featureMaps: Int, strides: [Int], anchorsPerCell: Int, hasLandmarks: Bool) {
            self.featureMaps = featureMaps
            self.strides = strides
            self.anchorsPerCell = anchorsPerCell
            self.hasLandmarks = hasLandmarks
        }
    }

    // face-encoder.ts:61-66
    public struct SimilarityTransform: Equatable, Sendable {
        public let a: Double
        public let b: Double
        public let tx: Double
        public let ty: Double

        public init(a: Double, b: Double, tx: Double, ty: Double) {
            self.a = a
            self.b = b
            self.tx = tx
            self.ty = ty
        }
    }

    /// 五点关键点（双眼、鼻尖、嘴角），对应 TS FaceLandmarks。
    public typealias FaceLandmarks = [[Double]]

    // face-encoder.ts:68-74（ArcFace 对齐模板）
    public static let arcFaceTemplate: FaceLandmarks = [
        [38.2946, 51.6963],
        [73.5318, 51.5014],
        [56.0252, 71.7366],
        [41.5493, 92.3655],
        [70.7299, 92.2041],
    ]

    /// Number.EPSILON（2^-52），见移植说明。
    private static let epsilon = Double.ulpOfOne

    // face-detector.ts:118-134
    public static func resolveScrfdLayout(outputCount: Int) throws -> ScrfdLayout {
        switch outputCount {
        case 6:
            return ScrfdLayout(featureMaps: 3, strides: [8, 16, 32], anchorsPerCell: 2, hasLandmarks: false)
        case 9:
            return ScrfdLayout(featureMaps: 3, strides: [8, 16, 32], anchorsPerCell: 2, hasLandmarks: true)
        case 10:
            return ScrfdLayout(featureMaps: 5, strides: [8, 16, 32, 64, 128], anchorsPerCell: 1, hasLandmarks: false)
        case 15:
            return ScrfdLayout(featureMaps: 5, strides: [8, 16, 32, 64, 128], anchorsPerCell: 1, hasLandmarks: true)
        default:
            throw FacePreprocessingError.unsupportedScrfdLayout(outputCount: outputCount)
        }
    }

    // face-encoder.ts:76-113
    public static func estimateSimilarityTransform(
        source: FaceLandmarks,
        destination: FaceLandmarks
    ) throws -> SimilarityTransform {
        var sourceSum: [Double] = [0, 0]
        for point in source {
            sourceSum[0] += point[0]
            sourceSum[1] += point[1]
        }
        let sourceMean = sourceSum.map { $0 / Double(source.count) }

        var destinationSum: [Double] = [0, 0]
        for point in destination {
            destinationSum[0] += point[0]
            destinationSum[1] += point[1]
        }
        let destinationMean = destinationSum.map { $0 / Double(destination.count) }

        var denominator = 0.0
        var real = 0.0
        var imaginary = 0.0
        for index in 0..<source.count {
            let sx = source[index][0] - sourceMean[0]
            let sy = source[index][1] - sourceMean[1]
            let dx = destination[index][0] - destinationMean[0]
            let dy = destination[index][1] - destinationMean[1]
            denominator += sx * sx + sy * sy
            real += sx * dx + sy * dy
            imaginary += sx * dy - sy * dx
        }
        if denominator <= epsilon {
            throw FacePreprocessingError.degenerateLandmarks
        }

        let a = real / denominator
        let b = imaginary / denominator
        return SimilarityTransform(
            a: a,
            b: b,
            tx: destinationMean[0] - a * sourceMean[0] + b * sourceMean[1],
            ty: destinationMean[1] - b * sourceMean[0] - a * sourceMean[1]
        )
    }

    // face-encoder.ts:140-183 核心循环（输出语义 = TS Float32Array：
    // 每元素以双精度算得后舍入到 Float）
    public static func alignedArcFaceInput(
        data: [UInt8],
        width: Int,
        height: Int,
        channels: Int,
        landmarks: FaceLandmarks,
        size: Int
    ) throws -> [Float] {
        // 见移植说明：TS 对 channels<3 产生 NaN（生产路径恒为 3 通道），Swift 显式抛错。
        guard channels >= 3 else {
            throw FacePreprocessingError.insufficientChannels(channels: channels)
        }

        let templateScale = Double(size) / 112
        let destination: FaceLandmarks = arcFaceTemplate.map { [$0[0] * templateScale, $0[1] * templateScale] }
        let transform = try estimateSimilarityTransform(source: landmarks, destination: destination)
        let determinant = transform.a * transform.a + transform.b * transform.b
        if determinant <= epsilon {
            throw FacePreprocessingError.singularTransform
        }

        let planeSize = size * size
        var input = [Float](repeating: 0, count: planeSize * 3)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - transform.tx
                let dy = Double(y) - transform.ty
                let sourceX = (transform.a * dx + transform.b * dy) / determinant
                let sourceY = (-transform.b * dx + transform.a * dy) / determinant
                let destinationIndex = y * size + x
                for channel in 0..<3 {
                    let pixel = sampleBilinear(
                        data: data,
                        width: width,
                        height: height,
                        channels: channels,
                        x: sourceX,
                        y: sourceY,
                        channel: channel
                    )
                    input[channel * planeSize + destinationIndex] = Float((pixel - 127.5) / 127.5)
                }
            }
        }
        return input
    }

    // face-encoder.ts:115-138
    private static func sampleBilinear(
        data: [UInt8],
        width: Int,
        height: Int,
        channels: Int,
        x: Double,
        y: Double,
        channel: Int
    ) -> Double {
        if x < 0 || y < 0 || x > Double(width - 1) || y > Double(height - 1) { return 0 }
        let x0 = floor(x)
        let y0 = floor(y)
        let x1 = min(Double(width - 1), x0 + 1)
        let y1 = min(Double(height - 1), y0 + 1)
        let wx = x - x0
        let wy = y - y0
        func at(_ px: Int, _ py: Int) -> Double {
            Double(data[(py * width + px) * channels + channel])
        }
        return at(Int(x0), Int(y0)) * (1 - wx) * (1 - wy)
            + at(Int(x1), Int(y0)) * wx * (1 - wy)
            + at(Int(x0), Int(y1)) * (1 - wx) * wy
            + at(Int(x1), Int(y1)) * wx * wy
    }
}

public enum FacePreprocessingError: Error, Equatable {
    case degenerateLandmarks
    case singularTransform
    case insufficientChannels(channels: Int)
    case unsupportedScrfdLayout(outputCount: Int)
}

extension FacePreprocessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .degenerateLandmarks:
            return "Face landmarks are degenerate"
        case .singularTransform:
            return "Face alignment transform is singular"
        case .insufficientChannels(let channels):
            return "Face alignment requires at least 3 channels, received \(channels)"
        case .unsupportedScrfdLayout(let outputCount):
            return "Unsupported SCRFD output signature: expected 6, 9, 10 or 15 tensors, received \(outputCount)"
        }
    }
}
