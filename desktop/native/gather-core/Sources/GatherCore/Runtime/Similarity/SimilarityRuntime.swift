// desktop/native/gather-core/Sources/GatherCore/Runtime/Similarity/SimilarityRuntime.swift
// W2c：SimilarityRuntime actor（设计 §1.1）—— 取代 Services/SimilarityService.swift
// 的编排面（集成轮同批删除旧服务与旧测试；本轮只新增，不接线、不改旧文件）。
//
// 结构（与旧实现的差异均为修正）：
// - actor 状态仅 flights: [String: Flight]（值类型；取代 controllers + NSLock）；
//   参数解析 / 校验 / flight 注册在同一无 await 同步前缀内完成（TOCTOU 免疫，
//   非法参数不泄漏占用）；
// - await 预读（照片投影 / index_seq / run 插入 / hash 行 / asset_file_id /
//   复用候选 / 文件 stat 扫描）全部集中在解码循环之前；
// - 长同步 CPU / 阻塞 IO 一律出 actor：stat 扫描、单档与多档聚类、
//   IncrementalClusterer（增量更新 / 状态构建）、结果 JSON 编码走 Task.detached；
//   解码本身走批内组内子任务（窗口由 similarity_decode_concurrency 配置）；
// - 取消检查点：run 写入后 / 每解码批前后 / 聚类返回后 / 每邻域档写前；
//   catch 的会话状态写与 defer 的 run 终态化带 generation 守卫（只有 flight.id
//   仍持有该会话才写；迟到 catch 不覆写后继 flight 的状态）；
// - hash 复用走 SimilarityHashReuse.plan + SimilarityStore（单事务落库，
//   不再有静态 database 方法，跨 await TOCTOU 消失）；
// - try? 吞错改 do/catch + 明确处理（log；analyze 的 params / 结果 JSON encode
//   失败必须抛）；
// - 邻域档 best-effort：multiCluster 只调一次（一次距离遍历服务全部档位）、
//   失败只记日志；取消则静默放弃，不影响主结果；
// - getResult 一致装配：成员表优先（SimilarityAssembler），groups_json 仅在
//   成员表出现前的旧行兜底。
//
// 注意：Runtime/ 目录禁止出现 SQL 文本与 database.* 调用（门禁）。

import Foundation

public actor SimilarityRuntime {

    // MARK: - 端口类型

    /// TS: (filepath, maxDimension) → 9x8 灰度像素网格（72 字节），失败返回 nil。
    public typealias ThumbnailProvider = @Sendable (String, Int) async -> [UInt8]?
    /// TS: clusterHashesInWorker。
    public typealias ClusterProvider = @Sendable ([HashEntry], Int, Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> ClusterResult
    /// TS: clusterHashesInWorkerMulti。
    public typealias MultiClusterProvider = @Sendable ([HashEntry], [Int], Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> [ClusterResult]
    /// TS: onProgress(current, total, message)。
    public typealias ProgressHandler = @Sendable (Int, Int, String) -> Void

    // MARK: - 依赖 / 端口装配

    /// 注入依赖：四个 Store + 设置读取（无 SQLiteDatabase、无 SQL）。
    public struct Dependencies: Sendable {
        public let photoStore: any PhotoStore
        public let sessionStore: any SessionStore
        public let similarityStore: any SimilarityStore
        public let jobStore: any JobStore
        /// TS: SettingsService.getNumber 注入。
        public let getNumber: @Sendable (String, Double) -> Double

        public init(
            photoStore: any PhotoStore,
            sessionStore: any SessionStore,
            similarityStore: any SimilarityStore,
            jobStore: any JobStore,
            getNumber: @escaping @Sendable (String, Double) -> Double = { _, defaultValue in defaultValue }
        ) {
            self.photoStore = photoStore
            self.sessionStore = sessionStore
            self.similarityStore = similarityStore
            self.jobStore = jobStore
            self.getNumber = getNumber
        }
    }

    /// 解码 / 聚类端口；默认值与旧服务一致（thumbnail 恒 nil，聚类走 ClusterEngine）。
    public struct Providers: Sendable {
        public let thumbnail: ThumbnailProvider
        public let cluster: ClusterProvider
        public let multiCluster: MultiClusterProvider

        public init(
            thumbnail: @escaping ThumbnailProvider = { _, _ in nil },
            cluster: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
                try ClusterEngine.clusterByHash(
                    entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                    mode: mode, onProgress: onProgress
                )
            },
            multiCluster: @escaping MultiClusterProvider = { entries, thresholds, minGroupSize, mode, onProgress in
                try ClusterEngine.clusterByHashMulti(
                    entries: entries, thresholds: thresholds, minGroupSize: minGroupSize,
                    mode: mode, onProgress: onProgress
                )
            }
        ) {
            self.thumbnail = thumbnail
            self.cluster = cluster
            self.multiCluster = multiCluster
        }
    }

    // MARK: - 常量

    /// analysis_runs.kind。
    public static let runKind = "similarity"
    /// TS: SettingsService 键名。
    public static let decodeConcurrencyKey = "similarity_decode_concurrency"
    public static let previewMaxDimensionKey = "similarity_preview_max_dimension"
    public static let convergenceIntervalKey = "similarity_cluster_convergence_interval"
    /// 解码并发窗口默认值与 clamp 边界（旧实现 min(32, max(1, ...))）。
    public static let decodeConcurrencyDefault = 4
    public static let decodeConcurrencyBounds = 1...32
    /// 预览最长边默认值与 clamp 边界（旧实现 min(2048, max(64, ...))）。
    public static let previewMaxDimensionDefault = 256
    public static let previewMaxDimensionBounds = 64...2048

    // MARK: - 状态

    /// 在飞分析（值类型）：generation id + 取消信号。只有 id 仍等于
    /// flights[sessionId]?.id 的持有者才能写会话状态 / 终态化 run / 释放占用。
    private struct Flight {
        let id: UUID
        let signal: JobAbortSignal
    }

    private let dependencies: Dependencies
    private let providers: Providers

    /// 唯一可变状态：sessionId → 在飞分析（无锁、无 controllers）。
    private var flights: [String: Flight] = [:]

    public init(dependencies: Dependencies, providers: Providers = Providers()) {
        self.dependencies = dependencies
        self.providers = providers
    }

    // MARK: - analyze

    /// 全量分析：hash 复用 → 缺失 hash 解码计算 → 聚类 → 落结果 → 邻域阈值档
    /// 预计算（best-effort）。threshold/minGroupSize 为 Double 对齐 TS number；
    /// 校验先于整数化（绝不 Int(NaN) 陷阱）。
    public func analyze(
        sessionId: String,
        threshold: Double? = nil,
        minGroupSize: Double? = nil,
        groupingMode: SimilarityGroupingMode? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws {
        // ① 同步前缀（无 await）：占用检查 → 参数解析/校验 → flight 注册。
        // 校验失败不留下占用（旧 TS 缺陷修复）；注册在首个 await 之前
        // （两个并发 analyze 只有一个能通过检查，TOCTOU 免疫）。
        if flights[sessionId] != nil { throw SimilarityError.analysisRunning }
        let params = try SimilarityValidation.resolved(
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            getNumber: dependencies.getNumber
        )
        let flight = Flight(id: UUID(), signal: JobAbortSignal())
        flights[sessionId] = flight

        var runId: Int64 = 0
        var runStatus = "failed"
        // TS finally：早退（abort）与异常路径都必须终态化 run 并释放占用。
        // generation 守卫：只有本 flight 仍持有该会话时才写。
        defer {
            if isCurrent(flight, for: sessionId) {
                if runId != 0 {
                    do {
                        try await dependencies.jobStore.finishAnalysisRun(runId: runId, status: runStatus)
                    } catch {
                        GatherLogger.log("Similarity run finalize failed: \(error)", level: .warn)
                    }
                }
                flights[sessionId] = nil
            }
        }

        do {
            try await dependencies.sessionStore.updateAnalysisStatus(id: sessionId, status: "running")

            // ② await 预读（全部集中在解码循环前）：照片投影 + index_seq 快照。
            // 快照保证 run.index_seq 与本次分析的照片一致。
            let photosSnapshot = PhotoAssets.collapse(
                try await dependencies.photoStore.getBySessionProjection(sessionId: sessionId)
            )
            let indexSeqSnapshot = try await dependencies.sessionStore.indexSeq(id: sessionId)
            if photosSnapshot.isEmpty { throw SimilarityError.noPhotos }

            runId = try await dependencies.jobStore.insertAnalysisRun(AnalysisRunInsert(
                sessionId: sessionId,
                kind: Self.runKind,
                photoCount: photosSnapshot.count,
                indexSeq: indexSeqSnapshot,
                params: try Self.encodeParams(params)
            ))

            if flight.signal.aborted { return }   // 取消检查点：run 写入后

            // 既有 hash 行 + 照片 → asset_file_id 映射预读（分块读在 Store 内）。
            let existingHashes = try await dependencies.similarityStore.hashes(sessionId: sessionId)
            let assetFileByPhoto = try await dependencies.photoStore.assetFileIdsByPhoto(sessionId: sessionId)

            // 文件统计优先取自索引扫描（checksum_file_size / mtime），完整分析
            // 不再逐照片 stat；只有未索引照片落盘。stat 属阻塞 IO → 出 actor。
            let sourceStats = await Self.scanSourceStats(photosSnapshot)

            var existingHashMap: [String: String] = [:]
            for row in existingHashes {
                guard let stat = sourceStats[row.photoId],
                      stat.size == row.fileSize,
                      abs(stat.mtimeMs - row.fileMtimeMs) < 1 else { continue }
                existingHashMap[row.photoId] = row.hashHex
            }

            // ③ TS: reuseSimilarityHashes —— 纯 plan + Store 单事务写入。
            // 旧实现的「读候选与写回分处两个 await 窗口」TOCTOU 结构性消失。
            let assetFileIds = SimilarityHashReuse.assetFileIds(
                photos: photosSnapshot, assetFileByPhoto: assetFileByPhoto
            )
            let candidates = try await dependencies.similarityStore.hashCandidates(assetFileIds: assetFileIds)
            let reusePlan = SimilarityHashReuse.plan(
                photos: photosSnapshot,
                sourceStats: sourceStats,
                existingHashMap: existingHashMap,
                assetFileByPhoto: assetFileByPhoto,
                candidates: candidates
            )
            if !reusePlan.writes.isEmpty {
                try await dependencies.similarityStore.upsertHashes(
                    sessionId: sessionId, hashes: reusePlan.writes
                )
            }
            existingHashMap = reusePlan.hashes

            // ④ 解码窗口：缺失 hash 的照片分批并发解码（窗口 = 设置值）。
            let uncachedPhotos = photosSnapshot.filter { existingHashMap[$0.id] == nil }
            if !uncachedPhotos.isEmpty {
                if flight.signal.aborted { return }

                onProgress?(0, uncachedPhotos.count, "similarity.hash")
                let decodeBatchSize = Self.intSetting(
                    dependencies.getNumber(Self.decodeConcurrencyKey, Double(Self.decodeConcurrencyDefault)),
                    fallback: Self.decodeConcurrencyDefault,
                    bounds: Self.decodeConcurrencyBounds
                )
                let previewMaxDimension = Self.intSetting(
                    dependencies.getNumber(Self.previewMaxDimensionKey, Double(Self.previewMaxDimensionDefault)),
                    fallback: Self.previewMaxDimensionDefault,
                    bounds: Self.previewMaxDimensionBounds
                )

                var offset = 0
                while offset < uncachedPhotos.count {
                    if flight.signal.aborted { return }   // 取消检查点：每解码批前
                    let batch = Array(uncachedPhotos[offset..<min(offset + decodeBatchSize, uncachedPhotos.count)])
                    offset += decodeBatchSize

                    let outcomes = await Self.decodeBatch(
                        batch,
                        previewMaxDimension: previewMaxDimension,
                        sourceStats: sourceStats,
                        thumbnail: providers.thumbnail
                    )
                    var writes: [SimilarityHashUpsert] = []
                    writes.reserveCapacity(outcomes.count)
                    for outcome in outcomes {
                        guard let pixels = outcome.pixels, let stat = outcome.stat else { continue }
                        let hash = DHash.compute(pixels9x8: pixels)
                        existingHashMap[outcome.photoId] = hash
                        writes.append(SimilarityHashUpsert(
                            photoId: outcome.photoId,
                            hashHex: hash,
                            fileSize: stat.size,
                            fileMtimeMs: stat.mtimeMs
                        ))
                    }
                    if flight.signal.aborted { return }   // 取消检查点：解码批落库前
                    if !writes.isEmpty {
                        try await dependencies.similarityStore.upsertHashes(sessionId: sessionId, hashes: writes)
                    }
                    onProgress?(min(offset, uncachedPhotos.count), uncachedPhotos.count, "similarity.hash")
                }

                onProgress?(uncachedPhotos.count, uncachedPhotos.count, "similarity.hash-done")
            }

            if flight.signal.aborted { return }

            let entries: [HashEntry] = photosSnapshot.compactMap { photo in
                guard let hash = existingHashMap[photo.id] else { return nil }
                return HashEntry(photoId: photo.id, hash: hash)
            }
            if entries.isEmpty { throw SimilarityError.noHashData }

            onProgress?(0, entries.count, "similarity.cluster")
            // ⑤ 聚类决策 + 执行（同步 CPU 全部出 actor）。
            let clustered = try await clusterEntries(
                sessionId: sessionId,
                entries: entries,
                threshold: params.threshold,
                minGroupSize: params.minGroupSize,
                groupingMode: params.groupingMode,
                onProgress: onProgress
            )
            // 取消检查点：聚类返回后（对齐 TS worker 拒绝路径；abort 恰在聚类
            // 结束后发生时不落库，比 TS 更严格，保留）。
            if flight.signal.aborted { throw JobCancelledError() }

            onProgress?(entries.count, entries.count, "similarity.cluster-done")

            let pathMap = Dictionary(uniqueKeysWithValues: photosSnapshot.map { ($0.id, $0.filepath) })
            let built = try await Self.buildStoredResult(
                rawGroups: clustered.groups,
                rawUngrouped: clustered.ungrouped,
                pathMap: pathMap,
                threshold: params.threshold,
                minGroupSize: params.minGroupSize,
                groupingMode: params.groupingMode,
                precomputed: false,
                compactGroupsJson: false
            )

            _ = try await dependencies.similarityStore.replaceResult(
                sessionId: sessionId,
                groupsJson: built.groupsJson,
                statsJson: built.statsJson,
                threshold: params.threshold,
                minGroupSize: params.minGroupSize,
                memberships: built.memberships
            )

            try await dependencies.sessionStore.updateAnalysisStatus(id: sessionId, status: "done")
            runStatus = "ok"

            // 邻域阈值档 best-effort：失败/取消不影响已保存的主结果。
            do {
                try await precomputeNeighborTiers(
                    sessionId: sessionId,
                    entries: entries,
                    pathMap: pathMap,
                    threshold: params.threshold,
                    minGroupSize: params.minGroupSize,
                    groupingMode: params.groupingMode,
                    signal: flight.signal,
                    onProgress: onProgress
                )
            } catch {
                if flight.signal.aborted { return }
                GatherLogger.log("Similarity neighbor threshold precomputation failed: \(error)", level: .warn)
            }
        } catch {
            // 迟到 catch 不得覆写后继 flight 的状态：generation 守卫。
            if isCurrent(flight, for: sessionId) {
                do {
                    try await dependencies.sessionStore.updateAnalysisStatus(
                        id: sessionId,
                        status: flight.signal.aborted ? "cancelled" : "failed"
                    )
                } catch {
                    GatherLogger.log("Similarity session status write failed: \(error)", level: .warn)
                }
            }
            throw error
        }
    }

    // MARK: - recluster

    /// 阈值重聚类：复用已有 hash，不重算（不注册 flight，与旧实现一致）。
    public func recluster(
        sessionId: String,
        threshold: Double,
        minGroupSize: Double,
        groupingMode: SimilarityGroupingMode = .global
    ) async throws -> SimilarityResult {
        try SimilarityValidation.validate(threshold: threshold, minGroupSize: minGroupSize)
        let thresholdValue = Int(threshold)
        let minGroupSizeValue = Int(minGroupSize)

        let existing = try await dependencies.similarityStore.latestResult(sessionId: sessionId)
        if existing == nil { throw SimilarityError.noResults }

        let photos = PhotoAssets.collapse(
            try await dependencies.photoStore.getBySessionProjection(sessionId: sessionId)
        )
        let hashRows = try await dependencies.similarityStore.hashes(sessionId: sessionId)
        var hashMap: [String: String] = [:]
        hashMap.reserveCapacity(hashRows.count)
        for row in hashRows { hashMap[row.photoId] = row.hashHex }

        let entries: [HashEntry] = photos.compactMap { photo in
            guard let hash = hashMap[photo.id] else { return nil }
            return HashEntry(photoId: photo.id, hash: hash)
        }
        if entries.isEmpty { throw SimilarityError.noHashRecluster }

        let clustered = try await clusterEntries(
            sessionId: sessionId,
            entries: entries,
            threshold: thresholdValue,
            minGroupSize: minGroupSizeValue,
            groupingMode: groupingMode,
            onProgress: nil
        )
        let pathMap = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })
        let built = try await Self.buildStoredResult(
            rawGroups: clustered.groups,
            rawUngrouped: clustered.ungrouped,
            pathMap: pathMap,
            threshold: thresholdValue,
            minGroupSize: minGroupSizeValue,
            groupingMode: groupingMode,
            precomputed: false,
            compactGroupsJson: false
        )

        _ = try await dependencies.similarityStore.replaceResult(
            sessionId: sessionId,
            groupsJson: built.groupsJson,
            statsJson: built.statsJson,
            threshold: thresholdValue,
            minGroupSize: minGroupSizeValue,
            memberships: built.memberships
        )

        try await dependencies.sessionStore.updateAnalysisStatus(id: sessionId, status: "done")

        do {
            try await precomputeNeighborTiers(
                sessionId: sessionId,
                entries: entries,
                pathMap: pathMap,
                threshold: thresholdValue,
                minGroupSize: minGroupSizeValue,
                groupingMode: groupingMode,
                signal: nil,
                onProgress: nil
            )
        } catch {
            GatherLogger.log("Similarity neighbor threshold precomputation failed: \(error)", level: .warn)
        }

        return built.result
    }

    // MARK: - cancel

    /// TS: cancel —— analysis_status 是与人脸分析共享的单列；只有本模块确有
    /// 在飞 run 时才写 'cancelled'（排队的 job 取消或人脸分析期间的取消不得
    /// 翻转人脸状态）。
    public func cancel(sessionId: String, markStatus: Bool = false) async throws {
        let flight = flights[sessionId]
        let hadFlight = flight != nil
        flight?.signal.abort()
        if hadFlight || markStatus {
            try await dependencies.sessionStore.updateAnalysisStatus(id: sessionId, status: "cancelled")
        }
    }

    // MARK: - 读路径

    /// 便宜的存在性检查：只查一行索引，不触成员表/照片投影/结果 payload。
    public func hasResult(sessionId: String, threshold: Int? = nil) async throws -> Bool {
        try await latestResultRow(sessionId: sessionId, threshold: threshold) != nil
    }

    /// 惰性结果装配：成员表优先；groups_json 仅在成员表出现前的旧行兜底。
    public func getResult(sessionId: String, threshold: Int? = nil) async throws -> SimilarityResult? {
        guard let row = try await latestResultRow(sessionId: sessionId, threshold: threshold) else {
            return nil
        }
        // 成员表是组结构的权威来源；只有在成员行存在时才需要照片投影
        // （ungrouped = 折叠资产减成员表）。畸形 stats/groups_json 抛错对齐
        // TS JSON.parse（SimilarityAssembler 先解析 stats）。
        let members = try await dependencies.similarityStore.groupMembers(sessionId: sessionId, resultId: row.id)
        let photos: [PhotoProjection]
        if members == nil {
            photos = []
        } else {
            photos = try await dependencies.photoStore.getBySessionProjection(sessionId: sessionId)
        }
        return try SimilarityAssembler.assembleResult(
            statsJson: row.statsJson,
            groupsJson: row.groupsJson,
            members: members,
            photos: photos
        )
    }

    /// 簇状态版本（ROADMAP 1.3）：供诊断与上层观测（版本号 / 连续增量次数 /
    /// 参数指纹）；无状态返回 nil。
    public func clusterMeta(sessionId: String) async throws -> SimilarityClusterMetaRecord? {
        try await dependencies.similarityStore.loadClusterSnapshot(sessionId: sessionId)?.meta
    }

    // MARK: - 聚类决策（增量 / 全量）

    /// 聚类决策 + 执行：状态参数匹配且连续增量次数未达收敛间隔时走
    /// IncrementalClusterer 邻域局部更新；否则全量重聚类并重建状态。
    /// 增量失败（状态损坏 / 非法哈希）退化为全量，不阻塞分析。
    private func clusterEntries(
        sessionId: String,
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        onProgress: ProgressHandler?
    ) async throws -> ClusterResult {
        let snapshot = try await dependencies.similarityStore.loadClusterSnapshot(sessionId: sessionId)
        let decision = SimilarityClusterPlan.decision(
            snapshot: snapshot,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            convergenceIntervalSetting: dependencies.getNumber(
                Self.convergenceIntervalKey,
                SimilarityClusterPlan.defaultConvergenceInterval
            )
        )

        if case let .incremental(version, incrementalUpdates) = decision, let snapshot {
            do {
                let state = snapshot.state
                // 增量更新与结果装配均为同步 CPU → 出 actor。
                let outcome = try await Self.runDetached {
                    try IncrementalClusterer.update(
                        state: state, entries: entries,
                        minGroupSize: minGroupSize, threshold: threshold
                    )
                }
                let result = try await Self.runDetached {
                    IncrementalClusterer.result(
                        state: outcome.state, entries: entries, minGroupSize: minGroupSize
                    )
                }
                try await dependencies.similarityStore.replaceClusterState(
                    sessionId: sessionId,
                    threshold: threshold,
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode.rawValue,
                    version: version,
                    incrementalUpdates: incrementalUpdates,
                    state: outcome.state
                )
                let summary = outcome.summary
                GatherLogger.log(
                    "Similarity incremental clustering: added=\(summary.addedCount) removed=\(summary.removedCount) changed=\(summary.changedCount) recomputed=\(summary.recomputedComponentCount) reused=\(summary.reusedComponentCount) version=\(version)",
                    level: .info
                )
                return result
            } catch {
                GatherLogger.log("Similarity incremental clustering fell back to full: \(error)", level: .warn)
            }
        }

        // 全量路径：首次 / 参数指纹不匹配 / 达到收敛间隔 / sequential /
        // 增量失败回退。版本号语义与旧实现一致：旧版本 + 1、增量计数清零。
        let fullVersion: Int
        if case let .full(version) = decision {
            fullVersion = version
        } else {
            fullVersion = (snapshot?.meta.version ?? 0) + 1
        }

        let clustered = try await Self.runCluster(
            entries: entries,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            onProgress: onProgress,
            provider: providers.cluster
        )

        if groupingMode == .global {
            do {
                let state = try await Self.runDetached {
                    try IncrementalClusterer.buildState(
                        entries: entries, minGroupSize: minGroupSize, threshold: threshold
                    )
                }
                try await dependencies.similarityStore.replaceClusterState(
                    sessionId: sessionId,
                    threshold: threshold,
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode.rawValue,
                    version: fullVersion,
                    incrementalUpdates: 0,
                    state: state
                )
            } catch {
                // 状态落库属于加速设施：失败不影响已算出的结果（下次全量重来）。
                GatherLogger.log("Similarity cluster state persist failed: \(error)", level: .warn)
                do {
                    try await dependencies.similarityStore.deleteClusterState(sessionId: sessionId)
                } catch {
                    GatherLogger.log("Similarity cluster state cleanup failed: \(error)", level: .warn)
                }
            }
        } else {
            // sequential 模式没有增量设施（前缀 run 语义），清状态强制下次全量。
            do {
                try await dependencies.similarityStore.deleteClusterState(sessionId: sessionId)
            } catch {
                GatherLogger.log("Similarity cluster state cleanup failed: \(error)", level: .warn)
            }
        }
        return clustered
    }

    // MARK: - 邻域阈值档

    /// 邻域阈值档 best-effort：一次 multiCluster 调用覆盖全部档位（距离与阈值
    /// 无关，只判定不同），逐档统一替换；每档写前检查取消。
    private func precomputeNeighborTiers(
        sessionId: String,
        entries: [HashEntry],
        pathMap: [String: String],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        signal: JobAbortSignal?,
        onProgress: ProgressHandler?
    ) async throws {
        if signal?.aborted ?? false { return }

        let tiers = SimilarityClusterPlan.neighborTiers(threshold: threshold)
        if tiers.isEmpty { return }

        let results = try await Self.runMultiCluster(
            entries: entries,
            thresholds: tiers,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            onProgress: onProgress,
            provider: providers.multiCluster
        )
        guard results.count == tiers.count else {
            GatherLogger.log(
                "Similarity neighbor tier provider returned \(results.count) results for \(tiers.count) tiers",
                level: .warn
            )
            return
        }

        for (index, tier) in tiers.enumerated() {
            if signal?.aborted ?? false { return }   // 取消检查点：每邻域档写前
            let built = try await Self.buildStoredResult(
                rawGroups: results[index].groups,
                rawUngrouped: results[index].ungrouped,
                pathMap: pathMap,
                threshold: tier,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: true,
                compactGroupsJson: true
            )
            _ = try await dependencies.similarityStore.replaceResultForThreshold(
                sessionId: sessionId,
                groupsJson: built.groupsJson,
                statsJson: built.statsJson,
                threshold: tier,
                minGroupSize: minGroupSize,
                memberships: built.memberships
            )
        }
    }

    // MARK: - 内部助手

    private func latestResultRow(sessionId: String, threshold: Int?) async throws -> SimilarityResultRecord? {
        if let threshold {
            return try await dependencies.similarityStore.result(sessionId: sessionId, threshold: threshold)
        }
        return try await dependencies.similarityStore.latestResult(sessionId: sessionId)
    }

    /// generation 守卫：只有当前持有该会话的 flight 才能写状态 / 终态化 run / 释放。
    private func isCurrent(_ flight: Flight, for sessionId: String) -> Bool {
        flights[sessionId]?.id == flight.id
    }

    /// TS: analysis_runs.params 序列化；encode 失败必须抛（旧实现静默 "{}"）。
    private static func encodeParams(_ params: SimilarityAnalysisParams) throws -> String {
        let data = try JSONEncoder().encode(params)
        return String(decoding: data, as: UTF8.self)
    }

    /// 设置值安全整数化：非有限 / NaN / 越界退化为默认值后再 clamp（旧实现
    /// Int(NaN) 会陷阱）。
    private static func intSetting(_ raw: Double, fallback: Int, bounds: ClosedRange<Int>) -> Int {
        guard let value = Int(exactly: raw.rounded(.towardZero)) else { return fallback }
        return min(bounds.upperBound, max(bounds.lowerBound, value))
    }

    /// 同步 CPU / 阻塞 IO 出 actor（设计 §0 反模式禁令）。
    private static func runDetached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility, operation: body).value
    }

    /// 协议枚举 → 聚类引擎枚举（本地映射，避免依赖旧服务的内部扩展）。
    private static func hashMode(_ mode: SimilarityGroupingMode) -> HashGroupingMode {
        switch mode {
        case .sequential: .sequential
        case .global: .global
        }
    }

    /// 单档聚类：provider 为同步 CPU，出 actor 执行。
    private static func runCluster(
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        onProgress: ProgressHandler?,
        provider: @escaping ClusterProvider
    ) async throws -> ClusterResult {
        let mode = hashMode(groupingMode)
        return try await Task.detached(priority: .utility) {
            try provider(entries, threshold, minGroupSize, mode) { current, total in
                onProgress?(current, total, "similarity.cluster")
            }
        }.value
    }

    /// 多档聚类：一次调用覆盖全部档位（与旧实现一致，不再逐档 O(n²)）。
    private static func runMultiCluster(
        entries: [HashEntry],
        thresholds: [Int],
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        onProgress: ProgressHandler?,
        provider: @escaping MultiClusterProvider
    ) async throws -> [ClusterResult] {
        let mode = hashMode(groupingMode)
        return try await Task.detached(priority: .utility) {
            try provider(entries, thresholds, minGroupSize, mode) { current, total in
                onProgress?(current, total, "similarity.thresholds")
            }
        }.value
    }

    /// 结果装配（纯函数）：groups_json/stats_json 编码可能很大 → 出 actor；
    /// encode 失败抛错（旧实现 try? 吞错落 "{}"）。
    private static func buildStoredResult(
        rawGroups: [[String]],
        rawUngrouped: [String],
        pathMap: [String: String],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        precomputed: Bool,
        compactGroupsJson: Bool
    ) async throws -> SimilarityBuiltResult {
        try await Task.detached(priority: .utility) {
            try SimilarityAssembler.build(
                rawGroups: rawGroups,
                rawUngrouped: rawUngrouped,
                pathMap: pathMap,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: precomputed,
                compactGroupsJson: compactGroupsJson
            )
        }.value
    }

    /// 文件统计（索引值优先，未索引照片落盘 stat）；stat 属阻塞 IO → 出 actor。
    private static func scanSourceStats(_ photos: [PhotoProjection]) async -> [String: SimilaritySourceStat] {
        await Task.detached(priority: .utility) {
            var stats: [String: SimilaritySourceStat] = [:]
            stats.reserveCapacity(photos.count)
            for photo in photos {
                if photo.status != "missing" && photo.checksumFileSize > 0 {
                    stats[photo.id] = SimilaritySourceStat(
                        size: photo.checksumFileSize,
                        mtimeMs: photo.checksumFileMtimeMs
                    )
                } else if let stat = tsStat(photo.filepath) {
                    stats[photo.id] = SimilaritySourceStat(size: Int(stat.size), mtimeMs: stat.mtimeMs)
                }
            }
            return stats
        }.value
    }

    /// 批内并发解码（窗口 = 设置值）：缩略图 provider 为 async 端口，
    /// 组内子任务不占用 actor 执行器。
    private static func decodeBatch(
        _ batch: [PhotoProjection],
        previewMaxDimension: Int,
        sourceStats: [String: SimilaritySourceStat],
        thumbnail: @escaping ThumbnailProvider
    ) async -> [DecodeOutcome] {
        await withTaskGroup(of: DecodeOutcome.self, returning: [DecodeOutcome].self) { group in
            for photo in batch {
                group.addTask {
                    let pixels = await thumbnail(photo.filepath, previewMaxDimension)
                    return DecodeOutcome(photoId: photo.id, pixels: pixels, stat: sourceStats[photo.id])
                }
            }
            var all: [DecodeOutcome] = []
            all.reserveCapacity(batch.count)
            for await outcome in group { all.append(outcome) }
            return all
        }
    }

    /// 单项解码结果（值类型，跨组内子任务传递）。
    private struct DecodeOutcome: Sendable {
        let photoId: String
        let pixels: [UInt8]?
        let stat: SimilaritySourceStat?
    }
}
