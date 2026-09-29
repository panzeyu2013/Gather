// desktop/native/gather-core/Sources/GatherCore/Face/Inference.swift
// Phase 2 任务 2.2「人脸推理（ONNX → Vision）」：推理管线。
//
// TS 源：desktop/src/main/services/face-kw/face-inference-worker.ts
//       + face-inference-worker-client.ts（重写）
//       + face-kw.service.ts 的批处理段（line 314-519，语义对齐）
//
// 重写说明（Swift 并发模型重设计）：
//   - TS 为 worker_threads + 消息协议（init/analyzeBatch/shutdown），Swift
//     为同进程 Actor：FaceInferenceEngine 持有 Vision 请求生命周期，
//     analyzeBatch 按图逐张处理，进度经回调流式上报，取消经 Task 取消传播；
//   - 批语义与 TS 一致：单张图失败不影响整批（per-image error 记录到
//     item.error），编码失败计数保留（encodingFailures）；
//   - 与 face-kw.service 的语义对齐点：
//       · 输入为 JPEG/PNG 等解码字节（上层已 getPreview 解码，对应
//         preview.buffer）；
//       · 每图独立 try（corrupt frame 不拖垮批次）；
//       · 进度 current: 已处理张数, total: 总张数（face.detect 阶段）；
//       · 取消检查发生在每张图处理边界（TS 的 signal.aborted 检查点）。
//   - Vision 无「会话初始化」概念（无模型加载），init 恒成功；provider/
//     fallbackToOnnx 开关保留在 FaceInferenceConfig 供上层路由。

#if canImport(Vision)
import Foundation
import Vision

/// 单张图片的人脸推理结果（对齐 TS FaceInferenceBatchItem）。
public struct FaceInferenceBatchItem: Equatable, Sendable {
    /// 单图失败信息（其余图片不受影响）；nil 表示成功。
    public let error: String?
    public let observations: [FaceEncodeResult]
    /// 检测到但嵌入失败的人脸数（模型不可用/输入不受支持/输出维度不符时为非零；
    /// 上层据此避免把"编码全失败"当成"这张照片没有脸"）。
    public let encodingFailures: Int

    public init(error: String? = nil, observations: [FaceEncodeResult] = [], encodingFailures: Int = 0) {
        self.error = error
        self.observations = observations
        self.encodingFailures = encodingFailures
    }
}

public enum FaceInferenceError: Error, Equatable {
    case cancelled
}

/// 人脸推理引擎（重写自 FaceInferenceWorker 的线程池模型）。
/// Actor 串行化内部状态：一次分析运行独占引擎（TS 的 worker 亦为串行
/// 消息循环）；并发分析由上层各自创建引擎实例（对齐 TS 按 worker 实例
/// 排队 + 池化的语义）。
public actor FaceInferenceEngine {
    private let config: FaceInferenceConfig
    /// 服务层注入的嵌入实例（nil = 按 config 自行解析）。
    private let injectedEmbedder: FaceEmbeddingProvider?

    /// - Parameter embedder: 可选注入的嵌入实例。由服务层每次运行创建一次并透传，
    ///   保证"写进 analysis_signature 的规格"与"真正用来推理的模型"是**同一个对象**：
    ///   否则签名算完后模型文件被替换，本次运行会用 A 的签名标注 B 的向量（对抗验证 V1
    ///   指出的混写窗口）。为 nil 时按 config 自行解析（空路径 → 内置 Vision）。
    public init(config: FaceInferenceConfig = FaceInferenceConfig(),
                embedder: FaceEmbeddingProvider? = nil) {
        self.config = config
        self.injectedEmbedder = embedder
    }

    /// 推理一批图片。图片为 ImageIO 可解码字节（如上层 getPreview 的
    /// JPEG buffer）。进度回调按处理顺序调用（current: 已处理, total: 总数）。
    /// 取消：Task 取消传播，取消点在每张图处理前。
    public func analyzeBatch(
        images: [Data],
        onProgress: ((current: Int, total: Int)) -> Void = { _ in }
    ) async throws -> [FaceInferenceBatchItem] {
        // 嵌入实例：优先用服务层注入的（与 analysis_signature 同源）；否则按配置解析
        // （空路径 = 内置 Vision 特征；配置了模型却不可加载 → 抛错，绝不静默回退：
        // 混用两套向量空间会让后续所有阈值失去意义且不报错）。
        let embedder = try injectedEmbedder ?? FaceEmbeddingModelFactory.make(
            modelPath: config.faceEmbeddingModelPath,
            modelVersion: config.faceEmbeddingModelVersion
        )
        var results: [FaceInferenceBatchItem] = []
        results.reserveCapacity(images.count)
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            let item: FaceInferenceBatchItem
            do {
                // 用带失败计数的入口：失败数要一路带到服务层（判断"这张照片编码全失败"，
                // 从而不写 analysis_state、不删旧簇与绑定——见 Encoder.FaceEncodeBatch）。
                let batch = try FaceEncoder.encodeFacesDetailed(
                    in: image,
                    confidenceThreshold: config.confidenceThreshold,
                    maxDetections: config.maxDetections,
                    embeddingDim: config.embeddingDim,
                    embedder: embedder
                )
                item = FaceInferenceBatchItem(
                    observations: batch.faces, encodingFailures: batch.encodeFailures)
            } catch {
                item = FaceInferenceBatchItem(error: "\(error)")
            }
            results.append(item)
            onProgress((index + 1, images.count))
        }
        return results
    }
}
#endif
