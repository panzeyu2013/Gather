// desktop/native/gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift
// Cut 1 / B6a + Cut 2 / S5c-2b-3b-2b-2：MetadataAPI 的 Live 实现（7 个方法）。
//
// 对应命令（7 条）：metadata.get / set / batch_set / conflicts / orphans /
// resolve_conflict / resolve_orphan。
//
// 依赖（2b-2 起不再持有 MetadataSyncCoordinator）：
// - metadataService：get/set/batchSet（缓存指纹、可写字段白名单、侧车分组串行）；
// - deliveryRepo：conflicts / resolveConflict / orphans / resolveOrphan 的唯一
//   持久化入口（deliveries / delivery_items / delivery_sessions）；
// - xmp：冲突的 remote 值读取与孤儿 restore/remove 的文件阶段（旧协调器的同一
//   两个动作，收窄为只读属性 + 三文件操作）。
//
// 校验归属：
// - MetadataGetInput 已在输入类型完成 photoIds 非空、逐项非空白、去重与
//   10000 上限；MetadataSetInput / MetadataBatchSetInput 完成 photoId 与
//   updates 非空校验；resolveConflict / resolveOrphan 的 choices 非空、未知
//   字段、action 枚举也在输入类型收敛（G5/G6）。本实现不重复解析 JSON；
// - 只接收 sessionId 的 conflicts 在这里补"非空白 + 长度上限"校验（对齐
//   LiveAPIInput.requireSessionId），失败统一 GatherError.invalidParameter；
// - 4 个破坏性入口只接收 Confirmed<T>（set / batchSet / resolveConflict /
//   resolveOrphan），内部固定传服务层语义：类型层面已经保证"没有确认弹窗
//   就写不出调用点"，实现不自行补确认、也不再解析 Bool（D-011）。
//
// 冲突/孤儿的领域判定（D-089 / 2b-2）：
// - 冲突是**交付级**事实：deliveries.status = conflict 且该交付经
//   delivery_sessions 关联到会话。可裁决字段从 delivery_items 派生
//   （rating/label 取自 attributes_json，keywords 取自 keywords 列；无任何可
//   推导字段时退回三个可写字段——旧协调器"无字段级差异也必须给出可裁决项"
//   的同一语义）；remote 值实时读盘（读不到按空属性处理，不伪造冲突）。
// - 裁决写交付：接受远程的字段从本地投影删除（keywords 改为盘上词表），
//   仍有保留字段 → 交付 revision + 1 回到 pending 并重排项（执行器重写本地值）；
//   全部接受 → 以盘上内容为新基线，只走 conflict → writing → written（保留
//   backup_path，cleanup 仍能恢复原文件）。**绝不在这里翻 synced**：synced 是
//   “全部 delivery_sessions 已确认”的跨会话结论，只能由 DeliveryRepo.confirm
//   在事务内判定（P1-10）。裁决只代表本会话接受远程，不代表其它会话已确认。
// - 孤儿 = 没有任何 delivery_sessions 关联的交付（旧 getOrphans 的同一判据）；
//   keep 删行、restore 先回滚文件再删行、retry 只把 failed/pending 重新入队。
//
// 错误映射：领域码一律以 GatherError 直出（XMP_CONFLICT_NOT_FOUND /
// XMP_CHOICE_MISSING / XMP_ORPHAN_NOT_FOUND / ...），不再依赖旧协调器的
// MetadataSyncError（2b-3 删除旧链路时本文件无需再改）。MetadataServiceError
// 与 DeliveryRepoError 没有协议码，保留原错误（D-030：非域错误不伪造业务码）。
// DBError.message 若本身就是错误码同样还原为 GatherError。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

public final class LiveMetadataAPI: MetadataAPI {
    private let metadataService: MetadataService
    private let deliveryRepo: DeliveryRepo
    private let xmp: any XMPProvider
    /// 与 DeliveryCoordinator / WritebackService 共用的按 xmpPath 文件锁。
    /// 生产组合根把 XMPFileLock.shared 同时注入三者（AppComposition），
    /// 缺省也是 .shared：孤儿 restore/remove 与 cleanup/replay/writeback 串行。
    private let fileLock: XMPFileLock

    /// Sendable 由协议继承显式声明：类为 final，四个依赖都是构造后不再变更的
    /// Sendable let（Repo 只持连接、XMPProvider 由宿主实现保证），故无需 @unchecked。
    public init(
        metadataService: MetadataService,
        deliveryRepo: DeliveryRepo,
        xmp: any XMPProvider,
        fileLock: XMPFileLock = .shared
    ) {
        self.metadataService = metadataService
        self.deliveryRepo = deliveryRepo
        self.xmp = xmp
        self.fileLock = fileLock
    }

    // MARK: - 读取

    public func get(_ input: MetadataGetInput) async throws -> [String: MetadataTags] {
        try await mapAsync {
            try await metadataService.getMetadata(photoIds: input.photoIds)
        }
    }

    public func conflicts(_ sessionId: String) async throws -> [MetadataConflict] {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync {
            var conflicts: [MetadataConflict] = []
            for delivery in try deliveryRepo.conflictDeliveries(sessionId: id) {
                let items = try deliveryRepo.items(deliveryId: delivery.id)
                let remote = (try? await xmp.readAttributes(photoPath: delivery.photoPath))
                    ?? MetadataWriteAttributes()
                let fields = Self.dirtyFields(items: items).map { field in
                    MetadataConflictField(
                        field: field,
                        baseline: Self.baselineValue(field, base: delivery.baseValues),
                        local: Self.localValue(field, items: items),
                        remote: Self.remoteValue(field, remote: remote)
                    )
                }
                conflicts.append(MetadataConflict(
                    xmpPath: delivery.xmpPath,
                    photoPath: delivery.photoPath,
                    revision: Int(delivery.revision),
                    fields: fields
                ))
            }
            return conflicts
        }
    }

    public func orphans() async throws -> [MetadataOrphan] {
        try map { try listOrphans() }
    }

    // MARK: - 写入（Confirmed<T>）

    public func set(_ input: Confirmed<MetadataSetInput>) async throws -> MetadataTags {
        let payload = input.value
        return try await mapAsync {
            try await metadataService.setMetadata(photoId: payload.photoId, tags: payload.tags)
        }
    }

    public func batchSet(_ input: Confirmed<MetadataBatchSetInput>) async throws -> BatchMetadataResult {
        let updates = input.value.updates.map { (photoId: $0.photoId, tags: $0.tags) }
        return try await mapAsync {
            try await metadataService.batchSet(updates: updates)
        }
    }

    // MARK: - 冲突/孤儿处置（Confirmed<T>）

    public func resolveConflict(
        _ input: Confirmed<MetadataResolveConflictInput>
    ) async throws -> MetadataSyncSummary {
        let payload = input.value
        return try await mapAsync {
            let path = TSPath.normalize(payload.xmpPath)
            guard let delivery = try deliveryRepo
                .conflictDeliveries(sessionId: payload.sessionId)
                .first(where: { $0.xmpPath == path }) else {
                throw GatherError(code: .XMP_CONFLICT_NOT_FOUND, underlying: path)
            }
            let items = try deliveryRepo.items(deliveryId: delivery.id)
            let dirty = Self.dirtyFields(items: items)
            // 每个待裁决字段都必须有选择（旧 reconcile 的同一门禁）；
            // choices 里多出的未改动字段只记日志，不参与写入。
            for field in dirty where payload.choices[field] == nil {
                throw GatherError(code: .XMP_CHOICE_MISSING, underlying: field.rawValue)
            }
            for field in payload.choices.keys where !dirty.contains(field) {
                GatherLogger.log(
                    "Ignoring conflict choice for untouched field \(field.rawValue) at \(path)",
                    level: .warn)
            }
            let accepted = dirty.filter { payload.choices[$0] == .useRemote }
            let remote = (try? await xmp.readAttributes(photoPath: delivery.photoPath))
                ?? MetadataWriteAttributes()
            if !accepted.isEmpty {
                try applyAcceptedRemote(accepted, items: items, remote: remote)
            }
            let remaining = dirty.filter { payload.choices[$0] != .useRemote }
            if remaining.isEmpty {
                // 全部接受远程：盘上内容成为新基线，交付结清（不再重写本地值）。
                try await acceptExternalState(delivery: delivery, remote: remote)
            } else {
                // 仍有保留字段：交付回到 pending（新输入 revision）并重排项，
                // 执行器下一次写盘即覆盖为本地值。
                guard try deliveryRepo.mergeInput(
                    xmpPath: delivery.xmpPath,
                    photoPath: delivery.photoPath,
                    expectedRevision: delivery.revision,
                    newRevision: delivery.revision + 1,
                    baseFingerprint: delivery.baseFingerprint,
                    baseValues: delivery.baseValues
                ) != nil else {
                    throw DeliveryRepoError.writeNotPersisted(delivery.xmpPath)
                }
                for item in items {
                    _ = try deliveryRepo.markItem(itemId: item.id, status: .pending)
                }
            }
            return try deliveryRepo.metadataSummary(sessionId: payload.sessionId)
        }
    }

    public func resolveOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        let payload = input.value
        return try await mapAsync {
            let path = TSPath.normalize(payload.xmpPath)
            guard let row = try deliveryRepo.orphanDeliveries()
                .first(where: { $0.xmpPath == path }) else {
                throw GatherError(code: .XMP_ORPHAN_NOT_FOUND, underlying: path)
            }
            if payload.action == .retry {
                switch row.typedStatus {
                case .some(.conflict):
                    throw GatherError(code: .XMP_CONFLICT_RESOLUTION_REQUIRED, underlying: path)
                case .some(.pending), .some(.failed):
                    // failed → pending 是合法迁移；pending 重新入队幂等（revision 推进）。
                    guard try deliveryRepo.mergeInput(
                        xmpPath: row.xmpPath,
                        photoPath: row.photoPath,
                        expectedRevision: row.revision,
                        newRevision: row.revision + 1,
                        baseFingerprint: row.baseFingerprint,
                        baseValues: row.baseValues
                    ) != nil else {
                        throw DeliveryRepoError.writeNotPersisted(row.xmpPath)
                    }
                default:
                    throw GatherError(code: .XMP_ORPHAN_NOT_RETRYABLE, underlying: path)
                }
                return try listOrphans()
            }
            if payload.action == .restore {
                // 与旧协调器同一顺序：先回滚文件，再删行（行删除失败可原样重试）。
                //
                // P0-1 第二入口：从 orphanDeliveries() 快照到 restore 之间可能已经
                // 被新会话链接 / 新输入推进 revision（mergeInput）。复核 → restore/
                // remove → 事后复核必须**整体**在同一次 XMPFileLock.run 内完成，
                // 且与 cleanup/finalize/replay 及 WritebackService 写盘共用同一实例
                // （AppComposition 注入 .shared）；否则旧备份会在新内容落盘后覆盖它。
                // 锁不可重入：闭包内只读交付行 + 调 XMPProvider，绝不再取同一路径锁。
                try await fileLock.run(path: row.xmpPath) {
                    try await restoreOrphanFile(row)
                }
            }
            guard try deliveryRepo.deleteOrphanDelivery(
                xmpPath: row.xmpPath, revision: row.revision) else {
                // 行已被并发改写/重新链接：不当作成功，重读列表返回真实状态。
                return try listOrphans()
            }
            // 备份文件在行删除成功之后清理（避免删备份成功 + 删行失败 → backupMissing）。
            if !row.backupPath.isEmpty, xmp.fileExists(row.backupPath) {
                try? await xmp.removeFile(row.backupPath)
            }
            return try listOrphans()
        }
    }

    /// 孤儿 restore/remove 的文件阶段（调用方必须已持有 fileLock.run(path:)）。
    ///
    /// 保留原入口的 A 守卫：restore/remove 前后各复核一次 revision/status/backup
    /// 且仍无会话关联；备份缺失显式失败（不删行）。锁只覆盖文件阶段——行删除仍由
    /// deleteOrphanDelivery 的 revision + 无链接 CAS 兜底，避免在锁内跨 DB 事务。
    private func restoreOrphanFile(_ row: DeliveryRow) async throws {
        if !row.backupPath.isEmpty {
            guard xmp.fileExists(row.backupPath) else {
                throw GatherError(code: .XMP_BACKUP_MISSING, underlying: row.backupPath)
            }
            try requireUnchangedOrphan(row)
            try await xmp.restore(photoPath: row.photoPath, backupPath: row.backupPath)
            try requireUnchangedOrphan(row)
        } else if xmp.fileExists(row.xmpPath) {
            try requireUnchangedOrphan(row)
            try await xmp.removeFile(row.xmpPath)
            try requireUnchangedOrphan(row)
        }
    }

    // MARK: - 交付字段投影

    /// 待裁决字段：从交付项派生（rating/label 在 attributes_json，keywords 在列里）。
    ///
    /// 一个侧车可有多条项（RAW+JPEG 共享侧车、多个模块先后写入），同一字段出现
    /// 任意一次即视为本次冲突的待裁决字段；完全推导不出时退回三个可写字段
    /// （交付级冲突仍必须有裁决出口）。
    private static func dirtyFields(items: [DeliveryItemRow]) -> [MetadataField] {
        var hasRating = false
        var hasLabel = false
        var hasKeywords = false
        for item in items {
            let attributes = item.attributes
            if attributes["rating"] != nil { hasRating = true }
            if attributes["label"] != nil { hasLabel = true }
            if !item.keywordList.isEmpty { hasKeywords = true }
        }
        var fields: [MetadataField] = []
        if hasRating { fields.append(.rating) }
        if hasLabel { fields.append(.label) }
        if hasKeywords { fields.append(.keywords) }
        return fields.isEmpty ? MetadataField.allCases : fields
    }

    /// baseline 取交付行的 base_values_json（旧 outbox base_values 的同一语义）。
    private static func baselineValue(_ field: MetadataField, base: JSONValue) -> JSONValue {
        switch field {
        case .keywords:
            let value = base["keywords"]
            return (value == nil || value == .null) ? .array([]) : value!
        case .label:
            let value = base["label"]
            return (value == nil || value == .null) ? .string("") : value!
        case .rating:
            return base["rating"] ?? .null
        }
    }

    /// local 取交付项里的本地输入（同一字段多项时取首项；keywords 取有序并集）。
    private static func localValue(_ field: MetadataField, items: [DeliveryItemRow]) -> JSONValue {
        switch field {
        case .rating:
            for item in items where item.attributes["rating"] != nil {
                return item.attributes["rating"]!
            }
            return .null
        case .label:
            for item in items where item.attributes["label"] != nil {
                return item.attributes["label"]!
            }
            return .string("")
        case .keywords:
            var seen = Set<String>()
            var list: [String] = []
            for item in items {
                for keyword in item.keywordList where seen.insert(keyword).inserted {
                    list.append(keyword)
                }
            }
            return .array(list.map { .string($0) })
        }
    }

    /// remote 取当前盘上属性（读取失败按空属性处理：不伪造冲突值）。
    private static func remoteValue(
        _ field: MetadataField,
        remote: MetadataWriteAttributes
    ) -> JSONValue {
        switch field {
        case .keywords:
            return .array((remote.keywords ?? []).map { .string($0) })
        case .label:
            return .string(remote.label ?? "")
        case .rating:
            return remote.rating.map { .number($0) } ?? .null
        }
    }

    /// 接受远程的字段：从本地投影删除（keywords 改为盘上词表），
    /// 保留字段原样留下（它们仍是要写盘的本地输入）。
    private func applyAcceptedRemote(
        _ fields: [MetadataField],
        items: [DeliveryItemRow],
        remote: MetadataWriteAttributes
    ) throws {
        guard !items.isEmpty, !fields.isEmpty else { return }
        var attributeUpdates: [(itemId: Int64, attributes: [String: JSONValue])] = []
        var keywordUpdates: [(itemId: Int64, keywords: [String])] = []
        for item in items {
            var merged = item.attributes
            if fields.contains(.rating) { merged.removeValue(forKey: "rating") }
            if fields.contains(.label) { merged.removeValue(forKey: "label") }
            if merged != item.attributes {
                attributeUpdates.append((item.id, merged))
            }
            if fields.contains(.keywords) {
                keywordUpdates.append((item.id, remote.keywords ?? []))
            }
        }
        try deliveryRepo.updateItemAttributes(attributeUpdates)
        try deliveryRepo.updateItemKeywords(keywordUpdates)
    }

    /// 全部接受远程：以盘上内容为新基线，只推进到 written。
    ///
    /// P1-10：这里不得直接 synced。synced 表示“该交付的所有关联会话都已确认”，
    /// 只有 DeliveryRepo.confirm 在“全部 delivery_sessions.confirmed_at 非空”的
    /// 单事务里才能翻转；否则一个会话的裁决会把其它会话未确认的新内容当成已确认，
    /// 随后的 confirm 的 itemsSynced 子查询会把它们的 written item 一起翻 synced，
    /// cleanup 便能删掉未确认内容。backup_path 原样保留（cleanup 仍能恢复原侧车）。
    private func acceptExternalState(
        delivery: DeliveryRow,
        remote: MetadataWriteAttributes
    ) async throws {
        let fingerprint: String
        do {
            fingerprint = try await MetadataFingerprint.contentFingerprint(delivery.xmpPath)
        } catch {
            // 读不到文件就无法把盘上状态固化成新基线：显式失败，不写假基线。
            throw GatherError(
                code: .XMP_CONFLICT_DETAILS_UNAVAILABLE,
                underlying: String(describing: error))
        }
        guard try deliveryRepo.markWriting(
                xmpPath: delivery.xmpPath, revision: delivery.revision) != nil else {
            throw DeliveryRepoError.writeNotPersisted(delivery.xmpPath)
        }
        // P1-10 残余：冲突前的 confirmed_at 属于旧内容，不能作为「新基线已确认」
        // 通过 confirm 的跨会话门禁（否则 s1/s2 的旧确认会让裁决后的首次 confirm
        // 直接翻 synced）。在 writing → written 之间清空：writing 本身不是可确认态，
        // 清空后到 written 之间不会有人重新确认；reset 自身单事务，失败则不写 written。
        _ = try deliveryRepo.resetConfirmations(xmpPath: delivery.xmpPath)
        guard try deliveryRepo.markWritten(
                xmpPath: delivery.xmpPath,
                revision: delivery.revision,
                baseFingerprint: fingerprint,
                baseValues: remote.asJSONValue,
                backupPath: delivery.backupPath) != nil else {
            throw DeliveryRepoError.writeNotPersisted(delivery.xmpPath)
        }
        // 刻意停在 written：等待所有关联会话各自 confirm（跨会话门禁）。
    }

    // MARK: - 孤儿恢复守卫（P0-1 第二入口）

    /// 复核孤儿交付自快照以来没有变化，且仍没有会话关联。
    ///
    /// 只读、同步：不做文件操作；不一致抛 XMP_EXTERNAL_EDIT_CONFLICT（错误可见，
    /// 不静默返回列表）。revision 推进说明旧备份已不对应盘上内容；链接出现说明
    /// 别的会话可能正在确认/清理，都不能替它回滚文件。
    private func requireUnchangedOrphan(_ row: DeliveryRow) throws {
        guard let current = try deliveryRepo.get(row.xmpPath) else {
            throw GatherError(code: .XMP_ORPHAN_NOT_FOUND, underlying: row.xmpPath)
        }
        let reason: String?
        if current.id != row.id {
            reason = "delivery-id-changed"
        } else if current.revision != row.revision {
            reason = "revision-changed"
        } else if current.status != row.status {
            reason = "status-changed"
        } else if current.backupPath != row.backupPath {
            reason = "backup-changed"
        } else {
            reason = nil
        }
        if let reason {
            throw GatherError(code: .XMP_EXTERNAL_EDIT_CONFLICT, underlying: reason)
        }
        let stillOrphan = try deliveryRepo.orphanDeliveries().contains { $0.id == row.id }
        guard stillOrphan else {
            throw GatherError(
                code: .XMP_EXTERNAL_EDIT_CONFLICT, underlying: "no-longer-orphan")
        }
    }

    // MARK: - 校验与错误映射

    private func listOrphans() throws -> [MetadataOrphan] {
        try deliveryRepo.orphanDeliveries().map { row in
            MetadataOrphan(
                xmpPath: row.xmpPath,
                photoPath: row.photoPath,
                status: row.status,
                revision: Int(row.revision),
                errorMessage: row.errorMessage,
                updatedAt: row.updatedAt
            )
        }
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.translate(error)
        }
    }

    private static func translate(_ error: Error) -> Error {
        switch error {
        case let gather as GatherError:
            return gather
        case let db as DBError:
            if case .message(let message) = db,
               let code = GatherErrorCode(rawValue: message) {
                return GatherError(code: code, underlying: message)
            }
            return db
        default:
            return error
        }
    }
}
