// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryCoordinator.swift
// WP2b：交付编排的**门面**（confirm / cleanup / finalize / mirror / replay）。
//
// 本文件在 WP2b 被拆成四层，各自只有一个入口：
// - DeliveryStateMachine：显式迁移表与命名判定（能不能）；
// - DeliveryStateWriter：所有 deliveries/delivery_items 状态写入（写什么）；
// - DeliveryIntentStore + DeliveryFilePhase + DeliveryDBPhase：saga 三段
//   （prepare → 文件阶段 → 单事务 DB 删除 + finish）；
// - DeliveryCleanupFlow / DeliveryReplayFlow / DeliveryMirrorWriter：逐交付控制流。
//
// 门面只做参数校验、门禁错误映射、只读摘要与组件装配，不再内联状态/SQL/文件逻辑；
// confirm 的完整性/reload-ack 门禁与写状态已合并进同一个 Repo 事务（P1-3）。
// 公开 API（init / confirm / cleanup / finalize / mirrorWriteback / replay /
// sessionSummary / metadataSummary）与 WP2a 逐字一致，调用方零改动。
//
// 模块适配器（5 方法 + module/capabilities/engine）已移出本类型：
// 见 Ports/DeliveryModulePorts.swift。

import Foundation
import GatherPersistence
import GatherProtocol

/// WP7b：交付侧的关联标识（只在日志里使用，不参与任何业务判定）。
///
/// 约定：`delivery:<id>/rev:<revision>/<phase>`。
/// - id / revision 来自交付行（cleanup/finalize）或 intent payload 的 prepare 快照（replay）；
/// - phase ∈ confirm / file / db / intent；
/// - confirm 是 (session, module) 级事务、没有单条交付 id：id 段用
///   `session:<sessionId>`、revision 固定 0（唯一例外，见 WP7b 台账）。
/// GatherLogger.log 不抛错（内部只做等级过滤 + sink 回调），因此日志不会改变
/// 返回值、错误或业务时序；sink 自身抛错也不是本类型能观察到的语义。
enum DeliveryTrace {
    static func text(id: String, revision: Int64, phase: String) -> String {
        "delivery:\(id)/rev:\(revision)/\(phase)"
    }

    static func text(deliveryId: Int64, revision: Int64, phase: String) -> String {
        text(id: String(deliveryId), revision: revision, phase: phase)
    }

    /// 统一字段序：trace → event → op → phase → 具体键值（供 grep / 测试断言）。
    static func log(_ trace: String, _ fields: String, level: LogLevel) {
        GatherLogger.log("trace=\(trace) \(fields)", level: level)
    }
}

public struct DeliveryCoordinator: Sendable {
    private let connection: DBConnection
    private let deliveryRepo: DeliveryRepo
    private let intentStore: DeliveryIntentStore
    private let stateWriter: DeliveryStateWriter
    private let summaryQuery: DeliverySummaryQuery
    private let files: any DeliveryFilePort
    /// 与 WritebackService 共享的按 xmpPath 文件锁（P0-1 收口）。
    /// cleanup/finalize/replay 的 verify → 文件阶段 → 事后再 verify 整体在锁内，
    /// 消除“旧备份覆盖新写入”的 TOCTOU 窗口；同一实例必须由组合根注入。
    private let fileLock: XMPFileLock
    private let fingerprint: DeliveryFingerprintProvider
    private let resolvePhotoPath: DeliveryPhotoPathResolver
    /// reload_acked_at 门禁（§5.4-2）。默认开启；测试/嵌入场景可显式关闭，
    /// 生产组合根不得关闭（否则确认/收尾会绕过 Capture One 的重载确认）。
    private let requireReloadAckEnabled: Bool
    /// 交付状态变化后的会话级通知（宿主刷新 C1 同步徽标）。
    ///
    /// S5c-2b-3b-2b-2：旧 MetadataSyncCoordinator 删除后，confirm/cleanup/finalize/
    /// 镜像这些会推进交付状态的动作必须仍能驱动 UI 刷新（SimilarityView /
    /// C1StatusCapsule 监听 c1-sync-status）。闭包只拿到 sessionId，不暴露内部行。
    private let eventSink: (@Sendable (String) -> Void)?

    public init(
        connection: DBConnection,
        deliveryRepo: DeliveryRepo,
        intentRepo: DeliveryIntentRepo,
        files: any DeliveryFilePort,
        fileLock: XMPFileLock = .shared,
        fingerprint: @escaping DeliveryFingerprintProvider = {
            try await MetadataFingerprint.contentFingerprint($0)
        },
        resolvePhotoPath: @escaping DeliveryPhotoPathResolver = { _, delivery in
            delivery.photoPath
        },
        requireReloadAck: Bool = true,
        eventSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.connection = connection
        self.deliveryRepo = deliveryRepo
        self.intentStore = DeliveryIntentStore(repo: intentRepo)
        self.stateWriter = DeliveryStateWriter(repo: deliveryRepo)
        self.summaryQuery = DeliverySummaryQuery(connection: connection)
        self.files = files
        self.fileLock = fileLock
        self.fingerprint = fingerprint
        self.resolvePhotoPath = resolvePhotoPath
        self.requireReloadAckEnabled = requireReloadAck
        self.eventSink = eventSink
    }

    /// 便捷构造：repo 由同一 connection 派生。
    public init(
        connection: DBConnection,
        files: any DeliveryFilePort,
        fileLock: XMPFileLock = .shared,
        fingerprint: @escaping DeliveryFingerprintProvider = {
            try await MetadataFingerprint.contentFingerprint($0)
        },
        resolvePhotoPath: @escaping DeliveryPhotoPathResolver = { _, delivery in
            delivery.photoPath
        },
        requireReloadAck: Bool = true,
        eventSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.init(
            connection: connection,
            deliveryRepo: DeliveryRepo(connection: connection),
            intentRepo: DeliveryIntentRepo(connection: connection),
            files: files,
            fileLock: fileLock,
            fingerprint: fingerprint,
            resolvePhotoPath: resolvePhotoPath,
            requireReloadAck: requireReloadAck,
            eventSink: eventSink
        )
    }

    /// 便捷构造：宿主已有 XMPProvider 时直接适配。
    public init(
        connection: DBConnection,
        xmp: any XMPProvider,
        fileLock: XMPFileLock = .shared,
        fingerprint: @escaping DeliveryFingerprintProvider = {
            try await MetadataFingerprint.contentFingerprint($0)
        },
        resolvePhotoPath: @escaping DeliveryPhotoPathResolver = { _, delivery in
            delivery.photoPath
        },
        requireReloadAck: Bool = true,
        eventSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.init(
            connection: connection,
            files: XMPDeliveryFilePort(xmp),
            fileLock: fileLock,
            fingerprint: fingerprint,
            resolvePhotoPath: resolvePhotoPath,
            requireReloadAck: requireReloadAck,
            eventSink: eventSink
        )
    }

    /// 交付状态已变化：通知宿主（sessionId 为空不通知）。
    private func emitStateChanged(_ sessionId: String) {
        guard !sessionId.isEmpty, let eventSink else { return }
        eventSink(sessionId)
    }

    // MARK: - 组件装配

    private func makeFilePhase() -> DeliveryFilePhase {
        DeliveryFilePhase(
            deliveryRepo: deliveryRepo,
            files: files,
            fileLock: fileLock,
            fingerprint: fingerprint
        )
    }

    private func makeDBPhase() -> DeliveryDBPhase {
        DeliveryDBPhase(
            connection: connection,
            deliveryRepo: deliveryRepo,
            writer: stateWriter,
            intents: intentStore
        )
    }

    private func makeCleanupFlow() -> DeliveryCleanupFlow {
        DeliveryCleanupFlow(
            deliveryRepo: deliveryRepo,
            writer: stateWriter,
            intents: intentStore,
            summaryQuery: summaryQuery,
            filePhase: makeFilePhase(),
            dbPhase: makeDBPhase(),
            resolvePhotoPath: resolvePhotoPath,
            emitStateChanged: { [eventSink] sessionId in
                guard !sessionId.isEmpty, let eventSink else { return }
                eventSink(sessionId)
            }
        )
    }

    private func makeReplayFlow() -> DeliveryReplayFlow {
        DeliveryReplayFlow(
            intents: intentStore,
            writer: stateWriter,
            filePhase: makeFilePhase(),
            dbPhase: makeDBPhase()
        )
    }

    private func makeMirrorWriter() -> DeliveryMirrorWriter {
        // 镜像的租约 owner 按调用生成：镜像是一次同步短序列，不跨调用复用身份。
        DeliveryMirrorWriter(
            repo: deliveryRepo,
            writer: stateWriter,
            leaseOwner: "mirror-" + UUID().uuidString)
    }

    // MARK: - 派生状态

    /// 会话级派生状态（只读；不写 sessions 列，D-021）。
    public func sessionSummary(
        sessionId: String,
        module: DeliveryModule? = nil
    ) throws -> DeliverySessionSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        return try summaryQuery.summary(sessionId: sessionId, module: module)
    }

    /// 旧 MetadataSyncSummary 投影（syncStatus/flush/retry/finalize 的统一返回）。
    /// 只读聚合，不写 sessions.writeback_status（D-021）。
    public func metadataSummary(
        sessionId: String,
        module: DeliveryModule? = nil
    ) throws -> MetadataSyncSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        return try summaryQuery.metadataSummary(sessionId: sessionId, module: module)
    }

    /// §5.4-2 reload_acked_at 门禁：Capture One 未确认重载前，finalize 不得
    /// 推进状态（旧 MetadataSyncCoordinator.requireReloadAck 的同一语义）。
    /// confirm 的同一门禁已下沉到 DeliveryRepo.confirm 的事务内（P1-3）。
    ///
    /// 直接读 sessions.reload_acked_at，而不是 SessionRepo.get：后者的投影仍带
    /// S5c-3 前的 legacy 列（writeback_status/import_source/failed_writeback_count），
    /// 在纯 SchemaV1 上会 SQL 编译失败。单列读取与旧实现逐字一致，也不用内存 ack
    /// （冷启动同样有效）。
    private func requireReloadAck(_ sessionId: String) throws {
        guard requireReloadAckEnabled else { return }
        let row = try connection.prepare(
            "SELECT reload_acked_at FROM sessions WHERE id = ?"
        ).get([.text(sessionId)])
        guard let acked = row?[0].textValue, !acked.isEmpty else {
            throw DeliveryCoordinatorError.reloadNotAcknowledged(sessionId: sessionId)
        }
    }

    // MARK: - confirm

    /// 会话对某模块的确认：门禁读与 confirmed_at/状态更新在同一个事务内（P1-3）。
    ///
    /// 门禁只拦 pending/writing/failed/conflict（交付或 item）；written 合法。
    /// 跨会话未确认不是抛错：本会话的 confirmed_at 先落地（进度可累积），
    /// 返回的 DeliveryConfirmSummary.unconfirmedSessionIds 指名阻塞会话，delivery 留在
    /// written，等对方 confirm 后才翻 synced（与 draft §5.4 的跨会话门禁一致）。
    ///
    /// 顺序不变：先查完整性，再查 reload-ack，最后才写状态；区别是这三步现在由
    /// DeliveryRepo.confirm 在**同一个事务**内完成，门禁读与写入之间没有窄窗口。
    /// 未 ack / 有阻断时 confirmed_at 不落地（避免"确认了一半"的假进度）。
    public func confirm(sessionId: String, module: DeliveryModule) throws -> DeliveryConfirmSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        let trace = DeliveryTrace.text(id: "session:\(sessionId)", revision: 0, phase: "confirm")
        do {
            // DB 阶段边界：完整性 / reload-ack 门禁与 confirm 的单事务合一。
            DeliveryTrace.log(
                trace,
                "event=start op=confirm phase=confirm module=\(module.rawValue)",
                level: .info)
            let confirmed = try stateWriter.confirm(
                scope: .module,
                sessionId: sessionId,
                module: module,
                requireReloadAck: requireReloadAckEnabled)
            DeliveryTrace.log(
                trace,
                "event=done op=confirm phase=confirm module=\(module.rawValue) "
                    + "links=\(confirmed.confirmedLinks) deliveries=\(confirmed.deliveriesSynced) "
                    + "items=\(confirmed.itemsSynced) "
                    + "unconfirmed=\(confirmed.unconfirmedSessionIds.count)",
                level: .info)
            emitStateChanged(sessionId)
            return confirmed
        } catch let gate as DeliveryConfirmGateError {
            // Repo 的事务内门禁 → 旧 Coordinator 错误码（调用方/UI 的契约不变）。
            let mapped: DeliveryCoordinatorError
            switch gate {
            case .incomplete(let blockers):
                mapped = .confirmIncomplete(blockers: blockers)
            case .reloadNotAcknowledged:
                mapped = .reloadNotAcknowledged(sessionId: sessionId)
            }
            DeliveryTrace.log(
                trace,
                "event=failed op=confirm phase=confirm module=\(module.rawValue) "
                    + "reason=\(mapped)",
                level: .warn)
            throw mapped
        } catch {
            // 事务失败（SQL/约束）带 phase + reason。
            DeliveryTrace.log(
                trace,
                "event=failed op=confirm phase=confirm module=\(module.rawValue) "
                    + "reason=\(error)",
                level: .warn)
            throw error
        }
    }

    // MARK: - cleanup / finalize

    /// 清理本会话在本模块下已确认（synced）的交付。
    ///
    /// 每个交付独立走三段：prepare → 文件恢复 → advance(fileDone) → DB 删除 → finish。
    /// 文件/DB 失败保留 intent 并继续处理下一个交付（单交付失败不拖垮整批）。
    /// 已有未完成 intent 的交付会被跳过（由 replay() 统一重试，避免重复 prepare）。
    public func cleanup(
        sessionId: String,
        module: DeliveryModule
    ) async throws -> DeliveryCleanupSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        return try await makeCleanupFlow().cleanup(sessionId: sessionId, module: module)
    }

    /// 结束会话：只处理 synced 交付；**保留 XMP 原样**，删除 items/links/delivery
    /// 与备份文件（刻意不 restore）。
    ///
    /// 与 cleanup 的差别只在文件阶段；DB 段复用 DeliveryRepo.deleteSyncedDelivery。
    /// 仍走 intent 前滚：prepared → 删备份（fileDone）→ CAS 删行 → finish；
    /// 任一步失败都保留 intent，replay() 可重试。冲突/非 synced 交付不是候选，
    /// 原样保留（等用户裁决/重新写入）。
    public func finalize(
        sessionId: String,
        module: DeliveryModule
    ) async throws -> DeliveryFinalizeSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        try requireReloadAck(sessionId)
        return try await makeCleanupFlow().finalize(sessionId: sessionId, module: module)
    }

    // MARK: - 写回镜像

    /// 把旧 WritebackService 的结果镜像进 deliveries / delivery_items / delivery_sessions。
    /// 失败不抛出（XMP 已落盘）：逐条进 errors，由调用方并入 WritebackResult.errors。
    public func mirrorWriteback(
        sessionId: String,
        module: DeliveryModule,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        let summary = try makeMirrorWriter().mirrorWriteback(
            sessionId: sessionId, module: module, items: items)
        emitStateChanged(sessionId)
        return summary
    }

    // MARK: - replay

    /// 启动回放（幂等）：先删除 applied 终态，再按相位处理 prepared/fileDone。
    ///
    /// - prepared：重做文件 + 重做 DB（restore 是覆盖写，幂等）；
    /// - fileDone：只补 DB，绝不重放文件；
    /// - applied ：已由 replayAll() 删除。
    ///
    /// 单条失败不抛出：保留 intent（prepared/fileDone）等待下次重试，错误进 summary。
    public func replay() async throws -> DeliveryReplaySummary {
        try await makeReplayFlow().replay()
    }

    /// 旧调用点兼容（Host/AppRuntime 的启动回放）：含义与 replay() 完全相同。
    /// 这不是模块方法；WP2c 接线可把它并入 replay() 并删掉。
    public func replayPendingDeliveries() async throws -> DeliveryReplaySummary {
        try await replay()
    }
}
