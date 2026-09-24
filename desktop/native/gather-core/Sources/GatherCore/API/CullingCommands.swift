// API/CullingCommands.swift
// R5 类型化 async 域协议：culling 域。
// 旧实现来源：gather-app 的会话命令分发器 culling.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// culling 域命令（17 条）。
///
/// 旧命令清单：`culling.list_page`、`culling.groups`、`culling.summary`、
/// `culling.history`、`culling.sync_status`、`culling.update`、
/// `culling.batch_update`、`culling.decide_group`、`culling.apply_history`、
/// `culling.writeback`、`culling.retry_failed_writeback`、`culling.flush`、
/// `culling.retry_sync`、`culling.finalize_sync`、`culling.confirm_sync`、
/// `culling.cleanup`、`culling.reset`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `culling.list_page` 的组过滤入参在 DTO 中名为 groupId、实现面名为
///   requestedGroupId，两套口径由实现对齐；afterRowId 为正整数 keyset 游标，
///   limit 缺省 200、上限 2000，DTO 不承载钳制，由实现保留。
/// - 旧 `culling.history` 的 limit 缺省 100、上限 500；DTO 为 Int?，
///   缺省与钳制由实现保留。
/// - 旧 `culling.update` / `culling.batch_update` / `culling.decide_group` /
///   `culling.apply_history` 的 expectedRevision 非负、批量上限 10000、
///   patch / entries 非空等门控不在 DTO 中，由实现保留。
/// - 旧 `culling.confirm_sync` 的响应恒为 true，本协议返回空。
public protocol CullingCommands: Sendable {
    /// 旧命令：`culling.list_page`。
    /// 资产分组 keyset 分页；scope 白名单校验，filters 为可选过滤面；
    /// 返回 Protocol/Culling.swift 的 CullingPage（nextRowId 为末页 nil）。
    func listPage(_ params: CullingListPageParams) async throws -> CullingPage

    /// 旧命令：`culling.groups`。
    /// 相似度分组（决策计数 + 成员轻投影），元素为 Protocol/Culling.swift 的 CullingGroup。
    func groups(_ params: CullingGroupsParams) async throws -> [CullingGroup]

    /// 旧命令：`culling.summary`。
    /// 徽标计数（决策 + 缓存兜底 + 相似度组数），返回 CullingSummary。
    func summary(_ params: CullingSummaryParams) async throws -> CullingSummary

    /// 旧命令：`culling.history`。
    /// 历史栈操作列表，元素为 CullingHistoryOperation；limit 为 nil 时取 100。
    func history(_ params: CullingHistoryParams) async throws -> [CullingHistoryOperation]

    /// 旧命令：`culling.sync_status`。
    /// 元数据同步摘要（pending/writing/written/failed/conflict/synced + items）。
    func syncStatus(_ params: CullingSyncStatusParams) async throws -> MetadataSyncSummary

    /// 旧命令：`culling.update`。
    /// 单张照片决策更新；expectedRevision 做 CAS，成功返回受影响资产的新状态。
    func update(_ params: CullingUpdateParams) async throws -> CullingUpdateResult

    /// 旧命令：`culling.batch_update`。
    /// 批量更新（单事务 CAS），返回每条操作的结果（历史操作 id 共享）。
    func batchUpdate(_ params: CullingBatchUpdateParams) async throws -> [CullingUpdateResult]

    /// 旧命令：`culling.decide_group`。
    /// 整组 keep/reject（K 保留 + 其余拒绝）；groupId 为 "resultId:index" 精确匹配。
    func decideGroup(_ params: CullingDecideGroupParams) async throws -> [CullingUpdateResult]

    /// 旧命令：`culling.apply_history`。
    /// 应用显式条目或历史栈操作（undo/redo）；返回每条目的更新结果。
    func applyHistory(_ params: CullingHistoryApplyParams) async throws -> [CullingUpdateResult]

    /// 旧命令：`culling.writeback`（破坏性）。
    /// CullingWritebackParams.confirmed 必须为 true（旧 WRITEBACK_CONFIRM_REQUIRED）；
    /// target 仅 rating / color_label / keyword；返回 Protocol/Core.swift 的 WritebackResult。
    @discardableResult
    func writeback(_ params: CullingWritebackParams) async throws -> WritebackResult

    /// 旧命令：`culling.retry_failed_writeback`（破坏性）。
    /// CullingRetryWritebackParams.confirmed 必须为 true（旧 WRITEBACK_RETRY_CONFIRM_REQUIRED）；
    /// 返回本次重试的写回结果。
    @discardableResult
    func retryFailedWriteback(_ params: CullingRetryWritebackParams) async throws -> WritebackResult

    /// 旧命令：`culling.flush`。
    /// 取消计时器后并行冲刷 pending/writing/failed 行，返回同步摘要。
    func flush(_ params: CullingFlushParams) async throws -> MetadataSyncSummary

    /// 旧命令：`culling.retry_sync`。
    /// failed 行重置后整体冲刷，返回同步摘要。
    func retrySync(_ params: CullingRetrySyncParams) async throws -> MetadataSyncSummary

    /// 旧命令：`culling.finalize_sync`（破坏性）。
    /// CullingFinalizeSyncParams.confirmed 必须为 true（旧 CULLING_FINALIZE_CONFIRM_REQUIRED）；
    /// 返回终局同步摘要。
    func finalizeSync(_ params: CullingFinalizeSyncParams) async throws -> MetadataSyncSummary

    /// 旧命令：`culling.confirm_sync`。
    /// 协调器确认 + 写回项存在时的写回确认；旧响应恒为 true，本协议返回空。
    func confirmSync(_ params: CullingConfirmSyncParams) async throws

    /// 旧命令：`culling.cleanup`（破坏性）。
    /// CullingCleanupParams.confirmed 必须为 true（旧 WRITEBACK_CLEANUP_CONFIRM_REQUIRED）；
    /// 返回协调器与写回清理的并集（Protocol/Core.swift 的 CleanupResult）。
    @discardableResult
    func cleanup(_ params: CullingCleanupParams) async throws -> CleanupResult

    /// 旧命令：`culling.reset`（破坏性）。
    /// CullingResetParams.confirmed 必须为 true（旧 CULLING_RESET_CONFIRM_REQUIRED）；
    /// groupId 为 nil 清整会话决策，否则只清该组。
    func reset(_ params: CullingResetParams) async throws
}
