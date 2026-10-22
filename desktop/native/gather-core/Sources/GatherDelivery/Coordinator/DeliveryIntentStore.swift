// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryIntentStore.swift
// WP2b：cleanup/finalize 的 intent 前滚与 payload（自 DeliveryCoordinator.swift 抽出）。
//
// 职责边界：
// - prepare / advance / finish 包装 DeliveryIntentRepo，编排层不再直接持 intent 仓储；
// - finishInTransaction 由 DeliveryDBPhase 在「DB 删除 + intent 收尾」的同一事务内调用；
// - payload 的 JSON 键、旧 intent 的缺省语义（S5c-2a 兼容）逐字保留：
//   旧 intent 没有 op → cleanup；没有 status → 按 synced；没有 module → nil（保守门禁）。

import Foundation
import GatherPersistence
import GatherProtocol

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

/// intent 的唯一编排入口（prepare / advance / finish）。
///
/// 事务纪律：
/// - prepare/advance/finish 各自是仓储级事务（与迁移前一致）；
/// - finishInTransaction 不另开事务，专供 DeliveryDBPhase 的
///   「DB 删除 + intent 收尾」单事务使用；
/// - finishIfPresent 把「intent 已不存在」视为已闭环（DB 段重放的幂等入口）。
struct DeliveryIntentStore: Sendable {
    private let repo: DeliveryIntentRepo

    init(repo: DeliveryIntentRepo) {
        self.repo = repo
    }

    @discardableResult
    func prepare(
        kind: DeliveryIntentKind,
        xmpPath: String,
        payload: JSONValue
    ) throws -> Int64 {
        try repo.prepare(kind: kind, xmpPath: xmpPath, payload: payload)
    }

    @discardableResult
    func advance(id: Int64, to phase: DeliveryIntentPhase) throws -> DeliveryIntentRow {
        try repo.advance(id: id, to: phase)
    }

    func finish(id: Int64, error: String? = nil) throws {
        try repo.finish(id: id, error: error)
    }

    /// 调用方必须已持有 connection.transaction（DB 删除 + intent 收尾同事务）。
    func finishInTransaction(id: Int64, error: String? = nil) throws {
        try repo.finishInTransaction(id: id, error: error)
    }

    /// 幂等收尾：intent 已不存在 → 视为已闭环（不抛 rowNotFound）。
    @discardableResult
    func finishIfPresent(id: Int64, error: String? = nil) throws -> Bool {
        guard try repo.get(id) != nil else { return false }
        try repo.finishInTransaction(id: id, error: error)
        return true
    }

    func pending() throws -> DeliveryIntentBacklog {
        try repo.pending()
    }

    @discardableResult
    func replayAll() throws -> DeliveryIntentBacklog {
        try repo.replayAll()
    }
}
