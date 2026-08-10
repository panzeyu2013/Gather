// desktop/native/gather-core/Sources/GatherCore/Face/Detector.swift
// Phase 2 任务 2.2「人脸推理（ONNX → Vision）」：Vision 检测器。
//
// TS 源：desktop/src/main/services/face-kw/face-detector.ts（重写）
//   能力契约对齐：DetectedFace { bbox(归一化 x,y,w,h), landmarks(5 点归一化),
//   confidence }；detectFacesMultiScale 的多尺度语义由 Vision 内部处理，
//   单次请求即覆盖（无 SCRFD 多 stride 概念）。
//
// 重写说明：
//   - 检测用 VNDetectFaceRectanglesRequest（macOS 14+ 平台，含
//     VNDetectFaceLandmarksRequest 不再需要——Vision 检测结果自带
//     boundingBox + confidence；landmarks 通过 VNDetectFaceLandmarksRequest
//     可选获取，本实现暂不启用，landmarks 为 nil，与 TS 的可选字段一致）；
//   - bbox 为归一化坐标（Vision 左下原点 → 转换为左上原点，与 TS 一致）；
//   - Vision 无置信度阈值参数（检测质量内部固定），confidenceThreshold
//     在结果后过滤（保留 TS 调用方语义）；
//   - maxDetections 在结果后截断（Vision 无上限参数）。
//
// 仅 macOS（Vision 框架）；Linux 构建时整个文件被 canImport 条件排除。

#if canImport(Vision)
import Foundation
import Vision
import CoreGraphics

/// 检测到的人脸（对齐 TS DetectedFace）。
public struct DetectedFace: Equatable, Sendable {
    /// 归一化 x, y, width, height（左上原点，与 TS bbox 一致）。
    public let bbox: [Double]
    /// 五点归一化关键点（当前 Vision 管线不启用，恒为 nil）。
    public let landmarks: [[Double]]?
    public let confidence: Double

    public init(bbox: [Double], landmarks: [[Double]]?, confidence: Double) {
        self.bbox = bbox
        self.landmarks = landmarks
        self.confidence = confidence
    }
}

public enum FaceDetectorError: Error, Equatable {
    case cannotCreateImageSource
    case invalidPixelData
    case visionRequestFailed(String)
}

/// Vision 人脸检测（重写自 face-detector.ts 的 SCRFD ONNX 检测）。
public enum FaceDetector {
    /// 检测图片中的人脸。imageData 为任意 ImageIO 可解码的图片字节
    /// （JPEG/PNG/HEIC/RAW 等，含 EXIF 方向；Vision 自动处理方向）。
    public static func detectFaces(
        in imageData: Data,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100
    ) throws -> [DetectedFace] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FaceDetectorError.cannotCreateImageSource
        }
        return try detectFaces(in: image, confidenceThreshold: confidenceThreshold, maxDetections: maxDetections)
    }

    /// 检测 CGImage 中的人脸（供上层复用已解码像素，避免重复解码）。
    public static func detectFaces(
        in image: CGImage,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100
    ) throws -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceDetectorError.visionRequestFailed(error.localizedDescription)
        }
        let observations = request.results ?? []
        var faces: [DetectedFace] = []
        for observation in observations {
            let confidence = Double(observation.confidence)
            guard confidence >= confidenceThreshold else { continue }
            // Vision boundingBox 为左下原点归一化；转为左上原点（y 翻转）。
            let box = observation.boundingBox
            let x = Double(box.origin.x)
            let y = 1.0 - Double(box.origin.y) - Double(box.size.height)
            faces.append(DetectedFace(
                bbox: [x, y, Double(box.size.width), Double(box.size.height)],
                landmarks: nil,
                confidence: confidence
            ))
            if faces.count >= maxDetections { break }
        }
        return faces
    }
}
#endif
