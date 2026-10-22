// desktop/native/gather-core/Sources/GatherDomain/Services/JobService.swift
// 后台任务唯一执行器：入队、准入、心跳、取消宽限、恢复、终态收尾全部在这里定义。
// 旧 JobScheduler（第二套 weight 调度）与 AnalysisWorker（未被生产引用的包装）已删除，
// 其预算准入语义并入本文件的 weightBudget 调度。
//
// ── 状态机（迁移只发生在 AnalysisJobRepo；本文件是唯一驱动者）──
//   queued     --claim-->            running
//   queued     --cancel-->           cancelled（不需要执行器参与）
//   running    --cancel-->           cancelling --执行器收尾/宽限兜底--> cancelled
//   running    --work throw-->       failed（真实错误码+消息）
//   running    --work ok-->          succeeded
//   running    --停机兜底/stale-->   interrupted（可恢复类型由看门狗自动 requeue）
//   interrupted/failed/cancelled --retry--> queued（checkpoint 保留=续跑）
//
// ── 三条关键语义 ──
// 1) 心跳：SQL 抛错（瞬时 BUSY 等）≠ 租约丢失。抛错只累计并重试，读回确认租约
//    仍属本进程就继续 running；只有 heartbeat 返回 0 行（对端已迁移/回收/删除）
//    才中止执行，且不再由本执行器改写对端状态（interrupted 由 recoverStale 负责）。
// 2) 取消：queued 直接终态；running 转 cancelling 并 abort signal，同时挂宽限定时器
//    （cancelGraceMs），即使执行器无视取消，宽限到点也由本执行器以租约收尾为
//    cancelled —— cancelling 永远不会是终点。
// 3) 恢复：看门狗周期性 recoverStale 后，对已注册且允许自动恢复的类型调用
//    resumeInterrupted(maxAttempts:)，超过尝试上限的行保持 interrupted 等用户重试；
//    明确的不恢复集合见 nonAutoResumableTypes。
import Foundation
import GatherPersistence
import GatherProtocol

/// 执行器观察到的取消（协作式，与 TS AbortSignal 语义一致）。
public struct JobCancelledError: Error, Equatable {
    public init() {}
}

/// 取消信号（TS AbortSignal 的等价物）。
/// 线程安全说明（Swift 6 `Sendable`）：可变状态 `_aborted`/`handlers` 只在
/// `lock`（NSLock）临界区内读写（abort 在锁外回调 handler，避免反向取锁死锁）。
/// 锁纪律无法被编译器静态验证，故标注 `@unchecked`。
public final class JobAbortSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _aborted = false
    private var handlers: [() -> Void] = []

    public var aborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _aborted
    }

    func abort() {
        lock.lock()
        guard !_aborted else {
            lock.unlock()
            return
        }
        _aborted = true
        let handlers = self.handlers
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// TS AbortSignal.addEventListener：已 abort 时锁外立即回调（避免反向取锁死锁）。
    public func addHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        if _aborted {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

/// 任务执行上下文（TS JobRunContext）。
/// 线程安全说明（Swift 6 `Sendable`）：可变状态 `pendingProgress`/
/// `lastProgressWriteAt`/`cancelCheckCalls`/`lastCancelDbCheckAt` 只在 `lock`（NSLock）
/// 临界区内读写；其余存储属性构造后不可变。锁纪律无法被编译器静态验证，
/// 故标注 `@unchecked`（与同仓 MetadataSyncCoordinator 的既有约定一致）。
public final class JobRunContext: @unchecked Sendable {
    public let signal: JobAbortSignal

    private let lock = NSLock()
    private var pendingProgress: JobProgressUpdate?
    private var lastProgressWriteAt: Int64 = 0
    private var cancelCheckCalls = 0
    private var lastCancelDbCheckAt: Int64 = 0
    private let cancelCheckEvery = JobService.cancelDbCheckEvery
    private let cancelCheckIntervalMs = JobService.cancelDbCheckIntervalMs
    private let progressWriteIntervalMs = JobService.progressWriteIntervalMs

    private let repo: AnalysisJobRepo
    private let jobId: String
    private let leaseOwner: String
    private let updateProgress: (String, String, JobProgressUpdate) throws -> Bool
    private let progressSink: ((AnalysisJobData, JobProgressUpdate) -> Void)?

    init(
        signal: JobAbortSignal,
        repo: AnalysisJobRepo,
        jobId: String,
        leaseOwner: String,
        updateProgress: @escaping (String, String, JobProgressUpdate) throws -> Bool,
        progressSink: ((AnalysisJobData, JobProgressUpdate) -> Void)?
    ) {
        self.signal = signal
        self.repo = repo
        self.jobId = jobId
        self.leaseOwner = leaseOwner
        self.updateProgress = updateProgress
        self.progressSink = progressSink
    }

    /// 进度上报：250ms 节流合并；current >= total（total > 0）视为完成立即 flush。
    public func updateProgress(_ update: JobProgressUpdate) {
        let now = Self.nowMs()
        lock.lock()
        let merged = merge(pendingProgress ?? JobProgressUpdate(), update)
        pendingProgress = merged
        let completed: Bool
        if let current = update.current, let total = update.total, total > 0 {
            completed = current >= total
        } else {
            completed = false
        }
        let shouldFlush = completed || now - lastProgressWriteAt >= progressWriteIntervalMs
        lock.unlock()
        if shouldFlush { flushProgress() }
    }

    /// checkpoint 落库：先 flush 旧进度，写 checkpoint，再 flush。
    public func updateCheckpoint(_ checkpoint: [String: JSONValue]) {
        flushProgress()
        lock.lock()
        pendingProgress = JobProgressUpdate(checkpoint: checkpoint)
        lock.unlock()
        flushProgress()
    }

    /// 取消检查：信号同步检查 + DB 'cancelling'/'cancelled' 节流检查。
    /// DB 读取失败（瞬时错误）不判定取消。
    public func throwIfCancelled(forceDbCheck: Bool = false) throws {
        if signal.aborted { throw JobCancelledError() }
        let now = Self.nowMs()
        lock.lock()
        cancelCheckCalls += 1
        let due = forceDbCheck ||
            cancelCheckCalls % cancelCheckEvery == 0 ||
            now - lastCancelDbCheckAt >= cancelCheckIntervalMs
        if due { lastCancelDbCheckAt = now }
        lock.unlock()
        if !due { return }
        if let latest = try? repo.get(jobId),
           latest.status == .cancelling || latest.status == .cancelled {
            throw JobCancelledError()
        }
    }

    /// 写进度；收尾由 JobService 调用。
    /// - 抛错：保留 pending，等下一次 flush 重试（瞬时 DB 错误不是取消）。
    /// - 返回 false（0 行）：租约已丢失，abort 执行并丢弃 pending。
    func flushProgress() {
        lock.lock()
        guard let update = pendingProgress else {
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            let ok = try updateProgress(jobId, leaseOwner, update)
            if !ok {
                lock.lock()
                pendingProgress = nil
                lock.unlock()
                signal.abort()
                return
            }
            lock.lock()
            if pendingProgress == update { pendingProgress = nil }
            lastProgressWriteAt = Self.nowMs()
            lock.unlock()
            if let latest = try? repo.get(jobId) {
                progressSink?(latest, update)
            }
        } catch {
            return
        }
    }

    private func merge(_ base: JobProgressUpdate, _ update: JobProgressUpdate) -> JobProgressUpdate {
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

/// 已完成结果记录（5 分钟过期，对应 TS completedResults）。
private struct CompletedResult {
    let value: Any?
    let error: Error?
    let expiresAt: Int64
}

/// 完成结果的值盒子。`Any?` 本身不是 Sendable，无法直接作为 continuation 的
/// `sending` 载荷（Swift 6 region isolation）。盒子构造时写入、此后只读
/// （唯一存储是 `let value`，无锁、无写者）；载荷的生命周期由 JobService.lock
/// 串行化（CompletedResult 只在锁内登记/取出）。故标注 `@unchecked`——
/// 这里承诺的是「不可变载体 + 既有锁纪律」，不是新增锁。
private struct JobResultValue: @unchecked Sendable {
    let value: Any?
}

/// 结果等待者（class 包装，按身份比较，替代无 Equatable 的 continuation）。
private final class Waiter: @unchecked Sendable {
    let continuation: CheckedContinuation<JobResultValue, Error>

    init(_ continuation: CheckedContinuation<JobResultValue, Error>) {
        self.continuation = continuation
    }
}

/// 单一后台任务执行器。
/// 线程安全说明（Swift 6 `Sendable`）：全部可变状态（`executors`/`activeRuns`/
/// `controllers`/`resultWaiters`/`completedResults`/`cancelGraceTasks`/`watchdog`/
/// `stopped`/`pumping`/`pumpRequested`/`progressSink`）只在 `lock`（NSLock）临界区内
/// 读写；其余存储属性构造后不可变。锁纪律无法被编译器静态验证，故标注
/// `@unchecked`（与同仓 MetadataSyncCoordinator/BatchCursor 一致）。
public final class JobService: @unchecked Sendable {
    public typealias JobExecutor = (AnalysisJobData, JobRunContext) async throws -> Any?
    public typealias JobProgressSink = (AnalysisJobData, JobProgressUpdate) -> Void

    // 时间与容量常量
    public static let progressWriteIntervalMs: Int64 = 250
    public static let waitForResultTimeoutMs: Int64 = 60 * 60_000
    public static let cancelDbCheckEvery = 50
    public static let cancelDbCheckIntervalMs: Int64 = 500
    public static let completedResultTtlMs: Int64 = 5 * 60_000
    public static let heartbeatIntervalMs: Int64 = 5_000
    public static let watchdogIntervalMs: Int64 = 5_000
    /// 心跳超时：超过该时长无心跳的行由 recoverStale 回收。
    public static let leaseTimeoutMs: Int64 = 30_000
    /// 取消宽限期：cancelling 行最迟在此时间后被强制收尾为 cancelled。
    public static let cancelGraceMs: Int64 = 15_000
    /// stop() 等待执行器自然退出的上限，超时后强制迁移未终态行。
    public static let stopTimeoutMs: Int64 = 10_000
    /// 自动恢复的尝试上限：超过后保持 interrupted，等用户显式重试。
    public static let maxAutoResumeAttempts = 3
    /// 明确的不自动恢复集合：缩略图预热是纯缓存任务，崩溃/停机后按需重建更省资源。
    public static let nonAutoResumableTypes: Set<AnalysisJobType> = [.thumbnailBuild]
    /// 终态行同时是 workspace 阶段证据（latestScanJob / hasSuccessfulExport），
    /// 清理默认排除它们。
    public static let stageEvidenceTypes: [AnalysisJobType] = [.metadataScan, .exportExecute]
    /// 准入预算：进程级 weight 预算（替代旧 JobScheduler 的共享预算与旧 maxConcurrentJobs=2）。
    public static let defaultWeightBudget: Int = max(2, min(6, ProcessInfo.processInfo.processorCount - 1))

    /// 类型默认 weight（重计算任务吃 2 个单位，I/O 与短任务吃 1）。
    public static func defaultWeight(for type: AnalysisJobType) -> Int {
        switch type {
        case .faceAnalyze, .similarityAnalyze, .duplicateScan:
            return 2
        case .metadataScan, .qualityScore, .exportExecute, .thumbnailBuild, .checksumBackfill:
            return 1
        }
    }

    /// 执行器注册项。`JobExecutor` 闭包类型未标 `@Sendable`（公开 API，注册点
    /// 含跨包调用方，本轮不动其签名）；本结构全部为 `let`，注册后不再变更，
    /// 且按契约执行器本就由 JobService 在后台任务里调用。故标注 `@unchecked`。
    private struct Registration: @unchecked Sendable {
        let executor: JobExecutor
        let weight: Int
        let autoResume: Bool
    }

    private struct ActiveRun {
        let controller: JobAbortSignal
        var task: Task<Void, Never>?
        let weight: Int
    }

    private let lock = NSLock()
    private let repo: AnalysisJobRepo
    public let leaseOwner: String
    /// 心跳间隔（默认 5000 对齐 TS；测试可注入短间隔）。
    public let heartbeatIntervalMs: Int64
    private let weightBudget: Int
    private let leaseTimeoutMs: Int64
    private let cancelGraceMs: Int64
    private let stopTimeoutMs: Int64
    private let maxAutoResumeAttempts: Int

    private var executors: [AnalysisJobType: Registration] = [:]
    private var activeRuns: [String: ActiveRun] = [:]
    private var controllers: [String: JobAbortSignal] = [:]
    private var resultWaiters: [String: [Waiter]] = [:]
    private var completedResults: [String: CompletedResult] = [:]
    private var cancelGraceTasks: [String: Task<Void, Never>] = [:]
    private var watchdog: Task<Void, Never>?
    private var stopped = true
    private var pumping = false
    private var pumpRequested = false
    private var progressSink: JobProgressSink?

    public init(
        repo: AnalysisJobRepo,
        heartbeatIntervalMs: Int64 = JobService.heartbeatIntervalMs,
        weightBudget: Int = JobService.defaultWeightBudget,
        leaseTimeoutMs: Int64 = JobService.leaseTimeoutMs,
        cancelGraceMs: Int64 = JobService.cancelGraceMs,
        stopTimeoutMs: Int64 = JobService.stopTimeoutMs,
        maxAutoResumeAttempts: Int = JobService.maxAutoResumeAttempts
    ) {
        self.repo = repo
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.weightBudget = max(1, weightBudget)
        self.leaseTimeoutMs = leaseTimeoutMs
        self.cancelGraceMs = cancelGraceMs
        self.stopTimeoutMs = stopTimeoutMs
        self.maxAutoResumeAttempts = max(1, maxAutoResumeAttempts)
        self.leaseOwner = "main-\(ProcessInfo.processInfo.processIdentifier)"
    }

    public func setProgressSink(_ sink: JobProgressSink?) {
        lock.lock()
        progressSink = sink
        lock.unlock()
    }

    // MARK: - 生命周期

    public func start() {
        lock.lock()
        guard stopped else {
            lock.unlock()
            return
        }
        stopped = false
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(JobService.watchdogIntervalMs))
                if Task.isCancelled { break }
                guard let self else { break }
                self.recoverAndResume()
            }
        }
        watchdog = task
        lock.unlock()
        recoverAndResume()
    }

    /// 停机：停止调度与看门狗、abort 全部执行器，限时等待自然退出，
    /// 超时后把仍由本租约持有的行强制迁移（cancelling→cancelled，running→interrupted）。
    public func stop() async {
        let handoff = beginStopLocked()
        handoff.graceTasks.forEach { $0.cancel() }
        handoff.controllers.forEach { $0.abort() }

        let deadline = Date().addingTimeInterval(Double(stopTimeoutMs) / 1000)
        while Date() < deadline {
            if activeRunCountLocked() == 0 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        forceFinalizeAbandoned()
    }

    /// stop() 首段临界区的产物（多值判定 → 私有 struct，同 ScanSlotDecision）。
    private struct StopHandoff {
        let graceTasks: [Task<Void, Never>]
        let controllers: [JobAbortSignal]
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func beginStopLocked() -> StopHandoff {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        let graceTasks = Array(cancelGraceTasks.values)
        cancelGraceTasks.removeAll()
        let controllers = Array(self.controllers.values)
        return StopHandoff(graceTasks: graceTasks, controllers: controllers)
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func activeRunCountLocked() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeRuns.count
    }

    /// 看门狗：回收 stale 租约 → 按类型策略自动恢复 interrupted → 驱动队列。
    private func recoverAndResume() {
        _ = try? repo.recoverStale(leaseTimeoutMs: Int(leaseTimeoutMs))
        resumeInterruptedForRegisteredTypes()
        pump()
    }

    private func resumeInterruptedForRegisteredTypes() {
        lock.lock()
        let running = !stopped
        let types = executors
            .filter { $0.value.autoResume && !JobService.nonAutoResumableTypes.contains($0.key) }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
        let cap = maxAutoResumeAttempts
        lock.unlock()
        guard running, !types.isEmpty else { return }
        _ = try? repo.resumeInterrupted(types: types, maxAttempts: cap)
    }

    // MARK: - 执行器注册

    /// 注册唯一执行器。
    /// - Parameters:
    ///   - weight: 准入预算单位（nil = 类型默认值，见 defaultWeight(for:)）。
    ///   - autoResume: 是否允许 interrupted 自动恢复；nonAutoResumableTypes 始终覆盖为 false。
    public func registerExecutor(
        type: AnalysisJobType,
        weight: Int? = nil,
        autoResume: Bool = true,
        executor: @escaping JobExecutor
    ) {
        let effectiveAutoResume = autoResume && !JobService.nonAutoResumableTypes.contains(type)
        lock.lock()
        executors[type] = Registration(
            executor: executor,
            weight: max(1, weight ?? JobService.defaultWeight(for: type)),
            autoResume: effectiveAutoResume)
        let running = !stopped
        lock.unlock()
        if running {
            resumeInterruptedForRegisteredTypes()
            pump()
        }
    }

    // MARK: - 任务 API

    @discardableResult
    /// 最近一次同 dedupeKey 终态任务的 checkpoint（只读）。
    /// 导出预览用它复用与执行一致的续跑基线（见 AnalysisJobRepo.latestTerminalCheckpoint）。
    public func latestTerminalCheckpoint(dedupeKey: String) throws -> [String: JSONValue]? {
        try repo.latestTerminalCheckpoint(dedupeKey: dedupeKey)
    }

    public func create(_ params: JobCreateParams) throws -> AnalysisJobData {
        let job = try repo.create(params)
        pump()
        return job
    }

    public func list(status: AnalysisJobStatus? = nil, includeCheckpoint: Bool = true) throws -> [AnalysisJobData] {
        try repo.list(status: status, includeCheckpoint: includeCheckpoint)
    }

    /// 取消：返回是否受理。queued 直接终态并补发终态帧；running 转 cancelling
    /// 并挂宽限定时器；cancelling 幂等重放；终态/不存在返回 false。
    @discardableResult
    public func cancel(_ id: String) throws -> Bool {
        switch try repo.requestCancel(id) {
        case .cancelledQueued:
            completeResult(id: id, error: JobCancelledError())
            emitTerminal(id: id)
            clearGraceTask(id: id)
            pump()
            return true
        case .cancellationRequested:
            controller(for: id)?.abort()
            scheduleCancelGrace(id: id)
            return true
        case .alreadyCancelling:
            scheduleCancelGrace(id: id)
            return true
        case .notCancellable:
            return false
        }
    }

    /// 按 scope 批量取消（幂等）。
    @discardableResult
    public func cancelScope(type: AnalysisJobType, scopeId: String) throws -> Int {
        var cancelledCount = 0
        for job in try repo.list() {
            if job.type == type && job.scopeId == scopeId &&
               activeAnalysisJobStatuses.contains(job.status),
               try cancel(job.id) {
                cancelledCount += 1
            }
        }
        return cancelledCount
    }

    /// 重试：仅 failed/interrupted/cancelled → queued（checkpoint 保留=续跑）。
    @discardableResult
    public func retry(_ id: String) throws -> Bool {
        let retried = try repo.retry(id)
        if retried {
            lock.lock()
            completedResults.removeValue(forKey: id)
            lock.unlock()
            pump()
        }
        return retried
    }

    /// 清理终态行：默认只清成功终态并保护阶段证据；失败/中断/取消行及其错误
    /// 原因只有调用方显式点名 statuses 时才会被删除。
    @discardableResult
    public func clearCompleted(
        statuses: [AnalysisJobStatus] = [.succeeded],
        excludeTypes: [AnalysisJobType] = JobService.stageEvidenceTypes
    ) throws -> Int {
        try repo.clearTerminal(statuses: statuses, excludeTypes: excludeTypes)
    }

    // MARK: - 结果等待

    /// 等待任务结果。succeeded 且内存结果已过期时返回 nil（持久行是权威记录）。
    public func waitForResult<T>(jobId: String, timeoutMs: Int64? = nil) async throws -> T? {
        if let completed = takeCompletedResult(jobId: jobId) {
            if let error = completed.error { throw error }
            return completed.value as? T
        }

        guard let persisted = try repo.get(jobId) else {
            throw JobServiceError.jobNotFound(jobId)
        }
        if persisted.status == .succeeded {
            return nil
        }
        if [.failed, .interrupted, .cancelled].contains(persisted.status) {
            if persisted.status == .cancelled {
                throw JobCancelledError()
            }
            throw JobServiceError.jobFailed(
                jobId,
                persisted.errorMessage.isEmpty ? "Analysis job \(persisted.status.rawValue)" : persisted.errorMessage)
        }

        let timeout = timeoutMs ?? JobService.waitForResultTimeoutMs
        let result: JobResultValue = try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            // 「检查已完成结果」与「注册 waiter」同一临界区，避免完成竞态挂死。
            if let completed = registerWaiterOrTakeCompletedResult(jobId: jobId, waiter: waiter) {
                if let error = completed.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: JobResultValue(value: completed.value))
                }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeout))
                guard let self else { return }
                let removed = self.removeWaiter(jobId: jobId, waiter: waiter)
                if removed {
                    continuation.resume(throwing: JobServiceError.waitForResultTimeout(jobId))
                }
            }
        }
        return result.value as? T
    }

    private func takeCompletedResult(jobId: String) -> CompletedResult? {
        lock.lock()
        defer { lock.unlock() }
        return completedResults[jobId]
    }

    private func registerWaiterOrTakeCompletedResult(jobId: String, waiter: Waiter) -> CompletedResult? {
        lock.lock()
        if let completed = completedResults[jobId] {
            lock.unlock()
            return completed
        }
        var waiters = resultWaiters[jobId] ?? []
        waiters.append(waiter)
        resultWaiters[jobId] = waiters
        lock.unlock()
        return nil
    }

    private func removeWaiter(jobId: String, waiter: Waiter) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var waiters = resultWaiters[jobId] ?? []
        if let index = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: index)
            if waiters.isEmpty {
                resultWaiters.removeValue(forKey: jobId)
            } else {
                resultWaiters[jobId] = waiters
            }
            return true
        }
        return false
    }

    // MARK: - 调度（唯一准入控制）

    private func pump() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        pumpRequested = true
        if pumping {
            lock.unlock()
            return
        }
        pumping = true
        lock.unlock()
        Task { [weak self] in
            await self?.pumpLoop()
        }
    }

    /// pumpLoop 每轮的锁内判定（多值判定 → 私有 enum，同 ScanSlotDecision）。
    private enum PumpLoopStep {
        /// 已停机：复位 pumping/pumpRequested 后退出。
        case stop
        /// 有待处理请求：复位 pumpRequested 后继续下一轮。
        case continueLoop
        /// 无待处理请求：复位 pumping 后退出。
        case idle
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func pumpLoopStepLocked() -> PumpLoopStep {
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            pumping = false
            pumpRequested = false
            return .stop
        }
        if pumpRequested {
            pumpRequested = false
            return .continueLoop
        }
        pumping = false
        return .idle
    }

    private func pumpLoop() async {
        while true {
            startEligibleJobs()
            switch pumpLoopStepLocked() {
            case .stop:
                return
            case .continueLoop:
                continue
            case .idle:
                return
            }
        }
    }

    /// 队列顺序 = repo 的唯一口径（priority ASC, updated_at ASC, rowid ASC）；
    /// 逐个按 weight 预算准入，claim 失败（跨进程竞争）直接跳过。
    private func startEligibleJobs() {
        let queued: [AnalysisJobData]
        do {
            queued = try repo.list(status: .queued)
        } catch {
            return
        }
        for job in queued {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            guard let registration = executors[job.type], activeRuns[job.id] == nil else {
                lock.unlock()
                continue
            }
            let used = activeRuns.values.reduce(0) { $0 + $1.weight }
            guard used + registration.weight <= weightBudget else {
                lock.unlock()
                continue
            }
            let controller = JobAbortSignal()
            activeRuns[job.id] = ActiveRun(controller: controller, task: nil, weight: registration.weight)
            lock.unlock()

            let claimed: Bool
            do {
                claimed = try repo.claim(id: job.id, leaseOwner: leaseOwner)
            } catch {
                removeActiveRun(id: job.id)
                continue
            }
            guard claimed else {
                removeActiveRun(id: job.id)
                continue
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.runClaimedJob(job: job, registration: registration, controller: controller)
            }
            lock.lock()
            controllers[job.id] = controller
            if var run = activeRuns[job.id] {
                run.task = task
                activeRuns[job.id] = run
            } else {
                // 执行任务已先一步收尾并移除记录：取消刚创建的任务，避免悬挂。
                task.cancel()
            }
            lock.unlock()
        }
    }

    private func removeActiveRun(id: String) {
        lock.lock()
        activeRuns.removeValue(forKey: id)
        controllers.removeValue(forKey: id)
        lock.unlock()
    }

    private func clearGraceTask(id: String) {
        lock.lock()
        let task = cancelGraceTasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    private func controller(for id: String) -> JobAbortSignal? {
        lock.lock()
        defer { lock.unlock() }
        return controllers[id]
    }

    // MARK: - 执行

    private func runClaimedJob(job: AnalysisJobData, registration: Registration, controller: JobAbortSignal) async {
        let context = JobRunContext(
            signal: controller,
            repo: repo,
            jobId: job.id,
            leaseOwner: leaseOwner,
            updateProgress: { [weak self] id, owner, update in
                guard let self else { return false }
                return try self.repo.updateProgress(id: id, leaseOwner: owner, update: update)
            },
            progressSink: { [weak self] job, update in
                self?.emitProgress(job: job, update: update)
            })

        let heartbeat = Task { [weak self] in
            await self?.heartbeatLoop(job: job, controller: controller, context: context)
        }

        var outcome: Result<Any?, Error>
        do {
            let value = try await registration.executor(job, context)
            context.flushProgress()
            // 成功路径也要尊重取消：用户已取消时按 cancelled 收尾，不写 succeeded。
            do {
                try context.throwIfCancelled(forceDbCheck: true)
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
        } catch {
            context.flushProgress()
            outcome = .failure(error)
        }
        heartbeat.cancel()
        settle(job: job, outcome: outcome, controller: controller)
        removeActiveRun(id: job.id)
        clearGraceTask(id: job.id)
        pump()
    }

    /// 心跳循环：0 行 = 租约丢失（中止）；SQL 抛错 = 重试并保持 running。
    private func heartbeatLoop(job: AnalysisJobData, controller: JobAbortSignal, context: JobRunContext) async {
        var consecutiveErrors = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(heartbeatIntervalMs))
            if Task.isCancelled || controller.aborted { return }
            context.flushProgress()
            do {
                let ok = try repo.heartbeat(id: job.id, leaseOwner: leaseOwner)
                consecutiveErrors = 0
                if !ok {
                    // 0 行：行已被对端迁移（回收/取消/删除）或租约被夺；
                    // 本执行器放弃，不再改写对端状态。
                    controller.abort()
                    return
                }
            } catch {
                consecutiveErrors += 1
                guard consecutiveErrors >= 3 else { continue }
                if let row = try? repo.get(job.id),
                   row.leaseOwner == leaseOwner,
                   activeAnalysisJobStatuses.contains(row.status) {
                    // 读回确认租约仍属本进程：瞬时 DB 错误，继续 running。
                    consecutiveErrors = 0
                }
                // 读回也失败：不 abort（SQL 错误 ≠ 用户取消），继续重试心跳。
            }
        }
    }

    /// 终态收尾：先写库（原子条件 UPDATE），成功才登记结果并广播真实终态帧。
    private func settle(job: AnalysisJobData, outcome: Result<Any?, Error>, controller: JobAbortSignal) {
        let value: Any?
        let error: Error?
        switch outcome {
        case .success(let result):
            value = result
            error = nil
        case .failure(let resultError):
            value = nil
            error = resultError
        }
        var cancelled = controller.aborted
        if let error, error is JobCancelledError { cancelled = true }
        let stoppedNow = isStopped

        if let error, !cancelled {
            let message = String(describing: error)
            let code = Self.gatherErrorCode(from: message) ?? "worker_error"
            if (try? repo.finish(id: job.id, leaseOwner: leaseOwner, status: .failed, error: (code, message))) == true {
                completeResult(id: job.id, error: error)
                emitTerminal(id: job.id)
            } else {
                finishMiss(id: job.id)
            }
            return
        }

        if cancelled {
            // 应用停机导致的取消不是用户取消 → interrupted，供下次启动恢复。
            if stoppedNow,
               (try? repo.interrupt(id: job.id, leaseOwner: leaseOwner)) == true {
                completeResult(id: job.id, error: JobServiceError.jobFailed(job.id, "Application stopped during execution"))
                emitTerminal(id: job.id)
                return
            }
            if (try? repo.finish(id: job.id, leaseOwner: leaseOwner, status: .cancelled)) == true {
                completeResult(id: job.id, error: JobCancelledError())
                emitTerminal(id: job.id)
            } else {
                finishMiss(id: job.id)
            }
            return
        }

        if (try? repo.finish(id: job.id, leaseOwner: leaseOwner, status: .succeeded)) == true {
            completeResult(id: job.id, value: value)
            emitTerminal(id: job.id)
        } else {
            finishMiss(id: job.id)
        }
    }

    /// 条件 UPDATE 未命中：行已不由本租约持有（对端已迁移/删除）。
    /// 只登记等待者结果（first-wins，不覆盖已有终态），不广播终态帧。
    private func finishMiss(id: String) {
        completeResult(id: id, error: JobServiceError.leaseLost(id))
    }

    /// settle 用（无参函数，避免与同名属性歧义）。
    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - 取消宽限

    /// 挂取消宽限定时器：到时仍为 cancelling（本租约）则强制收尾为 cancelled，
    /// 保证 cancelling 永远能离开；执行器稍后自然退出时结果 first-wins 不覆盖。
    private func scheduleCancelGrace(id: String) {
        lock.lock()
        cancelGraceTasks[id]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(self.cancelGraceMs))
            if Task.isCancelled { return }
            self.forceCancel(id: id)
        }
        cancelGraceTasks[id] = task
        lock.unlock()
    }

    private func forceCancel(id: String) {
        guard let row = try? repo.get(id),
              row.status == .cancelling,
              row.leaseOwner == leaseOwner else { return }
        if (try? repo.finish(id: id, leaseOwner: leaseOwner, status: .cancelled)) == true {
            completeResult(id: id, error: JobCancelledError())
            emitTerminal(id: id)
        }
        clearGraceTask(id: id)
    }

    /// 停机超时兜底：按行真实状态迁移（cancelling→cancelled，running→interrupted）。
    private func forceFinalizeAbandoned() {
        lock.lock()
        let ids = Array(activeRuns.keys)
        lock.unlock()
        for id in ids {
            guard let row = try? repo.get(id),
                  row.leaseOwner == leaseOwner,
                  activeAnalysisJobStatuses.contains(row.status) else { continue }
            if row.status == .cancelling {
                if (try? repo.finish(id: id, leaseOwner: leaseOwner, status: .cancelled)) == true {
                    completeResult(id: id, error: JobCancelledError())
                    emitTerminal(id: id)
                }
            } else if row.status == .running {
                if (try? repo.interrupt(id: id, leaseOwner: leaseOwner)) == true {
                    completeResult(id: id, error: JobServiceError.jobFailed(id, "Application stopped during execution"))
                    emitTerminal(id: id)
                }
            }
        }
    }

    // MARK: - 结果与事件

    private func completeResult(id: String, value: Any?) {
        registerResult(id: id, value: value, error: nil)
    }

    private func completeResult(id: String, error: Error) {
        registerResult(id: id, value: nil, error: error)
    }

    /// first-wins：已登记的终态结果不被迟到者覆盖（取消宽限 vs 执行器自然退出）。
    private func registerResult(id: String, value: Any?, error: Error?) {
        let expiry = Self.nowMs() + JobService.completedResultTtlMs
        lock.lock()
        if completedResults[id] != nil {
            lock.unlock()
            return
        }
        completedResults[id] = CompletedResult(value: value, error: error, expiresAt: expiry)
        let waiters = resultWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        for waiter in waiters {
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume(returning: JobResultValue(value: value))
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(JobService.completedResultTtlMs))
            guard let self else { return }
            self.expireCompletedResultIfDue(id: id)
        }
    }

    private func expireCompletedResultIfDue(id: String) {
        lock.lock()
        defer { lock.unlock() }
        if let entry = completedResults[id], entry.expiresAt <= Self.nowMs() {
            completedResults.removeValue(forKey: id)
        }
    }

    private func emitProgress(job: AnalysisJobData, update: JobProgressUpdate) {
        lock.lock()
        let sink = progressSink
        lock.unlock()
        sink?(job, update)
    }

    /// 终态帧：payload 与进度必须来自持久行的真实执行结果（不再用期望状态拼 1/1）。
    private func emitTerminal(id: String) {
        guard let latest = try? repo.get(id) else { return }
        let message: String?
        if !latest.errorMessage.isEmpty {
            message = latest.errorMessage
        } else if !latest.progressMessage.isEmpty {
            message = latest.progressMessage
        } else {
            message = nil
        }
        emitProgress(job: latest, update: JobProgressUpdate(
            current: latest.progressCurrent,
            total: latest.progressTotal,
            phase: latest.progressMessage.isEmpty ? nil : latest.progressMessage,
            message: message,
            checkpoint: latest.checkpoint))
    }

    private static func gatherErrorCode(from message: String) -> String? {
        GatherErrorCode.allCases.first { $0.rawValue == message }?.rawValue
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public enum JobServiceError: Error, Equatable {
    case jobNotFound(String)
    case jobFailed(String, String)
    case waitForResultTimeout(String)
    case leaseLost(String)
}
