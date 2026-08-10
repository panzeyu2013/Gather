// desktop/native/gather-core/Sources/GatherCore/Services/DuplicateService.swift
// TS 源: desktop/src/main/services/duplicate/duplicate.service.ts（Phase 3.6 移植）
//
// 移植差异说明（与 SimilarityService 相同的注入模式）：
// - TS 的图片解码（imageService.getThumbnail(filepath, 256) → sharp resize
//   9x8 + grayscale）经注入的 thumbnailProvider 接入：返回 9x8 灰度像素网格
//   （72 字节）后由 DHash.compute 计算，对应 TS computeVisualHashes 的输入
//   （sharp resize 之后），本文件零图片依赖，Linux 可单测。
// - 视觉聚类（TS clusterHashesInWorker → analysis worker）经注入的
//   clusterProvider 接入，默认 ClusterEngine.clusterByHash（minGroupSize=2、
//   mode='global'，与 duplicate.service.ts:275-283 一致）；TS worker 可被
//   abort 中途打断，Swift 聚类为同步调用，abort 在聚类返回后补查（对齐
//   SimilarityService 的竞态处理：更严格、取消不落库）。
// - 取消以 JobCancelledError 抛出（对齐 SimilarityService；TS 抛普通 Error
//   'Duplicate scan cancelled'，在 job 层均归类为取消）。
// - sha256File：TS 流式读文件（createReadStream），Swift 整文件读入内存后
//   SHA256（FIPS 180-4 纯 Swift 实现，ImageCache.swift）——结果逐字节一致，
//   大文件内存占用更高，属于有意取舍。
// - batchAsync（TS utils/async.ts）为滑动窗口实现（并发 32/2/8 与 TS 逐位
//   对齐）：首个失败后停止调度、在飞项跑完；Swift 侧等待在飞项结束后再抛
//   首个错误（TS 立即 reject），错误时序稍有差异，可观察行为一致。
// - 单飞（scanPromise/scanSessionId/scanThreshold）语义与 TS 完全一致：
//   busy 时同参数返回同一在飞 Task，不同参数抛 scanBusy。
// - similarity_hashes 写路径与 SimilarityService 协调：同一 UPSERT
//   ON CONFLICT(session_id, photo_id)（唯一索引 idx_similarity_hashes_session_photo
//   为冲突目标），两服务共享该表互不覆盖。
import Foundation

public enum DuplicateServiceError: Error, Equatable {
    /// TS: throw new Error('DUPLICATE_SCAN_BUSY')
    case scanBusy
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
        case .groupNotFound(let groupId): "Duplicate group \(groupId) was not found or has no members"
        case .memberNotFound(let memberId): "Duplicate member \(memberId) was not found"
        }
    }
}

/// TS 错误码映射（仅 scanBusy 在 GatherErrorCode 有对应码；其余为普通 Error）。
extension DuplicateServiceError {
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .scanBusy: .DUPLICATE_SCAN_BUSY
        case .groupNotFound, .memberNotFound: nil
        }
    }
}

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
    thumbnailProvider: @escaping (String, Int) async -> [UInt8]?
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

public final class DuplicateService {
    /// TS: ImageService.getThumbnail(filepath, 256) → 9x8 灰度像素网格。
    public typealias ThumbnailProvider = (String, Int) async -> [UInt8]?
    /// TS: clusterHashesInWorker（threshold, minGroupSize=2, mode='global'）。
    public typealias ClusterProvider = ([HashEntry], Int, Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> ClusterResult
    /// TS: onProgress(current, total, message)。
    public typealias ProgressHandler = (Int, Int, String) -> Void

    private let connection: DBConnection
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
        connection: DBConnection,
        thumbnailProvider: @escaping ThumbnailProvider = { _, _ in nil },
        clusterProvider: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        }
    ) {
        self.connection = connection
        self.thumbnailProvider = thumbnailProvider
        self.clusterProvider = clusterProvider
    }

    /// TS: scanDuplicates —— 单飞扫描。busy 时同参数返回同一在飞结果，
    /// 不同参数抛 scanBusy。
    public func scanDuplicates(
        sessionId: String,
        visualThreshold: Int? = nil,
        signal: JobAbortSignal? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> DuplicateScanResult {
        // 同步前缀（TS 首个 await 之前的语义）：占用检查与登记。
        switch beginScan(
            sessionId: sessionId,
            visualThreshold: visualThreshold,
            task: Task {
                try await self._scanDuplicates(
                    sessionId: sessionId, visualThreshold: visualThreshold,
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

        let allPhotos = try connection.prepare("""
            SELECT id, filepath, checksum, checksum_file_size, checksum_file_mtime_ms
            FROM photos WHERE session_id IN (?)
            """).query([.text(sessionId)]).map { row in
                DuplicatePhotoRow(
                    id: row[0].textValue ?? "",
                    filepath: row[1].textValue ?? "",
                    checksum: row[2].textValue ?? "",
                    checksumFileSize: row[3].intValue ?? 0,
                    checksumFileMtimeMs: row[4].doubleValue ?? 0
                )
            }
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
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: photo.filepath)) else { return nil }
            return Self.sha256Hex(data)
        }
        for (index, photo) in candidatePhotos.enumerated() {
            if let checksum = hashResults[index] {
                resolvedChecksums[photo.id] = checksum
            }
        }
        onProgress?(allPhotos.count + candidatePhotos.count, allPhotos.count * 3, "duplicate.hash")

        // TS:170-190 —— 视觉 hash 复用：similarity_hashes 行在 size/mtime 一致
        // 时直接采用，否则重新计算。
        let existingVisualRows = try connection.prepare("""
            SELECT photo_id, hash_hex, file_size, file_mtime_ms
            FROM similarity_hashes WHERE session_id IN (?)
            """).query([.text(sessionId)])

        var resolvedVisualHashes: [String: String] = [:]
        for row in existingVisualRows {
            let photoId = row[0].textValue ?? ""
            guard let meta = photoMeta[photoId],
                  meta.size == (row[2].intValue ?? 0),
                  abs(meta.mtimeMs - (row[3].doubleValue ?? 0)) < 1 else { continue }
            resolvedVisualHashes[photoId] = row[1].textValue ?? ""
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
        try connection.transaction {
            let updateChecksum = try connection.prepare("""
                UPDATE photos
                SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
                WHERE id = ?
                """)
            for photo in allPhotos {
                let meta = photoMeta[photo.id]
                _ = try updateChecksum.run([
                    .text(resolvedChecksums[photo.id] ?? ""),
                    .int(meta?.size ?? 0),
                    .real(meta?.mtimeMs ?? 0),
                    .text(photo.id),
                ])
            }
            // 与 SimilarityService 相同的 UPSERT 写路径：唯一索引
            // idx_similarity_hashes_session_photo 是冲突目标。
            let upsertHash = try connection.prepare("""
                INSERT INTO similarity_hashes
                  (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id, photo_id) DO UPDATE SET
                  hash_hex = excluded.hash_hex,
                  file_size = excluded.file_size,
                  file_mtime_ms = excluded.file_mtime_ms
                """)
            for (photoId, hash) in resolvedVisualHashes {
                let meta = photoMeta[photoId]
                _ = try upsertHash.run([
                    .text(sessionId), .text(photoId), .text(hash),
                    .int(meta?.size ?? 0), .real(meta?.mtimeMs ?? 0),
                ])
            }
        }

        // TS:241 —— 视觉聚类 O(n²)（大库达秒级），读取已提升到事务外。
        try connection.exec("PRAGMA group_concat_limit = 0")

        // TS:243-258 —— 精确分组：按 checksum 聚合。
        let exactRows = try connection.prepare("""
            SELECT checksum, COUNT(*) as cnt, GROUP_CONCAT(id) as photo_ids
            FROM photos
            WHERE session_id IN (?) AND checksum != ''
            GROUP BY checksum
            HAVING COUNT(*) > 1
            """).query([.text(sessionId)])

        var exactPhotoIds = Set<String>()
        for row in exactRows {
            for photoId in (row[2].textValue ?? "").split(separator: ",") {
                exactPhotoIds.insert(String(photoId))
            }
        }

        // TS:260-274 —— 视觉聚类输入：排除精确重复照片。
        let hashRows = excludeExactDuplicateHashes(
            rows: try connection.prepare("""
                SELECT sh.photo_id, sh.hash_hex
                FROM similarity_hashes sh
                JOIN photos p ON p.id = sh.photo_id
                WHERE p.session_id IN (?)
                ORDER BY sh.photo_id
                """).query([.text(sessionId)]).map { row in
                    (photoId: row[0].textValue ?? "", hashHex: row[1].textValue ?? "")
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

        // TS:292-329 —— 重建分组事务：先复位旧成员（removed → ready）再整组
        // 删除重插，保证扫描结果幂等。
        let groupIds = try connection.transaction { () -> (exact: [Int], visual: [Int]) in
            _ = try connection.prepare("""
                UPDATE photos
                SET status = 'ready'
                WHERE id IN (
                  SELECT photo_id
                  FROM duplicate_group_members
                  WHERE session_id IN (?)
                )
                AND status = 'removed'
                """).run([.text(sessionId)])
            _ = try connection.prepare(
                "DELETE FROM duplicate_group_members WHERE session_id IN (?)"
            ).run([.text(sessionId)])
            _ = try connection.prepare(
                "DELETE FROM duplicate_groups WHERE session_id IN (?)"
            ).run([.text(sessionId)])

            let insertGroup = try connection.prepare(
                "INSERT INTO duplicate_groups (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at) VALUES (?, ?, ?, ?, ?, NULL, ?)"
            )
            let insertMember = try connection.prepare(
                "INSERT INTO duplicate_group_members (group_id, photo_id, session_id, is_kept, file_size, file_mtime) VALUES (?, ?, ?, 1, ?, ?)"
            )
            var exactGroupIds: [Int] = []
            for row in exactRows {
                let photoIds = (row[2].textValue ?? "").split(separator: ",").map(String.init)
                _ = try insertGroup.run([
                    .text(sessionId), .text("exact"), .text(row[0].textValue ?? ""), .null,
                    .int(Int64(photoIds.count)), .text(now),
                ])
                let groupId = Int(connection.lastInsertRowid)
                exactGroupIds.append(groupId)
                for photoId in photoIds {
                    let meta = photoMeta[photoId]
                    _ = try insertMember.run([
                        .int(Int64(groupId)), .text(photoId), .text(sessionId),
                        meta.map { .int($0.size) } ?? .null,
                        meta.map { .text($0.mtimeISO) } ?? .null,
                    ])
                }
            }
            var visualGroupIds: [Int] = []
            for memberIds in components {
                // TS:318 —— 组内首成员（hashRows 按 photo_id 排序）的 hash 为代表。
                let firstHash = hashByPhotoId[memberIds[0]]!
                _ = try insertGroup.run([
                    .text(sessionId), .text("visual"), .null, .text(firstHash),
                    .int(Int64(memberIds.count)), .text(now),
                ])
                let groupId = Int(connection.lastInsertRowid)
                visualGroupIds.append(groupId)
                for photoId in memberIds {
                    let meta = photoMeta[photoId]
                    _ = try insertMember.run([
                        .int(Int64(groupId)), .text(photoId), .text(sessionId),
                        meta.map { .int($0.size) } ?? .null,
                        meta.map { .text($0.mtimeISO) } ?? .null,
                    ])
                }
            }
            return (exactGroupIds, visualGroupIds)
        }

        return try buildResult(exactGroupIds: groupIds.exact, visualGroupIds: groupIds.visual)
    }

    /// TS: getGroups —— duplicate.groups 命令；按 group_type, id 排序。
    public func getGroups(sessionId: String) throws -> [DuplicateGroup] {
        let groupRows = try connection.prepare("""
            SELECT * FROM duplicate_groups
            WHERE session_id = ?
            ORDER BY group_type, id
            """).query([.text(sessionId)])
        if groupRows.isEmpty { return [] }
        let memberMap = try fetchMembers(ids: groupRows.map { Int($0[0].intValue ?? 0) })
        return groupRows.map { row in
            makeGroup(row: row, memberMap: memberMap)
        }
    }

    /// TS: resolveGroup —— keep_one 按分数（size*1000 + mtimeMs）取最优保留，
    /// keep_all 全部保留；随后重算照片状态。
    public func resolveGroup(groupId: Int, resolution: DupResolution) throws {
        try connection.transaction {
            _ = try connection.prepare(
                "UPDATE duplicate_groups SET resolution = ? WHERE id = ?"
            ).run([.text(resolution.rawValue), .int(Int64(groupId))])

            let members = try connection.prepare(
                "SELECT * FROM duplicate_group_members WHERE group_id = ?"
            ).query([.int(Int64(groupId))])
            if members.isEmpty {
                throw DuplicateServiceError.groupNotFound(groupId)
            }

            if resolution == .keepAll {
                let updateMember = try connection.prepare(
                    "UPDATE duplicate_group_members SET is_kept = 1, resolution = ? WHERE id = ?"
                )
                for member in members {
                    _ = try updateMember.run([
                        .text(resolution.rawValue), .int(member[0].intValue ?? 0),
                    ])
                }
            } else {
                var bestId = members[0][0].intValue ?? 0
                var bestScore: Double = -1
                for member in members {
                    // TS: new Date(m.file_mtime || 0).getTime() —— null/空串 → 0，
                    // 非空非法串 → NaN（永不中选）。
                    let mtimeMs: Double
                    if let fileMtime = member[6].textValue, !fileMtime.isEmpty {
                        mtimeMs = tsDateParse(fileMtime) ?? .nan
                    } else {
                        mtimeMs = 0
                    }
                    let score = Double(member[5].intValue ?? 0) * 1000 + mtimeMs
                    if score > bestScore {
                        bestScore = score
                        bestId = member[0].intValue ?? 0
                    }
                }
                let updateMember = try connection.prepare(
                    "UPDATE duplicate_group_members SET is_kept = ?, resolution = ? WHERE id = ?"
                )
                for member in members {
                    let id = member[0].intValue ?? 0
                    _ = try updateMember.run([
                        .int(id == bestId ? 1 : 0), .text(resolution.rawValue), .int(id),
                    ])
                }
            }
            try recomputePhotoStatuses(members.compactMap { $0[2].textValue })
        }
    }

    /// TS: resolveMember —— 单成员保留/移除；resolution 只在未定（NULL）时写。
    public func resolveMember(memberId: Int, isKept: Bool) throws {
        try connection.transaction {
            _ = try connection.prepare("""
                UPDATE duplicate_group_members
                SET is_kept = ?, resolution = COALESCE(resolution, ?)
                WHERE id = ?
                """).run([
                    .int(isKept ? 1 : 0),
                    .text(isKept ? "keep_all" : "keep_one"),
                    .int(Int64(memberId)),
                ])
            let member = try connection.prepare(
                "SELECT photo_id FROM duplicate_group_members WHERE id = ?"
            ).get([.int(Int64(memberId))])
            guard let member else {
                throw DuplicateServiceError.memberNotFound(memberId)
            }
            try recomputePhotoStatuses([member[0].textValue ?? ""])
        }
    }

    // MARK: - 内部

    /// TS: recomputePhotoStatuses —— 任一 is_kept=0 成员 → 'removed'，否则 'ready'。
    private func recomputePhotoStatuses(_ photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        var seen = Set<String>()
        let uniqueIds = photoIds.filter { seen.insert($0).inserted }
        let placeholders = uniqueIds.map { _ in "?" }.joined(separator: ",")
        _ = try connection.prepare("""
            UPDATE photos
            SET status = CASE
              WHEN EXISTS (
                SELECT 1
                FROM duplicate_group_members dgm
                WHERE dgm.photo_id = photos.id
                  AND dgm.is_kept = 0
              ) THEN 'removed'
              ELSE 'ready'
            END
            WHERE id IN (\(placeholders))
            """).run(uniqueIds.map { .text($0) })
    }

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

    /// TS: buildResult/getGroups 的组读取（按 id 排序，成员 JOIN photos）。
    private func fetchGroups(ids: [Int]) throws -> [DuplicateGroup] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let groupRows = try connection.prepare(
            "SELECT * FROM duplicate_groups WHERE id IN (\(placeholders)) ORDER BY id"
        ).query(ids.map { .int(Int64($0)) })
        let memberMap = try fetchMembers(ids: ids)
        return groupRows.map { row in
            makeGroup(row: row, memberMap: memberMap)
        }
    }

    /// TS: duplicate_group_members JOIN photos（filepath/filename）按 dgm.id 排序。
    private func fetchMembers(ids: [Int]) throws -> [Int: [DuplicateGroupMember]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try connection.prepare("""
            SELECT dgm.*, p.filepath, p.filename
            FROM duplicate_group_members dgm
            JOIN photos p ON p.id = dgm.photo_id
            WHERE dgm.group_id IN (\(placeholders))
            ORDER BY dgm.id
            """).query(ids.map { .int(Int64($0)) })
        var memberMap: [Int: [DuplicateGroupMember]] = [:]
        for row in rows {
            let groupId = Int(row[1].intValue ?? 0)
            memberMap[groupId, default: []].append(DuplicateGroupMember(
                id: Int(row[0].intValue ?? 0),
                photoId: row[2].textValue ?? "",
                isKept: (row[4].intValue ?? 0) != 0,
                fileSize: row[5].intValue.map(Int.init),
                fileMtime: row[6].textValue,
                resolution: row[7].textValue,
                filepath: row[8].textValue ?? "",
                filename: row[9].textValue ?? ""
            ))
        }
        return memberMap
    }

    private func makeGroup(row: DBRow, memberMap: [Int: [DuplicateGroupMember]]) -> DuplicateGroup {
        let id = Int(row[0].intValue ?? 0)
        return DuplicateGroup(
            id: id,
            groupType: (row[2].textValue ?? "") == "exact" ? .exact : .visual,
            checksum: row[3].textValue,
            hashHex: row[4].textValue,
            memberCount: Int(row[5].intValue ?? 0),
            members: memberMap[id] ?? [],
            resolution: row[6].textValue,
            createdAt: row[7].textValue ?? ""
        )
    }

    /// TS: sha256File —— crypto.createHash('sha256') 的 hex（小写）。
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 私有行类型

/// TS: photos 行的字段子集（_scanDuplicates 读取）。
private struct DuplicatePhotoRow {
    let id: String
    let filepath: String
    let checksum: String
    let checksumFileSize: Int64
    let checksumFileMtimeMs: Double
}

/// TS: fs.stat 结果（_scanDuplicates stat 阶段）。
private struct PhotoStat {
    let size: Int64
    let mtimeMs: Double
    let mtimeISO: String
}

// MARK: - 并发批量（TS utils/async.ts batchAsync 的滑动窗口实现）

/// 共享取号游标：worker 从游标取下一个未分配项索引；失败后停止调度。
private final class BatchCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var failed = false
    private let count: Int

    init(count: Int) { self.count = count }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if failed || next >= count { return nil }
        defer { next += 1 }
        return next
    }

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}

/// TS: batchAsync —— 固定数量常驻 runner 从共享游标取任务（滑动窗口，慢项不
/// 阻塞整批）；结果按输入索引收集保持顺序；首个失败停止调度、在飞项跑完，
/// 错误按完成序取第一个（与 TS 语义一致）。
fileprivate func batchAsync<T, R>(
    _ items: [T],
    concurrency: Int,
    body: @escaping (T) async throws -> R
) async throws -> [R] {
    let limit = max(1, concurrency)
    guard !items.isEmpty else { return [] }
    let cursor = BatchCursor(count: items.count)
    var collected: [(index: Int, value: R)] = []
    try await withThrowingTaskGroup(of: [(Int, R)].self) { group in
        for _ in 0..<min(limit, items.count) {
            group.addTask {
                var local: [(Int, R)] = []
                while !Task.isCancelled, let index = cursor.nextIndex() {
                    do {
                        local.append((index, try await body(items[index])))
                    } catch {
                        cursor.markFailed()
                        throw error
                    }
                }
                return local
            }
        }
        for try await chunk in group {
            collected.append(contentsOf: chunk)
        }
    }
    collected.sort { $0.index < $1.index }
    return collected.map(\.value)
}
