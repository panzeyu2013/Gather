// desktop/native/gather-core/Sources/GatherCore/Face/EmbeddingModel.swift
// 人脸嵌入模型接缝（ADR-029 决策 1 的**模型层**：把"通用图像特征"换成可选的专业人脸模型）。
//
// 三个实现/入口：
//   · VisionFeaturePrintEmbedder —— 默认（无外部模型）：VNGenerateImageFeaturePrintRequest
//     revision 2，768 维，作用于 112×112 对齐图；
//   · CoreMLFaceEmbedder         —— 专用人脸模型（ArcFace/SFace 等 .mlmodel/.mlmodelc，
//     112×112 图像输入、输出 N 维向量），推理后 L2 归一化；
//   · FaceEmbeddingModelFactory  —— 由设置 face_embedding_model_path/…_version 解析。
//
// 设计约束（改动前请先读）：
//   ① **两套向量空间不得混用**：配置了模型却加载失败时必须抛错，禁止静默回退到 Vision
//      —— 静默回退会把两种分布的 embedding 写进同一列，此后所有阈值（eps/阈值/margin）
//      都失去意义，且错误不报、只表现为"聚类变差"；
//   ② 规格指纹 FaceEmbeddingSpec.signature 参与 analysis_signature：换模型、换权重、
//      换维度后旧观测自动判过期并重算（对照 PhotoPrism 的 faces migrate 命令）；
//   ③ 模型按"路径 + 版本 + 文件指纹"缓存：模型可达数百 MB，禁止逐图重复加载；
//   ④ 输入固定为对齐模板 112×112（FaceAlignmentTemplate.size）：模型若要求其它边长
//      需先扩模板与设置，不允许各自为政地缩放（会让几何与训练分布不一致）。

#if canImport(Vision)
import Foundation
import CoreGraphics
import Vision
#if canImport(CoreML)
import CoreML
#endif

/// 嵌入模型规格（写入 face_observations.model_id/model_version 并参与分析签名）。
public struct FaceEmbeddingSpec: Equatable, Sendable {
    public let modelId: String
    public let modelVersion: String
    /// 输出维度（实际 embedding 长度；用于换模型检测与维度守卫）。
    public let dimension: Int
    /// analysis_signature 用的规格指纹：必须随模型/权重/对齐方式任何变化而变。
    public let signature: String
    /// 权重指纹（SHA-256 前 8 字节十六进制）；内置模型（Vision）为 nil。
    public let weightHash: String?

    public init(
        modelId: String,
        modelVersion: String,
        dimension: Int,
        signature: String,
        weightHash: String? = nil
    ) {
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.dimension = dimension
        self.signature = signature
        self.weightHash = weightHash
    }

    /// CoreML 模型规格：签名含权重指纹，保证"同名同版本但换了权重"也会触发全量重算。
    public static func coreML(
        modelId: String,
        modelVersion: String,
        dimension: Int,
        weightHash: String
    ) -> FaceEmbeddingSpec {
        FaceEmbeddingSpec(
            modelId: "coreml-\(modelId)",
            modelVersion: modelVersion,
            dimension: dimension,
            signature: "coreml-\(modelId)@\(modelVersion):d\(dimension):h\(weightHash)",
            weightHash: weightHash
        )
    }
}

public enum FaceEmbeddingError: Error, Equatable, CustomStringConvertible {
    /// 设置了模型路径但文件不存在。
    case modelNotFound(String)
    /// 扩展名既不是 .mlmodel 也不是 .mlmodelc。
    case unsupportedModelFormat(String)
    /// 模型加载/编译失败（CoreML 的报错原文）。
    case modelLoadFailed(String)
    /// 输入类型不是图像（multiarray 输入的人脸模型需要转换时指定 image 输入）。
    case unsupportedInput(String)
    /// 输出张量形状不是"每张脸一个 N 维向量"。
    case invalidOutputShape([Int])
    /// 多个输出都能折叠成合法维度，无法判断哪个是人脸向量（拒绝猜测——猜错会静默入库错向量）。
    case ambiguousOutput([String])
    /// 推理输出长度与模型声明的维度不一致（用错输出或模型被替换）。
    case outputDimensionMismatch(expected: Int, actual: Int)
    case visionRequestFailed(String)
    case emptyOutput

    public var description: String {
        switch self {
        case let .modelNotFound(path):
            return "人脸嵌入模型不存在：\(path)（设置 face_embedding_model_path 指向 .mlmodel 或 .mlmodelc；留空则用内置 Vision 特征）"
        case let .unsupportedModelFormat(ext):
            return "不支持的人脸嵌入模型扩展名：.\(ext)（只接受 .mlmodel / .mlmodelc）"
        case let .modelLoadFailed(reason):
            return "人脸嵌入模型加载失败：\(reason)"
        case let .unsupportedInput(kind):
            return "人脸嵌入模型输入类型不受支持：\(kind)（需要 112×112 图像输入；multiarray 输入请用 coremltools 以 imageType 重新转换）"
        case let .invalidOutputShape(shape):
            return "人脸嵌入模型输出形状不受支持：\(shape)（需要 [1, N] 或 [N]，N 在 64…8192 之间）"
        case let .ambiguousOutput(names):
            return "人脸嵌入模型有多个可疑输出：\(names.joined(separator: "、"))。无法判断哪个是人脸向量（猜错会静默写入错误的向量）：请导出只输出人脸向量的模型，或把向量输出的名字改得可辨识（例如含 embed/feature）"
        case let .outputDimensionMismatch(expected, actual):
            return "人脸嵌入模型输出维度与声明不符：期望 \(expected)，实际 \(actual)（模型文件可能已被替换）"
        case let .visionRequestFailed(reason):
            return "人脸嵌入推理失败：\(reason)"
        case .emptyOutput:
            return "人脸嵌入推理没有返回结果"
        }
    }
}

/// 对齐后人脸的嵌入提供者。
/// 契约：输入必须是 112×112 对齐人脸（`FaceAlignmentTemplate.size`），输出**已 L2 归一化**。
public protocol FaceEmbeddingProvider: Sendable {
    var spec: FaceEmbeddingSpec { get }
    func embed(alignedFace: CGImage) throws -> [Double]
}

/// 默认实现：Vision 通用图像特征（rev2，768 维）。
/// 优点：无需外部模型、无下载、随系统更新；缺点：通用特征对人脸不是最优（见 ADR-029 已知限制）。
public struct VisionFeaturePrintEmbedder: FaceEmbeddingProvider {
    /// FeaturePrint rev2 实测维度（elementCount = 768）。spec.dimension 以此为声明值；
    /// 实际维度仍以 embedding.count 落库（换 SDK 后可检测）。
    public static let dimension = 768

    public init() {}

    public var spec: FaceEmbeddingSpec {
        FaceEmbeddingSpec(
            modelId: FaceEncoder.modelId,
            modelVersion: FaceEncoder.modelVersion,
            dimension: Self.dimension,
            signature: FaceEncoder.embeddingSpec
        )
    }

    public func embed(alignedFace: CGImage) throws -> [Double] {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(cgImage: alignedFace, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceEmbeddingError.visionRequestFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first else {
            throw FaceEmbeddingError.emptyOutput
        }
        let data = observation.data
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { throw FaceEmbeddingError.emptyOutput }
        let floats = data.withUnsafeBytes { bytes -> [Float] in
            Array(bytes.bindMemory(to: Float.self).prefix(count))
        }
        do {
            return try FaceEncoder.normalizeEmbedding(floats)
        } catch {
            throw FaceEmbeddingError.emptyOutput
        }
    }
}

// MARK: - 模型形态校验（可脱离 CoreML 单测）

/// 从模型描述提炼的输入/输出形态（CoreML 相关的类型不进入本结构，便于纯逻辑单测）。
public struct FaceEmbeddingModelShape: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case image
        case multiArray
        case unsupported(String)

        public var description: String {
            switch self {
            case .image: return "image"
            case .multiArray: return "multiArray"
            case let .unsupported(kind): return kind
            }
        }
    }

    /// 一个输出张量（名字用于确定性选择与报错，形状可能含 batch 维与尾部 1）。
    public struct Output: Equatable, Sendable {
        public let name: String
        public let shape: [Int]

        public init(name: String, shape: [Int]) {
            self.name = name
            self.shape = shape
        }
    }

    public let input: Input
    /// 全部 multiarray 输出，**按名字排序**——MLModelDescription 的字典遍历顺序不稳定，
    /// 不排序会让"选哪个输出"跨运行漂移（进而导致 spec 指纹抖动、缓存反复失效）。
    public let outputs: [Output]

    public init(input: Input, outputs: [Output]) {
        self.input = input
        self.outputs = outputs.sorted { $0.name < $1.name }
    }

    /// 单输出便捷构造（测试与常见模型）。
    public init(input: Input, outputShape: [Int]) {
        self.init(input: input, outputs: [Output(name: "output", shape: outputShape)])
    }

    /// 主输出形状（确定性：名字最小的那个；无输出为 []）。
    public var primaryOutputShape: [Int] { outputs.first?.shape ?? [] }

    /// 只保留有效维度：去掉前导 batch=1 与尾部 1。
    public var effectiveDimensions: [Int] {
        var dims = primaryOutputShape
        if dims.first == 1 { dims.removeFirst() }
        while dims.last == 1 { dims.removeLast() }
        return dims
    }
}

public enum FaceEmbeddingShapeValidator {
    /// 允许的嵌入维度范围（过小不是人脸特征，过大基本是误配的检测/分割模型）。
    public static let dimensionRange = 64...8192

    /// 校验模型形态并选出人脸向量输出（纯函数，单测覆盖）。
    /// 多个输出里**恰好一个**能折叠成合法维度才接受：人脸模型常同时输出 embedding 与
    /// logits/特征图，猜错会静默用错向量（且指纹看起来仍然"合理"）。
    public static func output(for shape: FaceEmbeddingModelShape) throws
        -> FaceEmbeddingModelShape.Output {
        guard case .image = shape.input else {
            throw FaceEmbeddingError.unsupportedInput(shape.input.description)
        }
        let valid = shape.outputs.filter { singleDimension(of: $0.shape) != nil }
        guard !valid.isEmpty else {
            throw FaceEmbeddingError.invalidOutputShape(shape.primaryOutputShape)
        }
        if valid.count == 1 { return valid[0] }
        // 多个输出都能当向量：真实 ArcFace 导出常同时带分类头（logits/softmax）。
        // 只做**保守**排除——名字一看就是分类头的去掉，若剩下恰好一个就接受；
        // 否则仍报歧义（宁可报错也不猜，猜错会静默入库错向量、且指纹看起来正常）。
        let headLike = ["logits", "logit", "softmax", "prob", "classifier", "class_", "fc", "head"]
        let embeddings = valid.filter { output in
            let name = output.name.lowercased()
            return !headLike.contains { name.contains($0) }
        }
        guard embeddings.count == 1 else {
            throw FaceEmbeddingError.ambiguousOutput(valid.map(\.name).sorted())
        }
        return embeddings[0]
    }

    /// 校验模型形态并推导嵌入维度。
    public static func dimension(for shape: FaceEmbeddingModelShape) throws -> Int {
        guard let dimension = singleDimension(of: try output(for: shape).shape) else {
            // output(for:) 只返回通过 singleDimension 的输出，这里不可达；保留分支是为了
            // 不返回一个"看起来正常"的 0 维（那会让下游拿 0 维向量建库）。
            throw FaceEmbeddingError.invalidOutputShape(shape.primaryOutputShape)
        }
        return dimension
    }

    /// 形状 → 单维嵌入长度；不是"每张脸一个向量"时返回 nil。
    static func singleDimension(of outputShape: [Int]) -> Int? {
        var dims = outputShape
        if dims.first == 1 { dims.removeFirst() }
        while dims.last == 1 { dims.removeLast() }
        guard dims.count == 1, dimensionRange.contains(dims[0]) else { return nil }
        return dims[0]
    }
}

// MARK: - 模型文件指纹（不依赖 CoreML，可独立单测）

/// 模型文件指纹工具。两个用途、两套代价：
///   · \`statFingerprint\`：递归"相对路径 + 大小 + mtime"，**廉价**，做进程内缓存键；
///   · \`contentFingerprint\`：递归"相对路径 + 全部内容"的分段链式哈希，做 spec.signature。
/// \`.mlmodelc\` 是**目录**：编译后的规格在 model.mlmodel，真正的权重在包内独立文件
/// （如 weights/weight.bin、model.espresso.weights）。原地替换包内文件**不会**改变
/// 目录自身的大小/mtime——只哈希 model.mlmodel 或只看目录 stat，都会让"换权重"逃过
/// 指纹，进而把两套向量空间写进同一列（对抗审查阻断项 1）。
public enum FaceEmbeddingFingerprint {
    /// 递归文件清单（排序后），.mlmodel 单文件也算一份。
    public static func files(of modelURL: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else { return [modelURL] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: modelURL, includingPropertiesForKeys: keys) else { return [] }
        var files: [URL] = []
        var seen: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            // 跳过 Finder/系统噪声（.DS_Store、._AppleDouble 等）：它们与权重无关，
            // 却会改变内容指纹 ⇒ analysis_signature 变 ⇒ **整个库被重算**。模型包里的
            // 真权重不会是点开头的文件（对抗验证 V1 的误报项）。
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular == true else { continue }
            guard seen.insert(url.path).inserted else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 相对路径（用于指纹里区分文件；绝对路径会让同一模型换个目录就换指纹）。
    static func relativePath(of file: URL, in modelURL: URL) -> String {
        let base = modelURL.path.hasSuffix("/") ? modelURL.path : modelURL.path + "/"
        return file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : file.lastPathComponent
    }

    /// 分段链式哈希：h₀ = 空；hᵢ₊₁ = SHA256(hᵢ ‖ 第 i 段)。
    /// 不是标准 SHA-256(整文件) 的等价物，只作"内容是否变化"的指纹；任何一段变化都会
    /// 改变最终摘要。之所以不一次性读整文件：人脸模型可达数百 MB，会造成内存尖峰。
    public static func chainedDigest(of url: URL, chunkSize: Int = 4 * 1024 * 1024) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var digest: [UInt8] = []
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            var payload = Data(digest)
            payload.append(chunk)
            digest = SHA256.hash(payload)
        }
        return digest
    }

    /// 递归 stat 指纹（缓存键）：廉价、不读内容；原地替换包内文件会改变其 mtime/size，
    /// 因此缓存失效并重新加载（加载后由 contentFingerprint 决定签名）。
    public static func statFingerprint(of modelURL: URL) -> String {
        var digest: [UInt8] = []
        func absorb(_ text: String) {
            var payload = Data(digest)
            payload.append(Data(text.utf8))
            digest = SHA256.hash(payload)
        }
        let files = files(of: modelURL)
        guard !files.isEmpty else { return "" }
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            absorb("\(relativePath(of: file, in: modelURL))|\(size)|\(Int(mtime * 1000))")
        }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 递归内容指纹（spec.signature）：相对路径 + 大小 + 逐文件分段链式内容哈希。
    public static func contentFingerprint(of modelURL: URL) -> String {
        var digest: [UInt8] = []
        func absorb(_ data: Data) {
            var payload = Data(digest)
            payload.append(data)
            digest = SHA256.hash(payload)
        }
        let files = files(of: modelURL)
        guard !files.isEmpty else { return "" }
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            absorb(Data("\(relativePath(of: file, in: modelURL))|\(size)|".utf8))
            absorb(Data(chainedDigest(of: file)))
        }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(CoreML)
// MARK: - CoreML 专用人脸模型

/// 专用人脸嵌入模型（ArcFace/SFace/AdaFace 等转换出的 CoreML 模型）。
/// 支持 .mlmodel（运行时编译）与 .mlmodelc（已编译）；要求 112×112 **图像输入**、
/// 单张人脸向量输出；推理在 Vision 的 VNCoreMLRequest 中执行（自动处理图像缩放）。
///
/// 已知边界（无真实模型可验证，首次接入必须人工确认）：`MLModel.compileModel(at:)`
/// 把 .mlmodel 编译到系统临时目录并保留（不做删除：MLModel 可能惰性映射该目录），
/// 因此每次进程首次加载会重新编译一次（大模型需数秒）；模型实例本身按文件指纹缓存，
/// 批内不会重复加载。若将来接入的模型要求非 112 边长输入，需同时扩模板与设置。
/// `@unchecked Sendable` 依据：存储属性只有 `spec`（值类型，不可变）与 `model`（MLModel，
/// 加载后不可变，CoreML 支持多线程并发 prediction）；每次 `embed` 都新建
/// VNCoreMLRequest/VNImageRequestHandler，不共享可变状态，故无需加锁。
public struct CoreMLFaceEmbedder: FaceEmbeddingProvider, @unchecked Sendable {
    public let spec: FaceEmbeddingSpec
    private let model: MLModel
    /// 被选中的输出名（VNCoreMLFeatureValueObservation.featureName 用它挑结果，
    /// 多输出模型下不能靠 results.first 的顺序）。
    private let outputName: String

    public init(modelURL: URL, modelVersion: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw FaceEmbeddingError.modelNotFound(modelURL.path)
        }
        let compiledURL: URL
        switch modelURL.pathExtension {
        case "mlmodelc":
            compiledURL = modelURL
        case "mlmodel":
            do {
                compiledURL = try MLModel.compileModel(at: modelURL)
            } catch {
                throw FaceEmbeddingError.modelLoadFailed("\(error)")
            }
        default:
            throw FaceEmbeddingError.unsupportedModelFormat(modelURL.pathExtension)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model: MLModel
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw FaceEmbeddingError.modelLoadFailed("\(error)")
        }
        let selected = try FaceEmbeddingShapeValidator.output(
            for: Self.shape(of: model.modelDescription))
        guard let dimension = FaceEmbeddingShapeValidator.singleDimension(of: selected.shape) else {
            throw FaceEmbeddingError.invalidOutputShape(selected.shape)
        }
        // 内容指纹覆盖包内**所有**文件（含 weights/weight.bin 等权重文件）——只哈希
        // model.mlmodel 会让"同架构换权重重导"逃过 analysis_signature（阻断项 1）。
        let hash = FaceEmbeddingFingerprint.contentFingerprint(of: modelURL)
        guard !hash.isEmpty else {
            throw FaceEmbeddingError.modelLoadFailed("无法读取模型文件（指纹为空）：\(modelURL.path)")
        }
        let name = modelURL.deletingPathExtension().lastPathComponent
        self.spec = .coreML(
            modelId: name,
            modelVersion: modelVersion.isEmpty ? "unversioned" : modelVersion,
            dimension: dimension,
            weightHash: hash
        )
        self.outputName = selected.name
        self.model = model
    }

    public func embed(alignedFace: CGImage) throws -> [Double] {
        let visionModel: VNCoreMLModel
        do {
            visionModel = try VNCoreMLModel(for: model)
        } catch {
            throw FaceEmbeddingError.modelLoadFailed("\(error)")
        }
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: alignedFace, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceEmbeddingError.visionRequestFailed(error.localizedDescription)
        }
        // 按输出名挑结果：多输出模型的 results 顺序不保证，first 可能拿到 logits。
        let observations = (request.results ?? []).compactMap { $0 as? VNCoreMLFeatureValueObservation }
        let observation = observations.first { $0.featureName == outputName } ?? observations.first
        guard let multiArray = observation?.featureValue.multiArrayValue else {
            throw FaceEmbeddingError.emptyOutput
        }
        let floats = try Self.floats(from: multiArray)
        // 维度守卫：用错输出/模型被替换时宁可报错，也不把错长度的向量写进库。
        guard floats.count == spec.dimension else {
            throw FaceEmbeddingError.outputDimensionMismatch(
                expected: spec.dimension, actual: floats.count)
        }
        do {
            return try FaceEncoder.normalizeEmbedding(floats)
        } catch {
            throw FaceEmbeddingError.emptyOutput
        }
    }

    /// 从 CoreML 模型描述提炼输入/输出形态。
    /// **确定性**：MLModelDescription 的字典遍历顺序不稳定，这里按"图像输入优先 + 输出
    /// 全收集并按名字排序"，否则同一模型可能跨运行选出不同输出（指纹抖动、缓存反复失效）。
    static func shape(of description: MLModelDescription) -> FaceEmbeddingModelShape {
        let inputFeatures = description.inputDescriptionsByName
        let input: FaceEmbeddingModelShape.Input
        if inputFeatures.values.contains(where: { $0.type == .image }) {
            input = .image
        } else if inputFeatures.values.contains(where: { $0.type == .multiArray }) {
            input = .multiArray
        } else {
            // String(describing:) 给出可读的枚举名（MLFeatureType.rawValue 是 Int32）。
            let kinds = Set(inputFeatures.values.map { String(describing: $0.type) }).sorted()
            input = .unsupported(kinds.isEmpty ? "none" : kinds.joined(separator: "+"))
        }
        var outputs: [FaceEmbeddingModelShape.Output] = []
        for (name, feature) in description.outputDescriptionsByName {
            guard feature.type == .multiArray, let constraint = feature.multiArrayConstraint else { continue }
            outputs.append(.init(name: name, shape: constraint.shape.map { $0.intValue }))
        }
        return FaceEmbeddingModelShape(input: input, outputs: outputs)
    }

    /// MLMultiArray → [Float]（float32/double/float16）。
    /// **必须尊重 strides**：dataPointer 线性读只在连续内存上成立，非连续数组会静默错序
    /// （读出的向量看起来"合法"，但每个元素都错位）。判定非连续时走逐线性下标取值
    /// （MLMultiArray 的 subscript 遵守 strides；输出只有几百维，性能可忽略）。
    static func floats(from multiArray: MLMultiArray) throws -> [Float] {
        let count = multiArray.count
        guard count > 0 else { throw FaceEmbeddingError.emptyOutput }
        switch multiArray.dataType {
        case .float32, .double, .float16:
            break
        default:
            throw FaceEmbeddingError.invalidOutputShape(multiArray.shape.map { $0.intValue })
        }
        if isContiguous(multiArray) {
            switch multiArray.dataType {
            case .float32:
                let pointer = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
                return Array(UnsafeBufferPointer(start: pointer, count: count))
            case .double:
                let pointer = multiArray.dataPointer.bindMemory(to: Double.self, capacity: count)
                return UnsafeBufferPointer(start: pointer, count: count).map { Float($0) }
            case .float16:
                let pointer = multiArray.dataPointer.bindMemory(to: Float16.self, capacity: count)
                return UnsafeBufferPointer(start: pointer, count: count).map { Float($0) }
            default:
                break
            }
        }
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            values[index] = Float(truncating: multiArray[index])
        }
        return values
    }

    /// 行主序连续内存判定（最后维步长 1，依次乘以前一维大小）。
    static func isContiguous(_ multiArray: MLMultiArray) -> Bool {
        let shape = multiArray.shape.map { $0.intValue }
        let strides = multiArray.strides.map { $0.intValue }
        guard shape.count == strides.count else { return false }
        var expected = 1
        for index in stride(from: shape.count - 1, through: 0, by: -1) {
            if strides[index] != expected { return false }
            expected *= shape[index]
        }
        return true
    }

}
#endif

// MARK: - 工厂（设置 → 提供者）

public enum FaceEmbeddingModelFactory {
    /// TS/原生设置键：模型路径（空 = 内置 Vision 特征）。
    public static let modelPathSetting = "face_embedding_model_path"
    /// 用户可读的模型版本标签（写进 model_version，便于事后追溯；不参与缓存键的语义判断）。
    public static let modelVersionSetting = "face_embedding_model_version"

    /// 由设置解析嵌入提供者。路径为空 → Vision；否则必须可加载（失败抛错，禁止静默回退）。
    ///
    /// 路径规范化（对抗审查实测问题）：`~` 必须展开（fileExists 不认 "~"，否则永远
    /// modelNotFound）、软链要解析到目标（否则 stat 的是链接本身，替换目标不会失效）、
    /// 相对路径按进程 CWD 解释——统一成绝对真实路径后再做缓存键与加载。
    public static func make(modelPath: String, modelVersion: String) throws -> FaceEmbeddingProvider {
        let trimmed = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return VisionFeaturePrintEmbedder() }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        return try cache.provider(forPath: url.path, version: modelVersion)
    }

    /// 只取规格（服务层建 analysis_signature 用）：与 `make` 共用缓存与错误语义，
    /// 保证"签名里的模型"与"实际推理用的模型"永远是同一个。
    public static func spec(modelPath: String, modelVersion: String) throws -> FaceEmbeddingSpec {
        try make(modelPath: modelPath, modelVersion: modelVersion).spec
    }

    /// 模型缓存：`@unchecked Sendable` 依据——唯一可变状态是 providers 字典（键 = 路径 +
    /// 版本 + 文件指纹），全部读写都在 lock 临界区内完成；loader（模型加载，可能耗秒级）
    /// 刻意在锁外调用，避免加载期间阻塞其他键的查询——代价是同一键并发未命中时可能重复
    /// 加载一次（幂等，最坏多读一次文件，不产生错误状态）。
    static let cache = Cache()

    final class Cache: @unchecked Sendable {
        typealias Loader = @Sendable (URL, String) throws -> FaceEmbeddingProvider

        private let lock = NSLock()
        private var providers: [String: FaceEmbeddingProvider] = [:]

        /// 键 = 路径 + 版本 + 递归 stat 指纹（包内每个文件的相对路径 + 大小 + mtime）。
        /// 为什么不是单看目录 stat：原地替换 `.mlmodelc` 包内的权重文件**不会**改变
        /// 目录自身的大小/mtime（对抗审查实测），只按目录 stat 缓存会继续用旧模型。
        ///
        /// **已知边界**：指纹是 stat 而不是内容——若有人把权重换成同尺寸文件并刻意把
        /// mtime 改回原值（`touch -r`），缓存不会失效（进程内继续用已加载的旧模型）。
        /// 不用内容指纹做键是因为代价：256 MiB 模型在 Debug 下整包哈希约 48s，不能放在
        /// 每次分析的路径上。内容指纹仍然决定 `spec.signature`（换权重 → 新签名 →
        /// 旧观测判过期重算），且一次运行只用**一个**嵌入实例（见 FaceInferenceEngine.init），
        /// 所以"签名与推理不同源"的混写窗口不存在。
        static func key(path: String, version: String, fingerprint: String) -> String {
            "\(path)|\(version)|\(fingerprint)"
        }

        func provider(
            forPath path: String,
            version: String,
            loader: Loader? = nil
        ) throws -> FaceEmbeddingProvider {
            let url = URL(fileURLWithPath: path)
            let fingerprint = FaceEmbeddingFingerprint.statFingerprint(of: url)
            guard !fingerprint.isEmpty else {
                throw FaceEmbeddingError.modelNotFound(path)
            }
            let cacheKey = Self.key(path: path, version: version, fingerprint: fingerprint)
            lock.lock()
            let cached = providers[cacheKey]
            lock.unlock()
            if let cached { return cached }
            let provider: FaceEmbeddingProvider
            if let loader {
                provider = try loader(url, version)
            } else {
#if canImport(CoreML)
                provider = try CoreMLFaceEmbedder(modelURL: url, modelVersion: version)
#else
                throw FaceEmbeddingError.unsupportedInput("当前平台没有 CoreML，无法加载专用人脸模型")
#endif
            }
            lock.lock()
            providers[cacheKey] = provider
            lock.unlock()
            return provider
        }

        /// 仅供测试：清空缓存。
        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            providers.removeAll()
        }
    }
}
#endif
