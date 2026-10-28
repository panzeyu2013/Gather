// desktop/native/gather-core/Sources/GatherDelivery/Writeback/WritebackService.swift
// TS 源: desktop/src/main/services/writeback/writeback.service.ts（630 行）+
// writeback-planners.ts（66 行），逐字移植
//
// 写回服务：preview/execute/retryFailed/confirmSync/cleanup 全量语义对齐
// writeback.ipc.ts 形状（culling.writeback / culling.retry_failed_writeback /
// culling.confirm_sync / culling.cleanup 均经本服务）。
// **持久化层（Cut 2 / S5c-2b-3a）**：状态机从旧 writeback_items/outbox 改为统一交付
// 模型（deliveries / delivery_items / delivery_sessions，D-013 / D-060 / D-082）：
// - preview 写交付行（createOrGet + upsertItem(pending) + linkSession）；
// - persistAttributes/persistKeywords 更新 delivery_items 的 attributes_json/keywords；
// - execute 从 delivery_items 读 pending/failed 项，逐项 markItem(written/failed)，
//   交付行 pending/failed → writing → written/failed（迁移表 + revision CAS）；
//   写盘前用 XMPProvider.backup 取真实备份，flush 后回读属性 + MetadataFingerprint，
//   把 backup_path/base_fingerprint/base_values 直接写进 deliveries（S5c-2b-3b-1），
//   不再留空等过渡期 outbox 镜像；
// - retryFailed 从 delivery_items 读 failed 项重放（沿用交付行上的旧备份）；
// - 不再写 writeback_items / metadata_outbox（旧表随 S5c-2b-3b-2 删除）。
//
// **去 sync 端口（Cut 2 / S5c-2b-3b-2a）**：本服务不再依赖 MetadataSyncPort。
// - 写盘在 execute 的 Phase 1 内**同步**完成（读当前属性 → 按磁盘现状合并关键词 →
//   xmp.writeAttributes → 回读属性/指纹），不再「先入 outbox、后 flushSession」；
//   因此 waitForIdle 没有等待对象，flushSession 只回读交付摘要
//   （DeliverySummaryQuery.metadataSummary）。
// - confirmSync 委托 DeliveryCoordinator.confirm：完整性/reload-ack 门禁与
//   confirmed_at 更新在同一个事务（P1-3）；本服务不再有绕过门禁的确认旁路。
// - cleanup 委托 DeliveryCoordinator.cleanup（module 作用域 + intent 前滚）。
//
// 注入点：
// - XMPProvider = TS writerRouter.selectSidecar()（XMP 读写，host 实现）——唯一写盘面。
// - DeliveryCoordinator = cleanup/finalize 的交付编排（同一 connection 的默认实例可由
//   connection + xmp 自建，宿主注入共享实例时以注入为准）。
// - XMPFileLock = 与 DeliveryCoordinator 共用的按 xmpPath 文件锁（P0-1 TOCTOU）：
//   execute 每个交付组的 backup/read/writeAttributes 与 cleanup restore/remove 互斥；
//   生产由 AppComposition 注入同一实例，缺省 .shared。
// - C1 相关：本服务不直接触碰 Capture One（reload-ack 由宿主侧直接写
//   sessions.reload_acked_at）。
//
// 拆分（final-sweep-code P1-1 / 纯移动）：按角色拆到同级
// WritebackService+{Execute,Recover,Converge,Helpers}.swift；本文件只留
// 存储属性 / init / 公共入口（reopenDeliveryForInput 为 preview 专用私有辅助）。
// 方法体、错误码、事务与顺序均未改。

import Foundation
import GatherPersistence
import GatherProtocol

/// TS: WritebackService。
/// 线程安全说明（Swift 6 `Sendable`）：本类无任何可变状态——全部存储属性
/// （`deliveryRepo`/xmp/`photoRepo`/`metadataCacheRepo`/`delivery`/
/// `summaryQuery`/`keywordOrigins`/`assetResolver`）都是 `let`，构造后不可变，
/// 故无需锁。标注 `@unchecked` 仅因为依赖仓库/协议存在类型未标 `Sendable`；
/// execute 的并发收集状态全部收在 PhaseOneCollector 的锁内。
public final class WritebackService: @unchecked Sendable {
    let deliveryRepo: DeliveryRepo
    /// 交付状态写入的唯一入口（WP2b）；读路径仍直接用 deliveryRepo。
    let stateWriter: DeliveryStateWriter
    let xmp: any XMPProvider
    /// R8：只读投影 / 三字段回写走窄端口；具体 Repo 只在组合根构造。
    private let photoRepo: any PhotoReadStore
    let metadataCacheRepo: any MetadataCacheStore
    let keywordOrigins: MetadataKeywordOriginRepo?
    let assetResolver: PhotoAssetResolver?
    let connection: DBConnection
    /// cleanup 的交付编排（intent 前滚 + 文件恢复）；宿主注入共享实例，
    /// 缺省按同一 connection/xmp 自建（测试/嵌入场景）。
    private let delivery: DeliveryCoordinator
    /// 与 DeliveryCoordinator 共用的按 xmpPath 文件锁（P0-1 TOCTOU 收口）：
    /// 同一交付组的 backup/read/writeAttributes 与 cleanup restore/remove 互斥。
    let fileLock: XMPFileLock
    /// flushSession 的只读投影（不再有调度语义）。
    private let summaryQuery: DeliverySummaryQuery
    /// 交付状态变化后的会话级通知：宿主据此刷新 C1 同步徽标。
    /// 旧 MetadataSyncCoordinator 的 eventSink 等价物（2b-3 删除旧协调器后仍能推送）。
    let eventSink: (@Sendable (String) -> Void)?
    /// 本服务实例的写租约 owner（P1-2）：进程内稳定，跨 execute 复用同一身份，
    /// 崩溃后新进程会拿到新 owner，只能等旧 heartbeat 过期后抢占。
    let leaseOwner: String

    public init(
        deliveryRepo: DeliveryRepo,
        xmp: any XMPProvider,
        photoRepo: any PhotoReadStore,
        metadataCacheRepo: any MetadataCacheStore,
        connection: DBConnection,
        keywordOrigins: MetadataKeywordOriginRepo? = nil,
        assetResolver: PhotoAssetResolver? = nil,
        delivery: DeliveryCoordinator? = nil,
        fileLock: XMPFileLock,
        eventSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.deliveryRepo = deliveryRepo
        self.stateWriter = DeliveryStateWriter(repo: deliveryRepo)
        self.xmp = xmp
        self.photoRepo = photoRepo
        self.metadataCacheRepo = metadataCacheRepo
        self.connection = connection
        self.keywordOrigins = keywordOrigins
        self.assetResolver = assetResolver
        self.eventSink = eventSink
        self.fileLock = fileLock
        self.leaseOwner = "writeback-" + newUUIDString()
        self.delivery = delivery ?? DeliveryCoordinator(
            connection: connection, xmp: xmp, fileLock: fileLock, eventSink: eventSink)
        self.summaryQuery = DeliverySummaryQuery(connection: connection)
    }

    /// preview 的交付重开：交付行已是 written/synced/failed/conflict 时按「新输入」语义
    /// 回到 pending（revision + 1，基线保持不变），否则 execute 抢不到写租约。
    /// cleaned 是审计终态（D-031），不可重开：保留原状态，execute 会逐项显式失败上报。
    private func reopenDeliveryForInput(xmpPath: String, photoPath: String) throws {
        guard let current = try deliveryRepo.get(xmpPath) else { return }
        switch current.typedStatus {
        case .some(.pending), .some(.writing), .some(.cleaned), .none:
            return
        case .some(.written), .some(.synced), .some(.failed), .some(.conflict):
            _ = try stateWriter.mergeInput(
                xmpPath: xmpPath,
                photoPath: photoPath.isEmpty ? current.photoPath : photoPath,
                expectedRevision: current.revision,
                newRevision: current.revision + 1,
                baseFingerprint: current.baseFingerprint,
                baseValues: current.baseValues
            )
        }
    }

    // MARK: - 公开 API（对齐 writeback.ipc.ts 形状）

    /// TS: preview —— 重建交付项（deliveries/delivery_items）；module != culling 时
    /// 先丢弃本模块陈旧的 pending/failed 项（否则下次 execute 会把旧关键词并进新 patch）。
    public func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions = WritebackOptions(),
        photoIds: Set<String>? = nil,
        keywordAdditions: [String: [String]]? = nil
    ) async throws -> WritebackPreview {
        let deliveryModule = try mapModule(module)
        try assertNoActiveOtherModule(sessionId: sessionId, module: module)

        // 轻投影：preview 只需要照片身份与 filepath，重 JSON 列从不读取。
        // P2：已移出工作区的照片不属于写回范围——与"移出=不导出"同一口径，
        // 否则预览里的"将写回 N 张"仍把 _rejects 里的照片算进来。
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }
        let filtered = photoIds.map { ids in photos.filter { ids.contains($0.id) } } ?? photos

        // 与 execute 完全相同的资产解析：asset_read_mode='asset' 且 relink 后，
        // 照片行的遗留 filepath/sidecar 与 PhotoAssetResolver.resolve() 返回不同，
        // preview/execute 不一致会让每个项永久失败。
        let resolvedByPhoto = try resolvePreviewTargets(
            sessionId: sessionId,
            photos: filtered.map { (id: $0.id, filepath: $0.filepath) }
        )
        var additionsBySidecar: [String: [String]] = [:]
        var sharedCounts: [String: Int] = [:]
        for photo in filtered {
            let sidecarPath = resolvedByPhoto[photo.id]?.xmpPath ?? ""
            sharedCounts[sidecarPath, default: 0] += 1
            additionsBySidecar[sidecarPath] = orderedUnion(
                additionsBySidecar[sidecarPath] ?? [],
                keywordAdditions?[photo.id] ?? []
            )
        }

        // 按侧车去重（首见照片保留，与 TS uniquePhotos 一致）。
        var targetSidecars: [String] = []
        var firstPhotoBySidecar: [String: (id: String, filepath: String)] = [:]
        var seenSidecars = Set<String>()
        for photo in filtered {
            let sidecarPath = resolvedByPhoto[photo.id]?.xmpPath ?? ""
            guard seenSidecars.insert(sidecarPath).inserted else { continue }
            targetSidecars.append(sidecarPath)
            firstPhotoBySidecar[sidecarPath] = (photo.id, photo.filepath)
        }
        let targetSet = Set(targetSidecars)

        // 旧 saveItems 的 DELETE 语义：本 (session, module) 下已不在本次计划里的
        // pending/failed 项必须丢弃，否则旧计划项会永久停在 pending。
        for row in try deliveryRepo.listItems(sessionId: sessionId, module: deliveryModule) {
            guard row.typedStatus == .pending || row.typedStatus == .failed else { continue }
            guard !targetSet.contains(row.xmpPath) else { continue }
            _ = try stateWriter.deleteItems(
                xmpPath: row.xmpPath, module: deliveryModule, statuses: [.pending, .failed])
        }

        var previewsBySidecar: [String: WritebackItemPreview] = [:]
        for sidecarPath in targetSidecars {
            guard let photo = firstPhotoBySidecar[sidecarPath] else { continue }
            var existingKeywords: [String] = []
            do {
                existingKeywords = try await xmp.readKeywords(photoPath: photo.filepath)
            } catch {
                // 缺失侧车 = 空；读取失败必须可见（否则会把外部关键词静默当空列表）。
                if xmp.fileExists(sidecarPath) {
                    // P2-5：非 trace 日志也不能输出绝对路径；basename#hash 保留定位能力。
                    GatherLogger.log(
                        "Writeback preview keyword read failed for "
                            + "\(DeliveryTrace.pathToken(sidecarPath)): "
                            + DeliveryTrace.reason(error, paths: [sidecarPath]),
                        level: .warn)
                }
            }
            // 旧 outbox 的 externalChanged 信号等价物：交付处于 conflict。
            let externalChanged = (try deliveryRepo.get(sidecarPath))?.typedStatus == .conflict
            _ = try stateWriter.createOrGet(xmpPath: sidecarPath, photoPath: photo.filepath)
            try reopenDeliveryForInput(xmpPath: sidecarPath, photoPath: photo.filepath)
            _ = try stateWriter.deleteItems(
                xmpPath: sidecarPath, module: deliveryModule, statuses: [.pending, .failed])
            let merged = orderedUnion(existingKeywords, additionsBySidecar[sidecarPath] ?? [])
            _ = try stateWriter.upsertItem(
                xmpPath: sidecarPath,
                photoId: photo.id,
                module: deliveryModule,
                keywords: merged,
                status: .pending
            )
            _ = try stateWriter.linkSession(xmpPath: sidecarPath, sessionId: sessionId)
            previewsBySidecar[sidecarPath] = WritebackItemPreview(
                dirtyFields: [.keywords],
                before: WritebackAttributes(keywords: existingKeywords),
                after: WritebackAttributes(keywords: merged),
                source: module,
                sharedPhotoCount: sharedCounts[sidecarPath] ?? 1,
                externalChanged: externalChanged,
                willCreate: !xmp.fileExists(sidecarPath)
            )
        }

        let pendingEntries = try loadEntries(
            sessionId: sessionId, module: deliveryModule, status: .pending)
        let previewItems = pendingEntries.map { entry -> WritebackItem in
            var item = entryToItem(entry, sessionId: sessionId)
            item.preview = previewsBySidecar[item.xmpPath]
            return item
        }
        return WritebackPreview(
            items: previewItems,
            totalCount: pendingEntries.count,
            affectedPhotos: filtered.count
        )
    }


    /// 按需执行入口（P1-9）：加载本会话/模块下 **pending + failed** 交付项，
    /// 原样交给 `execute` 完成写盘与状态推进（不复制任何写盘/租约逻辑）。
    ///
    /// 关键词队列（module=metadata）在 applyKeywords / retryKeywordWriteback 成功
    /// 后经宿主注入的闭包调用本入口；失败的项由 execute 落 failed（可重试），下次
    /// 调用 executePending 会连同 pending 一起再次消费。
    public func executePending(
        sessionId: String, module: String, includeFailed: Bool = false
    ) async throws -> WritebackResult {
        let deliveryModule = try mapModule(module)
        var items: [WritebackItem] = []
        // 已入队的项即使照片随后被移出（archived_at）**仍然写完**：写回队列是用户在
        // preview 时点下的显式动作，文件与侧车一起被搬到 _rejects，写进去不会丢数据；
        // 中途撤回会让 pending 项永远悬着（进度/失败聚合卡死）。可见性只约束
        // preview 的目标集合（见 preview 的归档过滤）与用户读面。
        // 默认只消费 pending：failed 必须由显式 retry 入口重试，否则用户已看到
        // "失败"的项会在一段时间后被无关 flush 静默写盘（模板/triage 批次的撤销
        // 入口可能已被关闭）。
        let statuses: [DeliveryItemStatus] = includeFailed ? [.pending, .failed] : [.pending]
        for status in statuses {
            items.append(contentsOf: try loadEntries(
                sessionId: sessionId, module: deliveryModule, status: status
            ).map { entryToItem($0, sessionId: sessionId) })
        }
        guard !items.isEmpty else {
            // 没有待写项也要做一次崩溃归位（P1-2）：否则 execute 在 markItem 与
            // markWritten 之间崩溃后，手动队列没有任何入口能把 writing 收口。
            let entries = try loadEntries(sessionId: sessionId, module: deliveryModule)
            let recovered = await recoverInterruptedWrites(
                sessionId: sessionId, entries: entries)
            if recovered.written + recovered.failed > 0 {
                emitStateChanged(sessionId)
            }
            return WritebackResult(
                totalAffected: recovered.written + recovered.failed,
                written: recovered.written,
                failed: recovered.failed,
                skipped: 0,
                errors: recovered.errors,
                failedItems: [],
                report: "No pending items to execute"
            )
        }
        return try await execute(sessionId: sessionId, module: module, items: items)
    }


    /// TS: removeOwnedFaceKeywords —— 撤销本模块引入的人脸关键词（按 origin 表
    /// 过滤后再移除，避免误删外部软件写入的关键词）；返回实际移除的关键词列表
    /// （TS removedKeywords 语义；无 origin 表注入时返回空数组）。
    public func removeOwnedFaceKeywords(
        sessionId: String,
        entries: [(photoId: String, xmpPath: String, keywords: [String])]
    ) async throws -> [String] {
        guard let keywordOrigins else { return [] }
        var byPath: [String: (photoId: String, keywords: Set<String>)] = [:]
        for entry in entries {
            var current = byPath[entry.xmpPath] ?? (photoId: entry.photoId, keywords: Set<String>())
            for keyword in entry.keywords { current.keywords.insert(keyword) }
            byPath[entry.xmpPath] = current
        }
        // 直写（S5c-2b-3b-2a）：撤销不再经 outbox/协调器排队——逐侧车读当前
        // 属性、移除本模块引入的词、原子写回；写成功后才注销 origin 记录。
        var removed: [String] = []
        for (xmpPath, entry) in byPath.sorted(by: { $0.key < $1.key }) {
            let owned = try keywordOrigins.getActiveIntroduced(
                xmpPath: xmpPath,
                source: "face-keyword",
                keywords: Array(entry.keywords)
            )
            if owned.isEmpty { continue }
            let photoPath: String
            if let assetResolver,
               let resolved = try? assetResolver.resolve(sessionId: sessionId, photoId: entry.photoId) {
                photoPath = resolved.filepath
            } else {
                photoPath = Self.photoPathFromSidecar(xmpPath)
            }
            do {
                // 撤销同样是 XMP 写盘：与 cleanup restore/remove 及 execute
                // 写盘共用同一把 xmpPath 锁，避免读-改-写被覆盖。
                try await fileLock.run(path: xmpPath) {
                    var attributes = try await self.xmp.readAttributes(photoPath: photoPath)
                    let remove = Set(owned)
                    attributes.keywords = (attributes.keywords ?? []).filter { !remove.contains($0) }
                    try await self.xmp.writeAttributes(photoPath: photoPath, attributes: attributes)
                }
            } catch {
                throw WritebackServiceError.undoFaceFailedWithMessage(
                    MetadataWritebackFailure.from(error, xmpPath: xmpPath).description)
            }
            try keywordOrigins.deactivate(
                xmpPath: xmpPath, source: "face-keyword", keywords: owned)
            removed.append(contentsOf: owned)
        }
        return removed
    }

    /// TS: retryFailed —— 从交付项里读 failed 并重放（不重新 preview）。
    public func retryFailed(sessionId: String, module: String) async throws -> WritebackResult {
        let deliveryModule = try mapModule(module)
        let failedEntries = try loadEntries(
            sessionId: sessionId, module: deliveryModule, status: .failed)
        let items = failedEntries.map { entryToItem($0, sessionId: sessionId) }
        if items.isEmpty {
            return WritebackResult(
                totalAffected: 0, written: 0, failed: 0, skipped: 0,
                errors: [], failedItems: [],
                report: "No failed items to retry"
            )
        }
        return try await execute(sessionId: sessionId, module: module, items: items)
    }

    /// TS: confirmSync —— 失败项存在时拒绝；其余门禁与状态推进**委托**
    /// DeliveryCoordinator.confirm（P1-3）。
    ///
    /// 旧实现直接调 stateWriter.confirm，绕过了 reload-ack 与完整性门禁，是
    /// 一条公共确认旁路。现在本入口与 culling/face/sim 的生产确认路径完全同路：
    /// 完整性 + reload-ack + confirmed_at/状态更新都在 DeliveryRepo.confirm 的
    /// 同一个事务里，不存在"先写确认、后补门禁"的窗口。
    ///
    /// 失败项的旧码 WRITEBACK_FAILURES_PENDING 保留（UI/调用方兼容）；其余阻断
    /// 以 DeliveryCoordinatorError（XMP_CONFIRM_INCOMPLETE /
    /// XMP_CONFIRM_REQUIRES_SYNC）原样上抛。
    public func confirmSync(sessionId: String, module: String) async throws {
        let deliveryModule = try mapModule(module)
        do {
            _ = try delivery.confirm(sessionId: sessionId, module: deliveryModule)
        } catch let error as DeliveryCoordinatorError {
            // 失败项保留旧 WRITEBACK_FAILURES_PENDING 码（与旧实现的前置
            // failedCount 检查同语义）；其余阻断按 Coordinator 错误上抛。
            if case .confirmIncomplete(let blockers) = error,
               blockers.contains(where: {
                   $0.hasPrefix("delivery:failed=") || $0.hasPrefix("item:failed=")
               }) {
                throw WritebackServiceError.failuresPending
            }
            throw error
        }
        emitStateChanged(sessionId)
    }

    /// TS: persistAttributes / persistKeywords —— 旧 writeback_items 的两个列更新，
    /// 现在写 delivery_items.attributes_json / keywords（execute 从这里读回属性）。
    public func persistAttributes(items: [WritebackItem]) throws {
        var updates: [(itemId: Int64, attributes: [String: JSONValue])] = []
        for item in items {
            guard let id = item.id, let attributes = item.attributes else { continue }
            var dict: [String: JSONValue] = [:]
            if let keywords = attributes.keywords { dict["keywords"] = .array(keywords.map { .string($0) }) }
            if let rating = attributes.rating { dict["rating"] = .number(rating) }
            if let label = attributes.label { dict["label"] = .string(label) }
            updates.append((Int64(id), dict))
        }
        try stateWriter.updateItemAttributes(updates)
    }

    public func persistKeywords(items: [WritebackItem]) throws {
        var updates: [(itemId: Int64, keywords: [String])] = []
        for item in items {
            guard let id = item.id else { continue }
            updates.append((Int64(id), item.keywords))
        }
        try stateWriter.updateItemKeywords(updates)
    }

    public func getItems(sessionId: String, module: String, status: String? = nil) throws -> [WritebackItem] {
        let deliveryModule = try mapModule(module)
        var typedStatus: DeliveryItemStatus? = nil
        if let status, !status.isEmpty {
            guard let parsed = DeliveryItemStatus(rawValue: status) else { return [] }
            typedStatus = parsed
        }
        return try loadEntries(sessionId: sessionId, module: deliveryModule, status: typedStatus)
            .map { entryToItem($0, sessionId: sessionId) }
    }

    /// TS: cleanup —— 只清理已确认的 synced 交付；confirm 后的重新 preview 会创建
    /// 新一轮 pending 项——在这里清掉会让后台以无 UI 记录的方式把未确认关键词
    /// 写进 XMP（故全非 synced 时抛 XMP_CLEANUP_REQUIRES_LOADED，保留旧语义）。
    ///
    /// 文件阶段（恢复备份/删侧车）与 DB 段（items/links/delivery + intent 前滚）
    /// 统一由 DeliveryCoordinator.cleanup 承担：本服务不再自己删 delivery_items，
    /// 也不再经旧 outbox 清理。
    public func cleanup(sessionId: String, module: String) async throws -> CleanupResult {
        let deliveryModule = try mapModule(module)
        let allItems = try deliveryRepo.listItems(sessionId: sessionId, module: deliveryModule)
        let hasSynced = allItems.contains { $0.typedStatus == .synced }
        if !hasSynced && !allItems.isEmpty {
            throw WritebackServiceError.cleanupRequiresLoaded
        }
        let summary = try await delivery.cleanup(sessionId: sessionId, module: deliveryModule)
        var errors = summary.errors
        // 外部修改冲突：交付已标 conflict（不恢复不删行），按旧码回填到 errors，
        // 让调用方的报告卡能显示哪些侧车被外部改过（与 CullingService 同口径）。
        for path in summary.conflictedXmpPaths {
            errors.append(
                MetadataWritebackFailure.from(
                    DeliveryError.externallyModified, xmpPath: path
                ).description)
        }
        emitStateChanged(sessionId)
        return CleanupResult(deletedCount: summary.deletedCount, errors: errors)
    }

    /// TS: flushSession 的替代入口（S5c-2b-3b-2a）——execute 已同步写盘，flush 不再
    /// 调度/写入任何行，只回读本会话（可按模块收窄）的交付摘要，供 UI/门禁查询。
    public func flushSession(sessionId: String, module: String? = nil) throws -> MetadataSyncSummary {
        let deliveryModule: DeliveryModule? = try module.map { try mapModule($0) }
        return try summaryQuery.metadataSummary(sessionId: sessionId, module: deliveryModule)
    }
}
