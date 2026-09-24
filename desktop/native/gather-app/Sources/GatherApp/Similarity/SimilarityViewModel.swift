// desktop/native/gather-app/Sources/GatherApp/Similarity/SimilarityViewModel.swift
// Phase 3.3 Similarity（相似度分析）：视图模型（服务可注入，同进程直连路由）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析流程/
//       阈值档切换/预设/KeywordWritebackPanel）+ stores/similarityStore.ts（阈值/
//       组大小/分组模式/isAnalyzing 草稿语义）+ api/similarity.ts（sim.* 命令形状）
//       + utils/c1-sync-controls.ts（三按钮状态机门控，2.3.5 P1）
//
// 差异说明（有意）：
// - TS 的 jobs:progress 推送 → 分析期间轮询 jobs.list（1s，测试可注入），
//   进度相位经 progressPhaseLabel 映射中文（progress.* 键值）；
// - 挂载恢复（重启后残留 running 任务）经轮询首帧识别并续传进度；
// - 关键词写回面板复用 sim.preview_writeback/sim.writeback 的预览、确认、
//   C1 reload ack 和失败重试链，选择集合仍对齐 onResultAdopted 清空语义；
// - TS 的「重新加载并确认」拆成两步（loadMetadata → confirmSync），按钮可用性
//   经 c1-sync-controls.ts 的 deriveSyncControls 移植实现；
// - 同步状态视图（TS captureOneApi.syncState）无现成路由命令，改经
//   sim.writeback_items 统计模块 outbox 行推导；reload ack（sessions.reload_acked_at）
//   路由侧不可读，以本地标记近似（reloadMetadata 成功置位、新写回活动复位，
//   与 DB clearReloadAck 语义一致），服务端 requireReloadAck 仍兜底。
import Foundation
import GatherCore

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态/时序门）或
/// 真实路由（LiveSimilarityDataProvider + 临时 SQLite）。
public protocol SimilarityDataProvider {
    /// TS: similarityApi.getResult → sim.result（threshold 缺省 = 最近档）。
    func getResult(sessionId: String, threshold: Int?) async throws -> SimilarityResult?
    /// TS: similarityApi.analyze → sim.analyze（JobService 异步，完成即成功）。
    func analyze(
        sessionId: String,
        threshold: Int?,
        minGroupSize: Int?,
        groupingMode: SimilarityGroupingMode
    ) async throws
    /// TS: similarityApi.cancel → sim.cancel_analysis。
    func cancelAnalysis(sessionId: String) async throws -> Bool
    /// TS: similarityApi.recluster → sim.recluster（同步返回新结果）。
    func recluster(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode
    ) async throws -> SimilarityResult
    /// 分析进度轮询（TS jobsApi.list 过滤 similarity.analyze + scopeId）。
    func listSimilarityJobs(sessionId: String) async throws -> [AnalysisJobData]
    func previewWriteback(sessionId: String, assignments: [SimilarityKeywordAssignment], threshold: Int?) async throws -> WritebackPreview
    func writeback(sessionId: String, itemIds: [Int], threshold: Int?) async throws -> WritebackResult
    func retryFailedWriteback(sessionId: String) async throws -> WritebackResult
    func confirmSync(sessionId: String) async throws
    func cleanupWriteback(sessionId: String) async throws -> CleanupResult
}

extension SimilarityDataProvider {
    /// TS: captureOneApi.syncState 的模块级数据源 —— 相似度模块 outbox 行
    /// （sim.writeback_items，每行 xmpStatus）。默认实现返回空（测试 stub；
    /// 同步状态仅 Live 侧有意义）。
    public func syncStateItems(sessionId: String) throws -> [WritebackItem] { [] }
}

/// 真实实现：同进程直连 SessionCommandRouter（sim.* 已接线命令以路由为
/// 唯一事实源，保证相似度占用/取消跨页一致）。
public final class LiveSimilarityDataProvider: SimilarityDataProvider {
    private let router: SessionCommandRouter

    public init(router: SessionCommandRouter) {
        self.router = router
    }

    public func getResult(sessionId: String, threshold: Int?) async throws -> SimilarityResult? {
        // sim.result 已迁入异步路由（结果读经 SimilarityStore）。
        let response: GatherCore.JSONValue = try await withCheckedThrowingContinuation { continuation in
            router.executeAsync("sim.result", params: [
                "sessionId": .string(sessionId),
                "threshold": threshold.map { .number(Double($0)) } ?? .null,
            ]) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_RESULT_FAILED"))
                    return
                }
                continuation.resume(returning: data)
            }
        }
        if response == .null { return nil }
        return try response.decoded(as: SimilarityResult.self)
    }

    public func analyze(
        sessionId: String,
        threshold: Int?,
        minGroupSize: Int?,
        groupingMode: SimilarityGroupingMode
    ) async throws {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "groupingMode": .string(groupingMode.rawValue),
        ]
        if let threshold { params["threshold"] = .number(Double(threshold)) }
        if let minGroupSize { params["minGroupSize"] = .number(Double(minGroupSize)) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            router.executeAsync("sim.analyze", params: params) { response in
                if response.ok {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_ANALYZE_FAILED"))
                }
            }
        }
    }

    public func cancelAnalysis(sessionId: String) async throws -> Bool {
        let response = try router.execute("sim.cancel_analysis", params: ["sessionId": .string(sessionId)])
        return response.boolValue ?? false
    }

    public func recluster(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode
    ) async throws -> SimilarityResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SimilarityResult, Error>) in
            router.executeAsync("sim.recluster", params: [
                "sessionId": .string(sessionId),
                "threshold": .number(Double(threshold)),
                "minGroupSize": .number(Double(minGroupSize)),
                "groupingMode": .string(groupingMode.rawValue),
            ]) { response in
                if response.ok, let data = response.data {
                    do {
                        continuation.resume(returning: try data.decoded(as: SimilarityResult.self))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_RECLUSTER_FAILED"))
                }
            }
        }
    }

    public func listSimilarityJobs(sessionId: String) async throws -> [AnalysisJobData] {
        try await router.jobRunner.list().filter {
            $0.type == .similarityAnalyze && $0.scopeType == "session" && $0.scopeId == sessionId
        }
    }

    public func previewWriteback(sessionId: String, assignments: [SimilarityKeywordAssignment], threshold: Int?) async throws -> WritebackPreview {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "assignments": try .array(assignments.map { try JSONValue(from: $0) }),
        ]
        if let threshold { params["threshold"] = .number(Double(threshold)) }
        // 经 executeAsync：sim.preview_writeback 在同步 execute 中的 awaitSync
        // 信号量桥会阻塞 @MainActor 调用线程（XMP/DB I/O 期间 UI 冻结）。
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WritebackPreview, Error>) in
            router.executeAsync("sim.preview_writeback", params: params) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_PREVIEW_WRITEBACK_FAILED"))
                    return
                }
                do { continuation.resume(returning: try data.decoded(as: WritebackPreview.self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func writeback(sessionId: String, itemIds: [Int], threshold: Int?) async throws -> WritebackResult {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "itemIds": .array(itemIds.map { .number(Double($0)) }),
            "confirmed": .bool(true),
        ]
        if let threshold { params["threshold"] = .number(Double(threshold)) }
        return try await withCheckedThrowingContinuation { continuation in
            router.executeAsync("sim.writeback", params: params) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_WRITEBACK_FAILED"))
                    return
                }
                do { continuation.resume(returning: try data.decoded(as: WritebackResult.self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func retryFailedWriteback(sessionId: String) async throws -> WritebackResult {
        try await withCheckedThrowingContinuation { continuation in
            router.executeAsync("sim.retry_failed_writeback", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ]) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_RETRY_WRITEBACK_FAILED"))
                    return
                }
                do { continuation.resume(returning: try data.decoded(as: WritebackResult.self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func confirmSync(sessionId: String) async throws {
        // 经 executeAsync：同步 execute 的 awaitSync 桥会阻塞 @MainActor 调用线程。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            router.executeAsync("sim.confirm_sync", params: ["sessionId": .string(sessionId)]) { response in
                if response.ok {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_CONFIRM_SYNC_FAILED"))
                }
            }
        }
    }

    public func cleanupWriteback(sessionId: String) async throws -> CleanupResult {
        try await withCheckedThrowingContinuation { continuation in
            router.executeAsync("sim.cleanup", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ]) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "SIM_CLEANUP_FAILED"))
                    return
                }
                do { continuation.resume(returning: try data.decoded(as: CleanupResult.self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 同步状态数据源：sim.writeback_items（模块 outbox 行，xmpStatus 计数）。
    public func syncStateItems(sessionId: String) throws -> [WritebackItem] {
        try router.execute("sim.writeback_items", params: ["sessionId": .string(sessionId)])
            .decoded(as: [WritebackItem].self)
    }
}

/// 同步状态视图（TS C1SyncStateView 的模块级近似：state + written 计数）。
/// reload ack 路由侧不可读，由 SimilarityViewModel 本地标记提供。
public struct SimilaritySyncView: Equatable {
    /// TS: state（CaptureOneSessionState 枚举；nil 表示尚未加载）。
    public let state: CaptureOneSessionState?
    /// TS: xmp.written —— 已写入、C1 未确认的行数。
    public let written: Int

    public init(state: CaptureOneSessionState?, written: Int) {
        self.state = state
        self.written = written
    }
}

/// 三按钮状态机门控 + 禁用提示 + 状态文案（TS utils/c1-sync-controls.ts 移植）。
public struct SimilaritySyncControls: Equatable {
    public let canLoadMetadata: Bool
    public let canConfirmSync: Bool
    public let canCleanup: Bool
    public let loadHint: String?
    public let confirmHint: String?
    public let cleanupHint: String?
    /// TS: syncStatusCopy（按钮旁状态文案）。
    public let statusText: String

    public init(
        canLoadMetadata: Bool,
        canConfirmSync: Bool,
        canCleanup: Bool,
        loadHint: String?,
        confirmHint: String?,
        cleanupHint: String?,
        statusText: String
    ) {
        self.canLoadMetadata = canLoadMetadata
        self.canConfirmSync = canConfirmSync
        self.canCleanup = canCleanup
        self.loadHint = loadHint
        self.confirmHint = confirmHint
        self.cleanupHint = cleanupHint
        self.statusText = statusText
    }
}

/// 相似度视图模型：分析控制（阈值/组大小/分组模式/预设）+ 运行状态机
/// （idle/running/result/error）+ 阈值档切换 + 分组选择 + 关键词写回
/// （预览/写回/重试/loadMetadata→confirmSync→cleanup 状态机）。
@MainActor
@Observable
public final class SimilarityViewModel {
    /// 页面级状态（TS 由 result/isLoading/error + isAnalyzing 组合表达）。
    public enum Phase: Equatable {
        case idle
        case running
        case result
        case error(String)
    }

    /// TS: similarityStore.ts 初始值。
    public static let defaultThreshold = 10
    public static let defaultMinGroupSize = 2
    /// TS: AnalysisPanel 预设。
    public static let presets: [(name: String, threshold: Int, minGroupSize: Int)] = [
        ("strict", 6, 2),
        ("balanced", 10, 2),
        ("loose", 16, 3),
    ]
    /// TS: KeywordWritebackPanel 预览明细上限。
    public static let previewItemLimit = 50

    public let sessionId: String
    private let provider: SimilarityDataProvider
    private let pollInterval: Duration
    /// TS: 阈值档切换防抖（300ms）。
    private let tierDebounceDelay: Duration
    private var pollTask: Task<Void, Never>?
    private var resultPollTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var tierTask: Task<Void, Never>?
    private var tierRequestID = 0
    /// 结果代：每次 adoptResult 自增；recluster/analyze 完成时若检测到
    /// await 期间已有更新代（事件驱动刷新）被采纳，则放弃旧代（对齐
    /// tierRequestID 防过期模式，审计 3）。
    private var resultRequestID = 0
    private let captureOne: CaptureOneBridge

    private(set) public var phase: Phase = .idle
    private(set) public var result: SimilarityResult?
    private(set) public var isAnalyzing = false
    private(set) public var isReclustering = false
    private(set) public var isCanceling = false
    private(set) public var isLoading = false
    private(set) public var errorMessage: String?
    private(set) public var progressCurrent = 0
    private(set) public var progressTotal = 0
    private(set) public var progressMessage = ""
    private(set) public var selectedGroupIds: Set<Int> = []
    private(set) public var writebackPreview: WritebackPreview?
    private(set) public var writebackResult: WritebackResult?
    private(set) public var isSyncBusy = false
    /// TS: KeywordWritebackPanel 的 message（面板状态文案）。
    private(set) public var writebackMessage: String?
    /// TS: syncView（C1SyncStateView；nil = 尚未加载 → 保守全禁用）。
    private(set) public var syncView: SimilaritySyncView?
    /// reload ack 本地近似：reloadMetadata 成功后置位，新写回活动复位
    /// （对齐 DB clearReloadAck：新写入使会话 reload-ack 失效）。
    private(set) public var reloadAcked = false
    public var writebackKeywords = ""
    /// 草稿参数（TS similarityStore：阈值/组大小/分组模式）。
    public var threshold = SimilarityViewModel.defaultThreshold
    public var minGroupSize = SimilarityViewModel.defaultMinGroupSize
    public var groupingMode: SimilarityGroupingMode = .global

    public init(
        sessionId: String,
        provider: SimilarityDataProvider,
        pollInterval: Duration = .seconds(1),
        tierDebounceDelay: Duration = .milliseconds(300),
        captureOne: CaptureOneBridge = CaptureOneBridge()
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.pollInterval = pollInterval
        self.tierDebounceDelay = tierDebounceDelay
        self.captureOne = captureOne
    }

    // MARK: 加载与恢复（TS useQuery + 挂载恢复 effect）

    /// 幂等守卫（审计 4）：会话切换时 .task(id:) 与 onChange 双触发 load()。
    /// load 主体为同步执行，先发者在置位 isLoading 后经 Task.yield() 让出
    /// 主队列一次，后发者看到 isLoading 直接跳过，避免 2× getResult/
    /// refreshSyncState/listSimilarityJobs；串行显式调用（测试/重试）不受影响。
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await Task.yield()
        do {
            if let result = try await provider.getResult(sessionId: sessionId, threshold: nil) {
                adoptResult(result, syncThreshold: true)
                phase = .result
            } else {
                phase = .idle
                startResultPolling()
            }
        } catch {
            // 初始加载失败：置 error 态 + 可见 message（TS index.tsx:994-999
            // 全页错误块；errorMessage 供横幅与重试态渲染）。
            let text = Self.message(for: error)
            phase = .error(text)
            errorMessage = text
        }
        refreshSyncState()
        // TS 挂载恢复：jobs.list 中残留 similarity.analyze 活跃任务 →
        // 恢复分析中状态与进度（轮询代替 jobs:progress 推送）；列表查询
        // 失败不静默吞错，写入 errorMessage 可见（审计 7a）。
        do {
            if let job = Self.activeSimilarityJob(from: try await provider.listSimilarityJobs(sessionId: sessionId)) {
                isAnalyzing = true
                updateProgress(from: job)
                startProgressPolling()
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// 结果查询刷新（分析完成后 / 重进页面）。
    private func refreshResult() async {
        do {
            if let result = try await provider.getResult(sessionId: sessionId, threshold: nil) {
                adoptResult(result, syncThreshold: true)
                phase = .result
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: 参数（TS similarityStore setter 语义）

    /// 阈值草稿变更：存在结果且与结果档位不同 → 防抖后尝试邻近阈值档
    /// （sim.result 按阈值查预计算档；命中才采纳，否则保留草稿）。
    public func thresholdDraftChanged() {
        guard let result, Double(threshold) != result.stats.threshold else {
            tierTask?.cancel()
            return
        }
        tierTask?.cancel()
        let requestID = tierRequestID + 1
        tierRequestID = requestID
        tierTask = Task { [weak self] in
            try? await Task.sleep(for: self?.tierDebounceDelay ?? .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.adoptTier(requestID: requestID)
        }
    }

    private func adoptTier(requestID: Int) async {
        guard requestID == tierRequestID else { return }
        do {
            guard let tier = try await provider.getResult(sessionId: sessionId, threshold: threshold),
                  tier.stats.threshold == Double(threshold) else {
                // 无预计算档（或请求过期）：保留草稿值（TS 注释同语义）。
                return
            }
            adoptResult(tier, syncThreshold: true)
            phase = .result
        } catch {
            // 瞬时失败：保留草稿，但给出可见提示（审计 7b）。
            errorMessage = Self.message(for: error)
        }
    }

    /// 预设应用（TS applyPreset：strict 6/2、balanced 10/2、loose 16/3）。
    public func applyPreset(_ name: String) {
        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
        threshold = preset.threshold
        minGroupSize = preset.minGroupSize
    }

    /// TS: activePreset 判定。
    public var activePreset: String? {
        if threshold == 6 && minGroupSize == 2 { return "strict" }
        if threshold == 10 && minGroupSize == 2 { return "balanced" }
        if threshold == 16 && minGroupSize == 3 { return "loose" }
        return nil
    }

    // MARK: 分析（TS analyzeMutation + 进度轮询）

    public func startAnalyze() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        errorMessage = nil
        progressCurrent = 0
        progressTotal = 0
        progressMessage = ""
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            await self?.runAnalysis()
        }
        startProgressPolling()
    }

    private func runAnalysis() async {
        // 捕获发起时的结果代：await 期间若事件驱动刷新已采纳更新代，
        // 完成后的旧代刷新放弃，避免 last-writer-wins 覆盖（审计 3）。
        let requestID = resultRequestID
        do {
            try await provider.analyze(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
            stopProgressPolling()
            isAnalyzing = false
            guard requestID == resultRequestID else { return }
            await refreshResult()
        } catch {
            stopProgressPolling()
            isAnalyzing = false
            errorMessage = Self.message(for: error)
            if result == nil {
                phase = .error(errorMessage ?? "SIM_ANALYZE_FAILED")
            }
        }
    }

    public func cancelAnalysis() async {
        guard !isCanceling else { return }
        isCanceling = true
        defer { isCanceling = false }
        isAnalyzing = false
        stopProgressPolling()
        do {
            _ = try await provider.cancelAnalysis(sessionId: sessionId)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: 重新聚类（TS reclusterMutation：同步返回并采纳新结果）

    public func recluster() async {
        guard !isReclustering, result != nil else { return }
        isReclustering = true
        errorMessage = nil
        defer { isReclustering = false }
        // 捕获发起时的结果代：await 期间更新代（事件驱动刷新）已被采纳
        // 时放弃本次旧代结果，避免覆盖新数据（审计 3）。
        let requestID = resultRequestID
        do {
            let newResult = try await provider.recluster(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
            guard requestID == resultRequestID else { return }
            adoptResult(newResult, syncThreshold: true)
            phase = .result
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: 进度轮询（TS jobs:progress 推送的替代）
    //
    // start/stop 供 RootView 做隐藏页轮询门控（opacity 常驻方案下
    // onDisappear/onAppear 不触发，由导航切换显式启停，审计 2）。

    func startProgressPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollProgress()
        }
    }

    func stopProgressPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// TS useQuery refetchInterval：无结果时每 2s 重查一次，直到有数据。
    func startResultPolling() {
        resultPollTask?.cancel()
        resultPollTask = Task { [weak self] in
            await self?.pollForResult()
        }
    }

    func stopResultPolling() {
        resultPollTask?.cancel()
        resultPollTask = nil
    }

    private func pollForResult() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if result != nil {
                stopResultPolling()
                return
            }
            do {
                if let result = try await provider.getResult(sessionId: sessionId, threshold: nil) {
                    adoptResult(result, syncThreshold: true)
                    phase = .result
                    stopResultPolling()
                    return
                }
            } catch {
                // 结果轮询失败：置 error 态 + 可见 message（同 load() 语义，
                // TS useQuery error → 全页错误块）。
                let text = Self.message(for: error)
                phase = .error(text)
                errorMessage = text
                stopResultPolling()
                return
            }
        }
    }

    /// 活跃任务消失（clearCompleted/去重替换）时连续空轮上限：进度轮询
    /// 在此轮数内未再见到活跃任务即退出，防止循环永不结束（审计 5）。
    /// 查询失败同样以连续失败轮数计，单次失败不计入空闲轮数（审计 8）。
    /// 默认轮询间隔 1s → 约 30s 兜底。
    private static let maxIdleProgressPollRounds = 30

    private func pollProgress() async {
        var idleRounds = 0
        var failedRounds = 0
        while !Task.isCancelled {
            do {
                let jobs = try await provider.listSimilarityJobs(sessionId: sessionId)
                failedRounds = 0
                if let job = Self.activeSimilarityJob(from: jobs) {
                    idleRounds = 0
                    if Self.isTerminal(job.status) {
                        // 挂载恢复场景：轮询发现任务已结束 → 刷新结果并退出。
                        isAnalyzing = false
                        await refreshResult()
                        break
                    }
                    updateProgress(from: job)
                } else {
                    idleRounds += 1
                    if idleRounds >= Self.maxIdleProgressPollRounds {
                        // 任务已消失（clearCompleted/去重替换）：退出轮询，
                        // 不再无限空转。
                        isAnalyzing = false
                        break
                    }
                }
            } catch {
                // 查询失败：不计入空闲轮数，仅连续失败轮数累计。
                idleRounds = 0
                failedRounds += 1
                if failedRounds >= Self.maxIdleProgressPollRounds {
                    isAnalyzing = false
                    break
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// TS: 挂载恢复 filter —— 活跃任务（queued/running/cancelling）。
    static func activeSimilarityJob(from jobs: [AnalysisJobData]) -> AnalysisJobData? {
        jobs.first { ["queued", "running", "cancelling"].contains($0.status.rawValue) }
    }

    static func isTerminal(_ status: AnalysisJobStatus) -> Bool {
        [.succeeded, .failed, .cancelled, .interrupted].contains(status)
    }

    private func updateProgress(from job: AnalysisJobData) {
        progressCurrent = job.progressCurrent
        progressTotal = job.progressTotal
        progressMessage = job.progressMessage.isEmpty ? "similarity.analyzing" : job.progressMessage
    }

    // MARK: 结果采纳（TS lastSyncedResult 同步语义 + onResultAdopted 清空选择）

    /// 新结果对象到达时同步草稿参数：阈值总是跟随；非预计算档（analyze/
    /// recluster 实时计算）时组大小与分组模式也跟随。每次采纳推进结果代
    /// （审计 3 的单调序）。
    private func adoptResult(_ newResult: SimilarityResult, syncThreshold: Bool) {
        guard syncThreshold else { return }
        resultRequestID += 1
        result = newResult
        selectedGroupIds = []
        threshold = Int(newResult.stats.threshold)
        if newResult.stats.precomputed != true {
            minGroupSize = newResult.stats.minGroupSize
            groupingMode = newResult.stats.groupingMode
        }
    }

    // MARK: 分组选择（对齐 onSelectedChange / onSelectAll）

    public func toggleGroupSelection(_ groupId: Int) {
        if selectedGroupIds.contains(groupId) {
            selectedGroupIds.remove(groupId)
        } else {
            selectedGroupIds.insert(groupId)
        }
        markWritebackDraftChanged()
    }

    public func setAllGroupsSelected(_ selected: Bool) {
        selectedGroupIds = selected
            ? Set(result?.groups.map(\.id) ?? [])
            : []
        markWritebackDraftChanged()
    }

    // MARK: 关键词写回（TS KeywordWritebackPanel）

    /// 中英文逗号分隔（TS `.split(/[,，]/)`）。
    public var parsedWritebackKeywords: [String] {
        writebackKeywords.split { $0 == "," || $0 == "，" }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// TS: previewWriteback/writeback 均以结果档位为参（result.stats.threshold），
    /// 草稿阈值仅用于展示与预计算档位切换。
    private var writebackThreshold: Int? {
        result.map { Int($0.stats.threshold) }
    }

    /// TS: canPreview（assignments > 0 && keywords > 0 && !busy）。
    public var canPreviewWriteback: Bool {
        !selectedGroupIds.isEmpty && !parsedWritebackKeywords.isEmpty && !isSyncBusy
    }

    /// 关键词/选择变化 → 清空旧预览、旧写回结果与同步状态视图（TS effect：
    /// setPreview(null) + setWritebackResult(null) + setSyncView(null)，按钮全禁用）。
    public func markWritebackDraftChanged() {
        writebackPreview = nil
        writebackResult = nil
        syncView = nil
    }

    public func previewKeywordWriteback() async {
        guard canPreviewWriteback else {
            if selectedGroupIds.isEmpty {
                errorMessage = GatherLocalization.l("请选择至少一个相似度分组")
            } else if parsedWritebackKeywords.isEmpty {
                errorMessage = GatherLocalization.l("请输入要写回的关键字")
            }
            return
        }
        isSyncBusy = true
        defer { isSyncBusy = false }
        do {
            let assignments = selectedGroupIds.sorted().map { SimilarityKeywordAssignment(groupId: $0, keywords: parsedWritebackKeywords) }
            writebackPreview = try await provider.previewWriteback(
                sessionId: sessionId,
                assignments: assignments,
                threshold: writebackThreshold
            )
            writebackMessage = String(format: GatherLocalization.l("预览完成：%lld 张照片将合并这些关键词。"), writebackPreview?.affectedPhotos ?? 0)
            errorMessage = nil
        } catch {
            let text = Self.message(for: error)
            errorMessage = text
            writebackMessage = String(format: GatherLocalization.l("预览失败：%@"), text)
        }
    }

    public func executeKeywordWriteback() async {
        guard canPreviewWriteback else { return }
        isSyncBusy = true
        defer {
            isSyncBusy = false
            refreshSyncState()
        }
        do {
            // TS: preview ?? await previewWriteback(...)（无预览时自动补一次）。
            let preview: WritebackPreview
            if let existing = writebackPreview {
                preview = existing
            } else {
                let assignments = selectedGroupIds.sorted().map { SimilarityKeywordAssignment(groupId: $0, keywords: parsedWritebackKeywords) }
                preview = try await provider.previewWriteback(
                    sessionId: sessionId,
                    assignments: assignments,
                    threshold: writebackThreshold
                )
                writebackPreview = preview
            }
            let ids = preview.items.compactMap(\.id)
            guard !ids.isEmpty else {
                writebackMessage = GatherLocalization.l("预览没有可写回项")
                return
            }
            let nextResult = try await provider.writeback(sessionId: sessionId, itemIds: ids, threshold: writebackThreshold)
            writebackResult = nextResult
            // 新写入活动使会话 reload-ack 失效（DB clearReloadAck 语义）。
            reloadAcked = false
            writebackMessage = String(format: GatherLocalization.l("XMP 写入完成：成功 %lld，失败 %lld，跳过 %lld。"), nextResult.written, nextResult.failed, nextResult.skipped)
            errorMessage = nil
        } catch {
            let text = Self.message(for: error)
            errorMessage = text
            writebackMessage = String(format: GatherLocalization.l("XMP 写入失败：%@"), text)
        }
    }

    public func retryKeywordWriteback() async {
        isSyncBusy = true
        defer {
            isSyncBusy = false
            refreshSyncState()
        }
        do {
            let nextResult = try await provider.retryFailedWriteback(sessionId: sessionId)
            writebackResult = nextResult
            reloadAcked = false
            writebackMessage = String(format: GatherLocalization.l("重试完成：成功 %lld，失败 %lld。"), nextResult.written, nextResult.failed)
            errorMessage = nil
        } catch {
            let text = Self.message(for: error)
            errorMessage = text
            writebackMessage = String(format: GatherLocalization.l("重试失败：%@"), text)
        }
    }

    /// 第一步：Capture One 加载元数据（成功才写入持久 ack；绝不自动确认）。
    public func loadMetadataInCaptureOne() async {
        isSyncBusy = true
        defer {
            isSyncBusy = false
            refreshSyncState()
        }
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            reloadAcked = true
            writebackMessage = GatherLocalization.l("已在 Capture One 中加载元数据，返回后请确认同步")
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
            writebackMessage = GatherLocalization.l("加载元数据失败")
        }
    }

    /// 第二步：确认同步（服务端 requireReloadAck 兜底）。
    public func confirmSync() async {
        do {
            try await provider.confirmSync(sessionId: sessionId)
            writebackMessage = GatherLocalization.l("已确认 Capture One 完成「加载元数据」，现在可以安全清理临时 XMP 变更。")
            errorMessage = nil
        } catch {
            let text = Self.message(for: error)
            errorMessage = text
            writebackMessage = String(format: GatherLocalization.l("确认失败：%@"), text)
        }
        refreshSyncState()
    }

    public func cleanupKeywordWriteback() async {
        do {
            let cleanup = try await provider.cleanupWriteback(sessionId: sessionId)
            writebackResult = nil
            writebackPreview = nil
            writebackMessage = String(format: GatherLocalization.l("清理完成：已恢复或移除 %lld 个 sidecar 文件。"), cleanup.deletedCount)
            errorMessage = nil
        } catch {
            let text = Self.message(for: error)
            errorMessage = text
            writebackMessage = String(format: GatherLocalization.l("清理失败：%@"), text)
        }
        refreshSyncState()
    }

    // MARK: C1 同步状态机（TS utils/c1-sync-controls.ts 移植，2.3.5 P1）

    /// 重拉同步状态视图（sim.writeback_items 行计数 → aggregateSessionState）；
    /// 失败保留上次视图（未知状态下按钮按保守策略全部禁用），但给出可见
    /// 提示，不再静默吞错（审计 7c）。
    public func refreshSyncState() {
        let items: [WritebackItem]
        do {
            items = try provider.syncStateItems(sessionId: sessionId)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.xmpStatus, default: 0] += 1
        }
        let state = aggregateSessionState(counts: counts, reloadAckedAt: reloadAcked ? "x" : nil)
        syncView = SimilaritySyncView(state: state, written: counts["written"] ?? 0)
    }

    /// 三按钮可用性 + 禁用提示 + 状态文案（deriveSyncControls /
    /// deriveSyncControlHints / syncStatusCopy 逐分支移植）。
    public var syncControls: SimilaritySyncControls {
        let state = syncView?.state
        let hasWritten = (syncView?.written ?? 0) > 0
        let acked = reloadAcked

        var canLoadMetadata = false
        var canConfirmSync = false
        var canCleanup = false
        if let state {
            let loadable = state == .syncing || state == .c1Read || state == .safeToCleanup
            canLoadMetadata = loadable
            let confirmable = (state == .c1Read && hasWritten && acked) || state == .safeToCleanup
            canConfirmSync = confirmable
            canCleanup = state == .safeToCleanup
        }

        let loadHint: String?
        if canLoadMetadata {
            loadHint = nil
        } else if state == .synced {
            loadHint = GatherLocalization.l("已完成同步，无需再次加载元数据")
        } else if state == .failed {
            loadHint = GatherLocalization.l("存在写入失败项，请先重试")
        } else if state == .conflict {
            loadHint = GatherLocalization.l("存在 XMP 冲突，请先裁决")
        } else {
            loadHint = GatherLocalization.l("没有可加载的已写入元数据")
        }
        let confirmHint: String?
        if canConfirmSync {
            confirmHint = nil
        } else if state == .synced {
            confirmHint = GatherLocalization.l("已完成同步")
        } else if !acked {
            confirmHint = GatherLocalization.l("请先在 Capture One 中加载元数据，再确认同步")
        } else {
            confirmHint = GatherLocalization.l("请先等待写入完成或处理失败项")
        }
        let cleanupHint: String?
        if canCleanup {
            cleanupHint = nil
        } else if state == .synced {
            cleanupHint = GatherLocalization.l("已完成清理")
        } else {
            cleanupHint = GatherLocalization.l("请先加载元数据并确认同步，再执行清理")
        }

        let statusText: String
        switch state {
        case .syncing: statusText = GatherLocalization.l("同步中：Gather 正在写入 XMP…")
        case .c1Read: statusText = GatherLocalization.l("Gather 已写入，等待 C1 读取")
        case .safeToCleanup: statusText = GatherLocalization.l("C1 已读取，可安全清理")
        case .synced: statusText = GatherLocalization.l("已同步")
        case .failed: statusText = GatherLocalization.l("有写入失败项，请先重试")
        case .conflict: statusText = GatherLocalization.l("存在 XMP 冲突，请先裁决")
        case .disconnected: statusText = GatherLocalization.l("Capture One 未连接")
        case .connected: statusText = GatherLocalization.l("已连接 Capture One，暂无写入")
        case nil: statusText = GatherLocalization.l("同步状态加载中…")
        }

        return SimilaritySyncControls(
            canLoadMetadata: canLoadMetadata,
            canConfirmSync: canConfirmSync,
            canCleanup: canCleanup,
            loadHint: loadHint,
            confirmHint: confirmHint,
            cleanupHint: cleanupHint,
            statusText: statusText
        )
    }

    // MARK: 错误 message（对齐 DashboardViewModel.message）

    static func message(for error: Error) -> String {
        if error is RouterCommandError {
            return GatherLocalization.message(for: error)
        }
        if let sessionError = error as? SessionServiceError {
            return sessionError.gatherCode.rawValue
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }
}
