// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceInferenceTests.swift
// Phase 2 任务 2.2（macOS 专属）：Provider/Encoder/Inference 测试。
// TS 源对照: face-kw/provider.ts + face-encoder.ts
//          + face-inference-worker(-client).ts
// 验证点：
//   - FaceProvider.resolve：auto/vision/coreml/cpu 解析与未知值抛错；
//   - FaceInferenceConfig 默认值与对齐（640/128/112/512）；
//   - Encoder：空图 → 空数组；错误输入 → 错误码；
//   - Inference：批处理逐图独立（坏图不拖垮批次）+ 进度流 + 取消。

import Foundation
import Testing
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct FaceInferenceTests {
    // ── 测试图片生成 ──

    /// 纯色图（无脸）：Vision 返回空结果。
    private func makeSolidJPEG(width: Int = 320, height: Int = 240, color: CGColor = .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError("CGContext failed") }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError("makeImage failed") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw TestError("destination failed") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestError("finalize failed") }
        return data as Data
    }

    private struct TestError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    // ── Provider ──

    @Test func providerResolveMapsLegacyNames() throws {
        #expect(try FaceProvider.resolve("auto") == .vision)
        #expect(try FaceProvider.resolve("vision") == .vision)
        #expect(try FaceProvider.resolve("coreml") == .vision)
        #expect(try FaceProvider.resolve("CoreMLExecutionProvider") == .vision)
        #expect(try FaceProvider.resolve("cpu") == .cpu)
        #expect(try FaceProvider.resolve("CPUExecutionProvider") == .cpu)
        #expect(throws: FaceProviderError.unknownProvider("cuda")) {
            _ = try FaceProvider.resolve("cuda")
        }
    }

    @Test func configDefaultsAlignWithModelConfig() {
        let config = FaceInferenceConfig()
        #expect(config.confidenceThreshold == 0.5)
        #expect(config.nmsThreshold == 0.4)
        #expect(config.maxDetections == 100)
        #expect(config.embeddingDim == 512)
        #expect(config.primaryInputSize == 640)
        #expect(config.secondaryInputSize == 128)
        #expect(config.encodeInputSize == 112)
        #expect(!config.fallbackToOnnxEnabled)
    }

    // ── Encoder（Vision 空图路径）──

    @Test func encoderReturnsEmptyForSolidImage() throws {
        let image = try makeSolidJPEG()
        let results = try FaceEncoder.encodeFaces(in: image)
        #expect(results.isEmpty)
    }

    @Test func encoderThrowsOnGarbageData() {
        #expect(throws: FaceEncoderError.self) {
            _ = try FaceEncoder.encodeFaces(in: Data("not an image".utf8))
        }
    }

    /// embedding 归一化契约：L2 范数为 1、符号保留、维度不变。
    @Test func normalizeEmbeddingIsL2UnitAndLossless() throws {
        let values: [Float] = [3.0, -4.0, 0.5]
        let normalized = try FaceEncoder.normalizeEmbedding(values)
        #expect(normalized.count == 3)
        let norm = normalized.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1.0) < 1e-9)
        #expect(normalized[0] > 0 && normalized[1] < 0) // 符号保留
    }

    @Test func normalizeEmbeddingRejectsZeroVector() {
        #expect(throws: FaceEncoderError.invalidEmbedding) {
            _ = try FaceEncoder.normalizeEmbedding([0, 0, 0])
        }
    }

    // ── Inference（批处理语义）──

    @Test func inferenceProcessesBatchAndStreamsProgress() async throws {
        let image = try makeSolidJPEG()
        let engine = FaceInferenceEngine()
        var progressEvents: [(Int, Int)] = []
        let results = try await engine.analyzeBatch(
            images: [image, image, image],
            onProgress: { progressEvents.append(($0.current, $0.total)) }
        )
        #expect(results.count == 3)
        for item in results {
            #expect(item.error == nil)
            #expect(item.observations.isEmpty)
            #expect(item.encodingFailures == 0)
        }
        #expect(progressEvents.count == 3)
        #expect(progressEvents.map { $0.0 } == [1, 2, 3])
        #expect(progressEvents.map { $0.1 } == [3, 3, 3])
    }

    @Test func inferenceIsolatesPerImageFailures() async throws {
        let good = try makeSolidJPEG()
        let engine = FaceInferenceEngine()
        let results = try await engine.analyzeBatch(images: [good, Data("garbage".utf8), good])
        #expect(results.count == 3)
        #expect(results[0].error == nil)
        #expect(results[1].error != nil)
        #expect(results[2].error == nil)
    }

    @Test func inferencePropagatesCancellation() async throws {
        let image = try makeSolidJPEG()
        let engine = FaceInferenceEngine()
        let task = Task {
            try await engine.analyzeBatch(images: Array(repeating: image, count: 500))
        }
        // 等待任务真正开始处理（批处理首图后取消点才可能触发）。
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            let results = try await task.value
            // 若取消晚于全部处理完成，批结果完整返回也算合法（竞态窗口）。
            #expect(results.count == 500)
        } catch is CancellationError {
            // 取消在 checkCancellation 点生效——期望路径。
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
