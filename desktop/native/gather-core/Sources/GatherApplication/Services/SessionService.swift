// desktop/native/gather-core/Sources/GatherApplication/Services/SessionService.swift
// TS 源: desktop/src/main/services/session/session.service.ts（Phase 3.2 移植）
// 会话服务：创建/列表/查询/删除/加照片。图片尺寸读取通过注入的
// dimensionsProvider 接入原生 RAWDecoder，
// 本文件保持零图片依赖，Linux 可单测。
import Foundation
import GatherPersistence
import GatherProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Cut 3 / 3b-0：SessionServiceError 已上移到 GatherProtocol
// （Protocol/SessionErrors.swift）；本文件经 import GatherProtocol 继续抛/判
// 同一类型，错误码映射（gatherCode）随类型一起留在协议层。

/// TS: AddPhotoResult（@gather/shared）。
public struct SessionAddPhotoResult: Equatable, Sendable {
    public let added: Int
    public let skipped: Int
    public let total: Int
    public let failedFiles: [String]

    public init(added: Int, skipped: Int, total: Int, failedFiles: [String]) {
        self.added = added
        self.skipped = skipped
        self.total = total
        self.failedFiles = failedFiles
    }
}

public final class SessionService {
    /// 设置读取端口（#9）：import_concurrency 等读取统一走任何装 SettingsReading
    /// 的实现，不再注入 (String, Double) -> Double 闭包。
    private let settings: any SettingsReading
    /// TS: ImageService.getDimensions(filepath) → { width, height }，失败抛错。
    private let dimensionsProvider: (String) throws -> (width: Int, height: Int)

    private let sessionRepo: any SessionRepository
    private let photoRepo: any PhotoRepository
    private let faceRepo: any FaceRepository
    private let personRepo: any PersonRepository
    private let metadataCacheRepo: any MetadataRepository
    private let jobRepo: any JobRepository
    private let assetRepo: (any AssetRepository)?
    private let deliverySummary: any DeliverySummaryReading
    private let transactions: any TransactionRunner

    public init(
        sessionRepo: any SessionRepository,
        photoRepo: any PhotoRepository,
        faceRepo: any FaceRepository,
        personRepo: any PersonRepository,
        metadataCacheRepo: any MetadataRepository,
        jobRepo: any JobRepository,
        assetRepo: (any AssetRepository)? = nil,
        deliverySummary: any DeliverySummaryReading,
        transactions: any TransactionRunner,
        settings: any SettingsReading = ClosureSettingsReader { _ in nil },
        dimensionsProvider: @escaping (String) throws -> (width: Int, height: Int) = { _ in
            throw SessionServiceError.sourceNotDir
        }
    ) {
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.faceRepo = faceRepo
        self.personRepo = personRepo
        self.metadataCacheRepo = metadataCacheRepo
        self.jobRepo = jobRepo
        self.deliverySummary = deliverySummary
        self.transactions = transactions
        self.settings = settings
        self.dimensionsProvider = dimensionsProvider
        self.assetRepo = assetRepo
    }

    public func createSession(name: String, source: String, sourcePath: String = "", truncatedImport: Bool = false) throws -> SessionData {
        let row = try sessionRepo.create(name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
        return try toSessionData(row)
    }

    /// 一跳本地目录导入：校验真实非根目录并建 session 行（source_path + 'local'）。
    /// 照片不在此插入——调用方入队 metadata.scan 索引 job，进程内流式遍历填充。
    public func createFromDirectory(
        name: String,
        sourcePath: String,
        source: String = "local",
        truncatedImport: Bool = false
    ) throws -> SessionData {
        try requireDirectory(sourcePath)
        let resolved = ScanPath.canonical(sourcePath)
        // 目录作用域的根必须是用户显式选择的目录：文件系统根、当前用户主目录
        // 及其祖先一律拒绝——递归扫描它们等于把整个卷/主目录导入会话。
        if ScanPath.isForbiddenRoot(resolved) {
            throw SessionServiceError.sourceRootForbidden
        }
        // TS: (name ?? '').trim() —— 空白含换行等，用 whitespacesAndNewlines 对齐。
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmedName.isEmpty ? TSPath.basename(resolved) : trimmedName
        return try createSession(name: sessionName, source: source, sourcePath: resolved, truncatedImport: truncatedImport)
    }

    public func listSessions() throws -> [SessionData] {
        try sessionRepo.list().map { try toSessionData($0) }
    }

    public func getSession(_ sessionId: String) throws -> SessionData? {
        // source_path 是扫描/监听作用域的唯一判据：非空 = 目录作用域（递归全树），
        // 空 = 显式文件集合作用域。这里绝不再用已导入照片的公共父目录回填它——
        // 那会把一次「选了 N 张照片」永久升级成对某个目录的全树扫描，而且会随
        // 照片集合变化漂移（历史 P0：父目录可上溯到 home）。
        guard let row = try sessionRepo.get(id: sessionId) else { return nil }
        return try toSessionData(row)
    }

    public func deleteSession(_ sessionId: String, confirmed: Bool) throws {
        if !confirmed { throw SessionServiceError.deleteNotConfirmed }
        try transactions.transaction {
            try deleteSessionDependencies(sessionId)
            let deleted = try sessionRepo.delete(id: sessionId)
            if !deleted { throw SessionServiceError.sessionNotFound }
            try sessionRepo.markOrphanedAssets()
        }
    }

    public func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws -> Int {
        if !confirmed { throw SessionServiceError.deleteNotConfirmed }
        return try transactions.transaction {
            for id in sessionIds {
                try deleteSessionDependencies(id)
            }
            _ = try sessionRepo.deleteMany(ids: sessionIds)
            try sessionRepo.markOrphanedAssets()
            return sessionIds.count
        }
    }

    /// 按依赖顺序删除所有引用 photos(id)/face_observations(id) 且无
    /// ON DELETE 动作的行；foreign_keys = ON 下必须先于 photoRepo.deleteBySession。
    private func deleteSessionDependencies(_ sessionId: String) throws {
        // face_cluster_members 引用 face_observations，簇必须先于观测删除。
        try faceRepo.deleteClustersBySession(sessionId)
        try faceRepo.deleteObservationsBySession(sessionId)
        // similarity_hashes 无级联引用 photos。
        try sessionRepo.deleteSimilarityDataBySession(sessionId: sessionId)
        try personRepo.deleteSessionRows(sessionId: sessionId)
        try metadataCacheRepo.deleteBySession(sessionId)
        // V1（D-033）：role_bindings.cluster_id 与 person_photos.photo_id/session_id 是
        // RESTRICT，必须在删 session/photos 之前显式清掉（上面删簇时已按会话删
        // role_bindings；这里再显式删一次，防止未来出现脱离簇的绑定行让删除整体
        // 失败）。writeback_items 表已随旧同步栈删除，写回行由 deliveries 级联处理。
        // 审计 P2：analysis_jobs 无 FK，会话删除后残留僵尸行（状态查询/
        // 任务中心会一直看到幽灵任务）。
        try jobRepo.deleteSessionJobs(sessionId: sessionId)
        try photoRepo.deleteBySession(sessionId: sessionId)
    }

    /// 批量加照片：分批读尺寸（import_concurrency，钳制 1..32），
    /// 落库 + 资产回填 + 照片计数 + index_seq 递增（新照片使旧分析失效）。
    public func addPhotos(sessionId: String, filepaths: [String], source: String) throws -> SessionAddPhotoResult {
        guard let session = try sessionRepo.get(id: sessionId) else {
            throw SessionServiceError.sessionNotFound
        }
        // 显式文件集合导入只写照片行，绝不推导/回填 source_path：导入范围
        // 永远等于用户选择的文件集合（目录作用域只能由 createFromDirectory
        // 或显式 relink 建立）。
        let normalized = normalizeImportFilepaths(filepaths)

        var failedFiles: [String] = []
        var entries: [PhotoAddInput] = []

        // TS: Math.floor(import_concurrency) 再钳制 1..32；NaN 时 TS 批大小为 NaN
        // → 循环零次执行。Int(NaN/∞) 会 fatalError 崩溃，必须先过滤再转换。
        let configured = settings.double(.importConcurrency)
        let batchSize: Int
        if configured.isNaN || configured.isInfinite {
            batchSize = 0
        } else {
            batchSize = max(1, min(32, Int(configured)))
        }
        var index = 0
        while index < normalized.count && batchSize > 0 {
            let batch = Array(normalized[index..<min(index + batchSize, normalized.count)])
            index += batchSize
            for fp in batch {
                do {
                    let dims = try dimensionsProvider(fp)
                    entries.append(PhotoAddInput(filepath: fp, width: dims.width, height: dims.height))
                } catch {
                    failedFiles.append(fp)
                }
            }
        }

        let result = try photoRepo.addPhotos(sessionId: sessionId, filepaths: entries, source)
        _ = try assetRepo?.backfillSession(sessionId)
        // P2：photo_count 是"工作区照片数"（UI/侧栏展示），必须与可见性同口径。
        // 物理行数会把已移出到 _rejects 的照片也算进来，侧栏数字永远不回落。
        let totalCount = try photoRepo.countVisibleBySession(sessionId: sessionId)
        try transactions.transaction {
            try sessionRepo.updatePhotoCount(id: sessionId, count: totalCount)
            // 新照片使先前任何分析失效：同一事务内 bump index_seq，
            // 使最近一次 ok run 过期（1.4.2）。
            if result.added > 0 {
                _ = try sessionRepo.bumpIndexSeq(id: sessionId)
            }
        }
        if totalCount > 0 && session.status == "draft" {
            try sessionRepo.updateStatus(id: sessionId, status: "photos_loaded")
        }
        // id 是索引器的内部接缝，不外泄到 IPC（shared AddPhotoResult 无此字段）。
        return SessionAddPhotoResult(
            added: result.added,
            skipped: result.skipped,
            total: totalCount,
            failedFiles: failedFiles
        )
    }

    /// P1 / D：会话内已有照片的校验和（摄取去重）。只取已回填的行。
    /// - Parameter matchingSizes: 非空时只对文件大小命中的未回填照片现算哈希；
    ///   避免一次摄取把整库未回填照片全部读一遍。
    /// 全库导入去重目标（Wave2 / task-15）。
    ///
    /// 只带定位信息（不给调用方整行）：replace 策略要用 filepath/sessionId 判断
    /// 「是否同一工作区、原路径是否可覆盖」。
    public struct LibraryDuplicateTarget: Equatable, Sendable {
        public let photoId: String
        public let sessionId: String
        public let filepath: String
        /// 库内文件大小（未回填行在 Application 侧 stat 后补上；用于预检的 size 预筛）。
        /// Wave4a-F2：plan 据此只对 size 命中的源做 SHA-256，不再整卡逐张哈希。
        public let fileSize: Int

        public init(
            photoId: String, sessionId: String, filepath: String, fileSize: Int = 0
        ) {
            self.photoId = photoId
            self.sessionId = sessionId
            self.filepath = filepath
            self.fileSize = fileSize
        }
    }

    /// 全库（跨工作区）已登记照片的校验和索引：checksum → 一份代表行。
    ///
    /// 与 photoChecksums 的分工：那个是**会话内**去重（同一张卡重复摄取）；
    /// 这个是跨工作区去重（同一批素材在别的 Gather 工作区里已经有了一份）。
    ///
    /// Wave4a-F1：懒索引常态下大部分行的 checksum 还没回填，旧实现只查已回填行 →
    /// 跨工作区去重整体失效。现在对「未回填的可见行」先 stat 做 size 预筛，命中
    /// matchingSizes 才 SHA-256；摄取路径顺手回填，下一次直接读 checksum。
    ///
    /// Wave4a-F2：预检（previewIngest）调用时 allowChecksumBackfill=false —— 只读索引，
    /// 不写库（预检不得产生副作用）。
    ///
    /// - Parameter matchingSizes: 本次源文件大小集合（空 = 不预筛，全部候选都算）。
    /// - Parameter allowChecksumBackfill: 是否把算出的 checksum 回写 photos。
    func libraryPhotoDuplicates(
        matchingSizes: Set<Int>,
        allowChecksumBackfill: Bool = true
    ) throws -> [String: LibraryDuplicateTarget] {
        var result: [String: LibraryDuplicateTarget] = [:]
        for row in try photoRepo.libraryFingerprints(matchingSizes: matchingSizes) {
            guard !row.checksum.isEmpty, result[row.checksum] == nil else { continue }
            result[row.checksum] = LibraryDuplicateTarget(
                photoId: row.photoId,
                sessionId: row.sessionId,
                filepath: row.filepath,
                fileSize: row.fileSize
            )
        }
        // 未回填候选：stat 做 size 预筛，命中才读整文件哈希。
        func inspectCandidate(_ row: LibraryPhotoFingerprint) {
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: row.filepath)
            } catch {
                // 文件不在（卷未挂载/已移动）：该行本轮无法参与去重，跳过。
                return
            }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if !matchingSizes.isEmpty, !matchingSizes.contains(size) { return }
            do {
                let sum = try FileHasher.sha256File(row.filepath)
                if result[sum] == nil {
                    result[sum] = LibraryDuplicateTarget(
                        photoId: row.photoId,
                        sessionId: row.sessionId,
                        filepath: row.filepath,
                        fileSize: size
                    )
                }
                guard allowChecksumBackfill else { return }
                let mtimeMs = (attrs[.modificationDate] as? Date)
                    .map { $0.timeIntervalSince1970 * 1000 } ?? 0
                do {
                    try photoRepo.updateChecksum(
                        photoId: row.photoId, checksum: sum,
                        fileSize: size, fileMtimeMs: mtimeMs)
                } catch {
                    GatherLogger.log(
                        "library dedupe checksum backfill failed for \(row.photoId): \(error)",
                        level: .debug)
                }
            } catch {
                GatherLogger.log(
                    "library dedupe checksum skipped for \(row.photoId): \(error)",
                    level: .debug)
            }
        }
        // Wave4c（task-49）：未回填候选按 rowid 游标分页拉取直到不足一批，
        // 不再硬 LIMIT 500（大库 >500 会部分失效）。生产实现是 PhotoRepo；
        // 协议 fake（测试替身）没有分页方法时跳过懒算候选。
        if let concrete = photoRepo as? PhotoRepo {
            var afterRowId: Int64 = 0
            let pageSize = PhotoRepo.libraryUnhashedPageSize
            while true {
                let page = try concrete.libraryUnhashedFingerprints(
                    afterRowId: afterRowId, limit: pageSize)
                for row in page.rows {
                    inspectCandidate(row)
                }
                if page.rows.count < pageSize { break }
                afterRowId = page.lastRowId
            }
        } else {
            GatherLogger.log(
                "library dedupe: 照片仓储实现不支持未回填候选分页，跳过懒算候选",
                level: .debug)
        }
        return result
    }

    /// Wave4a-F3：replace 覆盖写入后刷新库内行的指纹（checksum / size / mtime）。
    ///
    /// replace 的目标是既有照片的 filepath，登记走 addPhotos 的 INSERT OR IGNORE，
    /// 不会重算哈希；不刷新会让库内指纹与文件内容不一致（跨会话去重、重复检测、
    /// 交付 manifest 校验都依赖它）。
    ///
    /// - Returns: 实际刷新的行数（找不到路径/读不到文件的跳过）。
    @discardableResult
    func refreshPhotoFingerprints(
        sessionId: String, filepaths: [String]
    ) throws -> Int {
        guard !filepaths.isEmpty else { return 0 }
        var photoIdByPath: [String: String] = [:]
        for row in try photoRepo.getBySessionProjection(sessionId: sessionId) {
            photoIdByPath[row.filepath] = row.id
        }
        var refreshed = 0
        for filepath in Set(filepaths) {
            guard let photoId = photoIdByPath[filepath] else { continue }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: filepath)
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                let mtimeMs = (attrs[.modificationDate] as? Date)
                    .map { $0.timeIntervalSince1970 * 1000 } ?? 0
                let sum = try FileHasher.sha256File(filepath)
                try photoRepo.updateChecksum(
                    photoId: photoId, checksum: sum, fileSize: size, fileMtimeMs: mtimeMs)
                refreshed += 1
            } catch {
                GatherLogger.log(
                    "refreshPhotoFingerprints skipped \(filepath): \(error)", level: .warn)
            }
        }
        return refreshed
    }

    /// Wave4a-F2：allowChecksumBackfill=false 时只读索引（预检用），不改库。
    public func photoChecksums(
        sessionId: String,
        matchingSizes: Set<Int>? = nil,
        allowChecksumBackfill: Bool = true
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try photoRepo.getBySessionProjection(sessionId: sessionId) {
            if !row.checksum.isEmpty {
                result[row.checksum] = row.id
            } else {
                let attrs: [FileAttributeKey: Any]
                do {
                    attrs = try FileManager.default.attributesOfItem(atPath: row.filepath)
                } catch {
                    attrs = [:]
                }
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                if let matchingSizes, !matchingSizes.isEmpty, !matchingSizes.contains(size) {
                    continue
                }
                // 懒索引默认不回填 checksum；摄取去重要对存量照片现算一次，
                // 否则重复摄取同一批卡会再复制一份。算完立即回写：下次摄取
                // 直接读 checksum，不再对整库逐张 SHA-256。
                do {
                    let sum = try FileHasher.sha256File(row.filepath)
                    result[sum] = row.id
                    let mtimeMs = (attrs[.modificationDate] as? Date)
                        .map { $0.timeIntervalSince1970 * 1000 } ?? 0
                    if !allowChecksumBackfill {
                        continue
                    }
                    do {
                        try photoRepo.updateChecksum(
                            photoId: row.id, checksum: sum,
                            fileSize: size, fileMtimeMs: mtimeMs)
                    } catch {
                        GatherLogger.log(
                            "ingest checksum backfill failed for \(row.id): \(error)",
                            level: .debug)
                    }
                } catch {
                    GatherLogger.log(
                        "ingest checksum skipped for \(row.id): \(error)", level: .debug)
                }
            }
        }
        return result
    }

    /// P1-3：设置/修复工作区根目录。
    ///
    /// 根必须是已存在目录、非 forbidden root，且包含工作区**全部可见照片**；
    /// 不满足时显式失败，不做“部分照片留在根外”的半状态。成功后不触发扫描，
    /// UI 再让用户选择“扫描整个根/扫描新增”。
    public func setSourceRoot(sessionId: String, sourceRoot: String) throws -> SessionData {
        guard try sessionRepo.get(id: sessionId) != nil else {
            throw SessionServiceError.sessionNotFound
        }
        guard !sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionServiceError.sourceNotDir
        }
        // 词汇路径与真实路径都保留：索引里存下的照片可能用链接前缀，
        // 也可能用真实前缀。只按 resolved 判会把合法链接根误拒。
        let lexicalRoot = ScanPath.canonical(sourceRoot)
        let resolvedRoot = ScanPath.canonical(
            URL(fileURLWithPath: sourceRoot).resolvingSymlinksInPath().path)
        guard !lexicalRoot.isEmpty, !resolvedRoot.isEmpty else {
            throw SessionServiceError.sourceNotDir
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionServiceError.sourceNotDir
        }
        guard !ScanPath.isForbiddenRoot(lexicalRoot),
              !ScanPath.isForbiddenRoot(resolvedRoot) else {
            throw SessionServiceError.sourceRootForbidden
        }
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }
        let outside = photos.filter {
            !ScanPath.isWithin(candidate: $0.filepath, root: lexicalRoot)
                && !ScanPath.isWithin(candidate: $0.filepath, root: resolvedRoot)
        }
        guard outside.isEmpty else {
            throw GatherError(
                code: .SESSION_SOURCE_EXCLUDES_PHOTOS,
                params: ["count": "\(outside.count)"]
            )
        }
        // 保留用户选择的词汇路径，后续扫描/监听与照片前缀同口径。
        guard try sessionRepo.updateSourcePath(id: sessionId, path: lexicalRoot) else {
            throw SessionServiceError.sessionNotFound
        }
        guard let updated = try sessionRepo.get(id: sessionId) else {
            throw SessionServiceError.sessionNotFound
        }
        return try toSessionData(updated)
    }

    public func updateSession(sessionId: String, name: String) throws -> SessionData {
        let updated = try sessionRepo.updateName(id: sessionId, name: name)
        if !updated { throw SessionServiceError.sessionNotFound }
        guard let row = try sessionRepo.get(id: sessionId) else { throw SessionServiceError.sessionNotFound }
        return try toSessionData(row)
    }

    /// SessionRow → 协议形状。
    ///
    /// V1 已删 sessions.writeback_status / failed_writeback_count / import_source
    /// （D-021）：写回态由 deliveries + delivery_items 聚合派生（无交付 → idle），
    /// 失败数取 failed item 计数；import_source 无替代列，返回空串（调用方/UI
    /// 不依赖该字段，保留它只为协议形状不变）。
    private func toSessionData(_ row: SessionRow) throws -> SessionData {
        guard let status = SessionStatus(rawValue: row.status),
              let analysis = AnalysisStatus(rawValue: row.analysisStatus) else {
            throw SessionServiceError.sessionNotFound
        }
        let delivery = try deliverySummary.summary(sessionId: row.id)
        return SessionData(
            id: row.id,
            name: row.name,
            status: status,
            photoCount: row.photoCount,
            analysisStatus: analysis,
            writebackStatus: delivery.writebackStatus,
            importSource: "",
            sourcePath: row.sourcePath,
            failedWritebackCount: delivery.itemCounts[.failed] ?? 0,
            truncatedImport: row.truncatedImport == 1,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// TS: stat + isDirectory 校验（失败或非目录 → SESSION_SOURCE_NOT_DIR）。
    private func requireDirectory(_ path: String) throws {
        var s = stat()
        guard stat(path, &s) == 0 else { throw SessionServiceError.sourceNotDir }
        guard (s.st_mode & S_IFMT) == S_IFDIR else { throw SessionServiceError.sourceNotDir }
    }
}

// MARK: - 路径工具（TS session.service.ts 模块级函数）

/// TS: sanitizeSessionSourcePath —— 调用方提供的 sourcePath 只有在它是**至少两张
/// 已导入照片的真实公共父目录**时才被接受，否则返回空串。
///
/// 这是「目录作用域准入」的域规则：单文件、文件系统根、主目录、无公共父目录
/// 一律不得成为 source_path，否则索引器/监听器会递归到用户未选择的目录。
/// 注意它不再是「文件导入把公共父目录落库」的许可：文件导入的作用域由
/// metadata.scan job 的 requestedPaths 显式携带，source_path 保持为空。
public func sanitizeSessionSourcePath(sourcePath: String, filepaths: [String]) -> String {
    let resolved = ScanPath.canonical(sourcePath)
    if resolved.isEmpty || ScanPath.isForbiddenRoot(resolved) { return "" }
    let normalized = normalizeImportFilepaths(filepaths)
    if normalized.count < 2 { return "" }
    let parent = commonParentDirectory(filepaths: normalized)
    return !parent.isEmpty && resolved == parent ? resolved : ""
}

