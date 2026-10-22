// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryDBPhase.swift
// WP2b：cleanup / finalize 的 DB 段（自 DeliveryCoordinator.swift 抽出）。
//
// 核心修正（WP2 验收）：DB 删除与 intent.finish **同一事务**。
// 迁移前 applyCleanupDB 自己开事务（:1615），返回后 intentRepo.finish(id:) 又开
// 一个事务（:1712）；崩溃窗口里「文件已恢复、DB 已删、intent 还在」三种事实并存。
// 现在本文件只提供一个外层 connection.transaction：
//   - item 门禁复核（P1-8，覆盖文件阶段 await 期间的新增 item）
//   - deleteSyncedDelivery / deleteItems（事务内变体，不再嵌套 savepoint）
//   - intent.finishIfPresent（同一事务；intent 已不存在视为已闭环，重放幂等）
// 任一步失败整体回滚：不会出现「行删了、intent 没删」的半完成状态。
//
// 错误分型：DeliveryDBPhaseError.database / .finish 让调用方保留迁移前的
// XMP_CLEANUP_DB_FAILED / XMP_CLEANUP_FINISH_FAILED（finalize 同理）错误码。
//
// 锁序契约（P2-5）：本类型的 connection.transaction 闭包**只做 DB**，绝不取
// XMPFileLock / 调文件端口；持有 XMP 锁时读 DB 是允许的单向边（XMP → DB）。
// 反向边（DB → XMP）在类型层面被禁止：transaction body 是同步闭包，无法 await
// fileLock.run；禁止用 Task/detached 绕过。详见 docs/delivery-lock-order.md。

import Foundation
import GatherPersistence

/// cleanup 删除交付前的 item 门禁（P1-8）。
///
/// 交付是“一个侧车文件”粒度，item 是“(交付, 照片, 模块)”粒度；一个文件可以同时
/// 有 culling 与 metadata 的 item。模块级 cleanup 不能把其它模块的输入一起删掉：
/// - 任一 item 还不是 synced（pending/failed/written）→ 整条交付 skip；
/// - 全部 synced、但仍有其它模块的 item → 只清本模块 item，保留交付（留给
///   其它模块自己的 cleanup/finalize 收尾），且不碰文件（备份恢复会回滚别人的已确认内容）。
enum CleanupItemGate: Equatable {
    case proceed
    case incomplete(module: String, status: String)
    case retainForeign(modules: [String])
}

/// DB 删除段的 CAS 结果（用于区分「已删」「新输入保留」「状态已变」）。
enum CleanupDBOutcome: Equatable {
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

/// finalize 的 DB 段结果。
///
/// 与 DeliveryRepo.DeliveryDeleteOutcome 的区别只有 one case：删除前的
/// item 门禁不通过（P2-2）。返回独立类型而不是复用 .stateChanged，避免调用方
/// 把「跨模块 item 未收敛」误报成普通 CAS 拒绝。
enum FinalizeDBOutcome: Equatable {
    case deleted
    case alreadyGone
    case idChanged
    case revisionChanged
    case stateChanged
    /// 仍有非 synced item（任何模块）：fail-closed，不删行、不删备份。
    case incompleteItems(module: String, status: String)

    var reason: String {
        switch self {
        case .deleted: return "deleted"
        case .alreadyGone: return "already-gone"
        case .idChanged: return "idChanged"
        case .revisionChanged: return "revisionChanged"
        case .stateChanged: return "stateChanged"
        case .incompleteItems(let module, let status):
            return "incomplete-items(\(module):\(status))"
        }
    }
}

/// DB 段失败分型：保留迁移前的两套错误码。
enum DeliveryDBPhaseError: Error {
    /// 删除/门禁的 SQL 失败。
    case database(Error)
    /// intent 收尾失败（事务随之回滚，交付行不会丢）。
    case finish(Error)
}

struct DeliveryDBPhase: Sendable {
    private let connection: DBConnection
    private let deliveryRepo: DeliveryRepo
    private let writer: DeliveryStateWriter
    private let intents: DeliveryIntentStore

    init(
        connection: DBConnection,
        deliveryRepo: DeliveryRepo,
        writer: DeliveryStateWriter,
        intents: DeliveryIntentStore
    ) {
        self.connection = connection
        self.deliveryRepo = deliveryRepo
        self.writer = writer
        self.intents = intents
    }

    // MARK: - cleanup

    /// 单事务：item 门禁 → 删除（或只清本模块 item）→ intent 收尾。
    func applyCleanup(
        intentId: Int64,
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) throws -> CleanupDBOutcome {
        try connection.transaction {
            let gate: CleanupItemGate
            do {
                gate = try cleanupItemGate(deliveryId: payload.deliveryId, module: payload.module)
            } catch {
                throw DeliveryDBPhaseError.database(error)
            }
            switch gate {
            case .incomplete(let blockerModule, let status):
                try finish(
                    intentId,
                    error: "XMP_CLEANUP_INCOMPLETE_ITEMS: \(blockerModule):\(status)"
                )
                return .foreignItemsPending(module: blockerModule, status: status)
            case .retainForeign(let modules):
                // 全 synced 但还有其它模块 item：只清本模块 item，保留交付。
                if let module = payload.module {
                    do {
                        _ = try writer.deleteItemsInTransaction(
                            xmpPath: xmpPath, module: module, statuses: [.synced])
                    } catch {
                        throw DeliveryDBPhaseError.database(error)
                    }
                }
                try finish(
                    intentId,
                    error: "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: "
                        + modules.joined(separator: ",")
                )
                return .foreignItemsRetained(modules: modules)
            case .proceed:
                break
            }

            let deleted: DeliveryRepo.DeliveryDeleteOutcome
            do {
                deleted = try writer.deleteSyncedDeliveryInTransaction(
                    xmpPath: xmpPath,
                    deliveryId: payload.deliveryId,
                    revision: payload.revision
                )
            } catch {
                throw DeliveryDBPhaseError.database(error)
            }

            let outcome: CleanupDBOutcome
            switch deleted {
            case .deleted: outcome = .deleted
            case .alreadyGone: outcome = .alreadyGone
            case .idChanged: outcome = .rowReplaced
            case .revisionChanged: outcome = .revisionChanged
            case .stateChanged: outcome = .stateChanged
            }
            switch outcome {
            case .deleted, .alreadyGone:
                try finish(intentId, error: nil)
            case .rowReplaced, .revisionChanged, .stateChanged:
                try finish(intentId, error: "XMP_CLEANUP_SKIPPED: \(outcome.reason)")
            case .foreignItemsPending, .foreignItemsRetained:
                break // 上面已返回，不可达。
            }
            return outcome
        }
    }

    /// 交付级 item 门禁（P1-8 的唯一判定入口，cleanup 预检与 DB 段共用）。
    ///
    /// - 任一 item 非 synced（pending/failed/written）→ incomplete：删除会丢输入，
    ///   整条交付 skip（包括本模块 other-session 的未完成 item）。
    /// - 全部 synced 且模块已知：仍有其它模块 item → retainForeign。
    /// - 旧 intent 没有 module（nil）：只要所有 item 都 synced 就允许删除；无法
    ///   区分归属时不做“删一半”的动作，宁可少做。
    func cleanupItemGate(
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

    // MARK: - finalize

    /// finalize 的 DB 段：与 cleanup 同一删除 helper + intent 同事务，差异只在错误码。
    ///
    /// P1-1 顺序契约：备份删除**不在本事务内**，也不在文件阶段。调用方必须：
    ///   1. 先跑 finalize 文件阶段（只 verify，不删备份）；
    ///   2. 本方法返回 .deleted / .alreadyGone（事务已提交）之后，
    ///      才调用 DeliveryFilePhase.removeFinalizeBackup(...)。
    /// 本方法返回 .idChanged / .revisionChanged / .stateChanged 时，交付行与新输入
    /// 都保留，备份也必须保留（否则 backup_path 悬空）。因此备份删除不可能先于
    /// CAS；CAS/事务失败时 intent 与交付行一起回滚，replay 仍可重试。
    func applyFinalize(
        intentId: Int64,
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) throws -> FinalizeDBOutcome {
        try connection.transaction {
            // P2-2：finalize 也必须过跨模块 item 门禁。cleanup 的差异化语义
            // （retainForeign）在这里刻意不适用：finalize 不 restore，只是按
            // 「一个侧车文件」丢弃整条交付，其它模块已 synced 的 item 会随同一
            // 文件生命周期一起删除；真正危险的是**非 synced** item（pending/
            // failed/written），那意味着仍有未落盘的输入，必须 fail-closed。
            //
            // 当前 public 流程里「delivery synced + 其它模块 item 未 synced」
            // 不可达（新输入会经 openDeliveryForInput/mergeInput 把 delivery
            // 重开为 pending），但这是无断言的不变量：这里用门禁把它变成显式
            // 失败，而不是静默删掉别人的输入。
            let gate: CleanupItemGate
            do {
                gate = try finalizeItemGate(deliveryId: payload.deliveryId)
            } catch {
                throw DeliveryDBPhaseError.database(error)
            }
            if case .incomplete(let module, let status) = gate {
                // 断言级不变量（P2-2）：fail-closed + intent 终态错误，行/备份保留。
                // 刻意不用 assertionFailure：让错误路径在 debug 测试里可覆盖。
                try finish(
                    intentId,
                    error: "XMP_FINALIZE_INCOMPLETE_ITEMS: \(module):\(status)"
                )
                return .incompleteItems(module: module, status: status)
            }

            let outcome: DeliveryRepo.DeliveryDeleteOutcome
            do {
                outcome = try writer.deleteSyncedDeliveryInTransaction(
                    xmpPath: xmpPath,
                    deliveryId: payload.deliveryId,
                    revision: payload.revision
                )
            } catch {
                throw DeliveryDBPhaseError.database(error)
            }
            switch outcome {
            case .deleted:
                try finish(intentId, error: nil)
                return .deleted
            case .alreadyGone:
                try finish(intentId, error: nil)
                return .alreadyGone
            case .idChanged:
                try finish(intentId, error: "XMP_FINALIZE_SKIPPED: \(outcome.rawValue)")
                return .idChanged
            case .revisionChanged:
                try finish(intentId, error: "XMP_FINALIZE_SKIPPED: \(outcome.rawValue)")
                return .revisionChanged
            case .stateChanged:
                try finish(intentId, error: "XMP_FINALIZE_SKIPPED: \(outcome.rawValue)")
                return .stateChanged
            }
        }
    }

    /// finalize 的跨模块 item 门禁（P2-2）：所有模块的 item 都必须是 synced。
    ///
    /// 复用 cleanupItemGate 的唯一判定：module 传 nil 时它不区分归属，
    /// 只要求「不存在非 synced item」——正是 finalize 需要的不变量。
    func finalizeItemGate(deliveryId: Int64) throws -> CleanupItemGate {
        try cleanupItemGate(deliveryId: deliveryId, module: nil)
    }

    // MARK: - intent 收尾（同事务）

    private func finish(_ intentId: Int64, error: String?) throws {
        do {
            try intents.finishIfPresent(id: intentId, error: error)
        } catch {
            throw DeliveryDBPhaseError.finish(error)
        }
    }
}
