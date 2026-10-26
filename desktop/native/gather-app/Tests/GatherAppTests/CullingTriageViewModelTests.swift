// desktop/native/gather-app/Tests/GatherAppTests/CullingTriageViewModelTests.swift
// P0 / T0：技术质量建议的 VM 状态/动作测试（真实 VM + 类型化 stub）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

private func triageSummary(
    keep: Int,
    reject: Int,
    review: Int,
    total: Int,
    coverage: Double = 1,
    stale: Bool = false,
    fingerprint: String = "fp-triage"
) -> TriageSummary {
    TriageSummary(
        counts: TriageCounts(
            keep: keep, reject: reject, review: review, total: total, coverage: coverage
        ),
        stale: stale,
        policyVersion: "triage-v1",
        inputFingerprint: fingerprint,
        generatedAt: "2026-10-25T00:00:00.000Z"
    )
}

private func cullingSummary(_ triage: TriageSummary?) -> CullingSummary {
    CullingSummary(
        totalGroups: 1, totalPhotos: 2, kept: 0, rejected: 0, pending: 2,
        rated: 0, labeled: 0, triage: triage
    )
}

@MainActor
@Suite("T0 triage view model")
struct CullingTriageViewModelTests {
    private func makeVM(
        triage: TriageSummary?
    ) async -> (CullingViewModel, B8CullingAPIStub) {
        let api = B8CullingAPIStub()
        api.pageResult = b8CullingPage([b8CullingAsset("p1"), b8CullingAsset("p2")])
        api.summaryResult = cullingSummary(triage)
        let vm = CullingViewModel(
            sessionId: "s1",
            culling: api,
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub()
        )
        await vm.load()
        return (vm, api)
    }

    @Test("生成建议：传入 force，回填 summary 并刷新页")
    func generateTriageUpdatesSummary() async {
        let (vm, api) = await makeVM(triage: nil)
        let result = triageSummary(keep: 2, reject: 1, review: 1, total: 4, fingerprint: "fp-new")
        api.triageSummaryResult = result

        await vm.generateTriage(force: true)

        #expect(api.triageGenerateInputs.map(\.force) == [true])
        #expect(vm.triageSummary?.counts.keep == 2)
        #expect(vm.triageSummary?.inputFingerprint == "fp-new")
        #expect(vm.notice != nil)
        #expect(vm.triageError == nil)
        #expect(api.pageQueries.count > 1)
    }

    @Test("应用建议：带当前 fingerprint/verdicts/minConfidence")
    func applyTriageSendsFingerprint() async {
        let summary = triageSummary(
            keep: 1, reject: 1, review: 0, total: 2, fingerprint: "fp-apply"
        )
        let (vm, api) = await makeVM(triage: summary)
        api.applyTriageResult = TriageApplyResult(
            appliedAssets: 2, appliedPhotos: 2, appliedKeep: 1, appliedReject: 1,
            skippedManual: 1, skippedLowConfidence: 0, skippedMissing: 0,
            historyOperationId: 7
        )

        let result = await vm.applyTriage(minConfidence: 0.8)

        #expect(result?.appliedAssets == 2)
        #expect(result?.historyOperationId == 7)
        let input = api.applyTriageInputs.first?.value
        #expect(input?.sessionId == "s1")
        #expect(input?.fingerprint == "fp-apply")
        #expect(input?.verdicts == [.keep, .reject])
        #expect(input?.minConfidence == 0.8)
        #expect(vm.triageError == nil)
    }

    @Test("过期建议：禁止应用且不发请求")
    func staleBlocksApply() async {
        let stale = triageSummary(
            keep: 1, reject: 0, review: 0, total: 1,
            stale: true, fingerprint: "fp-stale"
        )
        let (vm, api) = await makeVM(triage: stale)

        let result = await vm.applyTriage()

        #expect(result == nil)
        #expect(api.applyTriageInputs.isEmpty)
        #expect(vm.triageError != nil)
        #expect(vm.canApplyTriage == false)
    }

    @Test("复核队列：sort=triageConfidenceAsc，filter=review，scope=filtered")
    func reviewQueueSetsSortAndFilter() async {
        let summary = triageSummary(keep: 1, reject: 1, review: 2, total: 4)
        let (vm, api) = await makeVM(triage: summary)

        await vm.showTriageReviewQueue()

        #expect(vm.sortMode == .triageConfidenceAsc)
        #expect(vm.scopeMode == .filtered)
        #expect(vm.filterState.triageVerdicts == [.review])
        let last = api.pageQueries.last
        #expect(last?.sort == .triageConfidenceAsc)
        #expect(last?.scope == .filtered)
        #expect(last?.filters?.triageVerdicts == [.review])
    }

    @Test("生成失败：映射为 triageError，不改变旧 summary")
    func generateErrorMaps() async {
        let old = triageSummary(keep: 0, reject: 0, review: 0, total: 2, fingerprint: "fp-old")
        let (vm, api) = await makeVM(triage: old)
        api.triageGenerateError = GatherError(code: .TRIAGE_NOT_READY)

        await vm.generateTriage()

        #expect(vm.triageError?.code == GatherErrorCode.TRIAGE_NOT_READY.rawValue)
        #expect(vm.triageSummary?.inputFingerprint == "fp-old")
        #expect(vm.isTriageBusy == false)
    }
}
