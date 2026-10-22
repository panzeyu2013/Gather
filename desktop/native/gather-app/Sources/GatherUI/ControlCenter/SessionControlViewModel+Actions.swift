// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlViewModel+Actions.swift
// Cut 4 / 4c-2e：控制中心 VM 动作（索引扫描 / 质量分析 / 任务重试 / 建任务），
// 从 SessionControlView.swift 205-316 行原样搬出。方法体逐字未动。

import SwiftUI
import GatherProtocol

extension SessionControlViewModel {
    /// 索引扫描：JobAPI.start 建 metadata.scan job 后立即返回
    /// （建任务规则在 `JobCreateParams.metadataScan` 单源；进度靠任务事件 + 轮询刷新）。
    public func scanIndex() async {
        await startMetadataScanJob(message: LocalizedText("索引扫描已入队"))
    }

    /// 画质分析：QualityAPI.analyze 建 quality.score job 并返回 AnalysisJobData；
    /// 返回值先并入当前列表，随后 load() 轮询任务进度（协议无事件流）。
    public func analyzeQuality() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let job = try await qualityAPI.analyze(
                try QualityAnalyzeInput(sessionId: sessionId)
            )
            upsertJob(job)
            notice = LocalizedText("技术质量分析已入队")
            await load()
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 索引失败重试：重新入队 metadata.scan（对齐 TS retryIndex → indexerApi.scan）。
    public func retryIndex() async {
        await startMetadataScanJob(message: LocalizedText("索引扫描已入队"))
    }

    public func retry(jobId: String) {
        Task {
            do {
                _ = try await jobAPI.retry(jobId)
                self.notice = LocalizedText("已重试任务")
                await self.load()
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }

    public func retry(_ job: AnalysisJobData) {
        guard [.failed, .interrupted, .cancelled].contains(job.status) else { return }
        retry(jobId: job.id)
    }

    /// recommendedNext.retry_jobs 动作：重试全部失败任务（TS 跳转 /jobs；
    /// 原生无任务中心页，等价改为逐个 jobs.retry）。
    public func retryFailedJobs() {
        let failed = workspaceStatus?.failedJobs ?? []
        guard !failed.isEmpty else { return }
        Task {
            var retried = 0
            var firstFailure: CommandError?
            for job in failed {
                do {
                    _ = try await jobAPI.retry(job.id)
                    retried += 1
                } catch {
                    if firstFailure == nil {
                        firstFailure = CommandError(error)
                    }
                }
            }
            if retried > 0 {
                self.notice = LocalizedText("已重试 %lld 个失败任务", params: ["\(retried)"])
                await self.load()
            }
            if retried == 0 {
                self.errorMessage = firstFailure ?? CommandError.localized("重试任务失败")
            }
        }
    }

    /// metadata.scan 的 JobAPI.start 统一入口：建任务后 drain 事件流（本页进度由
    /// 任务列表轮询与全局事件中心承载），避免遗留 AsyncStream 观察者。
    /// R1 P1-3：scope/dedupeKey/checkpoint 全部由协议层工厂构造。
    private func startMetadataScanJob(message: LocalizedText) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let handle = try await jobAPI.start(
                JobCreateParams.metadataScan(sessionId: sessionId, requestedPaths: nil))
            handle.drain()
            notice = message
            await load()
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 把刚建的任务并入当前列表：首帧即可见，随后的轮询以服务端快照为准。
    private func upsertJob(_ job: AnalysisJobData) {
        guard job.scopeId == sessionId else { return }
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
    }
}
