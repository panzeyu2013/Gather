// desktop/native/gather-app/Sources/GatherApp/Similarity/SimilarityViewModel.swift
// Phase 3.3 Similarity（相似度分析）：视图模型（服务可注入，同进程直连路由）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析流程/
//       阈值档切换/预设）+ stores/similarityStore.ts（阈值/组大小/分组模式/
//       isAnalyzing 草稿语义）+ api/similarity.ts（sim.* 命令形状）
//
// 差异说明（有意）：
// - TS 的 jobs:progress 推送 → 分析期间轮询 jobs.list（1s，测试可注入），
//   进度相位经 progressPhaseLabel 映射中文（progress.* 键值）；
// - 挂载恢复（重启后残留 running 任务）经轮询首帧识别并续传进度；
// - 关键词写回面板（sim.preview_writeback/sim.writeback 未接线）不展示，
//   选择集合保留（对齐 onResultAdopted 清空语义）。
import Foundation
import GatherCore

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态/时序门）或
/// 真实路由（LiveSimilarityDataProvider + 临时 SQLite）。
public protocol SimilarityDataProvider {
    /// TS: similarityApi.getResult → sim.result（threshold 缺省 = 最近档）。
    func getResult(sessionId: String, threshold: Int?) throws -> SimilarityResult?
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
    func listSimilarityJobs(sessionId: String) throws -> [AnalysisJobData]
}

/// 真实实现：同进程直连 SessionCommandRouter（sim.* 已接线命令以路由为
/// 唯一事实源，保证相似度占用/取消跨页一致）。
public final class LiveSimilarityDataProvider: SimilarityDataProvider {
    private let router: SessionCommandRouter

    public init(router: SessionCommandRouter) {
        self.router = router
    }

    public func getResult(sessionId: String, threshold: Int?) throws -> SimilarityResult? {
        let response = try router.execute("sim.result", params: [
            "sessionId": .string(sessionId),
            "threshold": threshold.map { .number(Double($0)) } ?? .null,
        ])
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

    public func listSimilarityJobs(sessionId: String) throws -> [AnalysisJobData] {
        try router.jobService.list().filter { $0.type == .similarityAnalyze && $0.scopeId == sessionId }
    }
}

/// 相似度视图模型：分析控制（阈值/组大小/分组模式/预设）+ 运行状态机
/// （idle/running/result/error）+ 阈值档切换 + 分组选择。
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

    public let sessionId: String
    private let provider: SimilarityDataProvider
    private let pollInterval: Duration
    /// TS: 阈值档切换防抖（300ms）。
    private let tierDebounceDelay: Duration
    private var pollTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var tierTask: Task<Void, Never>?
    private var tierRequestID = 0

    private(set) public var phase: Phase = .idle
    private(set) public var result: SimilarityResult?
    private(set) public var isAnalyzing = false
    private(set) public var isReclustering = false
    private(set) public var errorMessage: String?
    private(set) public var progressCurrent = 0
    private(set) public var progressTotal = 0
    private(set) public var progressMessage = ""
    private(set) public var selectedGroupIds: Set<Int> = []
    /// 草稿参数（TS similarityStore：阈值/组大小/分组模式）。
    public var threshold = SimilarityViewModel.defaultThreshold
    public var minGroupSize = SimilarityViewModel.defaultMinGroupSize
    public var groupingMode: SimilarityGroupingMode = .global

    public init(
        sessionId: String,
        provider: SimilarityDataProvider,
        pollInterval: Duration = .seconds(1),
        tierDebounceDelay: Duration = .milliseconds(300)
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.pollInterval = pollInterval
        self.tierDebounceDelay = tierDebounceDelay
    }

    // MARK: 加载与恢复（TS useQuery + 挂载恢复 effect）

    func load() async {
        do {
            if let result = try provider.getResult(sessionId: sessionId, threshold: nil) {
                adoptResult(result, syncThreshold: true)
                phase = .result
            } else {
                phase = .idle
            }
        } catch {
            phase = .error(Self.message(for: error))
        }
        // TS 挂载恢复：jobs.list 中残留 similarity.analyze 活跃任务 →
        // 恢复分析中状态与进度（轮询代替 jobs:progress 推送）。
        if let job = Self.activeSimilarityJob(from: (try? provider.listSimilarityJobs(sessionId: sessionId)) ?? []) {
            isAnalyzing = true
            updateProgress(from: job)
            startProgressPolling()
        }
    }

    /// 结果查询刷新（分析完成后 / 重进页面）。
    private func refreshResult() async {
        do {
            if let result = try provider.getResult(sessionId: sessionId, threshold: nil) {
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
            guard let tier = try provider.getResult(sessionId: sessionId, threshold: threshold),
                  tier.stats.threshold == Double(threshold) else {
                // 无预计算档（或请求过期）：保留草稿值（TS 注释同语义）。
                return
            }
            adoptResult(tier, syncThreshold: true)
            phase = .result
        } catch {
            // 瞬时失败：保留草稿。
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
        do {
            try await provider.analyze(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
            stopProgressPolling()
            isAnalyzing = false
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
        do {
            let newResult = try await provider.recluster(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
            adoptResult(newResult, syncThreshold: true)
            phase = .result
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: 进度轮询（TS jobs:progress 推送的替代）

    private func startProgressPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollProgress()
        }
    }

    private func stopProgressPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollProgress() async {
        while !Task.isCancelled {
            if let job = Self.activeSimilarityJob(from: (try? provider.listSimilarityJobs(sessionId: sessionId)) ?? []) {
                if Self.isTerminal(job.status) {
                    // 挂载恢复场景：轮询发现任务已结束 → 刷新结果并退出。
                    isAnalyzing = false
                    await refreshResult()
                    break
                }
                updateProgress(from: job)
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
    /// recluster 实时计算）时组大小与分组模式也跟随。
    private func adoptResult(_ newResult: SimilarityResult, syncThreshold: Bool) {
        guard syncThreshold else { return }
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
    }

    public func setAllGroupsSelected(_ selected: Bool) {
        selectedGroupIds = selected
            ? Set(result?.groups.map(\.id) ?? [])
            : []
    }

    // MARK: 错误 message（对齐 DashboardViewModel.message）

    static func message(for error: Error) -> String {
        if let commandError = error as? RouterCommandError {
            return commandError.message
        }
        if let sessionError = error as? SessionServiceError {
            return sessionError.gatherCode.rawValue
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }
}
