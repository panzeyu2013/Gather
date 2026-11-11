// desktop/native/gather-core/Sources/GatherApplication/Services/Quality/AITriageAutoPipeline.swift
// Wave2 / task-14：导入完成后的自动初审第三段（quality.score → triage.generate）。
//
// 为什么需要它：既有链路只到 quality.score 为止（WorkflowRegistry 的
// checksum.backfill(ingest) → metadata.scan(autoQuality) → quality.score），
// 建议生成一直只活在挑片页 ViewModel 里——用户不打开挑片页就永远没有建议。
// 本类型把"质量分析成功之后生成建议（并按开关自动应用）"做成可测试的编排，
// 宿主（AppBootstrap）在导入完成后调度它。
//
// 纪律：
// - 不新增 job 类型（schema CHECK 不允许），复用现有 quality.score；
// - 失败/取消绝不反向影响导入（导入已成功，本流程只是增强）；
// - 轮询与睡眠可注入 → 单测用假调度器驱动，不 sleep 真时间。
import Foundation
import GatherProtocol

/// 自动初审的编排结果（宿主只用来日志/广播，不参与业务判断）。
public struct AITriageAutoOutcome: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case done
        case skipped
        case stopped
    }

    public var stage: Stage
    /// 本次采用的 quality.score job（可能是既有在跑的，也可能是新建的）。
    public var qualityJobId: String?
    public var summary: TriageSummary?
    public var applied: TriageApplyResult?
    public var reason: String?

    public init(
        stage: Stage,
        qualityJobId: String? = nil,
        summary: TriageSummary? = nil,
        applied: TriageApplyResult? = nil,
        reason: String? = nil
    ) {
        self.stage = stage
        self.qualityJobId = qualityJobId
        self.summary = summary
        self.applied = applied
        self.reason = reason
    }
}

/// 导入后自动初审：等索引 → 确保 quality.score 跑完 → 生成建议（可选自动应用）。
///
/// 纯编排，所有副作用经 Dependencies 注入，因此可单测（假 job 列表 + 假睡眠）。
public struct AITriageAutoPipeline: Sendable {
    public struct Dependencies: Sendable {
        /// 会话相关 job 快照（含历史终态；调用方按 includeCheckpoint=false 取）。
        public var listJobs: @Sendable () throws -> [AnalysisJobData]
        /// 入队 quality.score（photoIds 缺省 = 会话全部照片）。
        public var enqueueQualityJob: @Sendable (String) throws -> AnalysisJobData
        /// 调 TriageService.generate。`@MainActor`：TriageService 不是 Sendable，
        /// 由宿主在 MainActor 上构造闭包（与挑片页 generateTriage 的既有隔离一致：
        /// 那条路径本来也在 MainActor 上调同一个服务）。
        public var generateTriage: @MainActor @Sendable (String) async throws -> TriageSummary
        /// 调 TriageService.apply（source=.automation；幂等/门禁由服务侧保证）。
        public var applyTriage: @MainActor @Sendable (TriageApplyInput) async throws -> TriageApplyResult
        /// triage_auto_apply（默认关）。
        public var autoApplyEnabled: @Sendable () -> Bool
        /// 轮询间隔（测试注入 no-op）。
        public var poll: @Sendable () async throws -> Void

        public init(
            listJobs: @escaping @Sendable () throws -> [AnalysisJobData],
            enqueueQualityJob: @escaping @Sendable (String) throws -> AnalysisJobData,
            generateTriage: @escaping @MainActor @Sendable (String) async throws -> TriageSummary,
            applyTriage: @escaping @MainActor @Sendable (TriageApplyInput) async throws -> TriageApplyResult,
            autoApplyEnabled: @escaping @Sendable () -> Bool,
            poll: @escaping @Sendable () async throws -> Void
        ) {
            self.listJobs = listJobs
            self.enqueueQualityJob = enqueueQualityJob
            self.generateTriage = generateTriage
            self.applyTriage = applyTriage
            self.autoApplyEnabled = autoApplyEnabled
            self.poll = poll
        }
    }

    private let deps: Dependencies
    /// 轮询上限（默认 600 × 0.5s = 5 分钟；索引/质量都能在 job 里续跑，超时只是停止等待）。
    private let maxPolls: Int

    public init(deps: Dependencies, maxPolls: Int = 600) {
        self.deps = deps
        self.maxPolls = max(1, maxPolls)
    }

    /// 执行编排。不抛错：所有失败都收敛成 .stopped/.skipped（导入不能被它拖累）。
    public func run(sessionId: String) async -> AITriageAutoOutcome {
        do {
            // ① 等 metadata.scan 终态：目录导入的照片由索引 job 发现，扫完才有 photoIds。
            guard let scanReady = try await waitForScan(sessionId: sessionId) else {
                return AITriageAutoOutcome(stage: .stopped, reason: "index-timeout")
            }
            if case .stopped(let reason) = scanReady {
                return AITriageAutoOutcome(stage: .stopped, reason: reason)
            }
            guard !Task.isCancelled else {
                return AITriageAutoOutcome(stage: .stopped, reason: "cancelled")
            }

            // ② 确保 quality.score 在跑（已有活跃 job 就复用，避免重复解码）。
            let qualityJobId = try await ensureQualityJob(sessionId: sessionId)
            guard let qualityJobId else {
                return AITriageAutoOutcome(stage: .stopped, reason: "quality-enqueue-failed")
            }

            // ③ 等 quality 终态。
            switch try await waitForQuality(sessionId: sessionId, jobId: qualityJobId) {
            case .succeeded:
                break
            case .waiting:
                // waitForQuality 的循环只在非 waiting 时返回；这里只是穷尽兜底。
                return AITriageAutoOutcome(
                    stage: .stopped, qualityJobId: qualityJobId, reason: "quality-wait-timeout")
            case .failed(let reason):
                return AITriageAutoOutcome(
                    stage: .stopped, qualityJobId: qualityJobId, reason: reason)
            }

            guard !Task.isCancelled else {
                return AITriageAutoOutcome(stage: .stopped, qualityJobId: qualityJobId, reason: "cancelled")
            }

            // ④ 生成建议（triage_auto_generate 的语义：到了这里就一定要生成一次）。
            let summary = try await deps.generateTriage(sessionId)
            guard deps.autoApplyEnabled() else {
                return AITriageAutoOutcome(
                    stage: .done, qualityJobId: qualityJobId, summary: summary)
            }

            // ⑤ 自动应用（automation 来源；服务侧仍跳过人工决策与低置信项）。
            let input = TriageApplyInput(
                sessionId: sessionId,
                verdicts: [.keep, .reject],
                minConfidence: nil,
                fingerprint: summary.inputFingerprint)
            let applied = try await deps.applyTriage(input)
            return AITriageAutoOutcome(
                stage: .done, qualityJobId: qualityJobId, summary: summary, applied: applied)
        } catch is CancellationError {
            return AITriageAutoOutcome(stage: .stopped, reason: "cancelled")
        } catch {
            return AITriageAutoOutcome(stage: .stopped, reason: "failed: \(error)")
        }
    }

    // MARK: - 纯判定（测试直接驱动）

    /// 索引是否已到终态。返回 nil = 轮询超时；.ready = 可以继续；.stopped = 别继续。
    static func scanState(_ jobs: [AnalysisJobData], sessionId: String) -> ScanState {
        let scans = jobs
            .filter { $0.type == .metadataScan && $0.scopeId == sessionId }
            .sorted { $0.createdAt < $1.createdAt }
        guard let latest = scans.last else { return .ready }
        switch latest.status {
        case .queued, .running, .cancelling:
            return .waiting
        case .succeeded:
            return .ready
        case .failed, .cancelled, .interrupted:
            // 索引失败时没有可信的 photoIds：不硬跑质量分析（会得到 0 张）。
            return .stopped("index-not-succeeded")
        }
    }

    enum ScanState: Equatable, Sendable {
        case waiting
        case ready
        case stopped(String)
    }

    /// 质量分析是否终态；以及该不该继续生成建议。
    static func qualityState(
        _ jobs: [AnalysisJobData], sessionId: String, jobId: String
    ) -> QualityState {
        guard let job = jobs.first(where: { $0.id == jobId }) else { return .waiting }
        switch job.status {
        case .queued, .running, .cancelling:
            return .waiting
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed("quality-failed")
        case .cancelled, .interrupted:
            return .failed("quality-\(job.status.rawValue)")
        }
    }

    enum QualityState: Equatable, Sendable {
        case waiting
        case succeeded
        case failed(String)
    }

    /// 会话里是否有活跃（queued/running/cancelling）的 quality.score job。
    static func activeQualityJob(_ jobs: [AnalysisJobData], sessionId: String) -> AnalysisJobData? {
        jobs.filter {
            $0.type == .qualityScore && $0.scopeId == sessionId
        }.last { job in
            switch job.status {
            case .queued, .running, .cancelling: true
            case .succeeded, .failed, .cancelled, .interrupted: false
            }
        }
    }

    // MARK: - 内部轮询

    private func waitForScan(sessionId: String) async throws -> ScanState? {
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            let state = Self.scanState(try deps.listJobs(), sessionId: sessionId)
            if state != .waiting { return state }
            try await deps.poll()
        }
        return nil
    }

    private func ensureQualityJob(sessionId: String) async throws -> String? {
        if let active = Self.activeQualityJob(try deps.listJobs(), sessionId: sessionId) {
            return active.id
        }
        do {
            return try deps.enqueueQualityJob(sessionId).id
        } catch {
            return nil
        }
    }

    private func waitForQuality(sessionId: String, jobId: String) async throws -> QualityState {
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            let state = Self.qualityState(try deps.listJobs(), sessionId: sessionId, jobId: jobId)
            if state != .waiting { return state }
            try await deps.poll()
        }
        return .failed("quality-timeout")
    }
}
