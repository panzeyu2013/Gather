// desktop/native/gather-core/Sources/GatherCore/Face/Alignment.swift
// 人脸 5 点对齐（竞品对标：Immich ArcFace 5 点 → 112×112、PhotoPrism YuNet 5 关键点 → 112×112）。
//
// 背景：本仓此前的 embedding 直接按检测框（bbox）裁剪，无关键点、无对齐——
// 侧脸、头部滚转（roll）、bbox 抖动都会让同一人的特征漂移。竞品的共识做法是
// 用 5 个关键点（双眼中心、鼻尖、双嘴角）对模板做**最小二乘相似变换**（含尺度、
// 仅旋转不镜像），再在 112×112 上裁剪/重采样后送识别模型。
//
// 本文件只做「几何」：关键点提取 → 相似变换 → 仿射重采样。模型仍由
// FaceEncoder 决定（当前为 Vision FeaturePrint，将来可换 CoreML 的 ArcFace/SFace，
// 接口不变）。
//
// 坐标系约定（易错点，集中说明一次）：
//   · Vision 的关键点/检测框是**左下原点、归一化**；本文件对外一律转成
//     **左上原点、像素**（与 CGImage.cropping、UI 一致）。
//   · 相似变换定义在「左上原点像素」空间：q ≈ A·p + t，A = [[a, -b], [b, a]]。
//   · 仿射重采样时 CGContext 的用户空间是左下原点，故合成矩阵为
//     S ∘ T ∘ F（S = 源图上下翻转、F = 目标上下翻转），见 affineTransform(for:size:)。
import CoreGraphics
import Foundation

#if canImport(Vision)
import Vision

/// 对齐目标：ArcFace 标准 112×112 五点模板（像素坐标，左上原点）。
/// 数值取自 ArcFace 官方 reference（112×112 输入的标准 5 点）。
public enum FaceAlignmentTemplate {
    /// 对齐后的人脸边长（像素）。
    public static let size = 112
    /// 左眼中心、右眼中心、鼻尖、左嘴角、右嘴角。
    public static let points: [(x: Double, y: Double)] = [
        (38.2946, 51.6963),
        (73.5318, 51.5014),
        (56.0252, 71.7366),
        (41.5493, 92.3655),
        (70.7299, 92.2041),
    ]
}

/// 二维相似变换（含尺度、仅旋转不镜像）：`q = A·p + t`，`A = [[a, -b], [b, a]]`。
public struct FaceSimilarityTransform: Equatable, Sendable {
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

    /// 作用在左上原点像素坐标上。
    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x - b * y + tx, b * x + a * y + ty)
    }

    /// 滚转角（度）：atan2(b, a)。正值 = 图像右侧较低（顺时针倾斜）。
    public var rollDegrees: Double {
        atan2(b, a) * 180 / Double.pi
    }

    /// 缩放系数 s = √(a² + b²)。
    public var scale: Double {
        (a * a + b * b).squareRoot()
    }

    /// 左上原点像素空间的 CGAffineTransform 形式（CG 用 [a b; c d; tx ty]，点 = 行向量）。
    public var cgTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }
}

/// 一次关键点提取的结果。
public struct FaceLandmarkGeometry: Equatable, Sendable {
    /// 左上原点像素坐标，顺序固定：左眼、右眼、鼻尖、左嘴角、右嘴角（按 x 排序，镜像无关）。
    public let fivePoints: [(x: Double, y: Double)]
    /// true = 来自 Vision 关键点；false = 关键点缺失，按 bbox 比例估算（回退路径）。
    public let usedLandmarks: Bool

    public init(fivePoints: [(x: Double, y: Double)], usedLandmarks: Bool) {
        self.fivePoints = fivePoints
        self.usedLandmarks = usedLandmarks
    }

    public static func == (lhs: FaceLandmarkGeometry, rhs: FaceLandmarkGeometry) -> Bool {
        lhs.usedLandmarks == rhs.usedLandmarks &&
            zip(lhs.fivePoints, rhs.fivePoints).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 }
    }
}

/// 一次对齐裁剪的结果。
public struct FaceAlignmentOutcome: Sendable {
    /// 112×112 对齐裁剪。
    public let crop: CGImage
    public let geometry: FaceLandmarkGeometry
    public let transform: FaceSimilarityTransform

    public init(crop: CGImage, geometry: FaceLandmarkGeometry, transform: FaceSimilarityTransform) {
        self.crop = crop
        self.geometry = geometry
        self.transform = transform
    }

    /// 滚转角（度），取自关键点连线（回退路径为 0）。
    public var rollDegrees: Double {
        geometry.usedLandmarks ? transform.rollDegrees : 0
    }
}

public enum FaceAligner {
    // MARK: - 关键点

    /// 提取 5 点（左上原点像素）。关键点缺失时按 bbox 比例估算并标记 usedLandmarks = false。
    public static func landmarkPoints(
        for observation: VNFaceObservation,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> FaceLandmarkGeometry {
        let size = CGSize(width: imageWidth, height: imageHeight)
        let landmarks = observation.landmarks

        func regionCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let points = region.pointsInImage(imageSize: size)
            guard !points.isEmpty else { return nil }
            var sumX = 0.0
            var sumY = 0.0
            for point in points {
                sumX += Double(point.x)
                sumY += Double(point.y)
            }
            return CGPoint(x: sumX / Double(points.count), y: sumY / Double(points.count))
        }

        /// 嘴部两个嘴角 = 区域里 x 最小 / x 最大的点（Vision 的 left/right 是主体左右，
        /// 自拍镜像时与图像 x 序不一致，故一律按 x 排序，保证与模板左右一致）。
        func xExtremes(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region, region.pointCount >= 2 else { return [] }
            let points = region.pointsInImage(imageSize: size)
            guard let minPoint = points.min(by: { $0.x < $1.x }),
                let maxPoint = points.max(by: { $0.x < $1.x }) else { return [] }
            return [minPoint, maxPoint]
        }

        let leftEye = regionCenter(landmarks?.leftEye)
        let rightEye = regionCenter(landmarks?.rightEye)
        let nose = regionCenter(landmarks?.nose) ?? regionCenter(landmarks?.noseCrest)
        let mouthCorners = xExtremes(landmarks?.outerLips)

        if let leftEye, let rightEye, let nose, mouthCorners.count == 2 {
            let eyes = [leftEye, rightEye].sorted { $0.x < $1.x }
            let ordered: [CGPoint] = [eyes[0], eyes[1], nose, mouthCorners[0], mouthCorners[1]]
            // Vision 为左下原点：y_top = imageHeight - y_vision。
            let five = ordered.map { (x: Double($0.x), y: Double(imageHeight) - Double($0.y)) }
            return FaceLandmarkGeometry(fivePoints: five, usedLandmarks: true)
        }

        return FaceLandmarkGeometry(
            fivePoints: estimatedFivePoints(
                normalizedBoundingBox: observation.boundingBox,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            ),
            usedLandmarks: false
        )
    }

    /// 无关键点时的 5 点估算（bbox 比例；内联常量按正面人脸统计比例：
    /// 眼距 ≈ 0.40·w、眼高 ≈ 0.36·h、鼻 ≈ 0.55·h、嘴 ≈ 0.72·h）。
    public static func estimatedFivePoints(
        normalizedBoundingBox box: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [(x: Double, y: Double)] {
        let x0 = Double(box.minX) * Double(imageWidth)
        let width = Double(box.width) * Double(imageWidth)
        // Vision 左下原点 → 左上原点的顶部 y。
        let top = (1 - Double(box.maxY)) * Double(imageHeight)
        let height = Double(box.height) * Double(imageHeight)
        func point(_ fx: Double, _ fy: Double) -> (x: Double, y: Double) {
            (x: x0 + fx * width, y: top + fy * height)
        }
        return [
            point(0.30, 0.36),
            point(0.70, 0.36),
            point(0.50, 0.55),
            point(0.36, 0.72),
            point(0.64, 0.72),
        ]
    }

    // MARK: - 相似变换

    /// 最小二乘相似变换（闭式解，等价 Umeyama 含尺度且不镜像）。
    /// 目标：min Σ|q_i − (A·p_i + t)|²，A = [[a, −b], [b, a]]。
    /// 解：a = Σ(q'·p') / Σ|p'|²，b = Σ(q'_y·p'_x − q'_x·p'_y) / Σ|p'|²（p'、q' 为去均值后的点）。
    /// 点数 < 2 或源点退化为一点时返回 nil（不可解）。
    public static func similarityTransform(
        from source: [(x: Double, y: Double)],
        to target: [(x: Double, y: Double)]
    ) -> FaceSimilarityTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }

        let n = Double(source.count)
        let meanPX = source.reduce(0) { $0 + $1.x } / n
        let meanPY = source.reduce(0) { $0 + $1.y } / n
        let meanQX = target.reduce(0) { $0 + $1.x } / n
        let meanQY = target.reduce(0) { $0 + $1.y } / n

        var dot = 0.0
        var cross = 0.0
        var denom = 0.0
        for i in 0..<source.count {
            let px = source[i].x - meanPX
            let py = source[i].y - meanPY
            let qx = target[i].x - meanQX
            let qy = target[i].y - meanQY
            dot += qx * px + qy * py
            cross += qy * px - qx * py
            denom += px * px + py * py
        }
        guard denom.isFinite, denom > 1e-12 else { return nil }

        let a = dot / denom
        let b = cross / denom
        guard a.isFinite, b.isFinite else { return nil }
        let tx = meanQX - (a * meanPX - b * meanPY)
        let ty = meanQY - (b * meanPX + a * meanPY)
        return FaceSimilarityTransform(a: a, b: b, tx: tx, ty: ty)
    }

    /// 源图（左上原点像素）→ 目标 112×112（左上原点像素）的 CG 合成矩阵：`D ∘ T ∘ F`。
    ///
    /// 推导（CG 用行向量、`concatenating` 左先右后）：
    ///   · `CGContext.draw(image, in: rect(0,0,W,H))` 把源图像素 p（左上原点）映到用户空间
    ///     `u = p·D`，其中 `D = [1,0,0,-1,0,H]`（源图上下翻转，H = 源图高度）；
    ///   · 目标像素 d（左上原点）映到设备空间 `d·F`，`F = [1,0,0,-1,0,size]`；
    ///   · 要求 `device = T(p)·F`，而 `device = p·D·CTM` ⇒ `CTM = D·T·F`（D 自逆）。
    /// 漏掉 D 的 `ty = H` 会把整张图画出画布（恒等变换必须是无操作，见单测）。
    public static func affineTransform(
        for transform: FaceSimilarityTransform,
        imageHeight: CGFloat,
        size: Int = FaceAlignmentTemplate.size
    ) -> CGAffineTransform {
        let side = CGFloat(size)
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: imageHeight)
        let flipTarget = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: side)
        return flipSource.concatenating(transform.cgTransform).concatenating(flipTarget)
    }

    /// 按变换重采样出 112×112 对齐人脸（高质量插值）。
    public static func alignedCrop(
        _ image: CGImage,
        transform: FaceSimilarityTransform,
        size: Int = FaceAlignmentTemplate.size
    ) -> CGImage? {
        let side = CGFloat(size)
        guard side >= 1 else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(affineTransform(for: transform, imageHeight: CGFloat(image.height), size: size))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        return context.makeImage()
    }

    /// 端到端：检测结果 → 5 点 → 相似变换 → 112×112 对齐裁剪。
    /// 无法求解变换（关键点退化）时回退到按 bbox 直接裁剪（`bboxCrop`），保持可用性。
    public static func align(
        _ image: CGImage,
        observation: VNFaceObservation,
        size: Int = FaceAlignmentTemplate.size,
        bboxCrop: CGImage? = nil
    ) -> FaceAlignmentOutcome? {
        let geometry = landmarkPoints(
            for: observation,
            imageWidth: CGFloat(image.width),
            imageHeight: CGFloat(image.height)
        )
        let template = FaceAlignmentTemplate.points
        guard let transform = similarityTransform(from: geometry.fivePoints, to: template) else {
            guard let crop = bboxCrop else { return nil }
            // 变换不可解时保留 bbox 裁剪；几何信息仍原样返回（调用方据 usedLandmarks 判断）。
            let identity = FaceSimilarityTransform(a: 1, b: 0, tx: 0, ty: 0)
            return FaceAlignmentOutcome(crop: crop, geometry: geometry, transform: identity)
        }
        guard let crop = alignedCrop(image, transform: transform, size: size) else {
            guard let crop = bboxCrop else { return nil }
            return FaceAlignmentOutcome(crop: crop, geometry: geometry, transform: transform)
        }
        return FaceAlignmentOutcome(crop: crop, geometry: geometry, transform: transform)
    }
}
#endif
