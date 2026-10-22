// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryStateWriter.swift
// WP2b：交付状态写入的**唯一入口**。
//
// 迁移前：WritebackService（18 处）、DeliveryCoordinator（9 处）、
// MetadataMutationService（1 处）各自持 DeliveryRepo 调 markWriting / markWritten /
// mergeInput / deleteSyncedDelivery；状态机可被任意编排代码绕过。
//
// 迁移后：GatherDelivery 内所有 deliveries / delivery_items 的写操作只在本文件
// 出现（Host 的 LiveMetadataAPI 仍有 6 处直调，属越界残余，见交付说明）。
// 本类型只做「合法性判定 + 一次仓储调用」，不持连接、不开事务：
// - 普通写入口由 Repo 自己开事务（与迁移前一致，行为不变）；
// - 带 InTransaction 后缀的入口供 DeliveryDBPhase 在已开启的事务内调用，
//   用于「DB 删除 + intent.finish 同一事务」。

import Foundation
import GatherPersistence
import GatherProtocol

struct DeliveryStateWriter: Sendable {
    private let repo: DeliveryRepo

    init(repo: DeliveryRepo) {
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

    /// 无租约的 pending/failed/conflict → writing（镜像路径）。
    @discardableResult
    func markWriting(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String = "",
        heartbeatAt: String? = nil
    ) throws -> DeliveryRow? {
        try repo.markWriting(
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

    /// writing → written（落盘成功）。
    @discardableResult
    func markWritten(
        xmpPath: String,
        revision: Int64,
        baseFingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) throws -> DeliveryRow? {
        try repo.markWritten(
            xmpPath: xmpPath,
            revision: revision,
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
    @discardableResult
    func confirm(
        scope: DeliveryConfirmScope,
        sessionId: String,
        module: DeliveryModule? = nil
    ) throws -> DeliveryConfirmSummary {
        try repo.confirm(scope: scope, sessionId: sessionId, module: module)
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
