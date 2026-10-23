// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+Load.swift
// Cut 4 / 4c-2i：DashboardViewModel 的加载分区（自 DashboardViewModel.swift 原样移出）。
// 行为不变：加载/刷新、相位收敛与 metadata.scan 快照种子。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    // MARK: 加载

    func loadAll() async {
        phase = .loading
        await refreshAll()
    }

    /// 侧栏“最近工作区”：只拉会话列表，不加载 workspace status / jobs。
    ///
    /// 失败时保留上一份列表——侧栏是辅助导航，不能在临时查询失败时闪成空；
    /// 页面级错误仍由工作台的 refreshAll 负责展示。
    func refreshSidebarSessions() async {
        do {
            sessions = try await listSessions()
        } catch {
            // 保留旧列表；不设置 phase / actionError，避免侧栏吞掉页面级错误语义。
        }
    }

    func refreshSessions() async {
        lastSessionsRefreshAt = Date()
        do {
            let sessions = try await listSessions()
            self.sessions = sessions
            // workspace.status：单 session 失败跳过，不影响整体刷新。
            var statuses: [String: WorkspaceStatus] = [:]
            for session in sessions {
                if let status = await workspaceStatus(sessionId: session.id) {
                    statuses[session.id] = status
                }
            }
            self.statuses = statuses
            settlePhase()
        } catch {
            if sessions.isEmpty {
                // 4a-3b-2a：首屏失败只存错误载体，文案在渲染期解析。
                phase = .failed(CommandError(error))
            } else {
                actionError = CommandError(error)
            }
        }
    }

    func refreshJobs() async {
        do {
            // 2s 轮询只用状态/进度（B-4/D-1）。
            let jobs = try await listJobs(includeCheckpoint: false)
            self.jobs = jobs
            self.scanJobs = Self.seedScanJobs(from: jobs)
            self.jobsError = nil
            settlePhase()
        } catch {
            if sessions.isEmpty {
                phase = .failed(CommandError(error))
            } else {
                jobsError = CommandError(error)
            }
        }
    }

    /// 刷新成功只提升 loading → loaded；已失败（首屏错误）不被后续刷新覆盖。
    private func settlePhase() {
        if phase == .loading { phase = .loaded }
    }

    /// TS: Dashboard/index.tsx:96-116 scanJobs 种子逻辑：jobs.list 中
    /// type == 'metadata.scan' 按 scopeId 取 updatedAt 最新者。
    static func seedScanJobs(from jobs: [AnalysisJobData]) -> [String: DashboardScanJob] {
        var latest: [String: (snapshot: DashboardScanJob, updatedAt: String)] = [:]
        for job in jobs where job.type == .metadataScan {
            let snapshot = DashboardScanJob(
                status: job.status.rawValue,
                current: job.progressCurrent,
                total: job.progressTotal
            )
            if let previous = latest[job.scopeId], job.updatedAt <= previous.updatedAt {
                continue
            }
            latest[job.scopeId] = (snapshot, job.updatedAt)
        }
        return latest.mapValues { $0.snapshot }
    }
}
