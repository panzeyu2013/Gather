// desktop/native/gather-core/Sources/GatherCore/Runtime/Indexer/IndexerRuntime.swift
// idx2a：IndexerRuntime actor 最小骨架（签署接口；行为随后续步骤迁入）。
// idx2b3：迁入 scan 的只读阶段（目录遍历/扩展名过滤/排除规则/stat 与
// contentChanged 判定/分块），产出候选变更列表；scan 仍抛 notImplemented，
// 写库、缺失对账与 index_seq 推进留待后续步骤。
// idxbase：asset_files 扫描基线经 AssetStore.assetFileStatsBySession 接入
// classify（键为 photo.assetFileId → asset_files.id），.unchanged 现可产出。
//
// 边界（逐步填充）：
// - 可变状态：cancelledSessions（cancel(sessionId:) 幂等登记，扫描实现迁入后
//   读取并清理）+ lastScanCandidateList（idx2b3 只读遍历/分类产物）。
//   本文件零 SQL、零锁；idx2b3 起只读调用 Store 协议（SessionStore/PhotoStore），
//   不触碰 Store 实现，也不写库。
// - 依赖经 Dependencies 值类型注入；SessionStore / PhotoStore 协议继承 Sendable，
//   SQLiteDatabase 为 actor，因此 Dependencies 可安全跨 actor 边界传递。
// - 契约类型复用 Protocol/Indexer.swift 的真实定义（IndexScanParams /
//   IndexScanResult），不在此重复声明。错误用本文件新增的最小
//   IndexerRuntimeError：旧 Services/IndexerService.swift 的 IndexerServiceError
//   只有 sessionNotFound / noSourcePath，无骨架所需的 notImplemented 类目。

import Foundation
import SQLite3
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 索引器运行时错误（骨架期占位；实现迁入后按需增删）。
public enum IndexerRuntimeError: Error, Equatable {
    case notImplemented(sessionId: String)
}

/// 扫描候选的只读分类（idx2b3：目录遍历/分类阶段产物；写库与对账未实现）。
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

    /// 已请求取消的 session（骨架期只登记；扫描实现随后续步骤消费并清理）。
    private var cancelledSessions: Set<String> = []

    /// 最近一次 scan 只读阶段产出的候选（idx2b3；写库/对账为后续步骤）。
    private var lastScanCandidateList: [IndexScanCandidate] = []

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// 扫描（idx2b3：只执行只读遍历/分类，写库与对账未实现，故仍抛
    /// notImplemented；候选列表经 lastScanCandidates()/lastScanClassifications()
    /// 暴露）。注：options 复用协议层真实的 IndexScanParams（其自带 sessionId
    /// 字段，与入参 sessionId 重复，属契约原样复用）；IndexScanParams 目前无
    /// requestedPaths 字段，增量分支保留私有参数，待契约补齐后接入。
    public func scan(sessionId: String, options: IndexScanParams) async throws -> IndexScanResult {
        lastScanCandidateList = []
        lastScanCandidateList = try await collectScanCandidates(sessionId: sessionId, requestedPaths: nil)
        throw IndexerRuntimeError.notImplemented(sessionId: sessionId)
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

    // ───────────── idx2b3：scan 只读阶段（目录遍历/分类） ─────────────

    /// TS: managedCacheRoots —— disk_cache_dir 设置优先，否则默认缓存目录。
    private func managedCacheRoots() -> [String] {
        let configured = deps.getSetting("disk_cache_dir", "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return [IndexAssembler.canonicalPath(configured)] }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return [IndexAssembler.canonicalPath(appSupport.appendingPathComponent("thumbnails").path)]
        }
        return []
    }

    /// 只读候选收集：目录遍历/扩展名过滤/排除规则 + 逐文件 stat/内容变化分类，
    /// 按 scanBatchFiles=32 分块。零 SQL、零写库、不做对账（missing 对账需要
    /// discoveredSet 与 Store 写序，属后续步骤）。
    private func collectScanCandidates(
        sessionId: String,
        requestedPaths: [String]?
    ) async throws -> [IndexScanCandidate] {
        let session = try await deps.sessionStore.get(id: sessionId)
        guard let session else { throw IndexerServiceError.sessionNotFound }
        guard !session.sourcePath.isEmpty else { throw IndexerServiceError.noSourcePath }
        let excludedRoots = managedCacheRoots()

        var filepaths: [String] = []
        var unreadableDirectories: [String] = []
        if let requestedPaths {
            // 旧 scanSession 的 requestedPaths 分支：显式路径只做排除 + stat
            // 存在性 + 扩展名过滤；缺失路径留给分类阶段判 missing。
            for filepath in Set(requestedPaths.map { TSPath.resolve($0) }) {
                if IndexAssembler.isExcluded(path: filepath, excludedRoots: excludedRoots) { continue }
                do {
                    let source = try deps.stat(filepath)
                    if source.isFile && IndexAssembler.isSupportedImage(filepath) {
                        filepaths.append(filepath)
                    }
                } catch {
                    // 缺失路径在分类阶段经 stat 失败判 missing。
                }
            }
        } else {
            // 生产者/消费者与有界通道是写阶段的流式结构；只读阶段一次性收集
            // 排序 DFS 文件序，与旧 walk 的产出顺序一致。
            try traverseFiles(
                directory: session.sourcePath,
                isRoot: true,
                excludedRoots: excludedRoots,
                filepaths: &filepaths,
                unreadableDirectories: &unreadableDirectories
            )
        }

        // 只读基线：existingByPath 用于区分 new/existing；asset_files 的
        // size/mtime/checksum 基线经 AssetStore 只读方法批量读取（键为
        // asset_files.id = photo.assetFileId，与旧实现 fileStats[assetFileId]
        // 的 join 键一致），本文件仍零 SQL。
        let existing = try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
        let existingByPath: [String: PhotoProjection] = Dictionary(
            uniqueKeysWithValues: existing.map { (IndexAssembler.normalizedPath($0.filepath), $0) }
        )
        let baselinesByAssetFileId = try await deps.assetStore.assetFileStatsBySession(sessionId: sessionId)

        var candidates: [IndexScanCandidate] = []
        candidates.reserveCapacity(filepaths.count + unreadableDirectories.count)
        // 分块（旧 scanBatch 按 scanBatchFiles 收批）；块内并发 4 由 Services
        // 内文件级私有 mapConcurrent 提供，本文件无法复用，此处按块顺序分类
        // （纯 stat + 纯函数，无写库副作用）。
        var offset = 0
        while offset < filepaths.count {
            let end = min(offset + IndexAssembler.scanBatchFiles, filepaths.count)
            for filepath in filepaths[offset..<end] {
                candidates.append(classify(
                    filepath: filepath,
                    existingByPath: existingByPath,
                    baselinesByAssetFileId: baselinesByAssetFileId
                ))
            }
            offset = end
        }
        for directory in unreadableDirectories {
            candidates.append(IndexScanCandidate(filepath: directory, action: .failed))
        }
        return candidates
    }

    /// 单文件分类（旧 scanBatch 的只读判定部分：stat + contentChanged；
    /// 尺寸/checksum 读取属写阶段，本步骤不发）。
    private func classify(
        filepath: String,
        existingByPath: [String: PhotoProjection],
        baselinesByAssetFileId: [String: AssetFileScanBaseline]
    ) -> IndexScanCandidate {
        let normalized = IndexAssembler.normalizedPath(filepath)
        // stat 先行：目录列举与 stat 之间消失的文件不得进入发现集合，
        // 否则末段永远不会把它对账为 missing（ghost photo）。
        let source: IndexerService.FileStat
        do {
            source = try deps.stat(filepath)
        } catch {
            return IndexScanCandidate(filepath: filepath, action: .missing)
        }
        guard let photo = existingByPath[normalized] else {
            return IndexScanCandidate(filepath: filepath, action: .new)
        }
        // asset_files 基线按 photo.assetFileId 查表（键为 asset_files.id）；
        // 无基线行时取 nil，退回照片自身索引 stat 作基线（旧实现同语义）。
        let indexed = photo.assetFileId.flatMap { baselinesByAssetFileId[$0] }
        // 仅当基线证明文件确实变化才算 content-changed：有 asset_files 基线
        // 比 size/mtime，无基线走照片自身 checksum stat。
        let contentChanged = IndexAssembler.contentChanged(
            indexedFileSize: indexed?.fileSize,
            indexedFileMtimeMs: indexed?.mtimeMs,
            photoChecksumFileSize: photo.checksumFileSize,
            photoChecksumFileMtimeMs: photo.checksumFileMtimeMs,
            sourceSize: source.size,
            sourceMtimeMs: source.mtimeMs
        )
        // 旧实现的短路：有 asset_files 基线且 checksum 非空 → unchanged
        // （checksum 为空串/NULL 时仍需重算，不短路）。
        if !contentChanged && photo.status != "missing" && !(indexed?.checksum?.isEmpty ?? true) {
            return IndexScanCandidate(filepath: filepath, action: .unchanged)
        }
        return IndexScanCandidate(filepath: filepath, action: .changed)
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

/// lstat 缓冲（文件级辅助：规避名为 stat 的成员对 POSIX stat 的遮蔽，
/// 形态与旧 IndexerService.lstatBuf 一致）。
private func runtimeLstatBuf() -> stat {
    stat()
}
