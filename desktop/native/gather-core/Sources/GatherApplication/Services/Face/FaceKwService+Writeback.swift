// WP5b：FaceKwService 拆分（纯移动，行为不变）——Writeback（写回/确认/清理）。
// 源：HEAD 95f0075 的 Services/FaceKwService.swift；仅调整跨文件访问级。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension FaceKwService {
    // ─────────────────────────── 写回（经注入 Provider） ───────────────────────────

    /// TS: face-kw.ipc.ts fkw.preview。
    public func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?
    ) async throws -> FaceKwWritebackPreview {
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
        let additions = Self.buildFaceKeywordAdditions(clusters)
        let boundPhotoIds = Set(additions.keys)
        return try await writebackProvider.preview(
            sessionId: sessionId,
            options: options,
            boundPhotoIds: boundPhotoIds,
            additions: additions
        )
    }

    /// TS: face-kw.ipc.ts fkw.writeback。
    ///
    /// S5c-2b-2：旧写盘路径不变（provider.execute），执行后按 xmpPath 把结果镜像进
    /// deliveries / delivery_items（module=.faceKeyword，status written/failed，
    /// revision/base 与 Culling 同一规则）。XMP 已落盘：镜像失败不回滚文件，
    /// 只把错误并入返回的 errors。
    public func writeback(
        sessionId: String,
        confirmed: Bool,
        items: [FaceKwWritebackItem]?
    ) async throws -> FaceKwWritebackResult {
        guard confirmed else { throw FaceKwServiceError.writebackConfirmRequired }
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        // TS 的 FKW_ITEMS_INVALID（Array.isArray 校验）属 JSON 契约层职责；
        // Swift 参数类型已强约束（nil 等价 TS 的 `params.items ?? []`）。
        let resolved = items ?? []
        let result = try await writebackProvider.execute(sessionId: sessionId, items: resolved)
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId, items: resolved, result: result
        )
        guard !mirrorErrors.isEmpty else { return result }
        var merged = result
        merged.errors.append(contentsOf: mirrorErrors)
        return merged
    }

    /// TS: face-kw.ipc.ts fkw.confirm_sync（返回 ok(true)）。
    ///
    /// S5c-2b-2 起由 DeliveryCoordinator 确认（module=.faceKeyword）：
    /// 门禁读 + 单事务推进；不再写 sessions.writeback_status（D-021）。
    /// 错误码保持旧 UI 认得的 XMP_CONFIRM_INCOMPLETE / XMP_CONFIRM_REQUIRES_SYNC /
    /// XMP_CONFIRM_OTHER_SESSION_PENDING（见 confirmDelivery）。
    public func confirmSync(sessionId: String) async throws -> Bool {
        _ = try confirmDelivery(sessionId: sessionId)
        return true
    }

    /// TS: face-kw.ipc.ts fkw.confirm_cleanup / fkw.cleanup。
    ///
    /// S5c-2b-2 起由 DeliveryCoordinator 清理（module=.faceKeyword）：
    /// 外部修改的交付标 conflict、不恢复、不删行；文件/DB 失败保留 intent。
    /// 本域没有 flush/retry_sync 命令，cleanup 是唯一的用户重试入口，因此先回放
    /// 未完成的 intent（失败只记日志，不阻断本次清理）。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> FaceKwCleanupResult {
        guard confirmed else { throw FaceKwServiceError.cleanupConfirmRequired }
        await replayPendingDeliveries(reason: "face_kw cleanup", sessionId: sessionId)
        let summary = try await delivery.cleanup(sessionId: sessionId)
        return Self.cleanupResult(from: summary)
    }

    // MARK: - 交付（Cut 2 / S5c-2b-2）

    /// confirm 的唯一出口：coordinator 错误 → 旧码。
    private func confirmDelivery(sessionId: String) throws -> DeliveryConfirmSummary {
        let summary: DeliveryConfirmSummary
        do {
            summary = try delivery.confirm(sessionId: sessionId)
        } catch let error as DeliveryCoordinatorError {
            switch error {
            case .confirmIncomplete(let blockers):
                // 旧码保持可读；阻断项进日志（UI 文案只认码值）。
                GatherLogger.log(
                    "face_kw confirm blocked (\(sessionId)): " + blockers.joined(separator: ","),
                    level: .warn
                )
                throw DeliveryError.confirmIncomplete
            case .reloadNotAcknowledged:
                // §5.4-2：Capture One 未确认重载 → 旧 UI 认得的"还不能收口"码。
                throw DeliveryError.confirmRequiresSync
            default:
                throw error
            }
        }
        if let blocker = summary.unconfirmedSessionIds.first {
            // 本会话 confirmed_at 已先落地；交付留在 written 等对方确认（旧语义）。
            throw DeliveryError.otherSessionNotConfirmed(sessionId: blocker)
        }
        return summary
    }

    /// DeliveryCleanupSummary → 旧 FaceKwCleanupResult（协议/UI 契约不变）。
    /// 外部修改冲突按路径回填 XMP_EXTERNALLY_MODIFIED（旧链路 throw externallyModified
    /// 的同码文案），可重试失败保留在 errors。
    private static func cleanupResult(from summary: DeliveryCleanupSummary) -> FaceKwCleanupResult {
        var errors = summary.errors
        for path in summary.conflictedXmpPaths {
            errors.append(
                MetadataWritebackFailure.from(
                    DeliveryError.externallyModified,
                    xmpPath: path
                ).description
            )
        }
        return FaceKwCleanupResult(deletedCount: summary.deletedCount, errors: errors)
    }

    /// cleanup 前的 intent 回放（本域无 flush 命令）。失败只记日志：
    /// 未完成的 intent 仍由 cleanup 的 INTENT_PENDING 跳过保护，不会静默丢。
    private func replayPendingDeliveries(reason: String, sessionId: String) async {
        do {
            let replay = try await delivery.engine.replay()
            for error in replay.errors {
                GatherLogger.log("\(reason) replay (\(sessionId)): \(error)", level: .warn)
            }
        } catch {
            GatherLogger.log("\(reason) replay (\(sessionId)): \(error)", level: .warn)
        }
    }

    /// 写回执行结果 → 交付镜像（S5c-2b-2 过渡双写）。
    ///
    /// S5c-2b-3b-2b-1：状态/属性改读 delivery_items（执行器已把行更新为
    /// written/failed），旧 writeback_items 不再读取；无交付行时按
    /// failedItems + result.written 推断（测试替身/无行场景）。
    /// 基线与备份直接回读 deliveries 行（执行器已落库），不再抄 outbox。
    private func mirrorWritebackOutcome(
        sessionId: String,
        items: [FaceKwWritebackItem],
        result: FaceKwWritebackResult
    ) -> [String] {
        guard !items.isEmpty else { return [] }
        let deliveryRepo = deliveryItems
        var persistedById: [Int64: DeliveryItemRow] = [:]
        let executedIds = Set(items.compactMap(\.id))
        if !executedIds.isEmpty {
            do {
                // 一次按会话读，再按本次执行的 id 收窄（避免逐项 N+1 查询）。
                for row in try deliveryRepo.listItems(sessionId: sessionId, module: .faceKeyword)
                where executedIds.contains(row.id) {
                    persistedById[row.id] = row
                }
            } catch {
                GatherLogger.log(
                    "face_kw writeback mirror: delivery items unavailable (\(sessionId)): \(error)",
                    level: .debug
                )
            }
        }

        var mirrorItems: [DeliveryWritebackMirrorItem] = []
        for item in items {
            // 无 id = 未执行（execute 对无 id 项同样 skipped），不镜像避免谎报写入。
            guard let id = item.id else { continue }
            let row = persistedById[id]
            let failedItem = result.failedItems.first { $0.id == id }
            let status: DeliveryItemStatus
            switch row?.status ?? failedItem?.xmpStatus ?? "" {
            case "written": status = .written
            case "failed": status = .failed
            default:
                if failedItem != nil {
                    status = .failed
                } else if result.written > 0 {
                    status = .written
                } else {
                    continue
                }
            }
            var errorMessage = ""
            if status == .failed {
                errorMessage = [row?.errorMessage, failedItem?.errorMessage]
                    .compactMap { $0 }
                    .first { !$0.isEmpty }
                    ?? result.errors.first {
                        $0.hasPrefix(item.photoPath) || $0.hasPrefix("\(id):")
                    }
                    ?? "WRITEBACK_FAILED"
            }

            // WP3b-2：基线经 Persistence 端口回读（与 deliveryWritebackBaseline 同口径）。
            let baseline = deliveryItems.itemBaseline(xmpPath: item.xmpPath)
            var attributes: [String: JSONValue] = [:]
            var parsedAttributes = false
            if let raw = row?.attributesJSON, !raw.isEmpty {
                do {
                    if case .object(let dict) = try JSONValue.parse(raw) {
                        // keywords 单列写，不重复进 attributes（与 Culling 镜像同口径）。
                        attributes = dict.filter { $0.key != "keywords" }
                        parsedAttributes = true
                    }
                } catch {
                    GatherLogger.log(
                        "face_kw writeback mirror: invalid attributes_json (\(item.xmpPath)): \(error)",
                        level: .debug
                    )
                }
            }
            if !parsedAttributes {
                if let rating = item.attributes?.rating { attributes["rating"] = .number(rating) }
                if let label = item.attributes?.label { attributes["label"] = .string(label) }
            }

            mirrorItems.append(DeliveryWritebackMirrorItem(
                photoId: item.photoId,
                photoPath: item.photoPath,
                xmpPath: item.xmpPath,
                keywords: Self.orderedUnion(item.keywords, item.attributes?.keywords ?? []),
                attributes: attributes,
                status: status,
                errorMessage: errorMessage,
                backupPath: baseline.backupPath.isEmpty ? item.backupPath : baseline.backupPath,
                baseFingerprint: baseline.baseFingerprint,
                baseValues: baseline.baseValues
            ))
        }

        guard !mirrorItems.isEmpty else { return [] }
        do {
            return try delivery.mirrorWriteback(
                sessionId: sessionId, items: mirrorItems
            ).errors
        } catch {
            return ["DELIVERY_MIRROR_FAILED: \(error)"]
        }
    }

    /// 有序并集（现有在前、新增去重追加），镜像 keywords 用。
    private static func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var merged: [String] = []
        for value in lhs + rhs where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    /// TS: buildFaceKeywordAdditions（fkw.preview 的写回规划）。
    public static func buildFaceKeywordAdditions(_ clusters: [FaceClusterRow]) -> [String: [String]] {
        var additions: [String: [String]] = [:]
        for cluster in clusters {
            guard let binding = cluster.binding else { continue }
            var seen = Set<String>()
            let keywords = ([binding.roleName] + binding.keywords)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            for member in cluster.members ?? [] {
                var merged = additions[member.photoId] ?? []
                for keyword in keywords where !merged.contains(keyword) {
                    merged.append(keyword)
                }
                additions[member.photoId] = merged
            }
        }
        return additions
    }
}
