// desktop/native/gather-core/Sources/GatherProtocol/API/CullingAPI.swift
// Cut 1 / 阶段 1A：挑片域协议（17 个方法）。
//
// 职责：挑片分页/历史栈/单张与批量决策/分组/摘要/同步状态/写回与清理。
// 对应命令（19 条）：culling.list_page / history / apply_history / update /
// batch_update / decide_group / sync_status / groups / summary / reset / writeback /
// flush / retry_sync / retry_failed_writeback / cleanup / finalize_sync / confirm_sync；
// culling.decide / batch_decide 已按 R2/R3 删除（行为由 update/batchUpdate 覆盖）。
// 校验归属：
// - scope/枚举、limit/afterRowId、entries 数量与 patch 范围在输入类型（§6.2）；
// - 破坏性入口 reset/writeback/retryFailedWriteback/cleanup/finalizeSync 使用
//   Confirmed<T>；实现不得自行补确认；
// - 修订冲突（CULLING_REVISION_CONFLICT）、照片归属、历史顺序由 CullingService 负责，
//   实现只做 GatherError 映射；
// - 写回/清理/最终同步的服务语义保持现状（Cut 2 的 DeliveryCoordinator 再统一）。

import Foundation

public protocol CullingAPI: Sendable {
    func page(_ query: CullingPageQuery) async throws -> CullingPage
    func history(_ query: CullingHistoryQuery) async throws -> [CullingHistoryOperation]
    func applyHistory(_ input: CullingApplyHistoryInput) async throws -> [CullingUpdateResult]
    func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult
    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult]
    func decideGroup(_ input: CullingDecideGroupInput) async throws -> [CullingUpdateResult]
    func groups(_ sessionId: String) async throws -> [CullingGroup]
    func summary(_ sessionId: String) async throws -> CullingSummary
    func syncStatus(_ sessionId: String) async throws -> CullingSyncStatus
    func reset(_ input: Confirmed<CullingResetInput>) async throws -> Bool
    func writeback(_ input: Confirmed<CullingWritebackInput>) async throws -> WritebackResult
    func flush(_ sessionId: String) async throws -> MetadataSyncSummary
    func retrySync(_ sessionId: String) async throws -> MetadataSyncSummary
    func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult
    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult
    func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataSyncSummary
    func confirmSync(_ sessionId: String) async throws -> Bool
}
