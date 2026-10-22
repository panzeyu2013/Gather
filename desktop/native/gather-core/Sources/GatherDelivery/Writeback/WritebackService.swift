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

import Foundation
import GatherPersistence
import GatherProtocol

/// TS: writeback.service.ts 抛出的错误码。
public enum WritebackServiceError: Error, Equatable, CustomStringConvertible {
    case otherModuleActive // WRITEBACK_OTHER_MODULE_ACTIVE
    case failuresPending // WRITEBACK_FAILURES_PENDING
    case undoFaceFailed // WRITEBACK_UNDO_FACE_FAILED
    /// TS: `result?.errorMessage || 'WRITEBACK_UNDO_FACE_FAILED'`（撤销失败的
    /// 具体原因优先，缺失时回退常量码）。
    case undoFaceFailedWithMessage(String)
    case cleanupRequiresLoaded // XMP_CLEANUP_REQUIRES_LOADED（writeback 侧守卫）

    public var description: String {
        switch self {
        case .otherModuleActive: "WRITEBACK_OTHER_MODULE_ACTIVE"
        case .failuresPending: "WRITEBACK_FAILURES_PENDING"
        case .undoFaceFailed: "WRITEBACK_UNDO_FACE_FAILED"
        case .undoFaceFailedWithMessage(let message):
            message.isEmpty ? "WRITEBACK_UNDO_FACE_FAILED" : message
        case .cleanupRequiresLoaded: "XMP_CLEANUP_REQUIRES_LOADED"
        }
    }
}

/// execute Phase 1 并发 body 的收集盒子（prepared/errors/failedItems/failed
/// 串行写入；并发 append 会 SIGSEGV 或静默丢项）。
/// `@unchecked Sendable` 的依据：四个可变字段只在 `lock`（NSLock）临界区内通过
/// 同步方法与快照属性读写；锁内不含 await，并发阶段结束后转单线程消费快照。
private final class PhaseOneCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: [PreparedEntry] = []
    private var errors: [String] = []
    private var failedItems: [WritebackItem] = []
    private var pathErrors: [String: String] = [:]
    private var failed = 0
    /// 每条交付（xmpPath）在写盘前取得的真实备份路径（S5c-2b-3b-1）。
    private var backups: [String: String] = [:]

    func recordPrepared(_ entry: PreparedEntry) {
        lock.lock()
        defer { lock.unlock() }
        prepared.append(entry)
    }

    func recordFailure(message: String, item: WritebackItem) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(message)
        failedItems.append(item)
        failed += 1
    }

    /// 逐交付首个失败原因（交付行最终标 failed 时用它当 error_message）。
    func recordPathError(path: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        if pathErrors[path] == nil { pathErrors[path] = message }
    }

    /// 同一交付只备份一次（共享侧车的 RAW+JPEG 走同一 xmpPath）。
    func needsBackup(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return backups[path] == nil
    }

    func recordBackup(path: String, backupPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if backups[path] == nil { backups[path] = backupPath }
    }

    var preparedSnapshot: [PreparedEntry] {
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }

    var errorsSnapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }

    var failedItemsSnapshot: [WritebackItem] {
        lock.lock()
        defer { lock.unlock() }
        return failedItems
    }

    var pathErrorsSnapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return pathErrors
    }

    var backupsSnapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return backups
    }

    var failedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

/// 交付行 + 交付项行的成对视图（execute/preview 的行映射单位）。
///
/// 为什么需要成对：delivery_items 不带 session_id/xmp_path/backup_path，
/// 交付级字段在 deliveries 上；一次 listItems + getMany 组装，避免 N+1。
private struct DeliveryWritebackEntry: Sendable {
    let delivery: DeliveryRow
    let item: DeliveryItemRow
}

/// execute 前的 writing 归位结果（P1-2）：崩溃遗留的写租约在本次执行内收敛。
private struct LeaseRecoveryResult {
    var written = 0
    var failed = 0
    var errors: [String] = []
}

/// TS: WritebackService。
/// 线程安全说明（Swift 6 `Sendable`）：本类无任何可变状态——全部存储属性
/// （`deliveryRepo`/xmp/`photoRepo`/`metadataCacheRepo`/`delivery`/
/// `summaryQuery`/`keywordOrigins`/`assetResolver`）都是 `let`，构造后不可变，
/// 故无需锁。标注 `@unchecked` 仅因为依赖仓库/协议存在类型未标 `Sendable`；
/// execute 的并发收集状态全部收在 PhaseOneCollector 的锁内。
public final class WritebackService: @unchecked Sendable {
    private let deliveryRepo: DeliveryRepo
    /// 交付状态写入的唯一入口（WP2b）；读路径仍直接用 deliveryRepo。
    private let stateWriter: DeliveryStateWriter
    private let xmp: any XMPProvider
    private let photoRepo: PhotoRepo
    private let metadataCacheRepo: MetadataCacheRepo
    private let keywordOrigins: MetadataKeywordOriginRepo?
    private let assetResolver: PhotoAssetResolver?
    private let connection: DBConnection
    /// cleanup 的交付编排（intent 前滚 + 文件恢复）；宿主注入共享实例，
    /// 缺省按同一 connection/xmp 自建（测试/嵌入场景）。
    private let delivery: DeliveryCoordinator
    /// 与 DeliveryCoordinator 共用的按 xmpPath 文件锁（P0-1 TOCTOU 收口）：
    /// 同一交付组的 backup/read/writeAttributes 与 cleanup restore/remove 互斥。
    private let fileLock: XMPFileLock
    /// flushSession 的只读投影（不再有调度语义）。
    private let summaryQuery: DeliverySummaryQuery
    /// 交付状态变化后的会话级通知：宿主据此刷新 C1 同步徽标。
    /// 旧 MetadataSyncCoordinator 的 eventSink 等价物（2b-3 删除旧协调器后仍能推送）。
    private let eventSink: (@Sendable (String) -> Void)?
    /// 本服务实例的写租约 owner（P1-2）：进程内稳定，跨 execute 复用同一身份，
    /// 崩溃后新进程会拿到新 owner，只能等旧 heartbeat 过期后抢占。
    private let leaseOwner: String

    public init(
        deliveryRepo: DeliveryRepo,
        xmp: any XMPProvider,
        photoRepo: PhotoRepo,
        metadataCacheRepo: MetadataCacheRepo,
        connection: DBConnection,
        keywordOrigins: MetadataKeywordOriginRepo? = nil,
        assetResolver: PhotoAssetResolver? = nil,
        delivery: DeliveryCoordinator? = nil,
        fileLock: XMPFileLock = .shared,
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

    /// 交付状态已变化：通知宿主（sessionId 为空不通知）。
    private func emitStateChanged(_ sessionId: String) {
        guard !sessionId.isEmpty, let eventSink else { return }
        eventSink(sessionId)
    }

    // MARK: - 交付写租约 trace（P2）

    /// 写租约事件：`trace=delivery:<id>/rev:<revision>/lease` + op/phase/reason。
    ///
    /// 只在租约冲突/丢失/条件更新未命中时 warn：这是写回最难排障、也最容易
    /// 在多写者下静默失败的路径。reason 只用错误码或脱敏后的错误文本，
    /// xmpPath 只以 basename#hash 出现（不泄漏绝对路径）。
    private func logLeaseEvent(
        xmpPath: String,
        delivery: DeliveryRow?,
        revision: Int64?,
        op: String,
        reason: String
    ) {
        let fallback: DeliveryRow?
        do {
            fallback = try deliveryRepo.get(xmpPath)
        } catch {
            fallback = nil
        }
        let identity = delivery ?? fallback
        guard let identity else { return }
        DeliveryTrace.log(
            DeliveryTrace.text(
                deliveryId: identity.id,
                revision: revision ?? identity.revision,
                phase: "lease"),
            "event=failed op=\(op) phase=lease xmp=\(DeliveryTrace.pathToken(xmpPath)) "
                + "reason=\(DeliveryTrace.reason(reason, paths: [xmpPath]))",
            level: .warn)
    }

    /// 仅把「租约被他人持有 / 租约已丢失」的错误码抽出来；其它错误不进租约 trace。
    private static func leaseFailureReason(_ error: Error) -> String? {
        guard let repoError = error as? DeliveryRepoError else { return nil }
        switch repoError {
        case .leaseHeld, .leaseLost: return repoError.code
        default: return nil
        }
    }


    // MARK: - 私有支撑

    /// 旧写回模块名 → 交付模块（落库值只取 SchemaV1 的 CHECK 值）。
    private func mapModule(_ module: String) throws -> DeliveryModule {
        guard let mapped = DeliveryModule(writebackModule: module) else {
            // 现有调用方只用 culling / similarity / face_kw（含 "face-keyword" 别名），
            // 未知模块是调用方 bug：显式失败而不是静默落到 .metadata。
            throw DeliveryRepoError.invalidArgument("unsupported writeback module: \(module)")
        }
        return mapped
    }

    /// TS: assertNoActiveOtherModule —— 单写回状态机：另一模块的 written/synced 工作
    /// 必须先确认并清理。读交付项（归属从旧 outbox 的 __owners__ 提升为行）。
    /// culling 是连续同步模块，绝不阻塞其它模块的批量写回，故排除。
    private func assertNoActiveOtherModule(sessionId: String, module: String) throws {
        let current = try mapModule(module)
        for row in try deliveryRepo.listItems(sessionId: sessionId) {
            guard row.typedStatus == .written || row.typedStatus == .synced else { continue }
            guard let typed = row.typedModule else {
                // 未知模块串（历史脏数据）按「其它模块」处理，宁可拦下不可覆盖。
                throw WritebackServiceError.otherModuleActive
            }
            if typed == current || typed == .culling { continue }
            throw WritebackServiceError.otherModuleActive
        }
    }

    /// 一次组装「会话 × 模块」的交付项与其交付行（listItems 一次 + getMany 一次）。
    private func loadEntries(
        sessionId: String,
        module: DeliveryModule,
        status: DeliveryItemStatus? = nil
    ) throws -> [DeliveryWritebackEntry] {
        let items = try deliveryRepo.listItems(sessionId: sessionId, module: module, status: status)
        guard !items.isEmpty else { return [] }
        let deliveries = try deliveryRepo.getMany(xmpPaths: items.map(\.xmpPath))
        return try items.map { item in
            guard let delivery = deliveries[TSPath.normalize(item.xmpPath)] else {
                throw DeliveryRepoError.rowNotFound(xmpPath: item.xmpPath)
            }
            return DeliveryWritebackEntry(delivery: delivery, item: item)
        }
    }

    /// TS: rowToItem —— 交付行 + 交付项行 → 协议形状（字段语义与旧 writeback_items 一致）。
    private func entryToItem(_ entry: DeliveryWritebackEntry, sessionId: String) -> WritebackItem {
        var attributes: WritebackAttributes? = nil
        if !entry.item.attributesJSON.isEmpty {
            let dict = entry.item.attributes
            attributes = WritebackAttributes(
                keywords: dict["keywords"]?.arrayElements?.compactMap { $0.stringValue },
                rating: dict["rating"]?.numberValue,
                label: dict["label"]?.stringValue
            )
        }
        return WritebackItem(
            id: Int(entry.item.id),
            photoId: entry.item.photoId,
            photoPath: entry.delivery.photoPath,
            sessionId: sessionId,
            module: entry.item.typedModule?.writebackModuleName ?? entry.item.module,
            keywords: entry.item.keywordList,
            attributes: attributes,
            xmpPath: entry.delivery.xmpPath,
            backupPath: entry.delivery.backupPath,
            xmpStatus: entry.item.status,
            errorMessage: entry.item.errorMessage,
            attemptCount: Int(entry.item.attemptCount),
            lastAttemptAt: entry.item.updatedAt
        )
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

    /// execute 的逐交付租约入口（P1-2）：pending/failed/conflict → writing；
    /// written/synced（仍有新的 pending item）→ 新输入重开后再抢租约；
    /// writing → claim（同 owner 续租 / 过期抢占 / 未过期拒绝），不再无条件复用；
    /// cleaned（审计终态）或 CAS 失配返回 nil，由调用方把本交付的项标 failed。
    private func beginDeliveryWrite(xmpPath: String) throws -> DeliveryRow? {
        guard let current = try deliveryRepo.get(xmpPath) else { return nil }
        switch current.typedStatus {
        case .some(.writing):
            // 崩溃遗留或并发写者：只有本 owner 续租、或旧 heartbeat 过期才能接管。
            return try stateWriter.claimWriting(
                xmpPath: xmpPath, revision: current.revision, leaseOwner: leaseOwner)
        case .some(.pending), .some(.failed), .some(.conflict):
            // 必须走 claim：读与写之间若被并发写者抢成 writing，markWriting 会
            // 无条件覆盖对方租约；claim 会按 owner/heartbeat 拒绝或续租。
            return try stateWriter.claimWriting(
                xmpPath: xmpPath, revision: current.revision,
                leaseOwner: leaseOwner, heartbeatAt: nowISOString())
        case .some(.written), .some(.synced):
            guard let reopened = try stateWriter.mergeInput(
                xmpPath: xmpPath,
                photoPath: current.photoPath,
                expectedRevision: current.revision,
                newRevision: current.revision + 1,
                baseFingerprint: current.baseFingerprint,
                baseValues: current.baseValues
            ) else {
                return nil
            }
            return try stateWriter.claimWriting(
                xmpPath: xmpPath, revision: reopened.revision,
                leaseOwner: leaseOwner, heartbeatAt: nowISOString())
        case .some(.cleaned), .none:
            return nil
        }
    }

    /// 崩溃归位（P1-2）：把本会话/模块下停在 writing 的交付收敛掉。
    ///
    /// 文件阶段在 execute Phase 1 完成、markItem(written) 在 Phase 2 才落库，因此：
    /// - 已有 written item：文件已写完（markItem 只在写盘成功后调用），只需补
    ///   markWritten（指纹/基线按当前盘上内容补齐，备份沿用交付行）；
    /// - 没有任何 written item：崩溃发生在写盘前/写盘中，归 failed 并记明确错误，
    ///   下一次重试可从 failed 重新抢租约，而不是永久卡在 writing。
    ///
    /// 只有本 owner 能续租或抢到过期租约才动行；他人未过期的租约留给持有者：
    /// 真正有输入项时由 beginDeliveryWrite 逐项显式失败，恢复扫描不误报并发写者。
    private func recoverInterruptedWrites(
        sessionId: String,
        entries: [DeliveryWritebackEntry]
    ) async -> LeaseRecoveryResult {
        var result = LeaseRecoveryResult()
        var byPath: [String: [DeliveryWritebackEntry]] = [:]
        for entry in entries where entry.delivery.typedStatus == .writing {
            byPath[entry.delivery.xmpPath, default: []].append(entry)
        }
        for path in byPath.keys.sorted() {
            guard let group = byPath[path], let stale = group.first?.delivery else { continue }
            let claimed: DeliveryRow?
            do {
                claimed = try stateWriter.claimWriting(
                    xmpPath: path, revision: stale.revision, leaseOwner: leaseOwner)
            } catch {
                // 他人持有效租约（或行已不在 writing）：留给持有者/下一次执行。
                if let leaseReason = Self.leaseFailureReason(error) {
                    logLeaseEvent(
                        xmpPath: path,
                        delivery: stale,
                        revision: stale.revision,
                        op: "writeback-recover",
                        reason: leaseReason)
                }
                continue
            }
            guard let row = claimed else {
                logLeaseEvent(
                    xmpPath: path,
                    delivery: stale,
                    revision: stale.revision,
                    op: "writeback-recover",
                    reason: "DELIVERY_WRITE_CAS_FAILED")
                result.errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                continue
            }
            if group.contains(where: { $0.item.typedStatus == .written }) {
                var baseValues = stale.baseValues
                let photoId = group.first?.item.photoId ?? ""
                let photoPath = recoveryPhotoPath(
                    sessionId: sessionId, delivery: stale, photoId: photoId)
                if !photoPath.isEmpty {
                    do {
                        baseValues = try await xmp.readAttributes(photoPath: photoPath).asJSONValue
                    } catch {
                        result.errors.append("DELIVERY_BASE_VALUES_FAILED: \(path): \(error)")
                    }
                }
                var fingerprint = stale.baseFingerprint
                do {
                    let fresh = try await MetadataFingerprint.contentFingerprint(path)
                    if !fresh.isEmpty { fingerprint = fresh }
                } catch {
                    result.errors.append("DELIVERY_FINGERPRINT_FAILED: \(path): \(error)")
                }
                do {
                    // 归位前还有两次 await 读盘：先续租，租约被接管就停止收敛。
                    guard try stateWriter.renewWriting(
                        xmpPath: path, revision: row.revision, leaseOwner: leaseOwner)
                    else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_LEASE_LOST")
                        result.errors.append("DELIVERY_LEASE_LOST: \(path)")
                        continue
                    }
                    if try stateWriter.markWritten(
                        xmpPath: path, revision: row.revision,
                        leaseOwner: leaseOwner,
                        baseFingerprint: fingerprint, baseValues: baseValues,
                        backupPath: stale.backupPath) != nil {
                        clearReloadAck(forXmpPath: path)
                        result.written += 1
                    } else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        result.errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: leaseReason)
                    }
                    result.errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            } else {
                do {
                    guard try stateWriter.renewWriting(
                        xmpPath: path, revision: row.revision, leaseOwner: leaseOwner)
                    else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_LEASE_LOST")
                        result.errors.append("DELIVERY_LEASE_LOST: \(path)")
                        continue
                    }
                    if try stateWriter.markFailed(
                        xmpPath: path, revision: row.revision,
                        errorMessage: Self.interruptedWriteMessage,
                        leaseOwner: leaseOwner) != nil {
                        result.failed += 1
                        result.errors.append("DELIVERY_WRITE_INTERRUPTED: \(path)")
                    } else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        result.errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: leaseReason)
                    }
                    result.errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            }
        }
        return result
    }

    /// 归位时解析写盘路径（优先资产解析，其次交付行/侧车推导）；空白路径表示无法回读。
    private func recoveryPhotoPath(
        sessionId: String,
        delivery: DeliveryRow,
        photoId: String
    ) -> String {
        if !photoId.isEmpty, let assetResolver,
           let resolved = try? assetResolver.resolve(sessionId: sessionId, photoId: photoId) {
            return resolved.filepath
        }
        if !delivery.photoPath.isEmpty { return delivery.photoPath }
        return Self.photoPathFromSidecar(delivery.xmpPath)
    }

    /// 归位为 failed 时的稳定错误串（UI/日志按前缀识别「崩溃后归位」）。
    private static let interruptedWriteMessage =
        "WRITEBACK_INTERRUPTED: write lease expired before the delivery completed"

    /// 新写入让关联会话的 Capture One reload-ack 失效（§5.4-2 门禁的数据侧）。
    ///
    /// 旧协调器在 claim 后按 outbox 关联会话清 ack；执行器直写后由交付的
    /// delivery_sessions 反查同一批会话，保证 confirm/finalize 必须等一次新 reload。
    private func clearReloadAck(forXmpPath xmpPath: String) {
        do {
            let path = TSPath.normalize(xmpPath)
            let rows = try connection.prepare("""
                SELECT ds.session_id
                FROM delivery_sessions ds
                JOIN deliveries d ON d.id = ds.delivery_id
                WHERE d.xmp_path = ?
                """).query([.text(path)])
            for row in rows {
                guard let sessionId = row[0].textValue, !sessionId.isEmpty else { continue }
                _ = try connection.prepare("""
                    UPDATE sessions SET reload_acked_at = NULL, updated_at = ?
                    WHERE id = ? AND reload_acked_at IS NOT NULL
                    """).run([.text(nowISOString()), .text(sessionId)])
            }
        } catch {
            // 不改变已落盘的 written：ack 清理失败只会让门禁更严格（下次 reload 仍可过）。
            GatherLogger.log(
                "Failed to clear reload-ack for \(xmpPath): \(error)", level: .warn)
        }
    }

    /// 逐项失败落库：状态行写不进去时只记日志（旧实现同一处理），
    /// 但绝不静默——execute 的计数/errors 仍会反映本项失败。
    private func persistItemFailure(itemId: Int64, message: String) {
        do {
            try stateWriter.markItem(itemId: itemId, status: .failed, errorMessage: message)
        } catch {
            GatherLogger.log("Failed to record writeback item failure: \(error)", level: .error)
        }
    }

    /// TS: preloadResolvedTargets —— 整批一次 resolveMany（单 IN 查询替代逐项
    /// 5 路 JOIN）；execute 用解析后的 filepath 写盘（relink 后 preview 快照
    /// 的路径可能已失效），解析器服务不到的照片缺席，回退存储路径。
    private func preloadResolvedTargets(
        sessionId: String,
        entries: [DeliveryWritebackEntry]
    ) throws -> [String: ResolvedPhotoAsset] {
        guard let assetResolver else { return [:] }
        return try assetResolver.resolveMany(
            sessionId: sessionId,
            photoIds: Array(Set(entries.map(\.item.photoId)))
        )
    }


    /// TS: resolvePreviewTargets —— preview 时逐会话一次 resolveMany 批量查询；
    /// 解析器服务不到的项按遗留 filepath/sidecar 兜底；无 resolveMany 时逐项
    /// resolve（保持旧的精确语义）。
    private func resolvePreviewTargets(
        sessionId: String,
        photos: [(id: String, filepath: String)]
    ) throws -> [String: (filepath: String, xmpPath: String)] {
        func fallback(_ photo: (id: String, filepath: String)) -> (filepath: String, xmpPath: String) {
            (photo.filepath, TSPath.xmpSidecarPath(photo.filepath))
        }
        var byPhoto: [String: (filepath: String, xmpPath: String)] = [:]
        if let assetResolver {
            let resolved = try assetResolver.resolveMany(sessionId: sessionId, photoIds: photos.map(\.id))
            for photo in photos {
                if let asset = resolved[photo.id] {
                    byPhoto[photo.id] = (asset.filepath, asset.xmpPath)
                } else {
                    byPhoto[photo.id] = fallback(photo)
                }
            }
            return byPhoto
        }
        for photo in photos {
            if let assetResolver, let asset = try? assetResolver.resolve(sessionId: sessionId, photoId: photo.id) {
                byPhoto[photo.id] = (asset.filepath, asset.xmpPath)
            } else {
                byPhoto[photo.id] = fallback(photo)
            }
        }
        return byPhoto
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
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
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
                    GatherLogger.log("Writeback preview keyword read failed for \(sidecarPath): \(error)", level: .warn)
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

    /// TS: execute —— 两阶段：Phase 1 并发读当前属性 → 合并关键词 → **直接写盘**
    /// （S5c-2b-3b-2a，不再入队/等 flush）；Phase 2 串行推进交付状态。
    ///
    /// 持久化：读 delivery_items（pending/failed）→ 交付行抢写租约 → 逐项写盘 +
    /// markItem(written/failed) → 交付行 markWritten/markFailed（revision CAS）。
    public func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult {
        let deliveryModule = try mapModule(module)
        try assertNoActiveOtherModule(sessionId: sessionId, module: module)

        var written = 0
        var failed = 0
        var skipped = 0
        var errors: [String] = []
        var failedItems: [WritebackItem] = []

        let persistedEntries = try loadEntries(sessionId: sessionId, module: deliveryModule)
        // 崩溃归位（P1-2）：上一轮在 markItem 与 markWritten 之间中断时交付停在
        // writing。先续租/抢占并收敛它，避免该侧车永久无法 confirm/cleanup。
        let leaseRecovery = await recoverInterruptedWrites(
            sessionId: sessionId, entries: persistedEntries)
        errors.append(contentsOf: leaseRecovery.errors)
        written += leaseRecovery.written
        failed += leaseRecovery.failed
        var entryIndex: [Int: DeliveryWritebackEntry] = [:]
        var deliveryByPath: [String: DeliveryRow] = [:]
        for entry in persistedEntries {
            entryIndex[Int(entry.item.id)] = entry
            // P2：租约 trace 的 delivery:<id>/rev 快照（claim 前最后一次读到的行）。
            deliveryByPath[entry.delivery.xmpPath] = deliveryByPath[entry.delivery.xmpPath]
                ?? entry.delivery
        }
        // 并发 body 只读捕获（Sendable 值类型字典），故在进入 batchAsync 前转成 let。
        let entryById = entryIndex
        let resolvedByPhoto = try preloadResolvedTargets(sessionId: sessionId, entries: persistedEntries)

        // 分组键是交付主键（deliveries.xmp_path）：一条交付 = 一个侧车文件；共享侧车的
        // 多张照片（RAW+JPEG）在 preview 已收敛到同一条交付，组内保持输入顺序串行合并。
        var groups: [String: [WritebackItem]] = [:]
        for item in items {
            guard let itemId = item.id, let entry = entryById[itemId] else {
                skipped += 1
                continue
            }
            guard let status = entry.item.typedStatus, status == .pending || status == .failed else {
                skipped += 1
                continue
            }
            groups[entry.delivery.xmpPath, default: []].append(item)
        }

        // 逐交付抢租约（本轮一次）。不可写的交付（cleaned / 行缺失 / 他人有效租约）
        // 逐项显式失败：租约冲突保留 DELIVERY_LEASE_HELD 码，不压成通用写失败。
        var writeRevisionByPath: [String: Int64] = [:]
        var unwritablePaths: [String: String] = [:]
        for path in groups.keys.sorted() {
            do {
                if let row = try beginDeliveryWrite(xmpPath: path) {
                    writeRevisionByPath[path] = row.revision
                } else {
                    unwritablePaths[path] =
                        "DELIVERY_NOT_WRITABLE: \(path) (terminal state or revision changed)"
                }
            } catch {
                if let leaseReason = Self.leaseFailureReason(error) {
                    logLeaseEvent(
                        xmpPath: path,
                        delivery: deliveryByPath[path],
                        revision: deliveryByPath[path]?.revision,
                        op: "writeback-execute",
                        reason: leaseReason)
                }
                if let repoError = error as? DeliveryRepoError, case .leaseHeld = repoError {
                    unwritablePaths[path] = repoError.description
                } else {
                    unwritablePaths[path] = MetadataWritebackFailure.from(
                        error, xmpPath: path).description
                }
            }
        }

        var runnableGroups: [(String, [WritebackItem])] = []
        for (path, groupItems) in groups.sorted(by: { $0.key < $1.key }) {
            guard let message = unwritablePaths[path] else {
                runnableGroups.append((path, groupItems))
                continue
            }
            for item in groupItems {
                guard let itemId = item.id, let entry = entryById[itemId] else { continue }
                persistItemFailure(itemId: Int64(itemId), message: message)
                errors.append("\(path): \(message)")
                failedItems.append(entryToItem(entry, sessionId: sessionId))
                failed += 1
            }
        }

        // batchAsync 的 body 并发执行：prepared/errors/failedItems/pathErrors 都是共享
        // 可变状态，必须串行写入（实测并发 append 会 SIGSEGV 或静默丢项）——统一收进
        // PhaseOneCollector 的锁内，快照在 await 返回后转单线程合并。
        let phaseOne = PhaseOneCollector()
        _ = try await batchAsync(runnableGroups, concurrency: 4) { group in
            let xmpPath = group.0
            let groupItems = group.1
            // P0-1 TOCTOU：一个交付组的 backup/read/write 必须在同一把
            // xmpPath 锁内完成；cleanup restore/remove 也取同一实例。
            try await self.fileLock.run(path: xmpPath) {
                await self.writeGroupItems(
                    xmpPath: xmpPath,
                    items: groupItems,
                    entryById: entryById,
                    resolvedByPhoto: resolvedByPhoto,
                    phaseOne: phaseOne,
                    sessionId: sessionId
                )
            }
        }


        // 并发阶段结束：把锁内收集的状态并入单线程局部量（此后只有本任务读写）。
        var prepared: [PreparedEntry] = []
        prepared.append(contentsOf: phaseOne.preparedSnapshot)
        errors.append(contentsOf: phaseOne.errorsSnapshot)
        failedItems.append(contentsOf: phaseOne.failedItemsSnapshot)
        failed += phaseOne.failedCount
        var firstErrorByPath = phaseOne.pathErrorsSnapshot
        // 写前备份快照（xmpPath → 真实备份文件；空串 = 原侧车不存在）。
        let backupByPath = phaseOne.backupsSnapshot
        // 交付级 photo_path/已有备份快照：markWritten 需要与交付行同源的路径。
        var photoPathByPath: [String: String] = [:]
        var existingBackupByPath: [String: String] = [:]
        for entry in prepared where photoPathByPath[entry.delivery.xmpPath] == nil {
            photoPathByPath[entry.delivery.xmpPath] = entry.writePhotoPath
            existingBackupByPath[entry.delivery.xmpPath] = entry.delivery.backupPath
        }

        // Phase 2（无 await 的状态推进）：Phase 1 已经真实写盘，逐项落 written。
        // 旧实现先入 outbox 再 flushSession 对照摘要——端口退场后摘要不再产生
        // 写事件，继续用它会把已落盘的项误判 failed。
        var writtenPaths = Set<String>()
        var baseValuesByPath: [String: JSONValue] = [:]
        for entry in prepared {
            do {
                try stateWriter.markItem(itemId: entry.itemId, status: .written)
            } catch {
                let message = "DELIVERY_ITEM_WRITE_FAILED: \(error)"
                persistItemFailure(itemId: entry.itemId, message: message)
                if firstErrorByPath[entry.delivery.xmpPath] == nil {
                    firstErrorByPath[entry.delivery.xmpPath] = message
                }
                errors.append("\(entry.photoPath): \(message)")
                failedItems.append(entry.persistedItem)
                failed += 1
                continue
            }
            // 本地投影失败不得静默：逐条进报告 errors（XMP 已落盘，不改判 written）。
            let attrs = entry.writtenAttributes.asJSONValue.objectValue ?? [:]
            errors.append(contentsOf: updateLocalProjection(entry: entry, attrs: attrs, module: module))
            written += 1
            writtenPaths.insert(entry.delivery.xmpPath)
            baseValuesByPath[entry.delivery.xmpPath] = entry.writtenAttributes.asJSONValue
        }

        // 落盘后回读真实基线（S5c-2b-3b-1）：指纹取磁盘内容，base_values 取
        // 持久化属性。回读失败只进 errors，不改判已落盘的 written，也不再把
        // 两列留空等 outbox 镜像。
        var fingerprintByPath: [String: String] = [:]
        for path in writtenPaths.sorted() {
            do {
                fingerprintByPath[path] = try await MetadataFingerprint.contentFingerprint(path)
            } catch {
                errors.append("DELIVERY_FINGERPRINT_FAILED: \(path): \(error)")
            }
            guard let photoPath = photoPathByPath[path] else { continue }
            do {
                baseValuesByPath[path] = try await xmp.readAttributes(photoPath: photoPath).asJSONValue
            } catch {
                // 保留 Phase 1 的写入属性回退值。
                errors.append("DELIVERY_BASE_VALUES_FAILED: \(path): \(error)")
            }
        }

        // 交付行收敛：本交付有成功项 → written；全部失败 → failed（与镜像同一口径）。
        // 备份路径用写前 xmp.backup 的真实返回值（重试沿用交付行上的旧备份）。
        for path in writeRevisionByPath.keys.sorted() {
            guard let revision = writeRevisionByPath[path] else { continue }
            // 长批次写盘可能超过租约 TTL：收敛前续租一次。失败说明租约已被
            // 他人接管/新输入推进 revision —— 本轮不得再写 written 或 failed
            // （P1-2），行保持原样交给持有者/下一次恢复扫描。
            let holdsLease: Bool
            do {
                holdsLease = try stateWriter.renewWriting(
                    xmpPath: path, revision: revision, leaseOwner: leaseOwner)
            } catch {
                logLeaseEvent(
                    xmpPath: path,
                    delivery: deliveryByPath[path],
                    revision: revision,
                    op: "writeback-converge",
                    reason: Self.leaseFailureReason(error) ?? "DELIVERY_LEASE_LOST")
                errors.append("DELIVERY_LEASE_LOST: \(path): \(error)")
                continue
            }
            guard holdsLease else {
                logLeaseEvent(
                    xmpPath: path,
                    delivery: deliveryByPath[path],
                    revision: revision,
                    op: "writeback-converge",
                    reason: "DELIVERY_LEASE_LOST")
                errors.append("DELIVERY_LEASE_LOST: \(path)")
                continue
            }
            if writtenPaths.contains(path) {
                let backupPath = backupByPath[path].flatMap { $0.isEmpty ? nil : $0 }
                    ?? existingBackupByPath[path]
                    ?? ""
                do {
                    let row = try stateWriter.markWritten(
                        xmpPath: path,
                        revision: revision,
                        leaseOwner: leaseOwner,
                        baseFingerprint: fingerprintByPath[path] ?? "",
                        baseValues: baseValuesByPath[path] ?? .object([:]),
                        backupPath: backupPath
                    )
                    if row == nil {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    } else {
                        // 已落盘：关联会话必须重新 reload 才能 confirm（§5.4-2）。
                        clearReloadAck(forXmpPath: path)
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: leaseReason)
                    }
                    errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            } else {
                let message = firstErrorByPath[path] ?? "WRITEBACK_FAILED"
                do {
                    let row = try stateWriter.markFailed(
                        xmpPath: path, revision: revision, errorMessage: message,
                        leaseOwner: leaseOwner)
                    if row == nil {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: leaseReason)
                    }
                    errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            }
        }

        // 交付行/项已从 pending 收敛到 written/failed：通知宿主刷新同步徽标。
        emitStateChanged(sessionId)
        return WritebackResult(
            totalAffected: written + failed + skipped,
            written: written,
            failed: failed,
            skipped: skipped,
            errors: errors,
            failedItems: failedItems,
            report: "Written: \(written), Failed: \(failed), Skipped: \(skipped)"
        )
    }

    /// 单个交付组的文件阶段（execute Phase 1 的唯一写盘入口）。
    ///
    /// 调用方必须已持有 XMPFileLock（同一 xmpPath）：backup → readAttributes →
    /// writeAttributes 必须原子成组，否则 cleanup 的 restore/remove 可能插在
    /// “读旧值”与“写新值”之间。组内仍按输入顺序串行（RAW+JPEG 共享侧车时
    /// 后一项看到前一项刚写入的内容），批次/排序语义不变。
    private func writeGroupItems(
        xmpPath: String,
        items: [WritebackItem],
        entryById: [Int: DeliveryWritebackEntry],
        resolvedByPhoto: [String: ResolvedPhotoAsset],
        phaseOne: PhaseOneCollector,
        sessionId: String
    ) async {
        for item in items {
            guard let itemId = item.id, let entry = entryById[itemId] else { continue }

            var photoPath = entry.delivery.photoPath
            if photoPath.isEmpty, !xmpPath.isEmpty {
                // TS: dbRow.xmp_path.replace(/\.xmp$/i, '')
                var fallback = xmpPath
                if fallback.lowercased().hasSuffix(".xmp") { fallback = String(fallback.dropLast(4)) }
                photoPath = fallback
            }
            let persistedItem = entryToItem(entry, sessionId: sessionId)
            guard !photoPath.isEmpty else {
                let message = "Missing photo path for writeback item"
                persistItemFailure(itemId: Int64(itemId), message: message)
                phaseOne.recordPathError(path: xmpPath, message: message)
                var failedItem = persistedItem
                failedItem.photoPath = ""
                phaseOne.recordFailure(message: "\(itemId): \(message)", item: failedItem)
                continue
            }

            do {
                // 写盘目标按 execute 时的资产状态解析：preview 与 execute 之间
                // 可能已完成 relink（asset_read_mode='asset'），用 preview 快照
                // 会写到旧路径/旧侧车。
                let resolvedTarget = resolvedByPhoto[entry.item.photoId]
                let writePhotoPath = resolvedTarget?.filepath ?? photoPath
                // 写前真实备份（S5c-2b-3b-1）：必须在文件写入之前取，
                // 备份路径随 markWritten 直接落 deliveries.backup_path。
                // 已有备份（重试）直接复用。
                if entry.delivery.backupPath.isEmpty, phaseOne.needsBackup(path: xmpPath) {
                    do {
                        let backupPath = try await xmp.backup(photoPath: writePhotoPath)
                        phaseOne.recordBackup(path: xmpPath, backupPath: backupPath)
                    } catch {
                        let message = MetadataWritebackFailure.from(error, xmpPath: xmpPath).description
                        persistItemFailure(itemId: Int64(itemId), message: message)
                        phaseOne.recordPathError(path: xmpPath, message: message)
                        phaseOne.recordFailure(message: "\(photoPath): \(message)", item: persistedItem)
                        continue
                    }
                }
                // 直写（S5c-2b-3b-2a）：先读当前属性再只覆盖本次字段，
                // 保留外部写入的 dateTaken/GPS；关键词按磁盘现状重新合并，
                // 避免 preview 快照与 execute 之间外部新增的词被静默丢弃。
                var attributesToWrite = try await xmp.readAttributes(photoPath: writePhotoPath)
                let keywordsBeforeWrite = attributesToWrite.keywords ?? []
                let writeKeywords = orderedUnion(keywordsBeforeWrite, persistedItem.keywords)
                // attributes.keywords（如 culling 写回计划）也必须合并。
                let mergedKeywords = orderedUnion(
                    writeKeywords,
                    persistedItem.attributes?.keywords ?? []
                )
                // 关键词写入模式（S5c-2b-3b-2b-2）：手动元数据把意图落在
                // delivery_items.attributes_json.keywords_mode。replace = 以项里的
                // keywords 为权威列表（replace/remove 必须能删词）；缺省/merge =
                // 与盘上现状取并集（culling/人脸/相似度的只增语义不变）。
                let keywordsMode = entry.item.attributes[
                    MetadataMutationService.keywordsModeKey]?.stringValue
                if keywordsMode == MetadataKeywordWriteMode.replace.rawValue {
                    attributesToWrite.keywords = persistedItem.keywords
                } else {
                    attributesToWrite.keywords = persistedItem.attributes != nil
                        ? mergedKeywords
                        : writeKeywords
                }
                if let attributes = persistedItem.attributes {
                    if let rating = attributes.rating { attributesToWrite.rating = rating }
                    if let label = attributes.label { attributesToWrite.label = label }
                }
                try await xmp.writeAttributes(
                    photoPath: writePhotoPath, attributes: attributesToWrite)
                phaseOne.recordPrepared(PreparedEntry(
                    itemId: Int64(itemId),
                    delivery: entry.delivery,
                    persistedItem: persistedItem,
                    photoPath: photoPath,
                    writePhotoPath: writePhotoPath,
                    writtenAttributes: attributesToWrite,
                    keywordsBeforeWrite: keywordsBeforeWrite
                ))
            } catch {
                // 逐项隔离：本项失败只影响本项，错误以「错误码 + 路径 + 原因」上报。
                let message = MetadataWritebackFailure.from(error, xmpPath: xmpPath).description
                persistItemFailure(itemId: Int64(itemId), message: message)
                phaseOne.recordPathError(path: xmpPath, message: message)
                phaseOne.recordFailure(message: "\(photoPath): \(message)", item: persistedItem)
            }
        }
    }


    /// 按需执行入口（P1-9）：加载本会话/模块下 **pending + failed** 交付项，
    /// 原样交给 `execute` 完成写盘与状态推进（不复制任何写盘/租约逻辑）。
    ///
    /// 手动元数据队列（module=metadata）在 setMetadata / batchSet 入队成功后经宿主
    /// 注入的闭包调用本入口；失败的项由 execute 落 failed（可重试），下次调用
    /// executePending 会连同 pending 一起再次消费。
    public func executePending(sessionId: String, module: String) async throws -> WritebackResult {
        let deliveryModule = try mapModule(module)
        var items: [WritebackItem] = []
        for status in [DeliveryItemStatus.pending, .failed] {
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

    /// 侧车路径 → 照片路径（xmp 后缀大小写不敏感，与 execute 的回退同口径）。
    private static func photoPathFromSidecar(_ xmpPath: String) -> String {
        xmpPath.lowercased().hasSuffix(".xmp") ? String(xmpPath.dropLast(4)) : xmpPath
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


    /// 写盘成功后的本地投影刷新（元数据缓存 + 人脸关键词归属）。
    /// XMP 已经落盘，因此投影失败不改判 written，但必须逐条可见（禁止 try? 吞写失败）。
    private func updateLocalProjection(entry: PreparedEntry, attrs: [String: JSONValue], module: String) -> [String] {
        var failures: [String] = []
        func record(_ operation: String, _ error: Error) {
            let failure = MetadataWritebackFailure.from(error, xmpPath: entry.delivery.xmpPath)
            failures.append(failure.description + " operation=" + operation)
            GatherLogger.log(
                "Writeback projection failed (\(operation)) for \(entry.delivery.xmpPath): \(error)",
                level: .warn)
        }
        if let rating = attrs["rating"]?.numberValue {
            do {
                try metadataCacheRepo.updateRating(photoId: entry.itemPhotoId, rating: Int64(rating))
            } catch {
                record("cache.updateRating", error)
            }
        }
        if let label = attrs["label"]?.stringValue {
            do {
                try metadataCacheRepo.updateLabel(photoId: entry.itemPhotoId, label: label)
            } catch {
                record("cache.updateLabel", error)
            }
        }
        if let keywords = attrs["keywords"]?.arrayElements?.compactMap({ $0.stringValue }) {
            do {
                try metadataCacheRepo.updateKeywords(photoId: entry.itemPhotoId, keywords: keywords)
            } catch {
                record("cache.updateKeywords", error)
            }
            if module == "face_kw", let keywordOrigins {
                // keywordsBeforeWrite 是 phase 1 的写前快照：写入前不在文件上的关键词即本模块引入的。
                let existing = Set(entry.keywordsBeforeWrite)
                let introduced = keywords.filter { !existing.contains($0) }
                do {
                    try keywordOrigins.markIntroduced(
                        xmpPath: entry.delivery.xmpPath, source: "face-keyword", keywords: introduced)
                } catch {
                    record("origin.markIntroduced", error)
                }
            }
        }
        return failures
    }
}

/// Phase 1 的 prepare 结果（TS 内联对象）。
private struct PreparedEntry: Sendable {
    let itemId: Int64
    /// 交付行快照（状态迁移用 xmpPath + revision）。
    let delivery: DeliveryRow
    let persistedItem: WritebackItem
    /// preview 快照里的照片路径（报告/失败信息用）。
    let photoPath: String
    /// execute 时实际写盘的照片路径（资产 relink 后与快照不同）。
    let writePhotoPath: String
    /// 实际写进侧车的完整属性（回读基线失败时的回退值，也供本地投影）。
    let writtenAttributes: MetadataWriteAttributes
    let keywordsBeforeWrite: [String]

    var itemPhotoId: String { persistedItem.photoId }
}

// writeback-planners.ts（writeback-planners.ts 全量）
// ────────────────────────────────────────────────────────────

/// TS: buildSimilarityKeywordPlan —— 相似度分组关键词 → 按侧车聚合 + 受影响路径集。
public func buildSimilarityKeywordPlan(
    groups: [SimilarityGroup],
    assignments: [(groupId: Int, keywords: [String])]
) throws -> (keywordsBySidecar: [String: [String]], affectedPaths: Set<String>) {
    let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    var keywordsBySidecar: [String: [String]] = [:]
    var affectedPaths = Set<String>()
    for assignment in assignments {
        guard let group = groupsById[assignment.groupId] else {
            throw WritebackPlannerError.groupNotInSession
        }
        for image in group.images {
            affectedPaths.insert(image.path)
            let sidecarPath = TSPath.xmpSidecarPath(image.path)
            keywordsBySidecar[sidecarPath] = orderedUnion(
                keywordsBySidecar[sidecarPath] ?? [],
                assignment.keywords
            )
        }
    }
    return (keywordsBySidecar, affectedPaths)
}

/// TS: buildFaceKeywordAdditions —— 人脸簇绑定 → 每照片关键词追加。
/// 实现见 FaceKwService.buildFaceKeywordAdditions（同 TS 源
/// writeback-planners.ts:48，本文件不重复定义）。

public enum WritebackPlannerError: Error, Equatable, CustomStringConvertible {
    case groupNotInSession // WRITEBACK_GROUP_NOT_IN_SESSION

    public var description: String {
        switch self {
        case .groupNotInSession: "WRITEBACK_GROUP_NOT_IN_SESSION"
        }
    }
}
