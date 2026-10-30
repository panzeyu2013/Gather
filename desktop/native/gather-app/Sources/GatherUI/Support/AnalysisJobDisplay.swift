// desktop/native/gather-app/Sources/GatherUI/Support/AnalysisJobDisplay.swift
// 摄取任务复用 checksum.backfill 载体（analysis_jobs.type 的 CHECK 不含 ingest.run），
// 展示层统一按 dedupeKey 前缀判定，避免各面板各写一份 checkpoint 判断——
// 也避免 includeCheckpoint=false 的面板（任务中心 2s 轮询）拿到空 checkpoint 后判错。
import GatherProtocol

extension AnalysisJobData {
    /// 是否为「摄取」任务（复用 checksum.backfill 的载体，dedupeKey = ingest.run:<session>:<hash>）。
    var isIngestRun: Bool {
        type == .checksumBackfill && dedupeKey.hasPrefix("ingest.run:")
    }
}
