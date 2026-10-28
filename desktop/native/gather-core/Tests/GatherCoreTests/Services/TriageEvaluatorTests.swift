// desktop/native/gather-core/Tests/GatherCoreTests/Services/TriageEvaluatorTests.swift
// P0 / T0：纯函数初筛器单测。覆盖设计 §11 的 20 个样例与关键边界。
// 只测纯函数，不涉及 API/仓储/UI。
import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol

private func quality(
    _ id: String,
    _ score: Double,
    focus: Double? = nil,
    exposure: Double = 0.60,
    closedEyeRisk: Double? = nil,
    warnings: [String] = [],
    status: QualityResultStatus = .succeeded
) -> QualityResult {
    QualityResult(
        photoId: id,
        status: status,
        errorMessage: status == .failed ? "failed" : nil,
        qualityScore: score,
        sharpness: focus ?? score,
        exposure: exposure,
        subjectSharpness: focus,
        closedEyeRisk: closedEyeRisk,
        warnings: warnings,
        modelId: "test",
        modelVersion: "1",
        inputFingerprint: "fp",
        updatedAt: "2026-10-25T00:00:00.000Z"
    )
}

private func failedQuality(_ id: String) -> QualityResult {
    quality(id, 0, status: .failed)
}

private func group(
    _ kind: TriageGroupRef.Kind,
    _ id: String,
    _ members: [String],
    lead: String? = nil
) -> TriageGroupRef {
    TriageGroupRef(kind: kind, groupId: id, memberPhotoIds: members, leadPhotoId: lead)
}

private func candidate(
    _ id: String,
    _ quality: QualityResult?,
    faces: Int = 0,
    area: Double = 0,
    groups: [TriageGroupRef] = [],
    manual: CullingDecisionValue? = nil,
    source: CullingDecisionSource? = nil,
    order: Int = 0,
    width: Int = 0,
    height: Int = 0,
    fileSize: Int64 = 0,
    model: ModelReviewResult? = nil
) -> TriageCandidate {
    TriageCandidate(
        photoId: id,
        quality: quality,
        modelReview: model,
        faceCount: faces,
        maxFaceAreaRatio: area,
        groups: groups,
        manualDecision: manual,
        decisionSource: source,
        importOrder: order,
        width: width,
        height: height,
        fileSize: fileSize
    )
}

private func result(_ evaluations: [TriageEvaluation], _ id: String) -> TriageResult? {
    for evaluation in evaluations {
        if case .suggestion(let result) = evaluation, result.photoId == id {
            return result
        }
    }
    return nil
}

private func codes(_ result: TriageResult?) -> [TriageReasonCode] {
    result?.reasons.map(\.code) ?? []
}

private func expectReview(_ result: TriageResult?, _ id: String) {
    #expect(result?.photoId == id)
    #expect(result?.verdict == .review)
}

@Suite
struct TriageEvaluatorTests {
    // MARK: - §11 样例

    @Test("P01-P03：相似组最佳/接近/模糊")
    func sampleSimilarityGroup() throws {
        let g = group(.similarity, "sim:1:0", ["p01", "p02", "p03"])
        let candidates = [
            candidate("p01", quality("p01", 0.86, focus: 0.90, exposure: 0.60), faces: 1, area: 0.05, groups: [g], order: 1),
            candidate("p02", quality("p02", 0.78, focus: 0.85, exposure: 0.60), faces: 1, area: 0.05, groups: [g], order: 2),
            candidate("p03", quality("p03", 0.52, focus: 0.05, exposure: 0.50, warnings: ["motion_blur"]), faces: 1, area: 0.05, groups: [g], order: 3),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)

        let p01 = try #require(result(out, "p01"))
        #expect(p01.verdict == .keep)
        #expect(abs(p01.confidence - 0.67) < 0.02)
        #expect(codes(p01).contains(.groupBest))

        let p02 = try #require(result(out, "p02"))
        #expect(p02.verdict == .review)
        #expect(abs(p02.confidence - 0.55) < 0.03)
        #expect(codes(p02).contains(.closeCall))
        #expect(codes(p02).contains(.weakerThanGroupBest))

        let p03 = try #require(result(out, "p03"))
        #expect(p03.verdict == .reject)
        #expect(abs(p03.confidence - 0.96) < 0.03)
        #expect(codes(p03).contains(.motionBlur))
        #expect(codes(p03).contains(.weakerThanGroupBest))
    }

    @Test("P04-P05：并列不猜")
    func sampleTie() throws {
        let g = group(.similarity, "sim:2:0", ["p04", "p05"])
        let candidates = [
            candidate("p04", quality("p04", 0.80, focus: 0.80, exposure: 0.80), groups: [g], order: 1),
            candidate("p05", quality("p05", 0.79, focus: 0.79, exposure: 0.80), groups: [g], order: 2),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        for id in ["p04", "p05"] {
            let r = try #require(result(out, id))
            #expect(r.verdict == .review)
            #expect(codes(r).contains(.tieWithGroup))
            #expect(r.confidence < 0.60)
        }
    }

    @Test("P06-P08：完全重复优先于相似组")
    func sampleExactDuplicates() throws {
        let exact = group(.exactDuplicate, "dup:1", ["p06", "p07", "p08"])
        // 同时挂一个相似组，验证 exact 优先。
        let sim = group(.similarity, "sim:3:0", ["p06", "p07", "p08"])
        let candidates = [
            candidate("p06", quality("p06", 0.70, focus: 0.70, exposure: 0.70), groups: [exact, sim], order: 1),
            candidate("p07", quality("p07", 0.70, focus: 0.70, exposure: 0.70), groups: [exact, sim], order: 2),
            candidate("p08", quality("p08", 0.70, focus: 0.70, exposure: 0.70), groups: [exact, sim], order: 3),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        let p06 = try #require(result(out, "p06"))
        #expect(p06.verdict == .keep)
        #expect(p06.confidence == 0.90)
        #expect(Set(codes(p06)) == Set([.duplicateExact, .groupBest]))
        for id in ["p07", "p08"] {
            let r = try #require(result(out, id))
            #expect(r.verdict == .reject)
            #expect(r.confidence == 0.95)
            #expect(codes(r) == [.duplicateExact])
        }
    }

    @Test("P09-P10：单张好片/低质")
    func sampleSingles() throws {
        let good = evaluateTriage(candidates: [
            candidate("p09", quality("p09", 0.82, focus: 0.82, exposure: 0.80)),
        ], policy: .v1)
        let p09 = try #require(result(good, "p09"))
        #expect(p09.verdict == .keep)
        #expect(abs(p09.confidence - 0.77) < 0.02)
        #expect(codes(p09).contains(.singleShot))

        let low = evaluateTriage(candidates: [
            candidate("p10", quality("p10", 0.40, focus: 0.40, exposure: 0.40)),
        ], policy: .v1)
        let p10 = try #require(result(low, "p10"))
        #expect(p10.verdict == .review)
        #expect(p10.confidence >= 0.55)
        #expect(codes(p10) == [.noAlternative, .lowTechnical])
    }

    @Test("P11-P13：合影最佳/第二/模糊")
    func sampleGroupPortraits() throws {
        let g = group(.similarity, "sim:4:0", ["p11", "p12", "p13"])
        let candidates = [
            candidate("p11", quality("p11", 0.88, focus: 0.90, exposure: 0.70), faces: 4, area: 0.08, groups: [g], order: 1),
            candidate("p12", quality("p12", 0.70, focus: 0.72, exposure: 0.70), faces: 4, area: 0.08, groups: [g], order: 2),
            candidate("p13", quality("p13", 0.46, focus: 0.05, exposure: 0.60, warnings: ["motion_blur"]), faces: 4, area: 0.08, groups: [g], order: 3),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)

        let p11 = try #require(result(out, "p11"))
        #expect(p11.verdict == .keep)
        #expect(abs(p11.confidence - 0.70) < 0.03)
        #expect(codes(p11) == [.groupBest])

        let p12 = try #require(result(out, "p12"))
        #expect(p12.verdict == .review)
        #expect(abs(p12.confidence - 0.60) < 0.02)
        #expect(codes(p12).contains(.multiFaceLowConfidence))
        #expect(codes(p12).contains(.weakerThanGroupBest))

        let p13 = try #require(result(out, "p13"))
        #expect(p13.verdict == .reject)
        #expect(p13.confidence >= 0.90)
        #expect(codes(p13).contains(.motionBlur))
    }

    @Test("P14-P15：未分析/失败只复核")
    func sampleNotAnalyzed() throws {
        let missing = evaluateTriage(candidates: [
            candidate("p14", nil),
        ], policy: .v1)
        let p14 = try #require(result(missing, "p14"))
        #expect(p14.verdict == .review)
        #expect(p14.confidence == 0)
        #expect(codes(p14) == [.qualityMissing])

        let failed = evaluateTriage(candidates: [
            candidate("p15", failedQuality("p15")),
        ], policy: .v1)
        let p15 = try #require(result(failed, "p15"))
        #expect(p15.verdict == .review)
        #expect(p15.confidence == 0)
        #expect(codes(p15) == [.analysisFailed])
    }

    @Test("P16-P17：人工已决策不生成")
    func sampleManualExcluded() throws {
        let g = group(.similarity, "sim:5:0", ["p16", "p17", "p18"])
        let candidates = [
            candidate("p16", quality("p16", 0.90), groups: [g], manual: .keep, source: .manual, order: 1),
            candidate("p17", quality("p17", 0.50), groups: [g], manual: .reject, source: .manual, order: 2),
            candidate("p18", quality("p18", 0.70), groups: [g], order: 3),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        if case .excluded(.manualOverride) = out[0] {} else {
            Issue.record("p16 应被人工排除")
        }
        if case .excluded(.manualOverride) = out[1] {} else {
            Issue.record("p17 应被人工排除")
        }
        #expect(result(out, "p18") != nil)
    }

    @Test("P18-P19：小脸最佳/第二")
    func sampleSmallFace() throws {
        let g = group(.similarity, "sim:6:0", ["p18", "p19"])
        let candidates = [
            candidate("p18", quality("p18", 0.74, focus: 0.74, exposure: 0.70), faces: 1, area: 0.005, groups: [g], order: 1),
            candidate("p19", quality("p19", 0.62, focus: 0.62, exposure: 0.70), faces: 1, area: 0.005, groups: [g], order: 2),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        let p18 = try #require(result(out, "p18"))
        #expect(p18.verdict == .keep)
        #expect(codes(p18).contains(.groupBest))
        #expect(codes(p18).contains(.smallFace))

        let p19 = try #require(result(out, "p19"))
        #expect(p19.verdict == .review)
        #expect(codes(p19).contains(.smallFace))
        #expect(codes(p19).contains(.closeCall))
    }

    @Test("P20：RAW/JPEG 单资产按一个候选处理")
    func sampleRawJpegLogicalAsset() throws {
        let out = evaluateTriage(candidates: [
            candidate("p20", quality("p20", 0.70, focus: 0.70, exposure: 0.70)),
        ], policy: .v1)
        let p20 = try #require(result(out, "p20"))
        #expect(p20.verdict == .keep)
        #expect(abs(p20.confidence - 0.68) < 0.02)
        #expect(codes(p20) == [.singleShot])
    }

    // MARK: - 边界

    @Test("单张永不 reject；低质只 review")
    func singleNeverRejects() throws {
        let out = evaluateTriage(candidates: [
            candidate("s1", quality("s1", 0.40, focus: 0.40, exposure: 0.40)),
        ], policy: .v1)
        let r = try #require(result(out, "s1"))
        #expect(r.verdict == .review)
        #expect(codes(r).contains(.lowTechnical))
    }

    @Test("组内未分析成员被忽略；只剩自己按无替代")
    func unanalyzedGroupMembersIgnored() throws {
        let g = group(.similarity, "sim:7:0", ["u1", "u2", "u3"])
        let candidates = [
            candidate("u1", quality("u1", 0.80, focus: 0.80, exposure: 0.70), groups: [g], order: 1),
            candidate("u2", nil, groups: [g], order: 2),
            candidate("u3", quality("u3", 0.40, focus: 0.40, exposure: 0.70), groups: [g], order: 3),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        let u1 = try #require(result(out, "u1"))
        #expect(u1.verdict == .keep)
        #expect(codes(u1).contains(.groupBest))
        #expect(result(out, "u2")?.verdict == .review)
        // u3 与 u1 同组：gap .40，有合格替代 → reject。
        let u3 = try #require(result(out, "u3"))
        #expect(u3.verdict == .reject)
    }

    @Test("组内只有一个已分析成员：按无替代处理")
    func onlyOneAnalyzedMember() throws {
        let g = group(.similarity, "sim:7:1", ["o1", "o2"])
        let out = evaluateTriage(candidates: [
            candidate("o1", quality("o1", 0.80, focus: 0.80, exposure: 0.70), groups: [g], order: 1),
            candidate("o2", nil, groups: [g], order: 2),
        ], policy: .v1)
        let o1 = try #require(result(out, "o1"))
        #expect(o1.verdict == .keep)
        #expect(codes(o1).contains(.noAlternative))
    }

    @Test("闭眼保护：最佳也 review，非最佳也不 reject")
    func closedEyeProtection() throws {
        let g = group(.similarity, "sim:8:0", ["c1", "c2"])
        let candidates = [
            candidate("c1", quality("c1", 0.90, focus: 0.90, exposure: 0.70, closedEyeRisk: 0.90), faces: 1, area: 0.05, groups: [g], order: 1),
            candidate("c2", quality("c2", 0.60, focus: 0.60, exposure: 0.70, closedEyeRisk: 0.90), faces: 1, area: 0.05, groups: [g], order: 2),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        #expect(result(out, "c1")?.verdict == .review)
        #expect(codes(result(out, "c1")).contains(.closedEyeSuspect))
        #expect(result(out, "c2")?.verdict == .review)
        #expect(codes(result(out, "c2")).contains(.closedEyeSuspect))
    }

    @Test("多脸：排名型 reject 降 review，硬技术失败仍 reject")
    func multiFaceProtection() throws {
        let g1 = group(.similarity, "sim:9:0", ["m1", "m2"])
        let soft = [
            candidate("m1", quality("m1", 0.90, focus: 0.90, exposure: 0.70), faces: 4, area: 0.08, groups: [g1], order: 1),
            candidate("m2", quality("m2", 0.50, focus: 0.60, exposure: 0.70), faces: 4, area: 0.08, groups: [g1], order: 2),
        ]
        let out1 = evaluateTriage(candidates: soft, policy: .v1)
        #expect(result(out1, "m2")?.verdict == .review)
        #expect(codes(result(out1, "m2")).contains(.multiFaceLowConfidence))

        let g2 = group(.similarity, "sim:9:1", ["m3", "m4"])
        let hard = [
            candidate("m3", quality("m3", 0.90, focus: 0.90, exposure: 0.70), faces: 4, area: 0.08, groups: [g2], order: 1),
            candidate("m4", quality("m4", 0.50, focus: 0.05, exposure: 0.70), faces: 4, area: 0.08, groups: [g2], order: 2),
        ]
        let out2 = evaluateTriage(candidates: hard, policy: .v1)
        #expect(result(out2, "m4")?.verdict == .reject)
    }

    @Test("原因最多 3 条并按码表排序")
    func reasonOrderAndLimit() throws {
        let g = group(.similarity, "sim:10:0", ["r1", "r2"])
        let candidates = [
            candidate("r1", quality("r1", 0.90, focus: 0.90, exposure: 0.70), groups: [g], order: 1),
            candidate("r2", quality("r2", 0.40, focus: 0.05, exposure: 0.10), groups: [g], order: 2),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        let r2 = try #require(result(out, "r2"))
        #expect(r2.reasons.count <= 3)
        let order = codes(r2)
        #expect(order.first == .weakerThanGroupBest)
        if let motion = order.firstIndex(of: .motionBlur),
           let exposure = order.firstIndex(of: .exposureLow) {
            #expect(motion < exposure)
        }
    }

    @Test("确定性：同输入同输出")
    func deterministic() throws {
        let g = group(.similarity, "sim:11:0", ["d1", "d2"])
        let candidates = [
            candidate("d1", quality("d1", 0.80), groups: [g], order: 1),
            candidate("d2", quality("d2", 0.50), groups: [g], order: 2),
        ]
        #expect(evaluateTriage(candidates: candidates, policy: .v1) == evaluateTriage(candidates: candidates, policy: .v1))
    }

    @Test("exact 组不受质量/margin 限制")
    func exactIgnoresQuality() throws {
        let g = group(.exactDuplicate, "dup:2", ["e1", "e2"])
        let candidates = [
            candidate("e1", quality("e1", 0.20, focus: 0.20, exposure: 0.20), groups: [g], order: 1),
            candidate("e2", quality("e2", 0.90, focus: 0.90, exposure: 0.90), groups: [g], order: 2),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        #expect(result(out, "e1")?.verdict == .keep)
        #expect(result(out, "e2")?.verdict == .reject)
    }

    @Test("exact 组最佳：分辨率优先，其次文件大小，最后才看导入序")
    func exactBestUsesResolutionThenSize() {
        let g = group(.exactDuplicate, "dup:3", ["lo", "hi", "hiBig"])
        let candidates = [
            candidate("lo", quality("lo", 0.99, focus: 0.90), groups: [g], order: 1,
                      width: 3000, height: 2000, fileSize: 9_000_000),
            candidate("hi", quality("hi", 0.40, focus: 0.90), groups: [g], order: 2,
                      width: 6000, height: 4000, fileSize: 3_000_000),
            candidate("hiBig", quality("hiBig", 0.40, focus: 0.90), groups: [g], order: 3,
                      width: 6000, height: 4000, fileSize: 8_000_000),
        ]
        let out = evaluateTriage(candidates: candidates)
        #expect(result(out, "hiBig")?.verdict == .keep)
        #expect(result(out, "lo")?.verdict == .reject)
        #expect(result(out, "hi")?.verdict == .reject)
    }

    @Test("exact 组最佳必须来自已分析成员：无质量行的高分片不占 best")
    func exactBestSkipsUnanalyzed() {
        let g = group(.exactDuplicate, "dup:4", ["raw", "jpg"])
        let candidates = [
            candidate("raw", nil, groups: [g], order: 1,
                      width: 6000, height: 4000, fileSize: 9_000_000),
            candidate("jpg", quality("jpg", 0.80, focus: 0.80), groups: [g], order: 2,
                      width: 6000, height: 4000, fileSize: 3_000_000),
        ]
        let out = evaluateTriage(candidates: candidates)
        #expect(result(out, "jpg")?.verdict == .keep)
        #expect(result(out, "raw")?.verdict == .review)
        #expect(codes(result(out, "raw")).contains(.qualityMissing))
    }

    @Test("exact 组也必须过 executionFloor：门限抬高后 keep/reject 一律 review")
    func exactRespectsExecutionFloor() {
        let g = group(.exactDuplicate, "dup:5", ["a", "b"])
        let policy = TriagePolicy(minExecutableConfidence: 0.96)
        let candidates = [
            candidate("a", quality("a", 0.90, focus: 0.90), groups: [g], order: 1,
                      width: 6000, height: 4000, fileSize: 9_000_000),
            candidate("b", quality("b", 0.90, focus: 0.90), groups: [g], order: 2,
                      width: 3000, height: 2000, fileSize: 3_000_000),
        ]
        let out = evaluateTriage(candidates: candidates, policy: policy)
        #expect(result(out, "a")?.verdict == .review)
        #expect(result(out, "b")?.verdict == .review)
    }

    @Test("门槛：非硬差距不足 0.75 只 review，足够才 reject")
    func rejectThresholdGate() throws {
        let g = group(.similarity, "sim:12:0", ["best", "mid", "weak"])
        let candidates = [
            candidate("best", quality("best", 0.90, focus: 0.80, exposure: 0.60), groups: [g], order: 1),
            candidate("mid", quality("mid", 0.76, focus: 0.80, exposure: 0.60), groups: [g], order: 2),
            candidate("weak", quality("weak", 0.50, focus: 0.80, exposure: 0.60), groups: [g], order: 3),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)

        let mid = try #require(result(out, "mid"))
        #expect(mid.verdict == .review)
        #expect(mid.confidence < 0.75)

        let weak = try #require(result(out, "weak"))
        #expect(weak.verdict == .reject)
        #expect(weak.confidence >= 0.75)
    }

    @Test("单张边界：q=0.60 keep，0.59 review")
    func singleThresholdBoundary() throws {
        let atBoundary = evaluateTriage(
            candidates: [candidate("edge", quality("edge", 0.60, focus: 0.60, exposure: 0.60), order: 1)],
            policy: .v1
        )
        #expect(result(atBoundary, "edge")?.verdict == .keep)

        let below = evaluateTriage(
            candidates: [candidate("below", quality("below", 0.59, focus: 0.59, exposure: 0.60), order: 1)],
            policy: .v1
        )
        #expect(result(below, "below")?.verdict == .review)
        #expect(codes(result(below, "below")).contains(.lowTechnical))
    }

    @Test("门槛：组内最佳 margin 达标但证据不足转 review")
    func bestKeepThresholdGate() throws {
        let g = group(.similarity, "sim:13:0", ["b1", "b2"])
        let candidates = [
            candidate("b1", quality("b1", 0.86, focus: 0.45, exposure: 0.35), groups: [g], order: 1),
            candidate("b2", quality("b2", 0.80, focus: 0.80, exposure: 0.60), groups: [g], order: 2),
        ]
        let out = evaluateTriage(candidates: candidates, policy: .v1)
        let b1 = try #require(result(out, "b1"))
        #expect(b1.verdict == .review)
        #expect(codes(b1).contains(.closeCall))
    }

    // MARK: - P1：组内最佳合格性 / 可执行下限 / 视觉重复理由

    @Test("组内最佳只在技术合格成员中选：硬失败的高分照片不占 best")
    func groupBestExcludesHardFailed() {
        let g = group(.similarity, "sim:20:0", ["a", "b", "c"])
        let candidates = [
            candidate("a", quality("a", 0.95, focus: 0.05), groups: [g], order: 0),
            candidate("b", quality("b", 0.70, focus: 0.90), groups: [g], order: 1),
            candidate("c", quality("c", 0.60, focus: 0.90), groups: [g], order: 2),
        ]
        let results = evaluateTriage(candidates: candidates)
        #expect(result(results, "b")?.verdict == .keep)
        #expect(result(results, "a")?.verdict == .review)
        #expect(result(results, "c")?.verdict == .review)
        let rejected = results.contains { evaluation in
            guard case .suggestion(let r) = evaluation else { return false }
            return r.verdict == .reject
        }
        #expect(!rejected)
    }

    @Test("minExecutable 抬高后：高于方向下限的置信度也只能 review")
    func minExecutableGatesGeneration() {
        let policy = TriagePolicy(keepConfidenceMin: 0.40, minExecutableConfidence: 1.0)
        let candidates = [candidate("a", quality("a", 0.90, focus: 0.90))]
        let results = evaluateTriage(candidates: candidates, policy: policy)
        #expect(result(results, "a")?.verdict == .review)
        #expect(policy.executionFloor(for: .keep) == 1.0)
    }

    @Test("人工淘汰组内最佳后：其余成员不再以它为锚点被判 reject")
    func manualRejectedBestDoesNotAnchorReject() throws {
        let g = group(.similarity, "sim:21:0", ["best", "second", "third"])
        let candidates = [
            candidate("best", quality("best", 0.95, focus: 0.95), groups: [g],
                      manual: .reject, source: .manual, order: 0),
            candidate("second", quality("second", 0.60, focus: 0.90), groups: [g], order: 1),
            candidate("third", quality("third", 0.40, focus: 0.90), groups: [g], order: 2),
        ]
        let results = evaluateTriage(candidates: candidates)
        #expect(result(results, "best") == nil, "人工决策资产不出建议")
        let second = try #require(result(results, "second"))
        #expect(second.verdict != .reject, "已淘汰的最佳不能成为淘汰第二名的理由")
    }

    @Test("人工淘汰 exact 组最佳后：剩余副本不被判 reject")
    func manualRejectedExactBestDoesNotAnchorReject() throws {
        let g = group(.exactDuplicate, "exact:1", ["best", "second"])
        let candidates = [
            candidate("best", quality("best", 0.95, focus: 0.95), groups: [g],
                      manual: .reject, source: .manual, order: 0,
                      width: 8000, height: 6000, fileSize: 40_000_000),
            candidate("second", quality("second", 0.60, focus: 0.90), groups: [g], order: 1,
                      width: 4000, height: 3000, fileSize: 10_000_000),
        ]
        let results = evaluateTriage(candidates: candidates)
        #expect(result(results, "best") == nil)
        let second = try #require(result(results, "second"))
        #expect(second.verdict != .reject)
    }

    // MARK: - v2：模型信号

    private func model(
        _ id: String,
        eyesOpen: Double? = nil,
        smile: Double? = nil,
        faceFocus: Double? = nil,
        captureQuality: Double? = nil,
        utility: Bool? = nil
    ) -> ModelReviewResult {
        var primary = FaceReviewSignal(
            index: 0, x: 0.4, y: 0.3, width: 0.2, height: 0.25, areaRatio: 0.05,
            captureQuality: captureQuality, eyeOpenScore: eyesOpen, smileScore: smile,
            focusScore: faceFocus, isPrimary: true)
        primary.captureQuality = captureQuality
        return ModelReviewResult(
            photoId: id, status: .succeeded,
            eyesOpenScore: eyesOpen, smileScore: smile, faceFocusScore: faceFocus,
            isUtilityImage: utility, faces: [primary],
            modelId: "model-review", modelVersion: "1",
            inputFingerprint: "fp", updatedAt: "2026-10-28T00:00:00.000Z")
    }

    @Test("v2：组内最佳闭眼（模型分）→ review + eyes_closed，不得 reject")
    func modelEyesClosedForcesReview() {
        let g = group(.similarity, "sim:1", ["a", "b"])
        let candidates = [
            candidate("a", quality("a", 0.90, focus: 0.90), faces: 1, area: 0.10,
                      groups: [g], order: 0,
                      model: model("a", eyesOpen: 0.10)),
            candidate("b", quality("b", 0.60, focus: 0.60), faces: 1, area: 0.10,
                      groups: [g], order: 1,
                      model: model("b", eyesOpen: 0.90)),
        ]
        let results = evaluateTriage(candidates: candidates, policy: .v2)
        let first = result(results, "a")
        #expect(first?.verdict == .review)
        #expect(codes(first).contains(.eyesClosed))
    }

    @Test("v2：人脸失焦（模型合焦分低）与合格替代同组 → reject + face_out_of_focus")
    func modelFaceFocusDrivesReject() {
        let g = group(.similarity, "sim:2", ["a", "b"])
        let candidates = [
            candidate("a", quality("a", 0.60, focus: 0.60), faces: 1, area: 0.10,
                      groups: [g], order: 0,
                      model: model("a", eyesOpen: 0.95, faceFocus: 0.08)),
            candidate("b", quality("b", 0.85, focus: 0.85), faces: 1, area: 0.10,
                      groups: [g], order: 1,
                      model: model("b", eyesOpen: 0.95, faceFocus: 0.80)),
        ]
        let results = evaluateTriage(candidates: candidates, policy: .v2)
        let weaker = result(results, "a")
        #expect(weaker?.verdict == .reject)
        #expect(codes(weaker).contains(.faceOutOfFocus))
        #expect(result(results, "b")?.verdict == .keep)
    }

    @Test("v2：工具图（截图/文档）单张也直接 reject + utility_image")
    func modelUtilityImageRejectsSingleShot() {
        let candidates = [
            candidate("shot", quality("shot", 0.70, focus: 0.70), faces: 0, order: 0,
                      model: model("shot", utility: true)),
        ]
        let results = evaluateTriage(candidates: candidates, policy: .v2)
        let verdict = result(results, "shot")
        #expect(verdict?.verdict == .reject)
        #expect(codes(verdict).contains(.utilityImage))
        #expect((verdict?.confidence ?? 0) >= 0.85)
    }

    @Test("visual duplicate 输出 duplicate_visual 理由")
    func visualDuplicateReason() {
        let g = group(.visualDuplicate, "dup:1", ["a", "b"])
        let candidates = [
            candidate("a", quality("a", 0.90, focus: 0.90), groups: [g], order: 0),
            candidate("b", quality("b", 0.60, focus: 0.90), groups: [g], order: 1),
        ]
        let results = evaluateTriage(candidates: candidates, policy: .v2)
        #expect(codes(result(results, "a")).contains(.duplicateVisual))
        #expect(codes(result(results, "b")).contains(.duplicateVisual))
    }
}


@Suite("策略版本隔离")
struct TriagePolicyGateTests {
    private func model(eyesOpen: Double) -> ModelReviewResult {
        ModelReviewResult(
            photoId: "a", assetFileId: nil, status: .succeeded,
            eyesOpenScore: eyesOpen, smileScore: 0.9, faceFocusScore: 0.05,
            aestheticScore: 0.5, isUtilityImage: true,
            faces: [FaceReviewSignal(
                index: 0, x: 0.1, y: 0.1, width: 0.2, height: 0.2, areaRatio: 0.1,
                captureQuality: 0.9, eyeOpenScore: eyesOpen, smileScore: 0.9,
                focusScore: 0.05, isPrimary: true)],
            warnings: [], modelId: "m", modelVersion: "1",
            inputFingerprint: "fp", updatedAt: "2026-10-28T00:00:00.000Z")
    }

    @Test("v1：模型信号（闭眼/工具图/失焦）完全不参与判定")
    func v1IgnoresModelSignals() {
        let candidate = TriageCandidate(
            photoId: "a", quality: QualityResult(
                photoId: "a", status: .succeeded,
                qualityScore: 0.9, sharpness: 0.9, exposure: 0.9,
                subjectSharpness: 0.9, closedEyeRisk: 0.1,
                warnings: [], modelId: "q", modelVersion: "1",
                inputFingerprint: "fp", updatedAt: "2026-10-28T00:00:00.000Z"),
            modelReview: model(eyesOpen: 0.05),
            faceCount: 1, maxFaceAreaRatio: 0.2)
        let v1 = evaluateTriage(candidates: [candidate], policy: .v1)
        let withoutModel = evaluateTriage(
            candidates: [TriageCandidate(
                photoId: "a", quality: candidate.quality,
                faceCount: 1, maxFaceAreaRatio: 0.2)], policy: .v1)
        #expect(v1.count == 1)
        #expect(withoutModel.count == 1)
        if case .suggestion(let a) = v1[0], case .suggestion(let b) = withoutModel[0] {
            #expect(a.verdict == b.verdict, "v1 不得因模型信号改判")
            #expect(a.reasons == b.reasons)
        } else {
            #expect(Bool(false), "应为建议")
        }
    }
}
