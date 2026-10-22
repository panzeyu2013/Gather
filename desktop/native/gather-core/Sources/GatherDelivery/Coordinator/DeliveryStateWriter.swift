// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryStateWriter.swift
// WP2b：交付状态写入的**唯一入口**。
//
// 迁移前：WritebackService（18 处）、DeliveryCoordinator（9 处）、
// MetadataMutationService（1 处）各自持 DeliveryRepo 调 markWriting / markWritten /
// mergeInput / deleteSyncedDelivery；状态机可被任意编排代码绕过。
//
// 迁移后：GatherDelivery 内所有 deliveries / delivery_items 的写操作只在本文件
// 出现；P1-2 起 Host 的 LiveMetadataAPI 也不再直调 DeliveryRepo 的写方法，
// 只经本文件新增的那组公开语义入口（acceptExternalState / reopenConflict /
// retryOrphan / deleteOrphanDelivery / persistAcceptedRemoteFields）。
// 模块外**只**公开这 5 个语义入口：Host 能表达「冲突部分接受 / 孤儿重试 /
// 采纳外部基线」的业务语义，但拿不到 markWriting / markWritten / mergeInput /
// markItem / resetConfirmations / updateItem* 这些单步迁移，也就拼不出绕过
// writer 的写序列（状态机唯一 owner 在模块边界上成立，而非只在模块内）。
//
// 本类型不持连接、不复制 SQL、不新增事务边界：
// - 普通写入口由 Repo 自己开事务（与迁移前一致，行为不变）；
// - 语义组合入口按调用方原有顺序调用多个 Repo 方法（每一步的事务边界不变，
//   刻意不合成跨步骤大事务：失败时的中间态与迁移前逐字一致）；
// - 带 InTransaction 后缀的入口供 DeliveryDBPhase 在已开启的事务内调用，
//   用于「DB 删除 + intent.finish 同一事务」。

import Foundation
import GatherPersistence
import GatherProtocol

public struct DeliveryStateWriter: Sendable {
    private let repo: DeliveryRepo

    /// 模块外（Host 的 LiveMetadataAPI）用同一 DeliveryRepo 构造；
    /// 生产组合根里与 DeliveryCoordinator / WritebackService 共用同一连接。
    public init(repo: DeliveryRepo) {
        self.repo = repo
    }

    // MARK: - 交付级状态

    /// 建行或读取既有交付（镜像/preview 的开行入口；revision 由调用方给）。
    @discardableResult
    func createOrGet(
        xmpPath: String,
        photoPath: String,
        revision: Int64 = 0,
        baseFingerprint: String = "",
        baseValues: JSONValue = .object([:])
    ) throws -> DeliveryRow {
        try repo.createOrGet(
            xmpPath: xmpPath,
            photoPath: photoPath,
            revision: revision,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues
        )
    }

    /// 新输入重新打开为 pending（revision 由调用方推进）。
    @discardableResult
    func mergeInput(
        xmpPath: String,
        photoPath: String,
        expectedRevision: Int64,
        newRevision: Int64,
        baseFingerprint: String,
        baseValues: JSONValue
    ) throws -> DeliveryRow? {
        try repo.mergeInput(
            xmpPath: xmpPath,
            photoPath: photoPath,
            expectedRevision: expectedRevision,
            newRevision: newRevision,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues
        )
    }

    /// 抢写租约（pending/failed/conflict → writing；writing 自迁移=续租）。
    @discardableResult
    func claimWriting(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String,
        heartbeatAt: String? = nil
    ) throws -> DeliveryRow? {
        try repo.claimWriting(
            xmpPath: xmpPath,
            revision: revision,
            leaseOwner: leaseOwner,
            heartbeatAt: heartbeatAt
        )
    }

    /// 同 owner 心跳续租；false = 租约已丢失。
    func renewWriting(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String,
        heartbeatAt: String? = nil
    ) throws -> Bool {
        try repo.renewWriting(
            xmpPath: xmpPath,
            revision: revision,
            leaseOwner: leaseOwner,
            heartbeatAt: heartbeatAt
        )
    }

    /// writing → written（落盘成功）。写者必须传自己的 leaseOwner（P1-2）：
    /// 租约被接管/重开时 Repo 抛 leaseLost，调用方不得覆盖新基线。
    @discardableResult
    func markWritten(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String,
        baseFingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) throws -> DeliveryRow? {
        try repo.markWritten(
            xmpPath: xmpPath,
            revision: revision,
            leaseOwner: leaseOwner,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues,
            backupPath: backupPath
        )
    }

    /// pending/writing/failed → failed。
    @discardableResult
    func markFailed(
        xmpPath: String,
        revision: Int64,
        errorMessage: String
    ) throws -> DeliveryRow? {
        try repo.markFailed(
            xmpPath: xmpPath, revision: revision, errorMessage: errorMessage)
    }

    /// 外部修改：任意活跃态 → conflict。
    @discardableResult
    func markConflict(
        xmpPath: String,
        revision: Int64,
        errorMessage: String
    ) throws -> DeliveryRow? {
        try repo.markConflict(
            xmpPath: xmpPath, revision: revision, errorMessage: errorMessage)
    }

    /// 会话确认（门禁读 + 单事务状态推进）。
    ///
    /// requireReloadAck 必须由调用方显式给出：完整性/reload-ack 门禁与
    /// confirmed_at 更新都在 Repo 的同一个事务内（P1-3），不存在只写确认的旁路。
    @discardableResult
    func confirm(
        scope: DeliveryConfirmScope,
        sessionId: String,
        module: DeliveryModule? = nil,
        requireReloadAck: Bool
    ) throws -> DeliveryConfirmSummary {
        try repo.confirm(
            scope: scope,
            sessionId: sessionId,
            module: module,
            requireReloadAck: requireReloadAck)
    }

    /// 交付链接会话（delivery_sessions 的唯一写路径）。
    @discardableResult
    func linkSession(xmpPath: String, sessionId: String) throws -> DeliveryRow {
        try repo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
    }

    /// 镜像开行：行不存在则创建；cleaned 是审计终态 → nil；否则按新输入推进 revision。
    /// CAS 失配时重读一次再推（与迁移前的两次尝试逐字一致）。
    func openDeliveryForWrite(
        xmpPath: String,
        photoPath: String,
        baseFingerprint: String,
        baseValues: JSONValue
    ) throws -> Int64? {
        guard let existing = try repo.get(xmpPath) else {
            return try repo.createOrGet(
                xmpPath: xmpPath,
                photoPath: photoPath,
                revision: 0,
                baseFingerprint: baseFingerprint,
                baseValues: baseValues
            ).revision
        }
        guard !DeliveryStateMachine.isTerminalForNewInput(existing.typedStatus) else { return nil }
        var current = existing
        for _ in 0..<2 {
            if let merged = try mergeInput(
                xmpPath: xmpPath,
                photoPath: photoPath,
                expectedRevision: current.revision,
                newRevision: current.revision + 1,
                baseFingerprint: baseFingerprint,
                baseValues: baseValues
            ) {
                return merged.revision
            }
            // CAS 失配（并发写入推进了 revision）：重读一次再推，仍失败则交给调用方记账。
            guard let latest = try repo.get(xmpPath),
                  !DeliveryStateMachine.isTerminalForNewInput(latest.typedStatus)
            else { return nil }
            current = latest
        }
        return nil
    }

    // MARK: - 交付项状态

    @discardableResult
    func upsertItem(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule,
        attributes: [String: JSONValue] = [:],
        keywords: [String] = [],
        status: DeliveryItemStatus = .pending,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow {
        try repo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoId,
            module: module,
            attributes: attributes,
            keywords: keywords,
            status: status,
            errorMessage: errorMessage
        )
    }

    @discardableResult
    func markItem(
        itemId: Int64,
        status: DeliveryItemStatus,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow? {
        try repo.markItem(itemId: itemId, status: status, errorMessage: errorMessage)
    }

    @discardableResult
    func deleteItems(
        xmpPath: String,
        module: DeliveryModule? = nil,
        statuses: Set<DeliveryItemStatus> = [.pending, .failed]
    ) throws -> Int {
        try repo.deleteItems(xmpPath: xmpPath, module: module, statuses: statuses)
    }

    func updateItemAttributes(_ updates: [(itemId: Int64, attributes: [String: JSONValue])]) throws {
        try repo.updateItemAttributes(updates)
    }

    func updateItemKeywords(_ updates: [(itemId: Int64, keywords: [String])]) throws {
        try repo.updateItemKeywords(updates)
    }

    /// 元数据入队（mergeInput + item + link 的 Compound 事务）。
    @discardableResult
    func enqueueMetadataMutation(
        xmpPath: String,
        photoPath: String,
        photoId: String,
        sessionId: String,
        attributes: [String: JSONValue],
        keywords: [String]?
    ) throws -> DeliveryRow {
        try repo.applyMetadataMutation(
            xmpPath: xmpPath,
            photoPath: photoPath,
            photoId: photoId,
            sessionId: sessionId,
            attributes: attributes,
            keywords: keywords
        )
    }

    // MARK: - 冲突裁决 / 孤儿处置（Host 语义入口，P1-2）
    //
    // 这 5 个入口是 LiveMetadataAPI 在拆掉对 DeliveryRepo 的直接依赖后唯一需要的
    // 写语义。每个入口都只组合本文件既有的低层方法（或 Repo 的单次调用），
    // 不复制 SQL、不改事务边界；语义/顺序/返回值与原 Host 调用点逐字对应。

    /// 采纳外部内容为新基线：writing → 使全部关联会话确认失效 → written。
    ///
    /// 顺序不可交换（原 LiveMetadataAPI.acceptExternalState 的逐字迁移）：
    /// 1. claimWriting：conflict → writing（带本次调用唯一的 leaseOwner，P1-2；
    ///    他人持有未过期租约时抛 leaseHeld，绝不覆盖正在进行的写回）；
    /// 2. resetConfirmations：冲突前的 confirmed_at 属于旧内容，必须清空，
    ///    否则旧确认会通过 confirm 的跨会话门禁，把裁决后的首次 confirm
    ///    直接翻成 synced（P1-10）。reset 只在 writing 态执行——writing 不是
    ///    可确认态，清空后到 written 之间不会有人重新确认；
    /// 3. markWritten：盘上内容成为新基线（baseFingerprint/baseValues），
    ///    backup_path 原样保留，cleanup 仍能恢复原侧车。
    ///
    /// 失败语义：claimWriting / markWritten 的 CAS 失配抛 writeNotPersisted；
    /// 租约冲突抛 leaseHeld；中间 reset 失败直接向上传播（此时停在 writing）。
    /// 刻意停在 written：等各关联会话各自 confirm，本入口绝不翻 synced。
    @discardableResult
    public func acceptExternalState(
        xmpPath: String,
        revision: Int64,
        baseFingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) throws -> DeliveryRow {
        let leaseOwner = "conflict-" + UUID().uuidString
        guard try claimWriting(
            xmpPath: xmpPath, revision: revision, leaseOwner: leaseOwner) != nil else {
            throw DeliveryRepoError.writeNotPersisted(xmpPath)
        }
        _ = try resetConfirmations(xmpPath: xmpPath)
        guard let written = try markWritten(
            xmpPath: xmpPath,
            revision: revision,
            leaseOwner: leaseOwner,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues,
            backupPath: backupPath
        ) else {
            throw DeliveryRepoError.writeNotPersisted(xmpPath)
        }
        return written
    }

    /// 冲突部分接受：交付按新 revision 重开为 pending，并把交付项退回 pending。
    ///
    /// 两步都在原 LiveMetadataAPI.resolveConflict 的同一位置：
    /// - mergeInput：revision + 1、状态回 pending，并在同一事务里清空该交付
    ///   全部关联会话的 confirmed_at（新内容的确认必须覆盖所有会话）；
    /// - 逐项 markItem(.pending)：attempt_count + 1，执行器下一次写盘即覆盖为
    ///   本地值。
    ///
    /// itemIds 由调用方在裁决前读取并原序传入；mergeInput CAS 失配先抛
    /// writeNotPersisted，此时一个 delivery_items 都不动（与原实现「先 merge
    /// 再逐项」的顺序一致）。
    @discardableResult
    public func reopenConflict(
        xmpPath: String,
        photoPath: String,
        expectedRevision: Int64,
        baseFingerprint: String,
        baseValues: JSONValue,
        itemIds: [Int64]
    ) throws -> Int64 {
        let reopened = try mergeInput(
            xmpPath: xmpPath,
            photoPath: photoPath,
            expectedRevision: expectedRevision,
            newRevision: expectedRevision + 1,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues
        )
        guard let reopened else {
            throw DeliveryRepoError.writeNotPersisted(xmpPath)
        }
        for itemId in itemIds {
            _ = try markItem(itemId: itemId, status: .pending)
        }
        return reopened.revision
    }

    /// 孤儿 retry：failed/pending 重新入队（revision 推进 → pending；**不动 items**）。
    ///
    /// 与 reopenConflict 的差别是语义性的：孤儿没有任何会话关联，retry 只是把
    /// 同一条 failed/pending 交付重新排队；旧实现也不在这里重置 item 状态，
    /// 本入口保持逐字一致（执行器按 upsert 复用旧项）。
    @discardableResult
    public func retryOrphan(
        xmpPath: String,
        photoPath: String,
        expectedRevision: Int64,
        baseFingerprint: String,
        baseValues: JSONValue
    ) throws -> Int64 {
        let reopened = try mergeInput(
            xmpPath: xmpPath,
            photoPath: photoPath,
            expectedRevision: expectedRevision,
            newRevision: expectedRevision + 1,
            baseFingerprint: baseFingerprint,
            baseValues: baseValues
        )
        guard let reopened else {
            throw DeliveryRepoError.writeNotPersisted(xmpPath)
        }
        return reopened.revision
    }

    /// 删除孤儿交付（单事务：revision CAS + 仍无会话关联 + 子行删除）。
    ///
    /// 返回 false 只表示状态已漂移（并发改写 / 被重新链接），调用方重读列表，
    /// 不得当作成功——原 LiveMetadataAPI.resolveOrphan 的守卫语义原样保留。
    public func deleteOrphanDelivery(xmpPath: String, revision: Int64) throws -> Bool {
        try repo.deleteOrphanDelivery(xmpPath: xmpPath, revision: revision)
    }

    /// 采纳远程字段后，把本地投影改写回交付项（先属性、后关键词）。
    ///
    /// 两批写各自单事务（Repo 语义），顺序与迁移前一致：属性（rating/label
    /// 从投影删除）成功后才会写 keywords；任一行缺失整批回滚并抛
    /// writeNotPersisted。空数组时 Repo 自己 no-op，不额外短路。
    public func persistAcceptedRemoteFields(
        attributeUpdates: [(itemId: Int64, attributes: [String: JSONValue])],
        keywordUpdates: [(itemId: Int64, keywords: [String])]
    ) throws {
        try updateItemAttributes(attributeUpdates)
        try updateItemKeywords(keywordUpdates)
    }

    /// 使该交付的全部关联会话确认失效（P1-10 的专用入口）。
    ///
    /// 单事务；返回本次实际清空的行数（原本已为空的不计，重复调用幂等）。
    /// 只由 acceptExternalState 在 writing → written 之间调用；**不公开**：
    /// 单独清确认而不推进状态会让交付停在可确认态，模块外只能通过
    /// acceptExternalState 表达同一语义。
    @discardableResult
    func resetConfirmations(xmpPath: String) throws -> Int {
        try repo.resetConfirmations(xmpPath: xmpPath)
    }

    // MARK: - DB 删除（cleanup / finalize）

    /// 单事务删除 synced 交付（独立入口；与迁移前一致）。
    @discardableResult
    func deleteSyncedDelivery(
        xmpPath: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryRepo.DeliveryDeleteOutcome {
        try repo.deleteSyncedDelivery(
            xmpPath: xmpPath, deliveryId: deliveryId, revision: revision)
    }

    /// 事务内变体：调用方已开启 connection.transaction（DB 删除 + intent.finish）。
    @discardableResult
    func deleteSyncedDeliveryInTransaction(
        xmpPath: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryRepo.DeliveryDeleteOutcome {
        try repo.deleteSyncedDeliveryInTransaction(
            xmpPath: xmpPath, deliveryId: deliveryId, revision: revision)
    }

    /// 事务内删除交付项（retainForeign 分支）。
    @discardableResult
    func deleteItemsInTransaction(
        xmpPath: String,
        module: DeliveryModule? = nil,
        statuses: Set<DeliveryItemStatus> = [.pending, .failed]
    ) throws -> Int {
        try repo.deleteItemsInTransaction(
            xmpPath: xmpPath, module: module, statuses: statuses)
    }
}
