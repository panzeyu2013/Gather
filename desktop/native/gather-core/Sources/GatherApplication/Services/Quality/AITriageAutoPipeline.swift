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
//
// Wave5 batch2（E1）：超时语义从「固定总时长 + 取消 job」改为「无进展才停止等待、
// 不取消 job」——5000 张素材的 quality.score 永远超过 5 分钟；在目标素材量上旧实现
// 会取消仍在正常推进的任务，而且用户毫无感知。索引等待放宽到 6× 预算，
// 质量等待按 progress 续期（连续 maxPolls 次无进展才判定卡住）。
import Foundation
import GatherProtocol

/// 停止/跳过原因（Wave4b / task-44：reason 字符串集中一处，宿主日志与测试断言同一口径）。
public enum AITriageStopReason {
    public static let indexTimeout = "index-timeout"
    public static let indexNotSucceeded = "index-not-succeeded"
    public static let qualityTimeout = "quality-timeout"
    public static let qualityEnqueueFailed = "quality-enqueue-failed"
    /// 质量 job 因取消/中断结束：`quality-cancelled` / `quality-interrupted`。
    public static func qualityEnded(_ status: AnalysisJobStatus) -> String {
        "quality-\(status.rawValue)"
    }
    public static let qualityFailed = "quality-failed"
    /// waitForQuality 不会返回 .waiting（循环只在非 waiting 时返回）；保留常量给穷尽分支。
    public static let qualityWaitTimeout = "quality-wait-timeout"
    public static let cancelled = "cancelled"
    public static let triageDisabled = "triage-disabled"
}

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
        /// 调 TriageService.generate。
        ///
        /// Wave4a / task-39（E4）：**不再标 @MainActor**——宿主用专用 actor 承载
        /// 非 Sendable 的 TriageService，本闭包在 actor 上排队执行，不占主线程。
        public var generateTriage: @Sendable (String) async throws -> TriageSummary
        /// 调 TriageService.apply（source=.automation；幂等/门禁由服务侧保证）。
        public var applyTriage: @Sendable (TriageApplyInput) async throws -> TriageApplyResult
        /// triage_auto_apply（默认关）。
        public var autoApplyEnabled: @Sendable () -> Bool
        /// triage_enabled（E4）：关闭时整条自动初审（含 quality.score 入队）直接 skipped，
        /// 不做无用的完整质量/模型分析。
        public var triageEnabled: @Sendable () -> Bool
        /// 结构化日志（宿主传 GatherLogger；测试注入记录器）。
        public var log: @Sendable (String) -> Void
        /// 轮询间隔（测试注入 no-op）。
        public var poll: @Sendable () async throws -> Void

        public init(
            listJobs: @escaping @Sendable () throws -> [AnalysisJobData],
            enqueueQualityJob: @escaping @Sendable (String) throws -> AnalysisJobData,
            generateTriage: @escaping @Sendable (String) async throws -> TriageSummary,
            applyTriage: @escaping @Sendable (TriageApplyInput) async throws -> TriageApplyResult,
            autoApplyEnabled: @escaping @Sendable () -> Bool,
            triageEnabled: @escaping @Sendable () -> Bool,
            log: @escaping @Sendable (String) -> Void,
            poll: @escaping @Sendable () async throws -> Void
        ) {
            self.listJobs = listJobs
            self.enqueueQualityJob = enqueueQualityJob
            self.generateTriage = generateTriage
            self.applyTriage = applyTriage
            self.autoApplyEnabled = autoApplyEnabled
            self.triageEnabled = triageEnabled
            self.log = log
            self.poll = poll
        }
    }

    private let deps: Dependencies
    /// 轮询预算（Wave5 batch2）：
    /// - 质量等待：**连续 maxPolls 次无进展**才停止等待（默认 600 × 0.5s = 5 分钟无进展）；
    /// - 索引等待：扫描进度只在收尾刷新，预算放宽到 6×（默认约 30 分钟）；
    /// - 超时只停止等待，不取消 job（job 继续后台完成，建议可下次补生成）。
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
                deps.log("ai.auto-triage session=\(sessionId) stage=stopped reason="
                    + AITriageStopReason.indexTimeout)
                return AITriageAutoOutcome(
                    stage: .stopped, reason: AITriageStopReason.indexTimeout)
            }
            if case .stopped(let reason) = scanReady {
                return AITriageAutoOutcome(stage: .stopped, reason: reason)
            }
            guard !Task.isCancelled else {
                return AITriageAutoOutcome(stage: .stopped, reason: AITriageStopReason.cancelled)
            }

            // E4：triage 关闭时不做无用功（quality + model review 都要解码，成本高）。
            guard deps.triageEnabled() else {
                deps.log("ai.auto-triage session=\(sessionId) stage=skipped reason="
                    + AITriageStopReason.triageDisabled)
                return AITriageAutoOutcome(
                    stage: .skipped, reason: AITriageStopReason.triageDisabled)
            }

            // ② 确保 quality.score 在跑（已有活跃 job 就复用，避免重复解码）。
            let qualityJobId = try await ensureQualityJob(sessionId: sessionId)
            guard let qualityJobId else {
                return AITriageAutoOutcome(
                    stage: .stopped, reason: AITriageStopReason.qualityEnqueueFailed)
            }

            // ③ 等 quality 终态。
            switch try await waitForQuality(sessionId: sessionId, jobId: qualityJobId) {
            case .succeeded:
                break
            case .waiting:
                // waitForQuality 的循环只在非 waiting 时返回；这里只是穷尽兜底。
                return AITriageAutoOutcome(
                    stage: .stopped, qualityJobId: qualityJobId,
                    reason: AITriageStopReason.qualityWaitTimeout)
            case .failed(let reason):
                // Wave5 batch2：超时只停止等待，**不取消** quality job —— 5000 张素材上
                // 固定 5 分钟总上限会把仍在正常推进的任务取消掉；job 留在后台跑完，
                // 建议可下次由导入/页面事件补生成（宿主状态卡显示"未完成"）。
                deps.log("ai.auto-triage session=\(sessionId) stage=stopped"
                    + " quality=\(qualityJobId) reason=\(reason) quality-job=left-running")
                return AITriageAutoOutcome(
                    stage: .stopped, qualityJobId: qualityJobId, reason: reason)
            }

            guard !Task.isCancelled else {
                return AITriageAutoOutcome(
                    stage: .stopped, qualityJobId: qualityJobId,
                    reason: AITriageStopReason.cancelled)
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
            return AITriageAutoOutcome(stage: .stopped, reason: AITriageStopReason.cancelled)
        } catch {
            return AITriageAutoOutcome(stage: .stopped, reason: "failed: \(error)")
        }
    }

    /// quality.score 的 dedupeKey（Wave4b）：**按导入批次唯一**。
    ///
    /// 为什么不用固定 key：`AnalysisJobRepo.create` 对同 dedupeKey 的活跃行做去重、
    /// 对终态行默认 `inheritCheckpoint: true` —— 固定 key 在"同会话二次导入/重试"时
    /// 会把上一批的 `photoIds` 合并进新 job 的 checkpoint，只分析旧照片。
    /// 批次 nonce 由宿主每次调度生成；空 nonce 退化为旧 key（兼容测试/旧调用）。
    public static func qualityJobDedupeKey(scopeId: String, batchNonce: String) -> String {
        let nonce = batchNonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nonce.isEmpty else { return "quality.score:\(scopeId):auto-import-triage" }
        return "quality.score:\(scopeId):auto-import-triage:\(nonce)"
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
            return .stopped(AITriageStopReason.indexNotSucceeded)
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
            return .failed(AITriageStopReason.qualityFailed)
        case .cancelled, .interrupted:
            return .failed(AITriageStopReason.qualityEnded(job.status))
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

    /// 索引等待（Wave5 batch2）：扫描进度只在收尾刷新，progress 无法用于续期，
    /// 因此把预算放宽到 6×（默认约 30 分钟）；到点只停止等待，不取消扫描 job。
    private func waitForScan(sessionId: String) async throws -> ScanState? {
        let limit = max(1, maxPolls) * 6
        for _ in 0..<limit {
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
            // Wave4b：入队失败不能静默（之前只返回 nil，日志里看不出链路断在哪）。
            deps.log("ai.auto-triage session=\(sessionId) stage=stopped reason="
                + AITriageStopReason.qualityEnqueueFailed + " error=\(error)")
            return nil
        }
    }

    /// 质量等待（Wave5 batch2）：按**进展**续期而非总时长 —— job 的
    /// progress（current/total/message）一变就重置"无进展"计数；progressTotal
    /// 即该批张数（QualityService/ModelReview 逐批上报），因此 5000 张只会延长
    /// 等待、不会被 5 分钟总上限误杀；只有连续 maxPolls 次无进展（默认 5 分钟）
    /// 才停止等待。hardLimit 仅防失控（默认 maxPolls × 24 ≈ 2 小时）。
    private func waitForQuality(sessionId: String, jobId: String) async throws -> QualityState {
        let hardLimit = max(1, maxPolls) * 24
        var idlePolls = 0
        var lastProgress = ""
        for _ in 0..<hardLimit {
            try Task.checkCancellation()
            let jobs = try deps.listJobs()
            let state = Self.qualityState(jobs, sessionId: sessionId, jobId: jobId)
            if state != .waiting { return state }
            let progress = Self.progressSignature(jobs.first { $0.id == jobId })
            if progress == lastProgress {
                idlePolls += 1
            } else {
                lastProgress = progress
                idlePolls = 0
            }
            if idlePolls >= maxPolls {
                return .failed(AITriageStopReason.qualityTimeout)
            }
            try await deps.poll()
        }
        return .failed(AITriageStopReason.qualityTimeout)
    }

    /// job 进展签名（只含进度，不含 heartbeat/updatedAt —— 心跳不应让卡死任务"续命"）。
    static func progressSignature(_ job: AnalysisJobData?) -> String {
        guard let job else { return "missing" }
        return "\(job.progressCurrent)/\(job.progressTotal)/\(job.progressMessage)"
    }
}
