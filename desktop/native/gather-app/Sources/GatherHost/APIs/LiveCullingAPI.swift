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
// - Wave1（task-6）新增 acknowledgeManualReload：只写 reload-ack 列（G2 的
//   "我已在 C1 手动 Load Metadata" 兜底），不伪造脚本成功，也不碰交付状态机。
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
    /// #2 S3：锁内执行（逐张加锁 + 失败隔离 + photo_count 重算）。
    private let rejectMove: CullingRejectMoveService?
    /// P1：移出后的跨表路径迁移（photos/deliveries/intents/origins/bindings/assets）。
    private let relocateAfterMove: ((String, String, String, Bool) throws -> Void)?
    /// P0-1：与写回/清理共用的按 xmpPath 文件锁。搬 sidecar 也在锁内，否则与
    /// 写回的 temp→rename 交错会把刚写回的内容覆盖回旧值。nil = 测试/未接线。
    private let fileLock: XMPFileLock?
    /// W1：模型级初审信号（检查器卡片按需读取；nil = 未接线，返回 nil）。
    private let modelReviewRepo: ModelReviewRepo?
    /// P1 下一波：校样反馈 v2（picks + rating/label/comment）；nil = 旧 picks 路径。
    private let proofFeedback: ProofFeedbackService?
    /// P1：技术质量建议阈值校准；nil = 未接线（API 显式报 INVALID_PARAM）。
    private let calibration: TriageCalibrationService?

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let；CullingService
    /// 的可变状态（会话级更新上下文缓存、Repo 缓存）由 DBConnection 的递归锁与
    /// 各 Repo 串行化（与组合根 @unchecked Sendable 同一约定）。
    public init(
        cullingService: CullingService,
        triageService: TriageService,
        sessionRepo: SessionRepo? = nil,
        photoRepo: (any PhotoRepository)? = nil,
        relocateAfterMove: ((String, String, String, Bool) throws -> Void)? = nil,
        fileLock: XMPFileLock? = nil,
        modelReviewRepo: ModelReviewRepo? = nil,
        proofFeedback: ProofFeedbackService? = nil,
        calibration: TriageCalibrationService? = nil
    ) {
        self.cullingService = cullingService
        self.triageService = triageService
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.relocateAfterMove = relocateAfterMove
        self.fileLock = fileLock
        // 依赖与原来完全同源（同一 photoRepo / 同一把锁），构造点在适配器内部，
        // 因此 FeatureAPIs 与 3 处测试构造点的参数零改动。
        self.rejectMove = photoRepo.map { _ in
            CullingRejectMoveService(
                refreshPhotoCount: { [sessionRepo] id in
                    _ = try sessionRepo?.refreshPhotoCount(id: id)
                },
                fileLock: fileLock)
        }
        self.modelReviewRepo = modelReviewRepo
        self.proofFeedback = proofFeedback
        self.calibration = calibration
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
        // #2 S3：规划部分抽到 RejectedMovePlanner（纯函数，core 侧可单测）：
        // 资产展开 / skipped 归因 / sharesSidecar / 目标目录安全校验都在那里。
        let plan = try map { () -> RejectedMovePlanner.Plan in
            let rows = try photoRepo.getBySessionProjection(sessionId: payload.sessionId)
            let rejected = Set(
                try cullingService.getDecisions(sessionId: payload.sessionId)
                    .filter { $0.decision == CullingDecisionValue.reject.rawValue }
                    .map(\.photoId))
            let session = try sessionRepo?.get(id: payload.sessionId)
            let candidates = rows.map {
                RejectedMovePlanner.Candidate(
                    photoId: $0.id, filepath: $0.filepath, assetId: $0.assetId,
                    isArchived: PhotoVisibility.isArchived(archivedAt: $0.archivedAt))
            }
            return try RejectedMovePlanner.plan(
                requestedIds: payload.photoIds,
                candidates: candidates,
                rejectedIds: rejected,
                sessionSourcePath: session?.sourcePath,
                explicitDestinationRoot: payload.destinationRoot)
        }

        // #2 S3：锁内执行已下沉到 CullingRejectMoveService（逐张加锁、失败隔离、
        // photo_count 重算）。这里只做规划 + 一次调用。
        guard let rejectMove else {
            throw GatherError(
                code: .INVALID_PARAM,
                params: ["field": "photoRepo", "reason": "move_rejected 未接线（缺少 photoRepo）"]
            )
        }
        // 函数开头的 guard 已把可选字段解成局部 photoRepo（同一作用域）。
        let mover = RejectedMover(photoRepo: photoRepo, relocate: relocateAfterMove)
        return try await rejectMove.move(plan, mover: mover, sessionId: payload.sessionId)
    }

    /// P0 / A1：当前 scope/filters 下的完整选中集（代表行）。
    public func selection(_ query: CullingSelectionQuery) async throws -> CullingSelectionIds {
        try map { try cullingService.selectableIds(query) }
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

    public func modelReview(_ photoId: String) async throws -> ModelReviewResult? {
        let trimmed = photoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatherError(code: .INVALID_PARAM, params: ["field": "photoId", "reason": "must not be empty"])
        }
        guard let repo = modelReviewRepo else { return nil }
        return try map {
            guard let row = try repo.latest(photoIds: [trimmed])[trimmed] else { return nil }
            do {
                return try JSONDecoder().decode(ModelReviewResult.self, from: Data(row.json.utf8))
            } catch {
                return nil
            }
        }
    }

    public func importClientSelection(
        _ input: Confirmed<ClientSelectionImportInput>
    ) async throws -> ClientSelectionImportReport {
        let payload = input.value
        let sessionId = try LiveAPIInput.requireSessionId(payload.sessionId)
        let data = Data(payload.json.utf8)

        let report: ClientSelectionImportReport
        if proofFeedback != nil {
            report = try await Task.detached(priority: .userInitiated) {
                try self.map {
                    // 服务非 Sendable：经 self 的 let 引用访问，不捕获成局部变量跨线程。
                    try self.proofFeedback!.import(
                        sessionId: sessionId, data: data)
                }
            }.value
        } else {
            // 未接线：保持 v1 勾选语义（评分/色标/评论不应用）。
            let ids = try map {
                try ClientSelectionParser.pickedPhotoIds(from: data)
            }
            let outcome = try await Task.detached(priority: .userInitiated) {
                try self.map {
                    try self.cullingService.applyImportedPicks(
                        sessionId: sessionId, photoIds: ids)
                }
            }.value
            let applied = outcome.results.count
            report = ClientSelectionImportReport(
                picked: ids.count,
                applied: applied,
                skipped: max(0, ids.count - applied - outcome.failed),
                failed: outcome.failed)
        }
        try await mapAsync {
            try await self.cullingService.flushQueuedMetadata(sessionId: sessionId)
        }
        return report
    }

    public func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult {
        try await Task.detached(priority: .userInitiated) {
            try self.map {
                try self.triageService.apply(input)
            }
        }.value
    }


    public func proofComments(sessionId: String) async throws -> [String: String] {
        guard let proofFeedback else { return [:] }
        return try map { try proofFeedback.comments(sessionId: sessionId) }
    }

    public func adjustmentHint(photoId: String) async throws -> CropFrame? {
        guard let photoRepo,
              let photo = try photoRepo.getLookupByIds([photoId]).first else { return nil }
        guard let bridge = CaptureOneBridge.shared,
              let hint = bridge.adjustmentHints(paths: [photo.filepath]).first,
              let rect = hint.cropRect else { return nil }
        return CropFrame(
            left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
            angle: hint.angle ?? 0)
    }

    public func triageCalibration(
        _ query: TriageCalibrationQuery
    ) async throws -> TriageCalibrationSnapshot {
        guard let calibration else {
            throw GatherError.invalidParameter(
                field: "triageCalibration", reason: "calibration service not wired")
        }
        let report = try await Task.detached(priority: .utility) {
            try self.map { try calibration.report(sessionId: query.sessionId) }
        }.value
        return Self.snapshot(from: report)
    }

    public func applyTriageCalibration(
        _ input: Confirmed<TriageCalibrationApplyInput>
    ) async throws -> TriageCalibrationThresholdSnapshot {
        guard let calibration else {
            throw GatherError.invalidParameter(
                field: "applyTriageCalibration", reason: "calibration service not wired")
        }
        let value = input.value
        let applied = try await Task.detached(priority: .utility) {
            try self.map {
                try calibration.applyThresholds(
                    keep: value.keep, reject: value.reject,
                    minExecutable: value.minExecutable)
            }
        }.value
        return TriageCalibrationThresholdSnapshot(
            keep: applied.keep, reject: applied.reject,
            minExecutable: applied.minExecutable)
    }

    private static func snapshot(
        from report: TriageCalibrationReport
    ) -> TriageCalibrationSnapshot {
        TriageCalibrationSnapshot(
            sessionId: report.sessionId,
            samples: report.samples,
            minSamples: report.minSamples,
            buckets: report.buckets.map {
                TriageCalibrationBucketSnapshot(
                    lowerBound: $0.lowerBound, upperBound: $0.upperBound,
                    samples: $0.samples, keepSuggestions: $0.keepSuggestions,
                    agreedKeep: $0.agreedKeep)
            },
            current: TriageCalibrationThresholdSnapshot(
                keep: report.current.keep, reject: report.current.reject,
                minExecutable: report.current.minExecutable),
            currentKeepPrecision: report.currentKeepPrecision,
            currentRejectPrecision: report.currentRejectPrecision,
            suggestions: report.suggestions.map {
                TriageCalibrationSuggestionSnapshot(
                    target: $0.target, confidence: $0.confidence,
                    samples: $0.samples, keepPrecision: $0.keepPrecision,
                    rejectPrecision: $0.rejectPrecision,
                    keep: $0.keep, reject: $0.reject, review: $0.review)
            },
            byCamera: report.byCamera.map {
                TriageCalibrationCameraSnapshot(
                    cameraModel: $0.cameraModel, samples: $0.samples,
                    keepPrecision: $0.keepPrecision)
            },
            generatedAt: report.generatedAt)
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
        recordManualFeedback(
            sessionId: input.sessionId, photoIds: [input.photoId],
            pickState: input.patch.pickState)
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
        recordManualFeedback(
            sessionId: input.sessionId, photoIds: input.photoIds,
            pickState: input.patch.pickState)
        return result
    }

    public func updateSelection(
        _ input: CullingSelectionUpdateInput
    ) async throws -> CullingSelectionUpdateResult {
        let result = try map { try cullingService.updateSelection(input) }
        try await mapAsync {
            try await cullingService.flushQueuedMetadata(sessionId: input.sessionId)
        }
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

    /// P0 / G2：手动 Load Metadata 的显式 ack（写 sessions.reload_acked_at）。
    ///
    /// 只写持久列、不触发 AppleScript：用户已在 C1 里执行 Load Metadata 是前提，
    /// Gather 无法验证也不该假装验证——它是**用户声明**，用来解除 §5.4-2 的
    /// reload-ack 死锁（DeliveryCoordinator.requireReloadAck 读同一列）。
    /// 返回 false 只在会话不存在时可能出现（此时报 SESSION_NOT_FOUND，不写孤儿列）。
    public func acknowledgeManualReload(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        guard let sessionRepo else {
            throw GatherError.invalidParameter(
                field: "sessionRepo", reason: "手动重载确认未接线（缺少 sessionRepo）")
        }
        let changed = try map {
            try sessionRepo.setReloadAckedAt(sessionId: id, iso: nowISOString())
        }
        guard changed else { throw GatherError(code: .SESSION_NOT_FOUND) }
        return true
    }

    /// Wave5 batch6 / R6：把本会话的淘汰判断在 C1 里表达为红标（只改 color tag）。
    ///
    /// 职责划分：本方法只做**查数据**（哪些照片是 rejected、它们的绝对路径），
    /// AppleScript/变体安全规则全在 CaptureOneBridge.writeRejectedColorTags。
    ///
    /// 数据口径：
    /// - 决策来源 = culling_decisions 里 decision == "reject" 的照片（与挑片页"淘汰"同一真相源）；
    /// - 只取可见且未缺失的照片（归档/移出 _rejects 的照片不该再去改 C1 色标）；
    /// - 没有淘汰项返回空报告（不是错误：UI 侧按钮本就禁用，服务端不制造假失败）。
    ///
    /// 未接线（测试替身/预览）时由协议默认实现抛 INVALID_PARAM，不伪造成功。
    public func writeRejectedColorTags(_ sessionId: String) async throws -> C1VariantWritebackReport {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        guard let bridge = CaptureOneBridge.shared else {
            throw GatherError.invalidParameter(
                field: "captureOne", reason: "C1 桥未接线（缺少 CaptureOneBridge.shared）")
        }
        let decisions = try map { try cullingService.getDecisions(sessionId: id) }
        let rejected = Set(
            decisions
                .filter { $0.decision == CullingDecisionValue.reject.rawValue }
                .map(\.photoId)
        )
        guard !rejected.isEmpty else { return C1VariantWritebackReport() }
        guard let photoRepo else {
            throw GatherError.invalidParameter(
                field: "photoRepo", reason: "淘汰红标未接线（缺少 photoRepo）")
        }
        let rows = try map { try photoRepo.getBySessionProjection(sessionId: id) }
        let paths = rows
            .filter { row in
                rejected.contains(row.id)
                    && PhotoVisibility.isVisible(archivedAt: row.archivedAt)
                    && row.status != "missing"
            }
            .map(\.filepath)
        guard !paths.isEmpty else { return C1VariantWritebackReport() }
        do {
            return try await bridge.writeRejectedColorTags(paths: paths)
        } catch let error as CaptureOneBridgeError {
            // 桥错误是稳定码：收敛成 GatherError（UI 按码取文案，不直出英文诊断）。
            throw GatherError(code: error.code, underlying: error.description)
        }
    }

    // MARK: - 校验与错误映射

    /// 人工改选 → triage_feedback（校准样本）。失败只记日志，不影响决策提交。
    private func recordManualFeedback(
        sessionId: String, photoIds: [String], pickState: PickState?
    ) {
        guard let pickState else { return }
        let decision: CullingDecisionValue
        switch pickState {
        case .picked: decision = .keep
        case .rejected: decision = .reject
        case .unreviewed: decision = .pending
        }
        for photoId in Set(photoIds) {
            do {
                _ = try triageService.recordManualDecision(
                    sessionId: sessionId, photoId: photoId, decision: decision)
            } catch {
                GatherLogger.log(
                    "triage feedback record failed: \(error)", level: .debug)
            }
        }
    }

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
