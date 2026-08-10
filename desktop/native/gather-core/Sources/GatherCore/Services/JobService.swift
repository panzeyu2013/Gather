// desktop/native/gather-core/Sources/GatherCore/Services/JobService.swift
// TS 源: desktop/src/main/services/jobs/job.service.ts（重写）
// 分析任务服务：租约执行、进度节流、心跳看门狗、取消传播、结果等待。
// 并发模型：class + NSLock（TS 为单线程事件循环，Swift 以锁保护共享状态）；
// 取消为协作式（executor 经 throwIfCancelled/signal 检查），与 TS AbortSignal
// 语义一致；心跳与超时用 Task.sleep 循环（对齐 setInterval 语义）。
import Foundation

public struct JobCancelledError: Error, Equatable {
    public init() {}
}

/// 取消信号（TS AbortSignal 的等价物）。
public final class JobAbortSignal {
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

    func addHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if _aborted {
            handler()
        } else {
            handlers.append(handler)
        }
    }
}

/// 任务执行上下文（TS JobRunContext）。
public final class JobRunContext {
    public let signal: JobAbortSignal

    private let lock = NSLock()
    private var pendingProgress: JobProgressUpdate?
    private var lastProgressWriteAt: Int64 = 0
    private var cancelCheckCalls = 0
    private var lastCancelDbCheckAt: Int64 = 0
    private let cancelCheckEvery = 50
    private let cancelCheckIntervalMs: Int64 = 500
    private let progressWriteIntervalMs: Int64 = 250

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

    /// 进度上报：250ms 节流合并；current >= total 视为完成立即落库。
    public func updateProgress(_ update: JobProgressUpdate) {
        let now = Self.nowMs()
        lock.lock()
        let merged = merge(pendingProgress ?? JobProgressUpdate(), update)
        pendingProgress = merged
        let completed =
            update.current != nil && update.total != nil &&
            update.total! > 0 && update.current! >= update.total!
        let shouldFlush = completed || now - lastProgressWriteAt >= progressWriteIntervalMs
        lock.unlock()
        if shouldFlush {
            flushProgress()
        }
    }

    /// checkpoint 落库：先 flush 旧进度，写 checkpoint，再 flush（TS 语义）。
    public func updateCheckpoint(_ checkpoint: [String: JSONValue]) {
        flushProgress()
        lock.lock()
        pendingProgress = JobProgressUpdate(checkpoint: checkpoint)
        lock.unlock()
        flushProgress()
    }

    /// 取消检查：信号同步检查 + DB 'cancelling' 状态节流检查（每 50 次或 500ms）。
    public func throwIfCancelled(forceDbCheck: Bool = false) throws {
        if signal.aborted { throw JobCancelledError() }
        let now = Self.nowMs()
        lock.lock()
        cancelCheckCalls += 1
        let due = forceDbCheck ||
            cancelCheckCalls % cancelCheckEvery == 0 ||
            now - lastCancelDbCheckAt >= cancelCheckIntervalMs
        lock.unlock()
        if !due { return }
        lock.lock()
        lastCancelDbCheckAt = now
        lock.unlock()
        if let latest = try? repo.get(jobId),
           latest.status == .cancelling || latest.status == .cancelled {
            throw JobCancelledError()
        }
    }

    /// runInternal 成功/失败路径的收尾 flush（对齐 TS context.flushProgress 调用点）。
    func flushProgress() {
        flushProgressInternal()
    }

    private func flushProgressInternal() {
        lock.lock()
        guard let update = pendingProgress else {
            lock.unlock()
            return
        }
        pendingProgress = nil
        lastProgressWriteAt = Self.nowMs()
        let jobId = self.jobId
        let leaseOwner = self.leaseOwner
        lock.unlock()
        let ok = (try? updateProgress(jobId, leaseOwner, update)) ?? false
        if !ok { signal.abort() }
        if let latest = try? repo.get(jobId) {
            progressSink?(latest, update)
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

/// 结果等待者（class 包装，按身份比较，替代无 Equatable 的 continuation）。
private final class Waiter: @unchecked Sendable {
    let continuation: CheckedContinuation<Any?, Error>

    init(_ continuation: CheckedContinuation<Any?, Error>) {
        self.continuation = continuation
    }
}

public final class JobService {
    public typealias JobExecutor = (AnalysisJobData, JobRunContext) async throws -> Any?
    public typealias JobProgressSink = (AnalysisJobData, JobProgressUpdate) -> Void

    public static let maxConcurrentJobs = 2
    public static let progressWriteIntervalMs: Int64 = 250
    public static let waitForResultTimeoutMs: Int64 = 60 * 60_000
    public static let cancelDbCheckEvery = 50
    public static let cancelDbCheckIntervalMs: Int64 = 500
    public static let completedResultTtlMs: Int64 = 5 * 60_000
    public static let heartbeatIntervalMs: Int64 = 5_000
    public static let watchdogIntervalMs: Int64 = 5_000
    /// 终态行同时是 workspace 阶段证据（workspace-status latestScanJob /
    /// hasSuccessfulExport），clearCompleted 排除，避免「清理已完成」把
    /// 已索引/已导出的工作区退回 imported（job.service.ts:33-41 注释）。
    public static let clearCompletedStageEvidenceTypes: [AnalysisJobType] = [.metadataScan, .exportExecute]

    private let lock = NSLock()
    private let repo: AnalysisJobRepo
    public let leaseOwner: String
    /// 心跳间隔（默认 5000 对齐 TS；测试可注入短间隔）。
    public let heartbeatIntervalMs: Int64

    private var executors: [AnalysisJobType: JobExecutor] = [:]
    private var autoResumeTypes: Set<AnalysisJobType> = []
    private var controllers: [String: JobAbortSignal] = [:]
    private var activeRuns: [String: Task<Void, Never>] = [:]
    private var resultWaiters: [String: [Waiter]] = [:]
    private var completedResults: [String: CompletedResult] = [:]
    private var watchdog: Task<Void, Never>?
    private var drainScheduled = false
    private var isDraining = false
    private var stopped = true
    private var progressSink: JobProgressSink?

    public init(repo: AnalysisJobRepo, heartbeatIntervalMs: Int64 = JobService.heartbeatIntervalMs) {
        self.repo = repo
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.leaseOwner = "main-\(ProcessInfo.processInfo.processIdentifier)"
    }

    public func setProgressSink(_ sink: JobProgressSink?) {
        lock.lock()
        progressSink = sink
        lock.unlock()
    }

    // ── 生命周期 ──

    public func start() {
        lock.lock()
        guard stopped else {
            lock.unlock()
            return
        }
        stopped = false
        lock.unlock()
        try? repo.recoverStale()
        _ = try? repo.resumeInterrupted(types: autoResumeTypes.sorted { $0.rawValue < $1.rawValue })
        scheduleDrain()
        lock.lock()
        guard watchdog == nil else {
            lock.unlock()
            return
        }
        let watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(JobService.watchdogIntervalMs))
                guard let self else { break }
                try? self.repo.recoverStale()
                self.scheduleDrain()
            }
        }
        watchdog = watchdogTask
        lock.unlock()
    }

    public func stop() async {
        takeDownControllers()
        let runs = snapshotActiveRuns()
        for run in runs {
            await run.value
        }
    }

    /// 置 stopped、取消看门狗与全部控制器（同步辅助，供 async 上下文调用）。
    private func takeDownControllers() {
        lock.lock()
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        let controllers = self.controllers.values
        self.controllers.removeAll()
        lock.unlock()
        controllers.forEach { $0.abort() }
    }

    private func snapshotActiveRuns() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeRuns.values)
    }

    public func registerExecutor(
        type: AnalysisJobType,
        executor: @escaping JobExecutor,
        autoResume: Bool = true
    ) {
        lock.lock()
        executors[type] = executor
        if autoResume {
            autoResumeTypes.insert(type)
        } else {
            autoResumeTypes.remove(type)
        }
        let running = !stopped
        let shouldResume = running && autoResumeTypes.contains(type)
        lock.unlock()
        if shouldResume {
            _ = try? repo.resumeInterrupted(types: [type])
        }
        if running {
            scheduleDrain()
        }
    }

    // ── 任务 API（直通 repo）──

    @discardableResult
    public func create(_ params: JobCreateParams) throws -> AnalysisJobData {
        let job = try repo.create(params)
        scheduleDrain()
        return job
    }

    public func list(status: AnalysisJobStatus? = nil) throws -> [AnalysisJobData] {
        try repo.list(status: status)
    }

    @discardableResult
    public func cancel(_ id: String) throws -> Bool {
        let wasQueued = try repo.get(id)?.status == .queued
        let cancelled = try repo.requestCancel(id)
        if cancelled {
            controller(for: id)?.abort()
            if wasQueued {
                // queued 取消不经过 runInternal，不会产生终态进度帧；补发
                // 以让依赖 jobs:progress 的客户端离开「扫描中…」（TS 注释）。
                completeResult(id: id, completed: .error(JobCancelledError()))
                emitTerminal(id: id, status: .cancelled)
            }
        }
        return cancelled
    }

    @discardableResult
    public func cancelScope(type: AnalysisJobType, scopeId: String) throws -> Int {
        var cancelledCount = 0
        for job in try repo.list() {
            if job.type == type && job.scopeId == scopeId &&
               [.queued, .running, .cancelling].contains(job.status),
               try cancel(job.id) {
                cancelledCount += 1
            }
        }
        return cancelledCount
    }

    @discardableResult
    public func retry(_ id: String) throws -> Bool {
        let retried = try repo.retry(id)
        if retried {
            lock.lock()
            completedResults.removeValue(forKey: id)
            lock.unlock()
            scheduleDrain()
        }
        return retried
    }

    @discardableResult
    public func clearCompleted() throws -> Int {
        try repo.clearCompleted(excludeTypes: JobService.clearCompletedStageEvidenceTypes)
    }

    public func claim(id: String, leaseOwner: String) throws -> Bool {
        try repo.claim(id: id, leaseOwner: leaseOwner)
    }

    @discardableResult
    public func heartbeat(id: String, leaseOwner: String) throws -> Bool {
        try repo.heartbeat(id: id, leaseOwner: leaseOwner)
    }

    @discardableResult
    public func updateProgress(id: String, leaseOwner: String, update: JobProgressUpdate) throws -> Bool {
        try repo.updateProgress(id: id, leaseOwner: leaseOwner, update: update)
    }

    @discardableResult
    public func finish(id: String, leaseOwner: String, status: AnalysisJobStatus, error: (code: String, message: String)? = nil) throws -> Bool {
        try repo.finish(id: id, leaseOwner: leaseOwner, status: status, error: error)
    }

    // ── 结果等待 ──

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
            throw JobServiceError.jobFailed(jobId, persisted.errorMessage.isEmpty ? "Analysis job \(persisted.status.rawValue)" : persisted.errorMessage)
        }

        let timeout = timeoutMs ?? JobService.waitForResultTimeoutMs
        let result: Any? = try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            appendWaiter(jobId: jobId, waiter: waiter)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeout))
                guard let self else { return }
                let removed = self.removeWaiter(jobId: jobId, waiter: waiter)
                if removed {
                    continuation.resume(throwing: JobServiceError.waitForResultTimeout(jobId))
                }
            }
        }
        return result as? T
    }

    private func takeCompletedResult(jobId: String) -> CompletedResult? {
        lock.lock()
        defer { lock.unlock() }
        return completedResults[jobId]
    }

    private func appendWaiter(jobId: String, waiter: Waiter) {
        lock.lock()
        var waiters = resultWaiters[jobId] ?? []
        waiters.append(waiter)
        resultWaiters[jobId] = waiters
        lock.unlock()
    }

    // ── 执行 ──

    public func run<T>(
        job: AnalysisJobData,
        leaseOwner: String,
        work: (JobRunContext) async throws -> T
    ) async throws -> T {
        // 同步前缀（claim + controller 注册）——与 TS 语义一致：JS 的 async
        // 函数在首个 await 前同步执行，drain 的并发上限依赖 controller 立即注册。
        let controller = try beginRun(job: job, leaseOwner: leaseOwner)
        return try await execute(job: job, leaseOwner: leaseOwner, controller: controller, work: work)
    }

    /// 同步执行 run 的前缀：claim 租约 + 注册取消控制器。
    /// claim 失败抛 notClaimable（调用方决定是否继续调度）。
    private func beginRun(job: AnalysisJobData, leaseOwner: String) throws -> JobAbortSignal {
        guard try claim(id: job.id, leaseOwner: leaseOwner) else {
            throw JobServiceError.notClaimable(job.id)
        }
        let controller = JobAbortSignal()
        setController(jobId: job.id, controller: controller)
        return controller
    }

    private func execute<T>(
        job: AnalysisJobData,
        leaseOwner: String,
        controller: JobAbortSignal,
        work: (JobRunContext) async throws -> T
    ) async throws -> T {
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(self?.heartbeatIntervalMs ?? JobService.heartbeatIntervalMs))
                guard let self else { break }
                let ok = (try? self.heartbeat(id: job.id, leaseOwner: leaseOwner)) ?? false
                if !ok {
                    controller.abort()
                    break
                }
            }
        }

        let context = JobRunContext(
            signal: controller,
            repo: repo,
            jobId: job.id,
            leaseOwner: leaseOwner,
            updateProgress: { id, owner, update in
                try self.updateProgress(id: id, leaseOwner: owner, update: update)
            },
            progressSink: { job, update in
                self.emitProgress(job: job, update: update)
            })

        do {
            let result = try await work(context)
            context.flushProgress()
            try context.throwIfCancelled(forceDbCheck: true)
            guard try finish(id: job.id, leaseOwner: leaseOwner, status: .succeeded) else {
                throw JobServiceError.leaseLost(job.id)
            }
            emitTerminal(id: job.id, status: .succeeded)
            heartbeat.cancel()
            removeController(jobId: job.id)
            return result
        } catch {
            context.flushProgress()
            heartbeat.cancel()
            removeController(jobId: job.id)
            let cancelled = error is JobCancelledError || controller.aborted
            let latest = try? repo.get(job.id)
            let interruptedByShutdown = cancelled && isStopped && latest?.status == .running
            if interruptedByShutdown {
                _ = try? repo.interrupt(id: job.id, leaseOwner: leaseOwner)
                emitTerminal(id: job.id, status: .interrupted)
            } else {
                let message = String(describing: error)
                let code: String
                if cancelled {
                    code = ""
                } else {
                    code = Self.isGatherErrorCode(message) ? message : "worker_error"
                }
                _ = try? finish(
                    id: job.id, leaseOwner: leaseOwner,
                    status: cancelled ? .cancelled : .failed,
                    error: cancelled ? nil : (code, message))
                emitTerminal(id: job.id, status: cancelled ? .cancelled : .failed)
            }
            throw error
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// 同步辅助：注册/移除运行中任务的取消控制器。
    private func setController(jobId: String, controller: JobAbortSignal) {
        lock.lock()
        controllers[jobId] = controller
        lock.unlock()
    }

    private func removeController(jobId: String) {
        lock.lock()
        controllers.removeValue(forKey: jobId)
        lock.unlock()
    }

    private func controllerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return controllers.count
    }

    private func controller(for id: String) -> JobAbortSignal? {
        lock.lock()
        defer { lock.unlock() }
        return controllers[id]
    }

    private func drainSnapshot(jobId: String, type: AnalysisJobType) -> (atCapacity: Bool, alreadyRunning: Bool, executor: JobExecutor?) {
        lock.lock()
        defer { lock.unlock() }
        return (
            atCapacity: controllers.count >= JobService.maxConcurrentJobs,
            alreadyRunning: controllers[jobId] != nil,
            executor: executors[type]
        )
    }

    private func emitProgress(job: AnalysisJobData, update: JobProgressUpdate) {
        lock.lock()
        let sink = progressSink
        lock.unlock()
        sink?(job, update)
    }

    /// 推送终态进度帧：恢复期客户端依赖事件而非轮询（TS 注释 234-248）。
    private func emitTerminal(id: String, status: AnalysisJobStatus) {
        guard let latest = try? repo.get(id) else { return }
        emitProgress(job: latest, update: JobProgressUpdate(current: 1, total: 1, message: status.rawValue))
    }

    // ── 调度 ──

    private func scheduleDrain() {
        lock.lock()
        if stopped || drainScheduled {
            lock.unlock()
            return
        }
        drainScheduled = true
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.drain()
            } catch {
                // repo.list 可抛（如关机时 DB 关闭）；fire-and-forget 调用方
                // 不应产生未处理错误（TS 注释 368-374 语义）。
                print("Background job drain failed: \(error)")
            }
            // 在 drain 完成（而非 Task 启动）后清除：多个 drain Task 并发会
            // 交错 beginRun，导致并发上限（controllers 计数）失效。
            self.clearDrainScheduled()
        }
    }

    private func clearDrainScheduled() {
        lock.lock()
        drainScheduled = false
        lock.unlock()
    }

    private func drain() async throws {
        lock.lock()
        if stopped || isDraining {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()
        defer {
            lock.lock()
            isDraining = false
            lock.unlock()
        }

        let queued: [AnalysisJobData]
        do {
            queued = try repo.list(status: .queued)
        } catch {
            return
        }

        for job in queued {
            let snapshot = drainSnapshot(jobId: job.id, type: job.type)
            if snapshot.atCapacity { break }
            if snapshot.alreadyRunning { continue }
            guard let executor = snapshot.executor else { continue }

            // 同步前缀：claim + controller 注册立即生效，并发上限精确。
            let controller: JobAbortSignal
            do {
                controller = try beginRun(job: job, leaseOwner: leaseOwner)
            } catch {
                // claim 失败（跨进程竞态等）按 TS drain 的 catch 路径分发结果。
                completeResult(id: job.id, completed: .error(error))
                continue
            }

            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.execute(
                        job: job,
                        leaseOwner: self.leaseOwner,
                        controller: controller,
                        work: { context in
                            try await executor(job, context)
                        })
                    self.completeResult(id: job.id, completed: .value(result))
                } catch {
                    let hasResult = self.hasCompletedResult(id: job.id)
                    if !hasResult {
                        self.completeResult(id: job.id, completed: .error(error))
                    }
                    if !(error is JobCancelledError) {
                        print("Background job \(job.id) failed: \(error)")
                    }
                }
                self.removeActiveRun(id: job.id)
                self.scheduleDrain()
            }
            recordActiveRun(id: job.id, task: task)
        }
    }

    private func recordActiveRun(id: String, task: Task<Void, Never>) {
        lock.lock()
        activeRuns[id] = task
        lock.unlock()
    }

    private func hasCompletedResult(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completedResults[id] != nil
    }

    private func removeActiveRun(id: String) {
        lock.lock()
        activeRuns.removeValue(forKey: id)
        lock.unlock()
    }

    private func completeResult(id: String, completed: Completion) {
        let value: Any?
        let error: Error?
        switch completed {
        case .value(let v):
            value = v
            error = nil
        case .error(let e):
            value = nil
            error = e
        }
        let expiry = Self.nowMs() + JobService.completedResultTtlMs
        lock.lock()
        completedResults[id] = CompletedResult(
            value: value, error: error, expiresAt: expiry)
        let waiters = resultWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        for waiter in waiters {
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume(returning: value)
            }
        }
        // 5 分钟过期删除（TS timer.unref 语义）。
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

    private static func isGatherErrorCode(_ message: String) -> Bool {
        GatherErrorCode.allCases.contains { $0.rawValue == message }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public enum JobServiceError: Error, Equatable {
    case jobNotFound(String)
    case jobFailed(String, String)
    case waitForResultTimeout(String)
    case notClaimable(String)
    case leaseLost(String)
}

/// 完成结果（value 或 error 二选一）。
private enum Completion {
    case value(Any?)
    case error(Error)
}
