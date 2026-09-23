// desktop/native/gather-core/Sources/GatherCore/Services/IndexerService.swift
// TS 源: desktop/src/main/services/indexer/index.service.ts（Phase 3.0 移植，
// 只移植扫描/索引核心 + checksum 回填；watcher 段已由 2.4 Watch/Coordinator.swift
// 完成，本服务经 scanHandler(sessionId, requestedPaths) 向其提供 fullScan 能力）
//
// 移植差异说明（均为有意取舍，行为语义逐条对齐）：
// - 目录遍历为单生产者顺序递归 + 有界通道（容量对齐 TS WALK_CHANNEL_CAPACITY）：
//   文件恰产出一次、不可读非根目录报 failed、排除根跳过、不可读根抛错——
//   与 TS 并行 walk 的对外语义一致；路径产出顺序为排序后的 DFS（TS 并行序
//   不可预期，测试不依赖）。
// - scanBatch 内部并发（SCAN_BATCH_CONCURRENCY=4）用 mapConcurrent 滑动窗口；
//   discoveredSet 等共享状态的写集中在串行提交阶段（TS 单线程天然安全）。
// - stat 经 public stat 接缝注入（TS 同款测试接缝）；checksum 经 fileHasher
//   注入（新增接缝，用于并发写入竞态测试；默认 = 整文件 SHA256，与 TS
//   createReadStream 流式 sha256 结果逐字节一致）。
// - backfill 的 keyset 分页直接走 PhotoRepo.getBySessionPage（Swift 侧 repo
//   恒定存在，无需 TS 的 feature-detection 回退）。
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum IndexerServiceError: Error, Equatable {
    case sessionNotFound
    case noSourcePath
}

/// TS 错误消息逐字对齐（executor 失败路径以 String(describing:) 记录，
/// 必须等于 TS error.message）。
extension IndexerServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sessionNotFound: "SESSION_NOT_FOUND"
        case .noSourcePath: "INDEX_SESSION_NO_SOURCE"
        }
    }
}

/// TS 错误码映射（桥接层序列化用）。
extension IndexerServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .noSourcePath: .INDEX_SESSION_NO_SOURCE
        }
    }
}

public final class IndexerService {
    /// TS: SUPPORTED（index.service.ts 顶部）。
    public static let supportedExtensions: Set<String> = [
        ".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif",
        ".nef", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw",
        ".tif", ".tiff", ".psd",
    ]
    /// TS: WALK_CHANNEL_CAPACITY。
    public static let walkChannelCapacity = 256
    /// TS: IN_CHUNK_SIZE。
    public static let inChunkSize = 400
    /// TS: PRUNE_LIKE_PREFILTER_CAP。
    public static let pruneLikePrefilterCap = 200
    /// TS: CHECKSUM_BACKFILL_BATCH / CHECKSUM_BACKFILL_CONCURRENCY /
    /// CHECKSUM_BACKFILL_PAGE_SIZE。
    public static let checksumBackfillBatch = 32
    public static let checksumBackfillConcurrency = 6
    public static let checksumBackfillPageSize = 2000
    /// TS: SCAN_BATCH_CONCURRENCY / SCAN_BATCH_FILES。
    public static let scanBatchConcurrency = 4
    public static let scanBatchFiles = 32

    /// stat 结果（TS stat() 的字段子集）。
    public typealias FileStat = (size: Int64, mtimeMs: Double, dev: Int64, ino: Int64, isFile: Bool)
    /// 图片尺寸提供者（TS: imageService.getDimensions）。
    public typealias DimensionsProvider = (String) throws -> (width: Int, height: Int)
    /// 设置读取（TS: settings.get(key, defaultValue)）。
    public typealias SettingReader = (String, String) -> String

    private let connection: DBConnection
    private let sessionRepo: SessionRepo
    private let photoRepo: PhotoRepo
    private let assetStore: any AssetStore
    private let getDimensions: DimensionsProvider
    private let getSetting: SettingReader

    /// TS: public stat 测试接缝 —— 增量扫描用 stat，可覆写以模拟目录列举与
    /// stat 之间文件消失（ghost photo 竞态）。
    public var stat: (String) throws -> FileStat = IndexerService.defaultStat
    /// checksum 计算接缝（默认整文件 SHA256 hex；测试注入并发写入者）。
    public var fileHasher: (String) throws -> String = IndexerService.sha256File

    public init(
        connection: DBConnection,
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        assetStore: any AssetStore,
        getDimensions: @escaping DimensionsProvider = IndexerService.defaultDimensions,
        getSetting: @escaping SettingReader = { _, defaultValue in defaultValue }
    ) {
        self.connection = connection
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.assetStore = assetStore
        self.getDimensions = getDimensions
        self.getSetting = getSetting
    }

    /// 默认 stat（TS stat 语义：缺失抛错，消息格式对齐 Node ENOENT）。
    public static func defaultStat(_ path: String) throws -> FileStat {
        guard let info = tsStat(path) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoSuchFileError,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: "ENOENT: no such file or directory, stat '\(path)'",
                ]
            )
        }
        return (
            size: info.size,
            mtimeMs: info.mtimeMs,
            dev: info.dev,
            ino: info.ino,
            isFile: info.isFile
        )
    }

    /// 默认图片尺寸读取（macOS 走 RAWDecoder，其余平台不可用即抛错）。
    public static func defaultDimensions(_ path: String) throws -> (width: Int, height: Int) {
        #if canImport(ImageIO)
        return try RAWDecoder.getDimensions(path: path)
        #else
        throw IndexerServiceError.noSourcePath
        #endif
    }

    /// TS: sha256File —— 整文件 SHA256 hex（小写，逐字节对齐 createReadStream 流式）。
    public static func sha256File(_ filePath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }

    /// TS: canonicalPath —— realpath，失败回退 textualPath（macOS /var、/tmp 前缀）。
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return textualPath(path)
    }

    /// TS: textualPath —— 仅解析 macOS 的两个符号链接前缀，避免逐文件 realpath。
    public static func textualPath(_ value: String) -> String {
        let resolved = TSPath.resolve(value)
        if resolved == "/var" || resolved.hasPrefix("/var/") {
            return "/private" + resolved
        }
        if resolved == "/tmp" || resolved.hasPrefix("/tmp/") {
            return "/private" + resolved
        }
        return resolved
    }

    /// TS: isWithin —— 候选路径是否落在规范根之内。
    public static func isWithin(candidate: String, canonicalRoot: String) -> Bool {
        let relative = TSPath.relative(canonicalRoot, to: textualPath(candidate))
        return relative == "" || (!relative.hasPrefix("..") && !TSPath.isAbsolute(relative))
    }

    /// TS: managedCacheRoots —— disk_cache_dir 设置优先，否则默认缓存目录。
    private func managedCacheRoots() -> [String] {
        let configured = getSetting("disk_cache_dir", "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return [Self.canonicalPath(configured)] }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Application Support/Gather/thumbnails（应用数据目录在
            // macOS 即 Application Support/<app>）。
            return [Self.canonicalPath(appSupport.appendingPathComponent("thumbnails").path)]
        }
        return []
    }

    // ─────────────────────────── 扫描 ───────────────────────────

    /// TS: scanSession —— 全量/增量扫描 + 索引入库 + 缺失对账 + index_seq 游标。
    /// requestedPaths=nil 时走目录遍历（fullScan）；非 nil 时只处理候选路径。
    /// 该方法是 WatchCoordinator fullScan/incremental 回调的服务端实现。
    public func scanSession(
        sessionId: String,
        requestedPaths: [String]? = nil,
        context: JobRunContext? = nil
    ) async throws -> IndexScanResult {
        let session = try self.sessionRepo.get(id: sessionId)
        guard let session else { throw IndexerServiceError.sessionNotFound }
        guard !session.sourcePath.isEmpty else { throw IndexerServiceError.noSourcePath }
        let excludedRoots = managedCacheRoots()
        var existing = try self.photoRepo.getBySessionProjection(sessionId: sessionId)
        // 生成缓存目录内的存量照片（缓存清扫）：事务内删除照片行 + 孤儿资产行。
        let generatedCachePhotos = existing.filter { photo in
            excludedRoots.contains { Self.isWithin(candidate: TSPath.resolve(photo.filepath), canonicalRoot: $0) }
        }
        if !generatedCachePhotos.isEmpty {
            let photoIds = generatedCachePhotos.map(\.id)
            let fileIds = generatedCachePhotos.compactMap(\.assetFileId)
            try self.connection.transaction {
                for chunk in chunked(photoIds) {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                    _ = try self.connection.prepare("DELETE FROM photos WHERE id IN (\(placeholders))")
                        .run(chunk.map { .text($0) })
                }
                _ = try self.connection.prepare("""
                    DELETE FROM session_assets
                    WHERE session_id = ? AND NOT EXISTS (
                      SELECT 1 FROM photos p
                      WHERE p.session_id = session_assets.session_id
                        AND p.asset_id = session_assets.asset_id
                    )
                  """).run([.text(sessionId)])
                if !fileIds.isEmpty {
                    for chunk in chunked(fileIds) {
                        let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                        _ = try self.connection.prepare("""
                            DELETE FROM asset_files
                            WHERE id IN (\(placeholders))
                              AND NOT EXISTS (SELECT 1 FROM photos p WHERE p.asset_file_id = asset_files.id)
                          """).run(chunk.map { .text($0) })
                    }
                    _ = try self.connection.prepare("""
                        DELETE FROM assets
                        WHERE NOT EXISTS (SELECT 1 FROM asset_members am WHERE am.asset_id = assets.id)
                      """).run()
                }
            }
            let removedIds = Set(photoIds)
            existing = existing.filter { !removedIds.contains($0.id) }
        }

        let existingByPath: [String: PhotoProjectionRow] = Dictionary(
            uniqueKeysWithValues: existing.map { (TSPath.normalize(TSPath.resolve($0.filepath)), $0) }
        )
        let fileRows = try self.connection.prepare("""
            SELECT af.id, af.file_size, af.file_mtime_ms, af.checksum
            FROM asset_files af
            JOIN photos p ON p.asset_file_id = af.id
            WHERE p.session_id = ?
          """).query([.text(sessionId)])
        var fileStats: [String: (id: String, fileSize: Int64, fileMtimeMs: Double, checksum: String)] = [:]
        for row in fileRows {
            let id = row[0].textValue ?? ""
            fileStats[id] = (
                id: id,
                fileSize: row[1].intValue ?? 0,
                fileMtimeMs: row[2].doubleValue ?? 0,
                checksum: row[3].textValue ?? ""
            )
        }

        var discoveredSet = Set<String>()
        var relinkedPhotoIds = Set<String>()
        var failed: [String] = []
        var discovered = 0
        var added = 0
        var skipped = 0
        // 内容变化的存量照片计数（连同 added/relinked/missing 驱动 index_seq）。
        var updatedExistingPhotos = 0
        // 提前声明：扫描中途取消/出错时 catch 路径需要判断是否发生过变更
        // （此时尚未做对账，保持空）。
        var missing: [PhotoProjectionRow] = []

        /// TS: scanBatch —— 一批文件的 stat/尺寸/checksum（并发 4）+ 单事务提交。
        let scanBatch: ([String]) async throws -> Void = { filepaths in
            try await context?.throwIfCancelled()
            // 懒校验模式：新/变文件只记尺寸，checksum 交给后台 checksum.backfill。
            let lazyChecksum = self.getSetting("lazy_checksum", "true") != "false"
            let results = try await mapConcurrent(filepaths, concurrency: Self.scanBatchConcurrency) { filepath -> BatchOutcome in
                let normalized = TSPath.normalize(TSPath.resolve(filepath))
                // stat 先行：目录列举与 stat 之间消失的文件不得进入 discoveredSet，
                // 否则末段永远不会把它对账为 missing（ghost photo）。
                let source: FileStat
                do {
                    source = try self.stat(filepath)
                } catch {
                    return BatchOutcome(normalized: normalized, item: .missing)
                }
                guard let photo = existingByPath[normalized] else {
                    do {
                        let dimensions = try self.getDimensions(filepath)
                        let checksum = lazyChecksum ? "" : try self.fileHasher(filepath)
                        return BatchOutcome(normalized: normalized, item: .new(
                            filepath: filepath, width: dimensions.width, height: dimensions.height,
                            checksum: checksum, fileSize: source.size, fileMtimeMs: source.mtimeMs,
                            fileIdentity: String(source.ino)
                        ))
                    } catch {
                        return BatchOutcome(normalized: normalized, item: .failed(filepath: filepath))
                    }
                }
                let indexed = photo.assetFileId.flatMap { fileStats[$0] }
                // 仅当基线证明文件确实变化才算 content-changed：无 asset_files
                // 行时用照片自身的索引 stat（checksum_file_size/mtime）作基线，
                // 否则每次重扫都 bump index_seq（TS 注释原话）。
                let contentChanged: Bool
                if let indexed {
                    contentChanged = indexed.fileSize != source.size
                        || abs(indexed.fileMtimeMs - source.mtimeMs) >= 1
                } else {
                    contentChanged = !(photo.checksumFileSize > 0
                        && Int64(photo.checksumFileSize) == source.size
                        && abs(photo.checksumFileMtimeMs - source.mtimeMs) < 1)
                }
                if !contentChanged && photo.status != "missing" && !(indexed?.checksum.isEmpty ?? true) {
                    return BatchOutcome(normalized: normalized, item: .unchanged)
                }
                do {
                    let dimensions = try self.getDimensions(filepath)
                    let needsChecksum = contentChanged || (indexed?.checksum.isEmpty ?? true)
                    let checksum: String
                    if needsChecksum {
                        checksum = lazyChecksum ? "" : try self.fileHasher(filepath)
                    } else {
                        checksum = indexed!.checksum
                    }
                    // 懒模式 + 未变化 + 快照 checksum 为空：不得清掉并发 backfill
                    // 刚写入的哈希（TS preserveChecksum 语义）。
                    let preserveChecksum = lazyChecksum && !contentChanged
                        && (indexed == nil || indexed!.checksum.isEmpty)
                    return BatchOutcome(normalized: normalized, item: .existing(
                        photoId: photo.id, assetFileId: photo.assetFileId,
                        width: dimensions.width, height: dimensions.height,
                        contentChanged: contentChanged, fileSize: source.size,
                        fileMtimeMs: source.mtimeMs, checksum: checksum,
                        preserveChecksum: preserveChecksum,
                        volumeId: "dev:\(source.dev)", fileIdentity: String(source.ino)
                    ))
                } catch {
                    return BatchOutcome(normalized: normalized, item: .failed(filepath: filepath))
                }
            }

            var newEntries: [NewEntry] = []
            // 本批路径/内容变化的照片：会话级失效（簇删除、导航组剪枝）每批一次。
            var batchAffectedPhotoIds = Set<String>()
            // Store 连接不参与旧事务：relink 探测先行（每文件一次），结果带入事务。
            var relinkResults: [String: AssetRelinkFileResult?] = [:]
            var relinkFailed = Set<String>()
            for outcome in results {
                if case .new(let filepath, _, _, let checksum, let fileSize, let fileMtimeMs, let fileIdentity) = outcome.item {
                    do {
                        relinkResults[filepath] = try await self.assetStore.relinkMovedFile(
                            newPath: filepath, checksum: checksum, fileSize: fileSize,
                            fileMtimeMs: fileMtimeMs, fileIdentity: fileIdentity
                        )
                    } catch {
                        if error is DBError { throw error }
                        relinkFailed.insert(filepath)
                    }
                }
            }
            // 全部写在一个事务内（曾为每文件一事务 ≈ 每批 32 次 fsync）。
            try self.connection.transaction {
                for outcome in results {
                    switch outcome.item {
                    case .missing:
                        // 不进入 discoveredSet：由末段对账为 missing。
                        break
                    case .failed(let filepath):
                        discoveredSet.insert(outcome.normalized)
                        failed.append(filepath)
                    case .unchanged:
                        discoveredSet.insert(outcome.normalized)
                        skipped += 1
                    case .new(let filepath, let width, let height, let checksum, let fileSize, let fileMtimeMs, let fileIdentity):
                        discoveredSet.insert(outcome.normalized)
                        if relinkFailed.contains(filepath) {
                            // 单文件可恢复失败（XMP 写入中、sidecar 冲突等守卫）
                            // 不整批回滚；真实数据库错误才中止批事务。
                            failed.append(filepath)
                            continue
                        }
                        let relocated: AssetRelinkFileResult? = relinkResults[filepath] ?? nil
                        if let relocated, !relocated.photoIds.isEmpty {
                            for photoId in relocated.photoIds {
                                batchAffectedPhotoIds.insert(photoId)
                                relinkedPhotoIds.insert(photoId)
                                try self.photoRepo.updateIndexedFile(
                                    photoId: photoId, width: width, height: height, changed: true
                                )
                                try self.photoRepo.updateChecksum(
                                    photoId: photoId, checksum: checksum,
                                    fileSize: Int(fileSize), fileMtimeMs: fileMtimeMs
                                )
                            }
                            skipped += 1
                        } else {
                            newEntries.append(NewEntry(
                                filepath: filepath, width: width, height: height,
                                checksum: checksum, fileSize: fileSize, fileMtimeMs: fileMtimeMs
                            ))
                        }
                    case .existing(let photoId, let assetFileId, let width, let height, let contentChanged,
                                    let fileSize, let fileMtimeMs, let checksum, let preserveChecksum,
                                    let volumeId, let fileIdentity):
                        discoveredSet.insert(outcome.normalized)
                        if contentChanged {
                            updatedExistingPhotos += 1
                        }
                        try self.photoRepo.updateIndexedFile(
                            photoId: photoId, width: width, height: height, changed: contentChanged
                        )
                        // 懒模式 + 未变化 + 空快照 checksum：保留照片行已有值。
                        if !preserveChecksum {
                            try self.photoRepo.updateChecksum(
                                photoId: photoId, checksum: checksum,
                                fileSize: Int(fileSize), fileMtimeMs: fileMtimeMs
                            )
                        }
                        if let assetFileId {
                            let timestamp = nowISOString()
                            _ = try self.connection.prepare("""
                                UPDATE asset_files
                                SET volume_id = ?, file_identity = ?, file_size = ?, file_mtime_ms = ?,
                                    checksum = CASE WHEN ? = 1 THEN checksum ELSE ? END,
                                    online_status = 'online', last_seen_at = ?, updated_at = ?
                                WHERE id = ?
                              """).run([
                                .text(volumeId), .text(fileIdentity), .int(fileSize), .real(fileMtimeMs),
                                .int(preserveChecksum ? 1 : 0), .text(checksum),
                                .text(timestamp), .text(timestamp), .text(assetFileId),
                            ])
                            if contentChanged {
                                let photoIds = try self.connection.prepare(
                                    "SELECT id FROM photos WHERE asset_file_id = ?"
                                ).query([.text(assetFileId)]).compactMap { $0[0].textValue }
                                for photoId in photoIds {
                                    batchAffectedPhotoIds.insert(photoId)
                                }
                                // 文件级清扫：先前照片删除留下的孤儿 analysis 行。
                                _ = try self.connection.prepare(
                                    "DELETE FROM asset_analysis WHERE asset_file_id = ?"
                                ).run([.text(assetFileId)])
                                _ = try self.connection.prepare("""
                                    UPDATE photos
                                    SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                                        width = ?, height = ?, updated_at = ?
                                    WHERE asset_file_id = ?
                                  """).run([
                                    .text(checksum), .int(fileSize), .real(fileMtimeMs),
                                    .int(Int64(width)), .int(Int64(height)),
                                    .text(timestamp), .text(assetFileId),
                                ])
                            }
                        }
                    }
                }
            }
            // 批提交成功后做一次失效（提交失败则回滚，analysis 输入保持有效）。
            try self.invalidatePathDependentAnalysis(photoIds: Array(batchAffectedPhotoIds))
            if !newEntries.isEmpty {
                let inserted = try self.photoRepo.addPhotos(
                    sessionId: sessionId,
                    filepaths: newEntries.map { PhotoAddInput(filepath: $0.filepath, width: $0.width, height: $0.height) },
                    "index"
                )
                added += inserted.added
                skipped += inserted.skipped
                // addPhotos 返回每个新行的 id：checksum 无需重读整表写入
                // （TS：曾在此 getBySessionProjection，首导入 O(n²)）。
                for (index, entry) in newEntries.enumerated() {
                    guard index < inserted.ids.count, !inserted.ids[index].isEmpty else { continue }
                    try self.photoRepo.updateChecksum(
                        photoId: inserted.ids[index], checksum: entry.checksum,
                        fileSize: Int(entry.fileSize), fileMtimeMs: entry.fileMtimeMs
                    )
                }
            }
        }

        // 扫描 + 终态提交整体受保护：批次提交后发生的取消/错误不得吞掉
        // index_seq bump。index_seq 是分析过期游标（sessions.index_seq vs
        // analysis_runs.index_seq）——批次已提交的新照片对已完成分析
        // （sim/fkw）的可见性完全依赖它推进；任何终态只要发生过真实变更
        // 都必须 bump（TS「任何批次提交后都 bump」语义）。
        do {
            if let requestedPaths {
                var candidates: [String] = []
                for filepath in Set(requestedPaths.map { TSPath.resolve($0) }) {
                    if excludedRoots.contains(where: { Self.isWithin(candidate: filepath, canonicalRoot: $0) }) { continue }
                    do {
                        let source = try self.stat(filepath)
                        if source.isFile && Self.supportedExtensions.contains(TSPath.extname(filepath).lowercased()) {
                            candidates.append(filepath)
                            discovered += 1
                        }
                    } catch {
                        // 缺失路径在下方对账。
                    }
                }
                if !candidates.isEmpty { try await scanBatch(candidates) }
            } else {
                // 生产者/消费者：walk 经有界通道流式产出，scanBatch 按 32 个一批消费。
                let channel = WalkChannel(capacity: Self.walkChannelCapacity)
                let producer = Task {
                    await Self.traverse(
                        directory: session.sourcePath,
                        isRoot: true,
                        excludedRoots: excludedRoots,
                        channel: channel
                    )
                    channel.close()
                }
                // 消费者提前退出（错误/取消）时解除阻塞中的生产者（TS walk 的
                // finally close 语义）。
                defer { channel.close() }
                var pending: [String] = []
                var keepGoing = true
                while keepGoing {
                    let event: WalkEvent
                    do {
                        event = try await channel.pull()
                    } catch {
                        await producer.value
                        throw error
                    }
                    switch event {
                    case .done:
                        keepGoing = false
                    case .unreadableDirectory(let directory):
                        failed.append(directory)
                    case .file(let filepath):
                        try await context?.throwIfCancelled()
                        discovered += 1
                        await context?.updateProgress(JobProgressUpdate(
                            current: discovered, total: 0, phase: "index.scanning"
                        ))
                        pending.append(filepath)
                        if pending.count >= Self.scanBatchFiles {
                            try await scanBatch(pending)
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !pending.isEmpty { try await scanBatch(pending) }
            }

            let requestedNormalized: Set<String>? = requestedPaths.map {
                Set($0.map { TSPath.normalize(TSPath.resolve($0)) })
            }
            for photo in existing {
                let normalized = TSPath.normalize(TSPath.resolve(photo.filepath))
                let inRequested = requestedNormalized.map { $0.contains(normalized) } ?? true
                if inRequested
                    && !discoveredSet.contains(normalized)
                    && !relinkedPhotoIds.contains(photo.id) {
                    missing.append(photo)
                }
            }
            try self.photoRepo.markMissing(photoIds: missing.map(\.id))
            _ = try await self.assetStore.backfillSession(sessionId)
            // index_seq 是分析过期游标：仅在真实变更（新增/内容变/重链接/新增缺失）
            // 时 bump；空转扫描不得把分析标脏。
            let committedChanges = added > 0
                || updatedExistingPhotos > 0
                || !relinkedPhotoIds.isEmpty
                || !missing.isEmpty
            var finalCount = 0
            try self.connection.transaction {
                finalCount = try self.photoRepo.countBySession(sessionId: sessionId)
                try self.sessionRepo.updatePhotoCount(id: sessionId, count: finalCount)
                if committedChanges {
                    _ = try self.sessionRepo.bumpIndexSeq(id: sessionId)
                }
            }
            if finalCount > 0 && session.status == "draft" {
                try self.sessionRepo.updateStatus(id: sessionId, status: "photos_loaded")
            }
            if !missing.isEmpty {
                let fileIds = missing.compactMap(\.assetFileId)
                for chunk in chunked(fileIds) {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                    _ = try self.connection.prepare("""
                        UPDATE asset_files SET online_status = 'offline', updated_at = ?
                        WHERE id IN (\(placeholders))
                      """).run([.text(nowISOString())] + chunk.map { .text($0) })
                }
            }
            await context?.updateProgress(JobProgressUpdate(current: discovered, total: discovered, phase: "index.done"))
            return IndexScanResult(
                sessionId: sessionId,
                discovered: discovered,
                added: added,
                skipped: skipped,
                missing: missing.count,
                failed: failed
            )
        } catch {
            // 取消/失败路径同样推进已提交批次的 index_seq（独立事务，
            // best-effort 不掩盖原错误）：已导入照片对已完成分析可见。
            let committedChanges = added > 0
                || updatedExistingPhotos > 0
                || !relinkedPhotoIds.isEmpty
                || !missing.isEmpty
            if committedChanges {
                try? self.connection.transaction {
                    _ = try self.sessionRepo.bumpIndexSeq(id: sessionId)
                }
            }
            throw error
        }
    }

    // ─────────────────────────── checksum 回填 ───────────────────────────

    /// TS: pendingChecksums —— 会话内仍缺 checksum 的照片数（调用方决定是否
    /// 创建 checksum.backfill 任务）。
    public func pendingChecksums(sessionId: String) throws -> Int {
        try self.photoRepo.getBySessionProjection(sessionId: sessionId)
            .filter { $0.checksum.isEmpty && $0.status != "missing" }
            .count
    }

    /// TS: backfillChecksums —— 后台回填懒索引留下的空 checksum：循环直到无
    /// pending；每批 stat 取新鲜 size/mtime，乐观守卫（AND checksum = ''）保证
    /// 与并发扫描互不覆盖；不可读照片记入 per-job 失败集避免死循环。
    public func backfillChecksums(
        sessionId: String,
        context: JobRunContext? = nil
    ) async throws -> (processed: Int, backfilled: Int, skipped: Int) {
        var processed = 0
        var backfilled = 0
        var skipped = 0
        var failedPhotoIds = Set<String>()
        // Keyset 游标：首趟全扫，后续从最后 rowid 继续。
        var afterRowId: Int64?
        for _ in 0... {
            try await context?.throwIfCancelled()
            let (pending, lastRowId) = try loadPendingBackfill(
                sessionId: sessionId, afterRowId: afterRowId, failedPhotoIds: failedPhotoIds
            )
            if let lastRowId { afterRowId = lastRowId }
            if pending.isEmpty { break }
            await context?.updateProgress(JobProgressUpdate(
                current: 0, total: pending.count, phase: "index.checksum"
            ))
            var passBackfilled = 0
            for offset in stride(from: 0, to: pending.count, by: Self.checksumBackfillBatch) {
                try await context?.throwIfCancelled()
                let batch = Array(pending[offset..<min(offset + Self.checksumBackfillBatch, pending.count)])
                // 哈希阶段只读；全部写入进入单事务。
                let results = try await mapConcurrent(
                    batch, concurrency: Self.checksumBackfillConcurrency
                ) { photo -> (photo: PhotoPageRow, checksum: String, size: Int64, mtimeMs: Double)? in
                    do {
                        let source = try self.stat(photo.filepath)
                        let checksum = try self.fileHasher(photo.filepath)
                        return (photo, checksum, source.size, source.mtimeMs)
                    } catch {
                        // 已删除/不可读：本任务内放弃，循环得以终止；
                        // 下次全量扫描会标记 missing。
                        return nil
                    }
                }
                try self.connection.transaction {
                    for (index, result) in results.enumerated() {
                        guard let result else {
                            failedPhotoIds.insert(batch[index].id)
                            skipped += 1
                            processed += 1
                            continue
                        }
                        // 乐观填充：仅当照片 checksum 仍为空才写（并发扫描
                        // 刚写/清空的值不被覆盖）。
                        let photoChanges = try self.connection.prepare("""
                            UPDATE photos
                            SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                                updated_at = ?
                            WHERE id = ? AND checksum = ''
                          """).run([
                            .text(result.checksum), .int(result.size), .real(result.mtimeMs),
                            .text(nowISOString()), .text(result.photo.id),
                        ])
                        if photoChanges == 0 {
                            // 另一写入者已填充（或清空）：跳过资产行写入，
                            // 保持 photos 与 asset_files 一致。
                            skipped += 1
                        } else {
                            if let assetFileId = result.photo.assetFileId {
                                _ = try self.connection.prepare("""
                                    UPDATE asset_files
                                    SET checksum = ?, file_size = ?, file_mtime_ms = ?, updated_at = ?
                                    WHERE id = ? AND checksum = ''
                                  """).run([
                                    .text(result.checksum), .int(result.size), .real(result.mtimeMs),
                                    .text(nowISOString()), .text(assetFileId),
                                ])
                            }
                            passBackfilled += 1
                            backfilled += 1
                        }
                        processed += 1
                    }
                }
                await context?.updateProgress(JobProgressUpdate(current: processed, total: pending.count))
            }
            // 全部 pending 要么已失败要么重试只会重复失败：停止而非空转。
            if passBackfilled == 0 { break }
        }
        return (processed: processed, backfilled: backfilled, skipped: skipped)
    }

    /// TS: loadPendingBackfill —— keyset 分页扫描待回填照片。
    private func loadPendingBackfill(
        sessionId: String,
        afterRowId: Int64?,
        failedPhotoIds: Set<String>
    ) throws -> (rows: [PhotoPageRow], lastRowId: Int64?) {
        var rows: [PhotoPageRow] = []
        var cursor: Int64? = afterRowId
        var lastRowId: Int64?
        for _ in 0... {
            let page = try self.photoRepo.getBySessionPage(
                sessionId: sessionId, afterRowId: cursor, limit: Self.checksumBackfillPageSize
            )
            if page.isEmpty { break }
            lastRowId = page[page.count - 1].rowid
            for photo in page {
                if photo.checksum?.isEmpty ?? true,
                   photo.status != "missing",
                   !failedPhotoIds.contains(photo.id) {
                    rows.append(photo)
                }
            }
            cursor = lastRowId
        }
        return (rows, lastRowId)
    }

    // ─────────────────────────── 分析失效 ───────────────────────────

    /// TS: deletePhotoInputs —— 逐照片删除分析输入（photo_id 粒度）。
    private func deletePhotoInputs(photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        for chunk in chunked(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try self.connection.prepare(
                "DELETE FROM similarity_hashes WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
            _ = try self.connection.prepare(
                "DELETE FROM face_observations WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
            _ = try self.connection.prepare(
                "DELETE FROM face_analysis_state WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
            _ = try self.connection.prepare(
                "DELETE FROM asset_analysis WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
            _ = try self.connection.prepare(
                "DELETE FROM photo_metadata_cache WHERE photo_id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
        }
    }

    /// TS: pruneAutomaticNavigationGroups —— 只删实际含受影响照片的自动导航组；
    /// JSON 不可读的组保留不删。
    private func pruneAutomaticNavigationGroups(sessionId: String, photoIds: [String]) throws {
        let affected = Set(photoIds)
        var groups: [(id: String, photoIdsJSON: String)] = []
        if !photoIds.isEmpty && photoIds.count <= Self.pruneLikePrefilterCap {
            let conditions = photoIds.map { _ in "photo_ids_json LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            let patterns = photoIds.map { id -> String in
                let escaped = id
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                return "%\"\(escaped)\"%"
            }
            let rows = try self.connection.prepare("""
                SELECT id, photo_ids_json FROM navigation_groups
                WHERE session_id = ? AND source = 'automatic' AND (\(conditions))
              """).query([.text(sessionId)] + patterns.map { .text($0) })
            for row in rows {
                groups.append((row[0].textValue ?? "", row[1].textValue ?? ""))
            }
        } else {
            let rows = try self.connection.prepare("""
                SELECT id, photo_ids_json FROM navigation_groups
                WHERE session_id = ? AND source = 'automatic'
              """).query([.text(sessionId)])
            for row in rows {
                groups.append((row[0].textValue ?? "", row[1].textValue ?? ""))
            }
        }
        var doomed: [String] = []
        for group in groups {
            guard let parsed = try? JSONValue.parse(group.photoIdsJSON),
                  case .array(let members) = parsed else { continue }
            let containsAffected = members.contains { member in
                guard case .string(let value) = member else { return false }
                return affected.contains(value)
            }
            if containsAffected { doomed.append(group.id) }
        }
        for chunk in chunked(doomed) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try self.connection.prepare(
                "DELETE FROM navigation_groups WHERE id IN (\(placeholders))"
            ).run(chunk.map { .text($0) })
        }
    }

    /// TS: deleteGlobalClusterResults —— 会话级相似度簇结果失效。
    private func deleteGlobalClusterResults(sessionId: String) throws {
        _ = try self.connection.prepare("DELETE FROM similarity_results WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    /// TS: deleteFaceClusterResults —— 会话级人脸簇结果失效（成员先于观测删除）。
    private func deleteFaceClusterResults(sessionId: String) throws {
        _ = try self.connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?")
            .run([.text(sessionId)])
        _ = try self.connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?")
            .run([.text(sessionId)])
        _ = try self.connection.prepare("DELETE FROM role_bindings WHERE session_id = ?")
            .run([.text(sessionId)])
        _ = try self.connection.prepare("DELETE FROM face_clusters WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    /// TS: invalidatePathDependentAnalysis —— 路径/内容变化的照片：逐照片删输入、
    /// 按成员剪自动导航组、会话级丢簇结果；每批调用一次。
    private func invalidatePathDependentAnalysis(photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        var affectedSessions = Set<String>()
        for chunk in chunked(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try self.connection.prepare(
                "SELECT DISTINCT session_id FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            for row in rows {
                if let sessionId = row[0].textValue { affectedSessions.insert(sessionId) }
            }
        }
        var photoIdsBySession: [String: [String]] = [:]
        for chunk in chunked(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try self.connection.prepare(
                "SELECT id, session_id FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            for row in rows {
                guard let id = row[0].textValue, let sessionId = row[1].textValue else { continue }
                photoIdsBySession[sessionId, default: []].append(id)
            }
        }
        try self.connection.transaction {
            // 会话级簇结果先行：成员行必须先于其引用的观测删除。
            for sessionId in affectedSessions {
                try deleteFaceClusterResults(sessionId: sessionId)
                try deleteGlobalClusterResults(sessionId: sessionId)
            }
            try deletePhotoInputs(photoIds: photoIds)
            for (sessionId, sessionPhotoIds) in photoIdsBySession {
                try pruneAutomaticNavigationGroups(sessionId: sessionId, photoIds: sessionPhotoIds)
            }
        }
    }

    // ─────────────────────────── 遍历 ───────────────────────────

    /// TS: walk —— 顺序递归遍历（lstat 判目录，符号链接不进递归），
    /// 事件经有界通道流出；不可读非根目录产出 unreadableDirectory 事件，
    /// 不可读根直接抛错（rootError → channel.fail）。
    private static func traverse(
        directory: String,
        isRoot: Bool,
        excludedRoots: [String],
        channel: WalkChannel
    ) async {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            if isRoot {
                channel.fail(error)
            } else {
                await channel.push(.unreadableDirectory(directory))
            }
            return
        }
        for name in entries {
            let full = directory + "/" + name
            if excludedRoots.contains(where: { isWithin(candidate: full, canonicalRoot: $0) }) { continue }
            if isDirectory(full) {
                await traverse(directory: full, isRoot: false, excludedRoots: excludedRoots, channel: channel)
            } else if supportedExtensions.contains(TSPath.extname(name).lowercased()) {
                await channel.push(.file(full))
            }
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        // lstat 判定（符号链接不进入递归，与 TS opendir.isSymbolicLink 语义一致）；
        // 用文件级 lstatRef 规避成员 stat 遮蔽。
        var s = lstatBuf()
        return lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
    }

    private func chunked(_ values: [String]) -> [[String]] {
        var chunks: [[String]] = []
        for offset in stride(from: 0, to: values.count, by: Self.inChunkSize) {
            chunks.append(Array(values[offset..<min(offset + Self.inChunkSize, values.count)]))
        }
        return chunks
    }
}

// MARK: - 扫描载荷类型

/// 待入库新照片（TS scanBatch 的 newEntries 元素）。
private struct NewEntry {
    let filepath: String
    let width: Int
    let height: Int
    let checksum: String
    let fileSize: Int64
    let fileMtimeMs: Double
}

/// 单文件批处理结果（normalized 供串行阶段入 discoveredSet）。
private struct BatchOutcome {
    let normalized: String
    let item: BatchItem
}

private enum BatchItem {
    case new(filepath: String, width: Int, height: Int, checksum: String,
             fileSize: Int64, fileMtimeMs: Double, fileIdentity: String)
    case existing(photoId: String, assetFileId: String?, width: Int, height: Int,
                  contentChanged: Bool, fileSize: Int64, fileMtimeMs: Double,
                  checksum: String, preserveChecksum: Bool,
                  volumeId: String, fileIdentity: String)
    case unchanged
    case failed(filepath: String)
    case missing
}

/// lstat 缓冲（文件级辅助：规避 IndexerService.stat 成员对 POSIX stat 的遮蔽）。
private func lstatBuf() -> stat {
    stat()
}

/// 遍历事件（TS BoundedChannel 的元素 + onUnreadableDirectory 回调合流）。
private enum WalkEvent {
    case file(String)
    case unreadableDirectory(String)
    case done
}

/// TS: BoundedChannel —— 有界通道：生产者在缓冲满时等待（背压），消费者在
/// 空时等待；fail 向消费者抛根级错误；close 正常结束。单生产者顺序遍历 +
/// 单消费者（scanSession），锁内 drain 语义与 TS 一致。
private final class WalkChannel {
    private let lock = NSLock()
    private var buffer: [WalkEvent] = []
    private var pullers: [CheckedContinuation<WalkEvent, Error>] = []
    private var pushers: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var failure: Error?
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func push(_ event: WalkEvent) async {
        while true {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            if buffer.count >= capacity {
                lock.unlock()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if closed || buffer.count < capacity {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        pushers.append(continuation)
                        lock.unlock()
                    }
                }
                continue
            }
            buffer.append(event)
            drainLocked()
            lock.unlock()
            return
        }
    }

    func pull() async throws -> WalkEvent {
        while true {
            lock.lock()
            if let event = buffer.isEmpty ? nil : buffer.removeFirst() {
                drainLocked()
                lock.unlock()
                return event
            }
            if closed {
                let error = failure
                lock.unlock()
                if let error { throw error }
                return .done
            }
            lock.unlock()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WalkEvent, Error>) in
                lock.lock()
                if let event = buffer.isEmpty ? nil : buffer.removeFirst() {
                    drainLocked()
                    lock.unlock()
                    continuation.resume(returning: event)
                    return
                }
                if closed {
                    let error = failure
                    lock.unlock()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: .done)
                    }
                    return
                }
                pullers.append(continuation)
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let waitingPullers = pullers
        let waitingPushers = pushers
        pullers.removeAll()
        pushers.removeAll()
        lock.unlock()
        for puller in waitingPullers { puller.resume(returning: .done) }
        for pusher in waitingPushers { pusher.resume() }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        failure = error
        closed = true
        buffer.removeAll()
        let waitingPullers = pullers
        let waitingPushers = pushers
        pullers.removeAll()
        pushers.removeAll()
        lock.unlock()
        for puller in waitingPullers { puller.resume(throwing: error) }
        for pusher in waitingPushers { pusher.resume() }
    }

    /// 锁内：把事件派给等待的消费者，容量回落后唤醒等待的生产者。
    private func drainLocked() {
        while !pullers.isEmpty && !buffer.isEmpty {
            let puller = pullers.removeFirst()
            let event = buffer.removeFirst()
            puller.resume(returning: event)
        }
        while !pushers.isEmpty && buffer.count < capacity {
            pushers.removeFirst().resume()
        }
    }
}

/// TS: mapConcurrent —— 固定 runner 从共享游标取任务（滑动窗口，结果保序，
/// 首个失败停止调度并在在飞项跑完后传播）。
private func mapConcurrent<T, R>(
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
    return collected.sorted { $0.index < $1.index }.map(\.value)
}

/// 共享游标（滑动窗口调度 + 首个失败即停）。
private final class BatchCursor {
    private let lock = NSLock()
    private var next = 0
    private let count: Int
    private var failed = false

    init(count: Int) {
        self.count = count
    }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, next < count else { return nil }
        defer { next += 1 }
        return next
    }

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}
