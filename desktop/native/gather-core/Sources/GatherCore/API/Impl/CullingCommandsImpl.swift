// API/Impl/CullingCommandsImpl.swift
// R5 命令层接线：culling 域实现（Culling 域 17 条命令）。
// 逻辑来源：宿主路由层 culling.* 分支；错误码字符串/错误类型/返回形状/缺省值/
// 门控一律不变：
// - 读路径：list_page（scope 白名单由 DTO 枚举承载；afterRowId 正整数、limit
//   1...2000 且缺省 200 由实现保留）、groups、summary、history（limit 1...500，
//   缺省 100）、sync_status；
// - 写路径：update（expectedRevision 非负）、batch_update（photoIds 上限 10000）、
//   decide_group（keepPhotoIds 上限 10000）、apply_history（entries 非空且 ≤10000、
//   逐条 expectedRevision 非负、historyOperationId ≥1）；
// - 破坏性命令：writeback / retry_failed_writeback / finalize_sync / cleanup /
//   reset 的 confirmed 门控保留（错误码与旧分支逐字一致）。
// 运行时（Runtime/Culling/）承担决策事务、历史栈、同步与写回编排；本实现只做
// 命令边界参数门控与 DTO→运行时形状投影。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// culling 域命令实现：注入 culling 运行时（读/写/同步/写回编排的唯一边界）。
public actor CullingCommandsImpl: CullingCommands {
    /// 旧分支 list_page 的 limit 缺省值。
    public static let pageLimitDefault = 200
    /// 旧分支 history 的 limit 缺省值。
    public static let historyLimitDefault = 100
    /// 旧分支 history 的 limit 上限。
    public static let historyLimitMax = 500

    private let culling: CullingRuntime

    public init(culling: CullingRuntime) {
        self.culling = culling
    }

    /// 旧命令：`culling.list_page`。scope 白名单由 DTO 枚举承载；
    /// afterRowId 正整数、limit 1...2000（缺省 200）按旧分支保留，
    /// groupId 映射到运行时的 requestedGroupId。
    public func listPage(_ params: CullingListPageParams) async throws -> CullingPage {
        let filters = try Self.validatedFilters(params.filters)
        let normalized = try CullingQueryBuilder.normalize(
            afterRowId: params.afterRowId.map(Int64.init),
            limit: params.limit ?? Self.pageLimitDefault
        )
        return try await culling.listPage(
            sessionId: params.sessionId,
            scope: params.scope,
            filters: filters,
            requestedGroupId: params.groupId,
            afterRowId: normalized.afterRowId,
            limit: normalized.limit
        )
    }

    /// 旧命令：`culling.groups`。相似度分组（决策计数 + 成员轻投影）。
    public func groups(_ params: CullingGroupsParams) async throws -> [CullingGroup] {
        try await culling.groups(sessionId: params.sessionId)
    }

    /// 旧命令：`culling.summary`。徽标计数（决策 + 缓存兜底 + 相似度组数）。
    public func summary(_ params: CullingSummaryParams) async throws -> CullingSummary {
        try await culling.summary(sessionId: params.sessionId)
    }

    /// 旧命令：`culling.history`。limit 缺省 100、上限 500（旧分支门控保留）。
    public func history(_ params: CullingHistoryParams) async throws -> [CullingHistoryOperation] {
        let limit: Int
        if let requested = params.limit {
            guard requested >= 1, requested <= Self.historyLimitMax else {
                throw CullingCommandsError.historyLimitInvalid
            }
            limit = requested
        } else {
            limit = Self.historyLimitDefault
        }
        return try await culling.history(sessionId: params.sessionId, limit: limit)
    }

    /// 旧命令：`culling.sync_status`。元数据同步摘要。
    public func syncStatus(_ params: CullingSyncStatusParams) async throws -> MetadataSyncSummary {
        try await culling.syncStatus(sessionId: params.sessionId)
    }

    /// 旧命令：`culling.update`。expectedRevision 非负（旧分支门控保留）；
    /// patch 合法性（互斥/范围/枚举）沿用旧分支逐字错误消息。
    public func update(_ params: CullingUpdateParams) async throws -> CullingUpdateResult {
        guard params.expectedRevision >= 0 else {
            throw CullingCommandsError.invalidExpectedRevision
        }
        try CullingQueryBuilder.validatePatch(params.patch)
        return try await culling.update(
            sessionId: params.sessionId,
            photoId: params.photoId,
            expectedRevision: params.expectedRevision,
            patch: params.patch
        )
    }

    /// 旧命令：`culling.batch_update`。photoIds 上限 10000（旧分支门控保留，
    /// 按原始条数计）；空选择由运行时逐字抛出。
    public func batchUpdate(_ params: CullingBatchUpdateParams) async throws -> [CullingUpdateResult] {
        guard params.photoIds.count <= CullingQueryBuilder.batchMax else {
            throw CullingServiceError.tooManyPhotoIds
        }
        try CullingQueryBuilder.validatePatch(params.patch)
        return try await culling.batchUpdate(
            sessionId: params.sessionId,
            photoIds: params.photoIds,
            patch: params.patch
        )
    }

    /// 旧命令：`culling.decide_group`。keepPhotoIds 上限 10000（旧分支门控保留）；
    /// 组归属校验（groupTooSmall / keepNotInGroup）由运行时承担。
    public func decideGroup(_ params: CullingDecideGroupParams) async throws -> [CullingUpdateResult] {
        guard params.keepPhotoIds.count <= CullingQueryBuilder.batchMax else {
            throw CullingServiceError.tooManyKeepPhotoIds
        }
        return try await culling.decideGroup(
            sessionId: params.sessionId,
            groupId: params.groupId,
            keepPhotoIds: params.keepPhotoIds
        )
    }

    /// 旧命令：`culling.apply_history`。entries 非空且 ≤10000、逐条 expectedRevision
    /// 非负、historyOperationId ≥1（旧分支门控保留）；undo/redo 并发边界由运行时承担。
    public func applyHistory(_ params: CullingHistoryApplyParams) async throws -> [CullingUpdateResult] {
        guard !params.entries.isEmpty, params.entries.count <= CullingQueryBuilder.batchMax else {
            throw CullingCommandsError.invalidEntries
        }
        for (index, entry) in params.entries.enumerated() {
            try CullingQueryBuilder.validatePatch(entry.patch)
            guard entry.expectedRevision >= 0 else {
                throw CullingCommandsError.invalidEntryExpectedRevision(index)
            }
        }
        guard params.historyOperationId >= 1 else {
            throw CullingCommandsError.invalidHistoryOperationId
        }
        return try await culling.applyHistory(
            sessionId: params.sessionId,
            requestedEntries: params.entries,
            historyOperationId: params.historyOperationId,
            direction: params.direction
        )
    }

    /// 旧命令：`culling.writeback`（破坏性）。confirmed 非 true →
    /// WRITEBACK_CONFIRM_REQUIRED；target 白名单由 DTO 枚举承载。
    @discardableResult
    public func writeback(_ params: CullingWritebackParams) async throws -> WritebackResult {
        guard params.confirmed else {
            throw CullingServiceError.writebackConfirmRequired
        }
        return try await culling.writeback(
            sessionId: params.sessionId, target: params.target, confirmed: true)
    }

    /// 旧命令：`culling.retry_failed_writeback`（破坏性）。confirmed 非 true →
    /// WRITEBACK_RETRY_CONFIRM_REQUIRED。
    @discardableResult
    public func retryFailedWriteback(
        _ params: CullingRetryWritebackParams
    ) async throws -> WritebackResult {
        guard params.confirmed else {
            throw CullingServiceError.writebackRetryConfirmRequired
        }
        return try await culling.retryFailedWriteback(
            sessionId: params.sessionId, confirmed: true)
    }

    /// 旧命令：`culling.flush`。取消计时器后并行冲刷 pending/writing/failed 行。
    public func flush(_ params: CullingFlushParams) async throws -> MetadataSyncSummary {
        try await culling.flush(sessionId: params.sessionId)
    }

    /// 旧命令：`culling.retry_sync`。failed 行重置后整体冲刷。
    public func retrySync(_ params: CullingRetrySyncParams) async throws -> MetadataSyncSummary {
        try await culling.retrySync(sessionId: params.sessionId)
    }

    /// 旧命令：`culling.finalize_sync`（破坏性）。confirmed 非 true →
    /// CULLING_FINALIZE_CONFIRM_REQUIRED。
    public func finalizeSync(_ params: CullingFinalizeSyncParams) async throws -> MetadataSyncSummary {
        guard params.confirmed else {
            throw CullingServiceError.finalizeConfirmRequired
        }
        return try await culling.finalizeSync(sessionId: params.sessionId, confirmed: true)
    }

    /// 旧命令：`culling.confirm_sync`。协调器确认 + 写回项存在时的写回确认；
    /// 旧响应恒为 true，协议面返回空。
    public func confirmSync(_ params: CullingConfirmSyncParams) async throws {
        try await culling.confirmSync(sessionId: params.sessionId)
    }

    /// 旧命令：`culling.cleanup`（破坏性）。confirmed 非 true →
    /// WRITEBACK_CLEANUP_CONFIRM_REQUIRED；返回协调器与写回清理的并集。
    @discardableResult
    public func cleanup(_ params: CullingCleanupParams) async throws -> CleanupResult {
        guard params.confirmed else {
            throw CullingServiceError.writebackCleanupConfirmRequired
        }
        return try await culling.cleanup(sessionId: params.sessionId, confirmed: true)
    }

    /// 旧命令：`culling.reset`（破坏性）。confirmed 非 true →
    /// CULLING_RESET_CONFIRM_REQUIRED；groupId 为 nil 清整会话决策，否则只清该组。
    public func reset(_ params: CullingResetParams) async throws {
        guard params.confirmed else {
            throw CullingServiceError.resetConfirmRequired
        }
        try await culling.resetCommand(
            sessionId: params.sessionId, groupId: params.groupId, confirmed: true)
    }

    // MARK: - 旧分支参数门控

    /// 旧分支 filters 逐字段校验：pickStates / colorLabels / qualityStatus 由 DTO
    /// 枚举承载，此处只保留 ratings 的有限整数 0...5 门控（旧错误消息逐字）。
    private static func validatedFilters(_ filters: CullingFilters?) throws -> CullingFilters? {
        guard let ratings = filters?.ratings else { return filters }
        guard ratings.allSatisfy({ $0.isFinite && $0.rounded() == $0 && (0...5).contains($0) }) else {
            throw CullingCommandsError.invalidRatingsFilter
        }
        return filters
    }
}

/// culling 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
/// 确认类与游标/批量类错误复用运行时既有错误类型，此处只补旧分支独有的
/// 消息形门控。
public enum CullingCommandsError: Error, Equatable {
    /// 旧参数校验拒绝：`ratings must contain integers from 0 to 5`。
    case invalidRatingsFilter
    /// 旧参数校验拒绝：`limit must be an integer between 1 and 500`。
    case historyLimitInvalid
    /// 旧参数校验拒绝：`entries must be a non-empty array with at most 10000 items`。
    case invalidEntries
    /// 旧参数校验拒绝：`entries[<index>].expectedRevision is invalid`。
    case invalidEntryExpectedRevision(Int)
    /// 旧参数校验拒绝：`historyOperationId must be a positive integer`。
    case invalidHistoryOperationId
    /// 旧参数校验拒绝：`expectedRevision must be a non-negative integer`。
    case invalidExpectedRevision
}

extension CullingCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidRatingsFilter: "ratings must contain integers from 0 to 5"
        case .historyLimitInvalid: "limit must be an integer between 1 and 500"
        case .invalidEntries: "entries must be a non-empty array with at most 10000 items"
        case .invalidEntryExpectedRevision(let index): "entries[\(index)].expectedRevision is invalid"
        case .invalidHistoryOperationId: "historyOperationId must be a positive integer"
        case .invalidExpectedRevision: "expectedRevision must be a non-negative integer"
        }
    }
}

extension CullingCommandsError {
    /// 桥接层序列化用；以上均为消息形参数错误，无 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? { nil }
}
