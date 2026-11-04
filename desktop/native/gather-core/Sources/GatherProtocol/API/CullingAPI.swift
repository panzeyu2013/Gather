// desktop/native/gather-core/Sources/GatherProtocol/API/CullingAPI.swift
// Cut 1 / 阶段 1A：挑片域协议（24 个方法；P0 / A1 追加 selection，P1-7 追加 updateSelection）。
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
// - 修订冲突（CULLING_REVISION_CONFLICT）、照片归属、历史顺序由 CullingDecisionService 负责，
//   实现只做 GatherError 映射；
// - 写回/清理/最终同步的服务语义保持现状（Cut 2 的 DeliveryCoordinator 再统一）。

import Foundation

public protocol CullingAPI: Sendable {
    func page(_ query: CullingPageQuery) async throws -> CullingPage
    func history(_ query: CullingHistoryQuery) async throws -> [CullingHistoryOperation]
    func applyHistory(_ input: CullingApplyHistoryInput) async throws -> [CullingUpdateResult]
    func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult
    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult]
    /// P1-7：按 scope/filters 重算选择、校验 hash，再按 10k 分块更新。
    func updateSelection(_ input: CullingSelectionUpdateInput) async throws -> CullingSelectionUpdateResult
    func decideGroup(_ input: CullingDecideGroupInput) async throws -> [CullingUpdateResult]
    func groups(_ sessionId: String) async throws -> [CullingGroup]
    func summary(_ sessionId: String) async throws -> CullingSummary
    /// P0 / T0：生成技术质量建议（只写 triage_suggestions，不写决策/XMP）。
    func generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary
    /// P0 / T0：应用建议（只写 culling 决策，source=ai；绝不自动写 XMP）。
    func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult
    /// P1：会话内客户校样评论（photoId → 最近一条评论）。
    func proofComments(sessionId: String) async throws -> [String: String]
    /// P1：当前照片的 crs 裁剪框（只读；无 sidecar/无裁剪 → nil）。
    func adjustmentHint(photoId: String) async throws -> CropFrame?
    /// P1：技术质量建议的阈值校准报告（只读；样本不足时 isApplicable=false）。
    func triageCalibration(_ query: TriageCalibrationQuery) async throws -> TriageCalibrationSnapshot
    /// P1：应用三个置信度阈值（写设置；不动策略版本字符串）。
    func applyTriageCalibration(_ input: Confirmed<TriageCalibrationApplyInput>) async throws -> TriageCalibrationThresholdSnapshot
    /// W1：单张照片的模型级初审信号（未分析 = nil，不是全 0）。
    func modelReview(_ photoId: String) async throws -> ModelReviewResult?
    /// W3：导入客户校样（selection.json）→ 勾选项标记为 keep（source=imported）。
    func importClientSelection(_ input: Confirmed<ClientSelectionImportInput>) async throws -> ClientSelectionImportReport
    /// P1 / D：把已淘汰的照片移到 <sessionRoot>/_rejects（只移动、不删除）。
    /// P0 / A1：混合批次按张过滤（返回 skipped），并按逻辑资产展开到全部变体。
    func moveRejected(_ input: Confirmed<CullingMoveRejectedInput>) async throws -> CullingMoveRejectedResult

    /// P0 / A1：当前 scope/filters 下的完整选中集（代表行）。跨页"全选"与移出用。
    /// 命中 CullingSelectionQuery.maxIds 时截断，truncated = true。
    func selection(_ query: CullingSelectionQuery) async throws -> CullingSelectionIds

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

public extension CullingAPI {
    /// 未接线（Preview/测试替身）：没有客户评论。
    func proofComments(sessionId: String) async throws -> [String: String] {
        _ = sessionId
        return [:]
    }

    /// 未接线（Preview/测试替身）：没有裁剪数据 → nil（不画标记）。
    func adjustmentHint(photoId: String) async throws -> CropFrame? {
        _ = photoId
        return nil
    }

    /// 未接线（Preview/测试替身）：显式失败，不伪造校准结果。
    func triageCalibration(_ query: TriageCalibrationQuery) async throws -> TriageCalibrationSnapshot {
        _ = query
        throw GatherError.invalidParameter(
            field: "triageCalibration", reason: "calibration API not wired")
    }

    func applyTriageCalibration(
        _ input: Confirmed<TriageCalibrationApplyInput>
    ) async throws -> TriageCalibrationThresholdSnapshot {
        _ = input
        throw GatherError.invalidParameter(
            field: "applyTriageCalibration", reason: "calibration API not wired")
    }
}
