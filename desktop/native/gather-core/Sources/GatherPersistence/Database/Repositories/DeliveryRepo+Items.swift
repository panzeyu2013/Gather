// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Items.swift
// DeliveryRepo 拆分（纯移动）：交付项 / 会话链接。
//
// 方法体与拆分前逐字一致；跨文件 private 成员仅提升为 internal。

import Foundation
import GatherProtocol

extension DeliveryRepo {
    // MARK: - 交付项

    /// 逐 (delivery, photo, module) upsert。UNIQUE 冲突时更新 attributes/keywords/status。
    /// 已存在行仍经迁移表校验（synced → pending 是「新输入重新打开」的合法路径）。
    @discardableResult
    public func upsertItem(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule,
        attributes: [String: JSONValue] = [:],
        keywords: [String] = [],
        status: DeliveryItemStatus = .pending,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow {
        let path = try normalizedPath(xmpPath)
        let attributesJSON = try JSONValue.stringify(.object(attributes))
        let keywordsJSON = try JSONValue.stringify(.array(keywords.map { .string($0) }))
        let now = nowISOString()
        return try connection.transaction {
            guard let delivery = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            if let existing = try itemRow(deliveryId: delivery.id, photoId: photoId, module: module) {
                guard let current = existing.typedStatus else {
                    throw DeliveryRepoError.illegalTransition(
                        xmpPath: path, from: "item:\(existing.status)", to: "item:\(status.rawValue)")
                }
                guard current.canTransition(to: status) else {
                    throw DeliveryRepoError.illegalTransition(
                        xmpPath: path, from: "item:\(current.rawValue)", to: "item:\(status.rawValue)")
                }
            }
            _ = try connection.prepare("""
                INSERT INTO delivery_items (
                  delivery_id, photo_id, module, attributes_json, keywords,
                  status, error_message, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(delivery_id, photo_id, module) DO UPDATE SET
                  attributes_json = excluded.attributes_json,
                  keywords = excluded.keywords,
                  status = excluded.status,
                  error_message = excluded.error_message,
                  updated_at = excluded.updated_at
                """).run([
                    .int(delivery.id), .text(photoId), .text(module.rawValue),
                    .text(attributesJSON), .text(keywordsJSON), .text(status.rawValue),
                    .text(errorMessage), .text(now), .text(now),
                ])
            guard let row = try itemRow(deliveryId: delivery.id, photoId: photoId, module: module) else {
                throw DeliveryRepoError.writeNotPersisted("\(path)#\(photoId)#\(module.rawValue)")
            }
            return row
        }
    }

    /// 交付项状态迁移（**唯一入口**：先过 DeliveryItemStatus.canTransition，再 CAS）。
    ///
    /// 与 deliveries 的状态迁移同一纪律：
    /// - 非法迁移抛 DeliveryRepoError.illegalTransition（from/to 带 "item:" 前缀）；
    /// - CAS 带「迁移表允许的来源态」守卫，返回 nil 表示并发迁移抢先（不是错误）；
    /// - attempt_count + 1 / updated_at 刷新，对应旧 writeback_items.updateStatus。
    @discardableResult
    public func markItem(
        itemId: Int64,
        status: DeliveryItemStatus,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow? {
        guard let current = try itemRow(id: itemId) else {
            throw DeliveryRepoError.writeNotPersisted("delivery_item#\(itemId)")
        }
        guard let typed = current.typedStatus else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: current.xmpPath, from: "item:\(current.status)", to: "item:\(status.rawValue)")
        }
        guard typed.canTransition(to: status) else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: current.xmpPath, from: "item:\(typed.rawValue)", to: "item:\(status.rawValue)")
        }
        let changed = try connection.prepare("""
            UPDATE delivery_items
            SET status = ?, error_message = ?, attempt_count = attempt_count + 1, updated_at = ?
            WHERE id = ? AND status IN (\(Self.allowedItemFromSQL(for: status)))
            """).run([
                .text(status.rawValue), .text(errorMessage), .text(nowISOString()), .int(itemId),
            ])
        guard changed == 1 else { return nil }
        return try itemRow(id: itemId)
    }

    /// 迁移表反向查询（item 版）：所有能到达 target 的来源态。
    private static func allowedItemFromSQL(for target: DeliveryItemStatus) -> String {
        DeliveryItemStatus.allCases
            .filter { $0.canTransition(to: target) }
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
    }

    /// 批量更新 delivery_items.attributes_json（persistAttributes 的唯一写入口）。
    ///
    /// 单事务；任一行不存在即整批回滚并抛 writeNotPersisted——写入口不得静默 no-op
    /// （旧 updateAttributesMany 的 0 行更新会让"属性已持久化"变成谎言）。
    public func updateItemAttributes(
        _ updates: [(itemId: Int64, attributes: [String: JSONValue])]
    ) throws {
        guard !updates.isEmpty else { return }
        let now = nowISOString()
        try connection.transaction {
            let statement = try connection.prepare(
                "UPDATE delivery_items SET attributes_json = ?, updated_at = ? WHERE id = ?")
            for update in updates {
                let json = try JSONValue.stringify(.object(update.attributes))
                let changed = try statement.run([.text(json), .text(now), .int(update.itemId)])
                guard changed == 1 else {
                    throw DeliveryRepoError.writeNotPersisted("delivery_item#\(update.itemId)")
                }
            }
        }
    }

    /// 批量更新 delivery_items.keywords（persistKeywords 的唯一写入口）。
    /// 事务语义与 updateItemAttributes 一致。
    public func updateItemKeywords(_ updates: [(itemId: Int64, keywords: [String])]) throws {
        guard !updates.isEmpty else { return }
        let now = nowISOString()
        try connection.transaction {
            let statement = try connection.prepare(
                "UPDATE delivery_items SET keywords = ?, updated_at = ? WHERE id = ?")
            for update in updates {
                let json = try JSONValue.stringify(.array(update.keywords.map { .string($0) }))
                let changed = try statement.run([.text(json), .text(now), .int(update.itemId)])
                guard changed == 1 else {
                    throw DeliveryRepoError.writeNotPersisted("delivery_item#\(update.itemId)")
                }
            }
        }
    }

    // MARK: - 手动元数据队列（合并 / 入队）

    /// 交付项字段级合并（旧 outbox mergePatch 的字段语义，S5c-2b-3b-2b-2）。
    ///
    /// - attributes 只覆盖同名字段，未提及字段保留（rating/label 各自独立）；
    /// - keywords 传 nil 表示「本次不动关键词」，传数组表示整体替换；
    /// - status 经迁移表校验（synced → pending 是「新输入重新打开」的合法路径）。
    ///
    /// 读-合并-写在**一个事务**内完成：旧实现由仓库保证同一路径串行，
    /// 否则两个并发入队会互相覆盖对方的字段。
    @discardableResult
    public func mergeItem(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule,
        attributes: [String: JSONValue] = [:],
        keywords: [String]? = nil,
        status: DeliveryItemStatus = .pending,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow {
        let path = try normalizedPath(xmpPath)
        return try connection.transaction {
            guard let delivery = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            let existing = try itemRow(deliveryId: delivery.id, photoId: photoId, module: module)
            var merged = existing?.attributes ?? [:]
            for (key, value) in attributes { merged[key] = value }
            return try upsertItem(
                xmpPath: path,
                photoId: photoId,
                module: module,
                attributes: merged,
                keywords: keywords ?? existing?.keywordList ?? [],
                status: status,
                errorMessage: errorMessage
            )
        }
    }

    /// 手动元数据入队的原子入口（P1-3）：开行（mergeInput）+ 合并 item + 链接会话
    /// 收进**一个** connection.transaction。
    ///
    /// 三步原先由 MetadataMutationService 分别调用、各自提交：中间任一步失败会留下
    /// 「revision 已 +1、status=pending，但没有任何 item/link」的幽灵交付（永久阻断
    /// 该侧车其它模块 confirm，且无 item 可执行），或 linkSession 被 FK 拒绝后留下
    /// 孤儿 pending item（会话/UI/cleanup 都看不到）。原子化后任何一步失败整体回滚：
    /// revision 不推进、不产生 delivery_items / delivery_sessions 行。
    ///
    /// 参数语义与各步完全一致（attributes/keywords 由服务层算好；keywords=nil 表示
    /// 本次不动词表；入队状态固定 pending）。返回提交后的交付行。
    @discardableResult
    public func applyMetadataMutation(
        xmpPath: String,
        photoPath: String,
        photoId: String,
        sessionId: String,
        attributes: [String: JSONValue] = [:],
        keywords: [String]? = nil
    ) throws -> DeliveryRow {
        let path = try normalizedPath(xmpPath)
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        return try connection.transaction {
            _ = try openDeliveryForInput(xmpPath: path, photoPath: photoPath)
            _ = try mergeItem(
                xmpPath: path,
                photoId: photoId,
                module: .metadata,
                attributes: attributes,
                keywords: keywords,
                status: .pending)
            // 链接会话：conflicts 按会话反查交付（旧 metadata_outbox_sessions 的等价物）。
            // session 不存在时 FK 拒绝 → 外层事务把前两步一并回滚。
            _ = try linkSession(xmpPath: path, sessionId: sessionId)
            guard let row = try get(path) else {
                throw DeliveryRepoError.writeNotPersisted(path)
            }
            return row
        }
    }

    /// 「新输入」重开交付行（原 MetadataMutationService.openDelivery 的原子版）。
    ///
    /// - 行不存在 → 新建（pending，revision 1 = 首个输入版本号）；
    /// - cleaned 是审计终态（D-031），不可重开：显式失败，不静默丢弃用户输入；
    /// - 其余状态一律 revision + 1 回到 pending，**基线保持不变**
    ///   （真实基线由执行器写盘后回读落库，本层不猜）。
    /// - CAS 失配重读一次再推（单连接事务内通常不会发生，保留与服务层旧语义一致）。
    private func openDeliveryForInput(xmpPath: String, photoPath: String) throws -> DeliveryRow {
        for _ in 0..<2 {
            guard let current = try get(xmpPath) else {
                // 首次输入 = revision 1（旧 outbox mergePatch 对新建行的同一口径）。
                return try createOrGet(xmpPath: xmpPath, photoPath: photoPath, revision: 1)
            }
            guard let typed = current.typedStatus else {
                throw DeliveryRepoError.illegalTransition(
                    xmpPath: current.xmpPath,
                    from: current.status,
                    to: DeliveryStatus.pending.rawValue)
            }
            guard typed != .cleaned else {
                throw DeliveryRepoError.illegalTransition(
                    xmpPath: current.xmpPath,
                    from: typed.rawValue,
                    to: DeliveryStatus.pending.rawValue)
            }
            if let merged = try mergeInput(
                xmpPath: current.xmpPath,
                photoPath: current.photoPath.isEmpty ? photoPath : current.photoPath,
                expectedRevision: current.revision,
                newRevision: current.revision + 1,
                baseFingerprint: current.baseFingerprint,
                baseValues: current.baseValues
            ) {
                return merged
            }
        }
        throw DeliveryRepoError.writeNotPersisted(xmpPath)
    }

    // MARK: - 会话链接

    /// 把交付链接到会话（delivery_sessions 的 ONLY 写入路径）。
    ///
    /// 语义：
    /// - 幂等（UNIQUE(delivery_id, session_id)）：新链接以 confirmed_at='' 插入，
    ///   不继承该交付上任何旧确认；重复链接把**该会话**的 confirmed_at 重置为 ''。
    ///   其他会话的确认只由新输入（mergeInput）统一失效，链接本身不替别人清确认。
    /// - **不改 delivery.status**：链接本身不是输入变更；synced 行被新会话链接后仍是 synced，
    ///   但新链接的 confirmed_at=''，交付若仍停在 written，任何会话的 confirm 都不会翻 synced。
    /// - session 不存在时由 FK 显式拒绝（不静默丢链接）。
    @discardableResult
    public func linkSession(xmpPath: String, sessionId: String) throws -> DeliveryRow {
        let path = try normalizedPath(xmpPath)
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        let now = nowISOString()
        return try connection.transaction {
            guard let delivery = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            _ = try connection.prepare("""
                INSERT INTO delivery_sessions (delivery_id, session_id, confirmed_at, created_at)
                VALUES (?, ?, '', ?)
                ON CONFLICT(delivery_id, session_id) DO UPDATE SET confirmed_at = ''
                """).run([.int(delivery.id), .text(sessionId), .text(now)])
            guard let row = try get(path) else {
                throw DeliveryRepoError.writeNotPersisted(path)
            }
            return row
        }
    }

    // MARK: - 交付项删除

    /// 删除指定交付下、给定模块/状态的 items（默认只删 pending+failed，对齐旧 discard 语义）。
    /// 返回实际删除行数。
    @discardableResult
    public func deleteItems(
        xmpPath: String,
        module: DeliveryModule? = nil,
        statuses: Set<DeliveryItemStatus> = [.pending, .failed]
    ) throws -> Int {
        _ = try normalizedPath(xmpPath)
        guard !statuses.isEmpty else { return 0 }
        return try connection.transaction {
            try deleteItemsInTransaction(
                xmpPath: xmpPath, module: module, statuses: statuses)
        }
    }

    /// 事务内变体（WP2b）：调用方已持有 connection.transaction 时使用，不另开 savepoint。
    ///
    /// 目前唯一调用方是 DeliveryDBPhase 的 retainForeign 分支：只清本模块 item
    /// 与 intent.finish 必须同事务，避免「item 已删、intent 未收尾」。
    @discardableResult
    public func deleteItemsInTransaction(
        xmpPath: String,
        module: DeliveryModule? = nil,
        statuses: Set<DeliveryItemStatus> = [.pending, .failed]
    ) throws -> Int {
        let path = try normalizedPath(xmpPath)
        guard !statuses.isEmpty else { return 0 }
        guard let delivery = try get(path) else {
            throw DeliveryRepoError.rowNotFound(xmpPath: path)
        }
        var sql = "DELETE FROM delivery_items WHERE delivery_id = ?"
        var values: [DBValue?] = [.int(delivery.id)]
        if let module {
            sql += " AND module = ?"
            values.append(.text(module.rawValue))
        }
        let placeholders = statuses
            .sorted { $0.rawValue < $1.rawValue }
            .map { _ in "?" }
            .joined(separator: ", ")
        sql += " AND status IN (\(placeholders))"
        values.append(contentsOf: statuses
            .sorted { $0.rawValue < $1.rawValue }
            .map { DBValue.text($0.rawValue) })
        return try connection.prepare(sql).run(values)
    }
}
