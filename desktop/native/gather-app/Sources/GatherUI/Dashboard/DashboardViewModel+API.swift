// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+API.swift
// Cut 4 / 4c-2i：DashboardViewModel 的 API/stub 双路径分区（自 DashboardViewModel.swift
// 原样移出）。行为不变：SessionAPI/JobAPI 与同步 Provider 的择路；跨文件调用点
// 因此由 private 放宽为 internal。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    // MARK: API/stub 双路径（B1）

    func listSessions() async throws -> [SessionData] {
        if let sessionAPI { return try await sessionAPI.list() }
        return try provider.listSessions()
    }

    func workspaceStatus(sessionId: String) async -> WorkspaceStatus? {
        if let sessionAPI {
            do { return try await sessionAPI.status(sessionId) } catch { return nil }
        }
        return try? provider.workspaceStatus(sessionId: sessionId)
    }

    func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] {
        if let jobAPI {
            return try await jobAPI.list(JobListFilter(includeCheckpoint: includeCheckpoint))
        }
        return try provider.listJobs(includeCheckpoint: includeCheckpoint)
    }

    /// R1 P1-3：dedupeKey/checkpoint 规则已上移到协议层工厂
    ///（GatherProtocol/JobInputs.swift 的 `JobCreateParams.metadataScan`）。
    /// 保留同名薄壳只因调用点 `DashboardViewModel+Actions.swift` 本轮不在
    /// 可写白名单；壳内不得再出现任何字面量。
    static func metadataScanRequest(
        sessionId: String,
        requestedPaths: [String]?
    ) -> JobCreateParams {
        JobCreateParams.metadataScan(sessionId: sessionId, requestedPaths: requestedPaths)
    }
}
