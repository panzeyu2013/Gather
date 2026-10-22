// desktop/native/gather-core/Sources/GatherApplication/Services/Similarity/SimilarityService+Cluster.swift
// P1-4 收口：SimilarityService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：recluster 与聚类决策（增量/全量择路、状态复用判定、结果 + 簇状态单事务落库）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension SimilarityService {

    /// 阈值重聚类（job 化，§4.2 修复）：复用已有 hash，不重算；与 analyze 共用
    /// 会话占用槽（互斥，占用中抛 SIM_ANALYSIS_RUNNING）。进度相位
    /// similarity.cluster → similarity.thresholds；取消在分段边界协作式检查
    /// （主结果提交前的取消不落库，提交后的档位预计算按 best-effort 提前退出）。
    /// 结果与簇状态单事务原子写；不写 sessions.analysis_status。
    public func recluster(
        sessionId: String,
        threshold: Double,
        minGroupSize: Double,
        groupingMode: SimilarityGroupingMode = .global,
        signal externalSignal: JobAbortSignal? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> SimilarityResult {
        try validateSimilarityParameters(threshold: threshold, minGroupSize: minGroupSize)
        let threshold = Int(threshold)
        let minGroupSize = Int(minGroupSize)

        let slot = try acquireSlot(sessionId: sessionId)
        let signal = slot.signal
        linkExternalSignal(externalSignal, to: slot)
        defer { releaseSlot(slot, for: sessionId) }
        if signal.aborted { throw JobCancelledError() }

        let existing = try similarityResultRepo.getLatest(sessionId: sessionId)
        if existing == nil { throw SimilarityServiceError.noResults }

        let photos = PhotoAssets.collapse(try photoRepo.getBySessionProjection(sessionId: sessionId))
        let hashMap = try hashes.getHashMap(sessionId: sessionId)

        let entries: [HashEntry] = photos.compactMap { photo in
            guard let hash = hashMap[photo.id] else { return nil }
            return HashEntry(photoId: photo.id, hash: hash)
        }
        if entries.isEmpty { throw SimilarityServiceError.noHashRecluster }

        onProgress?(0, entries.count, "similarity.cluster")
        let decision = try decideCluster(
            sessionId: sessionId,
            entries: entries,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            onProgress: onProgress
        )
        if signal.aborted { throw JobCancelledError() }
        onProgress?(entries.count, entries.count, "similarity.cluster-done")

        let pathMap = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })
        let built = buildStoredResult(
            rawGroups: decision.result.groups,
            rawUngrouped: decision.result.ungrouped,
            pathMap: pathMap,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            precomputed: false
        )

        _ = try persistClusterOutcome(
            sessionId: sessionId,
            threshold: threshold,
            minGroupSize: minGroupSize,
            built: built,
            stateUpdate: decision.stateUpdate
        )

        do {
            try await precomputeNeighborTiers(
                sessionId: sessionId,
                entries: entries,
                pathMap: pathMap,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                signal: signal,
                onProgress: onProgress
            )
        } catch {
            if signal.aborted { return built.result }
            GatherLogger.log("Similarity neighbor threshold precomputation failed: \(error)", level: .warn)
        }

        return built.result
    }

    // MARK: - 聚类决策（增量 / 全量）

    /// 聚类决策产物：簇结果 + 待与结果同事务落库的簇状态变更。
    struct ClusterDecision {
        let result: ClusterResult
        let stateUpdate: ClusterStateUpdate?
    }

    /// 簇状态变更（与结果同事务提交，§4.2 原子性修复）。
    /// Cut 5 / 5b-2b：replace 携带行级 diff，落库只写 upserts/removed。
    enum ClusterStateUpdate {
        case replace(
            threshold: Int, minGroupSize: Int, groupingMode: String,
            version: Int, incrementalUpdates: Int,
            state: ClusterState, diff: ClusterStateDiff
        )
        case delete
    }

    /// 聚类决策：状态参数匹配且连续增量次数未达收敛间隔时，走 IncrementalClusterer
    /// 的邻域局部更新；否则单趟全量（global 经 ClusterGraphPipeline 一次图构建同时
    /// 产出结果与状态，全仓唯一实现）。**不在本方法内落库**——状态变更
    /// 随结果由调用方在同一事务提交（见 persistClusterOutcome）。
    /// 增量失败（状态损坏/非法哈希）退化为全量，不阻塞分析。
    func decideCluster(
        sessionId: String,
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        onProgress: ProgressHandler?
    ) throws -> ClusterDecision {
        let snapshot = try clusterStateRepo.load(sessionId: sessionId)
        // Cut 5 / 5b-2b：版本列与快照必须一起判定——旧实现落的行即使参数全等
        // 也不得复用（否则两种算法的分量/种子会混在同一个 state 里）。
        let signature = ClusterStateVersioning.inputSignature(
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode.rawValue
        )
        let convergenceInterval = max(1, getNumber("similarity_cluster_convergence_interval", 10).safeInt(fallback: 10))

        if groupingMode == .global,
           let snapshot,
           stateIsReusable(
                snapshot: snapshot,
                signature: signature,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
           ),
           snapshot.meta.incrementalUpdates < convergenceInterval {
            do {
                let outcome = try IncrementalClusterer.update(
                    state: snapshot.state,
                    entries: entries,
                    minGroupSize: minGroupSize,
                    threshold: threshold
                )
                let result = IncrementalClusterer.result(
                    state: outcome.state, entries: entries, minGroupSize: minGroupSize
                )
                let summary = outcome.summary
                GatherLogger.log(
                    "Similarity incremental clustering: added=\(summary.addedCount) removed=\(summary.removedCount) changed=\(summary.changedCount) recomputed=\(summary.recomputedComponentCount) reused=\(summary.reusedComponentCount) version=\(snapshot.meta.version + 1)",
                    level: .info
                )
                return ClusterDecision(
                    result: result,
                    stateUpdate: .replace(
                        threshold: threshold,
                        minGroupSize: minGroupSize,
                        groupingMode: groupingMode.rawValue,
                        version: snapshot.meta.version + 1,
                        incrementalUpdates: snapshot.meta.incrementalUpdates + 1,
                        state: outcome.state,
                        diff: ClusterStateDiff(old: snapshot.state, new: outcome.state)
                    )
                )
            } catch {
                GatherLogger.log("Similarity incremental clustering fell back to full: \(error)", level: .warn)
            }
        }

        let clustered = try clusterProvider(
            entries, threshold, minGroupSize, HashGroupingMode(groupingMode),
            { current, total in onProgress?(current, total, "similarity.cluster") }
        )
        guard groupingMode == .global else {
            // sequential 模式没有增量设施（前缀 run 语义），清状态强制下次全量。
            return ClusterDecision(result: clustered.result, stateUpdate: .delete)
        }
        // state 与 result 来自同一次图构建（provider 的 ClusterGraphOutcome）。
        guard let state = clustered.state else {
            // 只可能来自测试注入的自定义 provider（无同源状态）：清状态，
            // 下次分析自然回到全量；结果照常落库。
            GatherLogger.log("Similarity cluster provider returned no state, clearing state", level: .warn)
            return ClusterDecision(result: clustered.result, stateUpdate: .delete)
        }
        return ClusterDecision(
            result: clustered.result,
            stateUpdate: .replace(
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode.rawValue,
                version: (snapshot?.meta.version ?? 0) + 1,
                incrementalUpdates: 0,
                state: state,
                // 全量覆盖也走行级 diff：参数不变但内容变化的照片只更新受影响的
                // 行，未变行不重写（旧实现是两表 DELETE 全表重插）。
                diff: ClusterStateDiff(old: snapshot?.state, new: state)
            )
        )
    }

    /// 增量复用判定（Cut 5 / 5b-2b）：参数、算法版本、参数指纹、状态摘要
    /// 六者全等才允许增量（repo.matches 做列级比对）。任一不符都按
    /// “旧/损坏 state”失效：调用方走全量并覆盖。
    private func stateIsReusable(
        snapshot: SimilarityClusterSnapshot,
        signature: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode
    ) -> Bool {
        if snapshot.meta.algorithmVersion != ClusterStateVersioning.currentAlgorithmVersion {
            GatherLogger.log(
                "Similarity cluster state version mismatch: stored=\(snapshot.meta.algorithmVersion) current=\(ClusterStateVersioning.currentAlgorithmVersion)",
                level: .debug
            )
            return false
        }
        if snapshot.meta.inputSignature != signature { return false }
        let digest = ClusterStateVersioning.stateDigest(snapshot.state)
        if snapshot.meta.stateDigest != digest {
            GatherLogger.log("Similarity cluster state digest mismatch, state invalidated", level: .warn)
            return false
        }
        return snapshot.matches(
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode.rawValue,
            algorithmVersion: ClusterStateVersioning.currentAlgorithmVersion,
            inputSignature: signature,
            stateDigest: digest
        )
    }

    /// 结果 + 簇状态单事务原子写：两写要么一起可见、要么一起不可见（§4.2 修复）。
    func persistClusterOutcome(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        built: StoredResultPayload,
        stateUpdate: ClusterStateUpdate?
    ) throws -> Int64 {
        try transactions.transaction {
            let resultId = try similarityResultRepo.replace(
                sessionId: sessionId,
                groupsJson: built.groupsJson,
                statsJson: built.statsJson,
                threshold: threshold,
                minGroupSize: minGroupSize,
                memberships: built.memberships
            )
            try applyClusterStateUpdate(stateUpdate, sessionId: sessionId)
            return resultId
        }
    }

    /// 簇状态变更落库（调用方事务内）。状态写入失败降级为清空（下次全量重来），
    /// 不因加速设施拖垮主结果；降级动作与结果同事务提交。
    private func applyClusterStateUpdate(_ update: ClusterStateUpdate?, sessionId: String) throws {
        switch update {
        case .none:
            return
        case .delete:
            try clusterStateRepo.delete(sessionId: sessionId)
        case .replace(let threshold, let minGroupSize, let groupingMode, let version, let incrementalUpdates, let state, let diff):
            do {
                try applyClusterState(
                    sessionId: sessionId,
                    threshold: threshold,
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode,
                    version: version,
                    incrementalUpdates: incrementalUpdates,
                    state: state,
                    diff: diff
                )
            } catch {
                GatherLogger.log("Similarity cluster state persist failed, clearing state: \(error)", level: .warn)
                try clusterStateRepo.delete(sessionId: sessionId)
            }
        }
    }

    /// 行级落库编排（Cut 5 / 5b-2b，调用方事务内）：语义 diff 在 Analysis 层计算，
    /// 版本/摘要在这里生成，SQL 细节全部交给 SimilarityClusterStateRepo.apply。
    /// 旧实现（两表 DELETE 全表重插）在 10k 照片时每次分析都写 10k 行，现降为 Δ 行。
    private func applyClusterState(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        version: Int,
        incrementalUpdates: Int,
        state: ClusterState,
        diff: ClusterStateDiff
    ) throws {
        try clusterStateRepo.apply(
            sessionId: sessionId,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            version: version,
            incrementalUpdates: incrementalUpdates,
            memberCount: state.hashes.count,
            algorithmVersion: ClusterStateVersioning.currentAlgorithmVersion,
            inputSignature: ClusterStateVersioning.inputSignature(
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            ),
            stateDigest: ClusterStateVersioning.stateDigest(state),
            upserts: diff.upserts.map { entry in
                SimilarityClusterStateWrite(
                    photoId: entry.photoId,
                    hashHex: entry.hashHex,
                    componentIndex: entry.componentIndex,
                    groupSeed: entry.groupSeed
                )
            },
            removedPhotoIds: diff.removed
        )
    }
}
