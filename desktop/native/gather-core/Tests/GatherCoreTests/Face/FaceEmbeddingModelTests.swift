// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceEmbeddingModelTests.swift
// 嵌入模型接缝测试（ADR-029 决策 1 的模型层）：
//   · Vision 默认实现的规格指纹必须与 FaceEncoder 常量一致（否则缓存键与真实模型脱钩）；
//   · 归一化契约（L2 单位向量）与实测维度；
//   · 模型形态校验（纯函数，覆盖 CoreML 之外也能测的判定逻辑）；
//   · 工厂：空路径 → Vision；坏路径/坏扩展名 → 明确报错；缓存与文件指纹失效；
//   · 端到端：配置了不可加载的模型时 analyzeBatch **必须抛错**（禁止静默回退，
//     否则两种向量空间会混进同一列且不报错）。
//
// 覆盖边界（文档化）：`CoreMLFaceEmbedder` 的真实推理路径没有可用的 .mlmodel 夹具，
// 无法在单测中执行（需要用户提供 ArcFace/SFace 模型）；本文件覆盖其**判定与错误路径**，
// 首次接入真实模型时必须人工验证一次 embedding 维度与归一化。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherCore

struct FaceEmbeddingModelTests {
    // ── 测试图片 ──

    /// 生成带渐变的图片（FeaturePrint 需要纹理；纯色图也可，但渐变更接近真实分布）。
    /// phase 用来生成**内容不同**的第二张图（见 visionEmbeddingDependsOnInput）。
    private func makeGradientImage(width: Int = 224, height: Int = 224, phase: Double = 0) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EmbeddingTestError("CGContext 创建失败") }
        for x in stride(from: 0, to: width, by: 4) {
            for y in stride(from: 0, to: height, by: 4) {
                let r = CGFloat(x) / CGFloat(width)
                let g = CGFloat(y) / CGFloat(height)
                let b = CGFloat(0.5 + 0.5 * sin((Double(x + y) / 32.0) + phase))
                context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        guard let image = context.makeImage() else { throw EmbeddingTestError("makeImage 失败") }
        return image
    }

    private func makeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EmbeddingTestError("destination 创建失败")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EmbeddingTestError("finalize 失败") }
        return data as Data
    }

    private struct EmbeddingTestError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    private struct FakeEmbedder: FaceEmbeddingProvider {
        let spec: FaceEmbeddingSpec
        let value: [Double]
        func embed(alignedFace: CGImage) throws -> [Double] { value }
    }

    // ── Vision 默认实现 ──

    @Test func visionSpecMatchesEncoderConstants() {
        let spec = VisionFeaturePrintEmbedder().spec
        // 规格指纹必须与 FaceEncoder 常量逐字一致：服务层把它写进 analysis_signature，
        // 两者一旦漂移，缓存键就与真实模型脱钩（旧向量会被当新向量复用）。
        #expect(spec.signature == FaceEncoder.embeddingSpec)
        #expect(spec.modelId == FaceEncoder.modelId)
        #expect(spec.modelVersion == FaceEncoder.modelVersion)
        #expect(spec.weightHash == nil)
        #expect(spec.dimension == VisionFeaturePrintEmbedder.dimension)
    }

    @Test func visionEmbedderReturnsUnitVectorOfDeclaredDimension() throws {
        let image = try makeGradientImage()
        let embedding = try VisionFeaturePrintEmbedder().embed(alignedFace: image)
        let dimension = VisionFeaturePrintEmbedder.dimension
        #expect(embedding.count == dimension)
        let norm = embedding.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1.0) < 1e-6)
    }

    // ── 形态校验（纯函数）──


    /// R1 审查缺口：只断言"维度对、模长为 1"时，一个**忽略输入**的实现（永远返回同一向量）
    /// 也能全绿。这里用两张内容不同的图要求两个向量不重合——嵌入必须是输入的函数。
    @Test func visionEmbeddingDependsOnInput() throws {
        let embedder = VisionFeaturePrintEmbedder()
        let first = try embedder.embed(alignedFace: try makeGradientImage(phase: 0))
        let second = try embedder.embed(alignedFace: try makeGradientImage(phase: .pi))
        #expect(first.count == 768)
        #expect(second.count == 768)
        let dot = zip(first, second).reduce(0.0) { $0 + $1.0 * $1.1 }
        #expect(dot < 0.999, "不同图像必须给出不同向量（余弦 \(dot)）——否则实现退化成常量")
    }

    @Test func shapeValidatorAcceptsFlattenableImageOutputs() throws {
        // [1, 512]、[512]、[1, 512, 1, 1] 都是"每张脸一个 512 维向量"的等价写法。
        #expect(try FaceEmbeddingShapeValidator.dimension(
            for: .init(input: .image, outputShape: [1, 512])) == 512)
        #expect(try FaceEmbeddingShapeValidator.dimension(
            for: .init(input: .image, outputShape: [512])) == 512)
        #expect(try FaceEmbeddingShapeValidator.dimension(
            for: .init(input: .image, outputShape: [1, 512, 1, 1])) == 512)
    }

    @Test func shapeValidatorRejectsUnsupportedShapes() {
        // multiarray 输入（Vision 无法按图像喂入）→ 明确报错并给出转换指引。
        #expect(throws: FaceEmbeddingError.unsupportedInput("multiArray")) {
            _ = try FaceEmbeddingShapeValidator.dimension(
                for: .init(input: .multiArray, outputShape: [1, 512]))
        }
        // 维度太小（不是人脸特征）/ 太大（基本是误配的分割模型）。
        #expect(throws: FaceEmbeddingError.invalidOutputShape([1, 32])) {
            _ = try FaceEmbeddingShapeValidator.dimension(
                for: .init(input: .image, outputShape: [1, 32]))
        }
        #expect(throws: FaceEmbeddingError.invalidOutputShape([1, 20000])) {
            _ = try FaceEmbeddingShapeValidator.dimension(
                for: .init(input: .image, outputShape: [1, 20000]))
        }
        // 多维度输出：不是"一个向量"，拒绝而不是猜。
        #expect(throws: FaceEmbeddingError.invalidOutputShape([1, 8, 8])) {
            _ = try FaceEmbeddingShapeValidator.dimension(
                for: .init(input: .image, outputShape: [1, 8, 8]))
        }
        // 错误信息必须可操作（指向 image 输入类型）。
        let message = FaceEmbeddingError.unsupportedInput("multiArray").description
        #expect(message.contains("image"))
    }

    @Test func shapeFlatteningDropsLeadingBatchAndTrailingOnes() {
        #expect(FaceEmbeddingModelShape(input: .image, outputShape: [1, 512, 1, 1])
            .effectiveDimensions == [512])
        #expect(FaceEmbeddingModelShape(input: .image, outputShape: [512, 1])
            .effectiveDimensions == [512])
        // 不以 1 开头的形状不当作 batch 维剔除。
        #expect(FaceEmbeddingModelShape(input: .image, outputShape: [3, 512])
            .effectiveDimensions == [3, 512])
    }

    // ── CoreML 规格指纹 ──

    @Test func coreMLSpecSignatureTracksWeightsAndVersion() {
        let a = FaceEmbeddingSpec.coreML(
            modelId: "arcface-r100", modelVersion: "w600k", dimension: 512, weightHash: "aabbccdd")
        let b = FaceEmbeddingSpec.coreML(
            modelId: "arcface-r100", modelVersion: "w600k", dimension: 512, weightHash: "11223344")
        let c = FaceEmbeddingSpec.coreML(
            modelId: "arcface-r100", modelVersion: "w600k-v2", dimension: 512, weightHash: "aabbccdd")
        // 同名同版本但换了权重 → 指纹必须不同（否则旧向量会被当新向量复用）。
        #expect(a.signature != b.signature)
        #expect(a.signature != c.signature)
        #expect(a.modelId.hasPrefix("coreml-"))
        #expect(a.weightHash == "aabbccdd")
    }

    // ── 工厂 ──

    @Test func factoryFallsBackToVisionForEmptyPath() throws {
        #expect(try FaceEmbeddingModelFactory.make(modelPath: "", modelVersion: "").spec
            == VisionFeaturePrintEmbedder().spec)
        // 纯空白也算"未配置"。
        #expect(try FaceEmbeddingModelFactory.make(modelPath: "   ", modelVersion: "x").spec
            == VisionFeaturePrintEmbedder().spec)
        #expect(try FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "")
            .signature == FaceEncoder.embeddingSpec)
    }

    @Test func factoryThrowsForMissingOrWrongFormatModel() throws {
        FaceEmbeddingModelFactory.cache.removeAll()
        let missing = "/tmp/gather-not-a-model-\(UUID().uuidString).mlmodel"
        #expect(throws: FaceEmbeddingError.modelNotFound(missing)) {
            _ = try FaceEmbeddingModelFactory.make(modelPath: missing, modelVersion: "v1")
        }
        // 存在但不是 CoreML 模型：必须报"格式不支持"，不能悄悄回退 Vision。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let onnx = dir.appendingPathComponent("face.onnx")
        try Data([0x00, 0x01, 0x02]).write(to: onnx)
        #expect(throws: FaceEmbeddingError.unsupportedModelFormat("onnx")) {
            _ = try FaceEmbeddingModelFactory.make(modelPath: onnx.path, modelVersion: "v1")
        }
    }

    @Test func cacheReusesProviderAndInvalidatesOnFileChange() throws {
        let cache = FaceEmbeddingModelFactory.Cache()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-embed-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("model.mlmodel")
        try Data(repeating: 0x01, count: 16).write(to: file)

        let counter = LockedCounter()
        let loader: FaceEmbeddingModelFactory.Cache.Loader = { _, version in
            counter.increment()
            return FakeEmbedder(
                spec: FaceEmbeddingSpec(
                    modelId: "fake", modelVersion: version, dimension: 4, signature: "fake"),
                value: [0.5, 0.5, 0.5, 0.5])
        }

        let first = try cache.provider(forPath: file.path, version: "v1", loader: loader)
        let second = try cache.provider(forPath: file.path, version: "v1", loader: loader)
        #expect(counter.value == 1)         // 命中缓存，不重复加载
        #expect(first.spec == second.spec)

        // 换版本 → 不同缓存键；换文件内容（大小/时间戳变化）→ 也失效重载。
        _ = try cache.provider(forPath: file.path, version: "v2", loader: loader)
        #expect(counter.value == 2)
        try Data(repeating: 0x02, count: 64).write(to: file)
        _ = try cache.provider(forPath: file.path, version: "v1", loader: loader)
        #expect(counter.value == 3)
    }

    // ── 端到端：配置错误必须失败，禁止静默回退 ──

    @Test func engineFailsFastWhenConfiguredModelIsUnloadable() async throws {
        let image = try makeJPEG(try makeGradientImage())
        let missing = "/tmp/gather-missing-\(UUID().uuidString).mlmodel"
        let engine = FaceInferenceEngine(config: FaceInferenceConfig(
            faceEmbeddingModelPath: missing,
            faceEmbeddingModelVersion: "v1"))
        await #expect(throws: FaceEmbeddingError.modelNotFound(missing)) {
            _ = try await engine.analyzeBatch(images: [image])
        }
    }

    @Test func inferenceConfigCarriesEmbeddingModelSettings() {
        let base = FaceInferenceConfig()
        #expect(base.faceEmbeddingModelPath == "")
        #expect(base.faceEmbeddingModelVersion == "")
        let configured = FaceInferenceConfig(
            faceEmbeddingModelPath: "/tmp/x.mlmodel", faceEmbeddingModelVersion: "v9")
        #expect(configured != base)     // 参与等值判定（配置变了就是不同配置）
        #expect(configured.faceEmbeddingModelPath == "/tmp/x.mlmodel")
    }
}

/// 线程安全计数器（loader 可能在并发上下文中被调用）。
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
