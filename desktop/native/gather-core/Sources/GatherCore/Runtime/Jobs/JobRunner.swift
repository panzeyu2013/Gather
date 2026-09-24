// desktop/native/gather-core/Sources/GatherCore/Runtime/Jobs/JobRunner.swift
// R3：JobRunner actor —— 取代 Services/JobService.swift + JobScheduler.swift +
// AnalysisWorker.swift（集成轮同批删除；本轮只新增，不接线、不改旧文件）。
//
// 与旧实现（job.service.ts 移植版）的语义对齐与硬化：
// - 单注册表：每个 AnalysisJobType 一个 executor；未注册类型 create 即抛
//   executorNotRegistered（旧实现静默永久 queued，审计 7.1-5）；
// - 租约 fencing：claim 成功才执行；心跳失败/租约被夺 → abort 该作业取消信号，
//   并以 leaseLost 抛错；看门狗发现 interrupted/租约漂移 → abort signal
//   （旧实现 throwIfCancelled 不识别 interrupted，审计 7.1-1）；
// - 取消：内存取消标志先置（signal.abort），DB 置 cancelling/cancelled；
//   running 作业先给宽限期自行退出，超时强制定终态并唤醒等待者
//   （旧实现 cancelling 可永久残留，审计 7.1-2/3）；
// - stop()：abort 全部作业后带超时等待在飞任务，超时仍返回（不挂死）；
// - checkpoint：JobCheckpoint 类型安全编解码；恢复后的行仍带上次 checkpoint，
//   executor 经 initialCheckpoint/loadCheckpoint() 读回；
// - 去重键：JobDedupKey 策略（同 key 共享在飞、同资源不同 key busy、
//   export key 纳入目标摘要）；
// - 完成结果：原子 take —— 作业完成时无等待者则落内存结果供一次性取走；
//   有等待者则广播给全部等待者（共享在飞结果），之后取回落持久行
//   （succeeded → nil，failed/interrupted → jobFailed，cancelled →
//   JobCancelledError）；超时返回 nil；
// - 崩溃恢复：start() 真正执行 recoverStale + resumeInterrupted 后才 drain，
//   并返回 JobRunnerStartReport 供宿主/测试核对。
//
// 依赖说明（集成轮）：JobAbortSignal / JobCancelledError 目前仍是
// Services/JobService.swift 的 public 类型（本轮不动旧文件）；删除旧文件时把
// 这两个声明原样迁入本文件即可，语义不变。
//
// 注意：Runtime/ 目录禁止出现 SQL 文本（check-no-legacy.sh 度量）。

import Foundation

// MARK: - 错误

public enum JobRunnerError: Error, Equatable {
    /// 未知作业（旧 JobServiceError.jobNotFound 同名同载荷）。
    case jobNotFound(String)
    /// 作业失败终态（旧 JobServiceError.jobFailed 同名同载荷）。
    case jobFailed(String, String)
    /// claim 失败（作业已被其他租约方执行/已终态）。
    case notClaimable(String)
    /// 心跳失败/租约被夺：执行行保持 running，由 recoverStale 接管。
    case leaseLost(String)
    /// 未注册 executor 的作业类型（旧实现静默 queued；新实现显式报错）。
    case executorNotRegistered(AnalysisJobType)
    /// 同资源已有不同 key 的活跃作业：busy（载荷：资源 + 在飞 key）。
    case busy(JobResource, String)

    /// 稳定错误码（日志/测试/宿主映射用；case 名与旧 JobServiceError 逐字对齐）。
    public var code: String {
        switch self {
        case .jobNotFound: "JOB_NOT_FOUND"
        case .jobFailed: "JOB_FAILED"
        case .notClaimable: "JOB_NOT_CLAIMABLE"
        case .leaseLost: "JOB_LEASE_LOST"
        case .executorNotRegistered: "JOB_EXECUTOR_NOT_REGISTERED"
        case .busy: "JOB_BUSY"
        }
    }
}

// MARK: - 启动报告

/// start() 的恢复结果（崩溃恢复必须真实执行，可核对）。
public struct JobRunnerStartReport: Equatable, Sendable {
    /// recoverStale 判死的过期租约行数。
    public let recoveredStale: Int
    /// resumeInterrupted 重新入队的行数（按已注册且 autoResume 的类型）。
    public let resumedInterrupted: Int

    public init(recoveredStale: Int, resumedInterrupted: Int) {
        self.recoveredStale = recoveredStale
        self.resumedInterrupted = resumedInterrupted
    }
}

// MARK: - 内部状态

/// 完成结果（value 或 error 二选一）。
private enum Completion {
    case value(Any?)
    case error(Error)
}

/// 内存完成结果：仅在「完成时没有登记等待者」时落表，供一次性 take。
private struct CompletedResult {
    let value: Any?
    let error: (any Error)?
    let expiresAt: Int64
}

/// 单个在飞作业的运行态。
private struct RunState {
    let jobId: String
    let dedupeKey: String
    let signal: JobAbortSignal
    /// 心跳失败或租约被夺：执行路径以此抛 leaseLost，且不覆写持久行。
    var leaseLost = false
    /// 取消宽限期的强制终态任务。
    var graceTask: Task<Void, Never>?
}

/// 一次性触发旗（超时/完成竞速用；actor 化，不引入 unchecked Sendable 标注）。
private actor OnceFlag {
    private var fired = false

    func tryFire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - JobRunner

public actor JobRunner {
    public typealias JobExecutor = (AnalysisJobData, JobRunnerContext) async throws -> Any?
    public typealias JobProgressSink = (AnalysisJobData, JobProgressUpdate) -> Void

    public static let maxConcurrentJobs = 2
    public static let progressWriteIntervalMs: Int64 = 250
    public static let waitForResultTimeoutMs: Int64 = 60 * 60_000
    public static let cancelDbCheckEvery = 50
    public static let cancelDbCheckIntervalMs: Int64 = 500
    public static let completedResultTtlMs: Int64 = 5 * 60_000
    public static let heartbeatIntervalMs: Int64 = 5_000
    public static let watchdogIntervalMs: Int64 = 5_000
    /// 取消宽限期：abort 后等待 executor 自行收尾；超时强制定终态。
    public static let cancelGracePeriodMs: Int64 = 2_000
    /// stop() 等待在飞任务的上限；超时仍返回。
    public static let stopTimeoutMs: Int64 = 5_000
    public static let leaseTimeoutMs: Int = 30_000
    /// 终态行同时是 workspace 阶段证据（workspace-status latestScanJob /
    /// hasSuccessfulExport），clearCompleted 排除（对齐旧 JobService）。
    public static let clearCompletedStageEvidenceTypes: [AnalysisJobType] = [.metadataScan, .exportExecute]

    private let jobStore: any JobStore
    /// 租约所有者（跨进程可辨识；心跳/终态写入均带该谓词）。
    public nonisolated let leaseOwner: String
    private let heartbeatIntervalMs: Int64
    private let watchdogIntervalMs: Int64
    private let cancelGracePeriodMs: Int64
    private let stopTimeoutMs: Int64
    private let progressWriteIntervalMs: Int64
    private let completedResultTtlMs: Int64
    private let maxConcurrentJobs: Int

    private var executors: [AnalysisJobType: JobExecutor] = [:]
    private var autoResumeTypes: Set<AnalysisJobType> = []
    private var runs: [String: RunState] = [:]
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var resultWaiters: [String: [UUID: CheckedContinuation<Any?, Error>]] = [:]
    private var completedResults: [String: CompletedResult] = [:]
    private var progressSink: JobProgressSink?
    private var watchdog: Task<Void, Never>?
    private var isStarted = false
    private var isDraining = false
    private var drainRequested = false

    public init(
        jobStore: any JobStore,
        leaseOwner: String? = nil,
        heartbeatIntervalMs: Int64 = JobRunner.heartbeatIntervalMs,
        watchdogIntervalMs: Int64 = JobRunner.watchdogIntervalMs,
        cancelGracePeriodMs: Int64 = JobRunner.cancelGracePeriodMs,
        stopTimeoutMs: Int64 = JobRunner.stopTimeoutMs,
        progressWriteIntervalMs: Int64 = JobRunner.progressWriteIntervalMs,
        completedResultTtlMs: Int64 = JobRunner.completedResultTtlMs,
        maxConcurrentJobs: Int = JobRunner.maxConcurrentJobs
    ) {
        self.jobStore = jobStore
        self.leaseOwner = leaseOwner ?? "main-\(ProcessInfo.processInfo.processIdentifier)"
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.watchdogIntervalMs = watchdogIntervalMs
        self.cancelGracePeriodMs = cancelGracePeriodMs
        self.stopTimeoutMs = stopTimeoutMs
        self.progressWriteIntervalMs = progressWriteIntervalMs
        self.completedResultTtlMs = completedResultTtlMs
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    // MARK: 生命周期

    /// 启动：先恢复（recoverStale + resumeInterrupted），再启动看门狗与调度。
    @discardableResult
    public func start() async -> JobRunnerStartReport {
        guard !isStarted else {
            return JobRunnerStartReport(recoveredStale: 0, resumedInterrupted: 0)
        }
        isStarted = true
        let recovered = (try? await jobStore.recoverStale(leaseTimeoutMs: Self.leaseTimeoutMs)) ?? 0
        let resumeTypes = autoResumeTypes.sorted { $0.rawValue < $1.rawValue }
        let resumed = (try? await jobStore.resumeInterrupted(types: resumeTypes)) ?? 0
        startWatchdog()
        scheduleDrain()
        return JobRunnerStartReport(recoveredStale: recovered, resumedInterrupted: resumed)
    }

    /// 停止：abort 全部在飞作业（含取消宽限任务）后带超时等待收尾。
    public func stop() async {
        isStarted = false
        watchdog?.cancel()
        watchdog = nil
        let states = runs.values
        let tasks = Array(runTasks.values)
        for state in states {
            state.graceTask?.cancel()
            state.signal.abort()
        }
        await waitForTasks(tasks, timeoutMs: stopTimeoutMs)
    }

    public func setProgressSink(_ sink: JobProgressSink?) {
        progressSink = sink
    }

    /// 注册 executor（每个类型一个；重复注册覆盖）。autoResume 的类型在
    /// start()/注册时对 interrupted 行重新入队。
    public func registerExecutor(
        type: AnalysisJobType,
        executor: @escaping JobExecutor,
        autoResume: Bool = true
    ) async {
        executors[type] = executor
        if autoResume {
            autoResumeTypes.insert(type)
        } else {
            autoResumeTypes.remove(type)
        }
        guard isStarted, autoResume else { return }
        _ = try? await jobStore.resumeInterrupted(types: [type])
        scheduleDrain()
    }

    // MARK: 任务 API

    /// 入队（单飞）：
    /// - 未注册类型 → executorNotRegistered；
    /// - 同资源已有不同 key 的活跃作业 → busy；
    /// - 同 key 已有活跃作业 → 返回既有行（共享在飞结果）；
    /// - 否则创建新行并调度。create 一律清掉目标行的内存完成结果
    ///   （审计 7.1-4：旧实现 5 分钟内重复导出会静默返回旧结果）。
    @discardableResult
    public func create(_ params: JobCreateParams) async throws -> AnalysisJobData {
        guard executors[params.type] != nil else {
            throw JobRunnerError.executorNotRegistered(params.type)
        }
        let key = JobDedupKey.resolve(params)
        let active = try await activeJobs(for: key.resource)
        if let conflicting = active.first(where: { $0.dedupeKey != key.rawValue }) {
            throw JobRunnerError.busy(key.resource, conflicting.dedupeKey)
        }
        if let shared = active.first(where: { $0.dedupeKey == key.rawValue }) {
            return shared
        }
        var effective = params
        effective.dedupeKey = key.rawValue
        let job = try await jobStore.create(effective)
        completedResults.removeValue(forKey: job.id)
        scheduleDrain()
        return job
    }

    public func list(status: AnalysisJobStatus? = nil) async throws -> [AnalysisJobData] {
        try await jobStore.list(status: status)
    }

    /// 取消：内存取消标志先置 → DB 置 cancelling（queued 直接 cancelled）。
    /// queued 立即终态并补发终态帧；running 进入宽限期，超时强制定终态。
    @discardableResult
    public func cancel(_ id: String) async throws -> Bool {
        let current = try await jobStore.get(id)
        let state = runs[id]
        state?.signal.abort()
        let cancelled = try await jobStore.requestCancel(id)
        guard cancelled else {
            state?.graceTask?.cancel()
            return false
        }
        if let state {
            scheduleGraceTerminal(id: id, state: state)
        } else if current?.status == .queued {
            // 排队取消不经过 runInternal，补发终态帧让客户端离开「扫描中…」。
            completeResultOnce(id: id, .error(JobCancelledError()))
            await emitTerminal(id: id, status: .cancelled)
        }
        return true
    }

    @discardableResult
    public func cancelScope(type: AnalysisJobType, scopeId: String) async throws -> Int {
        var cancelledCount = 0
        for status in [AnalysisJobStatus.queued, .running, .cancelling] {
            for job in try await jobStore.list(status: status) {
                if job.type == type, job.scopeId == scopeId, try await cancel(job.id) {
                    cancelledCount += 1
                }
            }
        }
        return cancelledCount
    }

    @discardableResult
    public func retry(_ id: String) async throws -> Bool {
        let retried = try await jobStore.retry(id)
        if retried {
            completedResults.removeValue(forKey: id)
            scheduleDrain()
        }
        return retried
    }

    @discardableResult
    public func clearCompleted() async throws -> Int {
        try await jobStore.clearCompleted(excludeTypes: Self.clearCompletedStageEvidenceTypes)
    }

    // ── Store 直通（API 对齐；运行路径自持租约谓词） ──

    public func claim(id: String, leaseOwner: String) async throws -> Bool {
        try await jobStore.claim(id: id, leaseOwner: leaseOwner)
    }

    @discardableResult
    public func heartbeat(id: String, leaseOwner: String) async throws -> Bool {
        try await jobStore.heartbeat(id: id, leaseOwner: leaseOwner)
    }

    @discardableResult
    public func updateProgress(id: String, leaseOwner: String, update: JobProgressUpdate) async throws -> Bool {
        try await jobStore.updateProgress(id: id, leaseOwner: leaseOwner, update: update)
    }

    @discardableResult
    public func finish(
        id: String,
        leaseOwner: String,
        status: AnalysisJobStatus,
        error: (code: String, message: String)? = nil
    ) async throws -> Bool {
        try await jobStore.finish(id: id, leaseOwner: leaseOwner, status: status, error: error)
    }

    /// 读取最近一次落库的 checkpoint（类型安全读取入口）。
    public func checkpoint(jobId: String) async throws -> JobCheckpoint? {
        guard let job = try await jobStore.get(jobId) else { return nil }
        return JobCheckpoint(raw: job.checkpoint)
    }

    /// 测试接缝：内存中是否存在未被取走的完成结果。
    internal func hasCompletedResult(id: String) -> Bool {
        guard let entry = completedResults[id] else { return false }
        return entry.expiresAt > Self.nowMs()
    }

    /// 测试接缝：该作业已登记的等待者数量（共享在飞结果的核对点）。
    internal func waiterCount(jobId: String) -> Int {
        resultWaiters[jobId]?.count ?? 0
    }

    // MARK: 结果等待（原子 take）

    /// 等待/取走作业结果：
    /// - 内存完成结果原子 take（只成功一次）；
    /// - 已终态：succeeded → nil；failed/interrupted → jobFailed；
    ///   cancelled → JobCancelledError；
    /// - 未完成：登记等待者（完成时广播），超时返回 nil。
    public func waitForResult<T>(jobId: String, timeoutMs: Int64? = nil) async throws -> T? {
        if let completed = takeCompletedResult(jobId: jobId) {
            if let error = completed.error { throw error }
            return completed.value as? T
        }

        guard let persisted = try await jobStore.get(jobId) else {
            throw JobRunnerError.jobNotFound(jobId)
        }
        switch persisted.status {
        case .succeeded:
            return nil
        case .cancelled:
            throw JobCancelledError()
        case .failed, .interrupted:
            throw JobRunnerError.jobFailed(
                jobId,
                persisted.errorMessage.isEmpty
                    ? "Analysis job \(persisted.status.rawValue)"
                    : persisted.errorMessage)
        case .queued, .running, .cancelling:
            break
        }

        let timeout = timeoutMs ?? Self.waitForResultTimeoutMs
        let waiterId = UUID()
        let value: Any? = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any?, Error>) in
            // 同一临界区：登记等待者，若完成结果已落表则直接取回（无间隙）。
            if let completed = registerWaiterOrTakeCompleted(
                jobId: jobId, waiterId: waiterId, continuation: continuation) {
                Self.resume(completed, continuation: continuation)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeout))
                guard let self else { return }
                await self.timeoutWaiter(jobId: jobId, waiterId: waiterId)
            }
        }
        return value as? T
    }

    /// 手动执行（claim + 注册取消控制器后调用 work；claim 失败抛 notClaimable）。
    public func run<T>(
        job: AnalysisJobData,
        leaseOwner: String,
        work: (JobRunnerContext) async throws -> T
    ) async throws -> T {
        let signal = try await beginRun(job: job, requireActiveRunner: false)
        do {
            let result = try await execute(
                job: job, leaseOwner: leaseOwner, signal: signal, work: work)
            finishRun(id: job.id)
            return result
        } catch {
            finishRun(id: job.id)
            throw error
        }
    }

    // MARK: 调度

    private func scheduleDrain() {
        guard isStarted else { return }
        drainRequested = true
        guard !isDraining else { return }
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        guard isStarted, !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while isStarted {
            drainRequested = false
            let started = await drainOnce()
            if !drainRequested || !started { break }
        }
    }

    private func drainOnce() async -> Bool {
        let queued: [AnalysisJobData]
        do {
            queued = try await jobStore.list(status: .queued)
        } catch {
            return false
        }
        var started = false
        for job in queued {
            if runs.count >= maxConcurrentJobs { break }
            if runs[job.id] != nil { continue }
            guard let executor = executors[job.type] else { continue }
            do {
                let signal = try await beginRun(job: job, requireActiveRunner: true)
                runTasks[job.id] = makeRunTask(job: job, executor: executor, signal: signal)
                started = true
            } catch {
                handleClaimFailure(id: job.id, error: error)
            }
        }
        return started
    }

    private func makeRunTask(
        job: AnalysisJobData,
        executor: @escaping JobExecutor,
        signal: JobAbortSignal
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            // 重新读取行：恢复/重试后的 checkpoint 以库内最新值为准。
            let fresh = (try? await self.jobStore.get(job.id)) ?? job
            do {
                let result = try await self.execute(
                    job: fresh,
                    leaseOwner: self.leaseOwner,
                    signal: signal,
                    work: { context in try await executor(fresh, context) })
                await self.completeResultOnce(id: job.id, .value(result))
            } catch {
                await self.completeResultOnce(id: job.id, .error(error))
                if !(error is JobCancelledError) {
                    GatherLogger.log("Background job \(job.id) failed: \(error)", level: .error)
                }
            }
            await self.finishRun(id: job.id)
            await self.scheduleDrain()
        }
    }

    /// claim + 登记取消控制器；claim 失败抛 notClaimable。
    /// requireActiveRunner=true（drain 路径）时，stop 竞态下不启动新作业。
    private func beginRun(job: AnalysisJobData, requireActiveRunner: Bool) async throws -> JobAbortSignal {
        if requireActiveRunner, !isStarted {
            throw JobRunnerError.notClaimable(job.id)
        }
        guard executors[job.type] != nil else {
            throw JobRunnerError.executorNotRegistered(job.type)
        }
        guard try await jobStore.claim(id: job.id, leaseOwner: leaseOwner) else {
            throw JobRunnerError.notClaimable(job.id)
        }
        if requireActiveRunner, !isStarted {
            _ = try? await jobStore.interrupt(id: job.id, leaseOwner: leaseOwner)
            throw JobRunnerError.notClaimable(job.id)
        }
        let signal = JobAbortSignal()
        runs[job.id] = RunState(jobId: job.id, dedupeKey: job.dedupeKey, signal: signal)
        // claim 与登记之间被 requestCancel 的竞态：立即置取消标志。
        if let latest = try? await jobStore.get(job.id),
           latest.status == .cancelling || latest.status == .cancelled {
            signal.abort()
        }
        return signal
    }

    private func handleClaimFailure(id: String, error: Error) {
        completeResultOnce(id: id, .error(error))
    }

    // MARK: 执行

    private func execute<T>(
        job: AnalysisJobData,
        leaseOwner: String,
        signal: JobAbortSignal,
        work: (JobRunnerContext) async throws -> T
    ) async throws -> T {
        let interval = heartbeatIntervalMs
        let heartbeat = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
                if Task.isCancelled { break }
                if await self.performHeartbeat(id: job.id, leaseOwner: leaseOwner) == false {
                    break
                }
            }
        }
        let context = JobRunnerContext(
            signal: signal,
            jobStore: jobStore,
            job: job,
            leaseOwner: leaseOwner,
            progressWriteIntervalMs: progressWriteIntervalMs,
            progressSink: progressSink)

        do {
            let result = try await work(context)
            await context.flushProgress()
            try await context.throwIfCancelled(forceDbCheck: true)
            if runs[job.id]?.leaseLost == true {
                throw JobRunnerError.leaseLost(job.id)
            }
            heartbeat.cancel()
            guard try await jobStore.finish(
                id: job.id, leaseOwner: leaseOwner, status: .succeeded, error: nil) else {
                let latest = try? await jobStore.get(job.id)
                if latest?.status == .cancelled {
                    throw JobCancelledError()
                }
                throw JobRunnerError.leaseLost(job.id)
            }
            await emitTerminal(id: job.id, status: .succeeded)
            return result
        } catch {
            await context.flushProgress()
            heartbeat.cancel()
            if runs[job.id]?.leaseLost == true {
                // 租约已丢失：不覆写持久行（由 recoverStale 接管），等待者收到 leaseLost。
                throw JobRunnerError.leaseLost(job.id)
            }
            let cancelled = error is JobCancelledError || signal.aborted
            let latest = try? await jobStore.get(job.id)
            if let status = latest?.status,
               status == .interrupted || status == .cancelled || status == .failed || status == .succeeded {
                // 已被看门狗/取消宽限期写终态：只补终态帧，不覆写。
                await emitTerminal(id: job.id, status: status)
                throw error
            }
            let interruptedByShutdown = cancelled && !isStarted && latest?.status == .running
            if interruptedByShutdown {
                _ = try? await jobStore.interrupt(id: job.id, leaseOwner: leaseOwner)
                await emitTerminal(id: job.id, status: .interrupted)
            } else {
                let message = String(describing: error)
                let code: String
                if cancelled {
                    code = ""
                } else {
                    code = Self.isGatherErrorCode(message) ? message : "worker_error"
                }
                _ = try? await jobStore.finish(
                    id: job.id,
                    leaseOwner: leaseOwner,
                    status: cancelled ? .cancelled : .failed,
                    error: cancelled ? nil : (code, message))
                await emitTerminal(id: job.id, status: cancelled ? .cancelled : .failed)
            }
            throw error
        }
    }

    /// 心跳直通 + 失败登记：失败即 abort 该作业取消信号并标记租约丢失。
    private func performHeartbeat(id: String, leaseOwner: String) async -> Bool {
        let ok = (try? await jobStore.heartbeat(id: id, leaseOwner: leaseOwner)) ?? false
        if !ok {
            runs[id]?.leaseLost = true
            runs[id]?.signal.abort()
        }
        return ok
    }

    private func finishRun(id: String) {
        runs[id]?.graceTask?.cancel()
        runs.removeValue(forKey: id)
        runTasks.removeValue(forKey: id)
    }

    // MARK: 取消宽限

    private func scheduleGraceTerminal(id: String, state: RunState) {
        state.graceTask?.cancel()
        let grace = cancelGracePeriodMs
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(grace))
            if Task.isCancelled { return }
            await self?.forceTerminalCancellation(id: id)
        }
        runs[id]?.graceTask = task
    }

    /// 宽限期到：强制定终态、唤醒等待者、取消 Swift 任务（协作式）。
    private func forceTerminalCancellation(id: String) async {
        guard let state = runs[id] else { return }
        runs[id]?.graceTask = nil
        state.signal.abort()
        _ = try? await jobStore.finish(
            id: id, leaseOwner: leaseOwner, status: .cancelled, error: nil)
        guard (try? await jobStore.get(id))?.status == .cancelled else { return }
        completeResultOnce(id: id, .error(JobCancelledError()))
        await emitTerminal(id: id, status: .cancelled)
        runTasks[id]?.cancel()
    }

    // MARK: 看门狗

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let interval = watchdogIntervalMs
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
                if Task.isCancelled { return }
                guard let self else { return }
                _ = try? await self.jobStore.recoverStale(leaseTimeoutMs: JobRunner.leaseTimeoutMs)
                await self.revalidateLeases()
                await self.expireCompletedResultsNow()
                await self.scheduleDrain()
            }
        }
    }

    /// 租约复检：interrupted 或其他进程夺走租约 → abort 该作业取消信号。
    private func revalidateLeases() async {
        for (id, state) in runs {
            guard let latest = try? await jobStore.get(id) else { continue }
            if latest.status == .interrupted {
                state.signal.abort()
                continue
            }
            let active = latest.status == .running || latest.status == .cancelling
            if !active || (!latest.leaseOwner.isEmpty && latest.leaseOwner != leaseOwner) {
                runs[id]?.leaseLost = true
                state.signal.abort()
            }
        }
    }

    // MARK: 完成结果

    private func takeCompletedResult(jobId: String) -> CompletedResult? {
        guard let entry = completedResults[jobId] else { return nil }
        completedResults.removeValue(forKey: jobId)
        guard entry.expiresAt > Self.nowMs() else { return nil }
        return entry
    }

    /// 完成结果：无等待者 → 落表供一次性 take（首写胜出）；有等待者 →
    /// 广播给全部等待者（共享在飞结果），不再落表。
    private func completeResultOnce(id: String, _ completion: Completion) {
        if let existing = completedResults[id], existing.expiresAt > Self.nowMs() { return }
        let value: Any?
        let error: (any Error)?
        switch completion {
        case .value(let v):
            value = v
            error = nil
        case .error(let e):
            value = nil
            error = e
        }
        let waiters = resultWaiters.removeValue(forKey: id) ?? [:]
        guard waiters.isEmpty else {
            for continuation in waiters.values {
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
            return
        }
        completedResults[id] = CompletedResult(
            value: value, error: error, expiresAt: Self.nowMs() + completedResultTtlMs)
    }

    /// 同一临界区：登记等待者；若完成结果已落表则取回（不登记）。
    private func registerWaiterOrTakeCompleted(
        jobId: String,
        waiterId: UUID,
        continuation: CheckedContinuation<Any?, Error>
    ) -> CompletedResult? {
        if let completed = takeCompletedResult(jobId: jobId) {
            return completed
        }
        var waiters = resultWaiters[jobId] ?? [:]
        waiters[waiterId] = continuation
        resultWaiters[jobId] = waiters
        return nil
    }

    private func timeoutWaiter(jobId: String, waiterId: UUID) {
        guard var waiters = resultWaiters[jobId], let continuation = waiters.removeValue(forKey: waiterId) else {
            return
        }
        if waiters.isEmpty {
            resultWaiters.removeValue(forKey: jobId)
        } else {
            resultWaiters[jobId] = waiters
        }
        continuation.resume(returning: nil)
    }

    private static func resume(_ completed: CompletedResult, continuation: CheckedContinuation<Any?, Error>) {
        if let error = completed.error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: completed.value)
        }
    }

    private func expireCompletedResultsNow() {
        let now = Self.nowMs()
        completedResults = completedResults.filter { $0.value.expiresAt > now }
    }

    // MARK: 进度帧

    private func emitTerminal(id: String, status: AnalysisJobStatus) async {
        guard let latest = try? await jobStore.get(id) else { return }
        progressSink?(latest, JobProgressUpdate(current: 1, total: 1, message: status.rawValue))
    }

    // MARK: 辅助

    private func activeJobs(for resource: JobResource) async throws -> [AnalysisJobData] {
        try await jobStore.listByType(resource.type).filter {
            $0.scopeType == resource.scopeType
                && $0.scopeId == resource.scopeId
                && ($0.status == .queued || $0.status == .running || $0.status == .cancelling)
        }
    }

    private func waitForTasks(_ tasks: [Task<Void, Never>], timeoutMs: Int64) async {
        guard !tasks.isEmpty else { return }
        let flag = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                for task in tasks {
                    await task.value
                }
                if await flag.tryFire() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if await flag.tryFire() { continuation.resume() }
            }
        }
    }

    private static func isGatherErrorCode(_ message: String) -> Bool {
        GatherErrorCode.allCases.contains { $0.rawValue == message }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - 运行上下文

/// 单次作业运行的上下文（actor：进度节流/取消检查状态隔离）。
/// executor 经 signal 观察取消；checkpoint 读写走类型安全编解码。
public actor JobRunnerContext {
    /// 取消信号（TS AbortSignal 等价物；abort → executor 协作退出）。
    public nonisolated let signal: JobAbortSignal
    public nonisolated let jobId: String
    public nonisolated let leaseOwner: String
    /// 运行开始时的 checkpoint 快照（崩溃恢复后可读到上次落库值）。
    public nonisolated let initialCheckpoint: JobCheckpoint

    private let jobStore: any JobStore
    private let progressSink: JobRunner.JobProgressSink?
    private let progressWriteIntervalMs: Int64
    private var checkpoint: JobCheckpoint
    private var pendingProgress: JobProgressUpdate?
    private var lastProgressWriteAt: Int64 = 0
    private var cancelCheckCalls = 0
    private var lastCancelDbCheckAt: Int64 = 0
    private let cancelCheckEvery = JobRunner.cancelDbCheckEvery
    private let cancelCheckIntervalMs = JobRunner.cancelDbCheckIntervalMs

    init(
        signal: JobAbortSignal,
        jobStore: any JobStore,
        job: AnalysisJobData,
        leaseOwner: String,
        progressWriteIntervalMs: Int64,
        progressSink: JobRunner.JobProgressSink?
    ) {
        self.signal = signal
        self.jobStore = jobStore
        self.jobId = job.id
        self.leaseOwner = leaseOwner
        self.initialCheckpoint = JobCheckpoint(raw: job.checkpoint)
        self.checkpoint = self.initialCheckpoint
        self.progressWriteIntervalMs = progressWriteIntervalMs
        self.progressSink = progressSink
    }

    /// 进度上报：窗口内合并；current >= total 视为完成立即落库。
    public func updateProgress(_ update: JobProgressUpdate) async {
        let now = Self.nowMs()
        let merged = Self.merge(pendingProgress ?? JobProgressUpdate(), update)
        pendingProgress = merged
        let completed = update.current != nil && update.total != nil
            && (update.total ?? 0) > 0 && (update.current ?? 0) >= (update.total ?? 0)
        if completed || now - lastProgressWriteAt >= progressWriteIntervalMs {
            await flushProgress()
        }
    }

    /// checkpoint 落库（覆盖语义：旧 JobService.updateCheckpoint 对齐）：先 flush
    /// 旧进度，替换 checkpoint，再 flush（更新落库 + 进度帧）。
    public func updateCheckpoint(_ value: JobCheckpoint) async {
        await flushProgress()
        checkpoint = value
        pendingProgress = JobProgressUpdate(checkpoint: value.raw)
        await flushProgress()
    }

    /// 旧签名便捷版（[String: JSONValue]）。
    public func updateCheckpoint(_ raw: [String: JSONValue]) async {
        await updateCheckpoint(JobCheckpoint(raw))
    }

    /// 合并语义：patch 覆盖同键旧值，其余保留（增量 checkpoint 用）。
    public func mergeCheckpoint(_ patch: JobCheckpoint) async {
        await updateCheckpoint(checkpoint.merging(patch))
    }

    /// 类型安全写入单个键并立即落库。
    public func setCheckpointValue<T: Encodable>(_ value: T, forKey key: String) async throws {
        var next = checkpoint
        try next.encode(value, forKey: key)
        await updateCheckpoint(next)
    }

    /// 类型安全读取单个键（缺键 nil，类型不符抛 DecodingError）。
    public func checkpointValue<T: Decodable>(_ type: T.Type = T.self, forKey key: String) throws -> T? {
        try checkpoint.decode(type, forKey: key)
    }

    /// 当前内存 checkpoint（含未落库的中间态）。
    public func currentCheckpoint() -> JobCheckpoint {
        checkpoint
    }

    /// 从库内重新加载 checkpoint（恢复/外部更新后读取）。
    @discardableResult
    public func loadCheckpoint() async throws -> JobCheckpoint {
        guard let job = try await jobStore.get(jobId) else { return checkpoint }
        let loaded = JobCheckpoint(raw: job.checkpoint)
        checkpoint = loaded
        return loaded
    }

    /// 取消检查：信号同步检查 + DB 状态节流复核（每 50 次或 500ms）。
    /// cancelling/cancelled/interrupted 均视为取消（interrupted 为 fencing 终态）。
    public func throwIfCancelled(forceDbCheck: Bool = false) async throws {
        if signal.aborted { throw JobCancelledError() }
        let now = Self.nowMs()
        cancelCheckCalls += 1
        let due = forceDbCheck
            || cancelCheckCalls % cancelCheckEvery == 0
            || now - lastCancelDbCheckAt >= cancelCheckIntervalMs
        if !due { return }
        lastCancelDbCheckAt = now
        if let latest = try? await jobStore.get(jobId) {
            if latest.status == .cancelling || latest.status == .cancelled || latest.status == .interrupted {
                throw JobCancelledError()
            }
        }
    }

    /// 收尾 flush（成功/失败路径调用点对齐旧实现）。
    public func flushProgress() async {
        guard let update = pendingProgress else { return }
        pendingProgress = nil
        lastProgressWriteAt = Self.nowMs()
        let ok = (try? await jobStore.updateProgress(
            id: jobId, leaseOwner: leaseOwner, update: update)) ?? false
        if !ok { signal.abort() }
        if let latest = try? await jobStore.get(jobId) {
            progressSink?(latest, update)
        }
    }

    private static func merge(_ base: JobProgressUpdate, _ update: JobProgressUpdate) -> JobProgressUpdate {
        JobProgressUpdate(
            current: update.current ?? base.current,
            total: update.total ?? base.total,
            phase: update.phase ?? base.phase,
            message: update.message ?? base.message,
            checkpoint: update.checkpoint ?? base.checkpoint)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
