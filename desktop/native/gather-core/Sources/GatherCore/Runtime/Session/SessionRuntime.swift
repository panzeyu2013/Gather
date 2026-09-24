// Runtime/Session/SessionRuntime.swift
// R4：会话编排从 Services/SessionService.swift 归位。TS 源:
// desktop/src/main/services/session/session.service.ts（Phase 3.2 移植）。
// 会话创建/列表/查询/删除/加照片；删除路径的跨域语句已逐字下沉
// Store/SessionDeletionStore.swift，本文件不再持有数据库连接。
// 图片尺寸读取通过注入的 dimensionsProvider 接入原生 RAWDecoder，
// 本文件保持零图片依赖，Linux 可单测。
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum SessionServiceError: Error, Equatable {
    case sourceNotDir
    case sourceRootForbidden
    case deleteNotConfirmed
    case sessionNotFound
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension SessionServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .sourceNotDir: .SESSION_SOURCE_NOT_DIR
        case .sourceRootForbidden: .SESSION_SOURCE_ROOT_FORBIDDEN
        case .deleteNotConfirmed: .SESSION_DELETE_NOT_CONFIRMED
        case .sessionNotFound: .SESSION_NOT_FOUND
        }
    }
}

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

/// 会话编排 Runtime（R4 归位）：依赖全部注入，无自有连接。
public final class SessionRuntime {
    /// TS: SettingsService.getNumber 注入（import_concurrency 用）。
    private let getNumber: (String, Double) -> Double
    /// TS: ImageService.getDimensions(filepath) → { width, height }，失败抛错。
    private let dimensionsProvider: (String) throws -> (width: Int, height: Int)

    private let sessionStore: any SessionStore
    private let photoStore: any PhotoStore
    private let faceStore: any FaceStore
    private let deletionStore: any SessionDeletionStore
    private let assetStore: (any AssetStore)?

    public init(
        sessionStore: any SessionStore,
        photoStore: any PhotoStore,
        faceStore: any FaceStore,
        deletionStore: any SessionDeletionStore,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        dimensionsProvider: @escaping (String) throws -> (width: Int, height: Int) = { _ in
            throw SessionServiceError.sourceNotDir
        },
        assetStore: (any AssetStore)? = nil
    ) {
        self.sessionStore = sessionStore
        self.photoStore = photoStore
        self.faceStore = faceStore
        self.deletionStore = deletionStore
        self.getNumber = getNumber
        self.dimensionsProvider = dimensionsProvider
        self.assetStore = assetStore
    }

    public func createSession(name: String, source: String, sourcePath: String = "", truncatedImport: Bool = false) async throws -> SessionData {
        let row = try await sessionStore.create(name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
        return try toSessionData(row)
    }

    /// 一跳本地目录导入：校验真实非根目录并建 session 行（source_path + 'local'）。
    /// 照片不在此插入——调用方入队 metadata.scan 索引 job，进程内流式遍历填充。
    public func createFromDirectory(name: String, sourcePath: String, truncatedImport: Bool = false) async throws -> SessionData {
        try requireDirectory(sourcePath)
        let resolved = TSPath.resolve(sourcePath)
        if resolved == "/" {
            throw SessionServiceError.sourceRootForbidden
        }
        // TS: (name ?? '').trim() —— 空白含换行等，用 whitespacesAndNewlines 对齐。
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmedName.isEmpty ? TSPath.basename(resolved) : trimmedName
        return try await createSession(name: sessionName, source: "local", sourcePath: resolved, truncatedImport: truncatedImport)
    }

    public func listSessions() async throws -> [SessionData] {
        try await sessionStore.list().map { try toSessionData($0) }
    }

    public func getSession(_ sessionId: String) async throws -> SessionData? {
        guard var row = try await sessionStore.get(id: sessionId) else { return nil }
        if row.sourcePath.isEmpty {
            let photos = try await photoStore.getBySession(sessionId: sessionId)
            // 单张照片推父目录会让索引器递归监控整个文件夹；多目录选择时
            // commonParentDirectory 同样拒绝文件系统根——绝不拿第一张照片的
            // 目录充数，否则会导入用户未选择的文件。
            if photos.count > 1 {
                let sourcePath = commonParentDirectory(filepaths: photos.map(\.filepath))
                if !sourcePath.isEmpty {
                    _ = try await sessionStore.updateSourcePath(id: sessionId, sourcePath: sourcePath)
                    // 与 TS 差异（有意）：TS 改内存行返回旧 updatedAt；这里重取
                    // 返回持久化后的新 updatedAt，DB 结果一致。
                    guard let updated = try await sessionStore.get(id: sessionId) else { return nil }
                    row = updated
                }
            }
        }
        return try toSessionData(row)
    }

    public func deleteSession(_ sessionId: String, confirmed: Bool) async throws {
        if !confirmed { throw SessionServiceError.deleteNotConfirmed }
        // 人脸数据由 Store 连接清理（跨连接不共享事务）；其余依赖行 + 会话行
        // 仍在原连接的删除顺序内完成，删除顺序与 ON DELETE 约束保持一致。
        try await deleteFaceData(sessionId)
        // Store 连接的照片行清理先于旧事务（foreign_keys = ON 下删除顺序要求）。
        try await deleteSessionDependencies(sessionId)
        let deleted = try await sessionStore.delete(id: sessionId)
        if !deleted { throw SessionServiceError.sessionNotFound }
        try await deletionStore.markOrphanAssets(now: nowISOString())
    }

    public func deleteSessions(_ sessionIds: [String], confirmed: Bool) async throws -> Int {
        if !confirmed { throw SessionServiceError.deleteNotConfirmed }
        for id in sessionIds {
            try await deleteFaceData(id)
        }
        for id in sessionIds {
            try await deleteSessionDependencies(id)
        }
        _ = try await sessionStore.deleteMany(ids: sessionIds)
        try await deletionStore.markOrphanAssets(now: nowISOString())
        return sessionIds.count
    }

    /// 按依赖顺序删除所有引用 photos(id)/face_observations(id) 且无
    /// ON DELETE 动作的行；foreign_keys = ON 下必须先于 photoStore.deleteBySession。
    /// face_cluster_members 引用 face_observations，簇必须先于观测删除（Store 连接）。
    private func deleteFaceData(_ sessionId: String) async throws {
        try await faceStore.deleteClustersBySession(sessionId)
        try await faceStore.deleteObservationsBySession(sessionId)
    }

    /// 删除其余依赖行（Store 连接；顺序满足 ON DELETE 约束）。
    private func deleteSessionDependencies(_ sessionId: String) async throws {
        // similarity_hashes 无级联引用 photos。
        try await sessionStore.deleteSimilarityData(sessionId: sessionId)
        try await deletionStore.deleteSessionDependencyRows(sessionId: sessionId)
        try await photoStore.deleteBySession(sessionId: sessionId)
    }

    /// 批量加照片：分批读尺寸（import_concurrency，钳制 1..32），
    /// 落库 + 资产回填 + 照片计数 + index_seq 递增（新照片使旧分析失效）。
    public func addPhotos(sessionId: String, filepaths: [String], source: String) async throws -> SessionAddPhotoResult {
        let session = try await sessionStore.get(id: sessionId)
        if session == nil { throw SessionServiceError.sessionNotFound }
        let normalized = normalizeImportFilepaths(filepaths)
        if session!.sourcePath.isEmpty && normalized.count >= 2 {
            let sourcePath = commonParentDirectory(filepaths: normalized)
            if !sourcePath.isEmpty {
                _ = try await sessionStore.updateSourcePath(id: sessionId, sourcePath: sourcePath)
            }
        }

        var failedFiles: [String] = []
        var entries: [PhotoAddInput] = []

        // TS: Math.floor(import_concurrency) 再钳制 1..32；NaN 时 TS 批大小为 NaN
        // → 循环零次执行。Int(NaN/∞) 会 fatalError 崩溃，必须先过滤再转换。
        let configured = getNumber("import_concurrency", 8)
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

        let result = try await photoStore.addPhotos(sessionId: sessionId, inputs: entries, source: source)
        // asset 回填经 Task 触发（Store 写为 async；照片行已在旧连接落库）。
        if let assetStore {
            Task { _ = try? await assetStore.backfillSession(sessionId) }
        }
        let totalCount = try await photoStore.countBySession(sessionId: sessionId)
        try await sessionStore.updatePhotoCount(id: sessionId, count: totalCount)
        // 新照片使先前任何分析失效：bump index_seq 使最近一次 ok run 过期（1.4.2）。
        if result.added > 0 {
            _ = try await sessionStore.bumpIndexSeq(id: sessionId)
        }
        if totalCount > 0 && session!.status == "draft" {
            try await sessionStore.updateStatus(id: sessionId, status: "photos_loaded")
        }
        // id 是索引器的内部接缝，不外泄到 IPC（shared AddPhotoResult 无此字段）。
        return SessionAddPhotoResult(
            added: result.added,
            skipped: result.skipped,
            total: totalCount,
            failedFiles: failedFiles
        )
    }

    public func updateSession(sessionId: String, name: String) async throws -> SessionData {
        let updated = try await sessionStore.updateName(id: sessionId, name: name)
        if !updated { throw SessionServiceError.sessionNotFound }
        guard let row = try await sessionStore.get(id: sessionId) else { throw SessionServiceError.sessionNotFound }
        return try toSessionData(row)
    }

    private func toSessionData(_ row: SessionRecord) throws -> SessionData {
        guard let status = SessionStatus(rawValue: row.status),
              let analysis = AnalysisStatus(rawValue: row.analysisStatus),
              let writeback = WritebackStatus(rawValue: row.writebackStatus) else {
            throw SessionServiceError.sessionNotFound
        }
        return SessionData(
            id: row.id,
            name: row.name,
            status: status,
            photoCount: row.photoCount,
            analysisStatus: analysis,
            writebackStatus: writeback,
            importSource: row.importSource,
            sourcePath: row.sourcePath,
            failedWritebackCount: row.failedWritebackCount,
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

/// TS: commonParentDirectory —— 文件列表的公共父目录；空列表或根目录返回空串。
/// 文件系统根不是有意义的照片源：把 "/" 落库会让索引器递归监控整个卷。
public func commonParentDirectory(filepaths: [String]) -> String {
    if filepaths.isEmpty { return "" }
    let directories = filepaths.map { TSPath.dirname(TSPath.resolve($0)) }
    var candidate = directories[0]
    if directories.count > 1 {
        for directory in directories.dropFirst() {
            while candidate != TSPath.dirname(candidate) {
                let relative = TSPath.relative(candidate, to: directory)
                if relative.isEmpty || (!relative.hasPrefix("..") && !TSPath.isAbsolute(relative)) {
                    break
                }
                candidate = TSPath.dirname(candidate)
            }
        }
    }
    if candidate == TSPath.root(candidate) { return "" }
    return candidate
}

/// TS: normalizeImportFilepaths —— trim + 去空 + resolve + 去重。
public func normalizeImportFilepaths(_ filepaths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for fp in filepaths {
        // TS String.prototype.trim() 去全部 Unicode 空白；Swift 无等价内置，
        // whitespacesAndNewlines 覆盖 ASCII 空白（含 \n\r\t），其余差异
        // 仅涉 Unicode 空白字符，可接受。
        let trimmed = fp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let resolved = TSPath.resolve(trimmed)
        if seen.insert(resolved).inserted { result.append(resolved) }
    }
    return result
}

/// TS: sanitizeSessionSourcePath —— 除非 sourcePath 是至少两张已导入照片的非根
/// 公共父目录，否则拒绝调用方提供的 sourcePath（防深链单文件或受损渲染层
/// 让索引器递归监控无关目录）。
public func sanitizeSessionSourcePath(sourcePath: String, filepaths: [String]) -> String {
    let resolved = TSPath.resolve(sourcePath)
    if resolved == TSPath.root(resolved) { return "" }
    let normalized = normalizeImportFilepaths(filepaths)
    if normalized.count < 2 { return "" }
    let parent = commonParentDirectory(filepaths: normalized)
    return !parent.isEmpty && resolved == parent ? resolved : ""
}
