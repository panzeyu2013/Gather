// desktop/native/gather-core/Tests/GatherCoreTests/Services/TriageMetricsTests.swift
// P0 / T0：真实集质量门的指标口径（纯函数）。
import Testing
@testable import GatherApplication
@testable import GatherProtocol

@Suite
struct TriageMetricsTests {
    @Test("误杀率、reject precision、复核率、覆盖率")
    func basicRates() throws {
        let rows: [TriageLabeledVerdict] = [
            .init(label: .keep, verdict: .keep),
            .init(label: .keep, verdict: .reject),   // 误杀
            .init(label: .reject, verdict: .reject),
            .init(label: .reject, verdict: .review),
        ]
        let report = TriageMetrics.evaluate(rows)
        let b = report.overall
        #expect(b.labeled == 4)
        #expect(b.trueKeep == 2)
        #expect(b.trueReject == 2)
        #expect(b.falseReject == 1)
        #expect(b.suggestedReject == 2)
        #expect(b.suggestedKeep == 1)
        #expect(b.review == 1)
        #expect(b.falseRejectRate == 0.5)
        #expect(b.rejectPrecision == 0.5)
        #expect(b.reviewRate == 0.25)
        #expect(b.coverage == 0.75)
    }

    @Test("unsure 不计入分母")
    func unsureExcluded() throws {
        let rows: [TriageLabeledVerdict] = [
            .init(label: .unsure, verdict: .reject),
            .init(label: .keep, verdict: .keep),
        ]
        let report = TriageMetrics.evaluate(rows)
        #expect(report.ignoredUnsure == 1)
        #expect(report.overall.labeled == 1)
        #expect(report.overall.falseRejectRate == 0)
    }

    @Test("分类桶独立计算")
    func categories() throws {
        let rows: [TriageLabeledVerdict] = [
            .init(label: .keep, verdict: .reject, category: "wedding"),
            .init(label: .keep, verdict: .keep, category: "wedding"),
            .init(label: .reject, verdict: .reject, category: "product"),
        ]
        let report = TriageMetrics.evaluate(rows)
        #expect(report.byCategory["wedding"]?.labeled == 2)
        #expect(report.byCategory["wedding"]?.falseRejectRate == 0.5)
        #expect(report.byCategory["product"]?.rejectPrecision == 1)
    }

    @Test("零样本时比率是 nil，不是 0")
    func emptyDenominator() throws {
        let report = TriageMetrics.evaluate([])
        #expect(report.overall.falseRejectRate == nil)
        #expect(report.overall.rejectPrecision == nil)
        #expect(report.overall.coverage == nil)
    }
}
