// desktop/native/gather-core/Sources/GatherCore/Services/WritebackService.swift
// TS 源: desktop/src/main/services/writeback/writeback.service.ts（630 行）+ 
// writeback-planners.ts（66 行），逐字移植
//
// 写回服务：preview/execute/retryFailed/confirmSync/cleanup 全量语义对齐
// writeback.ipc.ts 形状（culling.writeback / culling.retry_failed_writeback /
// culling.confirm_sync / culling.cleanup 均经本服务）。
// 状态机（writeback_items.xmp_status）：pending → written → synced →（cleanup
// 删除）；失败路径 failed；outbox 是单写回状态机，跨模块互斥门控。
//
// 注入点：
// - XMPProvider = TS writerRouter.selectSidecar()（XMP 读写，host 实现）。
// - MetadataSyncPort = TS Pick<MetadataSyncCoordinator, ...>（waitForIdle /
//   flushSession / confirmSync / cleanup）—— 3.4 CullingService 与测试可注入替身。
// - MetadataMutationPort = TS MetadataMutationService（queuePhotoValues）。
// - C1 相关：本服务不直接触碰 Capture One（reload-ack 由宿主 C1BridgeProvider
//   的 recordReloadAck 写入，coordinator 的 requireReloadAck 读 sessions 表）。

import Foundation

/// TS: writeback.service.ts 抛出的错误码。
public enum WritebackServiceError: Error, Equatable, CustomStringConvertible {
    case otherModuleActive // WRITEBACK_OTHER_MODULE_ACTIVE
    case failuresPending // WRITEBACK_FAILURES_PENDING
    case undoFaceFailed // WRITEBACK_UNDO_FACE_FAILED
    /// TS: `result?.errorMessage || 'WRITEBACK_UNDO_FACE_FAILED'`（撤销失败的
    /// 具体原因优先，缺失时回退常量码）。
    case undoFaceFailedWithMessage(String)
    case cleanupRequiresLoaded // XMP_CLEANUP_REQUIRES_LOADED（writeback 侧守卫）

    public var description: String {
        switch self {
        case .otherModuleActive: "WRITEBACK_OTHER_MODULE_ACTIVE"
        case .failuresPending: "WRITEBACK_FAILURES_PENDING"
        case .undoFaceFailed: "WRITEBACK_UNDO_FACE_FAILED"
        case .undoFaceFailedWithMessage(let message):
            message.isEmpty ? "WRITEBACK_UNDO_FACE_FAILED" : message
        case .cleanupRequiresLoaded: "XMP_CLEANUP_REQUIRES_LOADED"
        }
    }
}

/// TS: mutationSource —— writeback module 名 → outbox 的 mutation-source 名。
public func mutationSource(_ module: String) -> MetadataMutationSource {
    switch module {
    case "face_kw": .faceKeyword
    case "similarity": .similarity
    case "template": .template
    case "culling": .culling
    default: .manual
    }
}

/// TS: WritebackService。
public final class WritebackService {
    private let writebackStore: any WritebackStore
    private let xmp: any XMPProvider
    private let photoStore: any PhotoStore
    private let sessionRepo: SessionRepo
    private let metadataSync: any MetadataSyncPort
    private let metadataMutations: any MetadataMutationPort
    /// metadata_keyword_origins 的唯一入口（Store；nil 时不记录/不撤销来源）。
    private let metadataStore: (any MetadataStore)?
    private let assetResolver: PhotoAssetResolver?

    public init(
        writebackStore: any WritebackStore,
        xmp: any XMPProvider,
        photoStore: any PhotoStore,
        sessionRepo: SessionRepo,
        metadataSync: any MetadataSyncPort,
        metadataMutations: any MetadataMutationPort,
        metadataStore: (any MetadataStore)? = nil,
        assetResolver: PhotoAssetResolver? = nil
    ) {
        self.writebackStore = writebackStore
        self.xmp = xmp
        self.photoStore = photoStore
        self.sessionRepo = sessionRepo
        self.metadataSync = metadataSync
        self.metadataMutations = metadataMutations
        self.metadataStore = metadataStore
        self.assetResolver = assetResolver
    }

    // MARK: - 私有支撑

    /// TS: assertNoActiveOtherModule —— outbox 是单写回状态机：另一模块的
    /// written/synced 工作必须先确认并清理。outbox 行按 mutation-source 名存储，
    /// 与写入时的同一映射比较。
    private func assertNoActiveOtherModule(sessionId: String, module: String) async throws {
        if try await writebackStore.hasActiveOtherModule(
            sessionId: sessionId, module: mutationSource(module).rawValue) {
            throw WritebackServiceError.otherModuleActive
        }
        // 未注入 outbox 仓库的调用方遗留兜底：镜像 outbox 门控——交互式 culling
        // 同步是连续的，绝不阻塞批量写回，故 culling 行在此同样排除（outbox 侧
        // 检查已排除）。
        let activeOtherModule = try await writebackStore.writebackItems(sessionId: sessionId, module: nil, status: nil).first { item in
            item.module != module
                && item.module != "culling"
                && (item.xmpStatus == "written" || item.xmpStatus == "synced")
        }
        if activeOtherModule != nil {
            throw WritebackServiceError.otherModuleActive
        }
    }

    /// TS: resolveExecuteXmpPath —— execute 时 outbox 实际键控的侧车路径。
    /// queuePhotoValues 内部会重新解析照片，资产迁移在 preview 与 execute 之间
    /// 完成后此路径与 preview 快照（dbRow.xmpPath）不同——分组与等待必须用同一
    /// 实时路径，否则落在同一侧车的并发项互相竞态。
    private func resolveExecuteXmpPath(
        sessionId: String,
        dbRow: WritebackItemRecord,
        resolvedByPhoto: [String: String]? = nil
    ) -> String {
        if let assetResolver {
            if let resolvedByPhoto, let xmpPath = resolvedByPhoto[dbRow.photoId], !xmpPath.isEmpty {
                return xmpPath
            } else if resolvedByPhoto == nil {
                // 解析失败回退存储的 preview 路径。
                if let xmpPath = try? assetResolver.resolve(sessionId: sessionId, photoId: dbRow.photoId).xmpPath {
                    return xmpPath
                }
            }
        }
        return dbRow.xmpPath
    }

    /// TS: preloadResolvedXmpPaths —— 整批一次 resolveMany（单 IN 查询替代逐项
    /// 5 路 JOIN）；解析器服务不到的照片缺席，回退存储路径。
    private func preloadResolvedXmpPaths(
        sessionId: String,
        rows: [WritebackItemRecord]
    ) throws -> [String: String]? {
        guard let assetResolver else { return nil }
        let resolved = try assetResolver.resolveMany(
            sessionId: sessionId,
            photoIds: Array(Set(rows.map(\.photoId)))
        )
        var map: [String: String] = [:]
        for (photoId, asset) in resolved {
            map[photoId] = asset.xmpPath
        }
        return map
    }

    /// TS: resolvePreviewTargets —— preview 时逐会话一次 resolveMany 批量查询；
    /// 解析器服务不到的项按遗留 filepath/sidecar 兜底；无 resolveMany 时逐项
    /// resolve（保持旧的精确语义）。
    private func resolvePreviewTargets(
        sessionId: String,
        photos: [(id: String, filepath: String)]
    ) throws -> [String: (filepath: String, xmpPath: String)] {
        func fallback(_ photo: (id: String, filepath: String)) -> (filepath: String, xmpPath: String) {
            (photo.filepath, TSPath.xmpSidecarPath(photo.filepath))
        }
        var byPhoto: [String: (filepath: String, xmpPath: String)] = [:]
        if let assetResolver {
            let resolved = try assetResolver.resolveMany(sessionId: sessionId, photoIds: photos.map(\.id))
            for photo in photos {
                if let asset = resolved[photo.id] {
                    byPhoto[photo.id] = (asset.filepath, asset.xmpPath)
                } else {
                    byPhoto[photo.id] = fallback(photo)
                }
            }
            return byPhoto
        }
        for photo in photos {
            if let assetResolver, let asset = try? assetResolver.resolve(sessionId: sessionId, photoId: photo.id) {
                byPhoto[photo.id] = (asset.filepath, asset.xmpPath)
            } else {
                byPhoto[photo.id] = fallback(photo)
            }
        }
        return byPhoto
    }

    // MARK: - 公开 API（对齐 writeback.ipc.ts 形状）

    /// TS: preview —— 重建 writeback_items；module != culling 时先丢弃本模块
    /// 陈旧的 pending/failed outbox 行（否则下次 execute 经 mergePatch 把旧
    /// 关键词并进新 patch）。
    public func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions = WritebackOptions(),
        photoIds: Set<String>? = nil,
        keywordAdditions: [String: [String]]? = nil
    ) async throws -> WritebackPreview {
        try await assertNoActiveOtherModule(sessionId: sessionId, module: module)

        // culling 是连续同步模块：其 pending outbox 行可能携带用户交互式的
        // rating/label 编辑，与关键词 preview 无关——删除它们会静默丢失工作。
        if module != "culling" {
            try? await writebackStore.discardModulePending(sessionId: sessionId, sourceModule: mutationSource(module).rawValue)
        }

        // 轻投影：preview 只需要照片身份与 filepath，重 JSON 列从不读取。
        let photos = try await photoStore.getBySessionProjection(sessionId: sessionId)
        let filtered = photoIds.map { ids in photos.filter { ids.contains($0.id) } } ?? photos

        // 与 execute 完全相同的资产解析：asset_read_mode='asset' 且 relink 后，
        // 照片行的遗留 filepath/sidecar 与 PhotoAssetResolver.resolve() 返回不同，
        // preview/execute 不一致会让每个项永久失败。
        let resolvedByPhoto = try resolvePreviewTargets(
            sessionId: sessionId,
            photos: filtered.map { (id: $0.id, filepath: $0.filepath) }
        )
        var additionsBySidecar: [String: [String]] = [:]
        var sharedCounts: [String: Int] = [:]
        for photo in filtered {
            let sidecarPath = resolvedByPhoto[photo.id]?.xmpPath ?? ""
            sharedCounts[sidecarPath, default: 0] += 1
            additionsBySidecar[sidecarPath] = orderedUnion(
                additionsBySidecar[sidecarPath] ?? [],
                keywordAdditions?[photo.id] ?? []
            )
        }

        var items: [WritebackItemInput] = []
        var previewsBySidecar: [String: WritebackItemPreview] = [:]
        // 按侧车去重（首见照片保留，与 TS uniquePhotos 一致），逐张读现有关键词
        // （corrupt/missing 视为空）。顺序跟随 filtered 输入序。
        var seenSidecars = Set<String>()
        for photo in filtered {
            let sidecarPath = resolvedByPhoto[photo.id]?.xmpPath ?? ""
            if !seenSidecars.insert(sidecarPath).inserted { continue }
            var existingKeywords: [String] = []
            if let read = try? await xmp.readKeywords(photoPath: photo.filepath) {
                existingKeywords = read
            }
            let merged = orderedUnion(existingKeywords, additionsBySidecar[sidecarPath] ?? [])
            // outbox 冲突状态在进入预览构造前解析（Store 读为 async）。
            let externalChanged = (try? await writebackStore.outboxEntry(xmpPath: sidecarPath))
                .map { $0.status == "conflict" } ?? false
            let preview = WritebackItemPreview(
                dirtyFields: [.keywords],
                before: WritebackAttributes(keywords: existingKeywords),
                after: WritebackAttributes(keywords: merged),
                source: module,
                sharedPhotoCount: sharedCounts[sidecarPath] ?? 1,
                externalChanged: externalChanged,
                willCreate: !xmp.fileExists(sidecarPath)
            )
            previewsBySidecar[sidecarPath] = preview
            items.append(WritebackItemInput(
                photoId: photo.id,
                photoPath: photo.filepath,
                module: module,
                keywords: merged,
                xmpPath: sidecarPath,
                backupPath: ""
            ))
        }

        try await writebackStore.saveWritebackItems(sessionId: sessionId, module: module, items: items)
        let failedCount = try await writebackStore.failedWritebackCount(sessionId: sessionId, module: module)
        try sessionRepo.updateFailedWritebackCount(id: sessionId, count: failedCount)
        try sessionRepo.updateWritebackStatus(id: sessionId, status: failedCount > 0 ? "partial" : "idle")
        let savedRows = try await writebackStore.writebackItems(sessionId: sessionId, module: module, status: "pending")

        let previewItems = try savedRows.map { row -> WritebackItem in
            var item = try rowToItem(row)
            item.preview = previewsBySidecar[item.xmpPath]
            return item
        }
        return WritebackPreview(
            items: previewItems,
            totalCount: savedRows.count,
            affectedPhotos: filtered.count
        )
    }

    /// TS: execute —— 两阶段：先全部 prepare（合并关键词、入队变更）再一次性
    /// flushSession（旧实现逐项 flush 会把整个会话队列重写 O(items) 次）。
    public func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult {
        try await assertNoActiveOtherModule(sessionId: sessionId, module: module)
        var written = 0
        var failed = 0
        var skipped = 0
        var errors: [String] = []
        var failedItems: [WritebackItem] = []
        let persistedRows = try await writebackStore.writebackItems(sessionId: sessionId, module: module, status: nil)
        let rowById = Dictionary(uniqueKeysWithValues: persistedRows.map { (Int($0.id), $0) })
        let resolvedXmpByPhoto = try preloadResolvedXmpPaths(sessionId: sessionId, rows: persistedRows)

        // Phase 1：prepare（合并关键词 + 变更入队），任何 flush 之前完成。
        var prepared: [PreparedEntry] = []
        // 共享同一侧车的项（RAW+JPEG 对）必须保持原始顺序：每项都对着前一项
        // 写入的 outbox 行重新合并，按侧车串行使该过程确定。分组按 execute 时
        // 解析的路径而非 preview 快照：资产迁移可让不同 preview 组的项落进同一
        // 侧车——并行 mergePatch 会竞态且一项的关键词可能被静默丢弃。
        var groups: [String: [WritebackItem]] = [:]
        for item in items {
            guard let itemId = item.id else {
                skipped += 1
                continue
            }
            guard let dbRow = rowById[itemId],
                  dbRow.sessionId == sessionId,
                  dbRow.module == module else {
                skipped += 1
                continue
            }
            guard dbRow.xmpStatus == "pending" || dbRow.xmpStatus == "failed" else {
                skipped += 1
                continue
            }
            let groupKey = resolveExecuteXmpPath(sessionId: sessionId, dbRow: dbRow, resolvedByPhoto: resolvedXmpByPhoto)
            groups[groupKey, default: []].append(item)
        }

        try await batchAsync(groups.map { ($0.key, $0.value) }, concurrency: 4) { group in
            for item in group.1 {
                guard let itemId = item.id, let dbRow = rowById[itemId] else { continue }

                var photoPath = dbRow.photoPath
                if photoPath.isEmpty, !dbRow.xmpPath.isEmpty {
                    // TS: dbRow.xmp_path.replace(/\.xmp$/i, '')
                    var xmpPath = dbRow.xmpPath
                    if xmpPath.lowercased().hasSuffix(".xmp") { xmpPath = String(xmpPath.dropLast(4)) }
                    photoPath = xmpPath
                }
                guard !photoPath.isEmpty else {
                    let message = "Missing photo path for writeback item"
                    try await self.writebackStore.updateWritebackStatus(itemId: Int64(itemId), status: "failed", error: message)
                    errors.append("\(itemId): \(message)")
                    var failedItem = item
                    failedItem.photoPath = ""
                    failedItems.append(failedItem)
                    failed += 1
                    continue
                }
                let persistedItem = try self.rowToItem(dbRow)

                do {
                    // outbox 行（与协调器的在飞写入）按解析后的路径键控，等待同一键。
                    try await self.metadataSync.waitForIdle(xmpPath: group.0, timeoutMs: MetadataSyncCoordinator.defaultWaitTimeoutMs)
                    let keywordsBeforeWrite = try await self.xmp.readKeywords(photoPath: photoPath)
                    // 对当前文件状态重新合并，而不是信任 preview 快照：外部软件可能
                    // 在 preview 与 execute 之间加了关键词，写陈旧列表会静默丢弃那些改动。
                    let writeKeywords = orderedUnion(keywordsBeforeWrite, persistedItem.keywords)
                    // attributes.keywords（如 culling 写回计划）也必须合并，否则下方
                    // 展开会覆盖合并列表、绕过该保护。
                    let mergedKeywords = orderedUnion(
                        writeKeywords,
                        persistedItem.attributes?.keywords ?? []
                    )
                    // TS: attributes ? { ...attributes, keywords: mergedKeywords } : { keywords: writeKeywords }
                    var writeAttrs: [String: JSONValue] = ["keywords": .array(
                        (persistedItem.attributes != nil ? mergedKeywords : writeKeywords).map { .string($0) }
                    )]
                    if let attributes = persistedItem.attributes {
                        if let rating = attributes.rating { writeAttrs["rating"] = .number(rating) }
                        if let label = attributes.label { writeAttrs["label"] = .string(label) }
                    }
                    _ = try await self.metadataMutations.queuePhotoValues(
                        sessionId: sessionId,
                        photoId: dbRow.photoId,
                        values: writeAttrs,
                        source: mutationSource(module),
                        schedule: false
                    )
                    prepared.append(PreparedEntry(
                        itemId: Int64(itemId),
                        dbRow: dbRow,
                        persistedItem: persistedItem,
                        photoPath: photoPath,
                        writeAttrs: writeAttrs,
                        keywordsBeforeWrite: keywordsBeforeWrite
                    ))
                } catch {
                    let message = String(describing: error)
                    try await self.writebackStore.updateWritebackStatus(itemId: Int64(itemId), status: "failed", error: message)
                    errors.append("\(photoPath): \(message)")
                    failedItems.append(persistedItem)
                    failed += 1
                }
            }
        }

        // Phase 2：整会话队列一次 flush，然后逐项对照 summary 核验。
        var summary: MetadataSyncSummary? = nil
        if !prepared.isEmpty {
            do {
                summary = try await metadataSync.flushSession(sessionId: sessionId)
            } catch {
                let message = String(describing: error)
                for entry in prepared {
                    try await writebackStore.updateWritebackStatus(itemId: entry.itemId, status: "failed", error: message)
                    errors.append("\(entry.photoPath): \(message)")
                    failedItems.append(entry.persistedItem)
                    failed += 1
                }
                summary = nil
            }
        }
        if let summary {
            // summary 按 xmp_path 索引一次而非逐项扫描；重复时首个获胜（对齐 find()）。
            var summaryByPath: [String: MetadataSyncItem] = [:]
            for candidate in summary.items where summaryByPath[candidate.xmpPath] == nil {
                summaryByPath[candidate.xmpPath] = candidate
            }
            for entry in prepared {
                // outbox 按 execute 时解析的 xmp 路径键控变更；资产迁移在
                // preview 与 execute 之间完成后该路径与 preview 快照不同——按
                // 实时解析匹配，已落盘的项不得误报失败。
                let resolvedXmpPath = resolveExecuteXmpPath(sessionId: sessionId, dbRow: entry.dbRow, resolvedByPhoto: resolvedXmpByPhoto)
                let syncItem = summaryByPath[entry.dbRow.xmpPath] ?? summaryByPath[resolvedXmpPath]
                if let syncItem, syncItem.status == .written || syncItem.status == .synced {
                    try await writebackStore.updateWritebackStatus(itemId: entry.itemId, status: "written", error: nil)
                    let attrs = entry.writeAttrs
                    if let rating = attrs["rating"]?.numberValue {
                        try? await metadataStore?.updateRating(photoId: entry.dbRow.photoId, rating: Int64(rating))
                    }
                    if let label = attrs["label"]?.stringValue {
                        try? await metadataStore?.updateLabel(photoId: entry.dbRow.photoId, label: label)
                    }
                    if let keywords = attrs["keywords"]?.arrayElements?.compactMap({ $0.stringValue }) {
                        try? await metadataStore?.updateKeywords(photoId: entry.dbRow.photoId, keywords: keywords)
                        if module == "face_kw" {
                            // keywordsBeforeWrite 是 phase 1 的写前快照：写入前
                            // 不在文件上的关键词即本模块引入的。
                            let existing = Set(entry.keywordsBeforeWrite)
                            let introduced = keywords.filter { !existing.contains($0) }
                            try? await metadataStore?.markKeywordIntroduced(
                                xmpPath: entry.dbRow.xmpPath,
                                source: "face-keyword",
                                keywords: introduced
                            )
                        }
                    }
                    written += 1
                } else {
                    let message = syncItem?.errorMessage.isEmpty == false
                        ? syncItem!.errorMessage
                        : "XMP write ended in \(syncItem?.status.rawValue ?? "unknown") state"
                    try await writebackStore.updateWritebackStatus(itemId: entry.itemId, status: "failed", error: message)
                    errors.append("\(entry.photoPath): \(message)")
                    failedItems.append(entry.persistedItem)
                    failed += 1
                }
            }
        }

        let failedCount = try await writebackStore.failedWritebackCount(sessionId: sessionId, module: module)
        try sessionRepo.updateWritebackStatus(id: sessionId, status: failedCount > 0 ? "partial" : "done")
        try sessionRepo.updateFailedWritebackCount(id: sessionId, count: failedCount)

        return WritebackResult(
            totalAffected: written + failed + skipped,
            written: written,
            failed: failed,
            skipped: skipped,
            errors: errors,
            failedItems: failedItems,
            report: "Written: \(written), Failed: \(failed), Skipped: \(skipped)"
        )
    }

    /// TS: removeOwnedFaceKeywords —— 撤销本模块引入的人脸关键词（按 origin 表
    /// 过滤后再移除，避免误删外部软件写入的关键词）；返回实际移除的关键词列表
    /// （TS removedKeywords 语义；无 origin 表注入时返回空数组）。
    public func removeOwnedFaceKeywords(
        sessionId: String,
        entries: [(photoId: String, xmpPath: String, keywords: [String])]
    ) async throws -> [String] {
        guard let metadataStore else { return [] }
        var byPath: [String: (photoId: String, keywords: Set<String>)] = [:]
        for entry in entries {
            var current = byPath[entry.xmpPath] ?? (photoId: entry.photoId, keywords: Set<String>())
            for keyword in entry.keywords { current.keywords.insert(keyword) }
            byPath[entry.xmpPath] = current
        }
        var queued: [(xmpPath: String, keywords: [String])] = []
        for (xmpPath, entry) in byPath {
            let owned = try await metadataStore.activeIntroducedKeywords(
                xmpPath: xmpPath,
                source: "face-keyword",
                keywords: Array(entry.keywords)
            )
            if owned.isEmpty { continue }
            _ = try await metadataMutations.queueMutation(
                sessionId: sessionId,
                photoId: entry.photoId,
                patch: MetadataPatch(keywords: MetadataKeywordsPatch(op: .remove, values: owned)),
                source: .faceKeyword
            )
            queued.append((xmpPath, owned))
        }
        if queued.isEmpty { return [] }
        let summary = try await metadataSync.flushSession(sessionId: sessionId)
        var removed: [String] = []
        for item in queued {
            let result = summary.items.first { $0.xmpPath == item.xmpPath }
            if let result, result.status == .written || result.status == .synced {
                try await metadataStore.deactivateKeywordOrigins(xmpPath: item.xmpPath, source: "face-keyword", keywords: item.keywords)
                removed.append(contentsOf: item.keywords)
            } else {
                let message = result?.errorMessage.isEmpty == false ? result!.errorMessage : ""
                throw WritebackServiceError.undoFaceFailedWithMessage(message)
            }
        }
        return removed
    }

    /// TS: retryFailed。
    public func retryFailed(sessionId: String, module: String) async throws -> WritebackResult {
        let failedRows = try await writebackStore.writebackItems(sessionId: sessionId, module: module, status: "failed")
        let items = try failedRows.map { try rowToItem($0) }
        if items.isEmpty {
            return WritebackResult(
                totalAffected: 0, written: 0, failed: 0, skipped: 0,
                errors: [], failedItems: [],
                report: "No failed items to retry"
            )
        }
        return try await execute(sessionId: sessionId, module: module, items: items)
    }

    /// TS: confirmSync —— 失败项存在时拒绝；outbox 确认使用映射后的
    /// mutation-source 名（否则 face_kw 行永远到不了 synced，之后的每次清理
    /// 与其它模块的写回都会被永久阻塞）。
    public func confirmSync(sessionId: String, module: String) async throws {
        if try await writebackStore.failedWritebackCount(sessionId: sessionId, module: module) > 0 {
            throw WritebackServiceError.failuresPending
        }
        _ = try await metadataSync.confirmSync(sessionId: sessionId, sourceModule: mutationSource(module).rawValue)
        try await writebackStore.markWritebackWrittenAsSynced(sessionId: sessionId, module: module)
        try sessionRepo.updateWritebackStatus(
            id: sessionId,
            status: try await writebackStore.failedWritebackCount(sessionId: sessionId, module: nil) > 0
                ? "partial" : "done"
        )
    }

    /// TS: persistAttributes / persistKeywords。
    public func persistAttributes(items: [WritebackItem]) async throws {
        let entries = items.compactMap { item -> (id: Int64, attributes: [String: JSONValue])? in
            guard let id = item.id, let attributes = item.attributes else { return nil }
            var dict: [String: JSONValue] = [:]
            if let keywords = attributes.keywords { dict["keywords"] = .array(keywords.map { .string($0) }) }
            if let rating = attributes.rating { dict["rating"] = .number(rating) }
            if let label = attributes.label { dict["label"] = .string(label) }
            return (Int64(id), dict)
        }
        try await writebackStore.updateWritebackAttributes(entries.map {
            WritebackAttributesUpdate(id: $0.id, attributes: $0.attributes)
        })
    }

    public func persistKeywords(items: [WritebackItem]) async throws {
        let entries = items.compactMap { item -> (id: Int64, keywords: [String])? in
            guard let id = item.id else { return nil }
            return (Int64(id), item.keywords)
        }
        try await writebackStore.updateWritebackKeywords(entries.map {
            WritebackKeywordsUpdate(id: $0.id, keywords: $0.keywords)
        })
    }

    public func getItems(sessionId: String, module: String, status: String? = nil) async throws -> [WritebackItem] {
        try await writebackStore.writebackItems(sessionId: sessionId, module: module, status: status).map { try rowToItem($0) }
    }

    /// TS: cleanup —— 只删除已确认的 synced 行：confirm 后的重新 preview 会
    /// 创建新一轮 pending 行（其 outbox 项仍在存活）——在这里清掉会让后台协调器
    /// 以无 UI 记录的方式把未确认关键词写进 XMP。
    public func cleanup(sessionId: String, module: String) async throws -> CleanupResult {
        let allItems = try await writebackStore.writebackItems(sessionId: sessionId, module: module, status: nil)
        let syncedItems = allItems.filter { $0.xmpStatus == "synced" }
        if syncedItems.isEmpty && !allItems.isEmpty {
            throw WritebackServiceError.cleanupRequiresLoaded
        }
        let result = try await metadataSync.cleanup(sessionId: sessionId, sourceModule: mutationSource(module).rawValue)
        if !result.errors.isEmpty { return result }
        try await writebackStore.deleteWritebackItems(
            sessionId: sessionId,
            module: module,
            ids: syncedItems.map(\.id)
        )
        let remainingItems = try await writebackStore.writebackItems(sessionId: sessionId, module: nil, status: nil)
        try sessionRepo.updateWritebackStatus(
            id: sessionId,
            status: remainingItems.isEmpty
                ? "cleaned"
                : remainingItems.contains(where: { $0.xmpStatus == "failed" }) ? "partial" : "done"
        )
        return result
    }

    // MARK: - 行映射

    /// TS: rowToItem。
    private func rowToItem(_ row: WritebackItemRecord) throws -> WritebackItem {
        var attributes: WritebackAttributes? = nil
        if !row.attributesJson.isEmpty {
            if let parsed = try? JSONValue.parse(row.attributesJson), case .object(let dict) = parsed {
                attributes = WritebackAttributes(
                    keywords: dict["keywords"]?.arrayElements?.compactMap { $0.stringValue },
                    rating: dict["rating"]?.numberValue,
                    label: dict["label"]?.stringValue
                )
            }
        }
        return WritebackItem(
            id: Int(row.id),
            photoId: row.photoId,
            photoPath: row.photoPath,
            sessionId: row.sessionId,
            module: row.module,
            keywords: parseKeywords(row.keywords),
            attributes: attributes,
            xmpPath: row.xmpPath,
            backupPath: row.backupPath,
            xmpStatus: row.xmpStatus,
            errorMessage: row.errorMessage,
            attemptCount: row.attemptCount,
            lastAttemptAt: row.lastAttemptAt
        )
    }
}

/// Phase 1 的 prepare 结果（TS 内联对象）。
private struct PreparedEntry {
    let itemId: Int64
    let dbRow: WritebackItemRecord
    let persistedItem: WritebackItem
    let photoPath: String
    let writeAttrs: [String: JSONValue]
    let keywordsBeforeWrite: [String]
}

/// TS: parseKeywords（utils/async.ts）。
private func parseKeywords(_ raw: String) -> [String] {
    if raw.isEmpty || raw == "[]" { return [] }
    guard let parsed = try? JSONValue.parse(raw), case .array(let items) = parsed else { return [] }
    return items.compactMap { $0.stringValue }
}

/// TS: `[...new Set([...a, ...b])]`（保序去重合并）。
private func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in a + b where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

/// [String: JSONValue] → [String: Any]（WritebackRepo.updateAttributesMany 入参）。
private func jsonObject(_ dict: [String: JSONValue]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in dict {
        result[key] = jsonScalar(value)
    }
    return result
}

private func jsonScalar(_ value: JSONValue) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let v): return v
    case .number(let v): return v
    case .string(let v): return v
    case .array(let items): return items.map { jsonScalar($0) }
    case .object(let dict): return jsonObject(dict)
    }
}

/// TS: batchAsync（utils/async.ts）—— 与 coordinator / metadata.service 同款滑动窗口。
private func batchAsync<T, R>(
    _ items: [T],
    concurrency: Int,
    body: @escaping (T) async throws -> R
) async throws -> [R] {
    let limit = max(1, concurrency)
    guard !items.isEmpty else { return [] }
    let cursor = WritebackBatchCursor(count: items.count)
    var collected: [(index: Int, value: R)] = []
    try await withThrowingTaskGroup(of: [(Int, R)].self) { group in
        for _ in 0..<min(limit, items.count) {
            group.addTask {
                var local: [(Int, R)] = []
                while !Task.isCancelled, let index = cursor.nextIndex() {
                    do {
                        local.append((index, try await body(items[index])))
                    } catch {
                        cursor.markFailed()
                        throw error
                    }
                }
                return local
            }
        }
        for try await chunk in group {
            collected.append(contentsOf: chunk)
        }
    }
    collected.sort { $0.index < $1.index }
    return collected.map(\.value)
}

private final class WritebackBatchCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var failed = false
    private let count: Int

    init(count: Int) { self.count = count }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if failed || next >= count { return nil }
        defer { next += 1 }
        return next
    }

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}

// ────────────────────────────────────────────────────────────
// writeback-planners.ts（writeback-planners.ts 全量）
// ────────────────────────────────────────────────────────────

/// TS: buildCullingWritebackPlan —— culling 决策 → XMP 属性计划。
public func buildCullingWritebackPlan(
    decisions: [(photoId: String, decision: String)],
    target: CullingWritebackTarget
) -> [String: WritebackAttributes] {
    var plan: [String: WritebackAttributes] = [:]
    for item in decisions {
        if item.decision == "pending" { continue }
        switch target {
        case .rating:
            plan[item.photoId] = WritebackAttributes(rating: item.decision == "keep" ? 5 : 1)
        case .colorLabel:
            plan[item.photoId] = WritebackAttributes(label: item.decision == "keep" ? "Green" : "Red")
        case .keyword:
            plan[item.photoId] = WritebackAttributes(keywords: ["culling:\(item.decision)"])
        }
    }
    return plan
}

/// TS: buildSimilarityKeywordPlan —— 相似度分组关键词 → 按侧车聚合 + 受影响路径集。
public func buildSimilarityKeywordPlan(
    groups: [SimilarityGroup],
    assignments: [(groupId: Int, keywords: [String])]
) throws -> (keywordsBySidecar: [String: [String]], affectedPaths: Set<String>) {
    let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    var keywordsBySidecar: [String: [String]] = [:]
    var affectedPaths = Set<String>()
    for assignment in assignments {
        guard let group = groupsById[assignment.groupId] else {
            throw WritebackPlannerError.groupNotInSession
        }
        for image in group.images {
            affectedPaths.insert(image.path)
            let sidecarPath = TSPath.xmpSidecarPath(image.path)
            keywordsBySidecar[sidecarPath] = orderedUnion(
                keywordsBySidecar[sidecarPath] ?? [],
                assignment.keywords
            )
        }
    }
    return (keywordsBySidecar, affectedPaths)
}

/// TS: buildFaceKeywordAdditions —— 人脸簇绑定 → 每照片关键词追加。
/// 实现见 FaceKwService.buildFaceKeywordAdditions（同 TS 源
/// writeback-planners.ts:48，本文件不重复定义）。

public enum WritebackPlannerError: Error, Equatable, CustomStringConvertible {
    case groupNotInSession // WRITEBACK_GROUP_NOT_IN_SESSION

    public var description: String {
        switch self {
        case .groupNotInSession: "WRITEBACK_GROUP_NOT_IN_SESSION"
        }
    }
}
