// desktop/native/gather-core/Sources/GatherDomain/Services/DeliveryCoordinator.swift
// Cut 2 / S4-S5c-2b-1：统一交付模型的**服务层编排**
// （confirm + cleanup/finalize 文件阶段 + writeback 镜像 + intent 回放）。
//
// 设计要点（draft §5.4 / §5.5，D-021 / D-023 / D-031 / D-037）：
// 1. **接线状态**：S5c-2b-1 起 CullingService 的 confirm/cleanup/finalize/
//    syncStatus/flush/retry 与 writeback 镜像已接本文件（CullingDeliveryPort，
//    module=.culling）；S5c-2b-2 起 FaceKwService / SimilarityService 的
//    writeback 镜像与 confirm/cleanup 也接本文件（FaceKwDeliveryPort /
//    SimilarityDeliveryPort，module=.faceKeyword/.similarity）。文件写入仍由旧
//    WritebackService 执行（过渡双写）；旧服务/表删除留 S5c-2b-3。
// 2. **confirm 无 await**：门禁读 + DeliveryRepo.confirm 单事务。门禁（pending/writing/
//    failed/conflict）用 DeliverySummaryQuery 只读判断；会话状态由聚合派生，绝不写
//    sessions.writeback_status（V1 已删该列，D-021）。
// 3. **cleanup/finalize 文件阶段持 XMPFileLock**（P0-1 TOCTOU）：锁内重读
//    revision/status/指纹 → restore/remove → 事后复核；与 WritebackService 写盘
//    互斥。守卫仍需保留（锁外仍有 DB 新输入）。
// 4. **cleanup/finalize 分三段**：文件阶段不可回滚，所以用 delivery_intents 前滚：
//      prepare(prepared) → 文件阶段 → advance(fileDone) → DB 删除 → finish(删除 intent)。
//    cleanup 的文件阶段是 restore（无备份则删侧车）；finalize 是 dropWithoutRestore
//    （只删备份，XMP 原样保留）。任一步失败都保留 intent（prepared 或 fileDone），
//    下次 replay() 重试。
// 5. **replay 相位语义**（draft §5.5 三条硬规则）：
//      prepared：重做文件 + 重做 DB；
//      fileDone：只补 DB，绝不重放文件；
//      applied ：replayAll() 启动时直接删除 intent 行。
//    deliveries 删除带 revision 守卫：期间有新输入（revision 变了）就不删，intent 标
//    applied + error（新输入必须保留）。
// 6. **外部修改**：cleanup 前比对 base_fingerprint；不一致就把交付标 conflict 并跳过，
//    文件、DB、intent 都不动。
// 7. **依赖注入**：DeliveryRepo / DeliveryIntentRepo / DeliveryFilePort（XMPProvider 的
//    restore/delete/exists 窄端口）/ 指纹闭包 / photoPath 解析闭包。coordinator 自身不碰
//    FileManager，测试可用内存 fake 覆盖崩溃回放。
// 8. **跨模块 item 门禁（P1-8）**：交付是一个侧车文件，item 才分模块；cleanup 删除
//    交付前检查该交付的**所有** item。任一 item 非 synced（pending/failed/written）→
//    skip + XMP_CLEANUP_INCOMPLETE_ITEMS，不碰文件/DB；全部 synced 但仍有其它模块
//    item → 只清本模块 item、保留交付（XMP_CLEANUP_RETAINED_FOREIGN_ITEMS）。
//    DB 段在同一事务内复核，覆盖文件阶段 await 期间新增 item 的竞态与 replay。
//
// 已接线（S5c-2b-1/2b-2）：culling writeback 镜像、syncStatus/flush/retry 读
// DeliverySummaryQuery、finalize(dropWithoutRestore)、confirm/finalize 的
// reload_acked_at 门禁；faceKeyword/similarity 的 writeback 镜像与 confirm/cleanup。
// 未接线：Database.open 启动时调用 replay()、旧服务/表删除（2b-3）。

import Foundation
import GatherPersistence
import GatherProtocol

// MARK: - 文件端口

/// cleanup 只需要 XMPProvider 的三个能力：存在性、restore、removeFile。
/// 用窄端口而不是整个 XMPProvider，避免 coordinator 依赖读写/备份等无关方法。
public protocol DeliveryFilePort: Sendable {
    func fileExists(_ path: String) -> Bool
    func restore(photoPath: String, backupPath: String) async throws
    func removeFile(_ path: String) async throws
}

/// XMPProvider → DeliveryFilePort 的适配器（宿主接线用）。
public struct XMPDeliveryFilePort: DeliveryFilePort {
    private let provider: any XMPProvider

    public init(_ provider: any XMPProvider) {
        self.provider = provider
    }

    public func fileExists(_ path: String) -> Bool {
        provider.fileExists(path)
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        try await provider.restore(photoPath: photoPath, backupPath: backupPath)
    }

    public func removeFile(_ path: String) async throws {
        try await provider.removeFile(path)
    }
}

/// 内容指纹（cleanup 的外部修改检测）。默认走 MetadataFingerprint；测试注入假值。
public typealias DeliveryFingerprintProvider =
    @Sendable (_ xmpPath: String) async throws -> String

/// photoPath 解析（可接 PhotoAssetResolver）。默认直接用 deliveries.photo_path。
/// sessionId 供宿主按当前会话的资产解析规则返回真实照片路径。
public typealias DeliveryPhotoPathResolver =
    @Sendable (_ sessionId: String, _ delivery: DeliveryRow) throws -> String

// MARK: - 错误 / 结果

/// coordinator 的显式失败（不映射 GatherErrorCode；D-023 第 5 条，API 边界再转）。
public enum DeliveryCoordinatorError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// confirm 门禁：存在 pending/writing/failed/conflict 的交付或 item。
    case confirmIncomplete(blockers: [String])
    /// reload_acked_at 门禁（§5.4-2）：Capture One 尚未确认重载元数据。
    ///
    /// 码值沿用旧 UI 认得的 XMP_CONFIRM_REQUIRES_SYNC：S5c-2a 之前 confirm/finalize
    /// 在「不能收口」时抛的就是这个码；旧的 XMP_RELOAD_NOT_ACKED 仍由
    /// MetadataSyncCoordinator 保留（S5c-2b-3 删除旧链路后自然消失）。
    case reloadNotAcknowledged(sessionId: String)
    /// cleanup 的备份文件不存在（不删 DB、不误删侧车）。
    case backupMissing(xmpPath: String)
    /// 回放时 payload_json 缺字段/损坏。
    case invalidPayload(intentId: Int64, reason: String)
    /// 调用参数非法。
    case invalidArgument(String)
    /// 文件阶段已按旧快照执行，但 await 期间交付已被新输入/重写推进（P0-1）。
    /// 旧备份可能已覆盖新内容，必须显式上报并放弃 intent，不得静默当成功。
    case filePhaseInvalidated(xmpPath: String, reason: String)

    public var code: String {
        switch self {
        case .confirmIncomplete: return "XMP_CONFIRM_INCOMPLETE"
        case .reloadNotAcknowledged: return "XMP_CONFIRM_REQUIRES_SYNC"
        case .backupMissing: return "XMP_BACKUP_MISSING"
        case .invalidPayload: return "XMP_CLEANUP_INVALID_PAYLOAD"
        case .invalidArgument: return "DELIVERY_COORDINATOR_INVALID_ARGUMENT"
        case .filePhaseInvalidated: return "XMP_CLEANUP_FILE_PHASE_INVALIDATED"
        }
    }

    public var description: String {
        switch self {
        case .confirmIncomplete(let blockers):
            return "\(code): " + blockers.joined(separator: ",")
        case .reloadNotAcknowledged(let sessionId):
            return "\(code): \(sessionId)"
        case .backupMissing(let xmpPath):
            return "\(code): \(xmpPath)"
        case .invalidPayload(let intentId, let reason):
            return "\(code): #\(intentId) \(reason)"
        case .invalidArgument(let message):
            return "\(code): \(message)"
        case .filePhaseInvalidated(let xmpPath, let reason):
            return "\(code): \(xmpPath) reason=\(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// cleanup 的逐交付结果。errors 与 conflicted/skipped 分开，调用方可只对 errors 重试。
public struct DeliveryCleanupSummary: Sendable, Equatable {
    /// 真正删除了 deliveries 行的数量。
    public let deletedCount: Int
    /// 检测到外部修改、已标 conflict 且未删除的数量。
    public let conflictedCount: Int
    /// 未到 synced/已有未完成 intent/revision 已变等「本轮不处理」的数量。
    public let skippedCount: Int
    /// 可重试的失败（文件/DB/intent 写入），对应 intent 被保留。
    public let errors: [String]
    /// 检测到外部修改、已标 conflict 的侧车路径（按发现顺序）。
    /// 与 errors 分开：冲突不是「可重试失败」，而是需要用户裁决的外部修改；
    /// 调用方（如 CullingService.cleanup）据此把冲突按路径回填到旧 CleanupResult.errors。
    public let conflictedXmpPaths: [String]

    public init(
        deletedCount: Int,
        conflictedCount: Int,
        skippedCount: Int,
        errors: [String],
        conflictedXmpPaths: [String] = []
    ) {
        self.deletedCount = deletedCount
        self.conflictedCount = conflictedCount
        self.skippedCount = skippedCount
        self.errors = errors
        self.conflictedXmpPaths = conflictedXmpPaths
    }
}

/// 启动回放结果。
public struct DeliveryReplaySummary: Sendable, Equatable {
    /// 成功闭环（intent 删除）的数量。
    public let appliedCount: Int
    /// 因 revision/状态已变而终止（intent 标 applied + error）的数量。
    public let skippedCount: Int
    /// 仍保留 intent、下次 replay() 可重试的数量。
    public let failedCount: Int
    public let errors: [String]

    public init(
        appliedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        errors: [String]
    ) {
        self.appliedCount = appliedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.errors = errors
    }
}

/// finalize（dropWithoutRestore）的逐交付结果。
/// 与 cleanup 的区别：文件阶段只删除备份，绝不 restore；冲突交付不是候选（只处理 synced）。
public struct DeliveryFinalizeSummary: Sendable, Equatable {
    /// 真正删除了 deliveries 行的数量。
    public let deletedCount: Int
    /// 状态已变/已有未完成 intent/revision 已变等「本轮不处理」的数量。
    public let skippedCount: Int
    /// 可重试的失败（文件/DB/intent 写入），对应 intent 被保留。
    public let errors: [String]

    public init(deletedCount: Int, skippedCount: Int, errors: [String]) {
        self.deletedCount = deletedCount
        self.skippedCount = skippedCount
        self.errors = errors
    }
}

/// 旧 WritebackService 的执行结果 → 交付镜像的窄输入（S5c-2b-1 过渡双写）。
///
/// 为什么不让 coordinator 读 MetadataOutboxRow：outbox 是 S5c-2b-3 要删的旧模型；
/// 基线/备份路径由 CullingService 在过渡期从 outbox 抄出后显式传入，coordinator
/// 不反向依赖旧仓储。
public struct DeliveryWritebackMirrorItem: Sendable, Equatable {
    public let photoId: String
    public let photoPath: String
    public let xmpPath: String
    /// 写盘后的关键词（已合并既有词与计划词）。
    public let keywords: [String]
    /// rating/label 等结构化属性（keywords 已单列，不重复写入）。
    public let attributes: [String: JSONValue]
    /// 只允许 .written / .failed（pending 表示没执行，不镜像）。
    public let status: DeliveryItemStatus
    public let errorMessage: String
    public let backupPath: String
    public let baseFingerprint: String
    public let baseValues: JSONValue

    public init(
        photoId: String,
        photoPath: String,
        xmpPath: String,
        keywords: [String],
        attributes: [String: JSONValue] = [:],
        status: DeliveryItemStatus,
        errorMessage: String = "",
        backupPath: String = "",
        baseFingerprint: String = "",
        baseValues: JSONValue = .object([:])
    ) {
        self.photoId = photoId
        self.photoPath = photoPath
        self.xmpPath = xmpPath
        self.keywords = keywords
        self.attributes = attributes
        self.status = status
        self.errorMessage = errorMessage
        self.backupPath = backupPath
        self.baseFingerprint = baseFingerprint
        self.baseValues = baseValues
    }
}

/// 写回镜像结果（按交付分组后的计数 + 可重试/可诊断错误）。
public struct DeliveryMirrorSummary: Sendable, Equatable {
    public let deliveryCount: Int
    public let itemCount: Int
    public let errors: [String]

    public init(deliveryCount: Int, itemCount: Int, errors: [String]) {
        self.deliveryCount = deliveryCount
        self.itemCount = itemCount
        self.errors = errors
    }
}

/// 写回基线（S5c-2b-3b-2a）：执行器已把真实备份/指纹/基线直接写进 deliveries，
/// 镜像（Culling/FaceKw/Similarity 的 execute 后置步骤）只回读同一行，不再从
/// metadata_outbox 抄（旧表随 2b 删除，本类型保留为镜像的窄输入）。
struct DeliveryWritebackBaseline: Sendable, Equatable {
    let backupPath: String
    let baseFingerprint: String
    let baseValues: JSONValue

    static let empty = DeliveryWritebackBaseline(
        backupPath: "", baseFingerprint: "", baseValues: .object([:])
    )
}

/// 按 xmpPath 读交付行上的基线；行不存在 → 空基线（不阻塞镜像）。
/// 不抛错：镜像失败可回退为空基线，绝不让"读不到基线"伪造成写盘失败。
func deliveryWritebackBaseline(
    connection: DBConnection,
    xmpPath: String
) -> DeliveryWritebackBaseline {
    do {
        guard let row = try DeliveryRepo(connection: connection).get(xmpPath) else {
            return .empty
        }
        return DeliveryWritebackBaseline(
            backupPath: row.backupPath,
            baseFingerprint: row.baseFingerprint,
            baseValues: row.baseValues
        )
    } catch {
        GatherLogger.log(
            "delivery writeback baseline unavailable (\(xmpPath)): \(error)",
            level: .debug
        )
        return .empty
    }
}

// MARK: - intent payload

/// intent 的动作（同一 kind=.cleanup 的两种文件语义）。
///
/// SchemaV1 的 delivery_intents.kind 只有 cleanup/write 两个合法值（S5c-2b-1 不改
/// Schema），finalize 复用 kind=.cleanup，用 payload.op 区分文件阶段：
/// - cleanup：恢复备份（或删除本次写入的侧车），然后删行；
/// - finalize：保留 XMP 原样，只删除备份文件，然后删行（dropWithoutRestore）。
/// 旧 intent（S5c-2a）没有 op 键 → 默认 cleanup，回放向前兼容。
enum DeliveryIntentAction: String, Equatable {
    case cleanup
    case finalize
}

/// cleanup / finalize intent 的 payload（回放只靠它 + delivery_intents.xmp_path，
/// 不依赖父行存在）。
struct DeliveryCleanupPayload: Equatable {
    let action: DeliveryIntentAction
    let deliveryId: Int64
    let revision: Int64
    /// prepare 时的交付状态快照（cleanup/finalize 只处理 synced）。
    let status: String
    let backupPath: String
    let photoPath: String
    /// prepare 时的 deliveries.base_fingerprint（S5c 写入基线）。
    ///
    /// P0-1：文件阶段（restore / 无备份删侧车 / replay prepared）前必须用它
    /// 与重读的交付行 + 盘上指纹三方比对。旧 intent 没有该键 → ""：
    /// 仍做 id/revision/status 守卫，指纹退回当前行的 base_fingerprint。
    let baseFingerprint: String
    /// 发起本次 cleanup 的模块（P1-8）。
    ///
    /// 删除交付前要用它区分“本模块 item”与“文件级交付上其它模块的 item”；
    /// 旧 intent 没有该键 → nil：回放时退回“任何非 synced item 都阻断删除”的
    /// 保守判定（无法区分归属时宁可保留交付，也不静默删别人的输入）。
    let module: DeliveryModule?

    init(
        delivery: DeliveryRow,
        photoPath: String,
        action: DeliveryIntentAction = .cleanup,
        module: DeliveryModule? = nil
    ) {
        self.action = action
        self.deliveryId = delivery.id
        self.revision = delivery.revision
        self.status = delivery.status
        self.backupPath = delivery.backupPath
        self.photoPath = photoPath
        self.baseFingerprint = delivery.baseFingerprint
        self.module = module
    }

    init?(intent: DeliveryIntentRow) {
        guard let idValue = intent.payload["delivery_id"]?.numberValue,
              let deliveryId = Int64(exactly: idValue),
              deliveryId > 0,
              let revisionValue = intent.payload["revision"]?.numberValue,
              let revision = Int64(exactly: revisionValue),
              revision >= 0
        else { return nil }
        self.action = intent.payload["op"]?.stringValue
            .flatMap(DeliveryIntentAction.init(rawValue:)) ?? .cleanup
        self.deliveryId = deliveryId
        self.revision = revision
        // 旧 intent（S5c-2a）没有 status/base_fingerprint：cleanup 候选只可能是
        // synced，按 synced 解释；指纹退回重读行，仍能检测外部修改。
        let status = intent.payload["status"]?.stringValue ?? ""
        self.status = status.isEmpty ? DeliveryStatus.synced.rawValue : status
        self.baseFingerprint = intent.payload["base_fingerprint"]?.stringValue ?? ""
        self.backupPath = intent.payload["backup_path"]?.stringValue ?? ""
        self.photoPath = intent.payload["photo_path"]?.stringValue ?? ""
        self.module = intent.payload["module"]?.stringValue
            .flatMap(DeliveryModule.init(rawValue:))
    }

    var json: JSONValue {
        .object([
            "op": .string(action.rawValue),
            "delivery_id": .int(deliveryId),
            "revision": .int(revision),
            "status": .string(status),
            "backup_path": .string(backupPath),
            "photo_path": .string(photoPath),
            "base_fingerprint": .string(baseFingerprint),
            "module": .string(module?.rawValue ?? ""),
        ])
    }
}

/// 文件阶段前的守卫结论（P0-1）。
///
/// 只有 .proceed 允许碰文件；其余分支都不得 restore/remove：
/// - .changed：交付行已被新输入/重写推进（revision/status/base_fingerprint 不一致）；
/// - .conflict：行快照一致但盘上内容已不是基线（外部修改）；
/// - .alreadyGone：行已被并发删除，无法确认盘上内容归属。
private enum DeliveryFilePhaseVerdict: Equatable {
    case proceed
    case alreadyGone
    case changed(reason: String)
    case conflict(reason: String)
}

/// 锁内文件阶段的整体结果（P0-1 + TOCTOU 收口）。
///
/// 守卫、restore/remove 与事后复核必须在**同一次** `XMPFileLock.run` 内完成：
/// 分成两次取锁会重新打开“验证通过 → 另一写者落盘 → 旧备份覆盖”的窗口。
/// - .completed：verify 放行且文件阶段（含事后复核）成功；
/// - .skipped：verify 判定不得碰文件（changed/conflict/alreadyGone）；
/// - .invalidated：文件已执行，但事后复核发现新输入（等价于 filePhaseInvalidated）；
/// - .guardFailed / .fileFailed：保留旧错误码语义的失败（intent 留在 prepared）。
private enum LockedFilePhaseOutcome: Sendable {
    case completed
    case skipped(DeliveryFilePhaseVerdict)
    case invalidated(reason: String)
    case guardFailed(reason: String)
    case fileFailed(reason: String)
}

/// cleanup 删除交付前的 item 门禁（P1-8）。
///
/// 交付是“一个侧车文件”粒度，item 是“(交付, 照片, 模块)”粒度；一个文件可以同时
/// 有 culling 与 metadata 的 item。模块级 cleanup 不能把其它模块的输入一起删掉：
/// - 任一 item 还不是 synced（pending/failed/written）→ 整条交付 skip；
/// - 全部 synced、但仍有其它模块的 item → 只清本模块 item，保留交付（留给
///   其它模块自己的 cleanup/finalize 收尾），且不碰文件（备份恢复会回滚别人的已确认内容）。
private enum CleanupItemGate: Equatable {
    case proceed
    case incomplete(module: String, status: String)
    case retainForeign(modules: [String])
}

/// DB 删除段的 CAS 结果（用于区分「已删」「新输入保留」「状态已变」）。
private enum CleanupDBOutcome: Equatable {
    case deleted
    case alreadyGone
    case revisionChanged
    case rowReplaced
    case stateChanged
    /// 该交付上仍有非 synced item（含其它模块）：DB 段拒绝删除。
    case foreignItemsPending(module: String, status: String)
    /// 全部 item 已 synced，但仍有其它模块 item：只清本模块 item，保留交付。
    case foreignItemsRetained(modules: [String])

    var reason: String {
        switch self {
        case .deleted: return "deleted"
        case .alreadyGone: return "already-gone"
        case .revisionChanged: return "revision-changed"
        case .rowReplaced: return "row-replaced"
        case .stateChanged: return "state-changed"
        case .foreignItemsPending(let module, let status):
            return "foreign-items-pending(\(module):\(status))"
        case .foreignItemsRetained(let modules):
            return "foreign-items-retained(\(modules.joined(separator: ",")))"
        }
    }
}

// MARK: - Coordinator

/// 统一交付模型的服务层编排（confirm / cleanup / replay）。
///
/// 线程模型：所有 DB 访问经 DBConnection 的递归锁串行；文件阶段不持 DB 锁，但
/// 同一归一化 xmpPath 的 verify → restore/remove → 事后 verify 由注入的
/// XMPFileLock 串行（与 WritebackService 写盘共用）。本类型无自有可变状态，
/// 可安全跨任务共享；cleanup 的重复 prepare 由未完成 intent 检查兜底。
public struct DeliveryCoordinator: Sendable {
    private let connection: DBConnection
    private let deliveryRepo: DeliveryRepo
    private let intentRepo: DeliveryIntentRepo
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
    private let requireReloadAck: Bool
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
        self.intentRepo = intentRepo
        self.summaryQuery = DeliverySummaryQuery(connection: connection)
        self.files = files
        self.fileLock = fileLock
        self.fingerprint = fingerprint
        self.resolvePhotoPath = resolvePhotoPath
        self.requireReloadAck = requireReloadAck
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

    /// §5.4-2 reload_acked_at 门禁：Capture One 未确认重载前，confirm/finalize
    /// 都不得推进状态（旧 MetadataSyncCoordinator.requireReloadAck 的同一语义）。
    ///
    /// 直接读 sessions.reload_acked_at，而不是 SessionRepo.get：后者的投影仍带
    /// S5c-3 前的 legacy 列（writeback_status/import_source/failed_writeback_count），
    /// 在纯 SchemaV1 上会 SQL 编译失败。单列读取与旧实现逐字一致，也不用内存 ack
    /// （冷启动同样有效）。
    private func requireReloadAck(_ sessionId: String) throws {
        guard requireReloadAck else { return }
        let row = try connection.prepare(
            "SELECT reload_acked_at FROM sessions WHERE id = ?"
        ).get([.text(sessionId)])
        guard let acked = row?[0].textValue, !acked.isEmpty else {
            throw DeliveryCoordinatorError.reloadNotAcknowledged(sessionId: sessionId)
        }
    }

    // MARK: - confirm

    /// 会话对某模块的确认：门禁读 + DeliveryRepo.confirm 单事务。
    ///
    /// 门禁只拦 pending/writing/failed/conflict（交付或 item）；written 合法。
    /// 跨会话未确认不是抛错：本会话的 confirmed_at 先落地（进度可累积），
    /// 返回的 DeliveryConfirmSummary.unconfirmedSessionIds 指名阻塞会话，delivery 留在
    /// written，等对方 confirm 后才翻 synced（与 draft §5.4 的跨会话门禁一致）。
    ///
    /// 顺序与旧 confirmSync 一致：先查完整性，再查 reload-ack，最后才写状态；
    /// 未 ack 时 confirmed_at 不落地（避免"确认了一半"的假进度）。
    public func confirm(sessionId: String, module: DeliveryModule) throws -> DeliveryConfirmSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        let summary = try summaryQuery.summary(sessionId: sessionId, module: module)
        guard summary.isConfirmable else {
            throw DeliveryCoordinatorError.confirmIncomplete(blockers: summary.blockers)
        }
        try requireReloadAck(sessionId)
        let confirmed = try deliveryRepo.confirm(
            scope: .module, sessionId: sessionId, module: module)
        emitStateChanged(sessionId)
        return confirmed
    }

    // MARK: - cleanup

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
        let candidates = try summaryQuery.cleanupCandidates(sessionId: sessionId, module: module)
        let backlog = try intentRepo.pending()
        var activeIntents = Set(backlog.all.map(\.xmpPath))

        var deletedCount = 0
        var conflictedCount = 0
        var skippedCount = 0
        var errors: [String] = []
        var conflictedXmpPaths: [String] = []

        for candidate in candidates {
            if activeIntents.contains(candidate.xmpPath) {
                skippedCount += 1
                errors.append("XMP_CLEANUP_INTENT_PENDING: \(candidate.xmpPath)")
                continue
            }
            // 重新读一次，避免候选查询与文件阶段之间状态漂移。
            guard let current = try deliveryRepo.get(candidate.xmpPath),
                  current.id == candidate.id,
                  current.typedStatus == .synced
            else {
                skippedCount += 1
                continue
            }

            // P1-8：删除前检查该交付的**所有**模块 item（文件级交付可能同时有
            // culling/metadata/... 的输入）。必须在 prepare/文件阶段之前：确认
            // 不能删时不得 restore/remove 侧车，也不得建 intent。
            let itemGate: CleanupItemGate
            do {
                itemGate = try cleanupItemGate(deliveryId: current.id, module: module)
            } catch {
                skippedCount += 1
                errors.append(Self.failure("XMP_CLEANUP_ITEM_GATE_FAILED", current.xmpPath, error))
                continue
            }
            switch itemGate {
            case .incomplete(let blockerModule, let status):
                skippedCount += 1
                errors.append(
                    "XMP_CLEANUP_INCOMPLETE_ITEMS: \(current.xmpPath) "
                        + "module=\(blockerModule) status=\(status)")
                continue
            case .retainForeign(let modules):
                // 本模块 item 已全部 synced，但同一文件上还有其它模块的 synced item：
                // 只清本模块 item，交付保留给其它模块收尾；绝不恢复/删除文件。
                do {
                    let removed = try deliveryRepo.deleteItems(
                        xmpPath: current.xmpPath, module: module, statuses: [.synced])
                    skippedCount += 1
                    errors.append(
                        "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: \(current.xmpPath) "
                            + "modules=\(modules.joined(separator: ",")) "
                            + "ownItemsRemoved=\(removed)")
                } catch {
                    skippedCount += 1
                    errors.append(
                        Self.failure("XMP_CLEANUP_ITEM_CLEANUP_FAILED", current.xmpPath, error))
                }
                continue
            case .proceed:
                break
            }

            // 外部修改：盘上内容已不是我们写入的基线 → conflict，不恢复、不删行。
            if !current.baseFingerprint.isEmpty {
                let currentFingerprint: String
                do {
                    currentFingerprint = try await fingerprint(current.xmpPath)
                } catch {
                    skippedCount += 1
                    errors.append(Self.failure("XMP_FINGERPRINT_FAILED", current.xmpPath, error))
                    continue
                }
                if currentFingerprint != current.baseFingerprint {
                    do {
                        let updated = try deliveryRepo.markConflict(
                            xmpPath: current.xmpPath,
                            revision: current.revision,
                            errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT"
                        )
                        if updated != nil {
                            conflictedCount += 1
                            conflictedXmpPaths.append(current.xmpPath)
                        } else {
                            skippedCount += 1
                        }
                    } catch {
                        skippedCount += 1
                        errors.append(Self.failure("XMP_CLEANUP_CONFLICT_FAILED", current.xmpPath, error))
                    }
                    continue
                }
            }

            let resolvedPhotoPath: String
            do {
                resolvedPhotoPath = try resolvePhotoPath(sessionId, current)
            } catch {
                skippedCount += 1
                errors.append(Self.failure("XMP_CLEANUP_PATH_FAILED", current.xmpPath, error))
                continue
            }

            let payload = DeliveryCleanupPayload(
                delivery: current, photoPath: resolvedPhotoPath, module: module)
            let intentId: Int64
            do {
                intentId = try intentRepo.prepare(
                    kind: .cleanup,
                    xmpPath: current.xmpPath,
                    payload: payload.json
                )
            } catch {
                errors.append(Self.failure("XMP_CLEANUP_PREPARE_FAILED", current.xmpPath, error))
                continue
            }
            activeIntents.insert(current.xmpPath)

            // P0-1 + TOCTOU：verify → restore/remove → 事后再 verify 整体在
            // XMPFileLock 内（与 WritebackService 同一实例）。prepare 之后新输入
            // 可能已把 revision+1 / status 改回 pending；锁内重读后仍不一致则
            // 绝不碰文件，直接放弃本次清理（intent 标终态 + 错误可见）。
            let phase = await runLockedFilePhase(
                xmpPath: current.xmpPath, payload: payload)
            switch phase {
            case .completed:
                break
            case .guardFailed(let reason):
                // 指纹读取失败：prepared 留库，下次 replay 重试。
                errors.append("XMP_CLEANUP_GUARD_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .fileFailed(let reason):
                // prepared 留在库里：下次 replay() 重做文件（restore 幂等）。
                errors.append("XMP_CLEANUP_FILE_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .invalidated(let reason):
                // restore/remove 的 await 期间出现新输入：文件可能已被旧备份覆盖，
                // 不得静默走 DB 删除；放弃 intent 并显式上报（DB 保留新输入）。
                skippedCount += 1
                errors.append("XMP_CLEANUP_FILE_RACED: \(current.xmpPath) reason=\(reason)")
                do {
                    try intentRepo.finish(
                        id: intentId, error: "XMP_CLEANUP_FILE_RACED: \(reason)")
                } catch {
                    errors.append(
                        Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
                continue
            case .skipped(let verdict):
                switch verdict {
                case .changed(let reason):
                    skippedCount += 1
                    errors.append("XMP_CLEANUP_ABANDONED: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intentRepo.finish(
                            id: intentId, error: "XMP_CLEANUP_ABANDONED: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .conflict(let reason):
                    do {
                        if try deliveryRepo.markConflict(
                            xmpPath: current.xmpPath,
                            revision: current.revision,
                            errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT"
                        ) != nil {
                            conflictedCount += 1
                            conflictedXmpPaths.append(current.xmpPath)
                        } else {
                            skippedCount += 1
                            errors.append(
                                "XMP_CLEANUP_GUARD_CONFLICT_CAS_FAILED: \(current.xmpPath) reason=\(reason)")
                        }
                    } catch {
                        skippedCount += 1
                        errors.append(
                            Self.failure("XMP_CLEANUP_CONFLICT_FAILED", current.xmpPath, error))
                    }
                    do {
                        try intentRepo.finish(
                            id: intentId,
                            error: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .alreadyGone:
                    // 行已被并发删除：无法确认盘上内容归属，不碰文件，幂等收尾。
                    skippedCount += 1
                    do { try intentRepo.finish(id: intentId) }
                    catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .proceed:
                    // 不可达：runLockedFilePhase 已把 proceed 转成 .completed。
                    continue
                }
            }

            do {
                _ = try intentRepo.advance(id: intentId, to: .fileDone)
            } catch {
                // 文件已做、相位没推进：prepared 回放会再恢复一次（幂等），不会跳过文件。
                errors.append(Self.failure("XMP_CLEANUP_ADVANCE_FAILED", current.xmpPath, error))
                continue
            }

            let outcome: CleanupDBOutcome
            do {
                outcome = try applyCleanupDB(xmpPath: current.xmpPath, payload: payload)
            } catch {
                // fileDone 留在库里：replay() 只补 DB，不重放文件。
                errors.append(Self.failure("XMP_CLEANUP_DB_FAILED", current.xmpPath, error))
                continue
            }

            switch outcome {
            case .deleted:
                deletedCount += 1
                do {
                    try intentRepo.finish(id: intentId)
                } catch {
                    errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
            case .alreadyGone:
                skippedCount += 1
                do {
                    try intentRepo.finish(id: intentId)
                } catch {
                    errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
            case .foreignItemsPending(let blockerModule, let status):
                // 文件阶段期间/回放时出现其它模块的未完成 item：DB 段已拒绝删除。
                // 文件可能已恢复，必须让调用方看见原因，不能静默当成功。
                skippedCount += 1
                errors.append(
                    "XMP_CLEANUP_INCOMPLETE_ITEMS: \(current.xmpPath) "
                        + "module=\(blockerModule) status=\(status)")
                do {
                    try intentRepo.finish(
                        id: intentId,
                        error: "XMP_CLEANUP_INCOMPLETE_ITEMS: \(blockerModule):\(status)")
                } catch {
                    errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
            case .foreignItemsRetained(let modules):
                // DB 段已清本模块 item 并保留交付（其它模块 synced item 仍在）。
                skippedCount += 1
                errors.append(
                    "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: \(current.xmpPath) "
                        + "modules=\(modules.joined(separator: ","))")
                do {
                    try intentRepo.finish(
                        id: intentId,
                        error: "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: "
                            + modules.joined(separator: ","))
                } catch {
                    errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
            case .revisionChanged, .rowReplaced, .stateChanged:
                skippedCount += 1
                // 文件阶段已经执行而 DB 守卫拒绝：必须让调用方看见
                // 「文件可能已旧、新输入仍保留」，不能只记 skipped。
                errors.append("XMP_CLEANUP_SKIPPED: \(current.xmpPath) reason=\(outcome.reason)")
                do {
                    try intentRepo.finish(
                        id: intentId,
                        error: "XMP_CLEANUP_SKIPPED: \(outcome.reason)"
                    )
                } catch {
                    errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
            }
        }

        emitStateChanged(sessionId)
        return DeliveryCleanupSummary(
            deletedCount: deletedCount,
            conflictedCount: conflictedCount,
            skippedCount: skippedCount,
            errors: errors,
            conflictedXmpPaths: conflictedXmpPaths
        )
    }

    // MARK: - finalize（dropWithoutRestore，S5c-2b-1）

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
        let candidates = try summaryQuery.syncedCandidates(sessionId: sessionId, module: module)
        let backlog = try intentRepo.pending()
        var activeIntents = Set(backlog.all.map(\.xmpPath))
        var deletedCount = 0
        var skippedCount = 0
        var errors: [String] = []

        for candidate in candidates {
            if activeIntents.contains(candidate.xmpPath) {
                skippedCount += 1
                errors.append("XMP_FINALIZE_INTENT_PENDING: \(candidate.xmpPath)")
                continue
            }
            // 候选查询与文件阶段之间状态可能漂移：重新读一次再 prepare。
            guard let current = try deliveryRepo.get(candidate.xmpPath),
                  current.id == candidate.id,
                  current.typedStatus == .synced
            else {
                skippedCount += 1
                continue
            }
            let resolvedPhotoPath: String
            do {
                resolvedPhotoPath = try resolvePhotoPath(sessionId, current)
            } catch {
                skippedCount += 1
                errors.append(Self.failure("XMP_FINALIZE_PATH_FAILED", current.xmpPath, error))
                continue
            }
            let payload = DeliveryCleanupPayload(
                delivery: current,
                photoPath: resolvedPhotoPath,
                action: .finalize
            )
            let intentId: Int64
            do {
                intentId = try intentRepo.prepare(
                    kind: .cleanup,
                    xmpPath: current.xmpPath,
                    payload: payload.json
                )
            } catch {
                errors.append(Self.failure("XMP_FINALIZE_PREPARE_FAILED", current.xmpPath, error))
                continue
            }
            activeIntents.insert(current.xmpPath)

            // P0-1 + TOCTOU：finalize 只删备份，但备份路径可能已被新一轮写入
            // 复用；verify（锁内 revision/status）→ 删备份 → 事后复核整体在
            // XMPFileLock 内，与 WritebackService 写盘共用同一实例。
            let phase = await runLockedFilePhase(
                xmpPath: current.xmpPath, payload: payload)
            switch phase {
            case .completed:
                break
            case .guardFailed(let reason):
                errors.append("XMP_FINALIZE_GUARD_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .fileFailed(let reason):
                // prepared 留在库里：下次 replay 重删备份（删除是幂等的）。
                errors.append("XMP_FINALIZE_FILE_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .invalidated(let reason):
                skippedCount += 1
                errors.append("XMP_FINALIZE_FILE_RACED: \(current.xmpPath) reason=\(reason)")
                do {
                    try intentRepo.finish(
                        id: intentId, error: "XMP_FINALIZE_FILE_RACED: \(reason)")
                } catch {
                    errors.append(
                        Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
                continue
            case .skipped(let verdict):
                switch verdict {
                case .changed(let reason):
                    skippedCount += 1
                    errors.append("XMP_FINALIZE_ABANDONED: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intentRepo.finish(
                            id: intentId, error: "XMP_FINALIZE_ABANDONED: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .conflict(let reason):
                    // finalize 不做指纹比对；conflict 分支不可达（仅清理编译器穷举）。
                    skippedCount += 1
                    errors.append("XMP_FINALIZE_ABANDONED: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intentRepo.finish(
                            id: intentId, error: "XMP_FINALIZE_ABANDONED: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .alreadyGone:
                    skippedCount += 1
                    do { try intentRepo.finish(id: intentId) }
                    catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .proceed:
                    continue
                }
            }
            do {
                _ = try intentRepo.advance(id: intentId, to: .fileDone)
            } catch {
                errors.append(Self.failure("XMP_FINALIZE_ADVANCE_FAILED", current.xmpPath, error))
                continue
            }

            let outcome: DeliveryRepo.DeliveryDeleteOutcome
            do {
                outcome = try deliveryRepo.deleteSyncedDelivery(
                    xmpPath: current.xmpPath,
                    deliveryId: payload.deliveryId,
                    revision: payload.revision
                )
            } catch {
                // fileDone 留在库里：replay() 只补 DB，不重放文件。
                errors.append(Self.failure("XMP_FINALIZE_DB_FAILED", current.xmpPath, error))
                continue
            }
            switch outcome {
            case .deleted:
                deletedCount += 1
                do { try intentRepo.finish(id: intentId) }
                catch { errors.append(Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error)) }
            case .alreadyGone:
                skippedCount += 1
                do { try intentRepo.finish(id: intentId) }
                catch { errors.append(Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error)) }
            case .idChanged, .revisionChanged, .stateChanged:
                skippedCount += 1
                // 文件阶段（删备份）已执行而 DB 守卫拒绝：错误必须可见。
                errors.append(
                    "XMP_FINALIZE_SKIPPED: \(current.xmpPath) reason=\(outcome.rawValue)")
                do {
                    try intentRepo.finish(
                        id: intentId,
                        error: "XMP_FINALIZE_SKIPPED: \(outcome.rawValue)"
                    )
                } catch {
                    errors.append(Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
            }
        }

        emitStateChanged(sessionId)
        return DeliveryFinalizeSummary(
            deletedCount: deletedCount,
            skippedCount: skippedCount,
            errors: errors
        )
    }

    // MARK: - 写回镜像（S5c-2b-1 过渡双写）

    /// 把旧 WritebackService 的结果镜像进 deliveries / delivery_items / delivery_sessions。
    ///
    /// 语义：
    /// - 每个 xmpPath 一条 delivery（与旧 outbox 的侧车粒度一致）；同侧车的多张照片
    ///   （RAW+JPEG）各一条 item；
    /// - 已有交付收到新输入 → revision + 1、状态回到 pending 再走 writing；
    ///   旧 revision 的 CAS 写入口因此不会覆盖本轮结果；
    /// - item 先回 pending 再写目标态，覆盖 synced→pending→written 的合法重开路径；
    /// - 有任一 written item → delivery=written；全部 failed → delivery=failed；
    ///   混合时交付保持 written，但 failed item 会让摘要/confirm 门禁看见失败；
    /// - 失败不抛出（XMP 已落盘）：逐条进 errors，由调用方并入 WritebackResult.errors。
    public func mirrorWriteback(
        sessionId: String,
        module: DeliveryModule,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        var grouped: [String: [DeliveryWritebackMirrorItem]] = [:]
        var errors: [String] = []
        for item in items {
            let path = TSPath.normalize(item.xmpPath)
            guard !path.isEmpty else {
                errors.append("DELIVERY_MIRROR_INVALID_PATH: photo=\(item.photoId)")
                continue
            }
            guard item.status == .written || item.status == .failed else {
                errors.append("DELIVERY_MIRROR_INVALID_STATUS: \(path) \(item.status.rawValue)")
                continue
            }
            grouped[path, default: []].append(item)
        }

        var deliveryCount = 0
        var itemCount = 0
        for (path, groupItems) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let first = groupItems.first, !first.photoPath.isEmpty else {
                errors.append("DELIVERY_MIRROR_MISSING_PHOTO_PATH: \(path)")
                continue
            }
            do {
                guard let revision = try openDeliveryForWrite(
                    xmpPath: path,
                    photoPath: first.photoPath,
                    baseFingerprint: first.baseFingerprint,
                    baseValues: first.baseValues
                ) else {
                    errors.append("DELIVERY_MIRROR_TERMINAL_DELIVERY: \(path)")
                    continue
                }
                guard try deliveryRepo.markWriting(xmpPath: path, revision: revision) != nil else {
                    errors.append("DELIVERY_MIRROR_LEASE_CONFLICT: \(path)")
                    continue
                }
                var writtenItems = 0
                var firstErrorMessage = ""
                for item in groupItems {
                    // 先回 pending：覆盖 synced/written/failed 的合法重开路径
                    //（item 迁移表不允许 synced → written 一步到位）。
                    _ = try deliveryRepo.upsertItem(
                        xmpPath: path,
                        photoId: item.photoId,
                        module: module,
                        attributes: item.attributes,
                        keywords: item.keywords,
                        status: .pending,
                        errorMessage: ""
                    )
                    let row = try deliveryRepo.upsertItem(
                        xmpPath: path,
                        photoId: item.photoId,
                        module: module,
                        attributes: item.attributes,
                        keywords: item.keywords,
                        status: item.status,
                        errorMessage: item.errorMessage
                    )
                    itemCount += 1
                    if row.typedStatus == .failed {
                        if firstErrorMessage.isEmpty { firstErrorMessage = item.errorMessage }
                    } else {
                        writtenItems += 1
                    }
                }
                if writtenItems > 0 {
                    guard try deliveryRepo.markWritten(
                        xmpPath: path,
                        revision: revision,
                        baseFingerprint: first.baseFingerprint,
                        baseValues: first.baseValues,
                        backupPath: first.backupPath
                    ) != nil else {
                        errors.append("DELIVERY_MIRROR_WRITE_CAS_FAILED: \(path)")
                        continue
                    }
                } else {
                    guard try deliveryRepo.markFailed(
                        xmpPath: path,
                        revision: revision,
                        errorMessage: firstErrorMessage.isEmpty ? "WRITEBACK_FAILED" : firstErrorMessage
                    ) != nil else {
                        errors.append("DELIVERY_MIRROR_FAIL_CAS_FAILED: \(path)")
                        continue
                    }
                }
                _ = try deliveryRepo.linkSession(xmpPath: path, sessionId: sessionId)
                deliveryCount += 1
            } catch {
                errors.append(Self.failure("DELIVERY_MIRROR_FAILED", path, error))
            }
        }

        emitStateChanged(sessionId)
        return DeliveryMirrorSummary(
            deliveryCount: deliveryCount,
            itemCount: itemCount,
            errors: errors
        )
    }

    /// 新输入重新打开交付（pending）并推进 revision；cleaned 是审计终态，返回 nil。
    private func openDeliveryForWrite(
        xmpPath: String,
        photoPath: String,
        baseFingerprint: String,
        baseValues: JSONValue
    ) throws -> Int64? {
        guard let existing = try deliveryRepo.get(xmpPath) else {
            let created = try deliveryRepo.createOrGet(
                xmpPath: xmpPath,
                photoPath: photoPath,
                revision: 0,
                baseFingerprint: baseFingerprint,
                baseValues: baseValues
            )
            return created.revision
        }
        guard existing.typedStatus != .cleaned else { return nil }
        let newRevision = existing.revision + 1
        if let merged = try deliveryRepo.mergeInput(
            xmpPath: xmpPath,
            photoPath: photoPath,
            expectedRevision: existing.revision,
            newRevision: newRevision,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues
        ) {
            return merged.revision
        }
        // CAS 失配（并发写入推进了 revision）：重读一次再推，仍失败则交给调用方记账。
        guard let latest = try deliveryRepo.get(xmpPath),
              latest.typedStatus != .cleaned else { return nil }
        return try deliveryRepo.mergeInput(
            xmpPath: xmpPath,
            photoPath: photoPath,
            expectedRevision: latest.revision,
            newRevision: latest.revision + 1,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues
        )?.revision
    }

    /// finalize 的文件阶段：只删备份，绝不触碰 XMP（dropWithoutRestore）。
    /// 删除后同样复核快照：备份路径可能已被新一轮写入复用，不能静默删掉新备份。
    private func performFinalizeFilePhase(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async throws {
        guard !payload.backupPath.isEmpty else { return }
        guard files.fileExists(payload.backupPath) else { return }
        try await files.removeFile(payload.backupPath)
        try verifyFilePhaseAfterMutation(xmpPath: xmpPath, payload: payload)
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
        let backlog: DeliveryIntentBacklog
        do {
            backlog = try intentRepo.replayAll()
        } catch {
            throw DeliveryCoordinatorError.invalidArgument("读取回放待办失败: \(error)")
        }

        var appliedCount = 0
        var skippedCount = 0
        var failedCount = 0
        var errors: [String] = []

        /// 汇总一次「DB 段 + intent 收尾」的结果（可重试失败 / 闭环 / 跳过）。
        func record(_ result: DeliveryDBFinishOutcome) {
            if let retryable = result.retryableError {
                failedCount += 1
                errors.append(retryable)
            } else if result.applied {
                appliedCount += 1
            } else {
                skippedCount += 1
                if let notice = result.notice { errors.append(notice) }
            }
        }

        for intent in backlog.prepared {
            guard intent.typedKind == .cleanup else {
                failedCount += 1
                errors.append("XMP_CLEANUP_UNSUPPORTED_INTENT: #\(intent.id) kind=\(intent.kind)")
                continue
            }
            guard let payload = DeliveryCleanupPayload(intent: intent) else {
                do {
                    try intentRepo.finish(id: intent.id, error: "XMP_CLEANUP_INVALID_PAYLOAD")
                    skippedCount += 1
                } catch {
                    failedCount += 1
                    errors.append(Self.failure("XMP_CLEANUP_INVALID_PAYLOAD", intent.xmpPath, error))
                }
                continue
            }
            // P0-1 + TOCTOU：prepared 回放的 verify → 文件 → 事后 verify
            // 同样整体在 XMPFileLock 内；新输入已推进 revision 时绝不重做文件
            //（旧备份会覆盖新内容），直接放弃 intent 并上报。
            let phase = await runLockedFilePhase(
                xmpPath: intent.xmpPath, payload: payload)
            switch phase {
            case .completed:
                break
            case .guardFailed(let reason):
                failedCount += 1
                errors.append("XMP_CLEANUP_GUARD_FAILED: \(intent.xmpPath) reason=\(reason)")
                continue
            case .fileFailed(let reason):
                failedCount += 1
                errors.append("XMP_CLEANUP_FILE_FAILED: \(intent.xmpPath) reason=\(reason)")
                continue
            case .invalidated(let reason):
                do {
                    try intentRepo.finish(
                        id: intent.id, error: "XMP_CLEANUP_FILE_RACED: \(reason)")
                    skippedCount += 1
                    errors.append(
                        "XMP_CLEANUP_FILE_RACED: \(intent.xmpPath) reason=\(reason)")
                } catch {
                    failedCount += 1
                    errors.append(
                        Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
                }
                continue
            case .skipped(let verdict):
                switch verdict {
                case .changed(let reason):
                    do {
                        try intentRepo.finish(
                            id: intent.id, error: "XMP_CLEANUP_ABANDONED: \(reason)")
                        skippedCount += 1
                        errors.append(
                            "XMP_CLEANUP_ABANDONED: \(intent.xmpPath) reason=\(reason)")
                    } catch {
                        failedCount += 1
                        errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
                    }
                    continue
                case .conflict(let reason):
                    do {
                        _ = try deliveryRepo.markConflict(
                            xmpPath: intent.xmpPath,
                            revision: payload.revision,
                            errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT")
                        try intentRepo.finish(
                            id: intent.id,
                            error: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT: \(reason)")
                        skippedCount += 1
                        errors.append(
                            "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT: \(intent.xmpPath) reason=\(reason)")
                    } catch {
                        failedCount += 1
                        errors.append(Self.failure("XMP_CLEANUP_CONFLICT_FAILED", intent.xmpPath, error))
                    }
                    continue
                case .alreadyGone:
                    // 行已被并发删除：不碰文件，DB 段按 alreadyGone 幂等收尾。
                    record(applyDBAndFinish(intent: intent, payload: payload))
                    continue
                case .proceed:
                    continue
                }
            }
            do {
                _ = try intentRepo.advance(id: intent.id, to: .fileDone)
            } catch {
                failedCount += 1
                errors.append(Self.failure("XMP_CLEANUP_ADVANCE_FAILED", intent.xmpPath, error))
                continue
            }
            record(applyDBAndFinish(intent: intent, payload: payload))
        }

        for intent in backlog.fileDone {
            guard intent.typedKind == .cleanup else {
                failedCount += 1
                errors.append("XMP_CLEANUP_UNSUPPORTED_INTENT: #\(intent.id) kind=\(intent.kind)")
                continue
            }
            guard let payload = DeliveryCleanupPayload(intent: intent) else {
                do {
                    try intentRepo.finish(id: intent.id, error: "XMP_CLEANUP_INVALID_PAYLOAD")
                    skippedCount += 1
                } catch {
                    failedCount += 1
                    errors.append(Self.failure("XMP_CLEANUP_INVALID_PAYLOAD", intent.xmpPath, error))
                }
                continue
            }
            // 文件已是目标状态：这里绝不调用 performFilePhase。
            record(applyDBAndFinish(intent: intent, payload: payload))
        }

        return DeliveryReplaySummary(
            appliedCount: appliedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            errors: errors
        )
    }

    // MARK: - 文件阶段

    /// 文件阶段前的快照复核（P0-1 的唯一守卫入口）。
    ///
    /// 只有完全一致才返回 .proceed：
    /// 1. 重读交付行，比对 id/revision/status（+ payload 记录的 base_fingerprint）；
    /// 2. cleanup 还要比对盘上指纹（finalize 只删备份，绝不碰 XMP）；
    /// 3. 指纹读取是 await 窗口——窗口内可能又出现新输入，因此**再读一次**行，
    ///    不一致一律不碰文件（这也是回归测试的确定性注入点）。
    ///
    /// 指纹读取失败直接抛出：调用方保留 intent、下次 replay 重试。
    private func verifyFilePhase(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async throws -> DeliveryFilePhaseVerdict {
        guard let before = try deliveryRepo.get(xmpPath) else { return .alreadyGone }
        if let reason = Self.filePhaseSnapshotMismatch(before, payload: payload) {
            return .changed(reason: reason)
        }
        // finalize 不触碰 XMP：只做 revision/status 守卫，不读指纹。
        guard payload.action == .cleanup else { return .proceed }
        let expected = payload.baseFingerprint.isEmpty
            ? before.baseFingerprint
            : payload.baseFingerprint
        // 没有基线（旧行/懒备份）时无法检测外部修改，只剩同步快照守卫。
        guard !expected.isEmpty else { return .proceed }
        let onDisk = try await fingerprint(xmpPath)
        // await 期间新输入/重写：revision/status/基线任一变化都不得碰文件。
        guard let after = try deliveryRepo.get(xmpPath) else { return .alreadyGone }
        if let reason = Self.filePhaseSnapshotMismatch(after, payload: payload) {
            return .changed(reason: reason)
        }
        if after.baseFingerprint != before.baseFingerprint {
            return .changed(reason: "base-fingerprint-changed")
        }
        guard onDisk == expected else {
            return .conflict(reason: "fingerprint-mismatch")
        }
        return .proceed
    }

    /// 交付行与 intent 快照的不一致原因；nil 表示快照一致。
    private static func filePhaseSnapshotMismatch(
        _ row: DeliveryRow,
        payload: DeliveryCleanupPayload
    ) -> String? {
        if row.id != payload.deliveryId { return "delivery-id-changed" }
        if row.revision != payload.revision { return "revision-changed" }
        if row.status != payload.status { return "status-changed(\(row.status))" }
        if !payload.baseFingerprint.isEmpty, row.baseFingerprint != payload.baseFingerprint {
            return "base-fingerprint-changed"
        }
        return nil
    }

    /// 文件阶段执行后再次复核：restore/remove 的 await 期间若出现新输入，
    /// 旧备份可能已覆盖新内容。此时抛 .filePhaseInvalidated 让调用方显式上报
    /// 并放弃 intent（绝不静默走 DB 删除）。
    private func verifyFilePhaseAfterMutation(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) throws {
        guard let current = try deliveryRepo.get(xmpPath) else { return }
        if let reason = Self.filePhaseSnapshotMismatch(current, payload: payload) {
            throw DeliveryCoordinatorError.filePhaseInvalidated(
                xmpPath: xmpPath, reason: reason)
        }
    }

    /// 在 XMPFileLock 内执行 cleanup/finalize 的完整文件阶段（唯一入口）。
    ///
    /// 顺序固定：verify（锁内重读 revision/status/指纹）→ restore/remove →
    /// verifyFilePhaseAfterMutation（锁内重读，检测 restore 期间的新输入）。
    /// 失败不抛出：用 LockedFilePhaseOutcome 保留旧错误码语义，intent 留在 prepared。
    private func runLockedFilePhase(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async -> LockedFilePhaseOutcome {
        do {
            return try await fileLock.run(path: xmpPath) {
                let verdict: DeliveryFilePhaseVerdict
                do {
                    verdict = try await self.verifyFilePhase(
                        xmpPath: xmpPath, payload: payload)
                } catch {
                    return .guardFailed(reason: String(describing: error))
                }
                guard case .proceed = verdict else { return .skipped(verdict) }
                do {
                    switch payload.action {
                    case .cleanup:
                        try await self.performCleanupFilePhase(
                            xmpPath: xmpPath, payload: payload)
                    case .finalize:
                        try await self.performFinalizeFilePhase(
                            xmpPath: xmpPath, payload: payload)
                    }
                    return .completed
                } catch let error as DeliveryCoordinatorError {
                    if case .filePhaseInvalidated(_, let reason) = error {
                        return .invalidated(reason: reason)
                    }
                    return .fileFailed(reason: String(describing: error))
                } catch {
                    return .fileFailed(reason: String(describing: error))
                }
            }
        } catch {
            // 只有取锁/排队被取消才会走到这里：文件未执行，intent 保持 prepared。
            return .guardFailed(reason: String(describing: error))
        }
    }

    /// 把备份内容恢复回侧车；无备份时删除本次写入的侧车（旧 cleanup 语义）。
    /// 两种形态都幂等：恢复是覆盖写，删除前先看存在性。
    private func performCleanupFilePhase(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async throws {
        if payload.backupPath.isEmpty {
            if files.fileExists(xmpPath) {
                try await files.removeFile(xmpPath)
            }
        } else {
            guard files.fileExists(payload.backupPath) else {
                throw DeliveryCoordinatorError.backupMissing(xmpPath: xmpPath)
            }
            try await files.restore(
                photoPath: payload.photoPath,
                backupPath: payload.backupPath
            )
        }
        try verifyFilePhaseAfterMutation(xmpPath: xmpPath, payload: payload)
    }

    // MARK: - DB 段

    /// 同一事务删 items / links / delivery（revision + status 双守卫）。
    /// 实现收敛在 DeliveryRepo.deleteSyncedDelivery：cleanup 与 finalize 共用同一条
    /// CAS 纪律，Services 层不再持删除 SQL。
    ///
    /// P1-8：删除前在**同一事务**里复核该交付的所有 item。文件阶段（restore）是
    /// await 窗口，期间其它模块可能新建 pending/failed item；只靠 prepare 前的
    /// 检查会漏掉这种竞态。
    private func applyCleanupDB(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) throws -> CleanupDBOutcome {
        try connection.transaction {
            switch try cleanupItemGate(
                deliveryId: payload.deliveryId, module: payload.module) {
            case .incomplete(let blockerModule, let status):
                return .foreignItemsPending(module: blockerModule, status: status)
            case .retainForeign(let modules):
                // 全 synced 但还有其它模块 item：只清本模块 item，保留交付。
                if let module = payload.module {
                    _ = try deliveryRepo.deleteItems(
                        xmpPath: xmpPath, module: module, statuses: [.synced])
                }
                return .foreignItemsRetained(modules: modules)
            case .proceed:
                break
            }
            switch try deliveryRepo.deleteSyncedDelivery(
                xmpPath: xmpPath,
                deliveryId: payload.deliveryId,
                revision: payload.revision
            ) {
            case .deleted: return .deleted
            case .alreadyGone: return .alreadyGone
            case .idChanged: return .rowReplaced
            case .revisionChanged: return .revisionChanged
            case .stateChanged: return .stateChanged
            }
        }
    }

    /// 交付级 item 门禁（P1-8 的唯一判定入口，cleanup 预检与 DB 段共用）。
    ///
    /// - 任一 item 非 synced（pending/failed/written）→ incomplete：删除会丢输入，
    ///   整条交付 skip（包括本模块 other-session 的未完成 item）。
    /// - 全部 synced 且模块已知：仍有其它模块 item → retainForeign。
    /// - 旧 intent 没有 module（nil）：只要所有 item 都 synced 就允许删除；无法
    ///   区分归属时不做“删一半”的动作，宁可少做。
    private func cleanupItemGate(
        deliveryId: Int64,
        module: DeliveryModule?
    ) throws -> CleanupItemGate {
        let items = try deliveryRepo.items(deliveryId: deliveryId)
        if let blocker = items.first(where: { $0.typedStatus != .synced }) {
            return .incomplete(module: blocker.module, status: blocker.status)
        }
        guard let module else { return .proceed }
        let foreign = Set(items.lazy.map(\.module).filter { $0 != module.rawValue }).sorted()
        return foreign.isEmpty ? .proceed : .retainForeign(modules: foreign)
    }

    /// DB 段 + intent 收尾的结果。
    /// - retryableError 非空：intent 被保留，下次 replay 重试；
    /// - applied：DB 行已删除（或本来就不存在）且 intent 已闭环；
    /// - notice：intent 已标终态但 DB 守卫拒绝（新输入保留），错误必须可见。
    private struct DeliveryDBFinishOutcome {
        let applied: Bool
        let retryableError: String?
        let notice: String?

        static func retry(_ message: String) -> DeliveryDBFinishOutcome {
            DeliveryDBFinishOutcome(applied: false, retryableError: message, notice: nil)
        }

        static func closed() -> DeliveryDBFinishOutcome {
            DeliveryDBFinishOutcome(applied: true, retryableError: nil, notice: nil)
        }

        static func skipped(_ message: String) -> DeliveryDBFinishOutcome {
            DeliveryDBFinishOutcome(applied: false, retryableError: nil, notice: message)
        }
    }

    /// DB 段 + intent 收尾（按 payload.action 分派到 cleanup/finalize）。
    private func applyDBAndFinish(
        intent: DeliveryIntentRow,
        payload: DeliveryCleanupPayload
    ) -> DeliveryDBFinishOutcome {
        switch payload.action {
        case .cleanup:
            return applyCleanupDBAndFinish(intent: intent, payload: payload)
        case .finalize:
            return applyFinalizeDBAndFinish(intent: intent, payload: payload)
        }
    }

    private func applyCleanupDBAndFinish(
        intent: DeliveryIntentRow,
        payload: DeliveryCleanupPayload
    ) -> DeliveryDBFinishOutcome {
        let outcome: CleanupDBOutcome
        do {
            outcome = try applyCleanupDB(xmpPath: intent.xmpPath, payload: payload)
        } catch {
            return .retry(Self.failure("XMP_CLEANUP_DB_FAILED", intent.xmpPath, error))
        }
        switch outcome {
        case .deleted, .alreadyGone:
            do {
                try intentRepo.finish(id: intent.id)
                return .closed()
            } catch {
                return .retry(Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
            }
        case .foreignItemsPending(let blockerModule, let status):
            let notice = "XMP_CLEANUP_INCOMPLETE_ITEMS: \(intent.xmpPath) "
                + "module=\(blockerModule) status=\(status)"
            do {
                try intentRepo.finish(
                    id: intent.id,
                    error: "XMP_CLEANUP_INCOMPLETE_ITEMS: \(blockerModule):\(status)")
                return .skipped(notice)
            } catch {
                return .retry(Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
            }
        case .foreignItemsRetained(let modules):
            let notice = "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: \(intent.xmpPath) "
                + "modules=\(modules.joined(separator: ","))"
            do {
                try intentRepo.finish(
                    id: intent.id,
                    error: "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: "
                        + modules.joined(separator: ","))
                return .skipped(notice)
            } catch {
                return .retry(Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
            }
        case .revisionChanged, .rowReplaced, .stateChanged:
            do {
                try intentRepo.finish(
                    id: intent.id,
                    error: "XMP_CLEANUP_SKIPPED: \(outcome.reason)"
                )
                return .skipped(
                    "XMP_CLEANUP_SKIPPED: \(intent.xmpPath) reason=\(outcome.reason)")
            } catch {
                return .retry(Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
            }
        }
    }

    /// finalize 的 DB 段：与 cleanup 同一删除 helper，差异只在错误码。
    private func applyFinalizeDBAndFinish(
        intent: DeliveryIntentRow,
        payload: DeliveryCleanupPayload
    ) -> DeliveryDBFinishOutcome {
        let outcome: DeliveryRepo.DeliveryDeleteOutcome
        do {
            outcome = try deliveryRepo.deleteSyncedDelivery(
                xmpPath: intent.xmpPath,
                deliveryId: payload.deliveryId,
                revision: payload.revision
            )
        } catch {
            return .retry(Self.failure("XMP_FINALIZE_DB_FAILED", intent.xmpPath, error))
        }
        switch outcome {
        case .deleted, .alreadyGone:
            do {
                try intentRepo.finish(id: intent.id)
                return .closed()
            } catch {
                return .retry(Self.failure("XMP_FINALIZE_FINISH_FAILED", intent.xmpPath, error))
            }
        case .idChanged, .revisionChanged, .stateChanged:
            do {
                try intentRepo.finish(
                    id: intent.id,
                    error: "XMP_FINALIZE_SKIPPED: \(outcome.rawValue)"
                )
                return .skipped(
                    "XMP_FINALIZE_SKIPPED: \(intent.xmpPath) reason=\(outcome.rawValue)")
            } catch {
                return .retry(Self.failure("XMP_FINALIZE_FINISH_FAILED", intent.xmpPath, error))
            }
        }
    }

    // MARK: - 错误格式化

    private static func failure(_ code: String, _ xmpPath: String, _ error: Error) -> String {
        "\(code): \(xmpPath) reason=\(String(describing: error))"
    }
}

// MARK: - culling 适配（Cut 2 / S5c-2a）

/// CullingService 的交付面：module 固定为 .culling（S5c-2a 只接 culling；
/// FaceKw / Similarity 与 finalize/writeback 留 S5c-2b）。
///
/// 为什么不直接注入 DeliveryCoordinator：
/// 1. 调用点不应重复传模块常量，也不该拿到 face/similarity 的入口（越权面）；
/// 2. 测试可注入替身，验证「调用了确认/清理」而不必复刻 coordinator 的全部依赖。
public protocol CullingDeliveryPort: Sendable {
    /// 确认本会话在本模块下的已写交付（单事务；跨会话阻塞见返回值）。
    func confirmCulling(sessionId: String) throws -> DeliveryConfirmSummary
    /// 清理本会话在本模块下已确认（synced）的交付（恢复备份后物理删行）。
    func cleanupCulling(sessionId: String) async throws -> DeliveryCleanupSummary
    /// 保留 XMP 并结束（丢备份、删交付行；绝不 restore）。
    func finalizeCulling(sessionId: String) async throws -> DeliveryFinalizeSummary
    /// 旧 WritebackService 执行结果 → 交付镜像（S5c-2b-1 过渡双写）。
    func mirrorCullingWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    /// syncStatus/flush/retry/finalize 的统一读模型（旧 MetadataSyncSummary 投影）。
    func cullingMetadataSummary(sessionId: String) throws -> MetadataSyncSummary
    /// flush/retry_sync 的唯一动作：按相位回放未完成的 intent。
    func replayPendingDeliveries() async throws -> DeliveryReplaySummary
}

extension DeliveryCoordinator: CullingDeliveryPort {
    public func confirmCulling(sessionId: String) throws -> DeliveryConfirmSummary {
        try confirm(sessionId: sessionId, module: .culling)
    }

    public func cleanupCulling(sessionId: String) async throws -> DeliveryCleanupSummary {
        try await cleanup(sessionId: sessionId, module: .culling)
    }

    public func finalizeCulling(sessionId: String) async throws -> DeliveryFinalizeSummary {
        try await finalize(sessionId: sessionId, module: .culling)
    }

    public func mirrorCullingWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try mirrorWriteback(sessionId: sessionId, module: .culling, items: items)
    }

    public func cullingMetadataSummary(sessionId: String) throws -> MetadataSyncSummary {
        try metadataSummary(sessionId: sessionId, module: .culling)
    }

    public func replayPendingDeliveries() async throws -> DeliveryReplaySummary {
        try await replay()
    }
}

// MARK: - faceKeyword 适配（Cut 2 / S5c-2b-2）

/// FaceKwService 的交付面：module 固定为 .faceKeyword（落库 "face-keyword"）。
///
/// 与 CullingDeliveryPort 同一套理由：调用点不重复传模块常量、不拿到别域入口，
/// 测试可注入替身只验证「调用了确认/清理/镜像」。
public protocol FaceKwDeliveryPort: Sendable {
    /// 确认本会话在人脸关键词模块下的已写交付（单事务；跨会话阻塞见返回值）。
    func confirmFaceKeyword(sessionId: String) throws -> DeliveryConfirmSummary
    /// 清理本会话在人脸关键词模块下已确认（synced）的交付（恢复备份后物理删行）。
    func cleanupFaceKeyword(sessionId: String) async throws -> DeliveryCleanupSummary
    /// 旧 WritebackService 执行结果 → 交付镜像（S5c-2b-2 过渡双写）。
    func mirrorFaceKeywordWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    /// cleanup 前的崩溃恢复：按相位回放未完成的 intent。
    func replayPendingDeliveries() async throws -> DeliveryReplaySummary
}

extension DeliveryCoordinator: FaceKwDeliveryPort {
    public func confirmFaceKeyword(sessionId: String) throws -> DeliveryConfirmSummary {
        try confirm(sessionId: sessionId, module: .faceKeyword)
    }

    public func cleanupFaceKeyword(sessionId: String) async throws -> DeliveryCleanupSummary {
        try await cleanup(sessionId: sessionId, module: .faceKeyword)
    }

    public func mirrorFaceKeywordWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try mirrorWriteback(sessionId: sessionId, module: .faceKeyword, items: items)
    }
}

// MARK: - similarity 适配（Cut 2 / S5c-2b-2）

/// SimilarityService 的交付面：module 固定为 .similarity。
public protocol SimilarityDeliveryPort: Sendable {
    /// 确认本会话在相似度模块下的已写交付（单事务；跨会话阻塞见返回值）。
    func confirmSimilarity(sessionId: String) throws -> DeliveryConfirmSummary
    /// 清理本会话在相似度模块下已确认（synced）的交付（恢复备份后物理删行）。
    func cleanupSimilarity(sessionId: String) async throws -> DeliveryCleanupSummary
    /// 旧 WritebackService 执行结果 → 交付镜像（S5c-2b-2 过渡双写）。
    func mirrorSimilarityWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    /// cleanup 前的崩溃恢复：按相位回放未完成的 intent。
    func replayPendingDeliveries() async throws -> DeliveryReplaySummary
}

extension DeliveryCoordinator: SimilarityDeliveryPort {
    public func confirmSimilarity(sessionId: String) throws -> DeliveryConfirmSummary {
        try confirm(sessionId: sessionId, module: .similarity)
    }

    public func cleanupSimilarity(sessionId: String) async throws -> DeliveryCleanupSummary {
        try await cleanup(sessionId: sessionId, module: .similarity)
    }

    public func mirrorSimilarityWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try mirrorWriteback(sessionId: sessionId, module: .similarity, items: items)
    }
}

/// 仅文件系统的 DeliveryFilePort（S5c-2a 过渡默认）。
///
/// CullingService 在宿主未注入 CullingDeliveryPort 时用它自建 coordinator：
/// 恢复 = 备份覆盖写回 photo.xmp（幂等），删除 = unlink。宿主已有 XMPProvider
/// 时应注入 XMPDeliveryFilePort（原子替换 + 大小写侧车解析），S5c-2b 接线。
public struct FileSystemDeliveryFilePort: DeliveryFilePort {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        guard FileManager.default.fileExists(atPath: backupPath) else {
            throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
        }
        let target = TSPath.xmpSidecarPath(photoPath)
        // 先拷到同目录临时文件，再替换目标：中途失败不会把原侧车删空
        //（与 SidecarXMPProvider.install 的覆盖写语义一致）。
        let tempPath = target + ".restore-" + UUID().uuidString.lowercased()
        try FileManager.default.copyItem(atPath: backupPath, toPath: tempPath)
        do {
            if FileManager.default.fileExists(atPath: target) {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: target),
                    withItemAt: URL(fileURLWithPath: tempPath)
                )
            } else {
                try FileManager.default.moveItem(atPath: tempPath, toPath: target)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    public func removeFile(_ path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
