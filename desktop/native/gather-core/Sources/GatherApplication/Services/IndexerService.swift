// desktop/native/gather-core/Sources/GatherDomain/Services/IndexerService.swift
// TS 源: desktop/src/main/services/indexer/index.service.ts（Phase 3.0 移植，
// 只移植扫描/索引核心 + checksum 回填；watcher 段已由 2.4 Watch/Coordinator.swift
// 完成，本服务经 scanHandler(sessionId, requestedPaths) 向其提供 fullScan 能力）
//
// 移植差异说明（均为有意取舍，行为语义逐条对齐）：
// - 目录遍历为单生产者顺序递归 + 有界通道（容量对齐 TS WALK_CHANNEL_CAPACITY）：
//   文件恰产出一次、不可读非根目录报 failed、排除根跳过、不可读根抛错——
//   与 TS 并行 walk 的对外语义一致；路径产出顺序为排序后的 DFS（TS 并行序
//   不可预期，测试不依赖）。
// - scanBatch 内部并发（SCAN_BATCH_CONCURRENCY=4）用共享 batchAsync（Concurrent/
//   BatchRunner.swift）滑动窗口；
//   discoveredSet 等共享状态的写集中在串行提交阶段（TS 单线程天然安全）。
// - stat 经 public stat 接缝注入（TS 同款测试接缝）；checksum 经 fileHasher
//   注入（新增接缝，用于并发写入竞态测试；默认 = 整文件 SHA256，与 TS
//   createReadStream 流式 sha256 结果逐字节一致）。
// - backfill 的 keyset 分页直接走 PhotoRepo.getBySessionPage（Swift 侧 repo
//   恒定存在，无需 TS 的 feature-detection 回退）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum IndexerServiceError: Error, Equatable {
    case sessionNotFound
    case noSourcePath
    /// 目录作用域的根不可接受（文件系统根 / 用户主目录及其祖先）：
    /// 递归扫描这类根会把用户未选择的整个卷/主目录导入会话。
    case sourceRootForbidden
}

/// TS 错误消息逐字对齐（executor 失败路径以 String(describing:) 记录，
/// 必须等于 TS error.message）。
extension IndexerServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sessionNotFound: "SESSION_NOT_FOUND"
        case .noSourcePath: "INDEX_SESSION_NO_SOURCE"
        case .sourceRootForbidden: "SESSION_SOURCE_ROOT_FORBIDDEN"
        }
    }
}

/// TS 错误码映射（桥接层序列化用）。
extension IndexerServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .noSourcePath: .INDEX_SESSION_NO_SOURCE
        case .sourceRootForbidden: .SESSION_SOURCE_ROOT_FORBIDDEN
        }
    }
}

/// 线程安全说明（Swift 6 `Sendable`）：全部存储属性除两个测试接缝
/// `_stat`/`_fileHasher` 外均为 `let`；接缝由 `seamLock`（NSLock）保护，
/// 公开的 `stat`/`fileHasher` 是加锁计算属性。锁纪律无法被编译器静态验证，
/// 故标注 `@unchecked`（与同仓 MetadataSyncCoordinator/BatchCursor 一致）。
public final class IndexerService: @unchecked Sendable {
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

    /// WP3b-2：扫描写路径/派生失效 SQL 下沉到 IndexerRepo；事务经 TransactionRunner。
    private let indexer: any IndexerRepository
    private let transactions: any TransactionRunner
    private let sessionRepo: SessionRepo
    private let photoRepo: PhotoRepo
    private let assetRepo: AssetRepo
    /// 人脸派生结果失效入口（FaceRepo.invalidateDerivedResults）。可选注入：
    /// nil 时跳过人脸段（仅有相似度/元数据需求的宿主/测试），但**生产宿主必须
    /// 注入**，否则内容变化后人脸观察与 person_embeddings 不会失效。
    private let faceRepo: FaceRepo?
    private let getDimensions: DimensionsProvider
    private let getSetting: SettingReader
    private let warmMetadata: MetadataWarmup

    /// 测试接缝的共享可变状态：`_stat`/`_fileHasher` 由 `seamLock`（NSLock）保护，
    /// 公开接缝是加锁计算属性（生产路径构造后只读；测试在并发使用前覆写一次）。
    private let seamLock = NSLock()
    private var _stat: (String) throws -> FileStat = IndexerService.defaultStat
    private var _fileHasher: (String) throws -> String = FileHasher.sha256File

    /// TS: public stat 测试接缝 —— 增量扫描用 stat，可覆写以模拟目录列举与
    /// stat 之间文件消失（ghost photo 竞态）。
    public var stat: (String) throws -> FileStat {
        get {
            seamLock.lock()
            defer { seamLock.unlock() }
            return _stat
        }
        set {
            seamLock.lock()
            defer { seamLock.unlock() }
            _stat = newValue
        }
    }

    /// checksum 计算接缝（默认整文件 SHA256 hex；测试注入并发写入者）。
    public var fileHasher: (String) throws -> String {
        get {
            seamLock.lock()
            defer { seamLock.unlock() }
            return _fileHasher
        }
        set {
            seamLock.lock()
            defer { seamLock.unlock() }
            _fileHasher = newValue
        }
    }

    /// 新照片入库后的元数据预热：把新行 id 交给元数据链路（EXIF → 
    /// photo_metadata_cache，含 date_taken / camera_model）。**必须**由宿主注入
    /// MetadataService.getMetadata：不注入时这些列为空，RAW/JPEG 的按时间自动
    /// 合并（AssetRepo.reconcileRawJpegLinks 要求两侧 date_taken + camera_model）
    /// 会恒为 0 —— 旧实现正是漏了这一步。
    public typealias MetadataWarmup = ([String]) async -> Void

    public init(
        indexer: any IndexerRepository,
        transactions: any TransactionRunner,
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        assetRepo: AssetRepo,
        faceRepo: FaceRepo? = nil,
        getDimensions: @escaping DimensionsProvider = IndexerService.defaultDimensions,
        getSetting: @escaping SettingReader = { _, defaultValue in defaultValue },
        warmMetadata: @escaping MetadataWarmup = { _ in }
    ) {
        self.indexer = indexer
        self.transactions = transactions
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.assetRepo = assetRepo
        self.faceRepo = faceRepo
        self.getDimensions = getDimensions
        self.getSetting = getSetting
        self.warmMetadata = warmMetadata
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

    /// TS: sha256File —— 实现已下沉到 Persistence 的 `FileHasher`（Cut 3a / E-02：
    /// AssetRepo 在 Persistence，不能反向调 Domain 的哈希函数，否则
    /// Persistence↔Domain 成环、SwiftPM 报 cyclic dependency）。
    ///
    /// 保留一行委托仅作既有调用方的过渡别名；新代码请直接用 `FileHasher.sha256File`。
    @available(*, deprecated, message: "改用 FileHasher.sha256File（Cut 3a：哈希实现已下沉到 Persistence）")
    public static func sha256File(_ filePath: String) throws -> String {
        try FileHasher.sha256File(filePath)
    }

    /// TS: canonicalPath / textualPath / isWithin 三个纯函数已收敛到
    /// ScanPath（定义见 Database/ScanPath.swift）：扫描与导入两条链路共用同一归一化口径，
    /// 不得再各写一份。

    /// TS: managedCacheRoots —— disk_cache_dir 设置优先，否则默认缓存目录。
    private func managedCacheRoots() -> [String] {
        let configured = getSetting("disk_cache_dir", "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return [ScanPath.canonical(configured)] }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Application Support/Gather/thumbnails（应用数据目录在
            // macOS 即 Application Support/<app>）。
            return [ScanPath.canonical(appSupport.appendingPathComponent("thumbnails").path)]
        }
        return []
    }

    // ─────────────────────────── 扫描 ───────────────────────────

    /// TS: scanSession —— 全量/增量扫描 + 索引入库 + 缺失对账 + index_seq 游标。
    /// requestedPaths=nil 时走目录遍历（fullScan）；非 nil 时只处理候选路径。
    /// 由 app 的 metadata.scan job executor（ExecutorRegistry）直接调用。
    public func scanSession(
        sessionId: String,
        requestedPaths: [String]? = nil,
        context: JobRunContext? = nil
    ) async throws -> IndexScanResult {
        let session = try self.sessionRepo.get(id: sessionId)
        guard let session else { throw IndexerServiceError.sessionNotFound }
        // 扫描范围由调用方显式指定：
        //   requestedPaths == nil → 目录作用域：以 session.source_path 为根递归全树。
        //   requestedPaths != nil → 显式集合作用域：只处理给定路径（目录条目在其
        //                           自身范围内递归展开），绝不回退/扩张到 source_path。
        // 目录作用域要求 source_path 是「用户显式选择的目录」；历史实现会用所选
        // 文件的公共父目录充当 source_path，于是选 3 张照片等于递归扫描整个目录树，
        // 最坏可上溯到主目录。此处对不可接受的根显式失败，而不是照扫不误。
        if requestedPaths == nil {
            guard !session.sourcePath.isEmpty else { throw IndexerServiceError.noSourcePath }
            guard !ScanPath.isForbiddenRoot(session.sourcePath) else {
                throw IndexerServiceError.sourceRootForbidden
            }
        }
        let excludedRoots = managedCacheRoots()
        var existing = try self.photoRepo.getBySessionProjection(sessionId: sessionId)

        /// 按归一化路径归约：首见者胜（getBySessionProjection 按 rowid 升序返回，
        /// 首见者即最早导入的行，与迁移的「保留 rowid 最小者」一致）；重复键单独
        /// 收集、随后显式上报。绝不会像旧实现那样用
        /// Dictionary(uniqueKeysWithValues:) 在脏数据上 trap。
        func reduceByNormalizedPath(_ photos: [PhotoProjectionRow]) -> (
            byPath: [String: PhotoProjectionRow], duplicates: Set<String>
        ) {
            var byPath: [String: PhotoProjectionRow] = [:]
            var duplicates: Set<String> = []
            for photo in photos {
                let key = ScanPath.canonical(photo.filepath)
                if byPath[key] == nil {
                    byPath[key] = photo
                } else {
                    duplicates.insert(key)
                }
            }
            return (byPath, duplicates)
        }

        var (existingByPath, duplicatePathKeys) = reduceByNormalizedPath(existing)
        // 生成缓存目录内的存量照片（缓存清扫）：事务内删除照片行 + 孤儿资产行。
        // 复用上一步的归一化键做归属判断，避免逐照片二次 realpath。
        let generatedCachePhotos = existingByPath
            .filter { entry in
                excludedRoots.contains { ScanPath.isWithin(candidate: entry.key, root: $0) }
            }
            .map { $0.value }
        if !generatedCachePhotos.isEmpty {
            let photoIds = generatedCachePhotos.map(\.id)
            let fileIds = generatedCachePhotos.compactMap(\.assetFileId)
            try self.transactions.transaction {
                // person_photos.photo_id 是 ON DELETE RESTRICT（D-025）：缓存照片若已被
                // 标记身份，直接 DELETE photos 会让整个清扫事务回滚（FOREIGN KEY
                // constraint failed）。生成缓存是派生数据，先显式解除身份桥接再删照片，
                // 遵循 FK 顺序 person_photos → photos（顺序封在 IndexerRepo）。
                // role_bindings 不在此路径：本事务不删 session/face_clusters，用户绑定必须保留。
                try self.indexer.deletePersonPhotoBindings(photoIds: photoIds)
                try self.indexer.deletePhotos(photoIds: photoIds)
                try self.indexer.pruneSessionAssets(sessionId: sessionId)
                try self.indexer.pruneOrphanAssets(fileIds: fileIds)
            }
            let removedIds = Set(photoIds)
            existing = existing.filter { !removedIds.contains($0.id) }
            (existingByPath, duplicatePathKeys) = reduceByNormalizedPath(existing)
        }
        var fileStats: [String: (id: String, fileSize: Int64, fileMtimeMs: Double, checksum: String)] = [:]
        for row in try self.indexer.fileStats(sessionId: sessionId) {
            fileStats[row.id] = (
                id: row.id,
                fileSize: row.fileSize,
                fileMtimeMs: row.fileMtimeMs,
                checksum: row.checksum
            )
        }

        var discoveredSet = Set<String>()
        var relinkedPhotoIds = Set<String>()
        var failed: [String] = []
        // 归一化后仍重复的路径是库层面的不一致（迁移每次启动都会收敛，此处是
        // 运行期兜底）：不崩、不静默——首见者参与扫描，重复键作为失败项上报。
        if !duplicatePathKeys.isEmpty {
            let sample = duplicatePathKeys.sorted().prefix(3).joined(separator: ", ")
            GatherLogger.log(
                "Indexer found \(duplicatePathKeys.count) duplicate normalized photo path(s) in session \(sessionId); keeping the earliest row: \(sample)",
                level: .warn
            )
            failed.append(contentsOf: duplicatePathKeys.sorted())
        }
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
            // batchAsync 的 worker 子任务（@Sendable）只读下面两个映射；它们在本
            // 批次入口冻结为局部 let（构造后已无写者），避免并发闭包捕获 var。
            let existingByPathSnapshot = existingByPath
            let fileStatsSnapshot = fileStats
            try context?.throwIfCancelled()
            // 懒校验模式：新/变文件只记尺寸，checksum 交给后台 checksum.backfill。
            let lazyChecksum = self.getSetting("lazy_checksum", "true") != "false"
            let results = try await batchAsync(filepaths, concurrency: Self.scanBatchConcurrency) { filepath -> BatchOutcome in
                let normalized = ScanPath.canonical(filepath)
                // stat 先行：目录列举与 stat 之间消失的文件不得进入 discoveredSet，
                // 否则末段永远不会把它对账为 missing（ghost photo）。
                let source: FileStat
                do {
                    source = try self.stat(filepath)
                } catch {
                    return BatchOutcome(normalized: normalized, item: .missing)
                }
                guard let photo = existingByPathSnapshot[normalized] else {
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
                let indexed = photo.assetFileId.flatMap { fileStatsSnapshot[$0] }
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
            // 全部写在一个事务内（曾为每文件一事务 ≈ 每批 32 次 fsync）。
            try self.transactions.transaction {
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
                        let relocated: RelinkMovedFileResult?
                        do {
                            relocated = try self.assetRepo.relinkMovedFile(
                                newPath: filepath, checksum: checksum, fileSize: fileSize,
                                fileMtimeMs: fileMtimeMs, fileIdentity: fileIdentity
                            )
                        } catch {
                            // 单文件可恢复失败（XMP 写入中、sidecar 冲突等守卫）
                            // 不整批回滚；真实数据库错误才中止批事务。
                            if error is DBError { throw error }
                            failed.append(filepath)
                            continue
                        }
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
                            try self.indexer.updateAssetFile(
                                assetFileId: assetFileId,
                                volumeId: volumeId,
                                fileIdentity: fileIdentity,
                                fileSize: fileSize,
                                fileMtimeMs: fileMtimeMs,
                                checksum: checksum,
                                preserveChecksum: preserveChecksum,
                                timestamp: timestamp
                            )
                            if contentChanged {
                                for photoId in try self.indexer.photoIds(assetFileId: assetFileId) {
                                    batchAffectedPhotoIds.insert(photoId)
                                }
                                // 文件级清扫：先前照片删除留下的孤儿 analysis 行。
                                try self.indexer.deleteAssetAnalysis(assetFileId: assetFileId)
                                try self.indexer.updatePhotos(
                                    assetFileId: assetFileId,
                                    checksum: checksum,
                                    fileSize: fileSize,
                                    fileMtimeMs: fileMtimeMs,
                                    width: width,
                                    height: height,
                                    timestamp: timestamp
                                )
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
                // 只预热本批真正插入的行（跳过 == 无新行，不重复提取 EXIF）。
                let insertedIds = inserted.ids.filter { !$0.isEmpty }
                if !insertedIds.isEmpty {
                    await self.warmMetadata(insertedIds)
                }
            }
        }

        // 扫描 + 终态提交整体受保护：批次提交后发生的取消/错误不得吞掉
        // index_seq bump。index_seq 是分析过期游标（sessions.index_seq vs
        // analysis_runs.index_seq）——批次已提交的新照片对已完成分析
        // （sim/fkw）的可见性完全依赖它推进；任何终态只要发生过真实变更
        // 都必须 bump（TS「任何批次提交后都 bump」语义）。
        do {
            // 本次扫描真正覆盖到的路径（显式集合展开后的并集）：末段用它决定
            // 哪些存量照片需要参与 missing 对账。
            var requestedCoverage = Set<String>()
            if let requestedPaths {
                // 显式集合作用域：扫描集合 == 调用方给定的路径集合，不因集合里
                // 出现目录而扩张到 source_path 全树。目录条目仅在自身范围内递归
                // 展开（符号链接目录不进入递归，与全树遍历同一规则）；文件条目
                // 按受支持扩展名过滤；缺失/不支持的条目只登记覆盖集，留给末段
                // 对账为 missing / 直接忽略。
                var candidates: [String] = []
                // 显式集合的入口规则（与 nil 分支同一错误语义）：
                //   ① 每个条目都做禁根校验 —— 混合选择「目录 + 文件」时用户同样
                //      可能把 home 或 / 传进来，绝不允许照递归；
                //   ② 归一化去重；
                //   ③ 祖先胜出：若条目 X 落在另一保留条目 Y 之内，丢弃 X
                //      （Y 的展开已覆盖 X），避免同一子树被扫两遍；
                //   ④ 剩余条目按路径排序，扫描顺序确定。
                var requestedRoots = Set<String>()
                for requested in requestedPaths {
                    let canonical = ScanPath.canonical(requested)
                    guard !ScanPath.isForbiddenRoot(canonical) else {
                        GatherLogger.log(
                            "metadata.scan: forbidden requested root \(canonical)",
                            level: .warn
                        )
                        throw IndexerServiceError.sourceRootForbidden
                    }
                    requestedRoots.insert(canonical)
                }
                let orderedRoots = requestedRoots.sorted {
                    let leftDepth = $0.split(separator: "/").count
                    let rightDepth = $1.split(separator: "/").count
                    if leftDepth != rightDepth { return leftDepth < rightDepth }
                    return $0 < $1
                }
                var scanRoots: [String] = []
                var redundantRoots = 0
                for root in orderedRoots {
                    if scanRoots.contains(where: {
                        $0 != root && ScanPath.isWithin(candidate: root, root: $0)
                    }) {
                        redundantRoots += 1
                        continue
                    }
                    scanRoots.append(root)
                }
                if redundantRoots > 0 {
                    GatherLogger.log(
                        "metadata.scan: \(redundantRoots) requested path(s) already covered by an ancestor entry",
                        level: .warn
                    )
                }
                var queue = scanRoots
                while let filepath = queue.popLast() {
                    guard requestedCoverage.insert(filepath).inserted else { continue }
                    if excludedRoots.contains(where: { ScanPath.isWithin(candidate: filepath, root: $0) }) { continue }
                    if ScanPath.isDirectory(filepath) {
                        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: filepath) else {
                            continue
                        }
                        for name in entries.sorted() {
                            queue.append(ScanPath.canonical(filepath + "/" + name))
                        }
                        continue
                    }
                    guard Self.supportedExtensions.contains(TSPath.extname(filepath).lowercased()) else { continue }
                    // stat 失败（列举与 stat 之间消失）不得进入 discoveredSet，
                    // 否则末段永远不会把它对账为 missing（ghost photo）。
                    if (try? self.stat(filepath))?.isFile == true {
                        candidates.append(filepath)
                        discovered += 1
                    }
                }
                if !candidates.isEmpty { try await scanBatch(candidates) }
            } else {
                // 生产者/消费者：walk 经有界通道流式产出，scanBatch 按 32 个一批消费。
                let channel = WalkChannel(capacity: Self.walkChannelCapacity)
                let producer = Task {
                    await Self.traverse(
                        directory: ScanPath.canonical(session.sourcePath),
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
                        try context?.throwIfCancelled()
                        discovered += 1
                        context?.updateProgress(JobProgressUpdate(
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

            for photo in existing {
                let normalized = ScanPath.canonical(photo.filepath)
                // 全树扫描覆盖每条存量路径；显式集合只覆盖展开后的并集——
                // 集合外的照片不属于本次扫描范围，不得误标 missing。
                let inRequested = requestedPaths == nil || requestedCoverage.contains(normalized)
                if inRequested
                    && !discoveredSet.contains(normalized)
                    && !relinkedPhotoIds.contains(photo.id) {
                    missing.append(photo)
                }
            }
            try self.photoRepo.markMissing(photoIds: missing.map(\.id))
            _ = try self.assetRepo.backfillSession(sessionId)
            // index_seq 是分析过期游标：仅在真实变更（新增/内容变/重链接/新增缺失）
            // 时 bump；空转扫描不得把分析标脏。
            let committedChanges = added > 0
                || updatedExistingPhotos > 0
                || !relinkedPhotoIds.isEmpty
                || !missing.isEmpty
            var finalCount = 0
            try self.transactions.transaction {
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
                try self.indexer.markAssetFilesOffline(
                    fileIds: missing.compactMap(\.assetFileId),
                    timestamp: nowISOString()
                )
            }
            context?.updateProgress(JobProgressUpdate(current: discovered, total: discovered, phase: "index.done"))
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
                try? self.transactions.transaction {
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
        // E-5（性能审计）：下沉为 COUNT(*)（旧实现物化整会话行、含大列）。
        try self.photoRepo.pendingChecksumCount(sessionId: sessionId)
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
            try context?.throwIfCancelled()
            let (pending, lastRowId) = try loadPendingBackfill(
                sessionId: sessionId, afterRowId: afterRowId, failedPhotoIds: failedPhotoIds
            )
            if let lastRowId { afterRowId = lastRowId }
            if pending.isEmpty { break }
            context?.updateProgress(JobProgressUpdate(
                current: 0, total: pending.count, phase: "index.checksum"
            ))
            var passBackfilled = 0
            for offset in stride(from: 0, to: pending.count, by: Self.checksumBackfillBatch) {
                try context?.throwIfCancelled()
                let batch = Array(pending[offset..<min(offset + Self.checksumBackfillBatch, pending.count)])
                // 哈希阶段只读；全部写入进入单事务。
                let results = try await batchAsync(
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
                try self.transactions.transaction {
                    for (index, result) in results.enumerated() {
                        guard let result else {
                            failedPhotoIds.insert(batch[index].id)
                            skipped += 1
                            processed += 1
                            continue
                        }
                        // 乐观填充：仅当照片 checksum 仍为空才写（并发扫描
                        // 刚写/清空的值不被覆盖）。
                        let photoChanges = try self.indexer.backfillPhotoChecksum(
                            photoId: result.photo.id,
                            checksum: result.checksum,
                            fileSize: result.size,
                            fileMtimeMs: result.mtimeMs,
                            timestamp: nowISOString()
                        )
                        if !photoChanges {
                            // 另一写入者已填充（或清空）：跳过资产行写入，
                            // 保持 photos 与 asset_files 一致。
                            skipped += 1
                        } else {
                            if let assetFileId = result.photo.assetFileId {
                                try self.indexer.backfillAssetFileChecksum(
                                    assetFileId: assetFileId,
                                    checksum: result.checksum,
                                    fileSize: result.size,
                                    fileMtimeMs: result.mtimeMs,
                                    timestamp: nowISOString()
                                )
                            }
                            passBackfilled += 1
                            backfilled += 1
                        }
                        processed += 1
                    }
                }
                context?.updateProgress(JobProgressUpdate(current: processed, total: pending.count))
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
    /// 人脸段（face_observations / face_analysis_state）不在此处：它必须经
    /// FaceRepo.invalidateDerivedResults 走"先解除成员引用、再删观察、同事务
    /// 清 person_embeddings"的顺序（见 invalidatePathDependentAnalysis）。
    private func deletePhotoInputs(photoIds: [String]) throws {
        try self.indexer.deletePhotoInputs(photoIds: photoIds)
    }

    /// TS: pruneAutomaticNavigationGroups —— 只删实际含受影响照片的自动导航组；
    /// JSON 不可读的组保留不删。
    private func pruneAutomaticNavigationGroups(sessionId: String, photoIds: [String]) throws {
        let affected = Set(photoIds)
        // LIKE 预过滤（含 ESCAPE 转义）与全量分支都在 IndexerRepo。
        let groups: [(id: String, photoIdsJSON: String)] = try self.indexer
            .automaticNavigationGroups(
                sessionId: sessionId,
                photoIds: photoIds,
                prefilterCap: Self.pruneLikePrefilterCap
            )
            .map { (id: $0.id, photoIdsJSON: $0.photoIdsJSON) }
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
        try self.indexer.deleteNavigationGroups(ids: doomed)
    }

    /// TS: deleteGlobalClusterResults —— 会话级相似度簇结果失效。
    private func deleteGlobalClusterResults(sessionId: String) throws {
        try self.indexer.deleteSimilarityResults(sessionId: sessionId)
    }

    /// TS: invalidatePathDependentAnalysis —— 路径/内容变化的照片：逐照片删输入、
    /// 按成员剪自动导航组、会话级丢簇结果；每批调用一次。
    private func invalidatePathDependentAnalysis(photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        let affectedSessions = try self.indexer.sessionIds(photoIds: photoIds)
        let photoIdsBySession = try self.indexer.photoIdsBySession(photoIds: photoIds)
        try self.transactions.transaction {
            // 人脸派生结果：只失效本批命中的照片（成员引用先解除，再删观察，
            // 同事务清 person_embeddings）。用户绑定与簇行保留 —— 旧实现整会话
            // DELETE role_bindings/face_clusters 会静默销毁用户标注。
            for (sessionId, sessionPhotoIds) in photoIdsBySession {
                try faceRepo?.invalidateDerivedResults(
                    sessionId: sessionId, photoIds: sessionPhotoIds)
            }
            for sessionId in affectedSessions {
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
            if excludedRoots.contains(where: { ScanPath.isWithin(candidate: full, root: $0) }) { continue }
            if ScanPath.isDirectory(full) {
                await traverse(directory: full, isRoot: false, excludedRoots: excludedRoots, channel: channel)
            } else if supportedExtensions.contains(TSPath.extname(name).lowercased()) {
                await channel.push(.file(full))
            }
        }
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

/// 遍历事件（TS BoundedChannel 的元素 + onUnreadableDirectory 回调合流）。
private enum WalkEvent {
    case file(String)
    case unreadableDirectory(String)
    case done
}

/// TS: BoundedChannel —— 有界通道：生产者在缓冲满时等待（背压），消费者在
/// 空时等待；fail 向消费者抛根级错误；close 正常结束。单生产者顺序遍历 +
/// 单消费者（scanSession），锁内 drain 语义与 TS 一致。
///
/// 线程安全说明（Swift 6 `Sendable`）：生产者在独立 Task 里写通道，消费者在
/// scanSession 里读；全部可变状态（`buffer`/`pullers`/`pushers`/`closed`/`failure`）
/// 只在 `lock`（NSLock）临界区内读写。锁纪律无法被编译器静态验证，故标注
/// `@unchecked`（与同仓 BatchCursor 一致）。
private final class WalkChannel: @unchecked Sendable {
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

    /// push 的锁内判定（多值判定 → 私有 enum，同 ScanSlotDecision）。
    private enum PushSlotDecision {
        /// 通道已关闭：直接返回。
        case closed
        /// 缓冲已满：调用方 await 等待后重试。
        case waitForCapacity
        /// 已入队并 drain。
        case enqueued
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func enqueueOrWaitLocked(_ event: WalkEvent) -> PushSlotDecision {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        if buffer.count >= capacity { return .waitForCapacity }
        buffer.append(event)
        drainLocked()
        return .enqueued
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    /// 返回 true = 已登记等待（由 drainLocked/close/fail 唤醒）；false = 条件已满足，
    /// 调用方立即 resume。
    private func parkPusherLocked(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed || buffer.count < capacity { return false }
        pushers.append(continuation)
        return true
    }

    func push(_ event: WalkEvent) async {
        while true {
            switch enqueueOrWaitLocked(event) {
            case .closed:
                return
            case .enqueued:
                return
            case .waitForCapacity:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if !parkPusherLocked(continuation) {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// pull 的锁内判定（多值判定 → 私有 enum，同 ScanSlotDecision）。
    private enum PullSlotDecision {
        /// 已有事件（已 drain）：立即交付。
        case delivered(WalkEvent)
        /// 已关闭：failure 非 nil 抛错，否则交付 .done。
        case closed(Error?)
        /// 未关闭但无事件：调用方 await 等待。
        case wait
    }

    /// pull 登记等待的锁内判定（多值判定 → 私有 enum，同 ScanSlotDecision）。
    private enum PullParkDecision {
        /// 已登记 continuation，等待 drain/close/fail 唤醒。
        case parked
        /// 已有事件（已 drain）：立即交付。
        case delivered(WalkEvent)
        /// 已关闭：failure 非 nil 抛错，否则交付 .done。
        case closed(Error?)
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func takeOrWaitLocked() -> PullSlotDecision {
        lock.lock()
        defer { lock.unlock() }
        if let event = buffer.isEmpty ? nil : buffer.removeFirst() {
            drainLocked()
            return .delivered(event)
        }
        if closed { return .closed(failure) }
        return .wait
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func parkPullerLocked(_ continuation: CheckedContinuation<WalkEvent, Error>) -> PullParkDecision {
        lock.lock()
        defer { lock.unlock() }
        if let event = buffer.isEmpty ? nil : buffer.removeFirst() {
            drainLocked()
            return .delivered(event)
        }
        if closed { return .closed(failure) }
        pullers.append(continuation)
        return .parked
    }

    func pull() async throws -> WalkEvent {
        switch takeOrWaitLocked() {
        case .delivered(let event):
            return event
        case .closed(let error):
            if let error { throw error }
            return .done
        case .wait:
            break
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WalkEvent, Error>) in
            switch parkPullerLocked(continuation) {
            case .parked:
                break
            case .delivered(let event):
                continuation.resume(returning: event)
            case .closed(let error):
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: .done)
                }
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
