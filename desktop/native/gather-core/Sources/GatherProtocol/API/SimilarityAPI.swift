// desktop/native/gather-core/Sources/GatherProtocol/API/SimilarityAPI.swift
// Cut 1 / 阶段 1A：相似度域协议（10 个方法）。
//
// 职责：相似度结果读取、分析/重聚类/取消、关键字预览与写回、同步确认、清理。
// 对应命令（10 条）：sim.result / analyze / recluster / cancel_analysis /
// preview_writeback / writeback_items / writeback / confirm_sync /
// retry_failed_writeback / cleanup。
// 校验归属：
// - threshold 0...64、minGroupSize >= 2、assignments 归一化在输入类型；
// - writeback/retryFailedWriteback/cleanup 使用 Confirmed<T>；
// - “是否有结果/预览是否过期/待写项是否匹配”（SIM_THRESHOLD_NO_RESULTS /
//   SIM_PREVIEW_STALE）属于交付状态校验，留在 1B 实现；
// - analyze 暂保留 Bool 返回（与旧命令一致），recluster 返回 SimilarityResult?；
//   O5 的返回统一留到 Cut 1 后续评估，避免同时改语义。
// 输出类型：SimilarityResult / WritebackItem / WritebackPreview / WritebackResult /
// CleanupResult（后四者复用 Protocol/Core.swift）。

import Foundation

public protocol SimilarityAPI: Sendable {
    func result(_ query: SimilarityResultQuery) async throws -> SimilarityResult?
    func analyze(_ input: SimilarityAnalyzeInput) async throws -> Bool
    func recluster(_ input: SimilarityAnalyzeInput) async throws -> SimilarityResult?
    func cancelAnalysis(_ sessionId: String) async throws -> Bool
    func previewWriteback(_ input: SimilarityPreviewWritebackInput) async throws -> WritebackPreview
    func writebackItems(_ sessionId: String) async throws -> [WritebackItem]
    func writeback(_ input: Confirmed<SimilarityWritebackInput>) async throws -> WritebackResult
    func confirmSync(_ sessionId: String) async throws -> Bool
    func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult
    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult
}
