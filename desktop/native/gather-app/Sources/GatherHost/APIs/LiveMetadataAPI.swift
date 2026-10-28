// desktop/native/gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift
// MetadataAPI 的 Live 实现（18 个方法：7 个历史命令面 + 只读详情 + 模板 8 个
// + triage 写回 2 个）。
//
// 对应命令（7 条历史）：metadata.conflicts / orphans / resolve_conflict /
// resolve_orphan，以及 K0 的 preview / apply_keywords / retry_keyword_writeback；
// P1 的 metadata/templates/triage 入口是类型化新增，没有历史命令。
//
// 依赖（2b-2 起不再持有 MetadataSyncCoordinator；P1-2 起写路径收口）：
// - metadataService：关键词预览/应用/重试（缓存指纹、可写字段白名单、侧车分组串行）；
// - deliveryRepo：**只读**查询（conflictDeliveries / items / orphanDeliveries /
//   get / metadataSummary），本文件不再调用它的任何写方法；
// - stateWriter：交付状态与交付项写入的唯一入口（acceptExternalState /
//   reopenConflict / retryOrphan / deleteOrphanDelivery /
//   persistAcceptedRemoteFields）；
// - xmp：冲突的 remote 值读取与孤儿 restore/remove 的文件阶段（旧协调器的同一
//   两个动作，收窄为只读属性 + 三文件操作）。
//
// 校验归属：
// - resolveConflict / resolveOrphan / applyKeywords / retryKeywordWriteback
//   的 choices 非空、未知字段、action 枚举在输入类型收敛（G5/G6）；本实现不
//   重复解析 JSON；
// - 只接收 sessionId 的 conflicts 在这里补"非空白 + 长度上限"校验（对齐
//   LiveAPIInput.requireSessionId），失败统一 GatherError.invalidParameter；
// - 破坏性入口只接收 Confirmed<T>（resolveConflict / resolveOrphan /
//   applyKeywords / retryKeywordWriteback），类型层面保证"没有确认弹窗就写不出
//   调用点"，实现不自行补确认、也不再解析 Bool（D-011）。
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
// 状态写归属（P1-2）：resolveConflict / resolveOrphan 的每一步状态迁移都经
// DeliveryStateWriter 的语义入口，本文件不再出现 mergeInput / markWriting /
// markWritten / markItem / resetConfirmations / deleteOrphanDelivery /
// updateItemAttributes / updateItemKeywords；单步迁移在 GatherDelivery 内仍是
// internal，Host 拼不出绕过 writer 的写序列。冲突裁决“绝不翻 synced”的结论仍由
// DeliveryRepo.confirm 的跨会话门禁保证（见上一条）。
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
    /// 只读查询入口（写路径见 stateWriter，P1-2）。
    private let deliveryRepo: DeliveryRepo
    /// 交付状态 / 交付项的写入唯一入口；与 deliveryRepo 同一连接。
    private let stateWriter: DeliveryStateWriter
    private let xmp: any XMPProvider
    /// 与 DeliveryCoordinator / WritebackService 共用的按 xmpPath 文件锁
    /// （组合根构造唯一实例并注入三者）：孤儿 restore/remove 与
    /// cleanup/replay/writeback 串行。
    /// internal（非 private）：组合根契约测试要断言与 coordinator/writeback 同一实例。
    let fileLock: XMPFileLock
    /// P1 / B2：模板与批次（settings 单键 JSON；进程内唯一实例）。
    private let templateStore: MetadataTemplateStore
    private let batchStore: MetadataApplyBatchStore
    private let templateService: MetadataTemplateService

    /// Sendable 由协议继承显式声明：类为 final，所有依赖都是构造后不再变更的
    /// Sendable let（Repo 只持连接、stateWriter 由 deliveryRepo 派生、
    /// XMPProvider 由宿主实现保证），故无需 @unchecked。
    public init(
        metadataService: MetadataService,
        deliveryRepo: DeliveryRepo,
        xmp: any XMPProvider,
        fileLock: XMPFileLock,
        settingsService: SettingsService
    ) {
        self.metadataService = metadataService
        self.deliveryRepo = deliveryRepo
        self.stateWriter = DeliveryStateWriter(repo: deliveryRepo)
        self.xmp = xmp
        self.fileLock = fileLock
        self.templateStore = MetadataTemplateStore(settings: settingsService)
        self.batchStore = MetadataApplyBatchStore(settings: settingsService)
        self.templateService = MetadataTemplateService(
            templates: templateStore,
            batches: batchStore,
            metadata: metadataService,
            xmp: xmp
        )
    }

    // MARK: - 读取

    /// P1 / IPTC：只读元数据详情（缓存投影，不触发磁盘解析）。
    public func metadata(_ photoId: String) async throws -> PhotoMetadataDetail {
        try map { try metadataService.photoDetail(photoId: photoId) }
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

    // MARK: - P1 / E：triage 写回

    public func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async throws -> TriageWritebackResult {
        let payload = input.value
        let service = TriageWritebackService(xmp: xmp, metadata: metadataService, batches: batchStore)
        let batchId = UUID().uuidString
        // 逐张从缓存投影取当前星级：缓存是 XMP 的全应用投影，无需再读盘。
        var decisions: [TriageWritebackDecision] = []
        for item in payload.items {
            // "只写空评级"必须以盘上为准：缓存可能落后于外部软件刚写的星级。
            // 读不到盘上星级时用非 0 哨兵跳过 rating：绝不能拿缓存/0 覆盖用户星级。
            var rating = 1
            do {
                let detail = try metadataService.photoDetail(photoId: item.photoId)
                do {
                    let disk = try await xmp.readAttributes(photoPath: detail.filepath)
                    rating = Int(disk.rating ?? 0)
                } catch {
                    rating = 1
                }
            } catch {
                rating = 1
            }
            if let decision = TriageWritebackPlanner.plan(
                photoId: item.photoId,
                verdict: item.verdict,
                currentRating: rating,
                manuallyDecided: item.manuallyDecided,
                policy: payload.policy
            ) {
                decisions.append(decision)
            }
        }
        let outcome = await service.apply(decisions, batchId: batchId, now: nowISOString())
        return TriageWritebackResult(
            batchId: batchId,
            written: outcome.written,
            skipped: outcome.skipped,
            failed: outcome.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) }
        )
    }

    public func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> TriageWritebackResult {
        let service = TriageWritebackService(xmp: xmp, metadata: metadataService, batches: batchStore)
        let outcome = try await service.undo(batchId: input.value.batchId)
        return TriageWritebackResult(
            batchId: input.value.batchId,
            written: outcome.written,
            skipped: outcome.skipped,
            failed: outcome.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) }
        )
    }

    // MARK: - P1 / B2：元数据模板

    public func templates() async throws -> [MetadataTemplateSummary] {
        try map {
            templateStore.list().map { summary($0) }
        }
    }

    public func saveTemplate(_ input: MetadataTemplateSaveInput) async throws -> MetadataTemplateSummary {
        try map {
            let id = input.id ?? UUID().uuidString
            let saved = try templateStore.save(
                MetadataTemplate(id: id, name: input.name, fields: input.fields,
                                 createdAt: "", updatedAt: ""),
                now: nowISOString()
            )
            return summary(saved)
        }
    }

    public func templateFields(id: String) async throws -> DescriptiveMetadata {
        try map {
            guard let template = templateStore.get(id: id) else {
                throw MetadataTemplateServiceError.templateNotFound(id)
            }
            return template.fields
        }
    }

    public func deleteTemplate(_ input: Confirmed<MetadataTemplateDeleteInput>) async throws {
        try map { try templateStore.delete(id: input.value.templateId) }
    }

    public func previewTemplate(_ input: MetadataTemplatePreviewInput) async throws -> MetadataTemplatePreviewResult {
        try await mapAsync {
            guard let template = templateStore.get(id: input.templateId) else {
                throw MetadataTemplateServiceError.templateNotFound(input.templateId)
            }
            var photos: [(photoId: String, current: DescriptiveMetadata, disk: DescriptiveMetadata?)] = []
            for photoId in input.photoIds {
                let detail = try metadataService.photoDetail(photoId: photoId)
                let disk = (try? await xmp.readAttributes(photoPath: detail.filepath))?.descriptive
                photos.append((photoId, detail.descriptive, disk))
            }
            let preview = MetadataTemplatePreviewBuilder.build(
                template: template, photos: photos, policy: input.policy
            )
            let photoPreviews = preview.impacts.map { impact in
                MetadataPhotoPreview(
                    photoId: impact.photoId,
                    writes: impact.fields.filter { $0.action == .write }.map { $0.field.rawValue },
                    clears: impact.fields.filter { $0.action == .clear }.map { $0.field.rawValue },
                    conflicts: impact.fields.filter { $0.action == .conflict }.map { $0.field.rawValue }
                )
            }
            return MetadataTemplatePreviewResult(
                templateId: preview.templateId,
                templateName: preview.templateName,
                totalPhotos: preview.totalPhotos,
                changedPhotos: preview.changedPhotos,
                changedFields: preview.changedFields,
                conflictFields: preview.conflictFields,
                photos: photoPreviews
            )
        }
    }

    public func applyTemplate(_ input: Confirmed<MetadataTemplateApplyInput>) async throws -> MetadataTemplateApplyOutcome {
        let payload = input.value
        let result = try await templateService.apply(
            templateId: payload.templateId,
            photoIds: payload.photoIds,
            policy: payload.policy,
            now: nowISOString()
        )
        return MetadataTemplateApplyOutcome(
            batchId: result.batchId,
            written: result.written,
            skipped: result.skipped,
            conflicts: result.conflicts,
            failed: result.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) }
        )
    }

    public func recentBatches(limit: Int) async throws -> [MetadataBatchSummary] {
        try map {
            batchStore.list().prefix(max(0, limit)).map { batch in
                MetadataBatchSummary(
                    batchId: batch.id,
                    kind: batch.templateId == TriageWritebackService.batchTemplateID
                        ? "triage" : "template",
                    name: batch.templateName,
                    appliedAt: batch.appliedAt,
                    undone: batch.undone,
                    photoCount: batch.snapshots.count
                )
            }
        }
    }

    public func undoTemplate(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> MetadataTemplateApplyOutcome {
        let result = try await templateService.undo(batchId: input.value.batchId)
        return MetadataTemplateApplyOutcome(
            batchId: result.batchId,
            written: result.written,
            skipped: result.skipped,
            conflicts: result.conflicts,
            failed: result.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) }
        )
    }

    private func summary(_ template: MetadataTemplate) -> MetadataTemplateSummary {
        MetadataTemplateSummary(
            id: template.id,
            name: template.name,
            fieldCount: template.fields.nonNilFieldCount,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt
        )
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
                // 执行器下一次写盘即覆盖为本地值。两步（merge + 逐项 pending）
                // 是 writer 的 reopenConflict 语义，顺序/失败点与原实现一致。
                try stateWriter.reopenConflict(
                    xmpPath: delivery.xmpPath,
                    photoPath: delivery.photoPath,
                    expectedRevision: delivery.revision,
                    baseFingerprint: delivery.baseFingerprint,
                    baseValues: delivery.baseValues,
                    itemIds: items.map(\.id)
                )
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
                    try stateWriter.retryOrphan(
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
            guard try stateWriter.deleteOrphanDelivery(
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
    /// stateWriter.deleteOrphanDelivery 的 revision + 无链接 CAS 兜底，避免在锁内跨 DB 事务。
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
        try stateWriter.persistAcceptedRemoteFields(
            attributeUpdates: attributeUpdates,
            keywordUpdates: keywordUpdates)
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
        // 状态写整段交给 writer 的语义入口（P1-2）：writing → 清空全部关联会话
        // 确认 → written，顺序与失败语义见 DeliveryStateWriter.acceptExternalState。
        // P1-10 的旧确认必须在 writing → written 之间失效；这里绝不翻 synced
        // （synced 只能由 DeliveryRepo.confirm 的跨会话门禁翻转）。
        try stateWriter.acceptExternalState(
            xmpPath: delivery.xmpPath,
            revision: delivery.revision,
            baseFingerprint: fingerprint,
            baseValues: remote.asJSONValue,
            backupPath: delivery.backupPath
        )
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

    // MARK: - K0 关键词

    public func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview {
        try await mapAsync {
            let conflicts: Set<String>
            if let sessionId = try metadataService.sessionId(forPhotoIds: input.photoIds) {
                conflicts = Set(
                    try deliveryRepo.conflictDeliveries(sessionId: sessionId).map(\.xmpPath))
            } else {
                conflicts = []
            }
            return try await metadataService.previewKeywords(
                photoIds: input.photoIds,
                added: input.addedKeywords,
                removed: input.removedKeywords,
                conflictedXmpPaths: conflicts
            )
        }
    }

    public func applyKeywords(
        _ input: Confirmed<MetadataKeywordApplyInput>
    ) async throws -> MetadataKeywordApplyResult {
        let payload = input.value
        return try await mapAsync {
            let result = try await metadataService.applyKeywordDelta(
                photoIds: payload.photoIds,
                added: payload.addedKeywords,
                removed: payload.removedKeywords
            )
            guard let sessionId = try metadataService.sessionId(forPhotoIds: payload.photoIds) else {
                throw GatherError.invalidParameter(field: "photoIds", reason: "photos not found")
            }
            let status = try deliveryRepo.metadataSummary(sessionId: sessionId, module: .metadata)
            return MetadataKeywordApplyResult(result: result, status: status)
        }
    }

    public func retryKeywordWriteback(
        _ input: Confirmed<SessionReference>
    ) async throws -> MetadataKeywordApplyResult {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            let result = try await metadataService.retryKeywordWriteback(sessionId: sessionId)
            let status = try deliveryRepo.metadataSummary(sessionId: sessionId, module: .metadata)
            return MetadataKeywordApplyResult(result: result, status: status)
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
            throw LiveAPIErrorMapping.translateCommon(error) ?? error
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw LiveAPIErrorMapping.translateCommon(error) ?? error
        }
    }
}
