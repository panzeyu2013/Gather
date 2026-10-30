// desktop/native/gather-core/Tests/GatherCoreTests/Services/TriageCalibrationTests.swift
// P1 §3.11.2/§3.11.4：反馈落库 + 阈值校准（分桶精确率 / 样本门禁 / 只取人工决定）。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication
import GatherTestSupport

private let stamped = "2026-10-30T00:00:00.000Z"

/// 假的校准设置端口（生产是 SettingsService）。
private final class FakeCalibrationSettings: TriageCalibrationSettings {
    var values: [String: Double]
    init(values: [String: Double] = [:]) { self.values = values }
    func number(for key: String, defaultValue: Double) -> Double {
        values[key] ?? defaultValue
    }
    func write(_ key: String, value: String) throws {
        guard let parsed = Double(value) else {
            throw TriageCalibrationError.invalidThreshold(0)
        }
        values[key] = parsed
    }
}

private func sample(
    verdict: String,
    confidence: Double,
    action: String,
    camera: String? = nil
) -> TriageCalibrationSample {
    TriageCalibrationSample(
        photoId: "p-\(verdict)-\(confidence)-\(action)",
        sessionId: "s1",
        suggestionVerdict: verdict,
        suggestionConfidence: confidence,
        userAction: action,
        policyVersion: "triage-v2",
        cameraModel: camera,
        iso: 400)
}

private func makeService(
    settings: FakeCalibrationSettings = FakeCalibrationSettings(values: [
        TriageCalibrationKeys.minSamples: 50,
        TriageCalibrationKeys.keepConfidenceMin: 0.60,
        TriageCalibrationKeys.rejectConfidenceMin: 0.75,
        TriageCalibrationKeys.minExecutableConfidence: 0.55,
    ]),
    db: DBConnection
) -> (TriageCalibrationService, TriageFeedbackRepo) {
    let repo = TriageFeedbackRepo(connection: db)
    let service = TriageCalibrationService(
        feedback: repo, settings: settings, now: { stamped })
    return (service, repo)
}

private func insertDecision(
    _ db: DBConnection,
    photoId: String,
    sessionId: String = "s1",
    decision: String,
    source: String,
    revision: Int = 1
) throws {
    _ = try db.prepare("""
        INSERT INTO culling_decisions (
          session_id, photo_id, group_id, decision, rating, color_label,
          decision_source, revision, created_at, updated_at
        ) VALUES (?, ?, 'g', ?, 0, 'None', ?, ?, 't', 't')
        """).run([
            .text(sessionId), .text(photoId), .text(decision),
            .text(source), .int(Int64(revision)),
        ])
}

private func feedback(
    photoId: String,
    verdict: String = "keep",
    confidence: Double = 0.9,
    action: String = "keep"
) -> TriageFeedbackEntry {
    TriageFeedbackEntry(
        suggestionVerdict: verdict,
        userAction: action,
        suggestionConfidence: confidence,
        policyVersion: "triage-v2",
        photoId: photoId,
        sessionId: "s1",
        actedAt: stamped)
}

@Suite("TriageCalibration 分桶/建议阈值")
struct TriageCalibrationReportTests {
    @Test("10 桶精确率：keep 分母为 0 时是 nil 而不是 0")
    func buckets() {
        let samples = [
            sample(verdict: "keep", confidence: 0.95, action: "keep"),
            sample(verdict: "keep", confidence: 0.92, action: "keep"),
            sample(verdict: "keep", confidence: 0.91, action: "reject"),
            sample(verdict: "reject", confidence: 0.65, action: "reject"),
        ]
        let buckets = TriageCalibrationService.buckets(samples: samples)
        #expect(buckets.count == TriageCalibrationService.bucketCount)
        #expect(buckets[9].keepSuggestions == 3)
        #expect(buckets[9].agreedKeep == 2)
        #expect(abs((buckets[9].precision ?? 0) - 2.0 / 3.0) < 0.0001)
        #expect(buckets[6].keepSuggestions == 0)
        #expect(buckets[6].precision == nil)
        #expect(buckets[6].samples == 1)
    }

    @Test("建议阈值：同等精确率下取覆盖最大的最低阈值")
    func suggestion() {
        var samples: [TriageCalibrationSample] = []
        for index in 0..<40 {
            samples.append(sample(
                verdict: "keep", confidence: 0.9, action: "keep"))
            _ = index
        }
        for index in 0..<20 {
            samples.append(sample(
                verdict: "keep", confidence: 0.6, action: "reject"))
            _ = index
        }
        let suggestion = TriageCalibrationService.suggestion(samples: samples, target: 0.90)
        #expect(suggestion != nil)
        #expect(abs((suggestion?.confidence ?? 0) - 0.9) < 0.0001)
        #expect(suggestion?.keep == 40)
        #expect(suggestion?.review == 20)
        let loose = TriageCalibrationService.suggestion(samples: samples, target: 0.60)
        #expect(abs((loose?.confidence ?? 0) - 0.6) < 0.0001)
    }

    @Test("样本不足：报告可读但不可应用")
    func gating() throws {
        let db = try makeTestDB()
        let (service, repo) = makeService(db: db)
        try insertSession(db, "s1")
        for index in 0..<3 {
            let photoId = "p\(index)"
            try insertPhoto(db, id: photoId, sessionId: "s1")
            try insertDecision(db, photoId: photoId, decision: "keep", source: "manual")
            _ = try repo.record([feedback(photoId: photoId)])
        }
        let report = try service.report(sessionId: "s1")
        #expect(report.samples == 3)
        #expect(report.minSamples == 50)
        #expect(report.isApplicable == false)
        #expect(report.disabledReason != nil)
        let suggestion = TriageCalibrationSuggestion(
            target: 0.90, confidence: 0.9, samples: 3,
            keepPrecision: 1, rejectPrecision: nil, keep: 3, reject: 0, review: 0)
        #expect(throws: TriageCalibrationError.self) {
            _ = try service.apply(suggestion)
        }
    }
}

@Suite("TriageCalibration 只取人工决定")
struct TriageCalibrationSampleTests {
    @Test("AI 自动应用的反馈不计入样本（否则精确率恒为 1）")
    func excludesAISource() throws {
        let db = try makeTestDB()
        let (service, repo) = makeService(db: db)
        try insertSession(db, "s1")
        try insertPhoto(db, id: "manual1", sessionId: "s1")
        try insertPhoto(db, id: "ai1", sessionId: "s1")
        try insertPhoto(db, id: "imported1", sessionId: "s1")
        try insertDecision(db, photoId: "manual1", decision: "keep", source: "manual")
        try insertDecision(db, photoId: "ai1", decision: "keep", source: "ai")
        try insertDecision(db, photoId: "imported1", decision: "reject", source: "imported")
        _ = try repo.record([
            feedback(photoId: "manual1"),
            feedback(photoId: "ai1"),
            feedback(photoId: "imported1", verdict: "reject", action: "reject"),
        ])
        let report = try service.report(sessionId: "s1")
        #expect(report.samples == 2)
    }

    @Test("revision = 0 的默认行不计入样本")
    func excludesZeroRevision() throws {
        let db = try makeTestDB()
        let (service, repo) = makeService(db: db)
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertDecision(db, photoId: "p1", decision: "keep", source: "manual", revision: 0)
        _ = try repo.record([feedback(photoId: "p1")])
        let report = try service.report(sessionId: "s1")
        #expect(report.samples == 0)
        #expect(report.buckets.allSatisfy { $0.samples == 0 })
    }
}

@Suite("TriageFeedback 写入语义")
struct TriageFeedbackWriteTests {
    @Test("同一 photo 反复改只留最后一条")
    func replaceLastRow() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        let repo = TriageFeedbackRepo(connection: db)
        let first = try repo.record([feedback(photoId: "p1", action: "keep")])
        #expect(first.written == 1)
        #expect(first.replaced == 0)
        let second = try repo.record([feedback(photoId: "p1", action: "reject")])
        #expect(second.replaced == 1)
        let afterReplace = try repo.count(sessionId: "s1")
        #expect(afterReplace == 1)
        try insertDecision(db, photoId: "p1", decision: "reject", source: "manual")
        let samples = try repo.loadCalibrationSamples(sessionId: "s1")
        #expect(samples.count == 1)
        #expect(samples.first?.userAction == "reject")
    }

    @Test("非法 verdict/action 不落库（DB CHECK 前先拒绝）")
    func rejectsMalformedEntries() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        let repo = TriageFeedbackRepo(connection: db)
        var bad = feedback(photoId: "p1")
        bad = TriageFeedbackEntry(
            suggestionVerdict: "maybe", userAction: "keep", suggestionConfidence: 0.5,
            policyVersion: "triage-v2", photoId: bad.photoId, sessionId: bad.sessionId,
            actedAt: stamped)
        let result = try repo.record([bad])
        #expect(result.written == 0)
        let total = try repo.count(sessionId: nil)
        #expect(total == 0)
    }
}

@Suite("TriagePolicy 阈值指纹")
struct TriageThresholdFingerprintTests {
    @Test("阈值变化改指纹，版本字符串保持不变")
    func fingerprintTracksThresholds() {
        var policy = TriagePolicy.v2
        let base = policy.thresholdFingerprint
        #expect(policy.usesModelSignals)
        policy.keepConfidenceMin = 0.9
        #expect(policy.thresholdFingerprint != base)
        #expect(policy.version == "triage-v2")
        #expect(policy.usesModelSignals)
    }
}
