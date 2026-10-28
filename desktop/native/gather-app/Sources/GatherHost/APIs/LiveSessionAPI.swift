// desktop/native/gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift
// Cut 1 / 阶段 B1：SessionAPI 的 Live 实现（7 个方法）。
//
// 对应命令（9 条）：session.list / get / create / create_from_directory（M1 合并）/
// update / delete / delete_many（M2 合并）/ add_photos、workspace.status。
//
// 校验归属：
// - 输入类型已完成 name/sessionId/filepaths 的形状校验（D-012：显式
//   GatherError.invalidParameter，不静默）；
// - update 复用的旧 SessionUpdateParams 没有校验，本实现补 sessionId/name 非空白；
// - delete 只接收 Confirmed<SessionDeleteInput>，内部 confirmed 固定 true
//   （类型已保证，D-011；API 实现不得自行“补”确认）；
// - 目录准入复用 SessionService.createFromDirectory（真实目录 + 禁根 +
//   主目录祖先），文件导入复用 sanitizeSessionSourcePath（≥2 张照片的公共父目录），
//   两者都不在本文件重复实现路径规则；
// - 错误映射：SessionServiceError -> 已有域错误码；其余错误原样抛出（GatherError
//   目前没有 unspecified 码，B0/D-010 后续补）。
//
// WP4b：同步核心（listSync/createSync/…）已删除；协议方法直接实现同一套
// 服务调用，同步端口/SyncAPIPortBridge 不再存在。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveSessionAPI: SessionAPI, @unchecked Sendable {
    private let sessionService: SessionService
    private let workspaceStatusService: WorkspaceStatusService
    private let jobService: JobService

    /// @unchecked Sendable 依据：三个依赖都是构造后不再变更的 let；SessionService /
    /// WorkspaceStatusService / JobService 的可变状态分别由 DBConnection 的递归锁与
    /// 各服务自己的锁保护（与组合根 @unchecked Sendable 同一约定）。
    public init(
        sessionService: SessionService,
        workspaceStatusService: WorkspaceStatusService,
        jobService: JobService
    ) {
        self.sessionService = sessionService
        self.workspaceStatusService = workspaceStatusService
        self.jobService = jobService
    }

    // MARK: - P1 / D：摄取

    public func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        let payload = input.value
        let options = IngestOptions(
            destinationRoot: payload.destinationRoot,
            renameTemplate: payload.renameTemplate,
            secondDestinationRoot: payload.secondDestinationRoot,
            verifyChecksum: payload.verifyChecksum
        )
        let service = IngestService()
        return try map {
            // 目标必须落在会话源目录内：摄取写文件系统，不能接受任意磁盘路径。
            guard let session = try sessionService.getSession(payload.sessionId) else {
                throw GatherError(code: .SESSION_NOT_FOUND)
            }
            let base = URL(fileURLWithPath: session.sourcePath)
                .resolvingSymlinksInPath().path
            let destination = URL(fileURLWithPath: payload.destinationRoot)
                .resolvingSymlinksInPath().path
            guard !base.isEmpty, destination == base || destination.hasPrefix(base + "/") else {
                throw GatherError.invalidParameter(
                    field: "destinationRoot", reason: "must be inside the session source path")
            }
            // 第二目的地与主目的地同等边界：绝对路径、非根、不与主目的地相交，
            // 也不得落在会话源树内（否则副本会被下一轮 scan 扫成重复资产）。
            if let second = payload.secondDestinationRoot {
                let secondPath = URL(fileURLWithPath: second)
                    .resolvingSymlinksInPath().path
                let destinationPath = URL(fileURLWithPath: payload.destinationRoot)
                    .resolvingSymlinksInPath().path
                guard secondPath.hasPrefix("/"), secondPath != "/" else {
                    throw GatherError.invalidParameter(
                        field: "secondDestinationRoot",
                        reason: "must be an absolute directory other than /")
                }
                guard secondPath != destinationPath,
                      !secondPath.hasPrefix(destinationPath + "/"),
                      !destinationPath.hasPrefix(secondPath + "/") else {
                    throw GatherError.invalidParameter(
                        field: "secondDestinationRoot",
                        reason: "must not overlap destinationRoot")
                }
                guard secondPath != base, !secondPath.hasPrefix(base + "/") else {
                    throw GatherError.invalidParameter(
                        field: "secondDestinationRoot",
                        reason: "must be outside the session source path")
                }
            }
            var existing: [String: String] = [:]
            do {
                existing = try sessionService.photoChecksums(sessionId: payload.sessionId)
            } catch {
                GatherLogger.log("ingest checksum lookup failed: \(error)", level: .warn)
            }
            let plan = try service.plan(
                sourcePaths: payload.sourcePaths, options: options,
                existingChecksums: existing)
            let result = service.execute(plan, options: options)
            var registered = 0
            var unregistered: [String] = []
            // 登记走既有 add_photos 语义（RAW/JPEG 配对、去重、checksum 回填都复用）。
            if !result.copied.isEmpty {
                do {
                    let addResult = try sessionService.addPhotos(
                        sessionId: payload.sessionId, filepaths: result.copied, source: "ingest"
                    )
                    registered = addResult.added
                    unregistered = addResult.failedFiles
                } catch {
                    // 文件已落盘但登记失败：如实返回"已复制未登记"，让用户/调用方
                    // 可以重试 add_photos，而不是报整批失败把已落盘文件变成幽灵。
                    registered = 0
                    unregistered = result.copied
                    GatherLogger.log("ingest register failed: \(error)", level: .warn)
                }
            }
            return SessionIngestResult(
                registered: registered,
                copiedButUnregistered: unregistered,
                skipped: result.skipped,
                unreadable: result.unreadable,
                failed: result.failed.map { MetadataApplyFailureDTO(photoId: $0.sourcePath, message: $0.message) }
            )
        }
    }

    // MARK: - SessionAPI

    public func list() async throws -> [SessionData] {
        try map { try sessionService.listSessions() }
    }

    public func get(_ sessionId: String) async throws -> SessionData {
        let id = try requireNonBlank(sessionId, field: "sessionId", maxLength: 128)
        guard let session = try map({ try sessionService.getSession(id) }) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        return session
    }

    /// M1：目录 / filepaths / 空会话三路统一返回 SessionCreateResult。
    ///
    /// 目录分支建会话 + metadata.scan（目录全树作用域，checkpoint 不带
    /// requestedPaths，与旧 create_from_directory 及 Dashboard 目录导入一致）；
    /// filepaths 分支建会话 + addPhotos + metadata.scan（显式文件集合作用域）。
    /// 两路都在 job 创建失败时回滚会话行（旧 create_from_directory 的补偿语义）；
    /// 空会话分支只建会话，不入队索引。
    public func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        if !input.filepaths.isEmpty {
            return try createWithFilepaths(input)
        }
        if let sourcePath = input.sourcePath,
           !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let session = try map {
                try sessionService.createFromDirectory(
                    name: input.name,
                    sourcePath: sourcePath,
                    source: input.source,
                    truncatedImport: input.truncatedImport
                )
            }
            // 与 filepaths 分支同一副作用契约：任何调用方（Dashboard/菜单/CLI）
            // 建出的目录会话都必须被索引。requestedPaths 缺省 = 目录全树作用域。
            do {
                // R1 P1-3：index.scan 的 dedupeKey/checkpoint 规则只在协议层
                // 工厂定义，API 不再复刻字面量（行为：目录全树作用域）。
                _ = try jobService.create(
                    JobCreateParams.metadataScan(sessionId: session.id, requestedPaths: nil))
            } catch {
                // 索引 job 入队失败不得留下“永远不会被扫描”的半成品工作区。
                // 补偿删除是刚创建的空会话，非用户确认路径，显式 confirmed。
                try? sessionService.deleteSession(session.id, confirmed: true)
                throw error
            }
            return SessionCreateResult(session: session)
        }
        let session = try map {
            try sessionService.createSession(
                name: input.name,
                source: input.source,
                sourcePath: "",
                truncatedImport: input.truncatedImport
            )
        }
        return SessionCreateResult(session: session)
    }

    public func update(_ input: SessionUpdateParams) async throws -> SessionData {
        let id = try requireNonBlank(input.sessionId, field: "sessionId", maxLength: 128)
        // 旧命令面 的 session.update 对 name 只做 requiredString（无长度上限）；
        // 这里保留“非空白”语义，不额外改长度上限，避免 UI 行为变化。
        let name = try requireNonBlank(input.name, field: "name")
        return try map { try sessionService.updateSession(sessionId: id, name: name) }
    }

    public func delete(_ input: Confirmed<SessionDeleteInput>) async throws {
        let ids = input.value.sessionIds
        try map {
            if ids.count == 1 {
                // 保留旧 session.delete 的 SESSION_NOT_FOUND 语义；单条删除是
                // M2 的语法糖，缺失 id 与批量删除的历史行为不同。
                try sessionService.deleteSession(ids[0], confirmed: true)
            } else {
                _ = try sessionService.deleteSessions(ids, confirmed: true)
            }
        }
    }

    public func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        let result = try map {
            try sessionService.addPhotos(
                sessionId: input.sessionId,
                filepaths: input.filepaths,
                source: input.source
            )
        }
        return AddPhotoResult(
            added: result.added,
            skipped: result.skipped,
            total: result.total,
            failedFiles: result.failedFiles
        )
    }

    public func status(_ sessionId: String) async throws -> WorkspaceStatus {
        let id = try requireNonBlank(sessionId, field: "sessionId", maxLength: 128)
        guard let status = try map({ try workspaceStatusService.getStatus(sessionId: id) }) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        return status
    }

    // MARK: - 内部

    private func createWithFilepaths(_ input: SessionCreateInput) throws -> SessionCreateResult {
        // 与旧命令面 的 session.create 完全同一准入：只有“≥2 张照片的真实公共
        // 父目录”才被接受，否则落空串；文件导入的扫描范围由 job checkpoint 承担。
        let sourcePath = sanitizeSessionSourcePath(
            sourcePath: input.sourcePath ?? "",
            filepaths: input.filepaths
        )
        let session = try map {
            try sessionService.createSession(
                name: input.name,
                source: input.source,
                sourcePath: sourcePath,
                truncatedImport: input.truncatedImport
            )
        }
        // 与旧 UI 导入路径同一口径：job checkpoint 里的 requestedPaths 必须是
        // normalizeImportFilepaths 之后的路径（trim/去重/ScanPath.canonical），
        // 否则索引器按原始字符串匹配不到刚入库的 photos.filepath。
        let normalizedFilepaths = normalizeImportFilepaths(input.filepaths)
        let added = try map {
            try sessionService.addPhotos(
                sessionId: session.id,
                filepaths: normalizedFilepaths,
                source: input.source
            )
        }
        do {
            // R1 P1-3：建任务规则（含 requestedPaths checkpoint）由协议层工厂单源。
            _ = try jobService.create(
                JobCreateParams.metadataScan(
                    sessionId: session.id, requestedPaths: normalizedFilepaths))
        } catch {
            // 对齐旧 session.create_from_directory：索引 job 入队失败不得留下
            // “照片永远不会被扫描”的半成品工作区。补偿删除是刚创建的空会话，
            // 非用户确认路径，显式以 automation 来源构造 Confirmed。
            try? sessionService.deleteSession(session.id, confirmed: true)
            throw error
        }
        let refreshed = try map { try sessionService.getSession(session.id) } ?? session
        return SessionCreateResult(
            session: refreshed,
            added: added.added,
            skipped: added.skipped,
            failedFiles: added.failedFiles
        )
    }

    private func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int = 4096
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return value
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as GatherError {
            throw error
        } catch let error as SessionServiceError {
            throw GatherError(code: error.gatherCode)
        }
    }
}
