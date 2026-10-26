// desktop/native/gather-core/Sources/GatherApplication/Services/JobService.swift
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

    private let repo: any JobRepository
    private let jobId: String
    private let leaseOwner: String
    private let updateProgress: (String, String, JobProgressUpdate) throws -> Bool
    private let progressSink: ((AnalysisJobData, JobProgressUpdate) -> Void)?

    init(
        signal: JobAbortSignal,
        repo: any JobRepository,
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
struct CompletedResult {
    let value: Any?
    let error: Error?
    let expiresAt: Int64
}

/// 完成结果的值盒子。`Any?` 本身不是 Sendable，无法直接作为 continuation 的
/// `sending` 载荷（Swift 6 region isolation）。盒子构造时写入、此后只读
/// （唯一存储是 `let value`，无锁、无写者）；载荷的生命周期由 JobService.lock
/// 串行化（CompletedResult 只在锁内登记/取出）。故标注 `@unchecked`——
/// 这里承诺的是「不可变载体 + 既有锁纪律」，不是新增锁。
struct JobResultValue: @unchecked Sendable {
    let value: Any?
}

/// 结果等待者（class 包装，按身份比较，替代无 Equatable 的 continuation）。
final class Waiter: @unchecked Sendable {
    let continuation: CheckedContinuation<JobResultValue, Error>

    init(_ continuation: CheckedContinuation<JobResultValue, Error>) {
        self.continuation = continuation
    }
}

/// 单一后台任务执行器。
/// 线程安全说明（Swift 6 `Sendable`）：全部可变状态（`executors`/`activeRuns`/
/// `runStartedAtMs`/`controllers`/`resultWaiters`/`completedResults`/
/// `cancelGraceTasks`/`watchdog`/`stopped`/`pumping`/`pumpRequested`/
/// `progressSink`）只在 `lock`（NSLock）临界区内读写；其余存储属性构造后不可变。
/// 锁纪律无法被编译器静态验证，故标注 `@unchecked`（与同仓
/// MetadataSyncCoordinator/BatchCursor 一致）。
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
    struct Registration: @unchecked Sendable {
        let executor: JobExecutor
        let weight: Int
        let autoResume: Bool
    }

    struct ActiveRun {
        let controller: JobAbortSignal
        var task: Task<Void, Never>?
        let weight: Int
    }

    let lock = NSLock()
    let repo: any JobRepository
    public let leaseOwner: String
    /// 心跳间隔（默认 5000 对齐 TS；测试可注入短间隔）。
    public let heartbeatIntervalMs: Int64
    let weightBudget: Int
    let leaseTimeoutMs: Int64
    let cancelGraceMs: Int64
    let stopTimeoutMs: Int64
    let maxAutoResumeAttempts: Int

    var executors: [AnalysisJobType: Registration] = [:]
    var activeRuns: [String: ActiveRun] = [:]
    /// 本次 run 的起点（epoch ms，claim 成功时登记；run 收尾时清除）。
    /// 终态日志用它计算 duration_ms；queued 取消没有 run，记 0。
    var runStartedAtMs: [String: Int64] = [:]
    var controllers: [String: JobAbortSignal] = [:]
    var resultWaiters: [String: [Waiter]] = [:]
    var completedResults: [String: CompletedResult] = [:]
    var cancelGraceTasks: [String: Task<Void, Never>] = [:]
    var watchdog: Task<Void, Never>?
    var stopped = true
    var pumping = false
    var pumpRequested = false
    var progressSink: JobProgressSink?

    public init(
        repo: any JobRepository,
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
            // WP7b：queued 取消不经过执行器，仍是终态（trace 可看到未启动就结束）。
            Self.logJob(
                id,
                "event=terminal phase=terminal status=cancelled "
                    + "\(runDurationField(id: id)) reason=queued-cancel",
                level: .info)
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
        // 复审 P2：只取 (type, scope) 活跃行的 id，不再全表加载（含 checkpoint）。
        for id in try repo.activeJobIDs(type: type, scopeId: scopeId) where try cancel(id) {
            cancelledCount += 1
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

    private func controller(for id: String) -> JobAbortSignal? {
        lock.lock()
        defer { lock.unlock() }
        return controllers[id]
    }

    /// WP7b：job 侧关联标识（日志专用，不参与业务判定）。约定 `job:<id>`。
    /// GatherLogger.log 不抛错：日志失败不会改变返回值、错误或业务时序。
    static func logJob(_ jobId: String, _ fields: String, level: LogLevel) {
        GatherLogger.log("trace=job:\(jobId) \(fields)", level: level)
    }

    /// claim 成功：登记本次 run 的起点。只影响终态日志的 duration_ms，
    /// 不参与调度、租约或状态机判定。
    func beginRun(id: String) {
        let startedAt = Self.nowMs()
        lock.lock()
        runStartedAtMs[id] = startedAt
        lock.unlock()
    }

    /// 终态日志的 duration 字段；无 run（queued 取消）记 duration_ms=0。
    /// 锁只包住起点读取，墙钟差值在锁外计算。
    func runDurationField(id: String) -> String {
        lock.lock()
        let startedAt = runStartedAtMs[id]
        lock.unlock()
        guard let startedAt else { return "duration_ms=0" }
        return "duration_ms=\(max(0, Self.nowMs() - startedAt))"
    }

    static func gatherErrorCode(from message: String) -> String? {
        // 兼容 "CODE: detail" / "CODE" 两种历史落库文本；完整等值优先。
        let head = message.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? message
        return GatherErrorCode.allCases.first { $0.rawValue == message }?.rawValue
            ?? GatherErrorCode.allCases.first { $0.rawValue == head }?.rawValue
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - 错误

public enum JobServiceError: Error, Equatable {
    case jobNotFound(String)
    case jobFailed(String, String)
    case waitForResultTimeout(String)
    case leaseLost(String)
}
