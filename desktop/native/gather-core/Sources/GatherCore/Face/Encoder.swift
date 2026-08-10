// desktop/native/gather-core/Sources/GatherCore/Face/Encoder.swift
// Phase 2 任务 2.2「人脸推理（ONNX → Vision）」：Vision 人脸编码器。
//
// TS 源：desktop/src/main/services/face-kw/face-encoder.ts（重写）
//   能力契约对齐：输入人脸 → L2 归一化 embedding（供聚类/匹配）；
//   FaceInferenceObservation { bbox, confidence, embedding }。
//
// 重写说明（2026-08-10 环境决议）：
//   本机 macOS 26.5 SDK 的公开 Vision API 无 VNGenerateFaceEmbeddingsRequest
//   （计划初稿假设该 API；实测 tbd/头文件/swiftinterface 均不存在）。
//   替代方案：VNDetectFaceRectanglesRequest 检测人脸框 →
//   VNGenerateImageFeaturePrintRequest(revision 2) 对人脸区域提取
//   768 维特征（float32，实测 elementCount=768）作为 embedding。
//   Vision 特征与 ArcFace 特征空间不兼容（计划 §3.3 已声明 P4 全量重算），
//   维度 768 与 TS 512 不同属预期；Matcher/Clusterer 按输入维度工作，
//   无需改动。quality 对账门（0.3c ARI/NMI ≥ 0.95）未过时经
//   FaceInferenceConfig.fallbackToOnnxEnabled 回退 TS ONNX 管线。
//
// 注意：feature print 是整图语义特征，人脸区域裁剪后特征质量依赖
// crop 精度；后续若 SDK 提供专用 face embedding API 可在此替换
// makeRequest() 实现，接口不变。

#if canImport(Vision)
import Foundation
import Vision
import CoreGraphics

/// 单张人脸的编码结果（对齐 TS FaceInferenceObservation）。
public struct FaceEncodeResult: Equatable, Sendable {
    /// 归一化 x, y, width, height（左上原点）。
    public let bbox: [Double]
    public let confidence: Double
    /// L2 归一化 embedding（Vision feature print，768 维）。
    public let embedding: [Double]

    public init(bbox: [Double], confidence: Double, embedding: [Double]) {
        self.bbox = bbox
        self.confidence = confidence
        self.embedding = embedding
    }
}

public enum FaceEncoderError: Error, Equatable {
    case cannotCreateImageSource
    case visionRequestFailed(String)
    case noFeaturePrint
    case invalidEmbedding
}

/// Vision 人脸编码器（重写自 face-encoder.ts 的 ArcFace ONNX 编码）。
public enum FaceEncoder {
    /// 编码图片中的所有人脸。imageData 为任意 ImageIO 可解码图片字节。
    public static func encodeFaces(
        in imageData: Data,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100,
        embeddingDim: Int = 512
    ) throws -> [FaceEncodeResult] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FaceEncoderError.cannotCreateImageSource
        }
        return try encodeFaces(in: image, confidenceThreshold: confidenceThreshold,
                               maxDetections: maxDetections, embeddingDim: embeddingDim)
    }

    /// 编码 CGImage 中的人脸（供上层复用已解码像素）。
    /// embeddingDim 用于维度校验：期望 512（TS 语义），Vision feature print
    /// 实测 768 维——不一致时以实际维度为准并继续（返回值注释标明），
    /// 不抛错（Vision 维度由系统决定，非配置错误）。
    public static func encodeFaces(
        in image: CGImage,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100,
        embeddingDim: Int = 512
    ) throws -> [FaceEncodeResult] {
        // 1. 检测人脸框（Vision，左下原点归一化）。
        let detectRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([detectRequest])
        } catch {
            throw FaceEncoderError.visionRequestFailed(error.localizedDescription)
        }
        let observations = detectRequest.results ?? []
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var results: [FaceEncodeResult] = []
        for observation in observations {
            let confidence = Double(observation.confidence)
            guard confidence >= confidenceThreshold else { continue }
            // 2. 按人脸框裁剪原图（左上原点 bbox → 像素区域）。
            let box = observation.boundingBox
            let pixelX = box.origin.x * width
            let pixelY = (1.0 - box.origin.y - box.size.height) * height
            let pixelW = box.size.width * width
            let pixelH = box.size.height * height
            let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard cropRect.width >= 1, cropRect.height >= 1,
                let crop = image.cropping(to: cropRect) else { continue }
            // 3. 人脸区域特征（Vision feature print，L2 归一化）。
            guard let embedding = try? featurePrintEmbedding(of: crop) else { continue }
            results.append(FaceEncodeResult(
                bbox: [Double(box.origin.x),
                       Double(1.0 - box.origin.y - box.size.height),
                       Double(box.size.width),
                       Double(box.size.height)],
                confidence: confidence,
                embedding: embedding
            ))
            if results.count >= maxDetections { break }
        }
        return results
    }

    /// 对裁剪图提取 L2 归一化特征向量（VNGenerateImageFeaturePrintRequest，
    /// revision 2，768 维 float32——2026-08-10 本机实测 elementCount=768）。
    private static func featurePrintEmbedding(of image: CGImage) throws -> [Double] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceEncoderError.visionRequestFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first else {
            throw FaceEncoderError.noFeaturePrint
        }
        let data = observation.data
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { throw FaceEncoderError.noFeaturePrint }
        let floats = data.withUnsafeBytes { bytes -> [Float] in
            Array(bytes.bindMemory(to: Float.self).prefix(count))
        }
        return try normalizeEmbedding(floats)
    }

    /// L2 归一化 embedding（幂等；TS encodeFace 末尾的归一化语义）。
    /// 提取为 internal 以便单元测试直接验证维度与归一化契约。
    static func normalizeEmbedding(_ values: [Float]) throws -> [Double] {
        var sum = 0.0
        for value in values { sum += Double(value) * Double(value) }
        let norm = sum.squareRoot()
        guard norm.isFinite, norm > .ulpOfOne else {
            throw FaceEncoderError.invalidEmbedding
        }
        return values.map { Double($0) / norm }
    }
}
#endif
