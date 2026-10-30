// desktop/native/gather-core/Sources/GatherDelivery/Writeback/WritebackService+Execute.swift
// 拆分（final-sweep-code P1-1 / 纯移动）：WritebackService 按角色拆分——执行与写盘循环。
// 源：HEAD ab7752e 的 Writeback/WritebackService.swift；仅调整跨文件访问级与文件头注释。
import Foundation
import os
import GatherPersistence
import GatherProtocol

extension WritebackService {
    // MARK: - 失败落库 / 目标解析
    /// 逐项失败落库：状态行写不进去时只记日志（旧实现同一处理），
    /// 但绝不静默——execute 的计数/errors 仍会反映本项失败。
    private func persistItemFailure(itemId: Int64, message: String) {
        do {
            try stateWriter.markItem(itemId: itemId, status: .failed, errorMessage: message)
        } catch {
            GatherLogger.log("Failed to record writeback item failure: \(error)", level: .error)
        }
    }

    /// TS: preloadResolvedTargets —— 整批一次 resolveMany（单 IN 查询替代逐项
    /// 5 路 JOIN）；execute 用解析后的 filepath 写盘（relink 后 preview 快照
    /// 的路径可能已失效），解析器服务不到的照片缺席，回退存储路径。
    private func preloadResolvedTargets(
        sessionId: String,
        entries: [DeliveryWritebackEntry]
    ) throws -> [String: ResolvedPhotoAsset] {
        guard let assetResolver else { return [:] }
        return try assetResolver.resolveMany(
            sessionId: sessionId,
            photoIds: Array(Set(entries.map(\.item.photoId)))
        )
    }

    // MARK: - execute（Phase 1 写盘循环；Phase 2 收敛仍在其方法体内）
    /// TS: execute —— 两阶段：Phase 1 并发读当前属性 → 合并关键词 → **直接写盘**
    /// （S5c-2b-3b-2a，不再入队/等 flush）；Phase 2 串行推进交付状态。
    ///
    /// 持久化：读 delivery_items（pending/failed）→ 交付行抢写租约 → 逐项写盘 +
    /// markItem(written/failed) → 交付行 markWritten/markFailed（revision CAS）。
    public func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult {
        let deliveryModule = try mapModule(module)
        try assertNoActiveOtherModule(sessionId: sessionId, module: module)

        var written = 0
        var failed = 0
        var skipped = 0
        var errors: [String] = []
        var failedItems: [WritebackItem] = []

        let persistedEntries = try loadEntries(sessionId: sessionId, module: deliveryModule)
        // 崩溃归位（P1-2）：上一轮在 markItem 与 markWritten 之间中断时交付停在
        // writing。先续租/抢占并收敛它，避免该 sidecar 永久无法 confirm/cleanup。
        let leaseRecovery = await recoverInterruptedWrites(
            sessionId: sessionId, entries: persistedEntries)
        errors.append(contentsOf: leaseRecovery.errors)
        written += leaseRecovery.written
        failed += leaseRecovery.failed
        var entryIndex: [Int: DeliveryWritebackEntry] = [:]
        var deliveryByPath: [String: DeliveryRow] = [:]
        for entry in persistedEntries {
            entryIndex[Int(entry.item.id)] = entry
            // P2：租约 trace 的 delivery:<id>/rev 快照（claim 前最后一次读到的行）。
            deliveryByPath[entry.delivery.xmpPath] = deliveryByPath[entry.delivery.xmpPath]
                ?? entry.delivery
        }
        // 并发 body 只读捕获（Sendable 值类型字典），故在进入 batchAsync 前转成 let。
        let entryById = entryIndex
        let resolvedByPhoto = try preloadResolvedTargets(sessionId: sessionId, entries: persistedEntries)

        // 分组键是交付主键（deliveries.xmp_path）：一条交付 = 一个 sidecar 文件；共享 sidecar 的
        // 多张照片（RAW+JPEG）在 preview 已收敛到同一条交付，组内保持输入顺序串行合并。
        var groups: [String: [WritebackItem]] = [:]
        for item in items {
            guard let itemId = item.id, let entry = entryById[itemId] else {
                skipped += 1
                continue
            }
            guard let status = entry.item.typedStatus, status == .pending || status == .failed else {
                skipped += 1
                continue
            }
            groups[entry.delivery.xmpPath, default: []].append(item)
        }

        // 逐交付抢租约（本轮一次）。不可写的交付（cleaned / 行缺失 / 他人有效租约）
        // 逐项显式失败：租约冲突保留 DELIVERY_LEASE_HELD 码，不压成通用写失败。
        var writeRevisionByPath: [String: Int64] = [:]
        var unwritablePaths: [String: String] = [:]
        for path in groups.keys.sorted() {
            do {
                if let row = try beginDeliveryWrite(xmpPath: path) {
                    writeRevisionByPath[path] = row.revision
                } else {
                    unwritablePaths[path] =
                        "DELIVERY_NOT_WRITABLE: \(path) (terminal state or revision changed)"
                }
            } catch {
                if let leaseReason = Self.leaseFailureReason(error) {
                    logLeaseEvent(
                        xmpPath: path,
                        delivery: deliveryByPath[path],
                        revision: deliveryByPath[path]?.revision,
                        op: "writeback-execute",
                        reason: leaseReason)
                }
                if let repoError = error as? DeliveryRepoError, case .leaseHeld = repoError {
                    unwritablePaths[path] = repoError.description
                } else {
                    unwritablePaths[path] = MetadataWritebackFailure.from(
                        error, xmpPath: path).description
                }
            }
        }

        var runnableGroups: [(String, [WritebackItem])] = []
        for (path, groupItems) in groups.sorted(by: { $0.key < $1.key }) {
            guard let message = unwritablePaths[path] else {
                runnableGroups.append((path, groupItems))
                continue
            }
            for item in groupItems {
                guard let itemId = item.id, let entry = entryById[itemId] else { continue }
                persistItemFailure(itemId: Int64(itemId), message: message)
                errors.append("\(path): \(message)")
                failedItems.append(entryToItem(entry, sessionId: sessionId))
                failed += 1
            }
        }

        // batchAsync 的 body 并发执行：prepared/errors/failedItems/pathErrors 都是共享
        // 可变状态，必须串行写入（实测并发 append 会 SIGSEGV 或静默丢项）——统一收进
        // PhaseOneCollector 的锁内，快照在 await 返回后转单线程合并。
        let phaseOne = PhaseOneCollector()
        // 快路径（内嵌会话）的写后报告：commit 时就地算出指纹，Phase 2 不再重读整文件。
        let rewriteReports = RewriteReportCollector()
        _ = try await batchAsync(runnableGroups, concurrency: 4) { group in
            let xmpPath = group.0
            let groupItems = group.1
            // P0-1 TOCTOU：一个交付组的 backup/read/write 必须在同一把
            // xmpPath 锁内完成；cleanup restore/remove 也取同一实例。
            try await self.fileLock.run(path: xmpPath) {
                await self.writeGroupItems(
                    xmpPath: xmpPath,
                    items: groupItems,
                    entryById: entryById,
                    resolvedByPhoto: resolvedByPhoto,
                    phaseOne: phaseOne,
                    rewriteReports: rewriteReports,
                    sessionId: sessionId
                )
            }
        }


        // 并发阶段结束：把锁内收集的状态并入单线程局部量（此后只有本任务读写）。
        var prepared: [PreparedEntry] = []
        prepared.append(contentsOf: phaseOne.preparedSnapshot)
        errors.append(contentsOf: phaseOne.errorsSnapshot)
        failedItems.append(contentsOf: phaseOne.failedItemsSnapshot)
        failed += phaseOne.failedCount
        var firstErrorByPath = phaseOne.pathErrorsSnapshot
        // 写前备份快照（xmpPath → 真实备份文件；空串 = 原 sidecar 不存在）。
        let backupByPath = phaseOne.backupsSnapshot
        // 交付级 photo_path/已有备份快照：markWritten 需要与交付行同源的路径。
        var photoPathByPath: [String: String] = [:]
        var existingBackupByPath: [String: String] = [:]
        for entry in prepared where photoPathByPath[entry.delivery.xmpPath] == nil {
            photoPathByPath[entry.delivery.xmpPath] = entry.writePhotoPath
            existingBackupByPath[entry.delivery.xmpPath] = entry.delivery.backupPath
        }

        // Phase 2（无 await 的状态推进）：Phase 1 已经真实写盘，逐项落 written。
        // 旧实现先入 outbox 再 flushSession 对照摘要——端口退场后摘要不再产生
        // 写事件，继续用它会把已落盘的项误判 failed。
        var writtenPaths = Set<String>()
        var baseValuesByPath: [String: JSONValue] = [:]
        for entry in prepared {
            do {
                try stateWriter.markItem(
                    itemId: entry.itemId, status: .written, leaseOwner: leaseOwner)
            } catch {
                let message = "DELIVERY_ITEM_WRITE_FAILED: \(error)"
                persistItemFailure(itemId: entry.itemId, message: message)
                if firstErrorByPath[entry.delivery.xmpPath] == nil {
                    firstErrorByPath[entry.delivery.xmpPath] = message
                }
                errors.append("\(entry.photoPath): \(message)")
                failedItems.append(entry.persistedItem)
                failed += 1
                continue
            }
            // 本地投影失败不得静默：逐条进报告 errors（XMP 已落盘，不改判 written）。
            let attrs = entry.writtenAttributes.asJSONValue.objectValue ?? [:]
            errors.append(contentsOf: updateLocalProjection(entry: entry, attrs: attrs, module: module))
            written += 1
            writtenPaths.insert(entry.delivery.xmpPath)
            baseValuesByPath[entry.delivery.xmpPath] = entry.writtenAttributes.asJSONValue
        }

        // 落盘后回读真实基线（S5c-2b-3b-1）：指纹取磁盘内容，base_values 取
        // 持久化属性。回读失败只进 errors，不改判已落盘的 written，也不再把
        // 两列留空等 outbox 镜像。
        var fingerprintByPath: [String: String] = [:]
        // 快路径的写后报告（内嵌会话在 commit 内已算出指纹与扫描摘要）。
        let rewriteReportByPath = rewriteReports.snapshot
        for path in writtenPaths.sorted() {
            let report = rewriteReportByPath[path]
            if let report, !report.fingerprintAfter.isEmpty {
                // 第 7 次整文件读在这里消失：指纹来自 commit 的增量哈希。
                fingerprintByPath[path] = report.fingerprintAfter
            } else {
                do {
                    fingerprintByPath[path] = try await MetadataFingerprint.contentFingerprint(path)
                } catch {
                    errors.append("DELIVERY_FINGERPRINT_FAILED: \(path): \(error)")
                }
            }
            guard let photoPath = photoPathByPath[path] else { continue }
            if report != nil {
                // 第 8 次整文件读在这里消失：base_values 用本项已持有的写入属性。
                continue
            }
            do {
                baseValuesByPath[path] = try await xmp.readAttributes(photoPath: photoPath).asJSONValue
            } catch {
                // 保留 Phase 1 的写入属性回退值。
                errors.append("DELIVERY_BASE_VALUES_FAILED: \(path): \(error)")
            }
        }

        // 交付行收敛：本交付有成功项 → written；全部失败 → failed（与镜像同一口径）。
        // 备份路径用写前 xmp.backup 的真实返回值（重试沿用交付行上的旧备份）。
        for path in writeRevisionByPath.keys.sorted() {
            guard let revision = writeRevisionByPath[path] else { continue }
            // 长批次写盘可能超过租约 TTL：收敛前续租一次。失败说明租约已被
            // 他人接管/新输入推进 revision —— 本轮不得再写 written 或 failed
            // （P1-2），行保持原样交给持有者/下一次恢复扫描。
            let holdsLease: Bool
            do {
                holdsLease = try stateWriter.renewWriting(
                    xmpPath: path, revision: revision, leaseOwner: leaseOwner)
            } catch {
                logLeaseEvent(
                    xmpPath: path,
                    delivery: deliveryByPath[path],
                    revision: revision,
                    op: "writeback-converge",
                    reason: Self.leaseFailureReason(error) ?? "DELIVERY_LEASE_LOST")
                errors.append("DELIVERY_LEASE_LOST: \(path): \(error)")
                continue
            }
            guard holdsLease else {
                logLeaseEvent(
                    xmpPath: path,
                    delivery: deliveryByPath[path],
                    revision: revision,
                    op: "writeback-converge",
                    reason: "DELIVERY_LEASE_LOST")
                errors.append("DELIVERY_LEASE_LOST: \(path)")
                continue
            }
            if writtenPaths.contains(path) {
                let backupPath = backupByPath[path].flatMap { $0.isEmpty ? nil : $0 }
                    ?? existingBackupByPath[path]
                    ?? ""
                do {
                    let row = try stateWriter.markWrittenAndClearReloadAcks(
                        xmpPath: path,
                        revision: revision,
                        leaseOwner: leaseOwner,
                        baseFingerprint: fingerprintByPath[path] ?? "",
                        baseValues: baseValuesByPath[path] ?? .object([:]),
                        backupPath: backupPath,
                        timestamp: nowISOString()
                    )
                    if row == nil {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: leaseReason)
                    }
                    errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            } else {
                let message = firstErrorByPath[path] ?? "WRITEBACK_FAILED"
                do {
                    let row = try stateWriter.markFailed(
                        xmpPath: path, revision: revision, errorMessage: message,
                        leaseOwner: leaseOwner)
                    if row == nil {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: deliveryByPath[path],
                            revision: revision,
                            op: "writeback-converge",
                            reason: leaseReason)
                    }
                    errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            }
        }

        // 交付行/项已从 pending 收敛到 written/failed：通知宿主刷新同步徽标。
        emitStateChanged(sessionId)
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

    /// 单个交付组的文件阶段（execute Phase 1 的唯一写盘入口）。
    ///
    /// 调用方必须已持有 XMPFileLock（同一 xmpPath）：backup → readAttributes →
    /// writeAttributes 必须原子成组，否则 cleanup 的 restore/remove 可能插在
    /// “读旧值”与“写新值”之间。组内仍按输入顺序串行（RAW+JPEG 共享 sidecar 时
    /// 后一项看到前一项刚写入的内容），批次/排序语义不变。
    private func writeGroupItems(
        xmpPath: String,
        items: [WritebackItem],
        entryById: [Int: DeliveryWritebackEntry],
        resolvedByPhoto: [String: ResolvedPhotoAsset],
        phaseOne: PhaseOneCollector,
        rewriteReports: RewriteReportCollector,
        sessionId: String
    ) async {
        for item in items {
            guard let itemId = item.id, let entry = entryById[itemId] else { continue }

            var photoPath = entry.delivery.photoPath
            if photoPath.isEmpty, !xmpPath.isEmpty {
                // TS: dbRow.xmp_path.replace(/\.xmp$/i, '')
                var fallback = xmpPath
                if fallback.lowercased().hasSuffix(".xmp") { fallback = String(fallback.dropLast(4)) }
                photoPath = fallback
            }
            let persistedItem = entryToItem(entry, sessionId: sessionId)
            guard !photoPath.isEmpty else {
                let message = "Missing photo path for writeback item"
                persistItemFailure(itemId: Int64(itemId), message: message)
                phaseOne.recordPathError(path: xmpPath, message: message)
                var failedItem = persistedItem
                failedItem.photoPath = ""
                phaseOne.recordFailure(message: "\(itemId): \(message)", item: failedItem)
                continue
            }

            do {
                // 写盘目标按 execute 时的资产状态解析：preview 与 execute 之间
                // 可能已完成 relink（asset_read_mode='asset'），用 preview 快照
                // 会写到旧路径/旧 sidecar。
                let resolvedTarget = resolvedByPhoto[entry.item.photoId]
                let writePhotoPath = resolvedTarget?.filepath ?? photoPath
                // P1 下一波（plan §3.2）：内嵌目标优先走"一次打开"会话——写前指纹、
                // 备份、读属性、写盘、写后校验全部复用同一次顺序遍历。会话返回 nil
                // （非内嵌/不支持/读取回退）时落回下面的旧路径，语义逐字节不变。
                if let session = await openRewriteSession(photoPath: writePhotoPath) {
                    try await writeWithSession(
                        session: session,
                        entry: entry,
                        persistedItem: persistedItem,
                        xmpPath: xmpPath,
                        photoPath: photoPath,
                        writePhotoPath: writePhotoPath,
                        itemId: Int64(itemId),
                        phaseOne: phaseOne,
                        rewriteReports: rewriteReports)
                    continue
                }
                // P1：写前基线校验。plan/入队到真正写盘之间外部可能改过 sidecar；
                // 有 base_fingerprint 时先比对，避免 keepExternal 计划被静默覆盖。
                if (entry.item.typedModule == .metadata
                        || entry.item.typedModule == .template),
                   !entry.delivery.baseFingerprint.isEmpty {
                    let targetXmp = target.path(writePhotoPath)
                    do {
                        let current = try await MetadataFingerprint.contentFingerprint(targetXmp)
                        if current != entry.delivery.baseFingerprint {
                            let message = "XMP_EXTERNAL_EDIT_CONFLICT"
                            persistItemFailure(itemId: Int64(itemId), message: message)
                            phaseOne.recordPathError(path: xmpPath, message: message)
                            phaseOne.recordFailure(
                                message: "\(photoPath): \(message)", item: persistedItem)
                            continue
                        }
                    } catch {
                        let message = "XMP_FINGERPRINT_FAILED: \(error)"
                        persistItemFailure(itemId: Int64(itemId), message: message)
                        phaseOne.recordPathError(path: xmpPath, message: message)
                        phaseOne.recordFailure(
                            message: "\(photoPath): \(message)", item: persistedItem)
                        continue
                    }
                }
                // 写前真实备份（S5c-2b-3b-1）：必须在文件写入之前取，
                // 备份路径随 markWritten 直接落 deliveries.backup_path。
                // 已有备份（重试）直接复用。
                if entry.delivery.backupPath.isEmpty, phaseOne.needsBackup(path: xmpPath) {
                    do {
                        let backupPath = try await xmp.backup(photoPath: writePhotoPath)
                        phaseOne.recordBackup(path: xmpPath, backupPath: backupPath)
                    } catch {
                        let message = MetadataWritebackFailure.from(error, xmpPath: xmpPath).description
                        persistItemFailure(itemId: Int64(itemId), message: message)
                        phaseOne.recordPathError(path: xmpPath, message: message)
                        phaseOne.recordFailure(message: "\(photoPath): \(message)", item: persistedItem)
                        continue
                    }
                }
                // 直写（S5c-2b-3b-2a）：先读当前属性再只覆盖本次字段，
                // 保留外部写入的 dateTaken/GPS；关键词按磁盘现状重新合并，
                // 避免 preview 快照与 execute 之间外部新增的词被静默丢弃。
                // 合并规则抽在 mergeAttributes 里：快路径（内嵌会话）与旧路径共用同一份。
                let merged = mergeAttributes(
                    base: try await xmp.readAttributes(photoPath: writePhotoPath),
                    entry: entry,
                    persistedItem: persistedItem)
                let attributesToWrite = merged.attributes
                let keywordsBeforeWrite = merged.keywordsBeforeWrite
                try await xmp.writeAttributes(
                    photoPath: writePhotoPath, attributes: attributesToWrite)
                phaseOne.recordPrepared(PreparedEntry(
                    itemId: Int64(itemId),
                    delivery: entry.delivery,
                    persistedItem: persistedItem,
                    photoPath: photoPath,
                    writePhotoPath: writePhotoPath,
                    writtenAttributes: attributesToWrite,
                    keywordsBeforeWrite: keywordsBeforeWrite
                ))
            } catch {
                // 逐项隔离：本项失败只影响本项，错误以「错误码 + 路径 + 原因」上报。
                let message = MetadataWritebackFailure.from(error, xmpPath: xmpPath).description
                persistItemFailure(itemId: Int64(itemId), message: message)
                phaseOne.recordPathError(path: xmpPath, message: message)
                phaseOne.recordFailure(message: "\(photoPath): \(message)", item: persistedItem)
            }
        }
    }

    // MARK: - 内嵌快路径（plan §3.2）

    /// 打开写回会话。nil = 走旧路径；打开失败只留痕（快路径不得让原本能写成功的项失败）。
    private func openRewriteSession(photoPath: String) async -> (any MetadataRewriteSession)? {
        guard let factory = rewriteSessions else { return nil }
        do {
            return try await factory.open(photoPath: photoPath)
        } catch {
            GatherLogger.log(
                "embedded rewrite session unavailable, falling back "
                    + "(path token=\(TSPath.basename(photoPath))): \(error)",
                level: .debug)
            return nil
        }
    }

    /// 快路径的单项写盘：一次打开的会话同时覆盖
    /// 写前指纹（session.fingerprintBefore）/ 备份 / 读属性（session.attributes）/
    /// 写盘 + 写后校验（session.commit）/ 写后指纹（report.fingerprintAfter）。
    /// 与旧路径的差异只有"少读几遍整文件"，语义与错误码保持同一口径。
    private func writeWithSession(
        session: any MetadataRewriteSession,
        entry: DeliveryWritebackEntry,
        persistedItem: WritebackItem,
        xmpPath: String,
        photoPath: String,
        writePhotoPath: String,
        itemId: Int64,
        phaseOne: PhaseOneCollector,
        rewriteReports: RewriteReportCollector
    ) async throws {
        // 写前基线校验（P1）：与旧路径同一语义、同一稳定码，只是指纹改用会话快照
        // 里的值 —— 省掉第 1 次整文件读。
        if (entry.item.typedModule == .metadata || entry.item.typedModule == .template),
           !entry.delivery.baseFingerprint.isEmpty,
           session.fingerprintBefore != entry.delivery.baseFingerprint {
            throw WritebackConflictError(path: xmpPath)
        }
        // 写前真实备份（S5c-2b-3b-1）：必须在文件写入之前取；已有备份（重试）直接复用。
        if entry.delivery.backupPath.isEmpty, phaseOne.needsBackup(path: xmpPath) {
            let backupPath = try await session.writeHeaderBackup()
            phaseOne.recordBackup(path: xmpPath, backupPath: backupPath)
        }
        let merged = mergeAttributes(
            base: session.attributes, entry: entry, persistedItem: persistedItem)
        let report: MetadataRewriteReport
        do {
            report = try await session.commit(merged.attributes)
        } catch {
            // 失败不一定走到替换；让会话清掉本次新建的 header 备份，避免孤儿。
            await session.abort()
            throw error
        }
        rewriteReports.record(path: xmpPath, report: report)
        phaseOne.recordPrepared(PreparedEntry(
            itemId: itemId,
            delivery: entry.delivery,
            persistedItem: persistedItem,
            photoPath: photoPath,
            writePhotoPath: writePhotoPath,
            writtenAttributes: merged.attributes,
            keywordsBeforeWrite: merged.keywordsBeforeWrite
        ))
    }

    /// 组内合并：盘上现值 + 本项意图 → 待写属性。
    /// 旧路径（xmp.readAttributes）与快路径（session.attributes）共用这一份实现，
    /// 否则两条路径会写出不同关键词顺序/不同三态结果。
    private func mergeAttributes(
        base: MetadataWriteAttributes,
        entry: DeliveryWritebackEntry,
        persistedItem: WritebackItem
    ) -> (attributes: MetadataWriteAttributes, keywordsBeforeWrite: [String]) {
        var attributesToWrite = base
        let keywordsBeforeWrite = attributesToWrite.keywords ?? []
        let writeKeywords = orderedUnion(keywordsBeforeWrite, persistedItem.keywords)
        // attributes.keywords（如 culling 写回计划）也必须合并。
        let mergedKeywords = orderedUnion(
            writeKeywords,
            persistedItem.attributes?.keywords ?? []
        )
        // 关键词写入模式（S5c-2b-3b-2b-2）：手动元数据把意图落在
        // delivery_items.attributes_json.keywords_mode。replace = 以项里的
        // keywords 为权威列表（replace/remove 必须能删词）；缺省/merge =
        // 与盘上现状取并集（culling/人脸/相似度的只增语义不变）。
        let keywordsMode = entry.item.attributes[
            MetadataMutationService.keywordsModeKey]?.stringValue
        if keywordsMode == MetadataKeywordWriteMode.delta.rawValue {
            // K0：delta 在锁内按盘上现状重新合并，绝不覆盖 preview 后外部新增的词。
            let added = entry.item.attributes["keywords_added"]?
                .arrayElements?.compactMap(\.stringValue) ?? []
            let removed = entry.item.attributes["keywords_remove"]?
                .arrayElements?.compactMap(\.stringValue) ?? []
            attributesToWrite.keywords = KeywordPlanner.apply(
                existing: keywordsBeforeWrite, added: added, removed: removed)
        } else if keywordsMode == MetadataKeywordWriteMode.replace.rawValue {
            attributesToWrite.keywords = persistedItem.keywords
        } else {
            attributesToWrite.keywords = persistedItem.attributes != nil
                ? mergedKeywords
                : writeKeywords
        }
        if let attributes = persistedItem.attributes {
            if let rating = attributes.rating { attributesToWrite.rating = rating }
            if let label = attributes.label { attributesToWrite.label = label }
        }
        // P1 / IPTC：描述性元数据按字段三态合并到盘上现值（nil 保留、
        // 空值清空、有值写入），绝不整块覆盖外部新增的字段。
        if let descriptiveValue = entry.item.attributes["descriptive"],
           let descriptive = try? descriptiveValue.decode(DescriptiveMetadata.self),
           !descriptive.isEmpty {
            var merged = (attributesToWrite.descriptive ?? DescriptiveMetadata())
                .applying(descriptive)
            // 撤销模板时结构字段必须整块还原（含删除模板新增的 contact 成员）；
            // 普通套用仍走成员级合并，绝不覆盖外部填写的其它成员。
            // P0：标志为真但补丁没带 contact 时，绝不能拿空结构整块替换——
            // 那会把 sidecar 里的 CreatorContactInfo 静默删光。
            if entry.item.attributes["replace_contact"]?.boolValue == true,
               let contact = descriptive.contactInfo {
                merged.set(.contact(contact), for: .contactInfo)
            }
            attributesToWrite.descriptive = merged
            // P2：把"整块替换"标志带到 Converge，否则崩溃重放/撤销时缓存投影
            // 只做成员级合并，模板删掉的 contact 成员会留在 iptc_json。
            if entry.item.attributes["replace_contact"]?.boolValue == true,
               descriptive.contactInfo != nil {
                attributesToWrite.replaceContact = true
            }
        }
        // P1 / E：triage 私有命名空间信号随交付落盘。
        if let signal = entry.item.attributes["triageSignal"]?.stringValue {
            attributesToWrite.triageSignal = signal
        }
        return (attributesToWrite, keywordsBeforeWrite)
    }
}

/// 快路径的写后报告收集（并发 body 写入，Phase 2 单线程读快照）。
/// 与 PhaseOneCollector 同锁纪律：锁内不含 await。
final class RewriteReportCollector: Sendable {
    private let reports = OSAllocatedUnfairLock<[String: MetadataRewriteReport]>(initialState: [:])

    /// 同一交付（xmpPath）在一个组内串行写：后一次覆盖前一次，最终指纹以最后一次为准。
    func record(path: String, report: MetadataRewriteReport) {
        reports.withLock { $0[path] = report }
    }

    var snapshot: [String: MetadataRewriteReport] {
        reports.withLock { $0 }
    }
}

/// 写前基线不符（快路径）：稳定码与旧路径一致（XMP_EXTERNAL_EDIT_CONFLICT），
/// 由 MetadataWritebackFailure.from 落库成与旧路径同名的冲突。
struct WritebackConflictError: Error, MetadataCodedError, CustomStringConvertible {
    let path: String

    var code: String { "XMP_EXTERNAL_EDIT_CONFLICT" }
    var xmpPath: String { path }
    var description: String { "XMP_EXTERNAL_EDIT_CONFLICT: " + path }
}
