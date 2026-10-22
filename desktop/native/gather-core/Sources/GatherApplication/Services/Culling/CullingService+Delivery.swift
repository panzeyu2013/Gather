// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Delivery.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// 交付/写回编排：同步态读模型、flush/retry/finalize、writeback 镜像、confirm/cleanup。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    // MARK: - 同步态读模型（S5c-2b-3b-2a）

    /// 交付行 → 旧 MetadataSyncStatus 投影（culling 徽标/更新结果用）。
    static func syncStatus(from status: DeliveryStatus) -> MetadataSyncStatus {
        switch status {
        case .pending: .pending
        case .writing: .writing
        case .written: .written
        case .synced: .synced
        case .failed: .failed
        case .conflict: .conflict
        case .cleaned: .cleaned
        }
    }

    /// 同步态的唯一读模型是 deliveries（写回执行器直接维护）。
    /// 手动 rating/label 的旧 outbox 行不再读取：交付行尚未出现时返回调用方给出的
    /// 默认值（updateState 对共享元数据传 .pending，表达"已入队、尚未落交付"）。
    func currentSyncStatus(
        xmpPath: String,
        fallback: MetadataSyncStatus
    ) throws -> MetadataSyncStatus {
        if let row = try deliveryItems.getItem(xmpPath: xmpPath), let status = row.typedStatus {
            return Self.syncStatus(from: status)
        }
        return fallback
    }
    // MARK: - IPC 命令面（culling.ipc.ts 逐命令对齐）

    /// TS: culling.sync_status。
    ///
    /// S5c-2b-1 起改读交付模型（DeliverySummaryQuery 的 MetadataSyncSummary 投影），
    /// 只读 deliveries / delivery_items：计数按交付去重，item 的 pending/failed
    /// 会升级展示态；不再读 metadata_outbox。
    public func syncStatus(sessionId: String) throws -> MetadataSyncSummary {
        try delivery.cullingMetadataSummary(sessionId: sessionId)
    }
    /// TS: culling.flush。
    ///
    /// S5c-2b-1 起 flush 的动作是「回放未完成的 delivery intent」（cleanup/finalize
    /// 的崩溃恢复），不再触发旧 outbox 队列；写盘仍由 writeback/retryFailedWriteback
    /// 内的旧 WritebackService.execute 同步完成（S5c-2b-3 整体切换）。
    public func flush(sessionId: String) async throws -> MetadataSyncSummary {
        _ = try await delivery.replayPendingDeliveries()
        return try delivery.cullingMetadataSummary(sessionId: sessionId)
    }
    /// TS: culling.retry_sync。
    ///
    /// 与 flush 同一出口：按相位重放 intent（prepared 重做文件+DB，fileDone 只补 DB），
    /// 然后返回交付摘要。写回失败的逐项重试仍走 retryFailedWriteback。
    public func retrySync(sessionId: String) async throws -> MetadataSyncSummary {
        _ = try await delivery.replayPendingDeliveries()
        return try delivery.cullingMetadataSummary(sessionId: sessionId)
    }
    /// TS: culling.finalize_sync（confirmed 必须为 true，否则
    /// CULLING_FINALIZE_CONFIRM_REQUIRED）。
    ///
    /// S5c-2b-1：改由 DeliveryCoordinator.finalize(dropWithoutRestore) 执行——
    /// 「保留 XMP 并结束」：只处理 synced 交付，删除 items/links/delivery 与备份文件，
    /// **绝不 restore**；intent 前滚保证崩溃后可重试。不是 confirm 的别名。
    ///
    /// 门禁与 confirmSync 一致：Capture One 未 ack reload 时抛旧码
    /// XMP_CONFIRM_REQUIRES_SYNC（DeliveryError.confirmRequiresSync）。
    public func finalizeSync(sessionId: String, confirmed: Bool) async throws -> MetadataSyncSummary {
        guard confirmed else { throw CullingServiceError.finalizeConfirmRequired }
        do {
            let finalized = try await delivery.finalizeCulling(sessionId: sessionId)
            // 逐交付失败保留在 intent 里可重试；旧返回类型没有 errors 位，至少必须进日志
            //（禁止静默吞掉 XMP_FINALIZE_* —— 与 cleanup 的错误可见性同一纪律）。
            for error in finalized.errors {
                GatherLogger.log("culling finalize (\(sessionId)): \(error)", level: .warn)
            }
        } catch let error as DeliveryCoordinatorError {
            if case .reloadNotAcknowledged = error {
                throw DeliveryError.confirmRequiresSync
            }
            throw error
        }
        return try delivery.cullingMetadataSummary(sessionId: sessionId)
    }
    /// TS: culling.writeback —— 决策计划 → preview → 属性合并 → execute。
    /// 写回引擎由注入的 WritebackService 承担，本方法只组装计划与合并关键词。
    ///
    /// 计划的值来自唯一真相源：评分/色标读 photo_metadata_cache（用户设的 3 星就写
    /// 3 星，不是 keep→5/reject→1 的派生常量——execute 落盘后会按写入值刷新 cache，
    /// 写派生常量会反过来污染真相源），关键词来自决策本身。
    public func writeback(
        sessionId: String,
        target: CullingWritebackTarget,
        confirmed: Bool
    ) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackConfirmRequired }
        let decisions = try getDecisions(sessionId: sessionId).filter { $0.decision != "pending" }
        if decisions.isEmpty { throw CullingServiceError.noDecisions }
        let plan = try buildCullingWritebackPlan(decisions: decisions, target: target)
        if plan.isEmpty { throw CullingServiceError.noDecisions }

        let decidedPhotoIds = Set(plan.keys)
        let preview = try await writeback.preview(
            sessionId: sessionId,
            module: "culling",
            options: WritebackOptions(),
            photoIds: decidedPhotoIds,
            keywordAdditions: nil
        )
        var matchingItems = preview.items.filter { decidedPhotoIds.contains($0.photoId) }
        for index in matchingItems.indices {
            guard let attributes = plan[matchingItems[index].photoId],
                  matchingItems[index].id != nil else { continue }
            if let keywords = attributes.keywords {
                // TS: { keywords: [...new Set([...item.keywords, ...attributes.keywords])] }
                var merged: [String] = []
                for value in matchingItems[index].keywords + keywords
                where !merged.contains(value) {
                    merged.append(value)
                }
                matchingItems[index].attributes = WritebackAttributes(keywords: merged)
            } else {
                matchingItems[index].attributes = attributes
            }
        }
        try writeback.persistAttributes(items: matchingItems)
        var result = try await writeback.execute(sessionId: sessionId, module: "culling", items: matchingItems)
        // S5c-2b-1 过渡双写：XMP 已落盘，镜像失败不回滚文件，只把错误并入结果。
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId,
            executedIds: Set(matchingItems.compactMap(\.id)),
            fallbackItems: matchingItems,
            result: result
        )
        result.errors.append(contentsOf: mirrorErrors)
        return result
    }
    /// TS: culling.retry_failed_writeback（confirmed 必须为 true，否则
    /// WRITEBACK_RETRY_CONFIRM_REQUIRED）。
    ///
    /// 先记下「本次要重试的失败项 id」：retryFailed 只返回计数，镜像靠这些 id 收敛
    /// 范围，避免把早已 written 的旧项也推进一次 revision。
    public func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackRetryConfirmRequired }
        let failedBefore: [Int]
        do {
            failedBefore = try writeback.getItems(
                sessionId: sessionId, module: "culling", status: "failed"
            ).compactMap(\.id)
        } catch {
            // 读不到失败集就不能安全收敛镜像范围：宁可不镜像，也不把旧 written 项再推一次 revision。
            GatherLogger.log(
                "culling retry mirror: failed to read failed items (\(sessionId)): \(error)",
                level: .warn
            )
            failedBefore = []
        }
        var result = try await writeback.retryFailed(sessionId: sessionId, module: "culling")
        guard !failedBefore.isEmpty else { return result }
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId,
            executedIds: Set(failedBefore),
            fallbackItems: [],
            result: result
        )
        result.errors.append(contentsOf: mirrorErrors)
        return result
    }
    /// 写回执行结果 → 交付镜像（S5c-2b-1 过渡双写）。
    ///
    /// 状态取执行器写进 delivery_items 的持久化行（getItems 已改读交付表）；
    /// 取不到时按 result.failedItems + result.written 推断（测试替身/无行场景）。
    /// 基线与备份直接回读 deliveries 行（S5c-2b-3b-2a 起执行器自己落库），
    /// 不再有任何 outbox 抄写。
    private func mirrorWritebackOutcome(
        sessionId: String,
        executedIds: Set<Int>,
        fallbackItems: [WritebackItem],
        result: WritebackResult
    ) -> [String] {
        var persistedById: [Int: WritebackItem] = [:]
        do {
            for row in try writeback.getItems(sessionId: sessionId, module: "culling", status: nil) {
                if let id = row.id { persistedById[id] = row }
            }
        } catch {
            // 旧表读失败时退回 result 的失败集/计数推断；镜像缺失会进 errors，不静默。
            GatherLogger.log(
                "culling writeback mirror: failed to read persisted items (\(sessionId)): \(error)",
                level: .warn
            )
        }
        var fallbackById: [Int: WritebackItem] = [:]
        for item in fallbackItems {
            if let id = item.id, executedIds.contains(id) {
                fallbackById[id] = item
            }
        }

        var mirrorItems: [DeliveryWritebackMirrorItem] = []
        for id in executedIds.sorted() {
            let persisted = persistedById[id]
            let candidate = persisted ?? fallbackById[id]
            guard let candidate else { continue }
            let failedResult = result.failedItems.first { $0.id == id }
            let status: DeliveryItemStatus
            switch persisted?.xmpStatus ?? "" {
            case "written":
                status = .written
            case "failed":
                status = .failed
            default:
                if failedResult != nil {
                    status = .failed
                } else if result.written > 0, persisted == nil {
                    status = .written
                } else {
                    // pending（未执行）或无法判定：不镜像，避免谎报写入。
                    continue
                }
            }
            var errorMessage = ""
            if status == .failed {
                if let message = persisted?.errorMessage, !message.isEmpty {
                    errorMessage = message
                } else if let failedResult, !failedResult.errorMessage.isEmpty {
                    errorMessage = failedResult.errorMessage
                } else {
                    errorMessage = result.errors.first {
                        $0.hasPrefix("\(id):") || $0.hasPrefix(candidate.photoPath)
                    } ?? "WRITEBACK_FAILED"
                }
            }

            // S5c-2b-3b-2a：基线/备份以执行器刚写进 deliveries 的行为准（execute
            // 已直接落 base_fingerprint/base_values/backup_path），不再从 outbox 抄。
            let deliveryRow = try? deliveryItems.getItem(xmpPath: candidate.xmpPath)
            let baseValues = deliveryRow?.baseValues ?? .object([:])
            var attributes: [String: JSONValue] = [:]
            if let rating = candidate.attributes?.rating {
                attributes["rating"] = .number(rating)
            }
            if let label = candidate.attributes?.label {
                attributes["label"] = .string(label)
            }
            let keywords = candidate.attributes?.keywords ?? candidate.keywords
            mirrorItems.append(DeliveryWritebackMirrorItem(
                photoId: candidate.photoId,
                photoPath: candidate.photoPath,
                xmpPath: candidate.xmpPath,
                keywords: keywords,
                attributes: attributes,
                status: status,
                errorMessage: errorMessage,
                backupPath: deliveryRow.flatMap { $0.backupPath.isEmpty ? nil : $0.backupPath }
                    ?? candidate.backupPath,
                baseFingerprint: deliveryRow?.baseFingerprint ?? "",
                baseValues: baseValues
            ))
        }

        do {
            let summary = try delivery.mirrorCullingWriteback(
                sessionId: sessionId, items: mirrorItems
            )
            return summary.errors
        } catch {
            return ["DELIVERY_MIRROR_FAILED: \(error)"]
        }
    }
    // MARK: - 确认 / 清理 / 收尾（Cut 2：接 DeliveryCoordinator，module = .culling）

    /// TS: culling.confirm_sync —— 交付确认（门禁读 + 单事务状态推进）。
    ///
    /// 旧链路（metadataSync.confirmSync + writeback.confirmSync）已由
    /// DeliveryCoordinator 取代；不再写 sessions.writeback_status（D-021，V1 已删列）。
    /// 错误语义保持旧 UI 认得的码：
    /// - 门禁不完整（pending/writing/failed/conflict）→ XMP_CONFIRM_INCOMPLETE；
    /// - 未 ack reload（§5.4-2）→ XMP_CONFIRM_REQUIRES_SYNC；
    /// - 跨会话未确认 → XMP_CONFIRM_OTHER_SESSION_PENDING:<sessionId>
    ///   （本会话 confirmed_at 已先落地，交付留在 written 等对方确认）。
    public func confirmSync(sessionId: String) async throws {
        _ = try confirmDelivery(sessionId: sessionId)
    }

    /// TS: culling.cleanup（confirmed 必须为 true，否则
    /// WRITEBACK_CLEANUP_CONFIRM_REQUIRED）。
    ///
    /// 由 DeliveryCoordinator 清理（module=.culling）——外部修改的交付标 conflict、
    /// 不恢复、不删行；文件/DB 失败保留 intent，下次 replay 可重试。
    /// 旧的「metadataSync.cleanup + writeback.cleanup 两路合并」已移除；
    /// S5c-2b-1 起 writeback 结果也已镜像到 delivery_items（过渡双写），
    /// 旧表和 execute 执行器在 S5c-2b-3 删除。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        guard confirmed else { throw CullingServiceError.writebackCleanupConfirmRequired }
        let summary = try await delivery.cleanupCulling(sessionId: sessionId)
        return Self.cleanupResult(from: summary)
    }

    /// culling 确认的唯一出口（confirm 门禁错误 → 旧码；finalize 走同一 coordinator）。
    private func confirmDelivery(sessionId: String) throws -> DeliveryConfirmSummary {
        let summary: DeliveryConfirmSummary
        do {
            summary = try delivery.confirmCulling(sessionId: sessionId)
        } catch let error as DeliveryCoordinatorError {
            if case .confirmIncomplete(let blockers) = error {
                // 旧码保持可读；阻断项进日志（UI 文案只认码值）。
                GatherLogger.log(
                    "culling confirm blocked (\(sessionId)): " + blockers.joined(separator: ","),
                    level: .warn
                )
                throw DeliveryError.confirmIncomplete
            }
            if case .reloadNotAcknowledged = error {
                // §5.4-2：Capture One 未确认重载 → 旧 UI 认得的"还不能收口"码。
                throw DeliveryError.confirmRequiresSync
            }
            throw error
        }
        if let blocker = summary.unconfirmedSessionIds.first {
            throw DeliveryError.otherSessionNotConfirmed(sessionId: blocker)
        }
        return summary
    }

    /// DeliveryCleanupSummary → 旧 CleanupResult（协议/UI 契约不变）。
    /// - errors 原样保留（可重试失败，intent 已保留）；
    /// - 外部修改冲突按路径回填 XMP_EXTERNALLY_MODIFIED（旧链路 throw
    ///   externallyModified 产生的同码文案），用户仍能看到哪些侧车被改过。
    private static func cleanupResult(from summary: DeliveryCleanupSummary) -> CleanupResult {
        var errors = summary.errors
        for path in summary.conflictedXmpPaths {
            errors.append(
                MetadataWritebackFailure.from(
                    DeliveryError.externallyModified,
                    xmpPath: path
                ).description
            )
        }
        return CleanupResult(deletedCount: summary.deletedCount, errors: errors)
    }
    /// culling 写回计划：决策集 → 每照片的目标属性。
    /// 评分/色标的值来自唯一真相源 photo_metadata_cache；关键词来自决策本身。
    private func buildCullingWritebackPlan(
        decisions: [CullingDecisionLiteRow],
        target: CullingWritebackTarget
    ) throws -> [String: WritebackAttributes] {
        var cacheByPhoto: [String: MetadataCacheRow] = [:]
        if target != .keyword {
            cacheByPhoto = Dictionary(
                uniqueKeysWithValues: try metadataCacheRepo
                    .getBatch(decisions.map(\.photoId))
                    .map { ($0.photoId, $0) }
            )
        }
        var plan: [String: WritebackAttributes] = [:]
        for decision in decisions {
            switch target {
            case .rating:
                let cache = cacheByPhoto[decision.photoId]
                let rating = Swift.min(5, Swift.max(0, cache?.rating ?? 0))
                plan[decision.photoId] = WritebackAttributes(rating: Double(rating))
            case .colorLabel:
                let label = Self.colorLabel(cacheByPhoto[decision.photoId]?.label)
                // 写盘标签语义：None → 空串（清空色标），与 culling.update 一致。
                plan[decision.photoId] = WritebackAttributes(
                    label: label == .none ? "" : label.rawValue
                )
            case .keyword:
                plan[decision.photoId] = WritebackAttributes(
                    keywords: ["culling:\(decision.decision)"]
                )
            }
        }
        return plan
    }
}
