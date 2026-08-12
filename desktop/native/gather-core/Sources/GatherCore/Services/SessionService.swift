// desktop/native/gather-core/Sources/GatherCore/Services/SessionService.swift
// TS 源: desktop/src/main/services/session/session.service.ts（Phase 3.2 移植）
// 会话服务：创建/列表/查询/删除/加照片。图片尺寸读取通过注入的
// dimensionsProvider 接入原生 RAWDecoder，
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

public final class SessionService {
    /// TS: SettingsService.getNumber 注入（import_concurrency 用）。
    private let getNumber: (String, Double) -> Double
    /// TS: ImageService.getDimensions(filepath) → { width, height }，失败抛错。
    private let dimensionsProvider: (String) throws -> (width: Int, height: Int)

    private let sessionRepo: SessionRepo
    private let photoRepo: PhotoRepo
    private let faceRepo: FaceRepo
    private let assetRepo: AssetRepo?
    private let connection: DBConnection

    public init(
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        faceRepo: FaceRepo,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        dimensionsProvider: @escaping (String) throws -> (width: Int, height: Int) = { _ in
            throw SessionServiceError.sourceNotDir
        },
        assetRepo: AssetRepo? = nil
    ) {
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.faceRepo = faceRepo
        self.connection = connection
        self.getNumber = getNumber
        self.dimensionsProvider = dimensionsProvider
        self.assetRepo = assetRepo
    }

    public func createSession(name: String, source: String, sourcePath: String = "", truncatedImport: Bool = false) throws -> SessionData {
        let row = try sessionRepo.create(name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
        return try toSessionData(row)
    }

    /// 一跳本地目录导入：校验真实非根目录并建 session 行（source_path + 'local'）。
    /// 照片不在此插入——调用方入队 metadata.scan 索引 job，进程内流式遍历填充。
    public func createFromDirectory(name: String, sourcePath: String, truncatedImport: Bool = false) throws -> SessionData {
        try requireDirectory(sourcePath)
        let resolved = TSPath.resolve(sourcePath)
        if resolved == "/" {
            throw SessionServiceError.sourceRootForbidden
        }
        // TS: (name ?? '').trim() —— 空白含换行等，用 whitespacesAndNewlines 对齐。
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmedName.isEmpty ? TSPath.basename(resolved) : trimmedName
        return try createSession(name: sessionName, source: "local", sourcePath: resolved, truncatedImport: truncatedImport)
    }

    public func listSessions() throws -> [SessionData] {
        try sessionRepo.list().map { try toSessionData($0) }
    }

    public func getSession(_ sessionId: String) throws -> SessionData? {
        guard var row = try sessionRepo.get(id: sessionId) else { return nil }
        if row.sourcePath.isEmpty {
            let photos = try photoRepo.getBySession(sessionId: sessionId)
            // 单张照片推父目录会让索引器递归监控整个文件夹；多目录选择时
            // commonParentDirectory 同样拒绝文件系统根——绝不拿第一张照片的
            // 目录充数，否则会导入用户未选择的文件。
            if photos.count > 1 {
                let sourcePath = commonParentDirectory(filepaths: photos.map(\.filepath))
                if !sourcePath.isEmpty {
                    _ = try sessionRepo.updateSourcePath(id: sessionId, sourcePath: sourcePath)
                    // 与 TS 差异（有意）：TS 改内存行返回旧 updatedAt；这里重取
                    // 返回持久化后的新 updatedAt，DB 结果一致。
                    guard let updated = try sessionRepo.get(id: sessionId) else { return nil }
                    row = updated
                }
            }
        }
        return try toSessionData(row)
    }

    public func deleteSession(_ sessionId: String, confirmed: Bool) throws {
        if !confirmed { throw SessionServiceError.deleteNotConfirmed }
        try connection.transaction {
            try deleteSessionDependencies(sessionId)
            let deleted = try sessionRepo.delete(id: sessionId)
            if !deleted { throw SessionServiceError.sessionNotFound }
            _ = try connection.prepare("""
                UPDATE assets SET status = 'orphan', updated_at = ?
                WHERE status != 'orphan'
                  AND NOT EXISTS (
                    SELECT 1 FROM session_assets sa WHERE sa.asset_id = assets.id
                  )
              """).run([.text(nowISOString())])
        }
    }

    public func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws -> Int {
        if !confirmed { throw SessionServiceError.deleteNotConfirmed }
        return try connection.transaction {
            for id in sessionIds {
                try deleteSessionDependencies(id)
            }
            _ = try sessionRepo.deleteMany(ids: sessionIds)
            _ = try connection.prepare("""
                UPDATE assets SET status = 'orphan', updated_at = ?
                WHERE status != 'orphan'
                  AND NOT EXISTS (
                    SELECT 1 FROM session_assets sa WHERE sa.asset_id = assets.id
                  )
              """).run([.text(nowISOString())])
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
        _ = try connection.prepare("DELETE FROM person_embeddings WHERE session_id = ?").run([.text(sessionId)])
        _ = try connection.prepare("DELETE FROM person_photos WHERE session_id = ?").run([.text(sessionId)])
        _ = try connection.prepare("DELETE FROM photo_metadata_cache WHERE session_id = ?").run([.text(sessionId)])
        _ = try connection.prepare("DELETE FROM writeback_items WHERE session_id = ?").run([.text(sessionId)])
        // 审计 P2：analysis_jobs 无 FK，会话删除后残留僵尸行（状态查询/
        // 任务中心会一直看到幽灵任务）。
        _ = try connection.prepare("DELETE FROM analysis_jobs WHERE scope_type = 'session' AND scope_id = ?")
            .run([.text(sessionId)])
        try photoRepo.deleteBySession(sessionId: sessionId)
    }

    /// 批量加照片：分批读尺寸（import_concurrency，钳制 1..32），
    /// 落库 + 资产回填 + 照片计数 + index_seq 递增（新照片使旧分析失效）。
    public func addPhotos(sessionId: String, filepaths: [String], source: String) throws -> SessionAddPhotoResult {
        let session = try sessionRepo.get(id: sessionId)
        if session == nil { throw SessionServiceError.sessionNotFound }
        let normalized = normalizeImportFilepaths(filepaths)
        if session!.sourcePath.isEmpty && normalized.count >= 2 {
            let sourcePath = commonParentDirectory(filepaths: normalized)
            if !sourcePath.isEmpty {
                _ = try sessionRepo.updateSourcePath(id: sessionId, sourcePath: sourcePath)
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

        let result = try photoRepo.addPhotos(sessionId: sessionId, filepaths: entries, source)
        _ = try assetRepo?.backfillSession(sessionId)
        let totalCount = try photoRepo.countBySession(sessionId: sessionId)
        try connection.transaction {
            try sessionRepo.updatePhotoCount(id: sessionId, count: totalCount)
            // 新照片使先前任何分析失效：同一事务内 bump index_seq，
            // 使最近一次 ok run 过期（1.4.2）。
            if result.added > 0 {
                _ = try sessionRepo.bumpIndexSeq(id: sessionId)
            }
        }
        if totalCount > 0 && session!.status == "draft" {
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

    public func updateSession(sessionId: String, name: String) throws -> SessionData {
        let updated = try sessionRepo.updateName(id: sessionId, name: name)
        if !updated { throw SessionServiceError.sessionNotFound }
        guard let row = try sessionRepo.get(id: sessionId) else { throw SessionServiceError.sessionNotFound }
        return try toSessionData(row)
    }

    private func toSessionData(_ row: SessionRow) throws -> SessionData {
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
