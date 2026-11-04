// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataDispositionService.swift
// 元数据冲突/孤儿处置（#2：从 LiveMetadataAPI 下沉到用例层）。
//
// 为什么搬：LiveMetadataAPI 里有 350+ 行业务（读盘 + 文件锁 + 交付状态迁移 + 投影），
// 适配器变成了用例层；core 测试因此覆盖不到「restore 前后双复核」「绝不翻 synced」
// 这类不变量。
//
// 边界（谁拥有不变量就归谁）：
// - 进服务：跨仓储读取、XMP 读盘、文件锁、状态迁移、投影计算、不变量守卫；
// - 留适配器：Confirmed<T> 解包、LiveAPIInput 校验、LiveAPIErrorMapping、DTO 组装；
// - 不进任何一侧：XMPProvider 的具体实现（宿主注入，类型是 GatherProtocol 的端口）。
//
// 锁语义（与 docs/delivery-lock-order.md 一致）：resolveOrphan 的
// 「复核 → 文件 → 事后复核」必须整体在一次 XMPFileLock.run 内；锁不可重入，
// 闭包内只读交付行 + 调 XMPProvider，不得开事务、不得再取同路径锁。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

public struct MetadataDispositionService: Sendable {
    private let deliveries: any MetadataDispositionReading
    private let writer: DeliveryStateWriter
    private let xmp: any XMPProvider
    /// 与 DeliveryCoordinator / WritebackService 共用的按 xmpPath 文件锁
    /// （组合根构造唯一实例并注入）：孤儿 restore/remove 与 cleanup/replay/writeback 串行。
    /// internal：组合根契约测试要断言与 coordinator/writeback 同一实例。
    let fileLock: XMPFileLock

    public init(
        deliveries: any MetadataDispositionReading,
        writer: DeliveryStateWriter,
        xmp: any XMPProvider,
        fileLock: XMPFileLock
    ) {
        self.deliveries = deliveries
        self.writer = writer
        self.xmp = xmp
        self.fileLock = fileLock
    }

    public func conflicts(_ sessionId: String) async throws -> [MetadataConflict] {
        var conflicts: [MetadataConflict] = []
        for delivery in try deliveries.conflictDeliveries(sessionId: sessionId) {
            let items = try deliveries.items(deliveryId: delivery.id)
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

    public func orphans() async throws -> [MetadataOrphan] {
        try listOrphans()
    }

    public func resolveConflict(
        _ input: Confirmed<MetadataResolveConflictInput>
    ) async throws -> MetadataSyncSummary {
        let payload = input.value
        let path = TSPath.normalize(payload.xmpPath)
        guard let delivery = try deliveries
            .conflictDeliveries(sessionId: payload.sessionId)
            .first(where: { $0.xmpPath == path }) else {
            throw GatherError(code: .XMP_CONFLICT_NOT_FOUND, underlying: path)
        }
        let items = try deliveries.items(deliveryId: delivery.id)
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
            // 执行器下一次写盘即覆盖为本地值。两步（merge + 逐项 pending）
            // 是 writer 的 reopenConflict 语义，顺序/失败点与原实现一致。
            try writer.reopenConflict(
                xmpPath: delivery.xmpPath,
                photoPath: delivery.photoPath,
                expectedRevision: delivery.revision,
                baseFingerprint: delivery.baseFingerprint,
                baseValues: delivery.baseValues,
                itemIds: items.map(\.id)
            )
        }
        return try deliveries.metadataSummary(sessionId: payload.sessionId, module: nil)
    }

    public func resolveOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        let payload = input.value
        let path = TSPath.normalize(payload.xmpPath)
        guard let row = try deliveries.orphanDeliveries()
            .first(where: { $0.xmpPath == path }) else {
            throw GatherError(code: .XMP_ORPHAN_NOT_FOUND, underlying: path)
        }
        // 孤儿行来自 DB，不能把 xmp/photo/backup_path 当可信路径直接传给文件端口：
        // 伪造一条无 link 的 deliveries 行即可删/覆盖任意文件。restore/remove 前
        // 统一做绝对路径、无 ..、无 NUL、非常规 symlink、backup 同目录/前缀校验。
        try validateOrphanPaths(row)
        if payload.action == .retry {
            switch row.typedStatus {
            case .some(.conflict):
                throw GatherError(code: .XMP_CONFLICT_RESOLUTION_REQUIRED, underlying: path)
            case .some(.pending), .some(.failed):
                // failed → pending 是合法迁移；pending 重新入队幂等（revision 推进）。
                // 孤儿没有会话关联，retry 只重排交付、不动 items（writer 语义）。
                try writer.retryOrphan(
                    xmpPath: row.xmpPath,
                    photoPath: row.photoPath,
                    expectedRevision: row.revision,
                    baseFingerprint: row.baseFingerprint,
                    baseValues: row.baseValues
                )
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
        guard try writer.deleteOrphanDelivery(
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

    /// 孤儿 restore/remove 的文件阶段（调用方必须已持有 fileLock.run(path:)）。
    ///
    /// 保留原入口的 A 守卫：restore/remove 前后各复核一次 revision/status/backup
    /// 且仍无会话关联；备份缺失显式失败（不删行）。锁只覆盖文件阶段——行删除仍由
    /// writer.deleteOrphanDelivery 的 revision + 无链接 CAS 兜底，避免在锁内跨 DB 事务。
    /// 孤儿入口的统一路径校验。只允许绝对、无 `..`/NUL、非符号链接的路径；
    /// backup_path 还必须通过 DeliveryBackupPath 的同目录/前缀/常规文件校验。
    private func validateOrphanPaths(_ row: DeliveryRow) throws {
        try requireSafeAbsolutePath(row.xmpPath, field: "xmpPath")
        if !row.photoPath.isEmpty {
            try requireSafeAbsolutePath(row.photoPath, field: "photoPath")
        }
        if !row.backupPath.isEmpty {
            do {
                _ = try DeliveryBackupPath.validate(
                    xmpPath: row.xmpPath, backupPath: row.backupPath)
            } catch {
                throw GatherError(
                    code: .XMP_BACKUP_FAILED,
                    underlying: String(describing: error))
            }
        }
    }

    private func requireSafeAbsolutePath(_ path: String, field: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GatherError(code: .XMP_BACKUP_FAILED, underlying: "invalid \(field): \(path)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw GatherError(code: .XMP_BACKUP_FAILED, underlying: "traversal \(field): \(path)")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            return // 不存在交给文件端口报 backupMissing/restore 失败，保持原语义。
        }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw GatherError(code: .XMP_BACKUP_FAILED, underlying: "symlink \(field): \(path)")
        }
    }

    private func restoreOrphanFile(_ row: DeliveryRow) async throws {
        if !row.backupPath.isEmpty {
            guard xmp.fileExists(row.backupPath) else {
                throw GatherError(code: .XMP_BACKUP_MISSING, underlying: row.backupPath)
            }
            try requireUnchangedOrphan(row)
            try await xmp.restore(photoPath: row.photoPath, backupPath: row.backupPath)
            try requireUnchangedOrphan(row)
        } else if xmp.fileExists(row.xmpPath) {
            // 内嵌交付的 xmpPath 就是照片自身：没有备份时绝不能删原片。
            guard row.xmpPath.lowercased().hasSuffix(".xmp") else {
                throw GatherError(code: .XMP_BACKUP_MISSING, underlying: row.xmpPath)
            }
            try requireUnchangedOrphan(row)
            try await xmp.removeFile(row.xmpPath)
            try requireUnchangedOrphan(row)
        }
    }

    /// 待裁决字段：从交付项派生（rating/label 在 attributes_json，keywords 在列里）。
    ///
    /// 一个 sidecar 可有多条项（RAW+JPEG 共享 sidecar、多个模块先后写入），同一字段出现
    /// 任意一次即视为本次冲突的待裁决字段；完全推导不出时退回三个可写字段
    /// （交付级冲突仍必须有裁决出口）。
    private static func dirtyFields(items: [DeliveryItemRow]) -> [MetadataField] {
        var hasRating = false
        var hasLabel = false
        var hasKeywords = false
        for item in items {
            let attributes = item.attributes
            // descriptive/triageSignal 是块级载荷，不参与字段级裁决（baseline/local/
            // remote 都是 null，给用户一个无法判断的"空/空"选项只会误导）。
            if attributes["descriptive"] != nil || attributes["triageSignal"] != nil { continue }
            if attributes["rating"] != nil { hasRating = true }
            if attributes["label"] != nil { hasLabel = true }
            // 只删词的 delta 项 keywordList（after）可能为空，仍必须参与冲突裁决。
            if !item.keywordList.isEmpty
                || attributes["keywords_mode"]?.stringValue == "delta" {
                hasKeywords = true
            }
        }
        var fields: [MetadataField] = []
        if hasRating { fields.append(.rating) }
        if hasLabel { fields.append(.label) }
        if hasKeywords { fields.append(.keywords) }
        return fields.isEmpty ? [.rating, .label, .keywords] : fields
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
        case .descriptive:
            // P1 / IPTC：描述性元数据未接入交付队列的冲突解析，按"无基线"处理。
            return .null
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
        case .descriptive:
            // 同上：描述性元数据按块写入，不参与字段级冲突裁决。
            return .null
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
        case .descriptive:
            return .null
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
            if fields.contains(.keywords) {
                // 接受远程 = 以盘上词表为新基线；必须同时移除 delta 意图，
                // 否则同一 item 重放时会按 keywords_added/remove 再合并一次，
                // 把用户刚接受的远程删除词“复活”。
                merged.removeValue(forKey: MetadataMutationService.keywordsModeKey)
                merged.removeValue(forKey: "keywords_added")
                merged.removeValue(forKey: "keywords_remove")
                keywordUpdates.append((item.id, remote.keywords ?? []))
            }
            if merged != item.attributes {
                attributeUpdates.append((item.id, merged))
            }
        }
        // 交付项投影的写也归 writer（先属性、后关键词；两次批量写的事务边界不变）。
        try writer.persistAcceptedRemoteFields(
            attributeUpdates: attributeUpdates,
            keywordUpdates: keywordUpdates)
    }

    /// 全部接受远程：以盘上内容为新基线，只推进到 written。
    ///
    /// P1-10：这里不得直接 synced。synced 表示“该交付的所有关联会话都已确认”，
    /// 只有 DeliveryRepo.confirm 在“全部 delivery_sessions.confirmed_at 非空”的
    /// 单事务里才能翻转；否则一个会话的裁决会把其它会话未确认的新内容当成已确认，
    /// 随后的 confirm 的 itemsSynced 子查询会把它们的 written item 一起翻 synced，
    /// cleanup 便能删掉未确认内容。backup_path 原样保留（cleanup 仍能恢复原 sidecar）。
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
        // 状态写整段交给 writer 的语义入口（P1-2）：writing → 清空全部关联会话
        // 确认 → written，顺序与失败语义见 DeliveryStateWriter.acceptExternalState。
        // P1-10 的旧确认必须在 writing → written 之间失效；这里绝不翻 synced
        // （synced 只能由 DeliveryRepo.confirm 的跨会话门禁翻转）。
        try writer.acceptExternalState(
            xmpPath: delivery.xmpPath,
            revision: delivery.revision,
            baseFingerprint: fingerprint,
            baseValues: remote.asJSONValue,
            backupPath: delivery.backupPath
        )
        // 刻意停在 written：等待所有关联会话各自 confirm（跨会话门禁）。
    }

    /// 复核孤儿交付自快照以来没有变化，且仍没有会话关联。
    ///
    /// 只读、同步：不做文件操作；不一致抛 XMP_EXTERNAL_EDIT_CONFLICT（错误可见，
    /// 不静默返回列表）。revision 推进说明旧备份已不对应盘上内容；链接出现说明
    /// 别的会话可能正在确认/清理，都不能替它回滚文件。
    private func requireUnchangedOrphan(_ row: DeliveryRow) throws {
        guard let current = try deliveries.deliveryRow(xmpPath: row.xmpPath) else {
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
        let stillOrphan = try deliveries.orphanDeliveries().contains { $0.id == row.id }
        guard stillOrphan else {
            throw GatherError(
                code: .XMP_EXTERNAL_EDIT_CONFLICT, underlying: "no-longer-orphan")
        }
    }

    private func listOrphans() throws -> [MetadataOrphan] {
        try deliveries.orphanDeliveries().map { row in
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

}
