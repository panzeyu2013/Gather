// desktop/native/gather-core/Sources/GatherCore/Runtime/Duplicate/DuplicateRuntime.swift
// W2c：DuplicateRuntime actor —— 扫描管线编排 + 分组决议
// （旧 Services/DuplicateService.swift 的 Runtime 化，SQL/IO 全部下沉 Store）。
//
// 边界与语义（docs/ARCHITECTURE-W2C-DESIGN.md §2.3）：
// - actor 可变状态仅 scanFlight：同参数共享在飞结果、异参数抛
//   DuplicateError.scanBusy、成功/失败都释放；占用检查 + 登记为同步前缀
//   （中间无 await），并发调用 TOCTOU 免疫。
// - stat / sha256 走 ConcurrentMap.run（并发常量 32 / 2，定义在纯函数层）；
//   视觉聚类走 Task.detached —— actor 内不执行阻塞 IO 与长同步 CPU。
// - 写路径全部为 Store 单事务：writeScanResults（checksum 回写 + hash UPSERT）、
//   rebuildGroups（状态复位 + 整组重建）、applyResolution / resolveMember
//   （成员写入 + 照片状态重算）；本文件零 SQL、零锁、零 unchecked 并发标注。
// - 语义修正：sha256 流式（SHA256.stream，内存有界）；成员 = dgm.id 序、
//   组 = id 序（Store 保证）；keep_one 打分经纯函数
//   DuplicateAssembler.keptMemberIds；Store 的 DuplicateStoreError 映射回
//   DuplicateError（错误消息逐字对齐旧实现）。

import Foundation

public actor DuplicateRuntime {
    /// TS: ImageService.getThumbnail(filepath, 256) → 9x8 灰度像素网格。
    public typealias ThumbnailProvider = (String, Int) async -> [UInt8]?
    /// TS: clusterHashesInWorker（threshold, minGroupSize=2, mode='global'）。
    public typealias ClusterProvider = DuplicateClusterProvider
    /// TS: onProgress(current, total, message)。
    public typealias ProgressHandler = (Int, Int, String) -> Void

    private let store: any DuplicateStore
    private let thumbnailProvider: ThumbnailProvider
    private let clusterProvider: ClusterProvider

    /// 在飞扫描（值类型）：同参数调用共享该 Task，异参数调用抛 scanBusy。
    private struct ScanFlight {
        let sessionId: String
        let visualThreshold: Int?
        let task: Task<DuplicateScanResult, any Error>
    }

    /// 唯一可变状态：在飞扫描。仅注册方在结束（成功/失败）后释放。
    private var scanFlight: ScanFlight?

    public init(
        store: any DuplicateStore,
        thumbnailProvider: @escaping ThumbnailProvider = { _, _ in nil },
        clusterProvider: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        }
    ) {
        self.store = store
        self.thumbnailProvider = thumbnailProvider
        self.clusterProvider = clusterProvider
    }

    // MARK: - 扫描（单飞）

    /// TS: scanDuplicates —— 单飞扫描。busy 时同参数返回同一在飞结果，
    /// 不同参数抛 scanBusy。同步前缀（首个 await 之前）完成占用检查与登记。
    public func scanDuplicates(
        sessionId: String,
        visualThreshold: Int? = nil,
        signal: JobAbortSignal? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> DuplicateScanResult {
        if let flight = scanFlight {
            if flight.sessionId == sessionId && flight.visualThreshold == visualThreshold {
                // 同参数：共享在飞 promise（不重新登记）。
                return try await flight.task.value
            }
            throw DuplicateError.scanBusy
        }

        let task = Task {
            try await self.performScan(
                sessionId: sessionId,
                visualThreshold: visualThreshold,
                signal: signal,
                onProgress: onProgress
            )
        }
        scanFlight = ScanFlight(sessionId: sessionId, visualThreshold: visualThreshold, task: task)
        // TS finally：成功/失败路径都释放单飞占用。
        defer { scanFlight = nil }
        return try await task.value
    }

    // MARK: - 分组读取与决议

    /// TS: getGroups —— duplicate.groups 命令；按 group_type, id 排序。
    public func getGroups(sessionId: String) async throws -> [DuplicateGroup] {
        let records = try await store.groups(sessionId: sessionId)
        guard !records.isEmpty else { return [] }
        let members = try await memberRows(groupIds: records.map(\.id))
        return DuplicateAssembler.groups(records: records, members: members)
    }

    /// TS: resolveGroup —— keep_one 按分数（size*1000 + mtimeMs）取最优保留，
    /// keep_all 全部保留；随后重算照片状态。成员/照片写入 + 状态重算在 Store
    /// 单事务内完成（applyResolution），打分用纯函数。
    public func resolveGroup(groupId: Int, resolution: DupResolution) async throws {
        let members = try await store.members(groupId: groupId)
        guard !members.isEmpty else { throw DuplicateError.groupNotFound(groupId) }

        let rows = members.map(Self.memberRow(from:))
        let keptMemberIds = DuplicateAssembler.keptMemberIds(members: rows, resolution: resolution)
        do {
            try await store.applyResolution(
                groupId: groupId,
                resolution: resolution.rawValue,
                keptMemberIds: keptMemberIds
            )
        } catch DuplicateStoreError.groupNotFound(let missingGroupId) {
            throw DuplicateError.groupNotFound(missingGroupId)
        }
    }

    /// TS: resolveMember —— 单成员保留/移除；resolution 只在未定（NULL）时写，
    /// 照片状态重算与成员写入同事务（Store 内完成）。
    public func resolveMember(memberId: Int, isKept: Bool) async throws {
        do {
            _ = try await store.resolveMember(memberId: memberId, isKept: isKept)
        } catch DuplicateStoreError.memberNotFound(let missingMemberId) {
            throw DuplicateError.memberNotFound(missingMemberId)
        }
    }

    // MARK: - 扫描管线（TS: _scanDuplicates）

    /// 多阶段管线：stat（并发 32）→ sha256（并发 2）→ 视觉 hash（并发 8）→
    /// 落库（checksum + similarity_hashes）→ 精确/视觉聚类 → 重建分组。
    private func performScan(
        sessionId: String,
        visualThreshold: Int?,
        signal: JobAbortSignal?,
        onProgress: ProgressHandler?
    ) async throws -> DuplicateScanResult {
        // TS:87 —— 已中止则立即抛取消。
        if signal?.aborted ?? false { throw JobCancelledError() }
        let threshold = visualThreshold ?? DuplicateScanPipeline.defaultVisualThreshold
        let now = nowISOString()

        let allPhotos = try await store.photos(sessionId: sessionId)
        let totalUnits = allPhotos.count * 3

        // TS:114-130 —— stat 阶段（并发 32），不可读文件跳过。
        let statResults = try await ConcurrentMap.run(
            allPhotos,
            concurrency: DuplicateScanPipeline.statConcurrency
        ) { photo -> DuplicateScanPipeline.FileStat? in
            if signal?.aborted ?? false { throw JobCancelledError() }
            guard let stat = tsStat(photo.filepath) else { return nil }
            return DuplicateScanPipeline.FileStat(
                size: stat.size,
                mtimeMs: stat.mtimeMs,
                mtimeISO: isoString(Date(timeIntervalSince1970: stat.mtimeMs / 1000))
            )
        }
        var photoMeta: [String: DuplicateScanPipeline.FileStat] = [:]
        photoMeta.reserveCapacity(allPhotos.count)
        for (index, photo) in allPhotos.enumerated() {
            guard let meta = statResults[index] else { continue }
            photoMeta[photo.id] = meta
        }
        let sizeGroups = DuplicateScanPipeline.sizeGroups(photos: allPhotos, stats: photoMeta)
        onProgress?(allPhotos.count, totalUnits, "duplicate.read")

        // TS:132-153 —— 存储的 checksum 与 size/mtime 一致则复用，否则进候选。
        var resolvedChecksums = DuplicateScanPipeline.checksumReuse(photos: allPhotos, stats: photoMeta)
        let candidates = DuplicateScanPipeline.checksumCandidates(
            sizeGroups: sizeGroups,
            resolvedChecksums: resolvedChecksums,
            photos: allPhotos
        )

        // TS:155-168 —— sha256 阶段（并发 2，流式），不可读文件跳过。
        let hashResults = try await ConcurrentMap.run(
            candidates,
            concurrency: DuplicateScanPipeline.checksumConcurrency
        ) { photo -> String? in
            if signal?.aborted ?? false { throw JobCancelledError() }
            return try? SHA256.stream(file: photo.filepath)
        }
        for (index, photo) in candidates.enumerated() {
            if let checksum = hashResults[index] {
                resolvedChecksums[photo.id] = checksum
            }
        }
        onProgress?(allPhotos.count + candidates.count, totalUnits, "duplicate.hash")

        // TS:170-190 —— 视觉 hash 复用（size/mtime 一致时直接采用），miss 重算。
        let visualRows = try await store.visualHashes(sessionId: sessionId)
        let (reusedVisualHashes, misses) = DuplicateScanPipeline.visualHashReuse(
            rows: visualRows,
            photos: allPhotos,
            stats: photoMeta
        )
        var resolvedVisualHashes = reusedVisualHashes
        // TS:191 —— 计算前复查。
        if signal?.aborted ?? false { throw JobCancelledError() }
        let computed = await DuplicateScanPipeline.computeVisualHashes(
            photos: misses.map { (id: $0.id, filepath: $0.filepath) },
            thumbnailProvider: thumbnailProvider
        )
        if !computed.failures.isEmpty {
            // corrupt / 不可解码图片不参与视觉聚类（旧实现静默 try?，此处保留
            // 行为但把失败照片数暴露到日志）。
            GatherLogger.log(
                "Duplicate scan skipped \(computed.failures.count) unreadable thumbnail(s)",
                level: .debug
            )
        }
        // TS:193-199 —— computeVisualHashes 不观察 abort，落库前必须复查：
        // 中途到达的取消不得写入 hash 与重建分组。
        if signal?.aborted ?? false { throw JobCancelledError() }
        for (photoId, hash) in computed.hashes {
            resolvedVisualHashes[photoId] = hash
        }
        onProgress?(totalUnits, totalUnits, "duplicate.done")

        // TS:202-231 —— 分析数据落库（checksum 回写 + similarity_hashes UPSERT，
        // Store 单事务）。
        try await store.writeScanResults(
            sessionId: sessionId,
            checksums: allPhotos.map { photo in
                let meta = photoMeta[photo.id]
                return DuplicateChecksumUpdate(
                    photoId: photo.id,
                    checksum: resolvedChecksums[photo.id] ?? "",
                    fileSize: meta?.size ?? 0,
                    fileMtimeMs: meta?.mtimeMs ?? 0
                )
            },
            visualHashes: resolvedVisualHashes.map { photoId, hash in
                let meta = photoMeta[photoId]
                return DuplicateHashUpsert(
                    photoId: photoId,
                    hashHex: hash,
                    fileSize: meta?.size ?? 0,
                    fileMtimeMs: meta?.mtimeMs ?? 0
                )
            }
        )

        // TS:243-258 —— 精确分组：按 checksum 聚合（Swift 侧聚合，无 GROUP_CONCAT
        // 截断；旧实现的 PRAGMA group_concat_limit 已删除）。
        let exactGroups = try await store.exactDuplicateGroups(sessionId: sessionId)
        let exactPhotoIds = Set(exactGroups.flatMap(\.photoIds))

        // TS:260-274 —— 视觉聚类输入：排除精确重复照片（photo_id 序）。
        let hashRows = try await store.hashesForClustering(sessionId: sessionId)
        let (entries, hashByPhotoId) = DuplicateScanPipeline.visualClusteringEntries(
            rows: hashRows,
            exactPhotoIds: exactPhotoIds
        )

        // TS:275-288 —— hash 行 ≥2 才聚类；聚类为长同步 CPU，出 actor 执行。
        let components = try await Self.cluster(
            entries: entries,
            threshold: threshold,
            provider: clusterProvider
        )
        // TS worker 内可被 abort 拒绝；Swift 聚类返回后补查（对齐旧实现：
        // 更严格，取消不落库）。
        if signal?.aborted ?? false { throw JobCancelledError() }

        // TS:292-329 —— 重建分组事务：先复位旧成员（removed → ready）再整组
        // 删除重插，保证扫描结果幂等（Store 单事务）。
        let fileInfo = photoMeta.mapValues {
            DuplicateFileInfo(size: $0.size, mtimeISO: $0.mtimeISO)
        }
        let groupIds = try await store.rebuildGroups(
            sessionId: sessionId,
            exact: exactGroups,
            visual: components.map { memberIds in
                DuplicateVisualGroupInput(
                    hashHex: memberIds.first.flatMap { hashByPhotoId[$0] } ?? "",
                    photoIds: memberIds
                )
            },
            fileInfo: fileInfo,
            createdAt: now
        )

        return try await buildResult(exactGroupIds: groupIds.exact, visualGroupIds: groupIds.visual)
    }

    // MARK: - 私有

    /// TS: buildResult —— 按组 id 读取分组与成员，汇总 totalDuplicates。
    private func buildResult(exactGroupIds: [Int], visualGroupIds: [Int]) async throws -> DuplicateScanResult {
        let exact = try await groups(ids: exactGroupIds)
        let visual = try await groups(ids: visualGroupIds)
        return DuplicateAssembler.scanResult(exact: exact, visual: visual)
    }

    /// TS: buildResult/getGroups 的组读取（按 id 排序，成员 JOIN photos）。
    private func groups(ids: [Int]) async throws -> [DuplicateGroup] {
        guard !ids.isEmpty else { return [] }
        let records = try await store.groups(ids: ids)
        let members = try await memberRows(groupIds: records.map(\.id))
        return DuplicateAssembler.groups(records: records, members: members)
    }

    /// duplicate_group_members JOIN photos → DuplicateAssembler.MemberRow。
    private func memberRows(groupIds: [Int]) async throws -> [Int: [DuplicateAssembler.MemberRow]] {
        guard !groupIds.isEmpty else { return [:] }
        let records = try await store.membersWithPhoto(groupIds: groupIds)
        var rows: [Int: [DuplicateAssembler.MemberRow]] = [:]
        rows.reserveCapacity(records.count)
        for (groupId, members) in records {
            rows[groupId] = members.map(Self.memberRow(from:))
        }
        return rows
    }

    private static func memberRow(from member: DuplicateGroupMemberPhotoRecord) -> DuplicateAssembler.MemberRow {
        DuplicateAssembler.MemberRow(
            id: member.id,
            groupId: member.groupId,
            photoId: member.photoId,
            isKept: member.isKept,
            fileSize: member.fileSize,
            fileMtime: member.fileMtime,
            resolution: member.resolution,
            filepath: member.filepath,
            filename: member.filename
        )
    }

    private static func memberRow(from member: DuplicateGroupMemberRecord) -> DuplicateAssembler.MemberRow {
        DuplicateAssembler.MemberRow(
            id: member.id,
            groupId: member.groupId,
            photoId: member.photoId,
            isKept: member.isKept,
            fileSize: member.fileSize,
            fileMtime: member.fileMtime,
            resolution: member.resolution,
            filepath: "",
            filename: ""
        )
    }

    /// 视觉聚类（长同步 CPU）出 actor：detached 任务 + 注入 provider。
    private static func cluster(
        entries: [DuplicateHashPair],
        threshold: Int,
        provider: @escaping ClusterProvider
    ) async throws -> [[String]] {
        try await Task.detached(priority: .userInitiated) {
            try DuplicateScanPipeline.visualComponents(
                entries: entries,
                threshold: threshold,
                clusterProvider: provider
            )
        }.value
    }
}
