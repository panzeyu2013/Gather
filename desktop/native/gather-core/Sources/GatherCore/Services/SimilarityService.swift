// desktop/native/gather-core/Sources/GatherCore/Services/SimilarityService.swift
// TS 源: desktop/src/main/services/similarity/similarity.service.ts（Phase 3.3 移植，
// 算法已随 2.3 下沉 ClusterEngine / DHash）
//
// 移植差异说明（2026-08-10 逐模块对账结论，均为有意取舍）：
// - TS 的图片解码（sharp 缩略图）与 worker 聚类经注入的 thumbnailProvider /
//   clusterProvider 接入，本文件零图片/线程依赖，Linux 可单测。
// - thumbnailProvider 返回 9x8 灰度像素网格（72 字节），对应 TS
//   computeBatchDHash 的输入（sharp resize 9x8 + grayscale 之后）。
// - 取消语义对齐：pre-cluster 阶段 abort 后直接 return（TS 早退路径，
//   cancel() 已写 'cancelled'）；cluster 期间 abort 以 JobCancelledError 抛出
//   （对齐 TS worker 拒绝路径），catch 写 'cancelled'。唯一竞态差异：
//   abort 恰在 cluster 结束后、落库前发生——TS 会保存结果并写 'done'
//   （worker 已 settle），Swift 在 cluster 返回后补查 signal 抛取消、
//   不落库（更严格，保留）。
// - 聚类为同步 CPU 调用（ClusterEngine 为纯函数），helper 层可自行派发后台；
//   TS worker 的 no-progress 超时（60s~15min）属 worker 层职责，Swift 侧
//   由 AnalysisWorker/helper 层补等价看门狗，不在本服务内。
// - catch/finally 内的状态写与 run 终态用 try? 吞次生错误（TS 会覆盖原错误，
//   更稳，保留）。
// - JSON 载荷（analysis_runs.params / groups_json / stats_json）经
//   JSONEncoder 输出，键序不保证与 TS JSON.stringify 的插入序一致；所有
//   消费方均按 JSON 语义解析（getLatest 的 precomputed 子串匹配、getResult
//   逐键读取），字节序无影响。
import Foundation

public enum SimilarityServiceError: Error, Equatable {
    case thresholdInvalid
    case minGroupInvalid
    case analysisRunning
    case noPhotos
    case noHashData
    case noResults
    case noHashRecluster
}

/// TS 错误消息逐字对齐（executor 失败路径经 JobService 以 String(describing:)
/// 记录为 errorMessage，必须等于 TS error.message）。
extension SimilarityServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .thresholdInvalid: "SIM_THRESHOLD_INVALID"
        case .minGroupInvalid: "SIM_MIN_GROUP_INVALID"
        case .analysisRunning: "SIM_ANALYSIS_RUNNING"
        case .noPhotos: "SIM_NO_PHOTOS"
        case .noHashData: "SIM_NO_HASH_DATA"
        case .noResults: "SIM_NO_RESULTS"
        case .noHashRecluster: "SIM_NO_HASH_RECLUSTER"
        }
    }
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension SimilarityServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .thresholdInvalid: .SIM_THRESHOLD_INVALID
        case .minGroupInvalid: .SIM_MIN_GROUP_INVALID
        case .analysisRunning: .SIM_ANALYSIS_RUNNING
        case .noPhotos: .SIM_NO_PHOTOS
        case .noHashData: .SIM_NO_HASH_DATA
        case .noResults: .SIM_NO_RESULTS
        case .noHashRecluster: .SIM_NO_HASH_RECLUSTER
        }
    }
}
/// TS: SimilarityResult（相似度结果，非协议类型；sim.result / sim.recluster
/// 经 IPC 原样序列化 → Codable 合成 key 与 TS 逐字相同）。
public struct SimilarityResult: Codable, Equatable, Sendable {
    public let groups: [SimilarityGroup]
    public let ungrouped: [SimilarityImage]
    public let stats: SimilarityResultStats

    public init(groups: [SimilarityGroup], ungrouped: [SimilarityImage], stats: SimilarityResultStats) {
        self.groups = groups
        self.ungrouped = ungrouped
        self.stats = stats
    }
}

/// 协议枚举 → 聚类引擎枚举（两枚举值集相同，逐值映射）。
extension HashGroupingMode {
    init(_ mode: SimilarityGroupingMode) {
        switch mode {
        case .sequential: self = .sequential
        case .global: self = .global
        }
    }
}

/// TS: validateSimilarityParameters。参数类型为 Double 对齐 TS number：
/// Number.isInteger 校验（拒绝 NaN/∞/小数），通过后调用方再安全转 Int。
public func validateSimilarityParameters(threshold: Double, minGroupSize: Double) throws {
    if threshold.isNaN || threshold.isInfinite || threshold.rounded() != threshold || threshold < 0 || threshold > 64 {
        throw SimilarityServiceError.thresholdInvalid
    }
    if minGroupSize.isNaN || minGroupSize.isInfinite || minGroupSize.rounded() != minGroupSize || minGroupSize < 2 {
        throw SimilarityServiceError.minGroupInvalid
    }
}

public final class SimilarityService {
    /// TS: REUSE_HASH_CHUNK_SIZE。
    private static let reuseHashChunkSize = 400
    /// TS: NEIGHBOR_TIER_STEPS。
    private static let neighborTierSteps = [8, 4, -4, -8]

    /// TS: (filepath, maxDimension) → 9x8 灰度像素网格（72 字节），失败返回 nil。
    public typealias ThumbnailProvider = (String, Int) async -> [UInt8]?
    /// TS: clusterHashesInWorker。
    public typealias ClusterProvider = ([HashEntry], Int, Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> ClusterResult
    /// TS: clusterHashesInWorkerMulti。
    public typealias MultiClusterProvider = ([HashEntry], [Int], Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> [ClusterResult]
    /// TS: onProgress(current, total, message)。
    public typealias ProgressHandler = (Int, Int, String) -> Void

    private let photoRepo: PhotoRepo
    private let sessionRepo: SessionRepo
    private let similarityResultRepo: SimilarityResultRepo
    private let clusterStateRepo: SimilarityClusterStateRepo
    private let connection: DBConnection
    /// TS: SettingsService.getNumber 注入。
    private let getNumber: (String, Double) -> Double
    private let thumbnailProvider: ThumbnailProvider
    private let clusterProvider: ClusterProvider
    private let multiClusterProvider: MultiClusterProvider

    /// TS: controllers（Map<sessionId, AbortController>）。
    private var controllers: [String: JobAbortSignal] = [:]
    private let controllersLock = NSLock()

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func controller(for sessionId: String) -> JobAbortSignal? {
        controllersLock.lock()
        defer { controllersLock.unlock() }
        return controllers[sessionId]
    }

    private func registerController(_ signal: JobAbortSignal, for sessionId: String) {
        controllersLock.lock()
        controllers[sessionId] = signal
        controllersLock.unlock()
    }

    private func removeControllerIfCurrent(_ signal: JobAbortSignal, for sessionId: String) {
        controllersLock.lock()
        if controllers[sessionId] === signal {
            controllers.removeValue(forKey: sessionId)
        }
        controllersLock.unlock()
    }

    public init(
        photoRepo: PhotoRepo,
        sessionRepo: SessionRepo,
        similarityResultRepo: SimilarityResultRepo,
        clusterStateRepo: SimilarityClusterStateRepo,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        thumbnailProvider: @escaping ThumbnailProvider = { _, _ in nil },
        clusterProvider: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        },
        multiClusterProvider: @escaping MultiClusterProvider = { entries, thresholds, minGroupSize, mode, onProgress in
            try ClusterEngine.clusterByHashMulti(
                entries: entries, thresholds: thresholds, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        }
    ) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.similarityResultRepo = similarityResultRepo
        self.clusterStateRepo = clusterStateRepo
        self.connection = connection
        self.getNumber = getNumber
        self.thumbnailProvider = thumbnailProvider
        self.clusterProvider = clusterProvider
        self.multiClusterProvider = multiClusterProvider
    }

    /// 全量分析：hash 复用 → 缺失 hash 解码计算 → 聚类 → 落结果 →
    /// 邻域阈值档预计算（best-effort）。threshold/minGroupSize 为 Double
    /// 对齐 TS number；validate 通过后安全转 Int。
    public func analyze(
        sessionId: String,
        threshold: Double? = nil,
        minGroupSize: Double? = nil,
        groupingMode: SimilarityGroupingMode? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws {
        // 占用检查保持 TS 顺序；参数校验移到 controller 注册之前。
        // TS 源在注册之后才 validate（validate 在 try/defer 之外）——校验
        // 失败时 controller 不清理，该会话永久 SIM_ANALYSIS_RUNNING。
        // 此处为有意修复（与 TS 的差异：非法参数不会泄漏占用）。
        if controller(for: sessionId) != nil { throw SimilarityServiceError.analysisRunning }

        let thresholdValue = threshold ?? getNumber("default_threshold", 10)
        let minGroupSizeValue = minGroupSize ?? getNumber("default_min_group_size", 2)
        let groupingMode = groupingMode ?? .global

        try validateSimilarityParameters(threshold: thresholdValue, minGroupSize: minGroupSizeValue)
        let threshold = Int(thresholdValue)
        let minGroupSize = Int(minGroupSizeValue)

        let signal = JobAbortSignal()
        registerController(signal, for: sessionId)

        var runId: Int64 = 0
        var runStatus: String = "failed"
        // TS finally：早退（abort）与异常路径都必须落 run 终态并释放占用。
        defer {
            if runId != 0 {
                try? finalizeAnalysisRun(runId: runId, status: runStatus)
            }
            removeControllerIfCurrent(signal, for: sessionId)
        }
        do {
            try sessionRepo.updateAnalysisStatus(id: sessionId, status: "running")

            // 照片与 index_seq 快照共享一个读事务（design §8）：
            // 快照保证 run.index_seq 与本次分析的照片一致。
            let snapshot: (photos: [PhotoProjectionRow], indexSeq: Int) = try connection.transaction {
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

            let existingHashes = try connection.prepare(
                "SELECT photo_id, hash_hex, file_size, file_mtime_ms FROM similarity_hashes WHERE session_id = ?"
            ).query([.text(sessionId)]).map { row in
                SimilarityHashRow(
                    photoId: row[0].textValue ?? "",
                    hashHex: row[1].textValue ?? "",
                    fileSize: Int(row[2].intValue ?? 0),
                    fileMtimeMs: row[3].doubleValue ?? 0
                )
            }

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
                connection: connection,
                sessionId: sessionId,
                photos: snapshot.photos,
                sourceStats: sourceStats,
                existingHashMap: &existingHashMap
            )

            let uncachedPhotos = snapshot.photos.filter { existingHashMap[$0.id] == nil }
            if !uncachedPhotos.isEmpty {
                if signal.aborted { return }

                onProgress?(0, uncachedPhotos.count, "similarity.hash")
                let insertStmt = try connection.prepare("""
                    INSERT INTO similarity_hashes
                      (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, photo_id) DO UPDATE SET
                      hash_hex = excluded.hash_hex,
                      file_size = excluded.file_size,
                      file_mtime_ms = excluded.file_mtime_ms
                  """)

                let decodeBatchSize = min(32, max(1, Int(getNumber("similarity_decode_concurrency", 4))))
                let previewMaxDimension = min(2048, max(64, Int(getNumber("similarity_preview_max_dimension", 256))))

                var offset = 0
                while offset < uncachedPhotos.count {
                    if signal.aborted { return }
                    let batch = Array(uncachedPhotos[offset..<min(offset + decodeBatchSize, uncachedPhotos.count)])
                    offset += decodeBatchSize

                    var insertRows: [SimilarityHashInsert] = []
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
                        insertRows.append(SimilarityHashInsert(
                            sessionId: sessionId, photoId: result.photoId, hash: hash,
                            fileSize: stat.size, fileMtimeMs: stat.mtimeMs
                        ))
                    }
                    if signal.aborted { return }
                    if !insertRows.isEmpty {
                        try connection.transaction {
                            for row in insertRows {
                                _ = try insertStmt.run([
                                    .text(row.sessionId), .text(row.photoId), .text(row.hash),
                                    .int(Int64(row.fileSize)), .real(row.fileMtimeMs),
                                ])
                            }
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
            let clustered = try clusterEntries(
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
                rawGroups: clustered.groups,
                rawUngrouped: clustered.ungrouped,
                pathMap: pathMap,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: false
            )

            _ = try similarityResultRepo.replace(
                sessionId: sessionId,
                groupsJson: built.groupsJson,
                statsJson: built.statsJson,
                threshold: threshold,
                minGroupSize: minGroupSize,
                memberships: built.memberships
            )

            try sessionRepo.updateAnalysisStatus(id: sessionId, status: "done")
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
        } catch {
            try? sessionRepo.updateAnalysisStatus(
                id: sessionId,
                status: signal.aborted ? "cancelled" : "failed"
            )
            throw error
        }
    }

    /// TS: reuseSimilarityHashes —— 按 asset_file_id 分块批量读，消除逐照片 N+1；
    /// 目标照片与来源照片同资产文件且 size/mtime 一致时复用来源 hash。
    public static func reuseSimilarityHashes(
        connection: DBConnection,
        sessionId: String,
        photos: [PhotoProjectionRow],
        sourceStats: [String: (size: Int, mtimeMs: Double)],
        existingHashMap: inout [String: String]
    ) throws -> Int {
        let photoRows = try connection.prepare(
            "SELECT id, asset_file_id FROM photos WHERE session_id = ? AND asset_file_id IS NOT NULL"
        ).query([.text(sessionId)])
        var assetFileByPhoto: [String: String] = [:]
        var assetFileIds: [String] = []
        var seenAssetFiles = Set<String>()
        for row in photoRows {
            guard let id = row[0].textValue, let assetFileId = row[1].textValue else { continue }
            assetFileByPhoto[id] = assetFileId
            if seenAssetFiles.insert(assetFileId).inserted { assetFileIds.append(assetFileId) }
        }

        // 每个资产文件分块一次批量读：与任何目标照片共享资产文件的全部相似 hash。
        var rowsByAssetFile: [String: [HashCandidate]] = [:]
        for chunkStart in stride(from: 0, to: assetFileIds.count, by: reuseHashChunkSize) {
            let chunk = Array(assetFileIds[chunkStart..<min(chunkStart + reuseHashChunkSize, assetFileIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT h.id AS hash_id, h.photo_id, h.hash_hex, h.file_size, h.file_mtime_ms, p.asset_file_id
                FROM similarity_hashes h
                JOIN photos p ON h.photo_id = p.id
                WHERE p.asset_file_id IN (\(placeholders))
              """).query(chunk.map { .text($0) })
            for row in rows {
                guard let assetFileId = row[5].textValue else { continue }
                rowsByAssetFile[assetFileId, default: []].append(HashCandidate(
                    id: row[0].intValue ?? 0,
                    photoId: row[1].textValue ?? "",
                    hashHex: row[2].textValue ?? "",
                    fileSize: Int(row[3].intValue ?? 0),
                    fileMtimeMs: row[4].doubleValue ?? 0
                ))
            }
        }

        let saveStmt = try connection.prepare("""
            INSERT INTO similarity_hashes
              (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id, photo_id) DO UPDATE SET
              hash_hex = excluded.hash_hex,
              file_size = excluded.file_size,
              file_mtime_ms = excluded.file_mtime_ms
          """)
        var reused = 0
        try connection.transaction {
            for photo in photos {
                if existingHashMap[photo.id] != nil { continue }
                guard let sourceStat = sourceStats[photo.id],
                      let assetFileId = assetFileByPhoto[photo.id],
                      let candidates = rowsByAssetFile[assetFileId] else { continue }
                var source: HashCandidate?
                for candidate in candidates {
                    if candidate.photoId == photo.id { continue }
                    if candidate.fileSize != sourceStat.size { continue }
                    if abs(candidate.fileMtimeMs - sourceStat.mtimeMs) >= 1 { continue }
                    if source == nil || candidate.id > source!.id { source = candidate }
                }
                guard let source else { continue }
                _ = try saveStmt.run([
                    .text(sessionId), .text(photo.id), .text(source.hashHex),
                    .int(Int64(sourceStat.size)), .real(sourceStat.mtimeMs),
                ])
                existingHashMap[photo.id] = source.hashHex
                reused += 1
            }
        }
        return reused
    }

    /// 便宜的存在性检查：只查一行索引，不触成员表/照片投影/结果 payload。
    public func hasResult(sessionId: String, threshold: Int? = nil) throws -> Bool {
        let row = threshold == nil
            ? try similarityResultRepo.getLatest(sessionId: sessionId)
            : try similarityResultRepo.getByThreshold(sessionId: sessionId, threshold: threshold!)
        return row != nil
    }

    public func getResult(sessionId: String, threshold: Int? = nil) throws -> SimilarityResult? {
        let row = threshold == nil
            ? try similarityResultRepo.getLatest(sessionId: sessionId)
            : try similarityResultRepo.getByThreshold(sessionId: sessionId, threshold: threshold!)
        guard let row else { return nil }

        let stats = try parseStoredStats(row.statsJson)

        // 成员表是组结构的权威来源；groups_json 仅为成员表出现前的旧行解析。
        // 畸形 JSON 抛错对齐 TS JSON.parse（不静默降级）。
        let members = try similarityResultRepo.getGroupMembers(sessionId: sessionId, resultId: row.id)
        if members == nil {
            guard let data = row.groupsJson.data(using: .utf8) else {
                throw SimilarityServiceError.noResults
            }
            let stored = try JSONDecoder().decode(StoredGroupsJSON.self, from: data)
            return SimilarityResult(
                groups: stored.groups,
                ungrouped: stored.ungrouped ?? [],
                stats: stats
            )
        }

        var groupsByIndex: [Int: Int] = [:]
        var groups: [SimilarityGroup] = []
        for member in members! {
            if let position = groupsByIndex[member.groupIndex] {
                // 组内首个成员（最小成员 rowid）为代表，镜像 buildStoredResult。
                groups[position].images.append(SimilarityImage(
                    path: member.filepath,
                    representative: groups[position].images.isEmpty
                ))
                groups[position].count += 1
            } else {
                groupsByIndex[member.groupIndex] = groups.count
                groups.append(SimilarityGroup(
                    id: member.groupIndex + 1,
                    label: "Group \(member.groupIndex + 1)",
                    count: 1,
                    images: [SimilarityImage(path: member.filepath, representative: true)]
                ))
            }
        }

        // Ungrouped = 成员表之外的逻辑资产，镜像 analyze 写入 groups_json 的
        // 内容（折叠资产减已分组成员）；顺序跟随投影导入序。
        let memberPhotoIds = Set(members!.map(\.photoId))
        let ungrouped: [SimilarityImage] = PhotoAssets.collapse(
            try photoRepo.getBySessionProjection(sessionId: sessionId)
        )
        .filter { !memberPhotoIds.contains($0.id) }
        .map { SimilarityImage(path: $0.filepath) }

        return SimilarityResult(groups: groups, ungrouped: ungrouped, stats: stats)
    }

    /// TS: cancel —— analysis_status 是与人脸分析共享的单列；只有本模块确有
    /// 在飞 run 时才写 'cancelled'（排队的 job 取消或人脸分析期间的取消
    /// 不得翻转人脸状态）。
    public func cancel(sessionId: String, markStatus: Bool = false) throws {
        let signal = controller(for: sessionId)
        let hadController = signal != nil
        signal?.abort()
        if hadController || markStatus {
            try sessionRepo.updateAnalysisStatus(id: sessionId, status: "cancelled")
        }
    }

    /// 阈值重聚类：复用已有 hash，不重算。
    public func recluster(
        sessionId: String,
        threshold: Double,
        minGroupSize: Double,
        groupingMode: SimilarityGroupingMode = .global
    ) async throws -> SimilarityResult {
        try validateSimilarityParameters(threshold: threshold, minGroupSize: minGroupSize)
        let threshold = Int(threshold)
        let minGroupSize = Int(minGroupSize)

        let existing = try similarityResultRepo.getLatest(sessionId: sessionId)
        if existing == nil { throw SimilarityServiceError.noResults }

        let photos = PhotoAssets.collapse(try photoRepo.getBySessionProjection(sessionId: sessionId))
        let hashRows = try connection.prepare(
            "SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?"
        ).query([.text(sessionId)])
        var hashMap: [String: String] = [:]
        for row in hashRows {
            guard let photoId = row[0].textValue, let hash = row[1].textValue else { continue }
            hashMap[photoId] = hash
        }

        let entries: [HashEntry] = photos.compactMap { photo in
            guard let hash = hashMap[photo.id] else { return nil }
            return HashEntry(photoId: photo.id, hash: hash)
        }
        if entries.isEmpty { throw SimilarityServiceError.noHashRecluster }

        let clustered = try clusterEntries(
            sessionId: sessionId,
            entries: entries,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            onProgress: nil
        )
        let pathMap = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })
        let built = buildStoredResult(
            rawGroups: clustered.groups,
            rawUngrouped: clustered.ungrouped,
            pathMap: pathMap,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            precomputed: false
        )

        _ = try similarityResultRepo.replace(
            sessionId: sessionId,
            groupsJson: built.groupsJson,
            statsJson: built.statsJson,
            threshold: threshold,
            minGroupSize: minGroupSize,
            memberships: built.memberships
        )

        try sessionRepo.updateAnalysisStatus(id: sessionId, status: "done")

        do {
            try await precomputeNeighborTiers(
                sessionId: sessionId,
                entries: entries,
                pathMap: pathMap,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                signal: nil,
                onProgress: nil
            )
        } catch {
            GatherLogger.log("Similarity neighbor threshold precomputation failed: \(error)", level: .warn)
        }

        return built.result
    }

    // MARK: - 聚类决策（增量 / 全量）

    /// 簇状态版本（ROADMAP 1.3）：该会话的增量聚类状态元数据；无状态返回 nil。
    /// 供诊断与上层观测（版本号 / 连续增量次数 / 参数指纹）。
    public func clusterVersion(sessionId: String) throws -> SimilarityClusterMetaRow? {
        try clusterStateRepo.load(sessionId: sessionId)?.meta
    }

    /// 聚类决策：状态参数匹配且连续增量次数未达收敛间隔时，走 IncrementalClusterer
    /// 的邻域局部更新；否则全量重聚类并重建状态。两条路径都落库簇状态与版本号。
    /// 增量失败（状态损坏/非法哈希）退化为全量，不阻塞分析。
    private func clusterEntries(
        sessionId: String,
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        onProgress: ProgressHandler?
    ) throws -> ClusterResult {
        let snapshot = try clusterStateRepo.load(sessionId: sessionId)
        let convergenceInterval = max(1, Int(getNumber("similarity_cluster_convergence_interval", 10)))

        if groupingMode == .global,
           let snapshot,
           snapshot.matches(
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode.rawValue
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
                try clusterStateRepo.replace(
                    sessionId: sessionId,
                    threshold: threshold,
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode.rawValue,
                    version: snapshot.meta.version + 1,
                    incrementalUpdates: snapshot.meta.incrementalUpdates + 1,
                    state: outcome.state
                )
                let summary = outcome.summary
                GatherLogger.log(
                    "Similarity incremental clustering: added=\(summary.addedCount) removed=\(summary.removedCount) changed=\(summary.changedCount) recomputed=\(summary.recomputedComponentCount) reused=\(summary.reusedComponentCount) version=\(snapshot.meta.version + 1)",
                    level: .info
                )
                return result
            } catch {
                GatherLogger.log("Similarity incremental clustering fell back to full: \(error)", level: .warn)
            }
        }

        let clustered = try clusterProvider(
            entries, threshold, minGroupSize, HashGroupingMode(groupingMode),
            { current, total in onProgress?(current, total, "similarity.cluster") }
        )
        if groupingMode == .global {
            do {
                let state = try IncrementalClusterer.buildState(
                    entries: entries, minGroupSize: minGroupSize, threshold: threshold
                )
                try clusterStateRepo.replace(
                    sessionId: sessionId,
                    threshold: threshold,
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode.rawValue,
                    version: (snapshot?.meta.version ?? 0) + 1,
                    incrementalUpdates: 0,
                    state: state
                )
            } catch {
                // 状态落库属于加速设施：失败不影响已算出的结果（下次全量重来）。
                GatherLogger.log("Similarity cluster state persist failed: \(error)", level: .warn)
                try? clusterStateRepo.delete(sessionId: sessionId)
            }
        } else {
            // sequential 模式没有增量设施（前缀 run 语义），清状态强制下次全量。
            try? clusterStateRepo.delete(sessionId: sessionId)
        }
        return clustered
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
        _ = try connection.prepare("""
            INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, ?, ?, ?, ?, '', ?, 'running')
          """).run([
            .text(sessionId), .text(kind), .int(Int64(photoCount)), .int(Int64(indexSeq)),
            .text(nowISOString()), .text(String(data: data, encoding: .utf8) ?? "{}"),
        ])
        return connection.lastInsertRowid
    }

    // 取消的 run 在此以 'failed' 终态（sessions.analysis_status 在 catch 写
    // 'cancelled'）：run 记录按设计只区分 ok/failed，该分歧是刻意的——
    // 过期检测（1.4.2）一律忽略非 ok run。
    private func finalizeAnalysisRun(runId: Int64, status: String) throws {
        _ = try connection.prepare("UPDATE analysis_runs SET status = ?, finished_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISOString()), .int(runId)])
    }

    /// TS: buildStoredResult。
    private func buildStoredResult(
        rawGroups: [[String]],
        rawUngrouped: [String],
        pathMap: [String: String],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        precomputed: Bool,
        compactGroupsJson: Bool = false
    ) -> (result: SimilarityResult, groupsJson: String, statsJson: String, memberships: [(photoId: String, groupIndex: Int)]) {
        let groups: [SimilarityGroup] = rawGroups.enumerated().map { idx, memberIds in
            SimilarityGroup(
                id: idx + 1,
                label: "Group \(idx + 1)",
                count: memberIds.count,
                images: memberIds.enumerated().map { i, photoId in
                    SimilarityImage(path: pathMap[photoId] ?? "", representative: i == 0)
                }
            )
        }
        let ungrouped: [SimilarityImage] = rawUngrouped.map { photoId in
            SimilarityImage(path: pathMap[photoId] ?? "")
        }

        // 预计算邻域档永不读 groups_json：getLatest 排除之、culling 从成员表
        // 解析、getResult 也从成员表重建。逐档 stringify 多 MB payload 纯属
        // 浪费，档位行存紧凑占位（schema 要求非空串）。
        let groupsJson: String
        if compactGroupsJson {
            groupsJson = "{\"groups\":[],\"ungrouped\":[]}"
        } else {
            let payload = StoredGroupsJSON(groups: groups, ungrouped: ungrouped)
            groupsJson = String(data: (try? JSONEncoder().encode(payload)) ?? Data(), encoding: .utf8) ?? "{}"
        }
        let statsJson = String(
            data: (try? JSONEncoder().encode(StoredStatsPayload(
                totalGroups: groups.count,
                totalUngrouped: ungrouped.count,
                threshold: Double(threshold),
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: precomputed ? true : nil
            ))) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        return (
            result: SimilarityResult(
                groups: groups,
                ungrouped: ungrouped,
                stats: SimilarityResultStats(
                    totalGroups: groups.count,
                    totalUngrouped: ungrouped.count,
                    threshold: Double(threshold),
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode
                )
            ),
            groupsJson: groupsJson,
            statsJson: statsJson,
            memberships: rawGroups.enumerated().flatMap { groupIndex, photoIds in
                photoIds.map { (photoId: $0, groupIndex: groupIndex) }
            }
        )
    }

    /// 邻域阈值档：一次 pairwise 距离遍历服务全部档位（距离与阈值无关，
    /// 只判定不同），4 档预计算不再逐档重复 O(n²)。
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

        var savedTiers = Set<Int>([threshold])
        var candidates: [Int] = []
        for step in Self.neighborTierSteps {
            let tier = max(0, min(30, threshold + step))
            if !savedTiers.contains(tier) {
                savedTiers.insert(tier)
                candidates.append(tier)
            }
        }
        if candidates.isEmpty { return }

        let results = try multiClusterProvider(
            entries, candidates, minGroupSize, HashGroupingMode(groupingMode),
            { current, total in onProgress?(current, total, "similarity.thresholds") }
        )
        for (index, tier) in candidates.enumerated() {
            if signal?.aborted ?? false { return }
            let built = buildStoredResult(
                rawGroups: results[index].groups,
                rawUngrouped: results[index].ungrouped,
                pathMap: pathMap,
                threshold: tier,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: true,
                compactGroupsJson: true
            )
            _ = try similarityResultRepo.replaceForThreshold(
                sessionId: sessionId,
                groupsJson: built.groupsJson,
                statsJson: built.statsJson,
                threshold: tier,
                minGroupSize: minGroupSize,
                memberships: built.memberships
            )
        }
    }

    /// TS: getResult 的 stats 解析（Partial + 默认值；畸形 JSON 抛错对齐
    /// TS JSON.parse，不静默降级为全默认）。
    private func parseStoredStats(_ statsJson: String) throws -> SimilarityResultStats {
        guard let data = statsJson.data(using: .utf8) else {
            throw SimilarityServiceError.noResults
        }
        let stored = try JSONDecoder().decode(StoredStatsPayload.self, from: data)
        return SimilarityResultStats(
            totalGroups: stored.totalGroups ?? 0,
            totalUngrouped: stored.totalUngrouped ?? 0,
            threshold: stored.threshold ?? 0,
            minGroupSize: stored.minGroupSize ?? 2,
            groupingMode: stored.groupingMode ?? .global,
            precomputed: stored.precomputed == true
        )
    }
}

// MARK: - 私有载荷类型

/// TS: analysis_runs.params。
private struct AnalysisRunParams: Codable {
    let threshold: Int
    let minGroupSize: Int
    let groupingMode: SimilarityGroupingMode
}

/// TS: similarity_hashes 行（reuse 候选）。
private struct HashCandidate {
    let id: Int64
    let photoId: String
    let hashHex: String
    let fileSize: Int
    let fileMtimeMs: Double
}

/// TS: similarity_hashes 行（analyze 解码写入）。
private struct SimilarityHashRow {
    let photoId: String
    let hashHex: String
    let fileSize: Int
    let fileMtimeMs: Double
}

/// TS: analyze 解码写入行。
private struct SimilarityHashInsert {
    let sessionId: String
    let photoId: String
    let hash: String
    let fileSize: Int
    let fileMtimeMs: Double
}

/// TS: groups_json 载荷。
private struct StoredGroupsJSON: Codable {
    let groups: [SimilarityGroup]
    let ungrouped: [SimilarityImage]?
}

/// TS: stats_json 载荷（解析用，全可选；编码用全必填 + precomputed 可选）。
private struct StoredStatsPayload: Codable {
    let totalGroups: Int?
    let totalUngrouped: Int?
    let threshold: Double?
    let minGroupSize: Int?
    let groupingMode: SimilarityGroupingMode?
    let precomputed: Bool?
}
