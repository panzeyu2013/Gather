// desktop/native/gather-app/Tests/GatherAppTests/AITriageAutoPipelineTests.swift
// Wave5 batch2（E1）：导入后自动初审的"超时只停止等待、不取消 job + 大库按进展续期"。
// Wave5 batch6（E3）：初审前分组产物（duplicate.scan + navigation.analyze）的宿主决策与有界等待。
//
// 既有 core 侧测试覆盖 happy path / 复用 job / 跳过；这里补本批行为变更：
// 1. 质量超时不再取消 job（旧 Wave4b 语义已删除）；
// 2. 质量等待按 progress 续期 —— 5000 张素材的会话不会被 5 分钟总上限误杀；
// 3. 索引等待预算放宽到 6×（扫描进度只在收尾刷新）；
// 4. E3：pipeline 在 quality 后、generate 前调 ensureGroupArtifacts（失败仍生成）；
//    宿主侧 duplicatePlan 近期成功/活跃复用/入队判定，以及失败互不影响 + 有界等待预算。
//
// 假调度器驱动，不 sleep 真时间；不依赖数据库/文件系统。
import Foundation
import Testing
import os
@testable import GatherApplication
@testable import GatherHost
import GatherProtocol

private final class PipelineJobFeed: Sendable {
    private struct State {
        var snapshots: [[AnalysisJobData]]
        var index = 0
        var enqueued: [String] = []
        var generated: [String] = []
        var applied: [TriageApplyInput] = []
        var groups: [String] = []
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

    var enqueued: [String] { lock.withLock { $0.enqueued } }
    var generated: [String] { lock.withLock { $0.generated } }
    var groups: [String] { lock.withLock { $0.groups } }
    var events: [String] { lock.withLock { $0.events } }
    var applied: [TriageApplyInput] { lock.withLock { $0.applied } }
    var logs: [String] { lock.withLock { $0.logs } }

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

    func recordGroupArtifacts(_ sessionId: String) {
        lock.withLock { state in
            state.groups.append(sessionId)
            state.events.append("groups")
        }
    }

    func recordApply(_ input: TriageApplyInput) { lock.withLock { $0.applied.append(input) } }
    func recordLog(_ message: String) { lock.withLock { $0.logs.append(message) } }
}

private func pipelineJob(
    id: String,
    type: AnalysisJobType,
    status: AnalysisJobStatus,
    sessionId: String = "s1",
    progressCurrent: Int = 0,
    progressTotal: Int = 0,
    progressMessage: String = "",
    createdAt: String = "2026-11-11T00:00:00Z",
    finishedAt: String = ""
) -> AnalysisJobData {
    AnalysisJobData(
        id: id, type: type, scopeType: "session", scopeId: sessionId,
        dedupeKey: "\(type.rawValue):\(id)", status: status, priority: 0,
        progressCurrent: progressCurrent, progressTotal: progressTotal,
        progressMessage: progressMessage,
        inputFingerprint: "", modelId: "", modelVersion: "", checkpoint: [:],
        attemptCount: 0, leaseOwner: "", heartbeatAt: "",
        errorCode: "", errorMessage: "",
        createdAt: createdAt, startedAt: "", finishedAt: finishedAt,
        updatedAt: createdAt)
}

private func pipelineSummary() -> TriageSummary {
    TriageSummary(
        counts: TriageCounts(keep: 3, reject: 1, review: 1, total: 5, coverage: 1),
        stale: false, policyVersion: "triage-v2", inputFingerprint: "fp-1",
        generatedAt: "2026-11-11T00:00:00Z")
}

private func makePipeline(
    feed: PipelineJobFeed,
    maxPolls: Int = 3,
    groupOutcome: AITriageGroupArtifactsOutcome = .alreadyReady
) -> AITriageAutoPipeline {
    let deps = AITriageAutoPipeline.Dependencies(
        listJobs: { feed.current },
        enqueueQualityJob: { sessionId in
            feed.recordEnqueue(sessionId)
            return pipelineJob(id: "q1", type: .qualityScore, status: .queued)
        },
        generateTriage: { sessionId in
            feed.recordGenerate(sessionId)
            return pipelineSummary()
        },
        applyTriage: { input in
            feed.recordApply(input)
            return TriageApplyResult(appliedPhotos: 2)
        },
        autoApplyEnabled: { false },
        triageEnabled: { true },
        ensureGroupArtifacts: { sessionId in
            feed.recordGroupArtifacts(sessionId)
            return groupOutcome
        },
        log: { feed.recordLog($0) },
        poll: { feed.advance() })
    return AITriageAutoPipeline(deps: deps, maxPolls: maxPolls)
}

@Suite("自动初审：超时语义（Wave5 batch2）")
struct AITriageAutoPipelineWave5Tests {
    @Test("质量超时 → 只停止等待，不取消 job（job 留在后台继续）")
    func qualityTimeoutLeavesJobRunning() async {
        let feed = PipelineJobFeed([
            [
                pipelineJob(id: "scan", type: .metadataScan, status: .succeeded),
                pipelineJob(id: "q1", type: .qualityScore, status: .running),
            ],
        ])
        let outcome = await makePipeline(feed: feed, maxPolls: 2)
            .run(sessionId: "s1")
        #expect(outcome.stage == .stopped)
        #expect(outcome.reason == "quality-timeout")
        let logged = feed.logs.contains { $0.contains("quality-job=left-running") }
        #expect(logged, "超时日志必须说明 job 未被取消，便于诊断")
        #expect(feed.generated.isEmpty)
    }

    @Test("质量 job 持续报进展 → 超过 maxPolls 也不超时（按进展续期）")
    func progressExtendsQualityWait() async {
        // 0=scan 完成；1..6=q1 逐格推进；最后 succeeded。maxPolls=2 时旧实现
        // 会在第 2 次轮询后判超时；现在每格 progress 变化都会重置无进展计数。
        var snapshots: [[AnalysisJobData]] = [
            [pipelineJob(id: "scan", type: .metadataScan, status: .succeeded)],
        ]
        for step in 0..<6 {
            snapshots.append([
                pipelineJob(id: "scan", type: .metadataScan, status: .succeeded),
                pipelineJob(
                    id: "q1", type: .qualityScore, status: .running,
                    progressCurrent: step, progressTotal: 6, progressMessage: "quality"),
            ])
        }
        snapshots.append([
            pipelineJob(id: "scan", type: .metadataScan, status: .succeeded),
            pipelineJob(
                id: "q1", type: .qualityScore, status: .succeeded,
                progressCurrent: 6, progressTotal: 6, progressMessage: "done"),
        ])
        let feed = PipelineJobFeed(snapshots)
        let outcome = await makePipeline(feed: feed, maxPolls: 2)
            .run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(outcome.qualityJobId == "q1")
        #expect(feed.generated == ["s1"])
    }

    @Test("索引等待预算放宽到 6×：扫描 4 格（>maxPolls=2）不误判 index-timeout")
    func scanBudgetExtended() async {
        var snapshots: [[AnalysisJobData]] = []
        for _ in 0..<4 {
            snapshots.append([pipelineJob(id: "scan", type: .metadataScan, status: .running)])
        }
        snapshots.append([pipelineJob(id: "scan", type: .metadataScan, status: .succeeded)])
        snapshots.append([
            pipelineJob(id: "scan", type: .metadataScan, status: .succeeded),
            pipelineJob(id: "q1", type: .qualityScore, status: .succeeded),
        ])
        let feed = PipelineJobFeed(snapshots)
        let outcome = await makePipeline(feed: feed, maxPolls: 2)
            .run(sessionId: "s1")
        #expect(outcome.stage == .done)
        #expect(feed.generated == ["s1"])
    }

    @Test("进展签名只看进度：message/current 变化算进展，heartbeat/updatedAt 不算")
    func progressSignatureIgnoresHeartbeat() {
        let base = pipelineJob(
            id: "q1", type: .qualityScore, status: .running,
            progressCurrent: 2, progressTotal: 10)
        #expect(AITriageAutoPipeline.progressSignature(base) == "2/10/")
        var advanced = base
        advanced.progressCurrent = 3
        #expect(AITriageAutoPipeline.progressSignature(base)
            != AITriageAutoPipeline.progressSignature(advanced))
        var heartbeatOnly = base
        heartbeatOnly.updatedAt = "2026-11-11T00:10:00Z"
        #expect(AITriageAutoPipeline.progressSignature(base)
            == AITriageAutoPipeline.progressSignature(heartbeatOnly))
        #expect(AITriageAutoPipeline.progressSignature(nil) == "missing")
    }

    @Test("E3：pipeline 在 quality 后、generate 前确保分组产物；失败仍生成建议")
    func pipelineEnsuresGroupArtifacts() async {
        // 成功路径：事件顺序 quality-enqueued → groups → generate
        let okFeed = PipelineJobFeed([[
            pipelineJob(id: "scan", type: .metadataScan, status: .succeeded),
            pipelineJob(id: "q1", type: .qualityScore, status: .succeeded),
        ]])
        let ok = await makePipeline(feed: okFeed, groupOutcome: .enqueued)
            .run(sessionId: "s1")
        #expect(ok.stage == .done)
        #expect(okFeed.events == ["quality-enqueued", "groups", "generate"])
        #expect(okFeed.logs.contains { $0.contains("groups=enqueued") })

        // 失败路径：分组分析未完成只记日志，建议照常生成（初审不能被拖停）
        let failFeed = PipelineJobFeed([[
            pipelineJob(id: "scan", type: .metadataScan, status: .succeeded),
            pipelineJob(id: "q1", type: .qualityScore, status: .succeeded),
        ]])
        let failed = await makePipeline(
            feed: failFeed, groupOutcome: .failed("duplicate-wait: timeout"))
            .run(sessionId: "s1")
        #expect(failed.stage == .done)
        #expect(failFeed.generated == ["s1"])
        #expect(failFeed.logs.contains {
            $0.contains("groups=failed") && $0.contains("duplicate-wait: timeout")
        })
    }
}

// MARK: - Wave5 batch6（E3）：宿主侧分组产物准备（duplicate.scan + navigation.analyze）

private final class GroupArtifactsProbe: Sendable {
    private struct State {
        var enqueued: [String] = []
        var waited: [(jobId: String, timeoutMs: Int64)] = []
        var analyzed: [String] = []
        var logs: [String] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var enqueued: [String] { lock.withLock { $0.enqueued } }
    var waited: [(jobId: String, timeoutMs: Int64)] { lock.withLock { $0.waited } }
    var analyzed: [String] { lock.withLock { $0.analyzed } }
    var logs: [String] { lock.withLock { $0.logs } }

    func recordEnqueue(_ sessionId: String) {
        lock.withLock { $0.enqueued.append(sessionId) }
    }

    func recordWait(_ jobId: String, _ timeoutMs: Int64) {
        lock.withLock { $0.waited.append((jobId: jobId, timeoutMs: timeoutMs)) }
    }

    func recordAnalyze(_ sessionId: String) {
        lock.withLock { $0.analyzed.append(sessionId) }
    }

    func recordLog(_ message: String) {
        lock.withLock { $0.logs.append(message) }
    }
}

private func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func makeGroupArtifactsCoordinator(
    probe: GroupArtifactsProbe,
    jobs: [AnalysisJobData],
    hasNavigationGroups: Bool = false,
    enqueueFails: Bool = false,
    waitFails: Bool = false,
    navigationFails: Bool = false,
    now: Date = Date(timeIntervalSince1970: 1_000_000)
) -> AITriageGroupArtifactsCoordinator {
    AITriageGroupArtifactsCoordinator(
        deps: AITriageGroupArtifactsCoordinator.Dependencies(
            listJobs: { jobs },
            enqueueDuplicateScan: { sessionId in
                probe.recordEnqueue(sessionId)
                if enqueueFails {
                    throw GatherError.invalidParameter(field: "duplicate", reason: "injected")
                }
                return pipelineJob(id: "d-new", type: .duplicateScan, status: .queued)
            },
            waitDuplicateScan: { jobId, timeoutMs in
                probe.recordWait(jobId, timeoutMs)
                if waitFails {
                    throw GatherError.invalidParameter(
                        field: "duplicate-wait", reason: "injected timeout")
                }
            },
            hasNavigationGroups: { _ in hasNavigationGroups },
            analyzeNavigation: { sessionId in
                probe.recordAnalyze(sessionId)
                if navigationFails {
                    throw GatherError.invalidParameter(field: "navigation", reason: "injected")
                }
            },
            now: { now },
            log: { probe.recordLog($0) }))
}

@Suite("自动初审：分组产物准备（Wave5 batch6 / E3）")
struct AITriageGroupArtifactsTests {
    @Test("duplicatePlan：近期成功跳过 / 活跃 job 复用等待 / 其余入队（含不可解析 finishedAt）")
    func duplicatePlanDecisions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = pipelineJob(
            id: "d1", type: .duplicateScan, status: .succeeded,
            finishedAt: isoDate(now.addingTimeInterval(-60)))
        let old = pipelineJob(
            id: "d2", type: .duplicateScan, status: .succeeded,
            finishedAt: isoDate(now.addingTimeInterval(-3_600)))
        let active = pipelineJob(
            id: "d3", type: .duplicateScan, status: .running,
            createdAt: "2026-11-11T00:10:00Z")
        let unknown = pipelineJob(id: "d4", type: .duplicateScan, status: .succeeded)
        let otherSession = pipelineJob(
            id: "d5", type: .duplicateScan, status: .running, sessionId: "s2")

        #expect(AITriageGroupArtifactsCoordinator.duplicatePlan(
            jobs: [recent], sessionId: "s1", now: now, recentWindow: 900) == .recentSuccess)
        #expect(AITriageGroupArtifactsCoordinator.duplicatePlan(
            jobs: [old], sessionId: "s1", now: now, recentWindow: 900) == .enqueue)
        #expect(AITriageGroupArtifactsCoordinator.duplicatePlan(
            jobs: [active], sessionId: "s1", now: now, recentWindow: 900) == .waitActive("d3"))
        #expect(AITriageGroupArtifactsCoordinator.duplicatePlan(
            jobs: [], sessionId: "s1", now: now, recentWindow: 900) == .enqueue)
        // finishedAt 为空/不可解析：不可判定"近期"，宁可重扫一次也不能当已就绪。
        #expect(AITriageGroupArtifactsCoordinator.duplicatePlan(
            jobs: [unknown], sessionId: "s1", now: now, recentWindow: 900) == .enqueue)
        // 其它会话的 job 不参与判定。
        #expect(AITriageGroupArtifactsCoordinator.duplicatePlan(
            jobs: [otherSession], sessionId: "s1", now: now, recentWindow: 900) == .enqueue)
    }

    @Test("alreadyReady：近期成功 + 已有导航组 → 不入队、不等待、不重复分析")
    func alreadyReadySkipsEverything() async {
        let probe = GroupArtifactsProbe()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = pipelineJob(
            id: "d1", type: .duplicateScan, status: .succeeded,
            finishedAt: isoDate(now.addingTimeInterval(-60)))
        let coordinator = makeGroupArtifactsCoordinator(
            probe: probe, jobs: [recent], hasNavigationGroups: true, now: now)

        let outcome = await coordinator.run(sessionId: "s1")
        #expect(outcome == .alreadyReady)
        #expect(probe.enqueued.isEmpty)
        #expect(probe.waited.isEmpty)
        #expect(probe.analyzed.isEmpty)
    }

    @Test("enqueued：无结果 → 入队一次 + 60s 有界等待；导航组直接分析")
    func enqueuesAndWaitsBounded() async {
        let probe = GroupArtifactsProbe()
        let coordinator = makeGroupArtifactsCoordinator(probe: probe, jobs: [])
        let outcome = await coordinator.run(sessionId: "s1")

        #expect(outcome == .enqueued)
        #expect(probe.enqueued == ["s1"])
        #expect(probe.waited.count == 1)
        #expect(probe.waited.first?.jobId == "d-new")
        #expect(probe.waited.map { $0.timeoutMs } == [60_000],
            "有界等待必须是 poll 预算的一小段（60s），不能无限等")
        #expect(probe.analyzed == ["s1"])
        #expect(probe.logs.contains { $0.contains("groups.duplicate=enqueued") })
        #expect(probe.logs.contains { $0.contains("groups.navigation=analyzed") })
    }

    @Test("已有活跃 duplicate job → 复用等待，不重复入队")
    func activeJobReused() async {
        let probe = GroupArtifactsProbe()
        let active = pipelineJob(id: "d-active", type: .duplicateScan, status: .running)
        let coordinator = makeGroupArtifactsCoordinator(
            probe: probe, jobs: [active], hasNavigationGroups: true)
        let outcome = await coordinator.run(sessionId: "s1")

        #expect(outcome == .enqueued)
        #expect(probe.enqueued.isEmpty)
        #expect(probe.waited.map { $0.jobId } == ["d-active"])
        #expect(probe.analyzed.isEmpty)
    }

    @Test("失败互不影响：duplicate 超时 → navigation 仍分析，原因进 outcome/日志")
    func duplicateFailureStillAnalyzesNavigation() async {
        let probe = GroupArtifactsProbe()
        let coordinator = makeGroupArtifactsCoordinator(
            probe: probe, jobs: [], waitFails: true)
        let outcome = await coordinator.run(sessionId: "s1")

        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.hasPrefix("duplicate-wait"))
        #expect(probe.analyzed == ["s1"], "duplicate 失败不能阻断 navigation")
        #expect(probe.logs.contains { $0.contains("groups.duplicate=failed") })
    }

    @Test("导航分析失败 → outcome 带 navigation 原因（duplicate 已就绪结果不丢）")
    func navigationFailureReported() async {
        let probe = GroupArtifactsProbe()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = pipelineJob(
            id: "d1", type: .duplicateScan, status: .succeeded,
            finishedAt: isoDate(now.addingTimeInterval(-60)))
        let coordinator = makeGroupArtifactsCoordinator(
            probe: probe, jobs: [recent], navigationFails: true, now: now)
        let outcome = await coordinator.run(sessionId: "s1")

        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.hasPrefix("navigation"))
        #expect(probe.enqueued.isEmpty, "近期成功已跳过 duplicate")
        #expect(probe.logs.contains { $0.contains("groups.navigation=failed") })
    }
}
