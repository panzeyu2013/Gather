// API/SimilarityCommands.swift
// R5 类型化 async 域协议：similarity 域。
// 旧实现来源：gather-app 的会话命令分发器 sim.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// similarity 域命令（10 条）。
///
/// 旧命令清单：`sim.analyze`、`sim.cancel_analysis`、`sim.recluster`、
/// `sim.result`、`sim.preview_writeback`、`sim.writeback`、
/// `sim.writeback_items`、`sim.retry_failed_writeback`、`sim.confirm_sync`、
/// `sim.cleanup`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧路由把 threshold 收窄为整数；Protocol/Similarity.swift 的 DTO 为 Double?，
///   取整与阈值校验口径由实现统一。
/// - 旧 `sim.analyze` 等待作业完成后响应恒为 true，本协议返回空；
///   `sim.preview_writeback` 的预览形状对齐 Protocol/Core.swift 的 WritebackPreview。
public protocol SimilarityCommands: Sendable {
    /// 旧命令：`sim.analyze`。
    /// 建 similarity.analyze 作业并等待完成；threshold / minGroupSize 为 nil 时走默认设置（10 / 2）。
    func analyze(_ params: SimAnalyzeParams) async throws

    /// 旧命令：`sim.cancel_analysis`。
    /// 取消该会话的 similarity.analyze 作业；取消在后台完成，方法只等待提交。
    func cancelAnalysis(_ params: SimCancelAnalysisParams) async throws

    /// 旧命令：`sim.recluster`。
    /// 用给定阈值重聚类并返回结果；threshold / minGroupSize 缺省走设置项。
    func recluster(_ params: SimReclusterParams) async throws -> SimilarityResult

    /// 旧命令：`sim.result`。
    /// 同步查询既有结果；无结果时返回 nil（旧响应 ok(null)）。
    func result(_ params: SimResultParams) async throws -> SimilarityResult?

    /// 旧命令：`sim.preview_writeback`。
    /// 写回预览计划；无可用分析结果时抛错（旧 SIM_ANALYSIS_MISSING / SIM_THRESHOLD_NO_RESULTS）。
    func previewWriteback(_ params: SimPreviewWritebackParams) async throws -> WritebackPreview

    /// 旧命令：`sim.writeback`（破坏性）。
    /// SimWritebackParams.confirmed 必须为 true，且 itemIds 非空并与预览一致
    /// （旧 SIM_PREVIEW_REQUIRED / SIM_PREVIEW_STALE）。
    @discardableResult
    func writeback(_ params: SimWritebackParams) async throws -> WritebackResult

    /// 旧命令：`sim.writeback_items`。
    /// 返回该会话 similarity 模块的全部写回条目（旧 getItems 投影）。
    func writebackItems(_ params: SimWritebackItemsParams) async throws -> [WritebackItem]

    /// 旧命令：`sim.retry_failed_writeback`（破坏性）。
    /// SimRetryFailedWritebackParams.confirmed 必须为 true；返回本次重试结果。
    @discardableResult
    func retryFailedWriteback(_ params: SimRetryFailedWritebackParams) async throws -> WritebackResult

    /// 旧命令：`sim.confirm_sync`。
    /// 确认写回同步；旧响应恒为 true，本协议返回空。
    func confirmSync(_ params: SimConfirmSyncParams) async throws

    /// 旧命令：`sim.cleanup`（破坏性）。
    /// SimCleanupParams.confirmed 必须为 true；返回清理结果。
    @discardableResult
    func cleanup(_ params: SimCleanupParams) async throws -> CleanupResult
}
