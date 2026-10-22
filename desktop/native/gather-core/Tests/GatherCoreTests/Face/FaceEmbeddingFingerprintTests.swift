// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceEmbeddingFingerprintTests.swift
// 对抗审查（R1）阻断项 1 的回归测试 + 三个测试缺口：
//   · .mlmodelc 是**目录**：权重在包内独立文件（weights/weight.bin），原地替换**不改变**
//     目录大小/mtime —— 只哈希 model.mlmodel 或只看目录 stat 都会漏判"换了权重"，
//     于是两套向量空间写进同一列、analysis_signature 却不变。本文件用**同尺寸**替换
//     强制这条路径：内容指纹必须变、递归 stat 指纹必须变、缓存必须失效重载。
//   · MLMultiArray 非连续 strides：线性读会静默错序（向量"合法"但元素错位）。
//   · float16 输出（CoreML 量化模型常见）。
//   · 多输出模型的确定性选择与歧义拒绝。

import Foundation
import Testing
import CoreML
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct FaceEmbeddingFingerprintTests {
    // ── 测试夹具：手造一个"编译好的 .mlmodelc 包" ──

    private struct FakeModelPackage {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("gather-mlmodelc-\(UUID().uuidString).mlmodelc")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 规格文件与权重文件分开：权重在包内子目录里（真实 .mlmodelc 布局）。
            try Data(repeating: 0x41, count: 64).write(to: root.appendingPathComponent("model.mlmodel"))
            let weights = root.appendingPathComponent("weights")
            try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
            try Data(repeating: 0x01, count: 1024).write(to: weights.appendingPathComponent("weight.bin"))
        }

        var weightsURL: URL { root.appendingPathComponent("weights/weight.bin") }

        /// 同尺寸替换权重内容，并把 mtime 推到明确不同的一秒。
        func replaceWeightsSameSize(with byte: UInt8, mtime: Date) throws {
            try Data(repeating: byte, count: 1024).write(to: weightsURL)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: weightsURL.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("系统噪声文件（.DS_Store / ._*）不进指纹：一次 Finder 浏览不得让整个库重算")
    func noiseFilesAreIgnoredByFingerprints() throws {
        let package = try FakeModelPackage()
        defer { package.remove() }
        let contentBefore = FaceEmbeddingFingerprint.contentFingerprint(of: package.root)
        let statBefore = FaceEmbeddingFingerprint.statFingerprint(of: package.root)
        for name in [".DS_Store", "._weight.bin"] {
            try Data(repeating: 0xFF, count: 32)
                .write(to: package.root.appendingPathComponent(name))
        }
        // 反向护栏：真的改了权重文件时两条指纹都必须变（否则这条用例会"因为过滤太狠"而恒真）。
        #expect(FaceEmbeddingFingerprint.contentFingerprint(of: package.root) == contentBefore)
        #expect(FaceEmbeddingFingerprint.statFingerprint(of: package.root) == statBefore)
        try package.replaceWeightsSameSize(with: 0x7A, mtime: Date(timeIntervalSince1970: 1_700_000_500))
        #expect(FaceEmbeddingFingerprint.contentFingerprint(of: package.root) != contentBefore)
        #expect(FaceEmbeddingFingerprint.statFingerprint(of: package.root) != statBefore)
    }

    @Test("阻断 1 回归：同尺寸替换包内权重 → 内容指纹变化（旧实现只哈希 model.mlmodel 会漏判）")
    func contentFingerprintTracksInnerWeights() throws {
        let package = try FakeModelPackage()
        defer { package.remove() }
        let before = FaceEmbeddingFingerprint.contentFingerprint(of: package.root)
        #expect(!before.isEmpty)
        try package.replaceWeightsSameSize(with: 0x02, mtime: Date(timeIntervalSince1970: 1_700_000_000))
        let after = FaceEmbeddingFingerprint.contentFingerprint(of: package.root)
        #expect(after != before, "包内权重变了，内容指纹必须变（否则 analysis_signature 不变、旧向量被复用）")
    }

    @Test("递归 stat 指纹覆盖包内文件：目录 mtime 不变也要失效缓存键")
    func statFingerprintTracksInnerFileMtime() throws {
        let package = try FakeModelPackage()
        defer { package.remove() }
        let before = FaceEmbeddingFingerprint.statFingerprint(of: package.root)
        // 只改 mtime（内容与大小都不变）——模拟"同名同大小文件被替换后系统保留目录时间戳"。
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: package.weightsURL.path)
        // 目录自身的大小/mtime **不变**——这正是"只看目录 stat 会漏判"的机制；
        // 断言它不变，才能证明递归 stat 指纹带来的差异不是巧合。
        let directoryBefore = try FileManager.default.attributesOfItem(atPath: package.root.path)
        let directorySizeBefore = directoryBefore[.size] as? Int
        let directoryMtimeBefore = directoryBefore[.modificationDate] as? Date
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: package.weightsURL.path)
        let after = FaceEmbeddingFingerprint.statFingerprint(of: package.root)
        #expect(after != before, "包内文件 mtime 变化必须改变递归指纹")
        let directoryAfter = try FileManager.default.attributesOfItem(atPath: package.root.path)
        #expect(directoryAfter[.size] as? Int == directorySizeBefore, "目录自身大小不变（旧实现看不出差异）")
        #expect(
            directoryAfter[.modificationDate] as? Date == directoryMtimeBefore,
            "目录自身 mtime 不变（旧实现看不出差异）")
    }

    @Test("缓存：权重同尺寸替换后必须重新加载（旧键只看路径+版本+目录 stat 会复用旧模型）")
    func cacheInvalidatesOnInnerWeightChange() throws {
        let package = try FakeModelPackage()
        defer { package.remove() }
        let cache = FaceEmbeddingModelFactory.Cache()
        let counter = FingerprintTestCounter()
        let loader: FaceEmbeddingModelFactory.Cache.Loader = { _, version in
            counter.increment()
            return FakeProvider(spec: FaceEmbeddingSpec(
                modelId: "fake", modelVersion: version, dimension: 4, signature: "fake"))
        }
        _ = try cache.provider(forPath: package.root.path, version: "v1", loader: loader)
        _ = try cache.provider(forPath: package.root.path, version: "v1", loader: loader)
        #expect(counter.value == 1, "同指纹应命中缓存")
        try package.replaceWeightsSameSize(with: 0x03, mtime: Date(timeIntervalSince1970: 1_700_000_500))
        _ = try cache.provider(forPath: package.root.path, version: "v1", loader: loader)
        #expect(counter.value == 2, "包内权重变化必须让缓存键失效")
    }

    // ── MLMultiArray 读取 ──

    @Test("非连续 strides 必须按 strides 取值（线性读会静默错序）")
    func floatsRespectsNonContiguousStrides() throws {
        let capacity = 12
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { storage.deallocate() }
        for index in 0..<capacity { storage[index] = Float(index) }
        // shape [2,3] + strides [6,2]：逻辑元素 (r,c) 在 r*6 + c*2。
        let array = try MLMultiArray(
            dataPointer: UnsafeMutableRawPointer(storage),
            shape: [2, 3],
            dataType: .float32,
            strides: [6, 2],
            deallocator: nil)
        #expect(!CoreMLFaceEmbedder.isContiguous(array))
        let values = try FaceEmbeddingFingerprintTests.readFloats(array)
        #expect(values == [0, 2, 4, 6, 8, 10], "必须按 strides 取值，得到 \(values)")
    }

    @Test("连续 float32 / double / float16 输出都能读成 [Float]")
    func floatsSupportsCommonDataTypes() throws {
        let float32 = try MLMultiArray(shape: [1, 4], dataType: .float32)
        for index in 0..<4 { float32[index] = NSNumber(value: Float(index) + 0.5) }
        #expect(CoreMLFaceEmbedder.isContiguous(float32))
        #expect(try FaceEmbeddingFingerprintTests.readFloats(float32) == [0.5, 1.5, 2.5, 3.5])

        let double = try MLMultiArray(shape: [3], dataType: .double)
        for index in 0..<3 { double[index] = NSNumber(value: Double(index) * 2) }
        #expect(try FaceEmbeddingFingerprintTests.readFloats(double) == [0, 2, 4])

        let half = try MLMultiArray(shape: [1, 2], dataType: .float16)
        // 1.0 与 -2.5 在 float16 里精确可表示；NSNumber 用 Double 写入即可。
        half[0] = NSNumber(value: 1.0)
        half[1] = NSNumber(value: -2.5)
        #expect(try FaceEmbeddingFingerprintTests.readFloats(half) == [1.0, -2.5])
    }

    // ── 多输出形态 ──

    @Test("多输出：分类头按名字排除；排除后仍不唯一才拒绝（不猜）")
    func shapeValidatorSelectsOrRejects() throws {
        // 真实 ArcFace 导出常见"embedding + logits"：logits 名字一看就是分类头，
        // 保守排除后只剩 embedding ✓（此前一律报歧义，等于误杀这类导出）。
        let withLogits = FaceEmbeddingModelShape(input: .image, outputs: [
            .init(name: "logits", shape: [1, 1000]),
            .init(name: "embedding", shape: [1, 512]),
        ])
        #expect(try FaceEmbeddingShapeValidator.output(for: withLogits).name == "embedding")
        #expect(try FaceEmbeddingShapeValidator.dimension(for: withLogits) == 512)

        // 两个都不是分类头名字 → 无法判断 → 必须报错而不是猜（宁可不支持也不能静默入库错向量）。
        let ambiguous = FaceEmbeddingModelShape(input: .image, outputs: [
            .init(name: "output_a", shape: [1, 512]),
            .init(name: "output_b", shape: [1, 256]),
        ])
        #expect(throws: FaceEmbeddingError.ambiguousOutput(["output_a", "output_b"])) {
            _ = try FaceEmbeddingShapeValidator.output(for: ambiguous)
        }
        // 特征图不合法（rank 3）→ 唯一合法输出是 embedding。
        let mixed = FaceEmbeddingModelShape(input: .image, outputs: [
            .init(name: "featuremap", shape: [1, 512, 7, 7]),
            .init(name: "embedding", shape: [1, 512]),
        ])
        #expect(try FaceEmbeddingShapeValidator.output(for: mixed).name == "embedding")
        #expect(try FaceEmbeddingShapeValidator.dimension(for: mixed) == 512)
        // 输出按名字排序 → 同一模型跨运行选择稳定（字典遍历顺序不稳定）。
        let reordered = FaceEmbeddingModelShape(input: .image, outputs: [
            .init(name: "zzz", shape: [1, 8, 8]),
            .init(name: "aaa", shape: [1, 128]),
        ])
        #expect(reordered.outputs.map(\.name) == ["aaa", "zzz"])
    }

    // ── 路径规范化 ──

    @Test("波浪号路径会被展开（旧实现 fileExists 不认 ~，永远 modelNotFound）")
    func tildePathIsExpanded() throws {
        // 不写真实 home（沙箱/只读 home 会失败）：在临时目录建唯一目录，
        // 输入仍以 "~/" 开头，用「从 home 走 ../ 到临时目录」的相对路径构造 ——
        // 只有 ~ 展开生效才能命中文件；断言与回归意图保持不变。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-tilde-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "probe.onnx"
        let absolute = dir.appendingPathComponent(name)
        try Data([0x00]).write(to: absolute)

        let homeComponents = (NSHomeDirectory() as NSString).pathComponents
        let relativeFromHome = String(repeating: "../", count: max(0, homeComponents.count - 1))
            + String(absolute.path.dropFirst())
        // 若能展开，则路径存在 → 报"扩展名不支持"；不能展开则报 modelNotFound。
        #expect(throws: FaceEmbeddingError.unsupportedModelFormat("onnx")) {
            _ = try FaceEmbeddingModelFactory.make(modelPath: "~/" + relativeFromHome, modelVersion: "v1")
        }
    }

    /// 直接调用生产的读取实现（internal + @testable：CoreML 构造路径无真实模型可跑，
    /// 但 MLMultiArray → [Float] 这段纯逻辑必须被覆盖）。
    static func readFloats(_ array: MLMultiArray) throws -> [Float] {
        try CoreMLFaceEmbedder.floats(from: array)
    }
}

private struct FakeProvider: FaceEmbeddingProvider {
    let spec: FaceEmbeddingSpec
    func embed(alignedFace: CGImage) throws -> [Double] { [] }
}

private final class FingerprintTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

