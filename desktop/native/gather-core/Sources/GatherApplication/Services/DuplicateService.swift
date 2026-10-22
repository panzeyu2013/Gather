// desktop/native/gather-core/Sources/GatherDomain/Services/DuplicateService.swift
// TS 源: desktop/src/main/services/duplicate/duplicate.service.ts（Phase 3.6 移植）
//
// 移植差异说明（与 SimilarityService 相同的注入模式）：
// - TS 的图片解码（imageService.getThumbnail(filepath, 256) → sharp resize
//   9x8 + grayscale）经注入的 thumbnailProvider 接入：返回 9x8 灰度像素网格
//   （72 字节）后由 DHash.compute 计算，对应 TS computeVisualHashes 的输入
//   （sharp resize 之后），本文件零图片依赖，Linux 可单测。
// - 视觉聚类（TS clusterHashesInWorker → analysis worker）经注入的
//   clusterProvider 接入，默认 ClusterGraphPipeline（minGroupSize=2、
//   mode='global'，与 duplicate.service.ts:275-283 一致；与 SimilarityService/
//   AppComposition 是同一实现，Cut 5 / 5b-2a）；TS worker 可被
//   abort 中途打断，Swift 聚类为同步调用，abort 在聚类返回后补查（对齐
//   SimilarityService 的竞态处理：更严格、取消不落库）。
// - 取消以 JobCancelledError 抛出（对齐 SimilarityService；TS 抛普通 Error
//   'Duplicate scan cancelled'，在 job 层均归类为取消）。
// - sha256File：TS 流式读文件（createReadStream），Swift 整文件读入内存后
//   SHA256（FIPS 180-4 纯 Swift 实现，GatherPersistence/Database/SHA256.swift）——结果逐字节一致，
//   大文件内存占用更高，属于有意取舍。
// - batchAsync 为共享实现（Concurrent/BatchRunner.swift；TS utils/async.ts 同款
//   滑动窗口，并发 32/2/8 与 TS 逐位对齐）：首个失败停止调度、在飞项按各自取消
//   语义收尾后再抛错误（本文件的 stat/读文件不感知取消，等价于跑完；TS 立即
//   reject），错误时序稍有差异，可观察行为一致。
// - 单飞（scanPromise/scanSessionId/scanThreshold）语义与 TS 完全一致：
//   busy 时同参数返回同一在飞 Task，不同参数抛 scanBusy。视觉阈值入参为
//   Double：必须通过 0...64 整数校验（§4.2 P2），再规范化为 Int 作为单飞键。
// - similarity_hashes 写路径与 SimilarityService 协调：同一 UPSERT
//   ON CONFLICT(session_id, photo_id)（唯一索引 idx_similarity_hashes_session_photo
//   为冲突目标），两服务共享该表互不覆盖。
// - 决策持久（§4.2 P1 修复，有意偏离 TS）：重扫重建组与成员行，但用户的
//   keep/discard 决策以 photo_id 为身份存续，不再被重扫清空；「丢弃」的
//   下游后果（导出排除）由 photos.status='removed' 唯一承载（ExportService
//   据此过滤；需要该视图时从该唯一载体派生）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol

public enum DuplicateServiceError: Error, Equatable {
    /// TS: throw new Error('DUPLICATE_SCAN_BUSY')
    case scanBusy
    /// 视觉阈值非法（§4.2 P2 修复）：dHash 64 位，必须是 0...64 的整数。
    case thresholdInvalid
    /// TS: throw new Error(`Duplicate group ${groupId} was not found or has no members`)
    case groupNotFound(Int)
    /// TS: throw new Error(`Duplicate member ${memberId} was not found`)
    case memberNotFound(Int)
}

/// TS 错误消息逐字对齐（executor 失败路径经 JobService 以 String(describing:)
/// 记录为 errorMessage，必须等于 TS error.message）。
extension DuplicateServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .scanBusy: "DUPLICATE_SCAN_BUSY"
        case .thresholdInvalid: "DUP_THRESHOLD_INVALID"
        case .groupNotFound(let groupId): "Duplicate group \(groupId) was not found or has no members"
        case .memberNotFound(let memberId): "Duplicate member \(memberId) was not found"
        }
    }
}

/// TS 错误码映射（仅 scanBusy 在 GatherErrorCode 有对应码；其余为普通 Error）。
extension DuplicateServiceError {
    public var gatherCode: GatherErrorCode? {
        switch self {
        // 两个可本地化的协议码；groupNotFound/memberNotFound 为普通 Error。
        case .scanBusy: .DUPLICATE_SCAN_BUSY
        case .thresholdInvalid: .DUP_THRESHOLD_INVALID
        case .groupNotFound, .memberNotFound: nil
        }
    }
}

// 「丢弃」决策的下游后果语义（仍然有效，唯一载体是落库的 photos.status）：
//   - 成员行 is_kept=0 ⇔ 用户丢弃该重复副本；
//   - DuplicateService 是 photos.status='removed' 的唯一写者（决策回填后重算）；
//   - ExportService 以 status != 'removed' 过滤 → 这些照片不会导出；
//   - 文件从不移动/删除，决策也不因子库缺失而消失——撤销决策即恢复导出。
// （原先据此语义导出的 DuplicateDiscardImpact 快照结构与 discardedPhotoIds 查询
//   无任何生产消费者，已在无用代码清查中删除；需要该视图时请按上面的唯一载体重新派生。）

/// TS: excludeExactDuplicateHashes —— 从视觉 hash 行里剔除精确重复照片。
public func excludeExactDuplicateHashes(
    rows: [(photoId: String, hashHex: String)],
    exactPhotoIds: Set<String>
) -> [(photoId: String, hashHex: String)] {
    rows.filter { !exactPhotoIds.contains($0.photoId) }
}

/// TS: computeVisualHashes —— 并发 8 计算视觉 hash；corrupt 图片（provider 返回
/// nil）静默跳过（不影响精确重复检测），结果按输入序收集。
public func computeVisualHashes(
    photos: [(id: String, filepath: String)],
    thumbnailProvider: @escaping @Sendable (String, Int) async -> [UInt8]?
) async -> [String: String] {
    let computed = (try? await batchAsync(photos, concurrency: 8) { photo -> (String, String)? in
        guard let pixels = await thumbnailProvider(photo.filepath, 256) else { return nil }
        return (photo.id, DHash.compute(pixels9x8: pixels))
    }) ?? []
    var hashes: [String: String] = [:]
    for entry in computed {
        if let pair = entry {
            hashes[pair.0] = pair.1
        }
    }
    return hashes
}

/// 线程安全说明（Swift 6 `Sendable`）：单飞登记的全部可变状态
/// （`scanPromise`/`scanSessionId`/`scanThreshold`）只在 `lock`（NSLock）临界区内
/// 读写；其余存储属性（注入的 Repo/事务端口与两个 provider）构造后不可变。
/// 锁纪律无法被编译器静态验证，故标注 `@unchecked`（与同仓 BatchCursor/
/// MetadataSyncCoordinator 的既有约定一致）。
///
/// WP3b-3：本类型不再持裸连接——25 条 prepare 下沉到 DuplicateRepo /
/// DuplicateGroupQuery / SimilarityHashRepo，4 个事务经 TransactionRunner。
/// 这里只保留扫描阶段编排与决策/打分规则。
public final class DuplicateService: @unchecked Sendable {
    /// TS: ImageService.getThumbnail(filepath, 256) → 9x8 灰度像素网格。
    /// Swift 6：provider 会被 batchAsync 的 worker 子任务捕获并发调用，
    /// 闭包类型必须可跨并发域（@Sendable）。
    public typealias ThumbnailProvider = @Sendable (String, Int) async -> [UInt8]?
    /// TS: clusterHashesInWorker（threshold, minGroupSize=2, mode='global'）。
    public typealias ClusterProvider = ([HashEntry], Int, Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> ClusterResult
    /// TS: onProgress(current, total, message)。
    /// Swift 6：单飞扫描会把本回调捕获进自持 Task（scanDuplicates 的
    /// 注册/复用语义要求），回调在后台任务里执行，故类型必须可跨并发域。
    public typealias ProgressHandler = @Sendable (Int, Int, String) -> Void

    /// WP3b-3：SQL 全部在 Persistence；事务经 TransactionRunner（嵌套退化为 SAVEPOINT）。
    private let duplicateRepo: any DuplicateRepository
    private let groupQuery: any DuplicateGroupReading
    private let hashes: any SimilarityHashRepository
    private let transactions: any TransactionRunner
    private let thumbnailProvider: ThumbnailProvider
    private let clusterProvider: ClusterProvider

    /// TS: scanPromise / scanSessionId / scanThreshold（单飞）。Task 无法按值
    /// 比较，用 class 包装后按身份判断归属。
    private final class ScanHandle: @unchecked Sendable {
        let task: Task<DuplicateScanResult, any Error>
        init(_ task: Task<DuplicateScanResult, any Error>) { self.task = task }
    }

    private let lock = NSLock()
    private var scanPromise: ScanHandle?
    private var scanSessionId: String?
    private var scanThreshold: Int?

    public init(
        duplicateRepo: any DuplicateRepository,
        groupQuery: any DuplicateGroupReading,
        hashes: any SimilarityHashRepository,
        transactions: any TransactionRunner,
        thumbnailProvider: @escaping ThumbnailProvider = { _, _ in nil },
        clusterProvider: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            // global -> 单趟图（run）；sequential -> 相邻段（runSequential）。
            // 同一 ClusterGraphPipeline 入口，不再有第二份聚类实现。
            try ClusterGraphPipeline.run(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress
            ).result
        }
    ) {
        self.duplicateRepo = duplicateRepo
        self.groupQuery = groupQuery
        self.hashes = hashes
        self.transactions = transactions
        self.thumbnailProvider = thumbnailProvider
        self.clusterProvider = clusterProvider
    }

    /// 视觉阈值校验（§4.2 P2 修复）：dHash 为 64 位，阈值必须是 0...64 的整数。
    /// 100 会让全库连成一组、非整数此前被 Int.init 静默截断——两者都在此拒绝。
    /// router 在建 job 前可用同一实现校验原始 Double（服务入口会再校验一次）。
    public func validateDuplicateThreshold(_ value: Double) throws {
        // 与 validateSimilarityParameters 的阈值域判定共用同一函数
        //（DHash 64 位 → 0...64 整数；有限性拒绝 NaN/±∞）。
        if !DHash.isValidThreshold(value) {
            throw DuplicateServiceError.thresholdInvalid
        }
    }

    /// TS: scanDuplicates —— 单飞扫描。busy 时同参数返回同一在飞结果，
    /// 不同参数抛 scanBusy。visualThreshold 为 Double（对齐 TS number）：
    /// 校验通过后转 Int；单飞键用规范化后的 Int（10.0 与 10 视为同参数）。
    public func scanDuplicates(
        sessionId: String,
        visualThreshold: Double? = nil,
        signal: JobAbortSignal? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> DuplicateScanResult {
        if let visualThreshold { try validateDuplicateThreshold(visualThreshold) }
        let threshold = visualThreshold.map { Int($0) }
        // 同步前缀（TS 首个 await 之前的语义）：占用检查与登记。
        switch beginScan(
            sessionId: sessionId,
            visualThreshold: threshold,
            task: Task {
                try await self._scanDuplicates(
                    sessionId: sessionId, visualThreshold: threshold,
                    signal: signal, onProgress: onProgress)
            }
        ) {
        case .reused(let handle):
            // 同参数：与 TS 一致返回同一在飞 promise（不重新 await 登记）。
            return try await handle.task.value
        case .busy:
            throw DuplicateServiceError.scanBusy
        case .registered(let handle):
            // TS finally：成功/失败路径都释放单飞占用。
            defer { endScan(handle: handle) }
            return try await handle.task.value
        }
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private enum ScanSlotDecision {
        /// 同参数在飞扫描：复用同一 Task。
        case reused(ScanHandle)
        /// 不同参数在飞扫描：抛 scanBusy。
        case busy
        /// 新扫描已登记。
        case registered(ScanHandle)
    }

    private func beginScan(
        sessionId: String,
        visualThreshold: Int?,
        task: @autoclosure () -> Task<DuplicateScanResult, any Error>
    ) -> ScanSlotDecision {
        lock.lock()
        defer { lock.unlock() }
        if let existing = scanPromise {
            if scanSessionId == sessionId && scanThreshold == visualThreshold {
                return .reused(existing)
            }
            return .busy
        }
        scanSessionId = sessionId
        scanThreshold = visualThreshold
        let handle = ScanHandle(task())
        scanPromise = handle
        return .registered(handle)
    }

    private func endScan(handle: ScanHandle) {
        lock.lock()
        defer { lock.unlock() }
        if let current = scanPromise, current === handle {
            scanPromise = nil
        }
        scanSessionId = nil
        scanThreshold = nil
    }

    /// TS: _scanDuplicates —— 多阶段管线：
    /// stat（并发 32）→ sha256（并发 2）→ 视觉 hash（并发 8）→
    /// 落库（checksum + similarity_hashes）→ 精确/视觉聚类 → 重建分组。
    private func _scanDuplicates(
        sessionId: String,
        visualThreshold: Int?,
        signal: JobAbortSignal?,
        onProgress: ProgressHandler?
    ) async throws -> DuplicateScanResult {
        // TS:87 —— 已中止则立即抛取消。
        if signal?.aborted ?? false { throw JobCancelledError() }
        let threshold = visualThreshold ?? 4
        let now = nowISOString()

        let allPhotos = try duplicateRepo.getScanPhotos(sessionId: sessionId)
        let photoById = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })

        // TS:114-130 —— stat 阶段，不可读文件跳过。
        var photoMeta: [String: PhotoStat] = [:]
        var sizeGroups: [Int64: [String]] = [:]
        let statResults = try await batchAsync(allPhotos, concurrency: 32) { photo -> PhotoStat? in
            if signal?.aborted ?? false { throw JobCancelledError() }
            guard let stat = tsStat(photo.filepath) else { return nil }
            return PhotoStat(
                size: stat.size,
                mtimeMs: stat.mtimeMs,
                mtimeISO: isoString(Date(timeIntervalSince1970: stat.mtimeMs / 1000))
            )
        }
        for (index, photo) in allPhotos.enumerated() {
            guard let meta = statResults[index] else { continue }
            photoMeta[photo.id] = meta
            sizeGroups[meta.size, default: []].append(photo.id)
        }
        onProgress?(allPhotos.count, allPhotos.count * 3, "duplicate.read")

        // TS:132-153 —— 存储的 checksum 与 size/mtime 一致则复用，否则进候选。
        var resolvedChecksums: [String: String] = [:]
        for photo in allPhotos {
            guard let meta = photoMeta[photo.id],
                  !photo.checksum.isEmpty,
                  photo.checksumFileSize == meta.size,
                  abs(photo.checksumFileMtimeMs - meta.mtimeMs) < 1 else { continue }
            resolvedChecksums[photo.id] = photo.checksum
        }
        var candidatePhotos: [(id: String, filepath: String)] = []
        for (_, photoIds) in sizeGroups where photoIds.count >= 2 {
            for photoId in photoIds where resolvedChecksums[photoId] == nil {
                let photo = photoById[photoId]!
                candidatePhotos.append((photo.id, photo.filepath))
            }
        }

        // TS:155-168 —— sha256 阶段（并发 2），不可读文件跳过。
        let hashResults = try await batchAsync(candidatePhotos, concurrency: 2) { photo -> String? in
            if signal?.aborted ?? false { throw JobCancelledError() }
            // F-6 闭环（第二轮验证）：不再整文件读入 + 纯 Swift 哈希，
            // 改走 FileHasher（Persistence）的 CryptoKit 4MB 分块流式（内存恒定、约 9.4×）。
            guard let checksum = try? FileHasher.sha256File(photo.filepath) else { return nil }
            return checksum
        }
        for (index, photo) in candidatePhotos.enumerated() {
            if let checksum = hashResults[index] {
                resolvedChecksums[photo.id] = checksum
            }
        }
        onProgress?(allPhotos.count + candidatePhotos.count, allPhotos.count * 3, "duplicate.hash")

        // TS:170-190 —— 视觉 hash 复用：similarity_hashes 行在 size/mtime 一致
        // 时直接采用，否则重新计算。hash 表由 Similarity/Duplicate/Indexer 共用，
        // 读写统一走 SimilarityHashRepository。
        let existingVisualRows = try hashes.getRecords(sessionId: sessionId)

        var resolvedVisualHashes: [String: String] = [:]
        for row in existingVisualRows {
            guard let meta = photoMeta[row.photoId],
                  meta.size == Int64(row.fileSize),
                  abs(meta.mtimeMs - row.fileMtimeMs) < 1 else { continue }
            resolvedVisualHashes[row.photoId] = row.hashHex
        }
        let visualMisses = allPhotos.filter { resolvedVisualHashes[$0.id] == nil }
        // TS:191 —— 计算前复查。
        if signal?.aborted ?? false { throw JobCancelledError() }
        let computedVisualHashes = await computeVisualHashes(
            photos: visualMisses.map { (id: $0.id, filepath: $0.filepath) },
            thumbnailProvider: thumbnailProvider
        )
        // TS:193-199 —— computeVisualHashes 不观察 abort，落库前必须复查：
        // 中途到达的取消不得写入 hash 与重建分组。
        if signal?.aborted ?? false { throw JobCancelledError() }
        for (photoId, hash) in computedVisualHashes {
            resolvedVisualHashes[photoId] = hash
        }
        onProgress?(allPhotos.count * 3, allPhotos.count * 3, "duplicate.done")

        // TS:202-231 —— 分析数据落库（checksum 回写 + similarity_hashes UPSERT）。
        try transactions.transaction {
            try duplicateRepo.updateChecksums(allPhotos.map { photo in
                let meta = photoMeta[photo.id]
                return DuplicateChecksumWrite(
                    photoId: photo.id,
                    checksum: resolvedChecksums[photo.id] ?? "",
                    fileSize: meta?.size ?? 0,
                    fileMtimeMs: meta?.mtimeMs ?? 0
                )
            })
            // 与 SimilarityService 相同的 UPSERT 写路径：唯一索引
            // idx_similarity_hashes_session_photo 是冲突目标。
            try hashes.upsert(resolvedVisualHashes.map { photoId, hash in
                let meta = photoMeta[photoId]
                return SimilarityHashWrite(
                    sessionId: sessionId,
                    photoId: photoId,
                    hashHex: hash,
                    fileSize: Int(meta?.size ?? 0),
                    fileMtimeMs: meta?.mtimeMs ?? 0
                )
            })
        }

        // TS:241 —— 视觉聚类 O(n²)（大库达秒级），读取已提升到事务外。
        try duplicateRepo.enableUnlimitedGroupConcat()

        // TS:243-258 —— 精确分组：按 checksum 聚合。
        let exactRows = try duplicateRepo.getExactGroups(sessionId: sessionId)

        var exactPhotoIds = Set<String>()
        for row in exactRows {
            exactPhotoIds.formUnion(row.photoIds)
        }

        // TS:260-274 —— 视觉聚类输入：排除精确重复照片。
        let hashRows = excludeExactDuplicateHashes(
            rows: try duplicateRepo.getOrderedVisualHashes(sessionId: sessionId).map { row in
                (photoId: row.photoId, hashHex: row.hashHex)
            },
            exactPhotoIds: exactPhotoIds
        )
        var hashByPhotoId: [String: String] = [:]
        for row in hashRows {
            hashByPhotoId[row.photoId] = row.hashHex
        }

        let components: [[String]]
        if hashRows.count >= 2 {
            let clustered = try clusterProvider(
                hashRows.map { HashEntry(photoId: $0.photoId, hash: $0.hashHex) },
                threshold,
                2,
                .global,
                nil
            )
            // TS worker 内可被 abort 拒绝；Swift 聚类同步执行，返回后补查
            //（对齐 SimilarityService：更严格，取消不落库）。
            if signal?.aborted ?? false { throw JobCancelledError() }
            components = clustered.groups
        } else {
            components = []
        }

        // 重建分组事务（§4.2 P1 修复，有意偏离 TS 的「重扫即重置决策」）：
        // 组 id 与成员行 id 每次扫描都变，因此决策**不挂在组上**；稳定身份是
        // (session_id, photo_id) —— photo_id 在会话内可变不了，且与分组类型
        // (exact ↔ visual)、组结构变化全部解耦。流程：同事务内读旧决策 →
        // 重建组/成员 → 按 photo_id 回填 is_kept/resolution → 重算 photos.status。
        // 读-改-写单事务保证并发扫描不会互相清空：后写者读到的是先写者已提交
        // 的决策并原样继承。
        let groupIds = try transactions.transaction { () -> (exact: [Int], visual: [Int]) in
            let carriedDecisions = try duplicateRepo.getMemberDecisions(sessionId: sessionId)
            let previousMemberIds = Set(carriedDecisions.keys)

            try duplicateRepo.deleteGroupsAndMembers(sessionId: sessionId)

            // 与旧实现同一插入序：先 exact 组（按聚合行序）再 visual 组
            // （按聚类分量序）；成员行按（组序, 组内成员序）展开。组/成员 id
            // 序列因此逐位不变，只是 SQL 提前到 Repo（语句各只准备一次）。
            var groupInserts: [DuplicateGroupInsert] = []
            var pendingMembers: [(photoIds: [String], isExact: Bool)] = []
            for row in exactRows {
                groupInserts.append(DuplicateGroupInsert(
                    sessionId: sessionId, groupType: "exact", checksum: row.checksum,
                    hashHex: nil, memberCount: row.photoIds.count, createdAt: now
                ))
                pendingMembers.append((row.photoIds, true))
            }
            for memberIds in components {
                // TS:318 —— 组内首成员（hashRows 按 photo_id 排序）的 hash 为代表。
                let firstHash = hashByPhotoId[memberIds[0]]!
                groupInserts.append(DuplicateGroupInsert(
                    sessionId: sessionId, groupType: "visual", checksum: nil,
                    hashHex: firstHash, memberCount: memberIds.count, createdAt: now
                ))
                pendingMembers.append((memberIds, false))
            }
            let insertedGroupIds = try duplicateRepo.insertGroups(groupInserts)
            var exactGroupIds: [Int] = []
            var visualGroupIds: [Int] = []
            var currentMemberIds = Set<String>()
            var memberInserts: [DuplicateMemberInsert] = []
            for (index, pending) in pendingMembers.enumerated() {
                let groupId = insertedGroupIds[index]
                if pending.isExact {
                    exactGroupIds.append(groupId)
                } else {
                    visualGroupIds.append(groupId)
                }
                for photoId in pending.photoIds {
                    let meta = photoMeta[photoId]
                    let decision = carriedDecisions[photoId]
                    currentMemberIds.insert(photoId)
                    memberInserts.append(DuplicateMemberInsert(
                        groupId: groupId,
                        photoId: photoId,
                        sessionId: sessionId,
                        isKept: decision?.isKept == false ? false : true,
                        fileSize: meta?.size,
                        fileMtime: meta?.mtimeISO,
                        resolution: decision?.resolution
                    ))
                }
            }
            try duplicateRepo.insertMembers(memberInserts)
            // 组级 resolution 从成员决策派生（全部成员已决才落值）。
            try syncGroupResolutions(groupIds: exactGroupIds + visualGroupIds)
            // 决策落库：携带 is_kept=0 的成员置 'removed'（导出排除的唯一载体）；
            // 旧成员中已无丢弃决策的（组消失/照片脱组）复位 'ready'。未决成员
            // 保持原 status（pending/missing 不被本模块改写）。
            try duplicateRepo.markDiscarded(Array(currentMemberIds))
            try duplicateRepo.restoreOrphanedRemoved(Array(previousMemberIds))
            return (exactGroupIds, visualGroupIds)
        }

        return try buildResult(exactGroupIds: groupIds.exact, visualGroupIds: groupIds.visual)
    }

    /// TS: getGroups —— duplicate.groups 命令；按 group_type, id 排序。
    public func getGroups(sessionId: String) throws -> [DuplicateGroup] {
        let groupRows = try groupQuery.getGroups(sessionId: sessionId)
        if groupRows.isEmpty { return [] }
        let memberMap = makeMembers(try groupQuery.getMembers(groupIds: groupRows.map(\.id)))
        return groupRows.map { row in
            makeGroup(row: row, memberMap: memberMap)
        }
    }

    /// TS: resolveGroup —— keep_one 按分数（size*1000 + mtimeMs）取最优保留，
    /// keep_all 全部保留；随后重算照片状态。
    public func resolveGroup(groupId: Int, resolution: DupResolution) throws {
        try transactions.transaction {
            try duplicateRepo.setGroupResolutions([
                DuplicateGroupResolutionWrite(groupId: groupId, resolution: resolution.rawValue)
            ])

            let members = try groupQuery.getMembers(groupId: groupId)
            if members.isEmpty {
                throw DuplicateServiceError.groupNotFound(groupId)
            }

            if resolution == .keepAll {
                try duplicateRepo.setMembersKeptAll(
                    members.map(\.id), resolution: resolution.rawValue
                )
            } else {
                var bestId = members[0].id
                var bestScore: Double = -1
                for member in members {
                    // TS: new Date(m.file_mtime || 0).getTime() —— null/空串 → 0，
                    // 非空非法串 → NaN（永不中选）。
                    let mtimeMs: Double
                    if let fileMtime = member.fileMtime, !fileMtime.isEmpty {
                        mtimeMs = tsDateParse(fileMtime) ?? .nan
                    } else {
                        mtimeMs = 0
                    }
                    let score = Double(member.fileSize ?? 0) * 1000 + mtimeMs
                    if score > bestScore {
                        bestScore = score
                        bestId = member.id
                    }
                }
                try duplicateRepo.setMemberKept(
                    members.map { DuplicateMemberKeptWrite(memberId: $0.id, isKept: $0.id == bestId) },
                    resolution: resolution.rawValue
                )
            }
            try duplicateRepo.recomputePhotoStatuses(members.map(\.photoId))
        }
    }

    /// TS: resolveMember —— 单成员保留/移除；resolution 只在未定（NULL）时写。
    public func resolveMember(memberId: Int, isKept: Bool) throws {
        try transactions.transaction {
            try duplicateRepo.setMemberResolutionIfUnset(
                memberId: memberId,
                isKept: isKept,
                resolution: isKept ? "keep_all" : "keep_one"
            )
            guard let photoId = try duplicateRepo.getMemberPhotoId(memberId: memberId) else {
                throw DuplicateServiceError.memberNotFound(memberId)
            }
            try duplicateRepo.recomputePhotoStatuses([photoId])
        }
    }

    // MARK: - 内部

    /// 组级 resolution 派生：全部成员已决 → keep_all（全保留）/ keep_one（仅留 1）；
    /// 有未决成员 → 保持 NULL（未处理）。成员各自的 resolution 才是决策真相。
    private func syncGroupResolutions(groupIds: [Int]) throws {
        var writes: [DuplicateGroupResolutionWrite] = []
        for groupId in groupIds {
            let rows = try groupQuery.getMemberStates(groupId: groupId)
            guard !rows.isEmpty else { continue }
            var allResolved = true
            var keptCount = 0
            for row in rows {
                if row.resolution == nil { allResolved = false }
                if row.isKept { keptCount += 1 }
            }
            guard allResolved else { continue }
            let resolution: String?
            if keptCount == rows.count { resolution = "keep_all" }
            else if keptCount == 1 { resolution = "keep_one" }
            else { resolution = nil }
            guard let resolution else { continue }
            writes.append(DuplicateGroupResolutionWrite(groupId: groupId, resolution: resolution))
        }
        try duplicateRepo.setGroupResolutions(writes)
    }

    /// photos.status 的三个写者（markDiscarded / restoreOrphanedRemoved /
    /// recomputePhotoStatuses）已随 SQL 下沉到 DuplicateRepo；语义不变：
    /// 任一 is_kept=0 成员 → 'removed'（导出排除的唯一落库载体），否则 'ready'。

    /// TS: buildResult —— 按组 id 读取分组与成员，汇总 totalDuplicates。
    private func buildResult(exactGroupIds: [Int], visualGroupIds: [Int]) throws -> DuplicateScanResult {
        var exactGroups: [DuplicateGroup] = []
        var visualGroups: [DuplicateGroup] = []
        for ids in [exactGroupIds, visualGroupIds] {
            if ids.isEmpty { continue }
            for group in try fetchGroups(ids: ids) {
                if group.groupType == .exact {
                    exactGroups.append(group)
                } else {
                    visualGroups.append(group)
                }
            }
        }
        let totalDuplicates =
            exactGroups.reduce(0) { $0 + $1.memberCount }
            + visualGroups.reduce(0) { $0 + $1.memberCount }
        return DuplicateScanResult(
            exactGroups: exactGroups,
            visualGroups: visualGroups,
            totalDuplicates: totalDuplicates
        )
    }

    /// TS: buildResult 的组读取（按 id 排序，成员 JOIN photos）。
    private func fetchGroups(ids: [Int]) throws -> [DuplicateGroup] {
        guard !ids.isEmpty else { return [] }
        let groupRows = try groupQuery.getGroups(ids: ids)
        let memberMap = makeMembers(try groupQuery.getMembers(groupIds: ids))
        return groupRows.map { row in
            makeGroup(row: row, memberMap: memberMap)
        }
    }

    /// 读模型 → 协议成员（列序解码在 Persistence，这里只做字段映射）。
    private func makeMembers(
        _ detailsByGroup: [Int: [DuplicateGroupMemberDetail]]
    ) -> [Int: [DuplicateGroupMember]] {
        detailsByGroup.mapValues { details in
            details.map { detail in
                DuplicateGroupMember(
                    id: detail.member.id,
                    photoId: detail.member.photoId,
                    isKept: detail.member.isKept,
                    fileSize: detail.member.fileSize.map(Int.init),
                    fileMtime: detail.member.fileMtime,
                    resolution: detail.member.resolution,
                    filepath: detail.filepath,
                    filename: detail.filename
                )
            }
        }
    }

    /// SELECT * 列序契约在 DuplicateGroupRow（列 0-7），这里只做读模型映射。
    private func makeGroup(row: DuplicateGroupRow, memberMap: [Int: [DuplicateGroupMember]]) -> DuplicateGroup {
        DuplicateGroup(
            id: row.id,
            groupType: row.groupType == "exact" ? .exact : .visual,
            checksum: row.checksum,
            hashHex: row.hashHex,
            memberCount: row.memberCount,
            members: memberMap[row.id] ?? [],
            resolution: row.resolution,
            createdAt: row.createdAt
        )
    }
}

// MARK: - 私有行类型

/// TS: fs.stat 结果（_scanDuplicates stat 阶段）。
private struct PhotoStat {
    let size: Int64
    let mtimeMs: Double
    let mtimeISO: String
}
