// desktop/native/gather-app/Tests/GatherAppTests/AITriageAutoPipelineTests.swift
// Wave5 batch2（E1）：导入后自动初审的"超时只停止等待、不取消 job + 大库按进展续期"。
//
// 既有 core 侧测试覆盖 happy path / 复用 job / 跳过；这里只补本批行为变更：
// 1. 质量超时不再取消 job（旧 Wave4b 语义已删除）；
// 2. 质量等待按 progress 续期 —— 5000 张素材的会话不会被 5 分钟总上限误杀；
// 3. 索引等待预算放宽到 6×（扫描进度只在收尾刷新）。
//
// 假调度器驱动，不 sleep 真时间；不依赖数据库/文件系统。
import Foundation
import Testing
import os
@testable import GatherApplication
import GatherProtocol

private final class PipelineJobFeed: Sendable {
    private struct State {
        var snapshots: [[AnalysisJobData]]
        var index = 0
        var enqueued: [String] = []
        var generated: [String] = []
        var applied: [TriageApplyInput] = []
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
    var applied: [TriageApplyInput] { lock.withLock { $0.applied } }
    var logs: [String] { lock.withLock { $0.logs } }

    func recordEnqueue(_ sessionId: String) { lock.withLock { $0.enqueued.append(sessionId) } }
    func recordGenerate(_ sessionId: String) { lock.withLock { $0.generated.append(sessionId) } }
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
    progressMessage: String = ""
) -> AnalysisJobData {
    AnalysisJobData(
        id: id, type: type, scopeType: "session", scopeId: sessionId,
        dedupeKey: "\(type.rawValue):\(id)", status: status, priority: 0,
        progressCurrent: progressCurrent, progressTotal: progressTotal,
        progressMessage: progressMessage,
        inputFingerprint: "", modelId: "", modelVersion: "", checkpoint: [:],
        attemptCount: 0, leaseOwner: "", heartbeatAt: "",
        errorCode: "", errorMessage: "",
        createdAt: "2026-11-11T00:00:00Z", startedAt: "", finishedAt: "",
        updatedAt: "2026-11-11T00:00:00Z")
}

private func pipelineSummary() -> TriageSummary {
    TriageSummary(
        counts: TriageCounts(keep: 3, reject: 1, review: 1, total: 5, coverage: 1),
        stale: false, policyVersion: "triage-v2", inputFingerprint: "fp-1",
        generatedAt: "2026-11-11T00:00:00Z")
}

private func makePipeline(
    feed: PipelineJobFeed,
    maxPolls: Int = 3
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
}
