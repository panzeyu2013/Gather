// desktop/native/gather-core/Sources/GatherDomain/Services/SessionService.swift
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
        // V1（D-033）：role_bindings.cluster_id 与 person_photos.photo_id/session_id 是
        // RESTRICT，必须在删 session/photos 之前显式清掉（上面删簇时已按会话删
        // role_bindings；这里再显式删一次，防止未来出现脱离簇的绑定行让删除整体
        // 失败）。writeback_items 表已随旧同步栈删除，写回行由 deliveries 级联处理。
        _ = try connection.prepare("DELETE FROM role_bindings WHERE session_id = ?").run([.text(sessionId)])
        // 审计 P2：analysis_jobs 无 FK，会话删除后残留僵尸行（状态查询/
        // 任务中心会一直看到幽灵任务）。
        _ = try connection.prepare("DELETE FROM analysis_jobs WHERE scope_type = 'session' AND scope_id = ?")
            .run([.text(sessionId)])
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
        let delivery = try DeliverySummaryQuery(connection: connection)
            .summary(sessionId: row.id)
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

/// TS: commonParentDirectory —— 文件列表的公共父目录；空列表或根目录返回空串。
/// **仅用于给会话取名**：它绝不再被写进 sessions.source_path（那会把一次文件
/// 导入变成对公共父目录的全树扫描）。文件系统根与主目录同样返回空串。
public func commonParentDirectory(filepaths: [String]) -> String {
    if filepaths.isEmpty { return "" }
    let directories = filepaths.map { TSPath.dirname(ScanPath.canonical($0)) }
    var candidate = directories[0]
    if directories.count > 1 {
        // 向上收敛到同时包含 candidate 与 directory 的目录。用 ScanPath.isWithin
        // 的路径分量比较：TSPath.relative 内部会再次 standardizingPath，对存在的
        // 路径解析符号链接，使包含判定在 /private 前缀上不稳定。
        for directory in directories.dropFirst() {
            while candidate != TSPath.dirname(candidate),
                  !ScanPath.isWithin(candidate: directory, root: candidate) {
                candidate = TSPath.dirname(candidate)
            }
        }
    }
    if ScanPath.isForbiddenRoot(candidate) { return "" }
    return candidate
}

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

/// TS: normalizeImportFilepaths —— trim + 去空 + 归一化 + 去重。
/// 归一化走 ScanPath（扫描/监听/导入共用的唯一口径），因此落库的
/// photos.filepath 与索引器构造的路径键逐字相同。
public func normalizeImportFilepaths(_ filepaths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for fp in filepaths {
        // TS String.prototype.trim() 去全部 Unicode 空白；Swift 无等价内置，
        // whitespacesAndNewlines 覆盖 ASCII 空白（含 \n\r\t），其余差异
        // 仅涉 Unicode 空白字符，可接受。
        let trimmed = fp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let normalized = ScanPath.canonical(trimmed)
        if seen.insert(normalized).inserted { result.append(normalized) }
    }
    return result
}

