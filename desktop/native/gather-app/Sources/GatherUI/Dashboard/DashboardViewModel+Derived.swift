// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+Derived.swift
// Cut 4 / 4c-2i：DashboardViewModel 的派生展示分区（自 DashboardViewModel.swift 原样移出）。
// 行为不变：卡片计数文案/概览聚合/任务分组/进度百分比。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    // MARK: 派生展示

    /// TS: Dashboard/index.tsx photoCountLabel（344-359 行）。
    /// 4b-2e：返回模板 + 参数，由卡片在渲染期按当前语言解析（VM 不读全局语言）。
    func photoCountLabel(for session: SessionData) -> LocalizedText {
        let job = scanJobs[session.id]
        switch deriveCardIndexKind(job) {
        case .failed:
            return LocalizedText("索引失败")
        case .active:
            if let job, job.current > 0 {
                return LocalizedText("正在索引 %lld…", params: ["\(job.current)"])
            }
            return LocalizedText("扫描中…")
        case .count:
            if session.truncatedImport && job?.status != "succeeded" {
                return LocalizedText("≥%lld 张照片", params: ["\(session.photoCount)"])
            }
            return LocalizedText.plural("%lld 张照片", count: session.photoCount)
        }
    }

    /// 工作区概览聚合。
    func summary() -> DashboardSummary {
        DashboardSummary(
            sessionCount: sessions.count,
            photoCount: sessions.reduce(0) { $0 + $1.photoCount },
            pendingXmp: statuses.values.reduce(0) { $0 + $1.xmp.pending },
            conflictXmp: statuses.values.reduce(0) { $0 + $1.xmp.conflict },
            offlinePhotos: statuses.values.reduce(0) { $0 + $1.offlinePhotos }
        )
    }

    /// 进行中与需要处理（TS Jobs 页 attentionJobs：status != succeeded）。
    var attentionJobs: [AnalysisJobData] {
        jobs.filter { $0.status != .succeeded }
    }

    /// 已完成历史（TS Jobs 页 historyJobs）。
    var historyJobs: [AnalysisJobData] {
        jobs.filter { $0.status == .succeeded }
    }

    /// 清理按钮的可见性 = 真的会被清掉的行：仅成功终态且非阶段证据类型。
    /// 失败/中断/取消行保留错误原因（显式点名 statuses 才允许删除），
    /// 因此不能作为「有可清理内容」的依据，否则按钮会静默无事发生。
    var hasClearableJobs: Bool {
        jobs.contains { job in
            job.status == .succeeded
                && job.type != .metadataScan && job.type != .exportExecute
        }
    }

    /// TS Jobs 页进度百分比（progressTotal > 0 时 Math.round）。
    static func progressPercent(of job: AnalysisJobData) -> Int {
        job.progressTotal > 0
            ? Int((Double(job.progressCurrent) / Double(job.progressTotal) * 100).rounded())
            : 0
    }
}
