// desktop/native/gather-app/Sources/GatherHost/Triage/AITriage.swift
// M1（Wave4 / task-6）：从 AppBootstrap.swift 拆出的「导入后自动初审」类型群（E1–E4）。
//
// 纯移动：AITriageBackgroundWorker / AITriageFacePrerequisite / AITriageFacePlan /
// AITriageGroupArtifactsCoordinator / AITriageAutoScheduler / AITriageImportTrigger
// 逐行未改；装配仍在 AppBootstrap.makeScene / wire。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherApplication
import GatherUI
// MARK: - Wave2 / task-14：导入后自动初审

/// Wave4a / task-39（E4）：把 triage 的 generate/apply 移出 MainActor。
///
/// TriageService 不是 Sendable，且持有 gate 缓存/串行锁；由本 actor **自己**用
/// Sendable 句柄（DBConnection + SettingsService）构造同口径实例，pipeline 只通过
/// actor 方法访问 → 生成/应用在 actor 执行器上跑，不占主线程，也不新增逃逸口注解。
///
/// 注意：这是与组合根不同的第二个实例（只服务导入后自动初审）；gate 缓存 TTL 2s 独立，
/// 影响仅限于"刚生成完页面可能短暂拿旧门控"，随页面重载收敛。
actor AITriageBackgroundWorker {
    private let database: DBConnection
    private let settings: SettingsService
    private var service: TriageService?

    init(database: DBConnection, settings: SettingsService) {
        self.database = database
        self.settings = settings
    }

    private func resolvedService() -> TriageService {
        if let service { return service }
        // 与 CompositionCore 的构造保持同一口径（TriagePolicy.fromSettings + triage_enabled）。
        let created = TriageService(
            repository: TriageRepo(connection: database),
            decisions: CullingDecisionRepo(connection: database),
            history: CullingHistoryRepo(connection: database),
            transactions: database,
            policyProvider: { [settings] in TriagePolicy.fromSettings(settings) },
            enabledProvider: { [settings] in settings.bool(.triageEnabled) },
            feedback: TriageFeedbackRepo(connection: database))
        service = created
        return created
    }

    func generate(sessionId: String) throws -> TriageSummary {
        try resolvedService().generate(sessionId: sessionId)
    }

    func apply(_ input: TriageApplyInput) throws -> TriageApplyResult {
        try resolvedService().apply(Confirmed(input, source: .automation))
    }
}

/// E2 判定结果（Wave5 batch2）：人脸观测是否存在。
enum AITriageFacePrerequisite: Equatable {
    /// 已有人脸观测：闭眼/微笑/人脸合焦/小脸保护都能用。
    case present
    /// 没有观测：本次入队 face.analyze，但**不等待**（先按无脸信号生成建议）。
    case missing
    /// 查询失败：按"有观测"处理，绝不因为前置检查失败阻塞初审。
    case queryFailed
}

/// E2 动作计划：状态卡相位 + 是否入队 face.analyze。
///
/// "不阻塞"是结构性的：入队只发起后台任务，pipeline 立刻继续生成建议（本次按
/// 无脸信号），不会等待 face.analyze 的结果；状态卡保留「待人脸分析」直到本轮结束。
struct AITriageFacePlan: Equatable {
    let phase: AITriageStatusStore.Phase
    let enqueueFaceAnalysis: Bool

    static func make(from state: AITriageFacePrerequisite) -> AITriageFacePlan {
        switch state {
        case .present:
            return AITriageFacePlan(phase: .generating, enqueueFaceAnalysis: false)
        case .missing:
            return AITriageFacePlan(phase: .waitingFace, enqueueFaceAnalysis: true)
        case .queryFailed:
            return AITriageFacePlan(phase: .generating, enqueueFaceAnalysis: false)
        }
    }
}

/// Wave5 batch6（E3）：导入后自动初审前的分组产物准备。
///
/// 为什么需要：triage 的理由码要比较相似/重复/场景组，而三类分组分析一直是手动按钮
/// （50-ai-similarity §3-D）；导入即初审后若没有任何组，建议只能出硬技术失败。
///
/// 边界（与任务一致）：
/// - 复用现有 job 类型 duplicate.scan（JobService）与现有 navigation.analyze（NavigationAPI；
///   该命令没有 job 类型，不新增 job 类型）；
/// - 已有近期成功结果/已有组则跳过，不重算、不重复入队；
/// - 有界等待（默认 60s：poll 预算的一小段），超时只停止等待、**不取消** job；
/// - 任一步失败只记录原因并继续（初审不能被分组拖停）；不自动应用分组建议。
struct AITriageGroupArtifactsCoordinator: Sendable {
    /// duplicate.scan 的决策（纯判定，测试直接驱动）。
    enum DuplicatePlan: Equatable, Sendable {
        /// 近期成功：直接跳过，不重复入队。
        case recentSuccess
        /// 会话已有活跃 job：复用它并做有界等待（不重复入队）。
        case waitActive(String)
        /// 无结果/无活跃：入队并做有界等待。
        case enqueue
    }

    struct Dependencies: Sendable {
        var listJobs: @Sendable () throws -> [AnalysisJobData]
        var enqueueDuplicateScan: @Sendable (String) throws -> AnalysisJobData
        /// 有界等待：超时抛错但**不取消** job（与 quality 等待同一语义）。
        var waitDuplicateScan: @Sendable (String, Int64) async throws -> Void
        var hasNavigationGroups: @Sendable (String) throws -> Bool
        var analyzeNavigation: @Sendable (String) async throws -> Void
        var now: @Sendable () -> Date
        var log: @Sendable (String) -> Void
    }

    let deps: Dependencies
    /// 有界等待预算：任务要求"poll 预算的一小段"，默认 60s；超时只停止等待。
    let duplicateWaitTimeoutMs: Int64
    /// 近期成功窗口：默认 15 分钟内的成功结果视为已就绪，避免重复 dHash 扫描。
    let recentSuccessWindow: TimeInterval

    init(
        deps: Dependencies,
        duplicateWaitTimeoutMs: Int64 = 60_000,
        recentSuccessWindow: TimeInterval = 15 * 60
    ) {
        self.deps = deps
        self.duplicateWaitTimeoutMs = duplicateWaitTimeoutMs
        self.recentSuccessWindow = recentSuccessWindow
    }

    /// 纯判定：活跃 job 优先复用；近期成功跳过；其余入队。
    ///
    /// finishedAt 不可解析（旧行/空）时视为"不可判定近期"→ 重跑：宁可多扫一次，
    /// 也不能把没有组的旧结果当作已就绪（否则 triage 又退化到硬技术信号）。
    static func duplicatePlan(
        jobs: [AnalysisJobData],
        sessionId: String,
        now: Date,
        recentWindow: TimeInterval
    ) -> DuplicatePlan {
        let scans = jobs
            .filter { $0.type == .duplicateScan && $0.scopeId == sessionId }
            .sorted { $0.createdAt < $1.createdAt }
        if let active = scans.last(where: { Self.isActive($0.status) }) {
            return .waitActive(active.id)
        }
        if let succeeded = scans.last(where: { $0.status == .succeeded }),
           let finished = Self.parseTimestamp(succeeded.finishedAt),
           now.timeIntervalSince(finished) <= recentWindow {
            return .recentSuccess
        }
        return .enqueue
    }

    static func isActive(_ status: AnalysisJobStatus) -> Bool {
        switch status {
        case .queued, .running, .cancelling: true
        case .succeeded, .failed, .cancelled, .interrupted: false
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        // 形式：ISO8601（测试夹具为 "2026-11-11T00:00:00Z"；持久行可能带毫秒）。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// 准备分组产物。不抛错：所有失败收敛成 .failed(reason)，交给 pipeline 记日志并继续。
    func run(sessionId: String) async -> AITriageGroupArtifactsOutcome {
        var performed = false
        var failureReason: String?

        // 1) duplicate.scan：与 navigation 互不影响（前者失败不阻止后者）。
        do {
            let jobs = try deps.listJobs()
            switch Self.duplicatePlan(
                jobs: jobs,
                sessionId: sessionId,
                now: deps.now(),
                recentWindow: recentSuccessWindow
            ) {
            case .recentSuccess:
                deps.log("ai.auto-triage session=\(sessionId)"
                    + " groups.duplicate=skip reason=recent-success")
            case .waitActive(let jobId):
                performed = true
                deps.log("ai.auto-triage session=\(sessionId)"
                    + " groups.duplicate=wait-active job=\(jobId)")
                do {
                    try await deps.waitDuplicateScan(jobId, duplicateWaitTimeoutMs)
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=ready job=\(jobId)")
                } catch {
                    failureReason = "duplicate-wait: \(error)"
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=failed job=\(jobId) reason=\(error)")
                }
            case .enqueue:
                performed = true
                do {
                    let job = try deps.enqueueDuplicateScan(sessionId)
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=enqueued job=\(job.id)")
                    do {
                        try await deps.waitDuplicateScan(job.id, duplicateWaitTimeoutMs)
                        deps.log("ai.auto-triage session=\(sessionId)"
                            + " groups.duplicate=ready job=\(job.id)")
                    } catch {
                        failureReason = "duplicate-wait: \(error)"
                        deps.log("ai.auto-triage session=\(sessionId)"
                            + " groups.duplicate=failed job=\(job.id) reason=\(error)")
                    }
                } catch {
                    failureReason = "duplicate-enqueue: \(error)"
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=failed reason=enqueue: \(error)")
                }
            }
        } catch {
            failureReason = "duplicate-list: \(error)"
            deps.log("ai.auto-triage session=\(sessionId)"
                + " groups.duplicate=failed reason=list: \(error)")
        }

        // 2) navigation.analyze：已有组不重算；无 job 类型，直接调用现有 API。
        do {
            if try deps.hasNavigationGroups(sessionId) {
                deps.log("ai.auto-triage session=\(sessionId)"
                    + " groups.navigation=skip reason=already-exists")
            } else {
                performed = true
                do {
                    try await deps.analyzeNavigation(sessionId)
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.navigation=analyzed")
                } catch {
                    failureReason = failureReason ?? "navigation: \(error)"
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.navigation=failed reason=\(error)")
                }
            }
        } catch {
            failureReason = failureReason ?? "navigation-check: \(error)"
            deps.log("ai.auto-triage session=\(sessionId)"
                + " groups.navigation=failed reason=check: \(error)")
        }

        guard let failureReason else {
            return performed ? .enqueued : .alreadyReady
        }
        return .failed(failureReason)
    }
}

/// 自动初审的宿主调度入口（Wave5 batch2 / E1）。
///
/// 为什么单独成类型：五个导入入口（菜单/Finder、C1 文件、Dashboard 新建、
/// 加照片到已有工作区、Shortcuts 建库）共享同一份依赖与开关语义；
/// 之前只有前两个入口接了调度。类型是 Sendable，`schedule` 必须 MainActor
/// （读设置 + 写 UI 状态卡都要求主线程；真正耗时的 pipeline 仍在 detached 任务）。
struct AITriageAutoScheduler: Sendable {
    let jobService: JobService
    let database: DBConnection
    let settings: SettingsService
    /// E2：该会话是否已有人脸观测（face_observations 有行）。
    let hasFaceObservations: @Sendable (String) throws -> Bool
    /// E2：缺观测时入队一次增量 face.analyze（不等待结果）。
    let enqueueFaceAnalysis: @Sendable (String) -> Void
    /// E3：quality 成功后、生成建议前确保分组产物（duplicate.scan + navigation.analyze）。
    let ensureGroupArtifacts: @Sendable (String) async -> AITriageGroupArtifactsOutcome

    @MainActor
    func schedule(sessionId: String) {
        AITriageImportTrigger.schedule(
            sessionId: sessionId,
            jobService: jobService,
            database: database,
            settings: settings,
            hasFaceObservations: hasFaceObservations,
            enqueueFaceAnalysis: enqueueFaceAnalysis,
            ensureGroupArtifacts: ensureGroupArtifacts)
    }
}

/// 导入完成后调度自动初审（默认关：triage_auto_generate=0 时直接返回，行为与旧版一致）。
///
/// 边界：
/// - 只调度、不等待（Task.detached）；导入 API 的返回时间不变；
/// - 失败/超时只打日志 + 写状态卡，不回写导入状态（增强能力不能把导入变红）；
/// - 进度与取消走既有 JobService：quality.score 是普通 job，控制中心可见可取消；
///   用户取消该 job → pipeline 观察终态后停止，不会继续生成建议；
/// - Wave5 batch2：超时只停止等待、不取消 job；缺人脸观测时入队 face.analyze
///   但不等它（本次按无脸信号先生成，状态卡显示"待人脸分析"）。
/// - Wave5 batch6（E3）：quality 成功后先确保分组产物（duplicate.scan + navigation.analyze，
///   60s 有界等待）；失败只记日志并继续生成建议，不因分组拖停初审。
enum AITriageImportTrigger {
    /// @MainActor：只做调度（读设置 + 建 actor + 起 detached 任务）；
    /// 真正耗时的 generate/apply 在 `AITriageBackgroundWorker` actor 上执行（E4）。
    @MainActor
    static func schedule(
        sessionId: String,
        jobService: JobService,
        database: DBConnection,
        settings: SettingsService,
        hasFaceObservations: (@Sendable (String) throws -> Bool)? = nil,
        enqueueFaceAnalysis: (@Sendable (String) -> Void)? = nil,
        ensureGroupArtifacts: (@Sendable (String) async -> AITriageGroupArtifactsOutcome)? = nil
    ) {
        guard settings.bool(.triageAutoGenerate) else {
            // 未启用也要可见（状态卡 = 用户唯一的"这次导入到底跑没跑 AI 初审"答案）。
            AITriageStatusStore.shared.set(sessionId: sessionId, phase: .notEnabled)
            return
        }
        guard settings.bool(.triageEnabled) else {
            // triage 关闭：整条自动初审（含 quality 入队）直接跳过，不做无用解码。
            // 记一行日志便于排查"开了 auto_generate 却没反应"（triage_enabled 默认 0）。
            AITriageStatusStore.shared.set(sessionId: sessionId, phase: .notEnabled)
            GatherLogger.log(
                "ai.auto-triage session=\(sessionId) stage=skipped reason=triage-disabled",
                level: .info)
            return
        }
        AITriageStatusStore.shared.set(sessionId: sessionId, phase: .waitingIndex)
        let worker = AITriageBackgroundWorker(database: database, settings: settings)
        // Wave4b：一条导入链一个批次 nonce —— dedupeKey 唯一，`AnalysisJobRepo.create` 的
        // 默认 `inheritCheckpoint` 不会命中上一批终态行（旧 photoIds 会只分析旧照片）。
        let batchNonce = UUID().uuidString
        let deps = AITriageAutoPipeline.Dependencies(
            listJobs: { try jobService.list(status: nil, includeCheckpoint: false) },
            enqueueQualityJob: { scopeId in
                // 状态卡：质量分析已入队（复用活跃 job 时本闭包不调用，状态会停在
                // "等待扫描"直到生成阶段——可接受的最小可见性）。
                Task { @MainActor in
                    AITriageStatusStore.shared.set(
                        sessionId: scopeId, phase: .waitingQuality)
                }
                return try jobService.create(JobCreateParams(
                    type: .qualityScore,
                    scopeType: "session",
                    scopeId: scopeId,
                    dedupeKey: AITriageAutoPipeline.qualityJobDedupeKey(
                        scopeId: scopeId, batchNonce: batchNonce)))
            },
            // 生成/应用都在后台 actor 上（E4）；闭包本身是 @Sendable，不占主线程。
            generateTriage: { scopeId in
                // E2：生成前检查人脸观测。缺观测只入队 face.analyze、**不等待**，
                // 状态卡显示"待人脸分析"；本次建议仍按技术质量/审美信号照常生成。
                let facePlan: AITriageFacePlan? = hasFaceObservations.map { probe in
                    AITriageFacePlan.make(from: Self.facePrerequisite(
                        sessionId: scopeId, hasFaceObservations: probe))
                }
                let statusPhase = facePlan?.phase ?? .generating
                await MainActor.run {
                    AITriageStatusStore.shared.set(
                        sessionId: scopeId, phase: statusPhase)
                }
                if facePlan?.enqueueFaceAnalysis == true {
                    enqueueFaceAnalysis?(scopeId)
                }
                return try await worker.generate(sessionId: scopeId)
            },
            applyTriage: { input in
                try await worker.apply(input)
            },
            autoApplyEnabled: { settings.bool(.triageAutoApply) },
            triageEnabled: { settings.bool(.triageEnabled) },
            ensureGroupArtifacts: { scopeId in
                guard let ensureGroupArtifacts else { return .alreadyReady }
                return await ensureGroupArtifacts(scopeId)
            },
            log: { message in
                GatherLogger.log(message, level: .info)
            },
            poll: { try await Task.sleep(for: .milliseconds(500)) }
        )
        let pipeline = AITriageAutoPipeline(deps: deps)
        Task.detached(priority: .utility) {
            let outcome = await pipeline.run(sessionId: sessionId)
            GatherLogger.log(
                "ai.auto-triage session=\(sessionId) stage=\(outcome.stage.rawValue)"
                    + " quality=\(outcome.qualityJobId ?? "-")"
                    + " keep=\(outcome.summary?.counts.keep ?? -1)"
                    + " reject=\(outcome.summary?.counts.reject ?? -1)"
                    + " review=\(outcome.summary?.counts.review ?? -1)"
                    + " applied=\(outcome.applied?.appliedPhotos ?? 0)"
                    + " reason=\(outcome.reason ?? "-")",
                level: .info)
            // Wave5 batch2：终态（含跳过/超时）写进状态卡 —— 失败/跳过不能只进日志。
            await MainActor.run {
                AITriageStatusStore.shared.set(
                    sessionId: sessionId,
                    phase: Self.statusPhase(for: outcome))
            }
            // Wave4b：auto-generate-only（triage_auto_apply=0）也要广播——之前只在
            // appliedPhotos>0 时发，页面看不到"已生成建议"；现在只要生成成功（done）就刷新。
            guard outcome.stage == .done else { return }
            // 已挂载的挑片/图库据此重拉建议与决策（与 C1 判断落库同一广播口径）。
            await MainActor.run {
                GatherEventCenter.postDomainChange(
                    .culling, sessionId: sessionId, origin: "ai-auto-triage")
            }
        }
    }

    /// E2 纯判定：有人脸观测 = present；无 = missing；查询抛错 = queryFailed
    /// （按"有观测"处理——前置检查失败不能阻塞初审）。
    static func facePrerequisite(
        sessionId: String,
        hasFaceObservations: @Sendable (String) throws -> Bool
    ) -> AITriageFacePrerequisite {
        do {
            return try hasFaceObservations(sessionId) ? .present : .missing
        } catch {
            GatherLogger.log(
                "ai.auto-triage face prerequisite query failed: \(error)", level: .warn)
            return .queryFailed
        }
    }

    /// pipeline 结果 → 状态卡相位（Wave5 batch2）。纯映射，供单测直接驱动。
    @MainActor
    static func statusPhase(for outcome: AITriageAutoOutcome) -> AITriageStatusStore.Phase {
        switch outcome.stage {
        case .done:
            let counts = outcome.summary?.counts
            return .done(
                keep: counts?.keep ?? 0,
                reject: counts?.reject ?? 0,
                review: counts?.review ?? 0)
        case .skipped:
            return .skipped(outcome.reason ?? AITriageStopReason.cancelled)
        case .stopped:
            let reason = outcome.reason ?? "stopped"
            // pipeline 的未预期异常收敛成 "failed: ..."（见 AITriageAutoPipeline.run）。
            return reason.hasPrefix("failed:") ? .failed(reason) : .stopped(reason)
        }
    }
}
