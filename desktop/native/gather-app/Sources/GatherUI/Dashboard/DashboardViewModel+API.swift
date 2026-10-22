// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+API.swift
// Cut 4 / 4c-2i：DashboardViewModel 的 API 分区（自 DashboardViewModel.swift 原样移出）。
// WP4b：删掉 SessionAPI/JobAPI 与同步 Provider 的双路径择路；VM 只依赖 async
// DashboardDataProvider 端口（生产实现在 GatherHost）。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    // MARK: 数据读取（唯一 async 端口）

    func listSessions() async throws -> [SessionData] {
        try await provider.listSessions()
    }

    func workspaceStatus(sessionId: String) async -> WorkspaceStatus? {
        try? await provider.workspaceStatus(sessionId: sessionId)
    }

    func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] {
        try await provider.listJobs(includeCheckpoint: includeCheckpoint)
    }
}
