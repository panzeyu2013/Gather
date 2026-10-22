// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+Polling.swift
// Cut 4 / 4c-2i：DashboardViewModel 的轮询分区（自 DashboardViewModel.swift 原样移出）。
// 行为不变：活跃 2s/常驻 30s 自动刷新 Task 仍由 VM 持有；jobs:progress 逐帧合并。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    // MARK: 轮询（TS: Jobs 页 2s 活跃轮询 + useWorkspaceStatus 30s 兜底）

    package func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        guard isVisible else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.autoRefreshTick()
            }
        }
    }

    package func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func autoRefreshTick() async {
        // 有 queued/running 任务时增量刷新：jobs 每 2s 单查询（进度跟手），
        // sessions + N×workspace.status 降到 15s 档；无活跃任务 30s 全量兜底。
        let active = jobs.contains { $0.status == .queued || $0.status == .running }
        if active {
            await refreshJobs()
            let due = Date().timeIntervalSince(lastSessionsRefreshAt) >= 15
            if due {
                await refreshSessions()
            }
            return
        }
        let due = Date().timeIntervalSince(lastFullRefreshAt) >= 30
        guard due else { return }
        lastFullRefreshAt = Date()
        await refreshAll()
    }

    /// TS jobs:progress 事件订阅（Dashboard/index.tsx useEvent('jobs:progress')）：
    /// 逐帧更新任务中心行（jobs 快照）与 metadata.scan 卡片快照（「正在索引
    /// N…」毫秒级实时，替代仅 jobTerminal 的滞后刷新）；终态帧再整页刷新，
    /// 让索引写回的权威计数立即落定（对齐 TS 终态 invalidate sessions）。
    func applyJobEvent(_ event: GatherJobEvent) {
        let job = event.job
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        }
        guard job.type == .metadataScan else { return }
        let snapshot = DashboardScanJob(
            status: job.status.rawValue,
            current: job.progressCurrent,
            total: job.progressTotal
        )
        if event.isTerminal {
            switch job.status {
            case .failed, .succeeded:
                // 保留终态快照：failed → 卡片「索引失败 + 重试」；succeeded →
                // 截断导入的 ≥ 前缀去除（TS jobs:progress 终态分支）。
                scanJobs[job.scopeId] = snapshot
            case .queued, .running, .cancelling, .cancelled, .interrupted:
                scanJobs[job.scopeId] = nil
            }
            lastFullRefreshAt = Date()
            Task { await refreshAll() }
        } else {
            scanJobs[job.scopeId] = snapshot
        }
    }

    func refreshAll() async {
        await refreshSessions()
        await refreshJobs()
    }
}
