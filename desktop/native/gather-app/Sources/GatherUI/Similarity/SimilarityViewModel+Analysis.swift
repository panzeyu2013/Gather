// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityViewModel+Analysis.swift
// Cut 4 / 4c-2h：从 SimilarityViewModel.swift 移出参数草稿与阈值档、分析 /
// 取消 / 重新聚类、结果采纳与分组选择（原 322-453、633-675 行）。
// 纯搬移：阈值档防抖与代次守卫、结果代自增、采纳后清空选择/展开态逐字未动。
import Foundation
import GatherProtocol

extension SimilarityViewModel {

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
            guard let tier = try await similarity.result(
                SimilarityResultQuery(sessionId: sessionId, threshold: threshold)
            ),
            tier.stats.threshold == Double(threshold) else {
                // 无预计算档（或请求过期）：保留草稿值（TS 注释同语义）。
                return
            }
            adoptResult(tier, syncThreshold: true)
            phase = .result
        } catch {
            // 瞬时失败：保留草稿，但给出可见提示（审计 7b；4c-3 操作级出口）。
            actionError = CommandError(error)
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
        actionError = nil
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
            _ = try await similarity.analyze(SimilarityAnalyzeInput(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            ))
            stopProgressPolling()
            isAnalyzing = false
            guard requestID == resultRequestID else { return }
            await refreshResult()
        } catch {
            stopProgressPolling()
            isAnalyzing = false
            let failure = CommandError(error)
            if result == nil {
                // 无既有结果：页级失败只写 phase.error（4c-3 唯一来源）。
                actionError = nil
                phase = .error(failure)
            } else {
                // 已有结果：保留页面，失败作为操作级错误可见。
                actionError = failure
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
            _ = try await similarity.cancelAnalysis(sessionId)
        } catch {
            actionError = CommandError(error)
        }
    }

    // MARK: 重新聚类（TS reclusterMutation：同步返回并采纳新结果）

    public func recluster() async {
        guard !isReclustering, result != nil else { return }
        isReclustering = true
        actionError = nil
        defer { isReclustering = false }
        // 捕获发起时的结果代：await 期间更新代（事件驱动刷新）已被采纳
        // 时放弃本次旧代结果，避免覆盖新数据（审计 3）。
        let requestID = resultRequestID
        do {
            let input = try SimilarityAnalyzeInput(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
            guard let newResult = try await similarity.recluster(input) else { return }
            guard requestID == resultRequestID else { return }
            adoptResult(newResult, syncThreshold: true)
            phase = .result
        } catch {
            actionError = CommandError(error)
        }
    }
}
