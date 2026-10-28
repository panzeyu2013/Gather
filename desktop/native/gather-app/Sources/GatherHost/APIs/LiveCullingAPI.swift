// desktop/native/gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift
// Cut 1 / B3a：CullingAPI 的 Live 实现（19 个方法）。
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
    /// P1 / D：淘汰移动需要写 photos.filepath；nil = 未接线（调用显式报错）。
    private let photoRepo: (any PhotoRepository)?
    /// P1：移出后的跨表路径迁移（photos/deliveries/intents/origins/bindings/assets）。
    private let relocateAfterMove: ((String, String, String, Bool) throws -> Void)?
    /// P0-1：与写回/清理共用的按 xmpPath 文件锁。搬侧车也在锁内，否则与
    /// 写回的 temp→rename 交错会把刚写回的内容覆盖回旧值。nil = 测试/未接线。
    private let fileLock: XMPFileLock?

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let；CullingService
    /// 的可变状态（会话级更新上下文缓存、Repo 缓存）由 DBConnection 的递归锁与
    /// 各 Repo 串行化（与组合根 @unchecked Sendable 同一约定）。
    public init(
        cullingService: CullingService,
        triageService: TriageService,
        sessionRepo: SessionRepo? = nil,
        photoRepo: (any PhotoRepository)? = nil,
        relocateAfterMove: ((String, String, String, Bool) throws -> Void)? = nil,
        fileLock: XMPFileLock? = nil
    ) {
        self.cullingService = cullingService
        self.triageService = triageService
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.relocateAfterMove = relocateAfterMove
        self.fileLock = fileLock
    }

    // MARK: - P1 / D：淘汰移动

    /// 路径一律从 photos 表取（缓存不可靠），移动后立刻改写登记路径。
    public func moveRejected(_ input: Confirmed<CullingMoveRejectedInput>) async throws -> CullingMoveRejectedResult {
        guard let photoRepo else {
            throw GatherError(
                code: .INVALID_PARAM,
                params: ["field": "photoRepo", "reason": "move_rejected 未接线（缺少 photoRepo）"]
            )
        }
        let payload = input.value
        // 同步部分（校验 + 目标目录）沿用 map 的错误归一；文件搬移必须按单张进
        // XMPFileLock（与写回/清理同一把锁），所以拆成「校验 → 逐张加锁搬移」。
        //
        // P0 / A1 两处语义修正：
        // 1. **按资产展开**：挑片决策是资产级（CullingService.updateState 把 pickState
        //    写到同资产全部变体），只移代表行会把另一半变体留在工作区且仍是已淘汰。
        // 2. **按张过滤而不是整批拒绝**：混进保留件/已移出件时返回 skipped，
        //    其余照常移出（旧实现 allSatisfy 失败 → 一张都动不了）。
        let (targets, skipped, destination) = try map { () -> ([RejectedMoveItem], [CullingMoveRejectedSkip], String) in
            let rows = try photoRepo.getBySessionProjection(sessionId: payload.sessionId)
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            var skipped: [CullingMoveRejectedSkip] = []
            var skippedIds = Set<String>()
            func skip(_ photoId: String, _ reason: String) {
                guard skippedIds.insert(photoId).inserted else { return }
                skipped.append(CullingMoveRejectedSkip(photoId: photoId, reason: reason))
            }

            var requested: [PhotoProjectionRow] = []
            for photoId in payload.photoIds {
                if let row = byId[photoId] { requested.append(row) } else { skip(photoId, "not_in_session") }
            }
            let rejected = Set(
                try cullingService.getDecisions(sessionId: payload.sessionId)
                    .filter { $0.decision == CullingDecisionValue.reject.rawValue }
                    .map(\.photoId))

            // 资产展开：保持"请求顺序 → 资产内导入序"的确定性。
            var targetIds = Set<String>()
            var orderedIds: [String] = []
            func addTarget(_ photoId: String) {
                if targetIds.insert(photoId).inserted { orderedIds.append(photoId) }
            }
            for row in requested {
                if let assetId = row.assetId, !assetId.isEmpty {
                    for variant in rows where variant.assetId == assetId { addTarget(variant.id) }
                } else {
                    addTarget(row.id)
                }
            }
            var visibleByXmp: [String: [String]] = [:]
            for row in rows where row.archivedAt == nil {
                let key = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
                visibleByXmp[key, default: []].append(row.id)
            }
            // 先把“实际会移动”的行筛出来，再算 movingIds。资产展开会包含未淘汰的
            // 兄弟；若把这些兄弟也算作 moving，sharesSidecar 会被误判为 false，
            // 移出已淘汰变体时就会把共享 .xmp 从留下的兄弟身边搬走。
            var movingRows: [(photoId: String, row: PhotoProjectionRow)] = []
            for photoId in orderedIds {
                guard let row = byId[photoId] else { continue }
                if row.archivedAt != nil { skip(photoId, "already_archived"); continue }
                guard rejected.contains(photoId) else { skip(photoId, "not_rejected"); continue }
                movingRows.append((photoId, row))
            }
            let movingIds = Set(movingRows.map { $0.photoId })
            var items: [RejectedMoveItem] = []
            for (photoId, row) in movingRows {
                let key = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
                let siblingsRemain = (visibleByXmp[key] ?? []).contains { !movingIds.contains($0) }
                items.append(RejectedMoveItem(
                    photoId: photoId, filepath: row.filepath, sharesSidecar: siblingsRemain))
            }

            let session = try sessionRepo?.get(id: payload.sessionId)
            let root: String
            if let explicit = payload.destinationRoot {
                // 显式目标只接受会话根目录下的路径：防止把照片搬到任意目录。
                let base = URL(fileURLWithPath: session?.sourcePath ?? "")
                    .resolvingSymlinksInPath().path
                let target = URL(fileURLWithPath: explicit)
                    .resolvingSymlinksInPath().path
                guard !base.isEmpty, target == base || target.hasPrefix(base + "/") else {
                    throw GatherError.invalidParameter(
                        field: "destinationRoot", reason: "must be inside the session source path")
                }
                root = explicit
            } else if let sourcePath = session?.sourcePath, !sourcePath.isEmpty {
                root = sourcePath
            } else {
                root = requested.first.map { ($0.filepath as NSString).deletingLastPathComponent } ?? ""
            }
            return (items, skipped, (root as NSString).appendingPathComponent(RejectedMover.folderName))
        }

        var moved: [String] = []
        var newPaths: [String] = []
        var failures: [MetadataApplyFailureDTO] = []
        for item in targets {
            let one: RejectedMoveResult
            do {
                one = try await withFileLock(path: TSPath.xmpSidecarPath(item.filepath)) {
                    // 只捕获 self（@unchecked Sendable 的不可变依赖）；直接捕获局部
                    // photoRepo 会触发 Swift 6 的 non-Sendable 捕获错误。
                    guard let repo = self.photoRepo else {
                        throw GatherError(
                            code: .INVALID_PARAM,
                            params: ["field": "photoRepo", "reason": "move_rejected 未接线"])
                    }
                    return RejectedMover(photoRepo: repo, relocate: self.relocateAfterMove)
                        .move(items: [item], destinationRoot: destination)
                }
            } catch {
                failures.append(MetadataApplyFailureDTO(
                    photoId: item.photoId, message: String(describing: error)))
                continue
            }
            moved.append(contentsOf: one.moved)
            newPaths.append(contentsOf: one.newPaths)
            failures.append(contentsOf: one.failed.map {
                MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message)
            })
        }
        return CullingMoveRejectedResult(
            moved: moved, newPaths: newPaths, skipped: skipped, failed: failures)
    }

    /// P0 / A1：当前 scope/filters 下的完整选中集（代表行）。
    public func selection(_ query: CullingSelectionQuery) async throws -> CullingSelectionIds {
        try map { try cullingService.selectableIds(query) }
    }

    /// 文件搬移与写回/清理共用同一把按 xmpPath 的锁（未接线时退化为不加锁）。
    private func withFileLock<T: Sendable>(
        path: String,
        _ body: @Sendable () throws -> T
    ) async throws -> T {
        guard let fileLock else { return try body() }
        return try await fileLock.run(path: path) { try body() }
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
        try await mapAsync { try await cullingService.flushQueuedMetadata(sessionId: input.sessionId) }
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
        try await mapAsync { try await cullingService.flushQueuedMetadata(sessionId: input.sessionId) }
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
        try await mapAsync { try await cullingService.flushQueuedMetadata(sessionId: input.sessionId) }
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
