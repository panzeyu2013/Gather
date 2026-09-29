// desktop/native/gather-core/Sources/GatherCore/Face/Provider.swift
// Phase 2 任务 2.2「人脸推理（ONNX → Vision）」：provider 配置层。
//
// TS 源：desktop/src/main/services/face-kw/provider.ts（重写）
//   + face-inference-fallback.ts（重写，退化策略保留）
//
// 重写说明：TS 的 provider 字符串（'auto'/'coreml'/'cpu'/...）与 ONNX 执行
// 提供方（execution providers）是 ONNX 时代的产物；Vision 框架无模型资产，
// 无需 execution provider 解析。本文件提供：
//   - FaceProvider 枚举：.vision（默认，Vision 框架）/ .cpu（同 vision，
//     语义保留为显式 CPU 请求，实际由 Vision 内部调度）；
//   - 质量不达标回退 ONNX 的开关（fallbackToOnnxEnabled）：0.3c 对账门
//     未过时打开，供上层决定是否仍走旧 ONNX 管线（TS 侧保留）；
//   - 阈值/尺寸默认值（对齐 MODEL_CONFIG：detect inputSize 640 / secondary
//     128 / encode inputSize 112 / embeddingDim 512，Vision 编码维度由系统
//     决定，embeddingDim 仅作兼容校验）。

import Foundation

/// 人脸推理执行提供方（重写自 TS provider.ts 的 provider 字符串）。
public enum FaceProvider: String, Codable, Equatable, Sendable {
    /// Vision 框架（默认；替代 ONNX CoreML EP）。
    case vision
    /// 显式 CPU 请求（Vision 仍为后端；语义保留以兼容调用方配置）。
    case cpu

    /// 解析配置字符串：'auto'/'vision'/'coreml' → .vision；'cpu' → .cpu。
    /// 未知值抛错（TS 的 normalizeProviderName 静默降级，这里显式化，
    /// 因为错误的 provider 配置只会带来难以定位的行为差异）。
    public static func resolve(_ raw: String) throws -> FaceProvider {
        switch raw.lowercased() {
        case "auto", "vision", "coreml", "coremlexecutionprovider":
            return .vision
        case "cpu", "cpuexecutionprovider":
            return .cpu
        default:
            throw FaceProviderError.unknownProvider(raw)
        }
    }
}

public enum FaceProviderError: Error, Equatable {
    case unknownProvider(String)
}

/// 人脸推理参数（重写自 TS MODEL_CONFIG + face-kw.service 的 settings 读取）。
public struct FaceInferenceConfig: Equatable, Sendable {
    /// 检测置信度阈值（TS settings detect_confidence，默认 0.5）。
    public var confidenceThreshold: Double
    /// NMS 阈值（TS nms_threshold，默认 0.4；Vision 自带 NMS，保留字段对齐语义）。
    public var nmsThreshold: Double
    /// 每图最大检测数（TS max_detections，默认 100）。
    public var maxDetections: Int
    /// 编码维度（TS embedding_dim 默认 512；Vision 为固定值，超出则告警）。
    public var embeddingDim: Int
    /// 主检测输入尺寸（TS MODEL_CONFIG.detect.inputSize=640；Vision 内部
    /// 缩放，保留字段对齐语义）。
    public var primaryInputSize: Int
    /// 次级检测输入尺寸（TS 128）。
    public var secondaryInputSize: Int
    /// 编码输入尺寸（TS 112）。
    public var encodeInputSize: Int
    /// 质量不达标回退 ONNX 开关（0.3c 对账门未过时置 true，上层决定路由）。
    public var fallbackToOnnxEnabled: Bool
    /// 专用人脸嵌入模型路径（settings face_embedding_model_path；空 = 内置 Vision 特征）。
    /// 非空但不可加载时推理直接报错——禁止静默回退（会混用两套向量空间，见 EmbeddingModel）。
    public var faceEmbeddingModelPath: String
    /// 模型版本标签（settings face_embedding_model_version），写进 observation 供追溯。
    public var faceEmbeddingModelVersion: String

    public init(
        confidenceThreshold: Double = 0.5,
        nmsThreshold: Double = 0.4,
        maxDetections: Int = 100,
        embeddingDim: Int = 512,
        primaryInputSize: Int = 640,
        secondaryInputSize: Int = 128,
        encodeInputSize: Int = 112,
        fallbackToOnnxEnabled: Bool = false,
        faceEmbeddingModelPath: String = "",
        faceEmbeddingModelVersion: String = ""
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.nmsThreshold = nmsThreshold
        self.maxDetections = maxDetections
        self.embeddingDim = embeddingDim
        self.primaryInputSize = primaryInputSize
        self.secondaryInputSize = secondaryInputSize
        self.encodeInputSize = encodeInputSize
        self.fallbackToOnnxEnabled = fallbackToOnnxEnabled
        self.faceEmbeddingModelPath = faceEmbeddingModelPath
        self.faceEmbeddingModelVersion = faceEmbeddingModelVersion
    }
}
