// API/Impl/SessionCommandsImpl.swift
// R5 命令层接线：session 域实现（W5-2 首个落地域）。
// 逻辑来源：gather-app 的宿主「路由层」session.* 分支（session.create /
// create_from_directory / list / get / update / add_photos / delete /
// delete_many）；错误码与响应 JSON 形状与旧分支一致。
// 本文件只新增实现类型：不改 app 路由，切换留待 W5-4 逐域剪除时进行。
// 实现方式：包装 SessionRuntime（R4 归位；删除路径 SQL 已下沉 Store），仅补旧
// 分支在命令边界承载的两段编排：create 的 filepaths 导入后回读、
// create_from_directory 的 metadata.scan 入队与失败回滚。
import Foundation

/// session 域命令实现：注入会话服务与作业运行器。
///
/// 采用 actor 以串行化命令入口：协议要求 Sendable，而 SessionRuntime 为普通
/// final class，actor 隔离是无需不安全标注即可达标的实现形态。
public actor SessionCommandsImpl: SessionCommands {
    private let runtime: SessionRuntime
    private let jobs: JobRunner

    public init(runtime: SessionRuntime, jobs: JobRunner) {
        self.runtime = runtime
        self.jobs = jobs
    }

    // MARK: SessionCommands

    /// 旧命令：`session.create`。source 缺省 "manual"（非 "folder"）；
    /// filepaths 非空时创建即导入并回读会话（status/photoCount 已更新）。
    /// 旧响应在 filepaths 非空时为复合体，协议层已收敛为 SessionData。
    public func create(_ params: SessionCreateParams) async throws -> SessionData {
        let source = params.source ?? "manual"
        var session = try await runtime.createSession(
            name: params.name,
            source: source,
            sourcePath: params.sourcePath ?? "",
            truncatedImport: params.truncatedImport ?? false
        )
        if let filepaths = params.filepaths, !filepaths.isEmpty {
            _ = try await runtime.addPhotos(
                sessionId: session.id, filepaths: filepaths, source: source)
            session = try await runtime.getSession(session.id) ?? session
        }
        return session
    }

    /// 旧命令：`session.create_from_directory`。建会话后入队 metadata.scan；
    /// 入队失败回滚会话行，工作区列表不出现半成品会话。旧分支把回滚排在后台
    /// 任务并立即抛错；此处等待回滚完成再抛原始错误——错误码不变，回滚确定性
    /// 更强（可直接测试）。
    public func createFromDirectory(_ params: SessionCreateFromDirectoryParams) async throws -> SessionData {
        let session = try await runtime.createFromDirectory(
            name: params.name ?? "", sourcePath: params.sourcePath)
        do {
            _ = try await jobs.create(JobCreateParams(
                type: .metadataScan,
                scopeType: "session",
                scopeId: session.id,
                dedupeKey: "metadata.scan:\(session.id)"
            ))
        } catch {
            try? await runtime.deleteSession(session.id, confirmed: true)
            throw error
        }
        return session
    }

    /// 旧命令：`session.list`。
    public func list() async throws -> [SessionData] {
        try await runtime.listSessions()
    }

    /// 旧命令：`session.get`。会话不存在 → SESSION_NOT_FOUND。
    public func get(_ params: SessionGetParams) async throws -> SessionData {
        guard let session = try await runtime.getSession(params.sessionId) else {
            throw SessionServiceError.sessionNotFound
        }
        return session
    }

    /// 旧命令：`session.update`。
    public func update(_ params: SessionUpdateParams) async throws -> SessionData {
        try await runtime.updateSession(sessionId: params.sessionId, name: params.name)
    }

    /// 旧命令：`session.add_photos`。source 为 nil 时按旧行为取 "import"。
    public func addPhotos(_ params: SessionAddPhotosParams) async throws -> AddPhotoResult {
        let result = try await runtime.addPhotos(
            sessionId: params.sessionId,
            filepaths: params.filepaths,
            source: params.source ?? "import"
        )
        return AddPhotoResult(
            added: result.added,
            skipped: result.skipped,
            total: result.total,
            failedFiles: result.failedFiles
        )
    }

    /// 旧命令：`session.delete`（破坏性）。确认门控在服务层
    /// （SESSION_DELETE_NOT_CONFIRMED）。
    public func delete(_ params: SessionDeleteParams) async throws {
        try await runtime.deleteSession(params.sessionId, confirmed: params.confirmed)
    }

    /// 旧命令：`session.delete_many`（破坏性）。旧响应为 null，协议层收敛为
    /// 删除条数；服务层计数语义与 TS 一致（逐 id 删除后返回入参条数）。
    @discardableResult
    public func deleteMany(_ params: SessionDeleteManyParams) async throws -> Int {
        try await runtime.deleteSessions(params.sessionIds, confirmed: params.confirmed)
    }
}
