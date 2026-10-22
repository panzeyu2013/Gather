// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityViewModel+Load.swift
// Cut 4 / 4c-2h：从 SimilarityViewModel.swift 移出加载与恢复、两路轮询
// （原 269-320、455-487、525-631 行）。纯搬移：幂等守卫、挂载恢复、
// 空闲轮上限、代次守卫与错误落地逐字未动。
import Foundation
import GatherProtocol

extension SimilarityViewModel {

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
            if let result = try await similarity.result(SimilarityResultQuery(sessionId: sessionId)) {
                adoptResult(result, syncThreshold: true)
                phase = .result
            } else {
                phase = .idle
                startResultPolling()
            }
        } catch {
            // 初始加载失败：置 error 态（TS index.tsx:994-999 全页错误块）。
            // Cut 4 / 4c-3：页级错误只写 phase.error，errorMessage 是它的只读代理；
            // 清掉上次操作级错误，避免恢复成功后残留旧横幅。
            let failure = CommandError(error)
            phase = .error(failure)
            actionError = nil
        }
        await reloadSyncState()
        // TS 挂载恢复：jobs.list 中残留 similarity.analyze 活跃任务 →
        // 恢复分析中状态与进度（轮询代替 jobs:progress 推送）；列表查询
        // 失败不静默吞错，写入 actionError 可见（审计 7a；4c-3 操作级出口）。
        do {
            if let job = Self.activeSimilarityJob(from: try await listSimilarityJobs()) {
                isAnalyzing = true
                updateProgress(from: job)
                startProgressPolling()
            }
        } catch {
            actionError = CommandError(error)
        }
    }

    /// 结果查询刷新（分析完成后 / 重进页面）。
    func refreshResult() async {
        do {
            if let result = try await similarity.result(SimilarityResultQuery(sessionId: sessionId)) {
                adoptResult(result, syncThreshold: true)
                phase = .result
            }
        } catch {
            actionError = CommandError(error)
        }
    }

    // MARK: 进度轮询（TS jobs:progress 推送的替代）
    //
    // start/stop 供 RootView 做隐藏页轮询门控（opacity 常驻方案下
    // onDisappear/onAppear 不触发，由导航切换显式启停，审计 2）。
    // Cut 4 / 4a-2b：新增 setVisible/shutdown 后，View 只调 setVisible；
    // RootView 的显式 start/stop 保留（默认可见，行为不变）。

    package func startProgressPolling() {
        guard !isShutdown, isVisible else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollProgress()
        }
    }

    package func stopProgressPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// TS useQuery refetchInterval：无结果时每 2s 重查一次，直到有数据。
    package func startResultPolling() {
        guard !isShutdown, isVisible else { return }
        resultPollTask?.cancel()
        resultPollTask = Task { [weak self] in
            await self?.pollForResult()
        }
    }

    package func stopResultPolling() {
        resultPollTask?.cancel()
        resultPollTask = nil
    }

    private func pollForResult() async {
        // D-11（性能审计）：旧实现没有空闲上限 —— 长时间停在相似度页且从未分析时，
        // 会每 2s 在主线程同步拉一次 sim.result（全量投影 + 两次序列化）。
        // 与进度轮询一致，空转 30 轮（约 60s）后自行退出；有新结果时由事件/手动刷新唤醒。
        var idleRounds = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: resultPollInterval)
            guard !Task.isCancelled else { return }
            if result != nil {
                stopResultPolling()
                return
            }
            idleRounds += 1
            if idleRounds > Self.maxIdleProgressPollRounds {
                stopResultPolling()
                return
            }
            do {
                if let result = try await similarity.result(SimilarityResultQuery(sessionId: sessionId)) {
                    adoptResult(result, syncThreshold: true)
                    phase = .result
                    stopResultPolling()
                    return
                }
            } catch {
                // 结果轮询失败：置 error 态（同 load() 语义，TS useQuery error →
                // 全页错误块）。Cut 4 / 4c-3：页级错误只写 phase.error。
                let failure = CommandError(error)
                phase = .error(failure)
                actionError = nil
                stopResultPolling()
                return
            }
        }
    }

    private func pollProgress() async {
        var idleRounds = 0
        var failedRounds = 0
        while !Task.isCancelled {
            do {
                let jobs = try await listSimilarityJobs()
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
                        // 任务已消失（clearCompleted/去重替换）：退出轮询，不再无限空转。
                        //
                        // 第二轮验证修正：上面 isTerminal 的分支实际不可达——
                        // activeSimilarityJob 只返回 queued/running/cancelling，任务一旦
                        // 终态就落到这里。若分析时长超过结果轮询的空闲上限（约 62s），
                        // 两条轮询都已退出，页面会永远停在「无结果」直到手动刷新/重进。
                        // 退出前补一次结果查询（走 adoptResult 代际守卫，安全）。
                        isAnalyzing = false
                        await refreshResult()
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

    /// jobs.list 的唯一入口（B-4/D-1：轮询不需要 checkpoint 大字段）。
    private func listSimilarityJobs() async throws -> [AnalysisJobData] {
        try await jobs.list(JobListFilter(includeCheckpoint: false)).filter {
            $0.type == .similarityAnalyze && $0.scopeType == "session" && $0.scopeId == sessionId
        }
    }

    private func updateProgress(from job: AnalysisJobData) {
        progressCurrent = job.progressCurrent
        progressTotal = job.progressTotal
        progressMessage = job.progressMessage.isEmpty ? "similarity.analyzing" : job.progressMessage
    }

}
