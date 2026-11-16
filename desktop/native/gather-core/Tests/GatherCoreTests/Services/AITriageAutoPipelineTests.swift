// desktop/native/gather-core/Tests/GatherCoreTests/Services/AITriageAutoPipelineTests.swift
// Wave2 / task-14：导入后自动初审的编排（假 job 调度驱动，不 sleep 真时间）。
import Foundation
import Testing
import os
@testable import GatherProtocol
@testable import GatherApplication

/// 假 job 调度器：每次 poll 前进一格快照；入队/生成/应用都记录调用，便于断言。
private final class FakeJobFeed: Sendable {
    private struct State {
        var snapshots: [[AnalysisJobData]]
        var index: Int = 0
        var enqueued: [String] = []
        var generated: [String] = []
        var applied: [TriageApplyInput] = []
        var cancelledJobs: [String] = []
        var groups: [String] = []
        /// 事件顺序（Wave5 batch6）：用于断言 groups 在 generate 之前。
        var events: [String] = []
        var logs: [String] = []
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(_ snapshots: [[AnalysisJobData]]) {
        lock = OSAllocatedUnfairLock(initialState: State(snapshots: snapshots))
    }

    var current: [AnalysisJobData] {
        lock.withLock { state in
            state.snapshots[min(state.index, max(0, state.snapshots.count - 1))]
        }
    }

    func advance() {
        lock.withLock { state in
            state.index = min(state.index + 1, max(0, state.snapshots.count - 1))
        }
    }

    func recordEnqueue(_ sessionId: String) {
        lock.withLock { state in
            state.enqueued.append(sessionId)
            state.events.append("quality-enqueued")
        }
    }

    func recordGenerate(_ sessionId: String) {
        lock.withLock { state in
            state.generated.append(sessionId)
            state.events.append("generate")
        }
    }

    func recordApply(_ input: TriageApplyInput) {
        lock.withLock { $0.applied.append(input) }
    }

    func recordCancel(_ jobId: String) {
        lock.withLock { $0.cancelledJobs.append(jobId) }
    }

    func recordGroupArtifacts(_ sessionId: String) {
        lock.withLock { state in
            state.groups.append(sessionId)
            state.events.append("groups")
        }
    }

    func recordLog(_ message: String) {
        lock.withLock { $0.logs.append(message) }
    }

    var groups: [String] { lock.withLock { $0.groups } }
    var events: [String] { lock.withLock { $0.events } }
    var enqueued: [String] { lock.withLock { $0.enqueued } }
    var generated: [String] { lock.withLock { $0.generated } }
    var applied: [TriageApplyInput] { lock.withLock { $0.applied } }
    var cancelledJobs: [String] { lock.withLock { $0.cancelledJobs } }
    var logs: [String] { lock.withLock { $0.logs } }
}

private func makeJob(
    id: String,
    type: AnalysisJobType,
    status: AnalysisJobStatus,
    sessionId: String = "s1",
    createdAt: String = "2026-11-11T00:00:00Z"
) -> AnalysisJobData {
    AnalysisJobData(
        id: id, type: type, scopeType: "session", scopeId: sessionId,
        dedupeKey: "\(type.rawValue):\(id)", status: status, priority: 0,
        progressCurrent: 0, progressTotal: 0, progressMessage: "",
        inputFingerprint: "", modelId: "", modelVersion: "", checkpoint: [:],
        attemptCount: 0, leaseOwner: "", heartbeatAt: "",
        errorCode: "", errorMessage: "",
        createdAt: createdAt, startedAt: "", finishedAt: "", updatedAt: createdAt)
}

private func makeSummary(fingerprint: String = "fp-1") -> TriageSummary {
    TriageSummary(
        counts: TriageCounts(keep: 3, reject: 1, review: 1, total: 5, coverage: 1),
        stale: false, policyVersion: "triage-v2", inputFingerprint: fingerprint,
        generatedAt: "2026-11-11T00:00:00Z")
}

private func makePipeline(
    feed: FakeJobFeed,
    autoApply: Bool,
    triageEnabled: Bool = true,
    enqueueFails: Bool = false,
    summary: TriageSummary = makeSummary(),
    maxPolls: Int = 10,
    groupOutcome: AITriageGroupArtifactsOutcome = .alreadyReady
) -> AITriageAutoPipeline {
    let deps = AITriageAutoPipeline.Dependencies(
        listJobs: { feed.current },
        enqueueQualityJob: { sessionId in
            feed.recordEnqueue(sessionId)
            if enqueueFails {
                throw GatherError.invalidParameter(field: "job", reason: "injected enqueue failure")
            }
            return makeJob(id: "q1", type: .qualityScore, status: .queued)
        },
        generateTriage: { sessionId in
            feed.recordGenerate(sessionId)
            return summary
        },
        applyTriage: { input in
            feed.recordApply(input)
            return TriageApplyResult(appliedPhotos: 2)
        },
        autoApplyEnabled: { autoApply },
        triageEnabled: { triageEnabled },
        ensureGroupArtifacts: { sessionId in
            feed.recordGroupArtifacts(sessionId)
            return groupOutcome
        },
        log: { message in
            feed.recordLog(message)
        },
        poll: { feed.advance() })
    return AITriageAutoPipeline(deps: deps, maxPolls: maxPolls)
}

@Suite("导入后自动初审")
struct AITriageAutoPipelineTests {
    @Test("索引完成 → 入队质量 → 质量成功 → 生成建议（默认不自动应用）")
    func happyPathWithoutAutoApply() async {
        let feed = FakeJobFeed([
            [makeJob(id: "scan", type: .metadataScan, status: .running)],
            [makeJob(id: "scan", type: .metadataScan, status: .succeeded)],
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .queued),
            ],
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .succeeded),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: false).run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(outcome.qualityJobId == "q1")
        #expect(outcome.summary?.inputFingerprint == "fp-1")
        #expect(outcome.applied == nil)
        #expect(feed.enqueued == ["s1"])
        #expect(feed.generated == ["s1"])
        #expect(feed.applied.isEmpty)
    }

    @Test("triage_auto_apply=1 时按 automation 应用，并带上 summary 的指纹")
    func autoApply() async {
        let feed = FakeJobFeed([
            [makeJob(id: "scan", type: .metadataScan, status: .succeeded)],
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .succeeded),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: true).run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(outcome.applied?.appliedPhotos == 2)
        #expect(feed.applied.count == 1)
        #expect(feed.applied.first?.fingerprint == "fp-1")
        #expect(feed.applied.first?.verdicts == [.keep, .reject])
    }

    @Test("已有活跃 quality job 时复用它，不重复入队")
    func reuseActiveQualityJob() async {
        let feed = FakeJobFeed([
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q-existing", type: .qualityScore, status: .running),
            ],
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q-existing", type: .qualityScore, status: .succeeded),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: false).run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(outcome.qualityJobId == "q-existing")
        #expect(feed.enqueued.isEmpty)
    }

    @Test("质量 job 被取消 → 停止且不生成建议（用户取消必须尊重）")
    func qualityCancelledStops() async {
        let feed = FakeJobFeed([
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .running),
            ],
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .cancelled),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: true).run(sessionId: "s1")
        #expect(outcome.stage == .stopped)
        #expect(outcome.reason == "quality-cancelled")
        #expect(feed.generated.isEmpty)
        #expect(feed.applied.isEmpty)
        #expect(feed.groups.isEmpty, "质量未成功时不应跑分组准备（E3 在 quality 成功之后）")
    }

    @Test("索引失败 → 不跑质量分析（没有可信 photoIds）")
    func scanFailedStops() async {
        let feed = FakeJobFeed([
            [makeJob(id: "scan", type: .metadataScan, status: .failed)],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: false).run(sessionId: "s1")
        #expect(outcome.stage == .stopped)
        #expect(outcome.reason == "index-not-succeeded")
        #expect(feed.enqueued.isEmpty)
        #expect(feed.groups.isEmpty)
    }

    @Test("triage_enabled=0 → 直接 skipped：不入队质量、不生成、不应用（E4）")
    func triageDisabledSkips() async {
        let feed = FakeJobFeed([
            [makeJob(id: "scan", type: .metadataScan, status: .succeeded)],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: true, triageEnabled: false)
            .run(sessionId: "s1")
        #expect(outcome.stage == .skipped)
        #expect(outcome.reason == "triage-disabled")
        #expect(feed.enqueued.isEmpty, "关闭 triage 时不应再排 quality job（省掉整段解码）")
        #expect(feed.generated.isEmpty)
        #expect(feed.applied.isEmpty)
        #expect(feed.groups.isEmpty, "triage 关闭时也不做分组分析（整条自动初审被跳过）")
    }

    @Test("没有任何 job（空会话/立即返回）→ 视索引为就绪，直接排质量")
    func noScanMeansReady() {
        #expect(AITriageAutoPipeline.scanState([], sessionId: "s1") == .ready)
        let jobs = [makeJob(id: "q1", type: .qualityScore, status: .running)]
        #expect(AITriageAutoPipeline.scanState(jobs, sessionId: "s1") == .ready)
        #expect(AITriageAutoPipeline.scanState(jobs, sessionId: "other") == .ready)
        #expect(AITriageAutoPipeline.activeQualityJob(jobs, sessionId: "s1")?.id == "q1")
        #expect(AITriageAutoPipeline.activeQualityJob(jobs, sessionId: "other") == nil)
    }

    @Test("质量 job 超时 → 只停止等待、不取消 job（Wave5 batch2）")
    func qualityTimeout() async {
        let feed = FakeJobFeed([
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .running),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: false, maxPolls: 3)
            .run(sessionId: "s1")
        #expect(outcome.stage == .stopped)
        #expect(outcome.reason == "quality-timeout")
        #expect(feed.cancelledJobs.isEmpty, "超时只停止等待，不得取消仍在后台推进的 job")
        let loggedLeftRunning = feed.logs.contains { $0.contains("quality-job=left-running") }
        #expect(loggedLeftRunning)
    }

    @Test("入队失败 → 停止 + 日志，不静默吞掉（Wave4b）")
    func enqueueFailureLogged() async {
        let feed = FakeJobFeed([
            [makeJob(id: "scan", type: .metadataScan, status: .succeeded)],
        ])
        let outcome = await makePipeline(
            feed: feed, autoApply: false, enqueueFails: true).run(sessionId: "s1")
        #expect(outcome.stage == .stopped)
        #expect(outcome.reason == "quality-enqueue-failed")
        #expect(feed.generated.isEmpty)
        let loggedEnqueueFailure = feed.logs.contains { $0.contains("quality-enqueue-failed") }
        #expect(loggedEnqueueFailure)
    }

    @Test("quality dedupeKey 按导入批次唯一，避免继承旧 checkpoint（Wave4b）")
    func qualityDedupeKeyPerBatch() {
        let base = "quality.score:s1:auto-import-triage"
        #expect(AITriageAutoPipeline.qualityJobDedupeKey(scopeId: "s1", batchNonce: "") == base)
        let a = AITriageAutoPipeline.qualityJobDedupeKey(scopeId: "s1", batchNonce: "batch-a")
        let b = AITriageAutoPipeline.qualityJobDedupeKey(scopeId: "s1", batchNonce: "batch-b")
        #expect(a.hasPrefix(base + ":"))
        #expect(a != b, "不同导入批次不能共用 dedupeKey（否则 create 会继承旧 photoIds）")
        #expect(AITriageAutoPipeline.qualityJobDedupeKey(
            scopeId: "s1", batchNonce: "batch-a") == a, "同一批次内稳定")
    }

    @Test("reason 字符串集中：quality 取消/中断统一成 quality-<status>")
    func reasonStringsCentralized() {
        #expect(AITriageStopReason.qualityTimeout == "quality-timeout")
        #expect(AITriageStopReason.qualityEnded(.cancelled) == "quality-cancelled")
        #expect(AITriageStopReason.qualityEnded(.interrupted) == "quality-interrupted")
        #expect(AITriageStopReason.triageDisabled == "triage-disabled")
        #expect(AITriageStopReason.indexNotSucceeded == "index-not-succeeded")
    }

    // MARK: - Wave5 batch6（E3）：分组产物准备

    @Test("E3：quality 成功后、生成建议前确保分组产物（顺序 quality→groups→generate）")
    func ensuresGroupArtifactsBetweenQualityAndGenerate() async {
        let feed = FakeJobFeed([
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .succeeded),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: false, groupOutcome: .enqueued)
            .run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(feed.groups == ["s1"])
        #expect(feed.events == ["quality-enqueued", "groups", "generate"],
            "分组准备必须在质量成功后、建议生成前；顺序即 triage 理由码可用的保证")
        #expect(feed.logs.contains { $0.contains("groups=enqueued") })
    }

    @Test("E3：宿主返回 alreadyReady（近期成功/已有组）→ 只记录，不阻断生成")
    func groupArtifactsAlreadyReadyLogged() async {
        let feed = FakeJobFeed([
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .succeeded),
            ],
        ])
        let outcome = await makePipeline(feed: feed, autoApply: false, groupOutcome: .alreadyReady)
            .run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(feed.groups == ["s1"])
        #expect(feed.generated == ["s1"])
        #expect(feed.logs.contains { $0.contains("groups=already-ready") })
    }

    @Test("E3：分组分析未完成 → 只记日志并继续生成建议（初审不能被分组拖停）")
    func groupArtifactsFailureDoesNotBlockGenerate() async {
        let feed = FakeJobFeed([
            [
                makeJob(id: "scan", type: .metadataScan, status: .succeeded),
                makeJob(id: "q1", type: .qualityScore, status: .succeeded),
            ],
        ])
        let outcome = await makePipeline(
            feed: feed,
            autoApply: false,
            groupOutcome: .failed("duplicate-wait: timeout"))
            .run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(feed.generated == ["s1"])
        let logged = feed.logs.contains {
            $0.contains("groups=failed") && $0.contains("duplicate-wait: timeout")
        }
        #expect(logged, "失败原因必须进日志，不能静默")
    }
}
