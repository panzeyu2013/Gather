// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/PreprocessReconciliationTests.swift
// Face 预处理对账测试（Phase 1 任务 1.5「对账测试框架」第二批）。
// fixture 由 scripts/reconciliation/generate-preprocess-fixtures.mjs 生成
// （参照实现 = face-detector.ts / face-encoder.ts 照抄核心循环），
// 本测试逐 case 加载比对。自含 fixture 加载（经 #filePath 定位 Fixtures 目录）。
//
// 精度说明：TS 全程双精度运算，Swift 用 Double 逐语句同序运算，
// IEEE-754 跨语言确定 → 变换参数逐位相等；alignedArcFaceInput 输出经
// Float32Array 舍入到 float32（JSON 中保存该值的双精度展开），Swift 侧
// 同样 Double 算完舍入 Float 再展开回 Double 比对，逐位相等。

import Foundation
import Testing
@testable import GatherCore

struct PreprocessReconciliationTests {

    private struct Fixture: Decodable {
        let seed: Int
        let scrfdLayoutCases: [ScrfdLayoutCase]
        let transformCases: [TransformCase]
        let alignCases: [AlignCase]

        struct ScrfdLayoutCase: Decodable {
            let name: String
            let outputCount: Int
            let expected: LayoutValue?
            let error: String?
        }

        struct LayoutValue: Decodable, Equatable {
            let featureMaps: Int
            let strides: [Int]
            let anchorsPerCell: Int
            let hasLandmarks: Bool
        }

        struct TransformCase: Decodable {
            let name: String
            let source: [[Double]]
            let destination: [[Double]]
            let expected: TransformValue?
            let error: String?
        }

        struct TransformValue: Decodable, Equatable {
            let a: Double
            let b: Double
            let tx: Double
            let ty: Double
        }

        struct AlignCase: Decodable {
            let name: String
            let width: Int
            let height: Int
            let channels: Int
            let pixels: [Int]
            let landmarks: [[Double]]
            let size: Int
            let expected: [Double]?
            let error: String?
        }
    }

    private static func loadFixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("preprocess-fixtures.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    private static func expectThrow<T>(
        expectedMessage: String,
        _ body: () throws -> T
    ) {
        do {
            _ = try body()
            Issue.record("expected throw, got success")
        } catch {
            #expect(
                error.localizedDescription == expectedMessage,
                "expected '\(expectedMessage)', got '\(error.localizedDescription)'")
        }
    }

    // 布局解析：合法布局逐字段相等；不支持数抛与 TS 一致的消息
    @Test func resolveScrfdLayoutMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.scrfdLayoutCases {
            if let expected = c.expected {
                let layout = try FacePreprocessing.resolveScrfdLayout(outputCount: c.outputCount)
                #expect(layout.featureMaps == expected.featureMaps, "case \(c.name): featureMaps")
                #expect(layout.strides == expected.strides, "case \(c.name): strides")
                #expect(layout.anchorsPerCell == expected.anchorsPerCell, "case \(c.name): anchorsPerCell")
                #expect(layout.hasLandmarks == expected.hasLandmarks, "case \(c.name): hasLandmarks")
            } else {
                Self.expectThrow(expectedMessage: c.error ?? "") {
                    try FacePreprocessing.resolveScrfdLayout(outputCount: c.outputCount)
                }
            }
        }
    }

    // 相似变换：双精度逐位相等（含恒等变换 a=1/b=0/tx=0/ty=0 的精确断言）
    @Test func estimateSimilarityTransformMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.transformCases {
            if let expected = c.expected {
                let transform = try FacePreprocessing.estimateSimilarityTransform(
                    source: c.source,
                    destination: c.destination)
                #expect(transform.a == expected.a, "case \(c.name): a")
                #expect(transform.b == expected.b, "case \(c.name): b")
                #expect(transform.tx == expected.tx, "case \(c.name): tx")
                #expect(transform.ty == expected.ty, "case \(c.name): ty")
            } else {
                Self.expectThrow(expectedMessage: c.error ?? "") {
                    try FacePreprocessing.estimateSimilarityTransform(
                        source: c.source,
                        destination: c.destination)
                }
            }
        }
    }

    // 对齐输入：输出 float32 序列逐位相等（Double(Float) 展开后与 fixture 精确相等）
    @Test func alignedArcFaceInputMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.alignCases {
            let pixels: [UInt8] = c.pixels.map { UInt8($0) }
            if let expected = c.expected {
                let input = try FacePreprocessing.alignedArcFaceInput(
                    data: pixels,
                    width: c.width,
                    height: c.height,
                    channels: c.channels,
                    landmarks: c.landmarks,
                    size: c.size)
                #expect(input.count == expected.count, "case \(c.name): 输出长度")
                for (index, value) in expected.enumerated() {
                    #expect(
                        Double(input[index]) == value,
                        "case \(c.name): index \(index), expected \(value), got \(Double(input[index]))")
                }
            } else {
                Self.expectThrow(expectedMessage: c.error ?? "") {
                    try FacePreprocessing.alignedArcFaceInput(
                        data: pixels,
                        width: c.width,
                        height: c.height,
                        channels: c.channels,
                        landmarks: c.landmarks,
                        size: c.size)
                }
            }
        }
    }
}
