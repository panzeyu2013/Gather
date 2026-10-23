// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Confirm.swift
// DeliveryRepo 拆分（纯移动）：确认（单事务）。
//
// 方法体与拆分前逐字一致；跨文件 private 成员仅提升为 internal。

import Foundation
import GatherProtocol

extension DeliveryRepo {
    // MARK: - 确认（单事务）

    /// 本会话对交付的确认。**一个 connection.transaction，闭包内无 await**（draft §5.4）。
    ///
    /// P1-3：门禁读与状态更新在同一事务内，顺序为：
    /// 1. 事务内重读会话聚合（完整性与阻断项）；不可确认则抛
    ///    `DeliveryConfirmGateError.incomplete`，整个事务回滚、不写任何 confirmed_at；
    /// 2. 可选 reload-ack 门禁（`requireReloadAck`）也在同一事务内读 sessions；
    /// 3. 本次 scope 命中的 delivery_sessions 行写 confirmed_at——**只对
    ///    `deliveries.status IN ('written','synced')` 的行**，避免门禁读之后被
    ///    mergeInput 重开为 pending/writing/failed/conflict 的交付仍落确认；
    /// 4. 仅当「该 delivery 的所有关联会话都已确认」时，written → synced；
    /// 5. 这些 delivery 下所有 written items → synced（一个侧车文件是一次原子写入，
    ///    文件内容没有模块边界；scope=.module 只收窄「确认哪些 delivery 的链接」，
    ///    不把同一文件里其它模块的已写 items 留在 written）；
    /// 6. 读回 summary（本次计数 + 仍未确认的会话）。
    ///
    /// 事务用 BEGIN IMMEDIATE 开启（与迁移器同一理由）：门禁读之前先拿写锁，
    /// 进程内靠连接锁、跨进程靠 SQLite 写锁串行化「门禁判定 → confirmed_at
    /// 更新」；不会出现 deferred 读→写升级的 BUSY_SNAPSHOT，也不会写半套确认。
    ///
    /// scope=.session 时 module 参数被忽略（确认范围是整个会话，宽于模块过滤）。
    ///
    /// 与 draft §5.4 的两处收敛（均为避免跨会话副作用）：
    /// - synced 翻转限定在本次 scope 命中的 delivery 集合内（draft 的 SQL 未限定）；
    /// - confirmed_at 只写空值行（重复 confirm 幂等，summary 计数 = 本次新确认数）。
    ///
    /// 会话级写回态由 DeliverySummaryQuery 按 deliveries 聚合派生（D-021）；
    /// 本事务的门禁读与回读复用同一投影，不再有 legacy sessions 列。
    public func confirm(
        scope: DeliveryConfirmScope,
        sessionId: String,
        module: DeliveryModule? = nil,
        requireReloadAck: Bool = false
    ) throws -> DeliveryConfirmSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        if scope == .module, module == nil {
            throw DeliveryRepoError.invalidArgument("scope=.module 必须提供 module")
        }

        let gateModule: DeliveryModule? = scope == .module ? module : nil
        let targetSQL: String
        let targetValues: [DBValue?]
        switch scope {
        case .session:
            targetSQL = "SELECT tds.delivery_id FROM delivery_sessions tds WHERE tds.session_id = ?"
            targetValues = [.text(sessionId)]
        case .module:
            targetSQL = """
                SELECT tds.delivery_id FROM delivery_sessions tds
                WHERE tds.session_id = ?
                  AND EXISTS (
                    SELECT 1 FROM delivery_items di
                    JOIN photos p ON p.id = di.photo_id
                    WHERE di.delivery_id = tds.delivery_id
                      AND di.module = ?
                      AND p.session_id = ?
                  )
                """
            targetValues = [.text(sessionId), .text(module?.rawValue ?? ""), .text(sessionId)]
        }
        let now = nowISOString()

        return try connection.transaction(.immediate) {
            // P1-3：门禁读与写入同一事务。聚合查询复用 DeliverySummaryQuery，
            // 阻断项文案/顺序与 Coordinator 的只读摘要完全一致。
            let gate = try DeliverySummaryQuery(connection: connection)
                .summary(sessionId: sessionId, module: gateModule)
            guard gate.isConfirmable else {
                throw DeliveryConfirmGateError.incomplete(blockers: gate.blockers)
            }
            if requireReloadAck {
                let acked = try connection.prepare(
                    "SELECT reload_acked_at FROM sessions WHERE id = ?"
                ).get([.text(sessionId)])?[0].textValue ?? ""
                guard !acked.isEmpty else {
                    throw DeliveryConfirmGateError.reloadNotAcknowledged(sessionId: sessionId)
                }
            }

            // confirmed_at 只写「内容仍是已写/已确认」的交付：pending/writing/
            // failed/conflict 的交付即使命中 scope 也不落确认（P1-3 的窄窗口）。
            // 保留 synced：linkSession 给已确认交付新增会话时，新链接仍可补确认，
            // 不改变任何内容基线。
            let confirmedLinks = try connection.prepare("""
                UPDATE delivery_sessions SET confirmed_at = ?
                WHERE session_id = ? AND confirmed_at = ''
                  AND delivery_id IN (
                    SELECT d.id FROM deliveries d
                    WHERE d.status IN ('written', 'synced')
                      AND d.id IN (\(targetSQL))
                  )
                """).run([.text(now), .text(sessionId)] + targetValues)

            let deliveriesSynced = try connection.prepare("""
                UPDATE deliveries SET status = 'synced', updated_at = ?
                WHERE status = 'written'
                  AND id IN (\(targetSQL))
                  AND EXISTS (
                    SELECT 1 FROM delivery_sessions ds WHERE ds.delivery_id = deliveries.id
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM delivery_sessions ds
                    WHERE ds.delivery_id = deliveries.id AND ds.confirmed_at = ''
                  )
                """).run([.text(now)] + targetValues)

            let itemsSynced = try connection.prepare("""
                UPDATE delivery_items SET status = 'synced', updated_at = ?
                WHERE status = 'written'
                  AND delivery_id IN (
                    SELECT d.id FROM deliveries d
                    WHERE d.status = 'synced' AND d.id IN (\(targetSQL))
                  )
                """).run([.text(now)] + targetValues)

            let unconfirmed = try connection.prepare("""
                SELECT DISTINCT ds.session_id
                FROM delivery_sessions ds
                WHERE ds.confirmed_at = ''
                  AND ds.delivery_id IN (\(targetSQL))
                ORDER BY ds.session_id
                """).query(targetValues)

            return DeliveryConfirmSummary(
                scope: scope,
                confirmedLinks: confirmedLinks,
                deliveriesSynced: deliveriesSynced,
                itemsSynced: itemsSynced,
                unconfirmedSessionIds: unconfirmed.compactMap { $0[0].textValue }
            )
        }
    }
}

/// 确认范围：整个会话，或「该会话下含指定模块 item 的交付」。
public enum DeliveryConfirmScope: String, Sendable, CaseIterable, Equatable {
    case session
    case module
}

/// confirm 的读回摘要（供 UI / 审计；全部在 confirm 的同一事务内读取）。
public struct DeliveryConfirmSummary: Sendable, Equatable {
    public let scope: DeliveryConfirmScope
    /// 本次新确认的 delivery_sessions 行数（已确认行不重复计数）。
    public let confirmedLinks: Int
    /// 本次由 written 翻到 synced 的 delivery 行数。
    public let deliveriesSynced: Int
    /// 本次由 written 翻到 synced 的 item 行数。
    public let itemsSynced: Int
    /// 本次 scope 命中的 delivery 上仍未确认的会话（跨会话门禁的 UI 输入）。
    public let unconfirmedSessionIds: [String]

    public init(
        scope: DeliveryConfirmScope,
        confirmedLinks: Int,
        deliveriesSynced: Int,
        itemsSynced: Int,
        unconfirmedSessionIds: [String]
    ) {
        self.scope = scope
        self.confirmedLinks = confirmedLinks
        self.deliveriesSynced = deliveriesSynced
        self.itemsSynced = itemsSynced
        self.unconfirmedSessionIds = unconfirmedSessionIds
    }
}
