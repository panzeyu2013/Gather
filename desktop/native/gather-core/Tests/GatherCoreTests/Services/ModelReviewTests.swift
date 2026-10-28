// desktop/native/gather-core/Tests/GatherCoreTests/Services/ModelReviewTests.swift
// 模型级初审的纯函数：眼睛几何、微笑几何、拉普拉斯方差、指纹与 Codable 往返。
// 不触达 Vision（真实人脸质量由 docs 的真实集评估协议覆盖）。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("模型级初审（纯函数）")
struct ModelReviewTests {

    @Test("眼睛几何：睁眼 EAR 高、闭眼 EAR 低，分数单调")
    func eyeOpenGeometry() {
        // 6 点绕眼一周；上下眼睑距离决定 EAR。
        let open = [(0.0, 0.0), (0.3, 0.10), (0.7, 0.10), (1.0, 0.0), (0.7, -0.10), (0.3, -0.10)]
            .map { (x: $0.0, y: $0.1) }
        let closed = [(0.0, 0.0), (0.3, 0.01), (0.7, 0.01), (1.0, 0.0), (0.7, -0.01), (0.3, -0.01)]
            .map { (x: $0.0, y: $0.1) }
        let openEAR = try? #require(EyeOpenGeometry.eyeAspectRatio(open))
        let closedEAR = try? #require(EyeOpenGeometry.eyeAspectRatio(closed))
        #expect((openEAR ?? 0) > (closedEAR ?? 0))
        #expect(EyeOpenGeometry.score(ear: closedEAR ?? 0) < 0.05)
        #expect(EyeOpenGeometry.score(ear: openEAR ?? 0) > 0.5)
        #expect(EyeOpenGeometry.score(ear: 0) == 0)
        #expect(EyeOpenGeometry.score(ear: 1) == 1)
    }

    @Test("微笑几何：更宽的嘴得分更高；点不足返回 nil")
    func smileGeometry() {
        let wide = [(0.0, 0.0), (0.6, 0.1), (0.9, 0.0), (0.6, -0.1)].map { (x: $0.0, y: $0.1) }
        let narrow = [(0.4, 0.0), (0.5, 0.02), (0.6, 0.0), (0.5, -0.02)].map { (x: $0.0, y: $0.1) }
        let wideScore = SmileGeometry.score(points: wide, faceWidth: 1)
        let narrowScore = SmileGeometry.score(points: narrow, faceWidth: 1)
        #expect((wideScore ?? 0) > (narrowScore ?? 0))
        #expect(SmileGeometry.score(points: [], faceWidth: 1) == nil)
    }

    @Test("微笑几何：真实比值的「中性脸」不得饱和，微笑要明显高于中性")
    func smileGeometryIsCalibratedForRealRatios() throws {
        // 脸框归一化坐标：嘴宽 / 脸宽 中性≈0.38、微笑≈0.50；开口 0.03 → 0.08。
        func lips(width: Double, openness: Double) -> [(x: Double, y: Double)] {
            [(0.0, 0.0), (width * 0.6, openness), (width, 0.0), (width * 0.6, -openness)]
                .map { (x: $0.0, y: $0.1) }
        }
        let neutral = try #require(SmileGeometry.score(points: lips(width: 0.38, openness: 0.015), faceWidth: 1))
        let smiling = try #require(SmileGeometry.score(points: lips(width: 0.50, openness: 0.04), faceWidth: 1))
        #expect(neutral < 0.5, "中性脸不得饱和（旧阈值下几乎必然 =1，微笑维度失去区分度）")
        #expect(smiling > 0.7)
        #expect(smiling > neutral)
    }

    @Test("眼睛几何：脸框长宽比必须换算，否则窄脸 EAR 被系统性放大")
    func eyeOpenGeometryAccountsForFaceAspect() throws {
        let points = [(0.0, 0.0), (0.3, 0.12), (0.7, 0.12), (1.0, 0.0), (0.7, -0.12), (0.3, -0.12)]
            .map { (x: Double($0.0), y: Double($0.1)) }
        let square = try #require(EyeOpenGeometry.eyeAspectRatio(points))
        let tall = try #require(EyeOpenGeometry.eyeAspectRatio(points, aspectRatio: 1.5))
        // 归一化坐标里 y 以脸高为单位、x 以脸宽为单位：换算到同一量纲后，
        // 高瘦脸（aspect 1.5）的垂直距离变大 → EAR 恰好放大 1.5 倍。
        #expect(tall > square, "y 距离必须按脸框高/宽换算，否则长宽比会混进 EAR")
        #expect(abs(tall / square - 1.5) < 0.0001, "换算比例必须精确等于长宽比")
    }

    @Test("拉普拉斯方差：纯色 ≈ 0，棋盘格显著大于 0")
    func laplacianVariance() throws {
        let flat = [UInt8](repeating: 128, count: 64 * 64)
        let flatVariance = try #require(
            ModelReviewService.laplacianVariance(pixels: flat, width: 64, height: 64))
        #expect(flatVariance < 1e-6)

        var checker = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<64 {
            for x in 0..<64 {
                checker[y * 64 + x] = (x + y) % 2 == 0 ? 0 : 255
            }
        }
        let checkerVariance = try #require(
            ModelReviewService.laplacianVariance(pixels: checker, width: 64, height: 64))
        #expect(checkerVariance > 1000)
    }

    @Test("指纹：人脸框变化或模型版本变化都会失效")
    func fingerprintChanges() {
        let faceA = ModelReviewFaceBox(
            photoId: "p1", x: 0.1, y: 0.1, width: 0.2, height: 0.2, quality: 0.5)
        let faceB = ModelReviewFaceBox(
            photoId: "p1", x: 0.2, y: 0.1, width: 0.2, height: 0.2, quality: 0.5)
        let dims = (width: 6000, height: 4000)
        let base = ModelReviewService.fingerprint(faces: [faceA], dimensions: dims)
        #expect(base == ModelReviewService.fingerprint(faces: [faceA], dimensions: dims))
        #expect(base != ModelReviewService.fingerprint(faces: [faceB], dimensions: dims))
        // 尺寸变化（裁切/重新导出）必须失效；文件 size/mtime 变化不参与。
        #expect(base != ModelReviewService.fingerprint(
            faces: [faceA], dimensions: (width: 3000, height: 2000)))
    }

    @Test("ModelReviewResult Codable 往返（page 富化与缓存都依赖它）")
    func resultCodableRoundTrip() throws {
        let result = ModelReviewResult(
            photoId: "p1", assetFileId: "a1", status: .succeeded,
            eyesOpenScore: 0.9, smileScore: 0.4, faceFocusScore: 0.7,
            aestheticScore: 0.3, isUtilityImage: false,
            faces: [FaceReviewSignal(
                index: 0, x: 0.1, y: 0.2, width: 0.3, height: 0.4, areaRatio: 0.12,
                captureQuality: 0.8, eyeOpenScore: 0.9, smileScore: 0.4,
                focusScore: 0.7, isPrimary: true)],
            warnings: ["eyes_closed_suspected"],
            modelId: "model-review", modelVersion: "1",
            inputFingerprint: "fp", updatedAt: "2026-10-28T00:00:00.000Z")
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ModelReviewResult.self, from: encoded)
        #expect(decoded == result)
    }
}
