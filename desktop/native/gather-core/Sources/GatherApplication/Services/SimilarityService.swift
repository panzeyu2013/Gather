// desktop/native/gather-core/Sources/GatherApplication/Services/SimilarityService.swift
// TS 源: desktop/src/main/services/similarity/similarity.service.ts（Phase 3.3 移植，
// 算法已随 2.3 下沉 ClusterGraph / DHash）
//
// 移植差异说明（2026-08-10 逐模块对账结论，均为有意取舍）：
// - TS 的图片解码（sharp 缩略图）与 worker 聚类经注入的 thumbnailProvider /
//   clusterProvider 接入，本文件零图片/线程依赖，Linux 可单测。
// - thumbnailProvider 返回 9x8 灰度像素网格（72 字节），对应 TS
//   computeBatchDHash 的输入（sharp resize 9x8 + grayscale 之后）。
// - 取消语义对齐：pre-cluster 阶段 abort 后直接 return；cluster 期间 abort 以
//   JobCancelledError 抛出（对齐 TS worker 拒绝路径）。唯一竞态差异：abort 恰在
//   cluster 结束后、落库前发生——TS 会保存结果，Swift 在 cluster 返回后补查
//   signal 抛取消、不落库（更严格，保留）。
// - 状态真相源（§4.2 P1 修复，方案 A）：本服务**不写** sessions.analysis_status。
//   相似度状态由 analysis_jobs 的 (type='similarity.analyze', status) 派生；
//   analyze 与 recluster 互斥由会话占用槽（OperationSlot）保证，占用中抛
//   SIM_ANALYSIS_RUNNING。analysis_runs 仅保留分析 run 记录/过期检测用途。
// - recluster 与 analyze 同级：共用占用槽、支持 job 信号（进度/取消）、结果与
//   簇状态单事务原子写；它不重算哈希、不写 analysis_runs（不改变会话的分析新鲜度）。
// - 聚类为同步 CPU 调用（ClusterGraphPipeline 为无状态 enum），helper 层可自行派发后台；
//   TS worker 的 no-progress 超时（60s~15min）属 worker 层职责，Swift 侧
//   由 AnalysisWorker/helper 层补等价看门狗，不在本服务内。
// - catch/finally 内的状态写与 run 终态用 try? 吞次生错误（TS 会覆盖原错误，
//   更稳，保留）。
// - JSON 载荷（analysis_runs.params / groups_json / stats_json）经
//   JSONEncoder 输出，键序不保证与 TS JSON.stringify 的插入序一致；所有
//   消费方均按 JSON 语义解析（getLatest 的 precomputed 子串匹配、getResult
//   逐键读取），字节序无影响。
// - 写回 / 确认 / 清理（Cut 2 / S5c-2b-3b-1）：previewWriteback / persistKeywords /
//   writebackItems / writeback / retryFailedWriteback 全部经注入的
//   SimilarityWritebackProvider（宿主为 SimilarityWritebackBridge → 交付执行器）
//   执行；confirmSync / cleanup 由 DeliveryModuleAdapter（module=.similarity）
//   执行。Confirmed<T> 门禁与“预览是否过期”仍在 API 层（LiveSimilarityAPI）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

public enum SimilarityServiceError: Error, Equatable {
    case thresholdInvalid
    case minGroupInvalid
    case analysisRunning
    case noPhotos
    case noHashData
    case noResults
    case noHashRecluster
    /// 写回 Provider 未注入（S5c-2b-2 过渡接缝；宿主接线后不可达）。
    case writebackProviderMissing
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
        case .writebackProviderMissing: "WRITEBACK_PROVIDER_NOT_INJECTED"
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
        // 与 FaceKwServiceError.writebackProviderMissing 同一映射（装配错误不伪装业务码，
        // GatherError 无专用码，见 LiveFaceAPI.translate 的 D-010 说明）。
        case .writebackProviderMissing: .WRITEBACK_OTHER_MODULE_ACTIVE
        }
    }
}
/// 相似度写回面（Cut 2 / S5c-2b-3b-1 稳定接缝）。
///
/// LiveSimilarityAPI 不再直连 WritebackService：preview / persistKeywords /
/// writebackItems / execute / retryFailed 全部经本协议进入交付执行器。宿主用
/// SimilarityWritebackBridge（module 固定 similarity）适配旧 WritebackService；
/// S5c-2b-3b-2 删除旧服务时只替换桥的实现，API 与服务接缝不变。
public protocol SimilarityWritebackProvider: Sendable {
    /// sim.preview_writeback 的交付行重建（module=similarity，pending）。
    func preview(sessionId: String) async throws -> WritebackPreview
    /// preview 的关键词合并结果落库（delivery_items.keywords）。
    func persistKeywords(items: [WritebackItem]) throws
    /// sim.writeback_items / 写回前的待写项读取（可按 xmpStatus 过滤）。
    func getItems(sessionId: String, status: String?) throws -> [WritebackItem]
    /// sim.writeback 的执行段（文件写入 + 交付项/行状态收敛）。
    func execute(sessionId: String, items: [WritebackItem]) async throws -> WritebackResult
    /// sim.retry_failed_writeback：只重放本模块 failed 项。
    func retryFailed(sessionId: String) async throws -> WritebackResult
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
    // 阈值域判定与 DuplicateService.validateDuplicateThreshold 共用
    // DHash.isValidThreshold（dHash 64 位 → 0...64 整数）。
    if !DHash.isValidThreshold(threshold) {
        throw SimilarityServiceError.thresholdInvalid
    }
    if minGroupSize.isNaN || minGroupSize.isInfinite || minGroupSize.rounded() != minGroupSize || minGroupSize < 2 {
        throw SimilarityServiceError.minGroupInvalid
    }
}

public final class SimilarityService {
    /// TS: REUSE_HASH_CHUNK_SIZE。
    static let reuseHashChunkSize = 400
    /// TS: NEIGHBOR_TIER_STEPS。
    static let neighborTierSteps = [8, 4, -4, -8]

    /// TS: (filepath, maxDimension) → 9x8 灰度像素网格（72 字节），失败返回 nil。
    /// Swift 6：解码阶段的子任务（withTaskGroup 的 sending 闭包）并发调用本
    /// provider，闭包会被捕获进子任务，故类型必须可跨并发域（@Sendable）。
    public typealias ThumbnailProvider = @Sendable (String, Int) async -> [UInt8]?
    /// TS: clusterHashesInWorker。
    /// Cut 5 / 5b-1：返回值从 ClusterResult 扩为 ClusterGraphOutcome——一次图构建
    /// 同时给出 result 与 state，decideCluster 不再为状态做第二趟 buildState。
    /// sequential 模式无图，state 为 nil（调用方清空增量状态）。
    public typealias ClusterProvider = ([HashEntry], Int, Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> ClusterGraphOutcome
    /// TS: clusterHashesInWorkerMulti。多档位共享一张并集图（global）或逐档 engine（sequential）。
    public typealias MultiClusterProvider = ([HashEntry], [Int], Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> [ClusterResult]
    /// TS: onProgress(current, total, message)。
    public typealias ProgressHandler = (Int, Int, String) -> Void

    /// P1-1：仓储依赖一律走 Persistence 端口（any XxxRepository），具体 SQLite
    /// Repo 只在组合根构造；测试可用 fake 替换。
    let photoRepo: any PhotoRepository
    let sessionRepo: any SessionRepository
    let similarityResultRepo: any SimilarityRepository
    let clusterStateRepo: any SimilarityClusterStateRepository
    /// WP3b-2：similarity_hashes 读写与 analysis_runs 生命周期下沉到 Persistence；
    /// 事务经 TransactionRunner（嵌套退化为 SAVEPOINT，语义与旧 DBConnection 一致）。
    let hashes: any SimilarityHashRepository
    let analysisRuns: any AnalysisRunRepository
    private let deliveryItems: any DeliveryRepository
    let transactions: any TransactionRunner
    /// TS: SettingsService.getNumber 注入。
    let getNumber: (String, Double) -> Double
    let thumbnailProvider: ThumbnailProvider
    let clusterProvider: ClusterProvider
    let multiClusterProvider: MultiClusterProvider
    /// 旧写回执行器（S5c-2b-2 过渡接缝；S5c-2b-3 删除）。
    private let writebackProvider: (any SimilarityWritebackProvider)?
    /// 交付适配器（WP2c：module 固定 .similarity）：writeback 镜像 + confirm/cleanup。
    private let delivery: any DeliveryModuleAdapter

    /// 会话级占用（analyze/recluster 互斥）：同一会话任一时刻只允许一个相似度
    /// 操作在飞；占用内的取消信号由本服务持有，外部 job 信号（analyze/recluster
    /// 的 context.signal）经 addHandler 链接进来。
    ///
    /// analysis_status 不再由本服务读写（§4.2 P1 修复，方案 A）：状态真相源是
    /// analysis_jobs 的 (type, status) —— analyze 与 recluster 都以
    /// type='similarity.analyze' 入队（recluster 经 checkpoint.operation 区分），
    /// 跨模块交叉写 sessions.analysis_status 的路径已整段删除。
    final class OperationSlot {
        let signal = JobAbortSignal()
    }

    private var slots: [String: OperationSlot] = [:]
    private let slotsLock = NSLock()

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    func acquireSlot(sessionId: String) throws -> OperationSlot {
        slotsLock.lock()
        defer { slotsLock.unlock() }
        if slots[sessionId] != nil { throw SimilarityServiceError.analysisRunning }
        let slot = OperationSlot()
        slots[sessionId] = slot
        return slot
    }

    func releaseSlot(_ slot: OperationSlot, for sessionId: String) {
        slotsLock.lock()
        if slots[sessionId] === slot { slots.removeValue(forKey: sessionId) }
        slotsLock.unlock()
    }

    func currentSlot(for sessionId: String) -> OperationSlot? {
        slotsLock.lock()
        defer { slotsLock.unlock() }
        return slots[sessionId]
    }

    /// 外部 job 信号 → 占用信号（任一取消都能中断在飞操作）。
    func linkExternalSignal(_ external: JobAbortSignal?, to slot: OperationSlot) {
        guard let external else { return }
        if external.aborted { slot.signal.abort() }
        external.addHandler { slot.signal.abort() }
    }

    public init(
        photoRepo: any PhotoRepository,
        sessionRepo: any SessionRepository,
        similarityResultRepo: any SimilarityRepository,
        clusterStateRepo: any SimilarityClusterStateRepository,
        hashes: any SimilarityHashRepository,
        analysisRuns: any AnalysisRunRepository,
        deliveryItems: any DeliveryRepository,
        transactions: any TransactionRunner,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        thumbnailProvider: @escaping ThumbnailProvider = { _, _ in nil },
        clusterProvider: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            // Cut 5 / 5b-2a：唯一实现——global 单趟图（result + state 同源），
            // sequential 相邻段（state = nil，调用方清空增量状态）。
            try ClusterGraphPipeline.run(
                entries: entries, threshold: threshold,
                minGroupSize: minGroupSize, mode: mode, onProgress: onProgress)
        },
        multiClusterProvider: @escaping MultiClusterProvider = { entries, thresholds, minGroupSize, mode, onProgress in
            // global 共享同一张最高档并集位图（一次 O(n²) 距离遍历）；
            // sequential 逐档相邻段扫描。
            try ClusterGraphPipeline.runTiers(
                entries: entries, thresholds: thresholds,
                minGroupSize: minGroupSize, mode: mode, onProgress: onProgress)
        },
        writebackProvider: (any SimilarityWritebackProvider)? = nil,
        delivery: any DeliveryModuleAdapter
    ) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.similarityResultRepo = similarityResultRepo
        self.clusterStateRepo = clusterStateRepo
        self.hashes = hashes
        self.analysisRuns = analysisRuns
        self.deliveryItems = deliveryItems
        self.transactions = transactions
        self.getNumber = getNumber
        self.thumbnailProvider = thumbnailProvider
        self.clusterProvider = clusterProvider
        self.multiClusterProvider = multiClusterProvider
        self.writebackProvider = writebackProvider
        // WP3b-2：不再按 connection 自建 coordinator（Application 不持 DBConnection）。
        // 组合根注入交付适配器；测试经 ServiceConstructionTestSupport 的兼容 init 装配。
        self.delivery = delivery
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
            // P1：旧行没有成员表，只能按"哪些路径已归档"过滤；没有照片行的历史路径
            // 保持可见（不能当成归档件丢掉）。归档导致成员不足的组隐藏。
            let archivedPaths = Set(
                try photoRepo.getBySessionProjection(sessionId: sessionId)
                    .filter { PhotoVisibility.isArchived(archivedAt: $0.archivedAt) }
                    .map { TSPath.normalize($0.filepath) }
            )
            let groups = stored.groups.compactMap { group -> SimilarityGroup? in
                let originalCount = group.images.count
                let images = group.images.filter {
                    !archivedPaths.contains(TSPath.normalize($0.path))
                }
                // 只为"归档导致成员不足"而隐藏；minGroupSize=1 的合法单成员组保留
                // （唯一成员也被归档时组已空，不能留下空卡片）。
                guard images.count >= 2 || (originalCount < 2 && !images.isEmpty) else { return nil }
                var filtered = group
                filtered.images = images.enumerated().map { index, image in
                    var copy = image
                    copy.representative = index == 0
                    return copy
                }
                filtered.count = filtered.images.count
                return filtered
            }
            let ungrouped = (stored.ungrouped ?? []).filter {
                !archivedPaths.contains(TSPath.normalize($0.path))
            }
            // 统计实时化（§4.2 P2）：旧行没有成员表，但计数必须与实际返回的
            // payload 一致（不读快照计数）。
            var liveStats = stats
            liveStats.totalGroups = groups.count
            liveStats.totalUngrouped = ungrouped.count
            return SimilarityResult(groups: groups, ungrouped: ungrouped, stats: liveStats)
        }

        let originalCounts = try similarityResultRepo.groupMemberCounts(
            sessionId: sessionId, resultId: row.id)
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

        // 归档让组成员不足的组隐藏（决策要求 ≥2 张）；原本就只有 1 张的合法组保留。
        groups = groups.filter { group in
            let original = originalCounts[group.id - 1] ?? group.images.count
            return group.images.count >= 2 || (original < 2 && !group.images.isEmpty)
        }

        // Ungrouped = 成员表之外的逻辑资产，镜像 analyze 写入 groups_json 的
        // 内容（折叠资产减已分组成员）；顺序跟随投影导入序。
        // P1：归档照片不参与 ungrouped（否则相似度页会把 _rejects 里的照片列出来）。
        let memberPhotoIds = Set(members!.map(\.photoId))
        let ungrouped: [SimilarityImage] = PhotoAssets.collapse(
            try photoRepo.getBySessionProjection(sessionId: sessionId)
                .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }
        )
        .filter { !memberPhotoIds.contains($0.id) }
        .map { SimilarityImage(path: $0.filepath) }

        // 统计实时化（§4.2 P2）：成员表是组结构权威来源，计数必须与本次实时
        // 重建的 groups/ungrouped 一致——落库快照在分析后新导入照片时会虚低。
        var liveStats = stats
        liveStats.totalGroups = groups.count
        liveStats.totalUngrouped = ungrouped.count
        return SimilarityResult(groups: groups, ungrouped: ungrouped, stats: liveStats)
    }

    /// TS: cancel —— 只中断本服务在飞的相似度操作（analyze/recluster 共用占用
    /// 槽）。不再写 sessions.analysis_status：状态由 analysis_jobs 派生（方案 A）。
    public func cancel(sessionId: String) throws {
        currentSlot(for: sessionId)?.signal.abort()
    }

    // MARK: - 写回 / 确认 / 清理（Cut 2 / S5c-2b-2）

    /// sim.preview_writeback 的交付段：重建本会话 similarity 模块的 pending 交付项。
    /// 结果过滤/关键词合并（buildSimilarityKeywordPlan）仍在 API 层，属于命令语义。
    public func previewWriteback(sessionId: String) async throws -> WritebackPreview {
        guard let writebackProvider else { throw SimilarityServiceError.writebackProviderMissing }
        return try await writebackProvider.preview(sessionId: sessionId)
    }

    /// sim.preview_writeback 的关键词落库段（persist 与 preview 的收尾是同一批行）。
    public func persistKeywords(items: [WritebackItem]) throws {
        guard let writebackProvider else { throw SimilarityServiceError.writebackProviderMissing }
        try writebackProvider.persistKeywords(items: items)
    }

    /// sim.writeback_items：本会话 similarity 模块的交付项（UI 列表）。
    public func writebackItems(sessionId: String, status: String? = nil) throws -> [WritebackItem] {
        guard let writebackProvider else { throw SimilarityServiceError.writebackProviderMissing }
        return try writebackProvider.getItems(sessionId: sessionId, status: status)
    }

    /// sim.writeback 的执行段：旧写盘路径不变（provider.execute），执行后按
    /// xmpPath 把结果镜像进 deliveries / delivery_items（module=.similarity，
    /// status written/failed，revision/base 与 Culling/FaceKw 同一规则）。
    ///
    /// preview/persist 与 SIM_PREVIEW_STALE 校验仍由 API 层负责；XMP 已落盘，
    /// 镜像失败不回滚文件，只把错误并入返回的 errors。
    public func writeback(sessionId: String, items: [WritebackItem]) async throws -> WritebackResult {
        guard let writebackProvider else { throw SimilarityServiceError.writebackProviderMissing }
        let result = try await writebackProvider.execute(sessionId: sessionId, items: items)
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId, items: items, result: result
        )
        guard !mirrorErrors.isEmpty else { return result }
        var merged = result
        merged.errors.append(contentsOf: mirrorErrors)
        return merged
    }

    /// sim.retry_failed_writeback 的执行段：先记住本次要重试的失败项 id，
    /// 执行后只镜像这些 id（不把早已 written 的旧项再推进一次 revision）。
    public func retryFailedWriteback(sessionId: String) async throws -> WritebackResult {
        guard let writebackProvider else { throw SimilarityServiceError.writebackProviderMissing }
        let failedIds: Set<Int64>
        do {
            // 交付项即唯一写回队列（S5c-2b-3b-2b-1）：失败集从 delivery_items 读。
            failedIds = Set(try deliveryItems
                .listItems(sessionId: sessionId, module: .similarity, status: .failed)
                .map(\.id))
        } catch {
            // 读不到失败集就不能安全收敛镜像范围：宁可不镜像，也不把旧 written 项再推一次。
            GatherLogger.log(
                "similarity retry mirror: failed rows unavailable (\(sessionId)): \(error)",
                level: .debug
            )
            failedIds = []
        }
        let result = try await writebackProvider.retryFailed(sessionId: sessionId)
        guard !failedIds.isEmpty else { return result }
        let mirrorErrors = mirrorPersistedWriteback(sessionId: sessionId, ids: failedIds)
        guard !mirrorErrors.isEmpty else { return result }
        var merged = result
        merged.errors.append(contentsOf: mirrorErrors)
        return merged
    }

    /// sim.confirm_sync：由 DeliveryCoordinator 确认（module=.similarity）。
    /// 错误码保持旧 UI 认得的 XMP_CONFIRM_INCOMPLETE / XMP_CONFIRM_REQUIRES_SYNC /
    /// XMP_CONFIRM_OTHER_SESSION_PENDING。
    public func confirmSync(sessionId: String) async throws -> Bool {
        _ = try confirmDelivery(sessionId: sessionId)
        return true
    }

    /// sim.cleanup：由 DeliveryCoordinator 清理（module=.similarity）。
    /// 外部修改的交付标 conflict、不恢复、不删行；文件/DB 失败保留 intent。
    /// 破坏性确认门禁（Confirmed<T>）在 API 层，本方法只承接已确认的调用。
    /// 本域没有 flush/retry_sync 命令，cleanup 是唯一重试入口，先回放未完成 intent。
    public func cleanup(sessionId: String) async throws -> CleanupResult {
        await replayPendingDeliveries(reason: "similarity cleanup", sessionId: sessionId)
        let summary = try await delivery.cleanup(sessionId: sessionId)
        return Self.cleanupResult(from: summary)
    }

    // MARK: - 交付（Cut 2 / S5c-2b-2）

    /// confirm 的唯一出口：coordinator 错误 → 旧码。
    private func confirmDelivery(sessionId: String) throws -> DeliveryConfirmSummary {
        let summary: DeliveryConfirmSummary
        do {
            summary = try delivery.confirm(sessionId: sessionId)
        } catch let error as DeliveryCoordinatorError {
            switch error {
            case .confirmIncomplete(let blockers):
                GatherLogger.log(
                    "similarity confirm blocked (\(sessionId)): " + blockers.joined(separator: ","),
                    level: .warn
                )
                throw DeliveryError.confirmIncomplete
            case .reloadNotAcknowledged:
                throw DeliveryError.confirmRequiresSync
            default:
                throw error
            }
        }
        if let blocker = summary.unconfirmedSessionIds.first {
            // 本会话 confirmed_at 已先落地；交付留在 written 等对方确认（旧语义）。
            throw DeliveryError.otherSessionNotConfirmed(sessionId: blocker)
        }
        return summary
    }

    /// DeliveryCleanupSummary → 旧 CleanupResult（协议/UI 契约不变）。
    private static func cleanupResult(from summary: DeliveryCleanupSummary) -> CleanupResult {
        var errors = summary.errors
        for path in summary.conflictedXmpPaths {
            errors.append(
                MetadataWritebackFailure.from(
                    DeliveryError.externallyModified,
                    xmpPath: path
                ).description
            )
        }
        return CleanupResult(deletedCount: summary.deletedCount, errors: errors)
    }

    /// cleanup 前的 intent 回放（本域无 flush 命令）。失败只记日志：未完成的 intent
    /// 仍由 cleanup 的 INTENT_PENDING 跳过保护，不会静默丢。
    private func replayPendingDeliveries(reason: String, sessionId: String) async {
        do {
            let replay = try await delivery.engine.replay()
            for error in replay.errors {
                GatherLogger.log("\(reason) replay (\(sessionId)): \(error)", level: .warn)
            }
        } catch {
            GatherLogger.log("\(reason) replay (\(sessionId)): \(error)", level: .warn)
        }
    }

    /// 镜像候选（旧写回行与 result 归一到同一形状，避免两套循环漂移）。
    private struct MirrorCandidate {
        let photoId: String
        let photoPath: String
        let xmpPath: String
        let keywords: [String]
        let attributes: [String: JSONValue]
        let status: DeliveryItemStatus
        let errorMessage: String
        let backupPath: String
    }

    /// 写回执行结果 → 交付镜像。
    ///
    /// S5c-2b-3b-2b-1：状态/属性改读 delivery_items（执行器已把行更新为
    /// written/failed），旧 writeback_items 不再读取；无交付行时按
    /// failedItems + result.written 推断（测试替身/无行场景）。
    private func mirrorWritebackOutcome(
        sessionId: String,
        items: [WritebackItem],
        result: WritebackResult
    ) -> [String] {
        guard !items.isEmpty else { return [] }
        let deliveryRepo = deliveryItems
        var persistedById: [Int64: DeliveryItemRow] = [:]
        let executedIds = Set(items.compactMap(\.id).map(Int64.init))
        if !executedIds.isEmpty {
            do {
                // 一次按会话读，再按本次执行的 id 收窄（避免逐项 N+1 查询）。
                for row in try deliveryRepo.listItems(sessionId: sessionId, module: .similarity)
                where executedIds.contains(row.id) {
                    persistedById[row.id] = row
                }
            } catch {
                GatherLogger.log(
                    "similarity writeback mirror: delivery items unavailable (\(sessionId)): \(error)",
                    level: .debug
                )
            }
        }

        var candidates: [MirrorCandidate] = []
        for item in items {
            // 无 id = 未执行（execute 对无 id 项同样 skipped），不镜像避免谎报写入。
            guard let id = item.id else { continue }
            let row = persistedById[Int64(id)]
            let failedItem = result.failedItems.first { $0.id == id }
            let status: DeliveryItemStatus
            switch row?.status ?? failedItem?.xmpStatus ?? "" {
            case "written": status = .written
            case "failed": status = .failed
            default:
                if failedItem != nil {
                    status = .failed
                } else if result.written > 0 {
                    status = .written
                } else {
                    continue
                }
            }
            var errorMessage = ""
            if status == .failed {
                errorMessage = [row?.errorMessage, failedItem?.errorMessage]
                    .compactMap { $0 }
                    .first { !$0.isEmpty }
                    ?? result.errors.first {
                        $0.hasPrefix(item.photoPath) || $0.hasPrefix("\(id):")
                    }
                    ?? "WRITEBACK_FAILED"
            }
            let keywords = row.flatMap { Self.keywordList($0.keywords) } ?? item.keywords
            let attributes = row.flatMap { Self.attributeObject($0.attributesJSON) }
                ?? Self.attributes(from: item.attributes)
            candidates.append(MirrorCandidate(
                photoId: item.photoId,
                photoPath: item.photoPath,
                xmpPath: item.xmpPath,
                keywords: keywords,
                attributes: attributes,
                status: status,
                errorMessage: errorMessage,
                backupPath: item.backupPath
            ))
        }
        return mirror(candidates: candidates, sessionId: sessionId)
    }

    /// retry 后的镜像：只读指定 id 的交付项（执行器已把它们改成 written/failed）。
    private func mirrorPersistedWriteback(sessionId: String, ids: Set<Int64>) -> [String] {
        let repo = deliveryItems
        let rows: [DeliveryItemRow]
        do {
            rows = try repo
                .listItems(sessionId: sessionId, module: .similarity)
                .filter { ids.contains($0.id) }
        } catch {
            GatherLogger.log(
                "similarity retry mirror: persisted rows unavailable (\(sessionId)): \(error)",
                level: .debug
            )
            return []
        }
        let candidates = rows.compactMap { row -> MirrorCandidate? in
            guard row.status == "written" || row.status == "failed" else { return nil }
            let photoPath = (try? repo.getItem(xmpPath: row.xmpPath))?.photoPath ?? ""
            return MirrorCandidate(
                photoId: row.photoId,
                photoPath: photoPath,
                xmpPath: row.xmpPath,
                keywords: Self.keywordList(row.keywords) ?? [],
                attributes: Self.attributeObject(row.attributesJSON) ?? [:],
                status: row.status == "failed" ? .failed : .written,
                errorMessage: row.errorMessage,
                backupPath: ""
            )
        }
        return mirror(candidates: candidates, sessionId: sessionId)
    }

    /// 逐项补过渡基线后交给 coordinator；返回可并入旧结果 errors 的失败串。
    private func mirror(candidates: [MirrorCandidate], sessionId: String) -> [String] {
        guard !candidates.isEmpty else { return [] }
        let mirrorItems = candidates.map { candidate -> DeliveryWritebackMirrorItem in
            // WP3b-2：基线经 Persistence 端口回读（与 deliveryWritebackBaseline 同口径：
            // 行缺失/读失败 → 空基线，不阻塞镜像）。
            let baseline = deliveryItems.itemBaseline(xmpPath: candidate.xmpPath)
            return DeliveryWritebackMirrorItem(
                photoId: candidate.photoId,
                photoPath: candidate.photoPath,
                xmpPath: candidate.xmpPath,
                keywords: candidate.keywords,
                attributes: candidate.attributes,
                status: candidate.status,
                errorMessage: candidate.errorMessage,
                backupPath: baseline.backupPath.isEmpty ? candidate.backupPath : baseline.backupPath,
                baseFingerprint: baseline.baseFingerprint,
                baseValues: baseline.baseValues
            )
        }
        do {
            return try delivery.mirrorWriteback(
                sessionId: sessionId, items: mirrorItems
            ).errors
        } catch {
            return ["DELIVERY_MIRROR_FAILED: \(error)"]
        }
    }

    private static func keywordList(_ raw: String) -> [String]? {
        guard !raw.isEmpty else { return nil }
        do {
            guard case .array(let values) = try JSONValue.parse(raw) else { return nil }
            return values.compactMap(\.stringValue)
        } catch {
            GatherLogger.log("similarity mirror: invalid keywords_json: \(error)", level: .debug)
            return nil
        }
    }

    private static func attributeObject(_ raw: String) -> [String: JSONValue]? {
        guard !raw.isEmpty else { return nil }
        do {
            guard case .object(let dict) = try JSONValue.parse(raw) else { return nil }
            // keywords 单列写，不重复进 attributes（与 Culling 镜像同口径）。
            return dict.filter { $0.key != "keywords" }
        } catch {
            GatherLogger.log("similarity mirror: invalid attributes_json: \(error)", level: .debug)
            return nil
        }
    }

    private static func attributes(from attributes: WritebackAttributes?) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        if let rating = attributes?.rating { result["rating"] = .number(rating) }
        if let label = attributes?.label { result["label"] = .string(label) }
        return result
    }
}
