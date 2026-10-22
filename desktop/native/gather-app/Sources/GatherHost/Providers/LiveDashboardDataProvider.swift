// desktop/native/gather-app/Sources/GatherHost/Providers/LiveDashboardDataProvider.swift
// WP4b：Dashboard 的 async 数据端口实现在 Host（原 GatherUI/Dashboard/DashboardViewModel.swift）。
//
// 只做「async API → 页面形状」适配：Session 的目录/文件/空会话三路语义、索引
// 入队与回滚都在 LiveSessionAPI 内完成，本类不复制路径规则，也不再有同步核。
import Foundation
import GatherProtocol
import GatherUI

package final class LiveDashboardDataProvider: DashboardDataProvider {
    private let sessionAPI: any SessionAPI
    private let jobAPI: any JobAPI

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let，且各自协议
    /// 已声明 Sendable（Live 实现的底层连接由 DBConnection 串行化）。
    package init(sessionAPI: any SessionAPI, jobAPI: any JobAPI) {
        self.sessionAPI = sessionAPI
        self.jobAPI = jobAPI
    }

    package func listSessions() async throws -> [SessionData] {
        try await sessionAPI.list()
    }

    /// 注意：name 由调用方（DashboardViewModel）用显式 L10n 解析好再传入
    /// （4b-2l 起不在适配层读进程级语言；默认名是落库值，只在创建时解析一次）。
    package func createSession(name: String, source: String, sourcePath: String) async throws -> SessionData {
        let input = try SessionCreateInput(
            name: name,
            source: source,
            sourcePath: sourcePath
        )
        return try await sessionAPI.create(input).session
    }

    /// TS session.create：文件列表建库 + addPhotos（source 透传，C1 为
    /// "capture-one"），返回会话与失败文件计数；照片在创建时写入，
    /// metadata.scan 由 LiveSessionAPI 的 filepaths 分支负责入队。
    package func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String]
    ) async throws -> CreateSessionOutcome {
        let input = try SessionCreateInput(name: name, source: source, filepaths: filepaths)
        let result = try await sessionAPI.create(input)
        return CreateSessionOutcome(
            session: result.session,
            failedFiles: result.failedFiles,
            added: result.added
        )
    }

    package func deleteSession(_ sessionId: String, confirmed: Bool) async throws {
        guard confirmed else { throw GatherError(code: .SESSION_DELETE_NOT_CONFIRMED) }
        let input = try SessionDeleteInput(sessionIds: [sessionId])
        try await sessionAPI.delete(Confirmed(input, source: .userDialog))
    }

    package func deleteSessions(_ sessionIds: [String], confirmed: Bool) async throws {
        guard confirmed else { throw GatherError(code: .SESSION_DELETE_NOT_CONFIRMED) }
        guard !sessionIds.isEmpty else { return }
        let input = try SessionDeleteInput(sessionIds: sessionIds)
        try await sessionAPI.delete(Confirmed(input, source: .userDialog))
    }

    package func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? {
        // 缺失会话返回 nil（Dashboard 的兼容探活路径）；其余错误与原 VM 的
        // catch → nil 行为一致，不把 status 探活失败升级成页面错误。
        do {
            return try await sessionAPI.status(sessionId)
        } catch {
            return nil
        }
    }

    package func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] {
        try await jobAPI.list(JobListFilter(includeCheckpoint: includeCheckpoint))
    }

    package func cancelJob(_ jobId: String) async throws -> Bool {
        try await jobAPI.cancel(jobId)
    }

    package func retryJob(_ jobId: String) async throws -> Bool {
        try await jobAPI.retry(jobId)
    }

    package func clearCompletedJobs() async throws -> Int {
        try await jobAPI.clearCompleted(Confirmed(ClearCompletedInput()))
    }

    package func retryIndexScan(sessionId: String) async throws {
        // R1 P1-3：建任务规则只在协议层工厂定义，适配层不复刻 dedupeKey/checkpoint。
        let handle = try await jobAPI.start(
            JobCreateParams.metadataScan(sessionId: sessionId, requestedPaths: nil))
        handle.drain()
    }
}
