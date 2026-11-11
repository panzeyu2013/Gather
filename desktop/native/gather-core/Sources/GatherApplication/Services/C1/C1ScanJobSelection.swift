// desktop/native/gather-core/Sources/GatherApplication/Services/C1/C1ScanJobSelection.swift
// P2（Wave4b / 97 号报告 §4 C1）：metadata.scan「最新 job」的稳定选择。
//
// 背景：AnalysisJobRepo.latestScanJob 只按 updated_at DESC 取一条；批量导入/重试时
// 多个 job 可能落在同一毫秒，SQLite 对并列行的返回顺序由实现决定 → 等待方可能盯错
// job 的终态（A2 之后会表现为"该落库的跳过"或"多等一个扫描"）。
// 本文件在应用层用 (updatedAt, id) 全序重选，保证同一数据快照下结果确定。
import Foundation
import GatherProtocol

/// 本会话 metadata.scan 最新 job 的稳定选择（纯函数，供导入钩子/测试共用）。
public enum C1ScanJobSelection {
    /// 返回本会话最新 metadata.scan 的 status（rawValue）；没有 job 时 nil。
    ///
    /// 排序键：(updatedAt, id) 字典序。ISO8601 带小数秒且定长 → 字典序即时间序；
    /// id 是 uuid 字符串，作为同毫秒并列时的稳定 tie-break（不依赖 rowid 暴露）。
    public static func latestScanStatus(
        jobs: [AnalysisJobData],
        sessionId: String
    ) -> String? {
        var best: AnalysisJobData?
        for job in jobs where job.type == .metadataScan && job.scopeId == sessionId {
            guard let current = best else {
                best = job
                continue
            }
            if (job.updatedAt, job.id) > (current.updatedAt, current.id) {
                best = job
            }
        }
        return best?.status.rawValue
    }
}
