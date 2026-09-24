// desktop/native/gather-core/Sources/GatherCore/Runtime/Indexer/IndexerRuntime.swift
// idx2a：IndexerRuntime actor 最小骨架（签署接口；行为随后续步骤迁入）。
// idx2b3：迁入 scan 的只读阶段（目录遍历/扩展名过滤/排除规则/stat 与
// contentChanged 判定/分块），产出候选变更列表。
// idx2b4：迁入 scan 的写库/对账阶段（旧 Services/IndexerService.scanSession
// 的写序逐段对齐）：生成缓存清扫 → existing/existingByPath 重算 → asset_files
// 基线读取 → 32 文件一批的 stat/尺寸/checksum/relink 探测与写回 →
// asset_files 批回写 + 路径相关分析失效 → Store 侧 updateIndexedFile /
// updateChecksum / addPhotos → missing 对账 + markMissing + asset_files offline
// → backfillSession → photoCount / status / index_seq 提交；scan 返回真实
// IndexScanResult。
//
// 边界（逐步填充）：
// - 可变状态：cancelledSessions（cancel(sessionId:) 幂等登记；批间读取并清理，
//   命中抛 JobCancelledError）+ lastScanCandidateList（本次 scan 的分类产物）。
//   本文件零 SQL 文本、零锁；写库全部经 Store 协议方法。
// - 依赖经 Dependencies 值类型注入；SessionStore / PhotoStore / AssetStore 协议
//   继承 Sendable，SQLiteDatabase 为 actor，因此 Dependencies 可安全跨 actor
//   边界传递。
// - 契约类型复用 Protocol/Indexer.swift 的真实定义（IndexScanParams /
//   IndexScanResult），不在此重复声明。错误复用 Services 侧 IndexerServiceError
//   （sessionNotFound / noSourcePath，与旧 scanSession 一致）与
//   Runtime/Jobs/JobRunner.JobCancelledError（批间取消）。
// - 旧 scanSession 的 JobRunnerContext 不入 actor：scan 签名无 context，取消经
//   cancel(sessionId:) + 批间检查提供，进度上报留待接线步骤。

import Foundation
import SQLite3
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 索引器运行时错误（骨架期占位；idx2b4 起 scan 不再抛 notImplemented，
/// 保留公开类型以稳定已签署的接口面）。
public enum IndexerRuntimeError: Error, Equatable {
    case notImplemented(sessionId: String)
}

/// 扫描候选分类（idx2b3 引入；idx2b4 起由写阶段真实批结果等价推导）。
public enum IndexScanCandidateAction: String, Sendable, Equatable {
    /// 文件存在且会话内无同路径照片。
    case new
    /// 会话内已有同路径照片，stat/基线判定内容变化（尺寸与 checksum 留待写阶段）。
    case changed
    /// 会话内已有同路径照片且基线证明未变（asset_files 基线已接入；checksum
    /// 非空时短路为 unchanged）。
    case unchanged
    /// stat 失败：目录列举与 stat 之间消失，后续对账为 missing。
    case missing
    /// 不可读目录（非根遍历失败，对齐旧 failed 语义）。
    case failed
}

/// 单个扫描候选（filepath + 只读分类）。
public struct IndexScanCandidate: Sendable, Equatable {
    public let filepath: String
    public let action: IndexScanCandidateAction

    public init(filepath: String, action: IndexScanCandidateAction) {
        self.filepath = filepath
        self.action = action
    }
}

public actor IndexerRuntime {
    /// 运行时依赖（idx2b1 扩容：对齐旧 IndexerService 全集；引用为 Sendable
    /// 值语义，闭包为 @Sendable，可跨 actor 边界传递）。
    public struct Dependencies: Sendable {
        public let sessionStore: any SessionStore
        public let photoStore: any PhotoStore
        public let assetStore: any AssetStore
        public let database: SQLiteDatabase
        /// 图片尺寸读取（旧 IndexerService.DimensionsProvider；默认走 RAWDecoder）。
        public let getDimensions: @Sendable (String) throws -> (width: Int, height: Int)
        /// 设置读取（旧 IndexerService.SettingReader；默认回退 defaultValue）。
        public let getSetting: @Sendable (String, String) -> String
        /// stat 测试接缝（等价旧 IndexerService.stat；默认 IndexerService.defaultStat）。
        public var stat: @Sendable (String) throws -> IndexerService.FileStat
        /// checksum 计算接缝（等价旧 IndexerService.fileHasher；默认 IndexerService.sha256File）。
        public var fileHasher: @Sendable (String) async throws -> String

        public init(
            sessionStore: any SessionStore,
            photoStore: any PhotoStore,
            assetStore: any AssetStore,
            database: SQLiteDatabase,
            getDimensions: @escaping @Sendable (String) throws -> (width: Int, height: Int) = { try IndexerService.defaultDimensions($0) },
            getSetting: @escaping @Sendable (String, String) -> String = { _, defaultValue in defaultValue },
            stat: @escaping @Sendable (String) throws -> IndexerService.FileStat = { try IndexerService.defaultStat($0) },
            fileHasher: @escaping @Sendable (String) async throws -> String = { try IndexerService.sha256File($0) }
        ) {
            self.sessionStore = sessionStore
            self.photoStore = photoStore
            self.assetStore = assetStore
            self.database = database
            self.getDimensions = getDimensions
            self.getSetting = getSetting
            self.stat = stat
            self.fileHasher = fileHasher
        }
    }

    private let deps: Dependencies

    /// 已请求取消的 session（cancel(sessionId:) 幂等登记；批间读取并清理）。
    private var cancelledSessions: Set<String> = []

    /// 最近一次 scan 的分类产物（idx2b3 语义的候选列表）。
    private var lastScanCandidateList: [IndexScanCandidate] = []

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// 扫描：全量遍历 + 索引入库 + 缺失对账 + index_seq 游标（旧
    /// IndexerService.scanSession 的 actor 化）。注：options 复用协议层真实的
    /// IndexScanParams（其自带 sessionId 字段，与入参 sessionId 重复，属契约原样
    /// 复用）；IndexScanParams 目前无 requestedPaths 字段，增量分支保留私有参数，
    /// 待契约补齐后接入。
    public func scan(sessionId: String, options: IndexScanParams) async throws -> IndexScanResult {
        lastScanCandidateList = []
        // 终态清理登记：迟到的 cancel 不得污染下一次 scan；扫描途中的取消在
        // 批间检查处消费并抛出。
        defer { cancelledSessions.remove(sessionId) }
        return try await performScan(sessionId: sessionId, requestedPaths: nil)
    }

    /// 最近一次 scan 收集到的候选文件路径（idx2b3 internal 访问器）。
    func lastScanCandidates() -> [String] {
        lastScanCandidateList.map(\.filepath)
    }

    /// 最近一次 scan 的候选分类明细（filepath + action）。
    func lastScanClassifications() -> [IndexScanCandidate] {
        lastScanCandidateList
    }

    /// 请求取消（幂等）。
    public func cancel(sessionId: String) {
        cancelledSessions.insert(sessionId)
    }

    /// TS: managedCacheRoots —— disk_cache_dir 设置优先，否则默认缓存目录。
    private func managedCacheRoots() -> [String] {
        let configured = deps.getSetting("disk_cache_dir", "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return [IndexAssembler.canonicalPath(configured)] }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return [IndexAssembler.canonicalPath(appSupport.appendingPathComponent("thumbnails").path)]
        }
        return []
    }

    // ───────────── idx2b4：scan 写库/对账（旧 scanSession 的 actor 化） ─────────────

    /// 扫描主体：读阶段（会话/缓存清扫/基线）+ 写阶段（32 文件一批按时序提交）+
    /// 终态（missing 对账/计数/状态/index_seq）。写序与旧 scanSession 逐段对齐：
    /// 会话与源路径校验 → 缓存清扫（清扫后回读重算）→ existingByPath 与
    /// asset_files 基线 → 分批写 → 终态对账。取消/出错且已提交过变更时
    /// best-effort 推进 index_seq（不掩盖原错误）。
    private func performScan(sessionId: String, requestedPaths: [String]?) async throws -> IndexScanResult {
        let session = try await deps.sessionStore.get(id: sessionId)
        guard let session else { throw IndexerServiceError.sessionNotFound }
        guard !session.sourcePath.isEmpty else { throw IndexerServiceError.noSourcePath }
        let excludedRoots = managedCacheRoots()
        var existing = try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
        // 生成缓存目录内的存量照片（缓存清扫）：Store 事务删除照片行 + 孤儿资产行。
        let generatedCachePhotos = existing.filter { photo in
            IndexAssembler.isExcluded(path: TSPath.resolve(photo.filepath), excludedRoots: excludedRoots)
        }
        if !generatedCachePhotos.isEmpty {
            _ = try await deps.photoStore.purgeGeneratedCachePhotos(
                photoIds: generatedCachePhotos.map(\.id), sessionId: sessionId
            )
            // 清扫事务已提交：existing/existingByPath 必须回读重算，后续写阶段
            // 不得再依据清扫前的内存快照。
            existing = try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
        }
        let existingByPath: [String: PhotoProjection] = Dictionary(
            uniqueKeysWithValues: existing.map { (IndexAssembler.normalizedPath($0.filepath), $0) }
        )
        // asset_files 扫描基线（键为 asset_files.id = photo.assetFileId，与旧
        // fileStats[assetFileId] 的 join 键一致）。
        let baselines = try await deps.assetStore.assetFileStatsBySession(sessionId: sessionId)

        var discoveredSet = Set<String>()
        var relinkedPhotoIds = Set<String>()
        var failed: [String] = []
        var discovered = 0
        var added = 0
        var skipped = 0
        // 内容变化的存量照片计数（连同 added/relinked/missing 驱动 index_seq）。
        var updatedExistingPhotos = 0
        // 提前声明：取消/出错路径需要判断是否发生过真实变更（对账前保持空）。
        var missing: [PhotoProjection] = []
        var candidates: [IndexScanCandidate] = []

        do {
            var filepaths: [String] = []
            var unreadableDirectories: [String] = []
            var requestedNormalized: Set<String>? = nil
            if let requestedPaths {
                // 旧 scanSession 的 requestedPaths 分支：显式路径只做排除 + stat
                // 存在性 + 扩展名过滤；缺失路径留给末段对账判 missing。
                requestedNormalized = Set(requestedPaths.map(IndexAssembler.normalizedPath))
                for filepath in Set(requestedPaths.map { TSPath.resolve($0) }) {
                    if IndexAssembler.isExcluded(path: filepath, excludedRoots: excludedRoots) { continue }
                    do {
                        let source = try deps.stat(filepath)
                        if source.isFile && IndexAssembler.isSupportedImage(filepath) {
                            filepaths.append(filepath)
                        }
                    } catch {
                        // 缺失路径在末段对账。
                    }
                }
            } else {
                // 顺序递归遍历（排序 DFS，与旧 walk 的产出顺序一致）；不可读
                // 非根目录记入失败集，不可读根直接抛错。
                try traverseFiles(
                    directory: session.sourcePath,
                    isRoot: true,
                    excludedRoots: excludedRoots,
                    filepaths: &filepaths,
                    unreadableDirectories: &unreadableDirectories
                )
            }
            // discovered = 遍历产出的支持图片数（requestedPaths 分支为通过
            // 存在性/扩展名过滤的路径数，与旧实现两分支一致）。
            discovered = filepaths.count
            failed.append(contentsOf: unreadableDirectories)
            candidates.append(contentsOf: unreadableDirectories.map {
                IndexScanCandidate(filepath: $0, action: .failed)
            })

            // 写阶段：32 文件一批，批间检查取消（批前与末批后各一次）。
            var offset = 0
            while offset < filepaths.count {
                try throwIfCancelled(sessionId: sessionId)
                let end = min(offset + IndexAssembler.scanBatchFiles, filepaths.count)
                let effects = try await processScanBatch(
                    filepaths: Array(filepaths[offset..<end]),
                    sessionId: sessionId,
                    existingByPath: existingByPath,
                    baselines: baselines
                )
                discoveredSet.formUnion(effects.discoveredNormalized)
                relinkedPhotoIds.formUnion(effects.relinkedPhotoIds)
                failed.append(contentsOf: effects.failedPaths)
                candidates.append(contentsOf: effects.candidates)
                added += effects.added
                skipped += effects.skipped
                updatedExistingPhotos += effects.updatedExistingPhotos
                offset = end
            }
            try throwIfCancelled(sessionId: sessionId)

            missing.append(contentsOf: IndexAssembler.missingPhotos(
                existing: existing,
                requestedNormalized: requestedNormalized,
                discoveredSet: discoveredSet,
                relinkedPhotoIds: relinkedPhotoIds
            ))
            try await deps.photoStore.markMissing(photoIds: missing.map(\.id))
            _ = try await deps.assetStore.backfillSession(sessionId)
            // index_seq 是分析过期游标：仅真实变更（新增/内容变/重链接/新增缺失）
            // 才推进；空转扫描不得把分析标脏。
            let committedChanges = added > 0
                || updatedExistingPhotos > 0
                || !relinkedPhotoIds.isEmpty
                || !missing.isEmpty
            let finalCount = try await deps.photoStore.countBySession(sessionId: sessionId)
            try await deps.sessionStore.updatePhotoCount(id: sessionId, count: finalCount)
            if committedChanges {
                _ = try await deps.sessionStore.bumpIndexSeq(id: sessionId)
            }
            if finalCount > 0 && session.status == "draft" {
                try await deps.sessionStore.updateStatus(id: sessionId, status: "photos_loaded")
            }
            if !missing.isEmpty {
                // 缺失照片的 asset_files 标记 offline（M4；updatedAt 为 ISO 文本）。
                _ = try await deps.assetStore.markAssetFilesOffline(
                    ids: missing.compactMap(\.assetFileId), updatedAt: nowISOString()
                )
            }
            lastScanCandidateList = candidates
            return IndexScanResult(
                sessionId: sessionId,
                discovered: discovered,
                added: added,
                skipped: skipped,
                missing: missing.count,
                failed: failed
            )
        } catch {
            // 取消/失败路径同样推进已提交批次的 index_seq（best-effort，不掩盖
            // 原错误）：已导入照片对已完成分析可见。
            let committedChanges = added > 0
                || updatedExistingPhotos > 0
                || !relinkedPhotoIds.isEmpty
                || !missing.isEmpty
            if committedChanges {
                _ = try? await deps.sessionStore.bumpIndexSeq(id: sessionId)
            }
            throw error
        }
    }

    /// 一批（IndexAssembler.scanBatchFiles=32）的写阶段：批内并发 4（ConcurrentMap
    /// 保序）读取尺寸/checksum → relink 探测（每文件一次）→ asset_files 批回写
    /// （Store 单事务）→ 路径相关分析失效 → Store 侧照片写/新增。对应旧 scanBatch
    /// 闭包 + 批后失效与写入段。
    private func processScanBatch(
        filepaths: [String],
        sessionId: String,
        existingByPath: [String: PhotoProjection],
        baselines: [String: AssetFileScanBaseline]
    ) async throws -> IndexBatchEffects {
        try throwIfCancelled(sessionId: sessionId)
        let lazyChecksum = deps.getSetting("lazy_checksum", "true") != "false"
        let dependencies = deps
        let outcomes = try await ConcurrentMap.run(
            filepaths,
            concurrency: IndexAssembler.scanBatchConcurrency
        ) { filepath -> IndexFileOutcome in
            let normalized = IndexAssembler.normalizedPath(filepath)
            // stat 先行：目录列举与 stat 之间消失的文件不得进入 discoveredSet，
            // 否则末段永远不会把它对账为 missing（ghost photo）。
            let source: IndexerService.FileStat
            do {
                source = try dependencies.stat(filepath)
            } catch {
                return IndexFileOutcome(filepath: filepath, normalized: normalized, item: .missing)
            }
            guard let photo = existingByPath[normalized] else {
                do {
                    let dimensions = try dependencies.getDimensions(filepath)
                    let checksum = lazyChecksum ? "" : try await dependencies.fileHasher(filepath)
                    return IndexFileOutcome(filepath: filepath, normalized: normalized, item: .new(
                        width: dimensions.width, height: dimensions.height,
                        checksum: checksum, fileSize: source.size, fileMtimeMs: source.mtimeMs,
                        fileIdentity: String(source.ino)
                    ))
                } catch {
                    return IndexFileOutcome(filepath: filepath, normalized: normalized, item: .failed)
                }
            }
            let indexed = photo.assetFileId.flatMap { baselines[$0] }
            // NULL checksum 与「无基线行」在旧实现同为不可用基线（旧 fileStats
            // 用空串兜底），此处一并折叠为 indexedChecksum。
            let indexedChecksum = indexed?.checksum ?? ""
            // 仅当基线证明文件确实变化才算 content-changed：无 asset_files 行时
            // 用照片自身的索引 stat（checksum_file_size/mtime）作基线。
            let contentChanged = IndexAssembler.contentChanged(
                indexedFileSize: indexed?.fileSize,
                indexedFileMtimeMs: indexed?.mtimeMs,
                photoChecksumFileSize: photo.checksumFileSize,
                photoChecksumFileMtimeMs: photo.checksumFileMtimeMs,
                sourceSize: source.size,
                sourceMtimeMs: source.mtimeMs
            )
            // 旧实现的短路：基线存在且 checksum 非空 → unchanged。
            if !contentChanged && photo.status != "missing" && !indexedChecksum.isEmpty {
                return IndexFileOutcome(filepath: filepath, normalized: normalized, item: .unchanged)
            }
            do {
                let dimensions = try dependencies.getDimensions(filepath)
                let needsChecksum = contentChanged || indexedChecksum.isEmpty
                let checksum: String
                if needsChecksum {
                    checksum = lazyChecksum ? "" : try await dependencies.fileHasher(filepath)
                } else {
                    checksum = indexedChecksum
                }
                // 懒模式 + 未变化 + 快照 checksum 为空：不得清掉并发回填刚写入的
                // 哈希（旧 preserveChecksum 语义）。
                let preserveChecksum = lazyChecksum && !contentChanged && indexedChecksum.isEmpty
                return IndexFileOutcome(filepath: filepath, normalized: normalized, item: .existing(
                    photoId: photo.id, assetFileId: photo.assetFileId,
                    width: dimensions.width, height: dimensions.height,
                    contentChanged: contentChanged, fileSize: source.size,
                    fileMtimeMs: source.mtimeMs, checksum: checksum,
                    preserveChecksum: preserveChecksum,
                    volumeId: "dev:\(source.dev)", fileIdentity: String(source.ino)
                ))
            } catch {
                return IndexFileOutcome(filepath: filepath, normalized: normalized, item: .failed)
            }
        }

        // relink 探测先行（每文件一次），结果带入写库段；真实数据库错误直接抛出。
        var relinkResults: [String: AssetRelinkFileResult?] = [:]
        var relinkFailed = Set<String>()
        for outcome in outcomes {
            if case .new(_, _, let checksum, let fileSize, let fileMtimeMs, let fileIdentity) = outcome.item {
                do {
                    relinkResults[outcome.filepath] = try await deps.assetStore.relinkMovedFile(
                        newPath: outcome.filepath, checksum: checksum, fileSize: fileSize,
                        fileMtimeMs: fileMtimeMs, fileIdentity: fileIdentity
                    )
                } catch {
                    if error is SQLiteFailure { throw error }
                    relinkFailed.insert(outcome.filepath)
                }
            }
        }

        var effects = IndexBatchEffects()
        var assetUpdates: [AssetFileScanUpdate] = []
        var indexedWrites: [(photoId: String, width: Int, height: Int, changed: Bool)] = []
        var checksumWrites: [(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double)] = []
        var insertEntries: [IndexInsertEntry] = []
        var batchAffectedPhotoIds = Set<String>()

        for outcome in outcomes {
            effects.candidates.append(candidate(for: outcome))
            switch outcome.item {
            case .missing:
                // 不进入 discoveredSet：由末段对账为 missing。
                break
            case .failed:
                effects.discoveredNormalized.insert(outcome.normalized)
                effects.failedPaths.append(outcome.filepath)
            case .unchanged:
                effects.discoveredNormalized.insert(outcome.normalized)
                effects.skipped += 1
            case .new(let width, let height, let checksum, let fileSize, let fileMtimeMs, _):
                effects.discoveredNormalized.insert(outcome.normalized)
                if relinkFailed.contains(outcome.filepath) {
                    // 单文件可恢复失败（XMP 写入中、sidecar 冲突等守卫）不整批
                    // 回滚；真实数据库错误已在上方抛出。
                    effects.failedPaths.append(outcome.filepath)
                } else if let relocated = relinkResults[outcome.filepath] ?? nil, !relocated.photoIds.isEmpty {
                    for photoId in relocated.photoIds {
                        batchAffectedPhotoIds.insert(photoId)
                        effects.relinkedPhotoIds.insert(photoId)
                        indexedWrites.append((photoId, width, height, true))
                        checksumWrites.append((photoId, checksum, Int(fileSize), fileMtimeMs))
                    }
                    effects.skipped += 1
                } else {
                    insertEntries.append(IndexInsertEntry(
                        filepath: outcome.filepath, width: width, height: height,
                        checksum: checksum, fileSize: fileSize, fileMtimeMs: fileMtimeMs
                    ))
                }
            case .existing(let photoId, let assetFileId, let width, let height, let contentChanged,
                           let fileSize, let fileMtimeMs, let checksum, let preserveChecksum,
                           let volumeId, let fileIdentity):
                effects.discoveredNormalized.insert(outcome.normalized)
                if contentChanged { effects.updatedExistingPhotos += 1 }
                indexedWrites.append((photoId, width, height, contentChanged))
                // 懒模式 + 未变化 + 空快照 checksum：保留照片行已有值。
                if !preserveChecksum {
                    checksumWrites.append((photoId, checksum, Int(fileSize), fileMtimeMs))
                }
                assetUpdates.append(AssetFileScanUpdate(
                    assetFileId: assetFileId, volumeId: volumeId, fileIdentity: fileIdentity,
                    fileSize: fileSize, fileMtimeMs: fileMtimeMs, checksum: checksum,
                    preserveChecksum: preserveChecksum, contentChanged: contentChanged,
                    width: width, height: height
                ))
            }
        }

        // asset_files 批回写（Store 单事务；contentChanged 照片同时回传供失效）。
        batchAffectedPhotoIds.formUnion(
            try await deps.assetStore.applyScannedFiles(assetUpdates, sessionId: sessionId)
        )
        // 批提交成功后做一次失效（提交失败则回滚，分析输入保持有效）。
        try await deps.assetStore.invalidatePathDependentAnalysis(photoIds: Array(batchAffectedPhotoIds))
        // Store 写不参与旧事务：批提交后按原序应用（photoId 幂等）。
        for update in indexedWrites {
            try await deps.photoStore.updateIndexedFile(
                photoId: update.photoId, width: update.width, height: update.height, changed: update.changed
            )
        }
        for update in checksumWrites {
            try await deps.photoStore.updateChecksum(
                photoId: update.photoId, checksum: update.checksum,
                fileSize: update.fileSize, fileMtimeMs: update.fileMtimeMs
            )
        }
        if !insertEntries.isEmpty {
            let inserted = try await deps.photoStore.addPhotos(
                sessionId: sessionId,
                inputs: insertEntries.map {
                    PhotoAddInput(filepath: $0.filepath, width: $0.width, height: $0.height)
                },
                source: "index"
            )
            effects.added += inserted.added
            effects.skipped += inserted.skipped
            for (index, entry) in insertEntries.enumerated() {
                guard index < inserted.ids.count, !inserted.ids[index].isEmpty else { continue }
                try await deps.photoStore.updateChecksum(
                    photoId: inserted.ids[index], checksum: entry.checksum,
                    fileSize: Int(entry.fileSize), fileMtimeMs: entry.fileMtimeMs
                )
            }
        }
        return effects
    }

    /// 批结果 → 候选分类（idx2b3 语义的等价映射：existing 一律 .changed —— 旧
    /// unchanged 短路之外的文件都走写回分支）。
    private func candidate(for outcome: IndexFileOutcome) -> IndexScanCandidate {
        let action: IndexScanCandidateAction
        switch outcome.item {
        case .new: action = .new
        case .existing: action = .changed
        case .unchanged: action = .unchanged
        case .failed: action = .failed
        case .missing: action = .missing
        }
        return IndexScanCandidate(filepath: outcome.filepath, action: action)
    }

    /// 批间取消检查：命中登记即消费并抛 JobCancelledError（等价旧
    /// JobRunnerContext.throwIfCancelled）。
    private func throwIfCancelled(sessionId: String) throws {
        if cancelledSessions.remove(sessionId) != nil {
            throw JobCancelledError()
        }
    }

    /// TS: walk —— 顺序递归遍历（lstat 判目录，符号链接不进递归）；目录项
    /// 排序后 DFS，与旧 traverse 的产出顺序一致。不可读非根目录记入失败集，
    /// 不可读根直接抛错（旧 channel.fail 语义）。
    private func traverseFiles(
        directory: String,
        isRoot: Bool,
        excludedRoots: [String],
        filepaths: inout [String],
        unreadableDirectories: inout [String]
    ) throws {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            if isRoot { throw error }
            unreadableDirectories.append(directory)
            return
        }
        for name in entries {
            let full = directory + "/" + name
            if IndexAssembler.isExcluded(path: full, excludedRoots: excludedRoots) { continue }
            if Self.isDirectory(full) {
                try traverseFiles(
                    directory: full,
                    isRoot: false,
                    excludedRoots: excludedRoots,
                    filepaths: &filepaths,
                    unreadableDirectories: &unreadableDirectories
                )
            } else if IndexAssembler.isSupportedImage(name) {
                filepaths.append(full)
            }
        }
    }

    /// lstat 判定（符号链接不进入递归，与旧 IndexerService.isDirectory 一致）。
    private static func isDirectory(_ path: String) -> Bool {
        var s = runtimeLstatBuf()
        return lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
    }
}

// MARK: - 扫描写阶段载荷类型

/// 单文件批写结果（normalized 供 discoveredSet 入集；filepath 供候选列表与
/// relink 失败集使用）。
private struct IndexFileOutcome: Sendable {
    let filepath: String
    let normalized: String
    let item: IndexBatchItem
}

/// 单文件批写载荷（字段按旧 scanBatch 的 BatchItem 对齐）。
private enum IndexBatchItem: Sendable {
    case new(width: Int, height: Int, checksum: String,
             fileSize: Int64, fileMtimeMs: Double, fileIdentity: String)
    case existing(photoId: String, assetFileId: String?, width: Int, height: Int,
                  contentChanged: Bool, fileSize: Int64, fileMtimeMs: Double,
                  checksum: String, preserveChecksum: Bool,
                  volumeId: String, fileIdentity: String)
    case unchanged
    case failed
    case missing
}

/// 待入库新照片（旧 scanBatch 的 newEntries 元素）。
private struct IndexInsertEntry: Sendable {
    let filepath: String
    let width: Int
    let height: Int
    let checksum: String
    let fileSize: Int64
    let fileMtimeMs: Double
}

/// 一批写阶段产物（scan 侧统一合并；抛错批次的增量不参与合并）。
private struct IndexBatchEffects: Sendable {
    var added = 0
    var skipped = 0
    var updatedExistingPhotos = 0
    var relinkedPhotoIds: Set<String> = []
    var discoveredNormalized: Set<String> = []
    var failedPaths: [String] = []
    var candidates: [IndexScanCandidate] = []
}

/// lstat 缓冲（文件级辅助：规避名为 stat 的成员对 POSIX stat 的遮蔽，
/// 形态与旧 IndexerService.lstatBuf 一致）。
private func runtimeLstatBuf() -> stat {
    stat()
}
