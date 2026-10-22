// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceRealPhotoPipelineTests.swift
// 真实素材验证。**默认跳过**，用环境变量指一张有人脸的照片即可启用：
//
//   GATHER_FACE_FIXTURE=/tmp/face.jpg swift test --package-path desktop/native/gather-core \
//     --filter FaceRealPhotoPipelineTests
//
// 为什么不自动去 tests/fixtures/local/raw 找：那里是用户写真目录的软链（RAW，几十 MB/张），
// 且本机测试进程实测无法从 Data 解 RAW（ImageIO 报 cannotCreateImageSource）、目录列举
// 还会在某些视图下报 ENOTDIR —— 自动发现会让"夹具在但跑不了"变成红。需要时先转码：
//   sips -s format jpeg -Z 1600 <photo.NEF> --out /tmp/face.jpg
//
// 覆盖目标：
//   · 真实照片真的能走通 检测 → 5 点对齐 → 768 维单位向量（合成数据只验证了算法逻辑）；
//   · 编码失败必须被计数而不是静默吞掉（对抗审查阻断项 2 的上游半段）：
//     抛错的嵌入器 + 有脸的照片 → faces 为空且 encodeFailures > 0，上层据此才不会把
//     "编码全失败"当成"这张照片没有脸"（进而删旧簇与人工绑定）。

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GatherDomain
@testable import GatherProtocol
@testable import GatherAnalysis

@Suite("真实照片人脸管线（需 GATHER_FACE_FIXTURE）")
struct FaceRealPhotoPipelineTests {
    /// 环境变量指向的真实照片字节；不存在/不可解码则为 nil（整组跳过）。
    static let fixtureImageData: Data? = {
        guard let path = ProcessInfo.processInfo.environment["GATHER_FACE_FIXTURE"],
            !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
            CGImageSourceCreateWithData(data as CFData, nil) != nil else { return nil }
        return data
    }()

    // skip-owner: face-pipeline
    // 到期：2026-12-31（真实照片夹具纳入受控 fixture，或移入 scripts/manual 后删除本 gate）。
    // 原因：真实照片夹具需手动提供 GATHER_FACE_FIXTURE；CI 不设置该变量，用例必然 skip。
    // 手动 CI 条件：GATHER_FACE_FIXTURE=/tmp/face.jpg swift test --filter FaceRealPhotoPipelineTests。
    @Test("真实人像：检测 + 对齐 + 768 维单位向量 + 质量/框合法", .enabled(if: fixtureImageData != nil))
    func realPhotoProducesValidEmbedding() throws {
        let data = try #require(Self.fixtureImageData)
        let batch = try FaceEncoder.encodeFacesDetailed(in: data)
        #expect(!batch.faces.isEmpty, "真实人像应至少检测到一张脸")
        // 一行证据输出：跑这条用例的人能直接看到"真实素材上到底检测到几张、维度多少"。
        print(
            "REAL_PHOTO faces=\(batch.faces.count) dim=\(batch.faces.first?.embedding.count ?? 0) "
                + "quality=\(String(format: "%.3f", batch.faces.first?.quality ?? 0)) "
                + "encodeFailures=\(batch.encodeFailures)")
        for face in batch.faces {
            #expect(face.embedding.count == 768, "Vision feature print 应为 768 维")
            let norm = sqrt(face.embedding.reduce(0) { $0 + $1 * $1 })
            #expect(abs(norm - 1) < 1e-6, "落库前必须归一化（实际模长 \(norm)）")
            #expect(face.quality > 0 && face.quality <= 1)
            #expect(face.bbox.count == 4)
            for value in face.bbox { #expect(value >= -0.001 && value <= 1.001) }
        }
    }

    // skip-owner: face-pipeline
    // 到期：2026-12-31（同上，真实照片夹具受控化后删除本 gate）。
    // 原因：同 realPhotoProducesValidEmbedding，依赖手动 GATHER_FACE_FIXTURE；CI 必然 skip。
    // 手动 CI 条件：GATHER_FACE_FIXTURE=/tmp/face.jpg swift test --filter FaceRealPhotoPipelineTests。
    @Test("嵌入器抛错：失败被计数而不是当成没有脸", .enabled(if: fixtureImageData != nil))
    func embedderFailureIsCounted() throws {
        let data = try #require(Self.fixtureImageData)
        let batch = try FaceEncoder.encodeFacesDetailed(
            in: data, embedder: AlwaysFailingEmbedder())
        #expect(batch.faces.isEmpty)
        #expect(batch.encodeFailures > 0, "检测到脸但嵌入失败必须计数（否则上层会写 analysis_state 并删旧簇）")
        #expect(batch.detectedFaces == batch.encodeFailures)
    }

    // skip-owner: face-pipeline
    // 到期：2026-12-31（同上，真实照片夹具受控化后删除本 gate）。
    // 原因：同 realPhotoProducesValidEmbedding，依赖手动 GATHER_FACE_FIXTURE；CI 必然 skip。
    // 手动 CI 条件：GATHER_FACE_FIXTURE=/tmp/face.jpg swift test --filter FaceRealPhotoPipelineTests。
    @Test("同一张真实照片两次编码一致（Vision 确定性）", .enabled(if: fixtureImageData != nil))
    func realPhotoEncodingIsDeterministic() throws {
        let data = try #require(Self.fixtureImageData)
        let first = try FaceEncoder.encodeFacesDetailed(in: data)
        let second = try FaceEncoder.encodeFacesDetailed(in: data)
        #expect(first.faces.count == second.faces.count)
        for (lhs, rhs) in zip(first.faces, second.faces) {
            #expect(lhs.embedding == rhs.embedding, "同一输入必须给出同一向量（否则聚类结果不稳定）")
        }
    }
}

/// 恒失败的嵌入器（模拟"模型配置错/输入不受支持"）。
private struct AlwaysFailingEmbedder: FaceEmbeddingProvider {
    let spec = FaceEmbeddingSpec(
        modelId: "always-failing", modelVersion: "test", dimension: 8, signature: "always-failing")
    func embed(alignedFace: CGImage) throws -> [Double] {
        throw FaceEmbeddingError.emptyOutput
    }
}