// desktop/native/gather-core/Sources/GatherApplication/Services/IndexerService.swift
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
    let indexer: any IndexerRepository
    let transactions: any TransactionRunner
    /// P1-1：仓储依赖一律走 Persistence 端口（any XxxRepository），具体 SQLite
    /// Repo 只在组合根构造；测试可用 fake 替换。
    let sessionRepo: any SessionRepository
    let photoRepo: any PhotoRepository
    let assetRepo: any AssetRepository
    /// 人脸派生结果失效入口（FaceRepository.invalidateDerivedResults）。可选注入：
    /// nil 时跳过人脸段（仅有相似度/元数据需求的宿主/测试），但**生产宿主必须
    /// 注入**，否则内容变化后人脸观察与 person_embeddings 不会失效。
    let faceRepo: (any FaceRepository)?
    let getDimensions: DimensionsProvider
    let getSetting: SettingReader
    let warmMetadata: MetadataWarmup

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
        sessionRepo: any SessionRepository,
        photoRepo: any PhotoRepository,
        assetRepo: any AssetRepository,
        faceRepo: (any FaceRepository)? = nil,
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

    /// TS: sha256File —— 实现已下沉到 Persistence 的 `FileHasher`（Cut 3a / E-02）。

    /// TS: canonicalPath / textualPath / isWithin 三个纯函数已收敛到
    /// ScanPath（定义见 Database/ScanPath.swift）：扫描与导入两条链路共用同一归一化口径，
    /// 不得再各写一份。

    /// TS: managedCacheRoots —— disk_cache_dir 设置优先，否则默认缓存目录。
    func managedCacheRoots() -> [String] {
        let configured = getSetting("disk_cache_dir", "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return [ScanPath.canonical(configured)] }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Application Support/Gather/thumbnails（应用数据目录在
            // macOS 即 Application Support/<app>）。
            return [ScanPath.canonical(appSupport.appendingPathComponent("thumbnails").path)]
        }
        return []
    }
}
