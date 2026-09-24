// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Quality/QualityScorerTests.swift
// W2c：QualityScorer 纯函数测试（无数据库、无解码）。
//
// 语义对照旧 Services/QualityServiceTests.swift：
// - scores a flat image...（163-198）→ score 平图；
// - computes subject/eye metrics...（298-328）→ score 人脸区域；
// - returns a failed result...（250-273）→ failed；
// - cacheHitSkipsDecode（200-229）→ fingerprint/matchCached；
// - records a failed row...（275-296）→ insertSerialization 失败指纹；
// - QualityRelativeRankTests（459-514）→ rankings，并新增与旧 O(n²)
//   applyRelativeRanks 的**对拍断言**（固定数据，rank 逐一相同）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 夹具

private func makeScorerPhoto(
    id: String,
    assetFileId: String? = nil,
    filepath: String? = nil,
    width: Int = 100,
    height: Int = 80,
    updatedAt: String = "2026-01-01T00:00:00.000Z"
) -> QualityScorer.PhotoInput {
    QualityScorer.PhotoInput(
        id: id,
        assetFileId: assetFileId ?? "af-\(id)",
        filepath: filepath ?? "/photos/\(id).jpg",
        width: width,
        height: height,
        updatedAt: updatedAt
    )
}

/// 8x8 灰度像素（前 4 行棋盘格 0/255、后 4 行均匀 128），旧测试同款。
private func scorerCheckerboardPreview8x8() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 64)
    for y in 0..<8 {
        for x in 0..<8 {
            pixels[y * 8 + x] = y < 4 ? (x % 2 == 0 ? 0 : 255) : 128
        }
    }
    return pixels
}

private func makeScorerResult(
    photoId: String,
    score: Double,
    status: QualityResultStatus = .succeeded,
    relativeRank: Double? = nil
) -> QualityResult {
    QualityResult(
        photoId: photoId,
        assetFileId: status == .succeeded ? "af-\(photoId)" : nil,
        status: status,
        errorMessage: status == .failed ? "boom" : nil,
        qualityScore: score,
        sharpness: score,
        exposure: 1,
        relativeRank: relativeRank,
        warnings: [],
        modelId: QualityModel.modelId,
        modelVersion: QualityModel.modelVersion,
        inputFingerprint: "fp-\(photoId)",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

/// 旧实现 applyRelativeRanks（QualityService.swift:502-529）的逐字副本，
/// 仅把 DB 兜底分支去掉（groups 由调用方给出）：对拍用。
private func legacyApplyRelativeRanks(
    results: inout [QualityResult],
    groups: [Int: [String]]?
) {
    let successful = Dictionary(
        uniqueKeysWithValues: results
            .filter { $0.status == .succeeded }
            .map { ($0.photoId, $0) }
    )
    guard let memberGroups = groups else { return }
    for members in memberGroups.values {
        let ranked = members
            .compactMap { successful[$0] }
            .sorted { $0.qualityScore > $1.qualityScore }
        for (index, member) in ranked.enumerated() {
            if let position = results.firstIndex(where: { $0.photoId == member.photoId }) {
                results[position].relativeRank = Double(index + 1)
            }
        }
    }
}

@Suite("QualityScorer 纯函数（W2c）")
struct QualityScorerTests {
    // MARK: 指纹 / 缓存

    @Test("fingerprint 与旧 stat 指纹逐字一致（mtime 四舍五入）")
    func fingerprintMatchesLegacyFormat() {
        #expect(QualityScorer.fingerprint(size: 2048, mtimeMs: 1000.4) == "2048:1000.0")
        #expect(QualityScorer.fingerprint(size: 2048, mtimeMs: 1000.5) == "2048:1001.0")
        #expect(QualityScorer.fingerprint(size: 0, mtimeMs: 0) == "0:0.0")
    }

    @Test("matchCached 取指纹精确匹配的第一条存储行")
    func matchCachedReturnsFirstFingerprintMatch() {
        let older = makeScorerResult(photoId: "p1", score: 0.4)
        let newer = makeScorerResult(photoId: "p1", score: 0.9)
        let entries = [
            QualityScorer.CachedEntry(fingerprint: "100:1.0", result: older),
            QualityScorer.CachedEntry(fingerprint: "100:1.0", result: newer),
            QualityScorer.CachedEntry(fingerprint: "200:2.0", result: makeScorerResult(photoId: "p2", score: 0.5)),
        ]
        #expect(QualityScorer.matchCached(entries, fingerprint: "100:1.0")?.qualityScore == 0.4)
        #expect(QualityScorer.matchCached(entries, fingerprint: "200:2.0")?.photoId == "p2")
        #expect(QualityScorer.matchCached(entries, fingerprint: "300:3.0") == nil)
        #expect(QualityScorer.matchCached([], fingerprint: "x") == nil)
    }

    // MARK: score

    @Test("score 平图：低锐度 + 有效曝光 + motion_blur 警告")
    func scoreFlatImage() {
        let result = QualityScorer.score(
            photo: makeScorerPhoto(id: "p1"),
            preview: QualityScorer.PreviewInput(pixels: [UInt8](repeating: 128, count: 16), width: 4, height: 4),
            face: nil,
            inputFingerprint: "16:123.0",
            now: "2026-07-30T10:00:00.000Z"
        )

        #expect(result.photoId == "p1")
        #expect(result.assetFileId == "af-p1")
        #expect(result.status == .succeeded)
        #expect(result.qualityScore == 0.25) // 0*0.6 + 0*0.15 + 1*0.2 + 1*0.05
        #expect(result.sharpness == 0)
        #expect(result.exposure == 1)
        #expect(result.subjectSharpness == nil)
        #expect(result.faceQuality == nil)
        #expect(result.closedEyeRisk == nil)
        #expect(result.confidence == 0.55)
        #expect(result.warnings == ["motion_blur"])
        #expect(result.modelId == "technical-quality")
        #expect(result.modelVersion == "1")
        #expect(result.inputFingerprint == "16:123.0")
        #expect(result.relativeRank == nil)
        #expect(result.updatedAt == "2026-07-30T10:00:00.000Z")
    }

    @Test("score 人脸区域：主体/眼部指标与旧 QualityService 语义一致")
    func scoreFaceRegionMetrics() throws {
        let result = QualityScorer.score(
            photo: makeScorerPhoto(id: "p1"),
            preview: QualityScorer.PreviewInput(pixels: scorerCheckerboardPreview8x8(), width: 8, height: 8),
            face: QualityScorer.FaceInput(x: 0, y: 0, w: 50, h: 20, analysisSignature: "{\"previewMaxDimension\":50}"),
            inputFingerprint: "fp",
            now: "2026-07-30T10:00:00.000Z"
        )

        let subjectSharpness = try #require(result.subjectSharpness)
        #expect(abs(subjectSharpness - 0.5) < 0.01)
        #expect(result.faceQuality == result.subjectSharpness)
        #expect(abs((result.closedEyeRisk ?? 0) - 0.13) < 0.01)
        #expect(result.confidence == 0.6)
        #expect(result.warnings.isEmpty)
        #expect(result.qualityScore == 0.591)
    }

    @Test("score：人脸签名损坏时回退照片尺寸，不抛错")
    func scoreFaceWithoutSignatureFallsBack() {
        let result = QualityScorer.score(
            photo: makeScorerPhoto(id: "p1", width: 8, height: 8),
            preview: QualityScorer.PreviewInput(pixels: scorerCheckerboardPreview8x8(), width: 8, height: 8),
            face: QualityScorer.FaceInput(x: 0, y: 0, w: 8, h: 4, analysisSignature: "not-json"),
            inputFingerprint: "fp",
            now: "2026-07-30T10:00:00.000Z"
        )
        #expect(result.status == .succeeded)
        #expect(result.subjectSharpness != nil)
        #expect(result.confidence == 0.6)
    }

    @Test("score：极低曝光追加 exposure_issue，高闭眼风险追加启发式警告")
    func scoreWarningThresholds() {
        // 全 0 像素：mean 0 → exposure 0（<0.3）；sharpness 0（<0.12）。
        let dark = QualityScorer.score(
            photo: makeScorerPhoto(id: "p1"),
            preview: QualityScorer.PreviewInput(pixels: [UInt8](repeating: 0, count: 16), width: 4, height: 4),
            face: nil,
            inputFingerprint: "fp",
            now: "2026-07-30T10:00:00.000Z"
        )
        #expect(dark.exposure == 0)
        #expect(dark.warnings.contains("motion_blur"))
        #expect(dark.warnings.contains("exposure_issue"))
        #expect(!dark.warnings.contains("closed_eye_risk_heuristic"))
    }

    // MARK: failed

    @Test("failed 结果字段与旧 QualityService 失败路径逐字一致")
    func failedResultMatchesLegacy() {
        let result = QualityScorer.failed(
            photoId: "p1",
            assetFileId: "af-1",
            errorMessage: "QUALITY_NO_ASSET_FILE",
            now: "2026-07-30T10:00:00.000Z"
        )
        #expect(result.status == .failed)
        #expect(result.errorMessage == "QUALITY_NO_ASSET_FILE")
        #expect(result.qualityScore == 0)
        #expect(result.sharpness == 0)
        #expect(result.exposure == 0)
        #expect(result.warnings == ["analysis_failed"])
        #expect(result.modelId == "technical-quality")
        #expect(result.modelVersion == "1")
        #expect(result.inputFingerprint == "")
        #expect(result.updatedAt == "2026-07-30T10:00:00.000Z")
        #expect(result.relativeRank == nil)
        #expect(result.confidence == nil)
    }

    // MARK: insertSerialization

    @Test("insertSerialization：成功行用 result.inputFingerprint，JSON 可回读")
    func insertSerializationSuccess() throws {
        let result = QualityScorer.score(
            photo: makeScorerPhoto(id: "p1"),
            preview: QualityScorer.PreviewInput(pixels: [UInt8](repeating: 128, count: 16), width: 4, height: 4),
            face: nil,
            inputFingerprint: "16:123.0",
            now: "2026-07-30T10:00:00.000Z"
        )
        let row = try #require(try QualityScorer.insertSerialization(result: result, photoUpdatedAt: "T"))
        #expect(row.photoId == "p1")
        #expect(row.assetFileId == "af-p1")
        #expect(row.fingerprint == "16:123.0")
        #expect(row.updatedAt == "2026-07-30T10:00:00.000Z")
        #expect(row.warningsJson == "[\"motion_blur\"]")

        let decoded = try JSONDecoder().decode(QualityResult.self, from: Data(row.resultJson.utf8))
        #expect(decoded == result)
    }

    @Test("insertSerialization：失败行指纹为 failed:<photo.updatedAt>")
    func insertSerializationFailure() throws {
        let result = QualityScorer.failed(
            photoId: "p1", assetFileId: "af-1", errorMessage: "decode exploded",
            now: "2026-07-30T10:00:00.000Z"
        )
        let row = try #require(try QualityScorer.insertSerialization(
            result: result, photoUpdatedAt: "2026-01-01T00:00:00.000Z"
        ))
        #expect(row.fingerprint == "failed:2026-01-01T00:00:00.000Z")
        #expect(row.updatedAt == "2026-07-30T10:00:00.000Z")
        let decoded = try JSONDecoder().decode(QualityResult.self, from: Data(row.resultJson.utf8))
        #expect(decoded.status == .failed)
        #expect(decoded.errorMessage == "decode exploded")
    }

    @Test("insertSerialization：assetFileId 缺失不落库（返回 nil）")
    func insertSerializationSkipsWithoutAssetFile() throws {
        let result = QualityScorer.failed(
            photoId: "p1", assetFileId: nil, errorMessage: "QUALITY_NO_ASSET_FILE"
        )
        #expect(try QualityScorer.insertSerialization(result: result, photoUpdatedAt: "T") == nil)
    }

    // MARK: rankings（含与旧 O(n²) 实现的对拍）

    @Test("rankings 与旧 applyRelativeRanks 对拍：固定数据 rank 逐一相同")
    func rankingsMatchLegacyImplementation() {
        let groups: [Int: [String]] = [
            0: ["p3", "p1", "p2", "missing", "p4"],
            1: ["p6", "p5"],
            2: ["p7"],
            4: ["p8"],
        ]
        let fixture = [
            makeScorerResult(photoId: "p1", score: 0.4, relativeRank: 7),
            makeScorerResult(photoId: "p2", score: 0.9),
            makeScorerResult(photoId: "p3", score: 1.0),
            makeScorerResult(photoId: "p4", score: 0.9),
            makeScorerResult(photoId: "p5", score: 0.5, status: .failed, relativeRank: 3),
            makeScorerResult(photoId: "p6", score: 0.2),
            makeScorerResult(photoId: "p7", score: 0.9),
            makeScorerResult(photoId: "p8", score: 0.0, relativeRank: 9),
        ]

        var legacy = fixture
        legacyApplyRelativeRanks(results: &legacy, groups: groups)
        var ranked = fixture
        QualityScorer.rankings(results: &ranked, groups: groups)

        let legacyRanks = Dictionary(uniqueKeysWithValues: legacy.map { ($0.photoId, $0.relativeRank) })
        let newRanks = Dictionary(uniqueKeysWithValues: ranked.map { ($0.photoId, $0.relativeRank) })
        #expect(newRanks == legacyRanks)
        // 固定期望值（组内成功结果按分数降序 index+1）：
        #expect(newRanks["p3"] == 1)
        #expect(newRanks["p2"] == 2)   // 同分按成员出现序（p2 在 p4 前）
        #expect(newRanks["p4"] == 3)
        #expect(newRanks["p1"] == 4)
        #expect(newRanks["p6"] == 1)   // p5 失败不占位
        #expect(newRanks["p5"] == 3)   // 失败结果保持原值
        #expect(newRanks["p7"] == 1)   // 单成员组
        #expect(newRanks["p8"] == 1)   // 组 4
    }

    @Test("rankings 对拍：平移/重复/缺失成员与无组路径")
    func rankingsEdgeCasesMatchLegacy() {
        var groups: [Int: [String]] = [
            0: ["a", "a", "b"],       // 重复成员：两次赋值，后者覆盖（index+1 递增）
            1: ["missing"],           // 组内无本次结果：无赋值
            5: [],
            3: ["b", "c"],            // b 同时出现在组 0 与组 3：后写覆盖
        ]
        let fixture = [
            makeScorerResult(photoId: "a", score: 0.3),
            makeScorerResult(photoId: "b", score: 0.6),
            makeScorerResult(photoId: "c", score: 0.1, status: .failed),
        ]

        var legacy = fixture
        legacyApplyRelativeRanks(results: &legacy, groups: groups)
        var ranked = fixture
        QualityScorer.rankings(results: &ranked, groups: groups)
        #expect(
            Dictionary(uniqueKeysWithValues: ranked.map { ($0.photoId, $0.relativeRank) })
                == Dictionary(uniqueKeysWithValues: legacy.map { ($0.photoId, $0.relativeRank) })
        )

        // nil groups：no-op，原值保持。
        var noop = fixture
        QualityScorer.rankings(results: &noop, groups: nil)
        #expect(noop == fixture)

        // 空 members 的 groups 同样 no-op。
        groups[5] = []
        var emptyGroup = fixture
        QualityScorer.rankings(results: &emptyGroup, groups: [5: []])
        #expect(emptyGroup == fixture)
    }

    @Test("rankings 大输入（20000 结果单组）线性完成（旧 O(N×Σm) 预算内不可能）")
    func rankingsLargeInputCompletesQuickly() {
        let count = 20_000
        var results: [QualityResult] = []
        results.reserveCapacity(count)
        for index in 0..<count {
            results.append(makeScorerResult(photoId: "p\(index)", score: Double(index) / Double(count)))
        }
        let members = results.map(\.photoId) // 分数升序

        let elapsed = ContinuousClock().measure {
            QualityScorer.rankings(results: &results, groups: [0: members])
        }

        #expect(elapsed < .seconds(2))
        #expect(results.first { $0.photoId == "p19999" }?.relativeRank == 1)
        #expect(results.first { $0.photoId == "p0" }?.relativeRank == Double(count))
    }

    @Test("rankings 保序：多组 rank 与组键顺序无关（确定性）")
    func rankingsAreDeterministicAcrossGroupOrder() {
        let groupsA: [Int: [String]] = [2: ["c"], 0: ["a", "b"]]
        let groupsB: [Int: [String]] = [0: ["a", "b"], 2: ["c"]]
        let fixture = [
            makeScorerResult(photoId: "a", score: 0.2),
            makeScorerResult(photoId: "b", score: 0.8),
            makeScorerResult(photoId: "c", score: 0.5),
        ]
        var first = fixture
        QualityScorer.rankings(results: &first, groups: groupsA)
        var second = fixture
        QualityScorer.rankings(results: &second, groups: groupsB)
        #expect(first == second)
        #expect(first.first { $0.photoId == "b" }?.relativeRank == 1)
        #expect(first.first { $0.photoId == "a" }?.relativeRank == 2)
        #expect(first.first { $0.photoId == "c" }?.relativeRank == 1)
    }
}
