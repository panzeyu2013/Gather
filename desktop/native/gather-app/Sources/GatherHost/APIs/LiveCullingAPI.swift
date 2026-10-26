// desktop/native/gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift
// Cut 1 / B3a：CullingAPI 的 Live 实现（17 个方法）。
//
// 对应命令（19 条）：culling.list_page / history / apply_history / update /
// batch_update / decide_group / groups / summary / sync_status / reset /
// writeback / flush / retry_sync / retry_failed_writeback / cleanup /
// finalize_sync / confirm_sync（culling.decide / batch_decide 已按 R2/R3 删除，
// 行为由 update / batchUpdate 覆盖）。
//
// 校验归属（与 CullingInputs 的分工）：
// - scope 枚举、分页 limit/afterRowId、entries 数量与逐项字段、patch 非空与
//   0...5 整数范围都在输入类型 init 里完成（§6.2 / D-012），本实现不重复实现；
// - 只接收 sessionId 的方法（groups / summary / syncStatus / flush / retrySync /
//   confirmSync）在这里补“非空白 + 长度上限”校验（对齐 LiveSessionAPI.get），
//   失败统一 GatherError.invalidParameter；
// - 5 个破坏性入口只接收 Confirmed<T>（reset / writeback / retryFailedWriteback /
//   cleanup / finalizeSync），内部固定传 confirmed: true：类型层面已经保证
//   “没有确认弹窗就写不出调用点”，实现不自行补确认、也不再解析 Bool（D-011）；
// - 修订冲突、照片归属、历史顺序、写回与清理的编排仍由 CullingService 负责；
//   本实现只做 CullingServiceError -> GatherError 的映射。revisionConflict 带上
//   expected/current 参数（旧命令面 以 CODE::expected::current 传给 UI 插值，
//   GatherError 改为结构化 params，UI 模板可继续插值）。
//
// 边界：
// - 写回 / 清理 / 最终同步继续走 CullingService 现有接缝（Cut 2 的
//   DeliveryCoordinator 再统一状态机），本文件不提前改语义（R6）；
// - syncStatus 额外补 reloadAckedAt（旧命令面 在 JSON 层临时补的键），由
//   SessionRepo 读 session.reload_acked_at，输出收敛为 CullingSyncStatus。
// - 非域错误（DBError 中已经写成错误码的 message）沿用 LiveAPIErrorMapping 的
//   收敛口径；其余错误原样抛出（D-030 的通用文案兜底约定）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

public final class LiveCullingAPI: CullingAPI, @unchecked Sendable {
    private let cullingService: CullingService
    /// P0 / T0：技术质量建议（只写决策/建议，不写 XMP）。
    private let triageService: TriageService
    /// 只读会话行：syncStatus 需要 session.reload_acked_at。nil 时该字段恒为 nil
    /// （测试/嵌入场景不需要重载确认语义）。
    private let sessionRepo: SessionRepo?

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let；CullingService
    /// 的可变状态（会话级更新上下文缓存、Repo 缓存）由 DBConnection 的递归锁与
    /// 各 Repo 串行化（与组合根 @unchecked Sendable 同一约定）。
    public init(
        cullingService: CullingService,
        triageService: TriageService,
        sessionRepo: SessionRepo? = nil
    ) {
        self.cullingService = cullingService
        self.triageService = triageService
        self.sessionRepo = sessionRepo
    }

    // MARK: - 读

    public func page(_ query: CullingPageQuery) async throws -> CullingPage {
        try map { try cullingService.listPage(query) }
    }

    public func history(_ query: CullingHistoryQuery) async throws -> [CullingHistoryOperation] {
        try map {
            try cullingService.getHistory(sessionId: query.sessionId, limit: query.limit)
        }
    }

    public func groups(_ sessionId: String) async throws -> [CullingGroup] {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map { try cullingService.getGroups(sessionId: id) }
    }

    public func summary(_ sessionId: String) async throws -> CullingSummary {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map {
            var summary = try cullingService.getSummary(sessionId: id)
            // 关闭 T0 时跳过 TriageRepo 指纹聚合；summary 也不需要该字段。
            if triageService.isEnabled {
                summary.triage = try triageService.summary(sessionId: id)
            }
            return summary
        }
    }

    // MARK: - T0（技术质量建议）

    public func generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary {
        let id = try LiveAPIInput.requireSessionId(input.sessionId)
        // 生成/应用是同步 CPU+DB 重活；离开 MainActor，20k 候选不阻塞 UI。
        return try await Task.detached(priority: .userInitiated) {
            try self.map {
                try self.triageService.generate(sessionId: id, force: input.force)
            }
        }.value
    }

    public func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult {
        try await Task.detached(priority: .userInitiated) {
            try self.map {
                try self.triageService.apply(input)
            }
        }.value
    }

    public func syncStatus(_ sessionId: String) async throws -> CullingSyncStatus {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map {
            let summary = try cullingService.syncStatus(sessionId: id)
            let reloadAckedAt = try sessionRepo?.get(id: id)?.reloadAckedAt
            return CullingSyncStatus(summary: summary, reloadAckedAt: reloadAckedAt)
        }
    }

    // MARK: - 写（决策/历史）

    public func applyHistory(_ input: CullingApplyHistoryInput) async throws -> [CullingUpdateResult] {
        let result = try map {
            try cullingService.applyHistory(
                sessionId: input.sessionId,
                requestedEntries: input.entries,
                historyOperationId: input.historyOperationId,
                direction: input.direction,
                source: input.source ?? .manual
            )
        }
        try await cullingService.flushQueuedMetadata(sessionId: input.sessionId)
        return result
    }

    /// 单张更新走“会话级更新上下文 + updateState”两步（旧命令面 同一调用序列：
    /// 点击突发不再每次重读整个会话）。
    public func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult {
        let result = try map {
            let context = try cullingService.getUpdateContext(sessionId: input.sessionId)
            return try cullingService.updateState(
                sessionId: input.sessionId,
                photoId: input.photoId,
                expectedRevision: input.expectedRevision,
                patch: input.patch,
                context: context
            )
        }
        try await cullingService.flushQueuedMetadata(sessionId: input.sessionId)
        return result
    }

    public func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult] {
        let result = try map {
            try cullingService.batchUpdate(
                sessionId: input.sessionId,
                photoIds: input.photoIds,
                patch: input.patch
            )
        }
        try await cullingService.flushQueuedMetadata(sessionId: input.sessionId)
        return result
    }

    public func decideGroup(_ input: CullingDecideGroupInput) async throws -> [CullingUpdateResult] {
        try map {
            try cullingService.decideSimilarityGroup(
                sessionId: input.sessionId,
                groupId: input.groupId,
                keepPhotoIds: input.keepPhotoIds
            )
        }
    }

    // MARK: - 破坏性（Confirmed<T>，内部固定 confirmed: true）

    public func reset(_ input: Confirmed<CullingResetInput>) async throws -> Bool {
        let payload = input.value
        return try map {
            try cullingService.resetCommand(
                sessionId: payload.sessionId,
                groupId: payload.groupId,
                confirmed: true
            )
            return true
        }
    }

    public func writeback(_ input: Confirmed<CullingWritebackInput>) async throws -> WritebackResult {
        let payload = input.value
        return try await mapAsync {
            try await cullingService.writeback(
                sessionId: payload.sessionId,
                target: payload.target,
                confirmed: true
            )
        }
    }

    public func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            try await cullingService.retryFailedWriteback(sessionId: sessionId, confirmed: true)
        }
    }

    public func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            try await cullingService.cleanup(sessionId: sessionId, confirmed: true)
        }
    }

    public func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataSyncSummary {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            try await cullingService.finalizeSync(sessionId: sessionId, confirmed: true)
        }
    }

    // MARK: - 同步

    public func flush(_ sessionId: String) async throws -> MetadataSyncSummary {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync { try await cullingService.flush(sessionId: id) }
    }

    public func retrySync(_ sessionId: String) async throws -> MetadataSyncSummary {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync { try await cullingService.retrySync(sessionId: id) }
    }

    /// 旧命令面 的 culling.confirm_sync 成功即 ok(true)；服务返回 void，这里收敛
    /// 成 Bool（与 reset 同一惯例）。
    public func confirmSync(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync {
            try await cullingService.confirmSync(sessionId: id)
            return true
        }
    }

    // MARK: - 校验与错误映射

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as GatherError {
            throw error
        } catch let error as CullingServiceError {
            throw Self.gatherError(error)
        } catch let error as TriageServiceError {
            throw Self.gatherError(error)
        } catch let error as CodedError {
            throw GatherError(code: error.code, underlying: String(describing: error))
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as GatherError {
            throw error
        } catch let error as CullingServiceError {
            throw Self.gatherError(error)
        } catch let error as TriageServiceError {
            throw Self.gatherError(error)
        } catch let error as CodedError {
            throw GatherError(code: error.code, underlying: String(describing: error))
        }
    }

    /// TriageServiceError -> GatherError：四个稳定码，reason 放 params。
    static func gatherError(_ error: TriageServiceError) -> GatherError {
        switch error {
        case .notReady:
            return GatherError(code: .TRIAGE_NOT_READY, underlying: error.description)
        case .stale:
            return GatherError(code: .TRIAGE_STALE, underlying: error.description)
        case .applyInvalid(let reason):
            return GatherError(code: .TRIAGE_APPLY_INVALID, params: ["reason": reason], underlying: error.description)
        case .policyInvalid(let reason):
            return GatherError(code: .TRIAGE_POLICY_INVALID, params: ["reason": reason], underlying: error.description)
        }
    }

    /// CullingServiceError -> GatherError：
    /// - 有专用码的域错误保持码值（含 revisionConflict 的结构化参数）；
    /// - 纯输入形状错误（服务侧兜底的历史校验）映射为 INVALID_PARAM + field。
    static func gatherError(_ error: CullingServiceError) -> GatherError {
        switch error {
        case .photoNotInSession:
            return GatherError(code: .CULLING_PHOTO_NOT_IN_SESSION, underlying: error.description)
        case .revisionConflict(let expected, let current):
            return GatherError(
                code: .CULLING_REVISION_CONFLICT,
                params: [
                    "expectedRevision": String(expected),
                    "currentRevision": String(current),
                ],
                underlying: error.description
            )
        case .patchInvalid:
            return GatherError(code: .CULLING_PATCH_INVALID, underlying: error.description)
        case .emptySelection:
            return GatherError(code: .CULLING_EMPTY_SELECTION, underlying: error.description)
        case .photosNotInSession:
            return GatherError(code: .CULLING_PHOTOS_NOT_IN_SESSION, underlying: error.description)
        case .historyNotFound:
            return GatherError(code: .CULLING_HISTORY_NOT_FOUND, underlying: error.description)
        case .historyAlreadyUndone:
            return GatherError(code: .CULLING_HISTORY_ALREADY_UNDONE, underlying: error.description)
        case .historyNotUndone:
            return GatherError(code: .CULLING_HISTORY_NOT_UNDONE, underlying: error.description)
        case .historyDiverged:
            return GatherError(code: .CULLING_HISTORY_DIVERGED, underlying: error.description)
        case .historyDuplicatePhotos:
            return .invalidParameter(field: "entries", reason: error.description)
        case .noSimilarity:
            return GatherError(code: .CULLING_NO_SIMILARITY, underlying: error.description)
        case .groupTooSmall:
            return GatherError(code: .CULLING_GROUP_TOO_SMALL, underlying: error.description)
        case .keepNotInGroup:
            return GatherError(code: .CULLING_KEEP_NOT_IN_GROUP, underlying: error.description)
        case .ratingOutOfRange:
            return .invalidParameter(field: "patch.rating", reason: error.description)
        case .invalidPickState:
            return .invalidParameter(field: "patch.pickState", reason: error.description)
        case .invalidColorLabel:
            return .invalidParameter(field: "patch.colorLabel", reason: error.description)
        case .invalidScope:
            return GatherError(code: .CULLING_INVALID_SCOPE, underlying: error.description)
        case .pageLimitInvalid:
            return .invalidParameter(field: "limit", reason: error.description)
        case .tooManyPhotoIds:
            return .invalidParameter(field: "photoIds", reason: error.description)
        case .tooManyKeepPhotoIds:
            return .invalidParameter(field: "keepPhotoIds", reason: error.description)
        case .finalizeConfirmRequired:
            return GatherError(code: .CULLING_FINALIZE_CONFIRM_REQUIRED, underlying: error.description)
        case .resetConfirmRequired:
            return GatherError(code: .CULLING_RESET_CONFIRM_REQUIRED, underlying: error.description)
        case .noDecisions:
            return GatherError(code: .CULLING_NO_DECISIONS, underlying: error.description)
        case .writebackConfirmRequired:
            return GatherError(code: .WRITEBACK_CONFIRM_REQUIRED, underlying: error.description)
        case .writebackRetryConfirmRequired:
            return GatherError(code: .WRITEBACK_RETRY_CONFIRM_REQUIRED, underlying: error.description)
        case .writebackCleanupConfirmRequired:
            return GatherError(code: .WRITEBACK_CLEANUP_CONFIRM_REQUIRED, underlying: error.description)
        }
    }
}
