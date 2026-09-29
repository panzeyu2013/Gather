// desktop/native/gather-core/Sources/GatherCore/Face/Encoder.swift
// Phase 2 任务 2.2「人脸推理（ONNX → Vision）」：Vision 人脸编码器。
//
// TS 源：desktop/src/main/services/face-kw/face-encoder.ts（重写）
//   能力契约对齐：输入人脸 → L2 归一化 embedding（供聚类/匹配）；
//   FaceInferenceObservation { bbox, confidence, embedding }。
//
// 2026-09-28 算法改造（竞品对标：Immich ArcFace 5 点 → 112×112、PhotoPrism YuNet 5 关键点 → 112×112）：
//   本机 macOS SDK 无 VNGenerateFaceEmbeddingsRequest，故嵌入仍用
//   VNGenerateImageFeaturePrintRequest（revision 2，实测 768 维 float32）。
//   但**不再直接按 bbox 裁剪整脸**：改为
//     ① VNDetectFaceLandmarksRequest 取 5 点（双眼中心、鼻尖、双嘴角）；
//     ② FaceAligner 做最小二乘相似变换（含尺度、不镜像）到 ArcFace 112×112 模板；
//     ③ 在 112×112 对齐图上取特征（关键点缺失才回退 bbox 裁剪）。
//   同时用 VNDetectFaceCaptureQualityRequest 取系统人脸采集质量，与尺寸/滚转合成为
//   quality（见 FaceQuality）——供聚类核心点判定与低质量过滤。
//
// 缓存失效：`FaceEncoder.embeddingSpec` 必须随"对齐方式/特征模型"任何变化而变，
// 它写入 face_observations.model_id/model_version 并参与 analysis_signature；
// 旧 observation 因此被判定过期并重算（PhotoPrism 的 faces migrate 语义，
// 但不需要单独命令：下一次分析即迁移）。
//
// 已知偏差（文档化）：默认 FeaturePrint 是通用图像特征，与 ArcFace/SFace 特征空间
// 不兼容；维度 768 与 TS 契约 512 不同属预期（Matcher/Clusterer 按输入维度工作，
// 且 embedding_dim 落库可检测换模型）。
//
// 模型层已可插拔（见 EmbeddingModel.swift）：设置 face_embedding_model_path 指向
// ArcFace/SFace 的 .mlmodel(c) 即切换为专用模型，无需改编码器；规格指纹随模型与
// 权重变化，旧观测自动判过期重算。

#if canImport(Vision)
import Foundation
import Vision
import CoreGraphics

/// 单张人脸的编码结果（对齐 TS FaceInferenceObservation）。
public struct FaceEncodeResult: Equatable, Sendable {
    /// 归一化 x, y, width, height（左上原点）。
    public let bbox: [Double]
    public let confidence: Double
    /// L2 归一化 embedding（Vision feature print，768 维；维度以实际为准）。
    public let embedding: [Double]
    /// 综合质量 [0,1]（FaceQuality.composite）。
    public let quality: Double
    /// bbox 短边像素（PhotoPrism FACE_SIZE 同义）。
    public let faceSizePx: Double
    /// 头部滚转角（度）；关键点缺失时为 0。
    public let rollDegrees: Double
    /// Vision 人脸采集质量（0..1）；请求失败或未匹配到框时为 nil。
    public let captureQuality: Double?
    /// true = 走了 5 点对齐；false = 关键点缺失，按 bbox 回退裁剪。
    public let aligned: Bool
    /// 产出该 embedding 的模型标识与版本（来自 embedder.spec；随换模型而变，
    /// 落库到 face_observations.model_id/model_version）。
    public let modelId: String
    public let modelVersion: String

    public init(
        bbox: [Double],
        confidence: Double,
        embedding: [Double],
        quality: Double = 0,
        faceSizePx: Double = 0,
        rollDegrees: Double = 0,
        captureQuality: Double? = nil,
        aligned: Bool = false,
        modelId: String = FaceEncoder.modelId,
        modelVersion: String = FaceEncoder.modelVersion
    ) {
        self.bbox = bbox
        self.confidence = confidence
        self.embedding = embedding
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.rollDegrees = rollDegrees
        self.captureQuality = captureQuality
        self.aligned = aligned
        self.modelId = modelId
        self.modelVersion = modelVersion
    }
}

public enum FaceEncoderError: Error, Equatable {
    case cannotCreateImageSource
    case visionRequestFailed(String)
    case invalidEmbedding
}

/// Vision 人脸编码器（重写自 face-encoder.ts 的 ArcFace ONNX 编码）。
public enum FaceEncoder {
    /// 嵌入规格指纹（写入 model_id/model_version 并参与 analysis_signature）。
    public static let embeddingSpec = "vision-featureprint-rev2-aligned112-v1"
    public static let modelId = "vision-featureprint"
    public static let modelVersion = "rev2-aligned112-v1"
    /// 对齐人脸边长（ArcFace 模板）。
    public static let alignedFaceSize = FaceAlignmentTemplate.size

    /// 一次编码的完整结果：成功的人脸 + **编码失败数**。
    /// 为什么必须单独报失败：此前逐脸 `try?` 吞掉错误，上层会把"检测到脸但全部编码失败"
    /// 当成"这张照片真的没有脸"，于是写 analysis_state（不再重试）并清掉旧簇与人工绑定
    /// （对抗审查阻断项 2：模型配置错一次就会静默摧毁用户工作）。
    public struct FaceEncodeBatch: Equatable, Sendable {
        public let faces: [FaceEncodeResult]
        /// 检测到、但嵌入失败的人脸数（模型不可用、输入不受支持、输出维度不符等）。
        public let encodeFailures: Int
        /// 通过置信度筛选的人脸总数（= 成功 + 失败）。
        public var detectedFaces: Int { faces.count + encodeFailures }

        public init(faces: [FaceEncodeResult], encodeFailures: Int) {
            self.faces = faces
            self.encodeFailures = encodeFailures
        }
    }

    /// 编码图片中的所有人脸。imageData 为任意 ImageIO 可解码图片字节。
    public static func encodeFaces(
        in imageData: Data,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100,
        embeddingDim: Int = 512,
        embedder: FaceEmbeddingProvider = VisionFeaturePrintEmbedder()
    ) throws -> [FaceEncodeResult] {
        try encodeFacesDetailed(
            in: imageData, confidenceThreshold: confidenceThreshold,
            maxDetections: maxDetections, embeddingDim: embeddingDim, embedder: embedder
        ).faces
    }

    /// 带失败计数的编码入口（推理管线用；`encodeFaces` 是丢弃该计数的便捷重载）。
    public static func encodeFacesDetailed(
        in imageData: Data,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100,
        embeddingDim: Int = 512,
        embedder: FaceEmbeddingProvider = VisionFeaturePrintEmbedder()
    ) throws -> FaceEncodeBatch {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FaceEncoderError.cannotCreateImageSource
        }
        return try encodeFacesDetailed(
            in: image, confidenceThreshold: confidenceThreshold, maxDetections: maxDetections,
            embeddingDim: embeddingDim, embedder: embedder)
    }

    /// 编码 CGImage 中的人脸（供上层复用已解码像素）。
    /// embeddingDim 保留为调用方契约参数：Vision 维度由系统决定，实际维度以 embedding.count 为准
    /// （落库到 face_observations.embedding_dim，换模型/换 SDK 时可检测）。
    public static func encodeFaces(
        in image: CGImage,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100,
        embeddingDim: Int = 512,
        embedder: FaceEmbeddingProvider = VisionFeaturePrintEmbedder()
    ) throws -> [FaceEncodeResult] {
        try encodeFacesDetailed(
            in: image, confidenceThreshold: confidenceThreshold, maxDetections: maxDetections,
            embeddingDim: embeddingDim, embedder: embedder
        ).faces
    }

    /// 编码 CGImage 中的人脸（带失败计数；实现体）。
    public static func encodeFacesDetailed(
        in image: CGImage,
        confidenceThreshold: Double = 0.5,
        maxDetections: Int = 100,
        embeddingDim: Int = 512,
        embedder: FaceEmbeddingProvider = VisionFeaturePrintEmbedder()
    ) throws -> FaceEncodeBatch {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        // 1. 检测人脸 + 关键点（VNDetectFaceLandmarksRequest 的 results 同时含 bbox 与 landmarks）。
        let detectRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([detectRequest])
        } catch {
            throw FaceEncoderError.visionRequestFailed(error.localizedDescription)
        }
        let observations = detectRequest.results ?? []

        // 1b. 人脸采集质量（可选）：独立请求，失败不影响检测主路径。
        var captureObservations: [VNFaceObservation] = []
        let captureRequest = VNDetectFaceCaptureQualityRequest()
        if (try? handler.perform([captureRequest])) != nil {
            captureObservations = captureRequest.results ?? []
        }

        var results: [FaceEncodeResult] = []
        var encodeFailures = 0
        for observation in observations {
            let confidence = Double(observation.confidence)
            guard confidence >= confidenceThreshold else { continue }

            let box = observation.boundingBox
            let pixelX = box.origin.x * width
            let pixelY = (1.0 - box.origin.y - box.size.height) * height
            let pixelW = box.size.width * width
            let pixelH = box.size.height * height
            let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard cropRect.width >= 1, cropRect.height >= 1 else { continue }
            let bboxCrop = image.cropping(to: cropRect)

            // 2. 5 点对齐 → 112×112（关键点缺失时回退 bbox 裁剪）。
            guard let alignment = FaceAligner.align(
                image,
                observation: observation,
                size: alignedFaceSize,
                bboxCrop: bboxCrop
            ) else { continue }

            // 3. 对齐区域嵌入（默认 Vision feature print；可注入 CoreML 专用模型，见 EmbeddingModel）。
            // 失败必须计数而不是静默丢脸：上层据此判断"这张照片编码全失败"（不写 analysis_state、
            // 保留旧观测与簇），否则模型故障会被当成"没有脸"。
            let embedding: [Double]
            do {
                embedding = try embedder.embed(alignedFace: alignment.crop)
            } catch {
                encodeFailures += 1
                continue
            }

            let faceSizePx = Double(min(cropRect.width, cropRect.height))
            let rollDegrees = alignment.rollDegrees
            let captureQuality = FaceQuality.captureQuality(
                for: box,
                among: captureObservations
            )
            let quality = FaceQuality.composite(
                confidence: confidence,
                faceSizePx: faceSizePx,
                rollDegrees: rollDegrees,
                captureQuality: captureQuality
            )

            results.append(FaceEncodeResult(
                bbox: [Double(box.origin.x),
                       Double(1.0 - box.origin.y - box.size.height),
                       Double(box.size.width),
                       Double(box.size.height)],
                confidence: confidence,
                embedding: embedding,
                quality: quality,
                faceSizePx: faceSizePx,
                rollDegrees: rollDegrees,
                captureQuality: captureQuality,
                aligned: alignment.geometry.usedLandmarks,
                modelId: embedder.spec.modelId,
                modelVersion: embedder.spec.modelVersion
            ))
            // 上限按"检测到并尝试编码"的脸计（含失败），否则模型故障时会白跑整张图。
            if results.count + encodeFailures >= maxDetections { break }
        }
        return FaceEncodeBatch(faces: results, encodeFailures: encodeFailures)
    }

    // 特征提取已移入 EmbeddingModel.swift 的 VisionFeaturePrintEmbedder（默认实现）与
    // CoreMLFaceEmbedder（专用模型）：编码器只负责"检测 + 5 点对齐 + 调用注入的 embedder"，
    // 这样换模型不需要改编码器（ADR-029 决策 1）。

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
