// desktop/native/gather-core/Sources/GatherApplication/Services/Similarity/SimilarityService+Analyze.swift
// P1-4 收口：SimilarityService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：analyze 全流程（hash 复用 → 缺 hash 解码 → 聚类决策 → 结果落库 → 邻域档预计算）
// 与会话占用槽外部信号链接；analysis_runs 生命周期（start/finalize，仅 analyze 使用）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension SimilarityService {

    /// 全量分析：hash 复用 → 缺失 hash 解码计算 → 聚类 → 落结果 →
    /// 邻域阈值档预计算（best-effort）。threshold/minGroupSize 为 Double
    /// 对齐 TS number；validate 通过后安全转 Int。
    public func analyze(
        sessionId: String,
        threshold: Double? = nil,
        minGroupSize: Double? = nil,
        groupingMode: SimilarityGroupingMode? = nil,
        signal externalSignal: JobAbortSignal? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws {
        // 参数校验先于占用获取（TS 源在校验前注册占用，非法参数会永久泄漏占用；
        // 这里保留此前的有意修复）。
        let thresholdValue = threshold ?? getNumber("default_threshold", 10)
        let minGroupSizeValue = minGroupSize ?? getNumber("default_min_group_size", 2)
        let groupingMode = groupingMode ?? .global

        try validateSimilarityParameters(threshold: thresholdValue, minGroupSize: minGroupSizeValue)
        let threshold = Int(thresholdValue)
        let minGroupSize = Int(minGroupSizeValue)

        let slot = try acquireSlot(sessionId: sessionId)
        let signal = slot.signal
        linkExternalSignal(externalSignal, to: slot)

        var runId: Int64 = 0
        var runStatus: String = "failed"
        // TS finally：早退（abort）与异常路径都必须落 run 终态并释放占用。
        defer {
            if runId != 0 {
                try? finalizeAnalysisRun(runId: runId, status: runStatus)
            }
            releaseSlot(slot, for: sessionId)
        }
        do {
            if signal.aborted { return }

            // 照片与 index_seq 快照共享一个读事务（design §8）：
            // 快照保证 run.index_seq 与本次分析的照片一致。
            let snapshot: (photos: [PhotoProjectionRow], indexSeq: Int) = try transactions.transaction {
                (PhotoAssets.collapse(try photoRepo.getBySessionProjection(sessionId: sessionId)),
                 try sessionRepo.getIndexSeq(id: sessionId))
            }
            if snapshot.photos.isEmpty { throw SimilarityServiceError.noPhotos }
            runId = try startAnalysisRun(
                sessionId: sessionId,
                kind: "similarity",
                photoCount: snapshot.photos.count,
                indexSeq: snapshot.indexSeq,
                params: AnalysisRunParams(threshold: threshold, minGroupSize: minGroupSize, groupingMode: groupingMode)
            )

            if signal.aborted { return }

            let existingHashes = try hashes.getRecords(sessionId: sessionId)

            // 文件统计优先取自索引扫描（checksum_file_size / mtime），完整分析
            // 不再逐照片 stat（SSD 1-3s、网络卷数分钟）；只有未索引照片落盘。
            var sourceStats: [String: (size: Int, mtimeMs: Double)] = [:]
            for photo in snapshot.photos {
                if photo.status != "missing" && photo.checksumFileSize > 0 {
                    sourceStats[photo.id] = (photo.checksumFileSize, photo.checksumFileMtimeMs)
                } else if let stat = tsStat(photo.filepath) {
                    // 不可读文件走常规预览失败路径。
                    sourceStats[photo.id] = (Int(stat.size), stat.mtimeMs)
                }
            }

            var existingHashMap: [String: String] = [:]
            for row in existingHashes {
                guard let stat = sourceStats[row.photoId],
                      stat.size == row.fileSize,
                      abs(stat.mtimeMs - row.fileMtimeMs) < 1 else { continue }
                existingHashMap[row.photoId] = row.hashHex
            }
            _ = try Self.reuseSimilarityHashes(
                hashes: hashes,
                transactions: transactions,
                sessionId: sessionId,
                photos: snapshot.photos,
                sourceStats: sourceStats,
                existingHashMap: &existingHashMap
            )

            let uncachedPhotos = snapshot.photos.filter { existingHashMap[$0.id] == nil }
            if !uncachedPhotos.isEmpty {
                if signal.aborted { return }

                onProgress?(0, uncachedPhotos.count, "similarity.hash")

                let decodeBatchSize = min(32, max(1, getNumber("similarity_decode_concurrency", 4).safeInt(fallback: 4)))
                let previewMaxDimension = min(2048, max(64, getNumber("similarity_preview_max_dimension", 256).safeInt(fallback: 256)))

                var offset = 0
                while offset < uncachedPhotos.count {
                    if signal.aborted { return }
                    let batch = Array(uncachedPhotos[offset..<min(offset + decodeBatchSize, uncachedPhotos.count)])
                    offset += decodeBatchSize

                    var insertRows: [SimilarityHashWrite] = []
                    // 审计 P1-性能：批内并发解码（batch 大小即
                    // similarity_decode_concurrency 设置，4 默认）。此前
                    // for-await 顺序解码，10 万张有效并发 = 1。RAWDecoder
                    // 走 ImageIO 线程安全，sourceStats 只读并发访问安全。
                    typealias DecodeResult = (photoId: String, pixels: [UInt8]?, stat: (size: Int, mtimeMs: Double)?)
                    let results = await withTaskGroup(
                        of: DecodeResult.self,
                        returning: [DecodeResult].self
                    ) { group in
                        for photo in batch {
                            group.addTask { [thumbnailProvider, sourceStats] in
                                let pixels = await thumbnailProvider(photo.filepath, previewMaxDimension)
                                return (photo.id, pixels, sourceStats[photo.id])
                            }
                        }
                        var all: [DecodeResult] = []
                        all.reserveCapacity(batch.count)
                        for await result in group {
                            all.append(result)
                        }
                        return all
                    }
                    for result in results {
                        guard let pixels = result.pixels, let stat = result.stat else { continue }
                        let hash = DHash.compute(pixels9x8: pixels)
                        existingHashMap[result.photoId] = hash
                        insertRows.append(SimilarityHashWrite(
                            sessionId: sessionId, photoId: result.photoId, hashHex: hash,
                            fileSize: stat.size, fileMtimeMs: stat.mtimeMs
                        ))
                    }
                    if signal.aborted { return }
                    if !insertRows.isEmpty {
                        // 每批一个事务（与旧实现同边界），语句由 Repo 准备一次。
                        try transactions.transaction {
                            try hashes.upsert(insertRows)
                        }
                    }
                    onProgress?(
                        min(offset, uncachedPhotos.count),
                        uncachedPhotos.count,
                        "similarity.hash"
                    )
                }

                onProgress?(uncachedPhotos.count, uncachedPhotos.count, "similarity.hash-done")
            }

            if signal.aborted { return }

            let entries: [HashEntry] = snapshot.photos.compactMap { photo in
                guard let hash = existingHashMap[photo.id] else { return nil }
                return HashEntry(photoId: photo.id, hash: hash)
            }
            if entries.isEmpty { throw SimilarityServiceError.noHashData }

            onProgress?(0, entries.count, "similarity.cluster")
            // ROADMAP 1.3：参数匹配且未达收敛间隔时走邻域增量聚类，
            // 否则全量重聚类（首次 / 参数变化 / 定期全局收敛）。
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

            let pathMap = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0.filepath) })
            let built = buildStoredResult(
                rawGroups: decision.result.groups,
                rawUngrouped: decision.result.ungrouped,
                pathMap: pathMap,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: false
            )

            // 结果 + 簇状态单事务原子写（§4.2 修复）：不再出现「结果已替换、
            // 增量状态还是上一次」的错配窗口。
            _ = try persistClusterOutcome(
                sessionId: sessionId,
                threshold: threshold,
                minGroupSize: minGroupSize,
                built: built,
                stateUpdate: decision.stateUpdate
            )
            runStatus = "ok"

            // 邻域阈值档 best-effort：同一批 hash 再聚几次很便宜，失败/取消
            // 不影响上面已保存的主结果。
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
                if signal.aborted { return }
                GatherLogger.log("Similarity neighbor threshold precomputation failed: \(error)", level: .warn)
            }
        }
    }

    // MARK: - 内部

    /// TS: startAnalysisRun。
    private func startAnalysisRun(
        sessionId: String,
        kind: String,
        photoCount: Int,
        indexSeq: Int,
        params: AnalysisRunParams
    ) throws -> Int64 {
        let data = try JSONEncoder().encode(params)
        // 载荷编码留在应用层（params_json 的键序是契约）；落库交 AnalysisRunRepo。
        return try analysisRuns.start(
            sessionId: sessionId,
            kind: kind,
            photoCount: photoCount,
            indexSeq: indexSeq,
            paramsJson: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    // 取消/失败的 run 在此以 'failed' 终态：run 记录按设计只区分 ok/failed；
    // 取消态由 analysis_jobs（type+status）表达，过期检测（1.4.2）一律忽略非 ok run。
    private func finalizeAnalysisRun(runId: Int64, status: String) throws {
        try analysisRuns.finish(runId: runId, status: status)
    }
}

// MARK: - 运行参数

/// TS: analysis_runs.params。
private struct AnalysisRunParams: Codable {
    let threshold: Int
    let minGroupSize: Int
    let groupingMode: SimilarityGroupingMode
}
