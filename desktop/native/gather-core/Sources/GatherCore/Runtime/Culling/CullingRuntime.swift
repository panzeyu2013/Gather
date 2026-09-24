// desktop/native/gather-core/Sources/GatherCore/Runtime/Culling/CullingRuntime.swift
// W2b（设计 §1/§2.5/§2.6）：CullingRuntime actor —— 取代 Services/CullingService.swift
// 的读路径与写路径编排（本轮只新增，不接线、不改旧文件；步骤 7 切换后删除旧服务）。
//
// 结构：
// - 唯一长生命周期可变状态是 CullingSessionCache actor；本 actor 只持 Dependencies
//   + loader + cache，不持任何可变字典/类（旧 sessionLookupCache/sessionUpdateCache
//   的可变 class 条目结构性消除）。
// - 读：list / listPage / groups / summary / history；写：update / batchUpdate /
//   applyHistory / decideGroup / reset / resetCommand；纯委托：syncStatus / flush /
//   retrySync / finalizeSync / writeback / retryFailedWriteback / confirmSync / cleanup。
// - 重入安全：全部 await 预读集中在 updateContext / loadUpdateRows（进入无 await 的
//   同步临界区 performUpdate 之前）；performUpdate 绝不 await，写入经值类型
//   CullingWriteCollectors 收集，提交阶段再回异步。
// - revision：单事务 CAS 由 CullingStore.applyDecisionStates 承担（消除 TOCTOU）。
//
// 与旧实现的有意差异（均已注释，见最终迁移报告）：
// 1. 旧 updateState 只预读「被点击照片」的决策行，资产变体的状态回退到缓存行并把其
//    revision 重置为 1；CAS 下这会误报冲突。新实现预读**受影响照片超集**（资产变体 +
//    共享侧车）的决策行与缓存行，变体 revision 连续递增（修复，非兼容层）。
// 2. commitDecisionWritesCAS：Store 的 applyDecisionStates 只接受单一
//    expectedRevision，而同一资产两个变体的 revision 基线可不同（正常数据形态）。
//    实现按基线分组：同基线一批一次事务；混合基线按基线类顺序 CAS，任一组冲突立即
//    停止并返回冲突（已提交组不回滚——Store API 单基线约束下的已知偏差，报告已列出
//    建议：给 CullingDecisionWrite 增加 per-write expectedRevision）。
// 3. 提交顺序：CAS 决策写入 → outbox → 派生缓存列 → 历史；旧实现 outbox → 派生列 →
//    决策 upsert → 历史。CAS 冲突时不再产生任何副作用（旧实现会先写 outbox）。
// 4. CullingStoreError 在 Runtime 边界按设计 §3.5 映射：
//    undoNotLatest/redoOutOfOrder/historyStale/historyCorrupt →
//    historyAlreadyUndone/historyNotUndone/historyDiverged/historyNotFound。
// 5. loadSessionPhotos 的 try? 静默降级改为上抛（设计 §3.1）；提交后 outbox 状态回读
//    仍显式忽略读失败（决策已落库，展示载荷保留保守值，原 try? 语义）。
//
// 门禁：本文件不出现 SQL 文本与 SQLiteDatabase（只经 Store 协议）。

import Foundation

// MARK: - 写入收集器（值类型）

/// 事务外收集、提交后落库的写入集合。替代旧 CullingHistorySink（带检查豁免的可变
/// class，门禁词不在此复述）：全部字段为 Sendable 值类型，inout 传入同步临界区，
/// 绝无共享可变状态。
struct CullingWriteCollectors: Sendable {
    /// 历史条目（appendHistory 用）。
    var historyEntries: [CullingHistoryEntry] = []
    /// 派生缓存列补丁（rating/label）。
    var cachePatches: [CullingCachePatch] = []
    /// 决策行写入（CAS 主体）。
    var decisionWrites: [CullingDecisionWrite] = []
    /// outbox 值直写（queuePhotoValues 后置）。
    var outboxWrites: [CullingOutboxWrite] = []
}

// MARK: - 预读快照（进入同步临界区前一次性构造）

/// updateState 的不可变预读快照（所有 await 都发生在构造之前）。
struct CullingUpdateSnapshot: Sendable {
    let photos: [CullingPhotoRow]
    let photoById: [String: CullingPhotoRow]
    let photosByAssetId: [String: [CullingPhotoRow]]
    /// photoId → "resultId:index"（已解析，绝不为 nil）。
    let groupMap: [String: String]
    /// xmpPath → 共享该侧车的照片。
    let linkedByXmp: [String: [CullingPhotoRow]]
    /// photoId → 元数据缓存行（受影响超集）。
    let cacheRows: [String: MetadataCacheRecord]
    /// photoId → 当前决策行（受影响超集；缺失即首次决策）。
    let decisionRows: [String: CullingDecisionRecord]
}

/// performUpdate 的同步产出：结果 + 提交所需信息。
private struct CullingUpdateOutcome: Sendable {
    var result: CullingUpdateResult
    /// 每条决策写入的 CAS 基线（photoId → 预读 revision）。
    var expectedRevisions: [String: Int]
    /// metadataSync.schedule 的目标（仅 metadataPatch 非空时非空，设计 §3.8）。
    var scheduleXmpPaths: [String]
}

/// CAS 失败组（用于按真实 current revision 抛出 CULLING_REVISION_CONFLICT）。
private struct CullingDecisionCASConflict: Sendable {
    let expected: Int
    let photoId: String
}

// MARK: - CullingRuntime

public actor CullingRuntime {
    /// 依赖集合（装配期注入；actor 只读）。
    public struct Dependencies {
        public let photoStore: any PhotoStore
        public let queryStore: any CullingQueryStore
        public let cullingStore: (any CullingStore)?
        public let metadataStore: any MetadataStore
        public let similarityStore: any SimilarityStore
        public let writebackStore: any WritebackStore
        public let sessionStore: any SessionStore
        public let jobStore: any JobStore
        public let faceStore: any FaceStore
        public let personStore: any PersonStore
        public let metadataSync: any CullingSyncPort
        public let metadataMutations: any MetadataMutationPort
        public let writeback: any CullingWritebackPort
        public let getNumber: (String, Double) -> Double

        public init(
            photoStore: any PhotoStore,
            queryStore: any CullingQueryStore,
            cullingStore: (any CullingStore)?,
            metadataStore: any MetadataStore,
            similarityStore: any SimilarityStore,
            writebackStore: any WritebackStore,
            sessionStore: any SessionStore,
            jobStore: any JobStore,
            faceStore: any FaceStore,
            personStore: any PersonStore,
            metadataSync: any CullingSyncPort,
            metadataMutations: any MetadataMutationPort,
            writeback: any CullingWritebackPort,
            getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue }
        ) {
            self.photoStore = photoStore
            self.queryStore = queryStore
            self.cullingStore = cullingStore
            self.metadataStore = metadataStore
            self.similarityStore = similarityStore
            self.writebackStore = writebackStore
            self.sessionStore = sessionStore
            self.jobStore = jobStore
            self.faceStore = faceStore
            self.personStore = personStore
            self.metadataSync = metadataSync
            self.metadataMutations = metadataMutations
            self.writeback = writeback
            self.getNumber = getNumber
        }
    }

    private let deps: Dependencies
    private let loader: CullingLookupLoader
    private let cache: CullingSessionCache

    public init(dependencies: Dependencies, cache: CullingSessionCache = CullingSessionCache()) {
        self.deps = dependencies
        self.loader = CullingLookupLoader(
            cullingStore: dependencies.cullingStore,
            metadataStore: dependencies.metadataStore,
            writebackStore: dependencies.writebackStore,
            similarityStore: dependencies.similarityStore,
            jobStore: dependencies.jobStore,
            faceStore: dependencies.faceStore,
            personStore: dependencies.personStore
        )
        self.cache = cache
    }

    // MARK: - 读路径

    /// TS: list —— 会话全量资产列表（变体折叠 + 过滤安全网）。
    public func list(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil
    ) async throws -> [CullingAsset] {
        let photos = try await loadSessionPhotoRows(sessionId: sessionId)
        let lookup = try await sessionAssetLookup(sessionId: sessionId, photos: photos)
        return CullingAssembler.filterVisible(
            CullingAssembler.assembleAssets(photos: photos, lookup: lookup, getNumber: deps.getNumber),
            scope: scope,
            filters: filters,
            requestedGroupId: requestedGroupId
        )
    }

    /// TS: listPage —— 资产分组 keyset 分页（RAW/JPEG 变体永不分页；total 精确）。
    /// total 与 page 同源：SQL scope 经 CullingQueryStore.countAssetGroups；不可解析的
    /// 相似度组 id 回退 JS 相似度映射计数（与页面 JS 过滤同源，防止 total 与页漂移）。
    public func listPage(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil,
        afterRowId: Int64? = nil,
        limit: Int = 200
    ) async throws -> CullingPage {
        let request = try CullingQueryBuilder.pageRequest(
            sessionId: sessionId,
            scope: scope,
            filters: filters,
            requestedGroupId: requestedGroupId,
            afterRowId: afterRowId,
            limit: limit
        )
        let page = try await deps.queryStore.assetGroupPage(request.query)
        let photos = page.rows.map { CullingPhotoRow(row: $0) }
        let lookup = try await loader.loadPageLookup(photos: photos, sessionId: sessionId)
        let assets = CullingAssembler.filterVisible(
            CullingAssembler.assembleAssets(photos: photos, lookup: lookup, getNumber: deps.getNumber),
            scope: request.postFilter.scope,
            specs: request.postFilter.specs,
            metadataConflictOnly: request.postFilter.metadataConflictOnly,
            requestedGroupId: request.postFilter.requestedGroupId
        )
        let total = try await countForRequest(request: request, similarityMap: lookup.similarityMap)
        return CullingPage(
            assets: assets,
            nextRowId: page.cursor.map(Int.init),
            total: total
        )
    }

    /// TS: getGroups —— 相似度分组（决策计数 + 成员轻投影）。
    public func groups(sessionId: String) async throws -> [CullingGroup] {
        let sessionLookup = try await loader.loadSessionLookup(sessionId: sessionId)
        guard sessionLookup.resultRow != nil else { return [] }
        let photos = try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
            .map { CullingPhotoRow(row: $0) }
        let decisions = try await loader.loadDecisions(photos: photos, sessionId: sessionId, mode: .session)
        return CullingAssembler.groups(
            photos: photos,
            membership: sessionLookup.similarityMap,
            decisions: decisions.mapValues(\.decision)
        )
    }

    /// TS: getSummary —— 徽标计数（决策 + 缓存 fallback + 相似度组数）。
    /// 决策与缓存读每次调用保持新鲜（徽标必须反映刚完成的写入），不走会话缓存；
    /// 组数用 Assembler.parseTotalGroups 解析小 stats_json（旧 groupCount 缓存字段
    /// 在本 Runtime 中不再需要：版本键已把重建成本限制到 (session, seq, resultId)）。
    public func summary(sessionId: String) async throws -> CullingSummary {
        let photos = try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
            .map { CullingPhotoRow(row: $0) }
        let decisions = try await loader.loadDecisions(photos: photos, sessionId: sessionId, mode: .session)
        let cacheByPhoto = try await loader.loadSummaryCache(photoIds: photos.map(\.id))
        let sessionLookup = try await loader.loadSessionLookup(sessionId: sessionId)
        return CullingAssembler.summary(
            photos: photos,
            decisions: decisions,
            cacheByPhoto: cacheByPhoto,
            result: sessionLookup.resultRow
        )
    }

    /// TS: getHistory —— 历史栈（Store 内 clamp 到 500）。
    public func history(sessionId: String, limit: Int = 100) async throws -> [CullingHistoryOperation] {
        try await deps.cullingStore?.historyList(sessionId: sessionId, limit: limit) ?? []
    }

    // MARK: - 缓存失效

    /// TS: invalidateSessionLookup —— 后台分析（质量/人脸/关键词）跑完一轮后调用：
    /// 分析派生映射（质量/人脸/人物）立即失效，下一次读取按需重载。相似度版本键与
    /// update 条目不受影响（index_seq 即照片集版本，设计 §2）。
    public func invalidateSessionLookup(sessionId: String) async {
        await cache.invalidateAnalyses(sessionId: sessionId)
    }

    // MARK: - 写路径：单张更新

    /// TS: update —— 单张照片状态更新（pick/rating/colorLabel），受影响照片为 asset
    /// 变体（pick）或共享侧车（shared metadata）。revision 由 Store 单事务 CAS 保证。
    @discardableResult
    public func update(
        sessionId: String,
        photoId: String,
        expectedRevision: Int,
        patch: CullingUpdatePatch
    ) async throws -> CullingUpdateResult {
        let context = try await resolvedUpdateContext(sessionId: sessionId, freshReadOnMissing: false)
        guard let target = context.entry.photoById[photoId] else {
            throw CullingServiceError.photoNotInSession
        }
        let preReadIds = Self.affectedPhotoIds(
            targets: [target],
            patch: patch,
            photosByAssetId: context.entry.photosByAssetId,
            linkedByXmp: context.entry.linkedByXmp ?? [:]
        )
        let rows = try await loadUpdateRows(sessionId: sessionId, photoIds: preReadIds)
        let snapshot = Self.makeSnapshot(entry: context.entry, rows: rows)

        var collectors = CullingWriteCollectors()
        let outcome = try performUpdate(
            sessionId: sessionId,
            photoId: photoId,
            expectedRevision: expectedRevision,
            patch: patch,
            snapshot: snapshot,
            collectors: &collectors
        )
        if let conflict = try await commitDecisionWritesCAS(
            sessionId: sessionId,
            writes: collectors.decisionWrites,
            expectedRevisions: outcome.expectedRevisions
        ) {
            throw try await revisionConflictError(conflict, sessionId: sessionId)
        }
        try await commitOutboxWrites(collectors.outboxWrites)
        try await commitCachePatches(collectors.cachePatches)
        var result = outcome.result
        result.historyOperationId = try await appendHistory(collectors.historyEntries, sessionId: sessionId)
        for xmpPath in outcome.scheduleXmpPaths {
            deps.metadataSync.schedule(xmpPath: xmpPath)
        }
        await refreshOutboxStatus(of: &result)
        return result
    }

    // MARK: - 写路径：批量更新

    /// TS: batchUpdate —— 批量更新；pick 按逻辑资产合并、shared metadata 按共享侧车
    /// 合并，决策行整批一次事务 CAS。返回每条操作的结果（历史操作 id 共享）。
    public func batchUpdate(
        sessionId: String,
        photoIds: [String],
        patch: CullingUpdatePatch
    ) async throws -> [CullingUpdateResult] {
        try CullingQueryBuilder.validatePatch(patch)
        let uniqueIds = try CullingQueryBuilder.validateBatch(photoIds)

        var context = try await resolvedUpdateContext(sessionId: sessionId, freshReadOnMissing: false)
        // 与旧实现相同的 fresh-read 兜底：索引器刚加的照片可能缺席版本缓存。
        if uniqueIds.contains(where: { context.entry.photoById[$0] == nil }) {
            context = try await resolvedUpdateContext(sessionId: sessionId, freshReadOnMissing: true)
            if uniqueIds.contains(where: { context.entry.photoById[$0] == nil }) {
                throw CullingServiceError.photosNotInSession
            }
        }
        let entry = context.entry
        let operationIds = Self.operationIds(uniqueIds: uniqueIds, patch: patch, photoById: entry.photoById)
        let targets = operationIds.compactMap { entry.photoById[$0] }
        let preReadIds = Self.affectedPhotoIds(
            targets: targets,
            patch: patch,
            photosByAssetId: entry.photosByAssetId,
            linkedByXmp: entry.linkedByXmp ?? [:]
        )
        let rows = try await loadUpdateRows(sessionId: sessionId, photoIds: preReadIds)
        let snapshot = Self.makeSnapshot(entry: entry, rows: rows)

        var collectors = CullingWriteCollectors()
        var results: [CullingUpdateResult] = []
        var expectedRevisions: [String: Int] = [:]
        var scheduleXmpPaths: [String] = []
        for photoId in operationIds {
            let current = Int(snapshot.decisionRows[photoId]?.revision ?? 0)
            let outcome = try performUpdate(
                sessionId: sessionId,
                photoId: photoId,
                expectedRevision: current,
                patch: patch,
                snapshot: snapshot,
                collectors: &collectors
            )
            results.append(outcome.result)
            expectedRevisions.merge(outcome.expectedRevisions) { _, new in new }
            scheduleXmpPaths.append(contentsOf: outcome.scheduleXmpPaths)
        }

        if let conflict = try await commitDecisionWritesCAS(
            sessionId: sessionId,
            writes: collectors.decisionWrites,
            expectedRevisions: expectedRevisions
        ) {
            throw try await revisionConflictError(conflict, sessionId: sessionId)
        }
        try await commitOutboxWrites(collectors.outboxWrites)
        try await commitCachePatches(collectors.cachePatches)
        if let cullingStore = deps.cullingStore, !collectors.historyEntries.isEmpty {
            let operationId = try await cullingStore.appendHistory(
                sessionId: sessionId, entries: collectors.historyEntries
            ).id
            for index in results.indices {
                results[index].historyOperationId = operationId
            }
        }
        for xmpPath in scheduleXmpPaths {
            deps.metadataSync.schedule(xmpPath: xmpPath)
        }
        return results
    }

    // MARK: - 写路径：应用历史（显式条目 / undo / redo）

    /// TS: applyHistory —— 应用显式条目（renderer 重建的补丁）或历史栈操作（undo/redo，
    /// 按操作 id 解析 entries）；带操作 id 时校验并发边界（undone 标志 + 分歧比较）。
    @discardableResult
    public func applyHistory(
        sessionId: String,
        requestedEntries: [CullingHistoryApplyEntry],
        historyOperationId: Int? = nil,
        direction: CullingHistoryDirection? = nil
    ) async throws -> [CullingUpdateResult] {
        var historyOperationId = historyOperationId
        var entries = requestedEntries
        var historicalFields: [String: [CullingUpdatePatchField]] = [:]
        var operation: CullingHistoryOperation?
        if let operationId = historyOperationId, let direction {
            operation = try await loadHistoryOperation(sessionId: sessionId, operationId: operationId)
            guard let operation else { throw CullingServiceError.historyNotFound }
            if operation.undone != (direction == .redo) {
                throw direction == .undo
                    ? CullingServiceError.historyAlreadyUndone
                    : CullingServiceError.historyNotUndone
            }
            historicalFields = Dictionary(
                uniqueKeysWithValues: operation.entries.map { ($0.photoId, $0.fields) }
            )
            entries = operation.entries.map { entry in
                // 操作 id 与顺序是并发守卫。revision 从当前数据库状态解析，
                // 使连续 undo/redo 在插入中间历史操作与应用重启后仍然有效。
                CullingHistoryApplyEntry(
                    photoId: entry.photoId,
                    expectedRevision: -1,
                    patch: CullingAssembler.patch(
                        fields: entry.fields,
                        snapshot: direction == .undo ? entry.before : entry.after
                    )
                )
            }
        }
        if entries.isEmpty { return [] }
        let unique = Set(entries.map(\.photoId))
        // ADR-017: internal-invariant diagnostic —— 损坏的历史载荷。
        if unique.count != entries.count {
            throw CullingServiceError.historyDuplicatePhotos
        }
        for entry in entries {
            try CullingQueryBuilder.validatePatch(entry.patch)
        }

        let context = try await resolvedUpdateContext(sessionId: sessionId, freshReadOnMissing: false)
        var entryContext = context
        // 与 update/batchUpdate 相同的 fresh-read 兜底。
        if entries.contains(where: { entryContext.entry.photoById[$0.photoId] == nil }) {
            entryContext = try await resolvedUpdateContext(sessionId: sessionId, freshReadOnMissing: true)
        }
        let entryIds = entries.map(\.photoId)
        let rows = try await loadUpdateRows(sessionId: sessionId, photoIds: entryIds)
        let snapshot = Self.makeSnapshot(entry: entryContext.entry, rows: rows)

        for entry in entries {
            guard snapshot.photoById[entry.photoId] != nil else {
                throw CullingServiceError.photoNotInSession
            }
            let currentRevision = snapshot.decisionRows[entry.photoId]?.revision ?? 0
            if historyOperationId == nil && currentRevision != Int64(entry.expectedRevision) {
                throw CullingServiceError.revisionConflict(
                    expected: entry.expectedRevision, current: Int(currentRevision)
                )
            }
        }
        if let operation, direction != nil {
            for historical in operation.entries {
                let current = CullingAssembler.state(
                    photoId: historical.photoId,
                    decision: snapshot.decisionRows[historical.photoId],
                    cache: snapshot.cacheRows[historical.photoId]
                )
                let expected = direction == .undo ? historical.after : historical.before
                for field in historical.fields
                where !CullingAssembler.matchesSnapshot(state: current, snapshot: expected, field: field) {
                    throw CullingServiceError.historyDiverged
                }
            }
        }

        // outbox 每会话读一次而非每条目两次（1 万次 undo 就是 2 万次单行查询）：
        // 行按 xmp 路径键控，顺序内读取全部发生在 queuePhotoValues 写任何行之前。
        var outboxByPath = Dictionary(
            uniqueKeysWithValues: try await deps.writebackStore.outboxEntries(sessionId: sessionId)
                .map { ($0.xmpPath, $0) }
        )
        func outboxStatus(_ xmpPath: String) -> MetadataSyncStatus {
            MetadataSyncStatus(rawValue: outboxByPath[xmpPath]?.status ?? "") ?? .clean
        }

        // ---- 无 await 的状态计算与收集 ----
        var collectors = CullingWriteCollectors()
        var results: [CullingUpdateResult] = []
        var expectedRevisions: [String: Int] = [:]
        var xmpPatches: [String: (photoId: String, values: [String: JSONValue])] = [:]
        for entry in entries {
            guard let photo = snapshot.photoById[entry.photoId] else {
                throw CullingServiceError.photoNotInSession
            }
            let existing = snapshot.decisionRows[entry.photoId]
            let cache = snapshot.cacheRows[entry.photoId]
            let before = CullingAssembler.state(
                photoId: entry.photoId, decision: existing, cache: cache
            )
            let after = AssetCullingState(
                photoId: entry.photoId,
                pickState: entry.patch.pickState ?? before.pickState,
                rating: entry.patch.rating ?? before.rating,
                colorLabel: entry.patch.colorLabel ?? before.colorLabel,
                source: .manual,
                revision: before.revision + 1,
                updatedAt: nowISOString()
            )
            expectedRevisions[entry.photoId] = before.revision
            collectors.decisionWrites.append(CullingDecisionWrite(
                sessionId: sessionId,
                photoId: entry.photoId,
                groupId: snapshot.groupMap[entry.photoId] ?? "ungrouped",
                state: CullingDecisionState(
                    decision: CullingAssembler.legacyDecision(after.pickState).rawValue,
                    rating: Int64(after.rating),
                    colorLabel: after.colorLabel.rawValue,
                    revision: Int64(after.revision)
                )
            ))
            if entry.patch.rating != nil {
                collectors.cachePatches.append(
                    CullingCachePatch(photoId: entry.photoId, rating: Int64(after.rating)))
            }
            if entry.patch.colorLabel != nil {
                collectors.cachePatches.append(
                    CullingCachePatch(photoId: entry.photoId, label: after.colorLabel.rawValue))
            }
            let xmpPath = TSPath.xmpSidecarPath(photo.filepath)
            var values = xmpPatches[xmpPath]?.values ?? [:]
            if entry.patch.rating != nil { values["rating"] = .number(after.rating) }
            if entry.patch.colorLabel != nil {
                values["label"] = .string(after.colorLabel == .none ? "" : after.colorLabel.rawValue)
            }
            if !values.isEmpty {
                xmpPatches[xmpPath] = (photoId: entry.photoId, values: values)
            }
            collectors.historyEntries.append(CullingHistoryEntry(
                photoId: entry.photoId,
                before: CullingStateSnapshot(
                    pickState: before.pickState, rating: before.rating, colorLabel: before.colorLabel
                ),
                after: CullingStateSnapshot(
                    pickState: after.pickState, rating: after.rating, colorLabel: after.colorLabel
                ),
                expectedRevision: after.revision,
                fields: historicalFields[entry.photoId] ?? CullingAssembler.fields(entry.patch)
            ))
            results.append(CullingUpdateResult(
                states: [after],
                xmpPath: xmpPath,
                syncStatus: outboxStatus(xmpPath)
            ))
        }
        for (photoId, values) in xmpPatches.values {
            collectors.outboxWrites.append(CullingOutboxWrite(
                sessionId: sessionId, photoId: photoId,
                values: values, source: .culling, schedule: false
            ))
        }

        // ---- 提交 ----
        if let conflict = try await commitDecisionWritesCAS(
            sessionId: sessionId,
            writes: collectors.decisionWrites,
            expectedRevisions: expectedRevisions
        ) {
            throw try await revisionConflictError(conflict, sessionId: sessionId)
        }
        try await commitOutboxWrites(collectors.outboxWrites)
        try await commitCachePatches(collectors.cachePatches)
        if let operationId = historyOperationId, let direction {
            try await setHistoryUndone(
                sessionId: sessionId, operationId: operationId, undone: direction == .undo
            )
        } else if let cullingStore = deps.cullingStore, !collectors.historyEntries.isEmpty {
            historyOperationId = try await cullingStore.appendHistory(
                sessionId: sessionId, entries: collectors.historyEntries
            ).id
        }
        for xmpPath in xmpPatches.keys {
            deps.metadataSync.schedule(xmpPath: xmpPath)
        }
        // queuePhotoValues 写 outbox（mergePatch 把状态 bump 到 pending），提交后再一次
        // 批量读刷新——返回状态必须反映写后行（一次会话级读，非每条目单行读）。
        for row in try await deps.writebackStore.outboxEntries(sessionId: sessionId) {
            outboxByPath[row.xmpPath] = row
        }
        for index in results.indices {
            results[index].syncStatus = outboxStatus(results[index].xmpPath)
            results[index].historyOperationId = historyOperationId
        }
        return results
    }

    // MARK: - 写路径：整组 keep/reject

    /// TS: decideSimilarityGroup —— 整组批量 keep/reject（K 保留 + 其余拒绝）。
    /// 组 id 与最新结果派生的完整 "resultId:index" 精确相等（旧结果的组 id 匹配不到）。
    public func decideGroup(
        sessionId: String,
        groupId: String,
        keepPhotoIds: [String]
    ) async throws -> [CullingUpdateResult] {
        let keep = try CullingQueryBuilder.validateKeepIds(keepPhotoIds)
        guard let resultRow = try await deps.similarityStore.latestResult(sessionId: sessionId) else {
            throw CullingServiceError.noSimilarity
        }
        let groupPhotoIds: [String]
        if let members = try await deps.similarityStore.groupMembers(
            sessionId: sessionId, resultId: resultRow.id
        ) {
            groupPhotoIds = members
                .filter { "\(resultRow.id):\($0.groupIndex)" == groupId }
                .map(\.photoId)
        } else {
            groupPhotoIds = []
        }
        if groupPhotoIds.count < 2 { throw CullingServiceError.groupTooSmall }

        var keepIds: [String] = []
        for photoId in keep where !keepIds.contains(photoId) {
            keepIds.append(photoId)
        }
        let groupIdSet = Set(groupPhotoIds)
        if keepIds.isEmpty || keepIds.count >= groupPhotoIds.count
            || keepIds.contains(where: { !groupIdSet.contains($0) }) {
            throw CullingServiceError.keepNotInGroup
        }
        let keepIdSet = Set(keepIds)
        let currentRows = Dictionary(
            uniqueKeysWithValues: try await (deps.cullingStore?.decisions(
                sessionId: sessionId, photoIds: groupPhotoIds) ?? []
            ).map { ($0.photoId, $0) }
        )
        return try await applyHistory(
            sessionId: sessionId,
            requestedEntries: groupPhotoIds.map { photoId in
                CullingHistoryApplyEntry(
                    photoId: photoId,
                    expectedRevision: Int(currentRows[photoId]?.revision ?? 0),
                    patch: CullingUpdatePatch(
                        pickState: keepIdSet.contains(photoId) ? .picked : .rejected
                    )
                )
            }
        )
    }

    // MARK: - 写路径：reset

    /// TS: reset —— 清空会话决策（可选按组）。
    public func reset(sessionId: String, groupId: String? = nil) async throws {
        guard let cullingStore = deps.cullingStore else { return }
        if let groupId {
            try await cullingStore.deleteDecisions(sessionId: sessionId, groupId: groupId)
        } else {
            try await cullingStore.deleteDecisions(sessionId: sessionId)
        }
    }

    /// TS: culling.reset（confirmed 必须为 true，否则 CULLING_RESET_CONFIRM_REQUIRED）。
    public func resetCommand(sessionId: String, groupId: String? = nil, confirmed: Bool) async throws {
        guard confirmed else { throw CullingServiceError.resetConfirmRequired }
        try await reset(sessionId: sessionId, groupId: groupId)
    }

    // MARK: - IPC 命令面（纯委托；culling.ipc.ts 逐命令对齐）

    public func syncStatus(sessionId: String) async throws -> MetadataSyncSummary {
        try await deps.metadataSync.getSummary(sessionId: sessionId)
    }

    public func flush(sessionId: String) async throws -> MetadataSyncSummary {
        try await deps.metadataSync.flushSession(sessionId: sessionId)
    }

    public func retrySync(sessionId: String) async throws -> MetadataSyncSummary {
        try await deps.metadataSync.retrySession(sessionId: sessionId)
    }

    public func finalizeSync(sessionId: String, confirmed: Bool) async throws -> MetadataSyncSummary {
        guard confirmed else { throw CullingServiceError.finalizeConfirmRequired }
        return try await deps.metadataSync.finalizeSession(sessionId: sessionId)
    }

    /// TS: culling.writeback —— 决策计划 → preview → 属性合并 → execute。
    /// 写回引擎由注入的 CullingWritebackPort 承担，本方法只组装计划与合并关键词。
    public func writeback(
        sessionId: String,
        target: CullingWritebackTarget,
        confirmed: Bool
    ) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackConfirmRequired }
        let decisions = try await deps.cullingStore?.decisions(sessionId: sessionId) ?? []
        let plan = buildCullingWritebackPlan(
            decisions: decisions.map { (photoId: $0.photoId, decision: $0.decision) },
            target: target
        )
        if plan.isEmpty { throw CullingServiceError.noDecisions }

        let decidedPhotoIds = Set(plan.keys)
        let preview = try await deps.writeback.preview(
            sessionId: sessionId,
            module: "culling",
            options: WritebackOptions(),
            photoIds: decidedPhotoIds,
            keywordAdditions: nil
        )
        var matchingItems = preview.items.filter { decidedPhotoIds.contains($0.photoId) }
        for index in matchingItems.indices {
            guard let attributes = plan[matchingItems[index].photoId],
                  matchingItems[index].id != nil else { continue }
            if let keywords = attributes.keywords {
                // TS: { keywords: [...new Set([...item.keywords, ...attributes.keywords])] }
                var merged: [String] = []
                for value in matchingItems[index].keywords + keywords
                where !merged.contains(value) {
                    merged.append(value)
                }
                matchingItems[index].attributes = WritebackAttributes(keywords: merged)
            } else {
                matchingItems[index].attributes = attributes
            }
        }
        try await deps.writeback.persistAttributes(items: matchingItems)
        return try await deps.writeback.execute(sessionId: sessionId, module: "culling", items: matchingItems)
    }

    public func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackRetryConfirmRequired }
        return try await deps.writeback.retryFailed(sessionId: sessionId, module: "culling")
    }

    /// TS: culling.confirm_sync —— 协调器确认 + 写回项存在时的写回确认。
    public func confirmSync(sessionId: String) async throws {
        _ = try await deps.metadataSync.confirmSync(sessionId: sessionId, sourceModule: "culling")
        if try await deps.writeback.getItems(sessionId: sessionId, module: "culling", status: nil).count > 0 {
            try await deps.writeback.confirmSync(sessionId: sessionId, module: "culling")
        }
    }

    /// TS: culling.cleanup（confirmed 必须为 true）—— 协调器清理 + 写回清理的并集。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        guard confirmed else { throw CullingServiceError.writebackCleanupConfirmRequired }
        let backgroundResult = try await deps.metadataSync.cleanup(sessionId: sessionId, sourceModule: "culling")
        let explicitResult = try await deps.writeback.cleanup(sessionId: sessionId, module: "culling")
        return CleanupResult(
            deletedCount: backgroundResult.deletedCount + explicitResult.deletedCount,
            errors: backgroundResult.errors + explicitResult.errors
        )
    }

    // MARK: - 会话照片 / 更新上下文（await 预读）

    /// TS: loadSessionPhotos —— 轻投影（重 JSON 列跳过）。旧实现的 try? → [] 静默降级
    /// 已按设计 §3.1 改为上抛：数据库错误绝不被当成「会话为空」。
    private func loadSessionPhotoRows(sessionId: String) async throws -> [CullingPhotoRow] {
        try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
            .map { CullingPhotoRow(row: $0) }
    }

    /// 版本键控的更新上下文（index_seq 即照片集版本，设计 §2）。
    /// freshReadOnMissing 为 true 时强制重读一次照片集（旧 refreshSessionUpdateContext
    /// 的一次性兜底；缓存条目按当前 index_seq 键覆盖）。
    private func updateContext(
        sessionId: String,
        freshReadOnMissing: Bool
    ) async throws -> (key: CullingSessionCache.UpdateKey, entry: CullingSessionCache.Update) {
        let indexSeq = try await deps.sessionStore.indexSeq(id: sessionId)
        let key = CullingSessionCache.UpdateKey(sessionId: sessionId, indexSeq: indexSeq)
        if !freshReadOnMissing, let cached = await cache.update(for: key) {
            return (key, cached)
        }
        let photos = try await loadSessionPhotoRows(sessionId: sessionId)
        let entry = CullingSessionCache.Update(photos: photos)
        await cache.store(entry, for: key)
        return (key, entry)
    }

    /// TS: ensureUpdateExtras —— 懒填充组索引与 xmp 联动映射。组索引按相似度结果
    /// 版本键控：结果替换即重建，绝不写旧结果的无主组 id。
    private func resolvedUpdateContext(
        sessionId: String,
        freshReadOnMissing: Bool
    ) async throws -> (key: CullingSessionCache.UpdateKey, entry: CullingSessionCache.Update) {
        var (key, entry) = try await updateContext(
            sessionId: sessionId, freshReadOnMissing: freshReadOnMissing
        )
        let lookup = try await sessionLookupEntry(sessionId: sessionId, photos: entry.photos)
        if entry.groupMap != nil && entry.groupMapResultId == lookup.entry.resultRow?.id {
            return (key, entry)
        }
        entry.groupMap = lookup.entry.groupIndex
        entry.groupMapResultId = lookup.entry.resultRow?.id
        entry.linkedByXmp = CullingAssembler.linkedByXmpIndex(entry.photos)
        await cache.store(entry, for: key)
        return (key, entry)
    }

    /// 版本键控会话查找条目（组索引已解析）。不装载分析映射（写路径不需要）。
    private func sessionLookupEntry(
        sessionId: String,
        photos: [CullingPhotoRow]
    ) async throws -> (key: CullingSessionCache.LookupKey, entry: CullingSessionCache.Lookup) {
        let indexSeq = try await deps.sessionStore.indexSeq(id: sessionId)
        let fetched = try await loader.loadSessionLookup(sessionId: sessionId)
        let key = CullingSessionCache.LookupKey(
            sessionId: sessionId,
            indexSeq: indexSeq,
            similarityResultId: fetched.resultRow?.id
        )
        var entry = await cache.lookup(for: key) ?? fetched
        if entry.resultRow?.id != fetched.resultRow?.id {
            // 版本键已含 resultId；防御性重建（绝不混用两个结果的缓存行）。
            entry = fetched
        }
        if !entry.groupIndexResolved {
            entry.groupIndex = CullingGroupIndex.build(photos: photos, resultRow: entry.resultRow)
            entry.groupIndexResolved = true
            await cache.store(entry, for: key)
        }
        return (key, entry)
    }

    /// 读路径的会话查找条目：在版本键控条目上按需装载分析映射（质量/人脸/人物）。
    private func cachedSessionLookup(
        sessionId: String,
        photos: [CullingPhotoRow]
    ) async throws -> CullingSessionCache.Lookup {
        let (key, entry) = try await sessionLookupEntry(sessionId: sessionId, photos: photos)
        guard !entry.analysesLoaded else { return entry }
        var updated = entry
        let analyses = try await loader.loadAnalyses(photos: photos, sessionId: sessionId, mode: .session)
        updated.analysesLoaded = true
        updated.qualityByPhoto = analyses.qualityByPhoto
        updated.facesByPhoto = analyses.facesByPhoto
        updated.analysisMaxByPhoto = analyses.analysisMaxByPhoto
        updated.peopleByPhoto = analyses.peopleByPhoto
        await cache.store(updated, for: key)
        return updated
    }

    /// list 的富查询装配（会话模式，分析映射命中缓存）。
    private func sessionAssetLookup(
        sessionId: String,
        photos: [CullingPhotoRow]
    ) async throws -> CullingAssetLookup {
        let entry = try await cachedSessionLookup(sessionId: sessionId, photos: photos)
        let decisions = try await loader.loadDecisions(photos: photos, sessionId: sessionId, mode: .session)
        let cacheRows = try await loader.loadMetadata(photoIds: photos.map(\.id))
        let outboxByPath = try await loader.loadOutbox(sessionId: sessionId, photos: photos, mode: .session)
        return CullingAssetLookup(
            decisions: decisions,
            cacheRows: cacheRows,
            outboxByPath: outboxByPath,
            similarityMap: entry.similarityMap,
            // TS 原地改对象引用；Swift 值类型按 photoId 回写（副本，不写回缓存）。
            qualityByPhoto: CullingAssembler.applyRelativeRank(
                entry.qualityByPhoto, similarityMap: entry.similarityMap),
            facesByPhoto: entry.facesByPhoto,
            analysisMaxByPhoto: entry.analysisMaxByPhoto,
            peopleByPhoto: entry.peopleByPhoto,
            linkedCounts: CullingLookupLoader.linkedCounts(photos)
        )
    }

    // MARK: - 同步临界区（无 await）

    /// TS: updateState —— 在预读快照上完成状态计算与写入收集，绝不 await。
    /// 受影响照片为 asset 变体（pick）或共享侧车（rating/label），保序同旧实现。
    private func performUpdate(
        sessionId: String,
        photoId: String,
        expectedRevision: Int,
        patch: CullingUpdatePatch,
        snapshot: CullingUpdateSnapshot,
        collectors: inout CullingWriteCollectors
    ) throws -> CullingUpdateOutcome {
        try CullingQueryBuilder.validatePatch(patch)
        guard let target = snapshot.photoById[photoId] ?? snapshot.photos.first(where: { $0.id == photoId })
        else {
            throw CullingServiceError.photoNotInSession
        }
        let currentRevision = Int(snapshot.decisionRows[photoId]?.revision ?? 0)
        if currentRevision != expectedRevision {
            throw CullingServiceError.revisionConflict(
                expected: expectedRevision, current: currentRevision
            )
        }

        let targetXmpPath = TSPath.xmpSidecarPath(target.filepath)
        let changesSharedMetadata = patch.rating != nil || patch.colorLabel != nil
        // 保序受影响集合：TS Map.set 保留首见位置（先资产变体，后共享侧车），
        // 结果状态数组的顺序依赖它。
        var affected: [CullingPhotoRow] = []
        var affectedSeen = Set<String>()
        func addAffected(_ photo: CullingPhotoRow) {
            if affectedSeen.insert(photo.id).inserted {
                affected.append(photo)
            }
        }
        if patch.pickState != nil, let assetId = target.assetId {
            for photo in snapshot.photosByAssetId[assetId] ?? [] {
                addAffected(photo)
            }
        } else {
            addAffected(target)
        }
        if changesSharedMetadata {
            for photo in snapshot.linkedByXmp[targetXmpPath] ?? [] {
                addAffected(photo)
            }
        }
        let pickTargets: Set<String> = patch.pickState != nil && target.assetId != nil
            ? Set((snapshot.photosByAssetId[target.assetId!] ?? []).map(\.id))
            : [target.id]

        var resultStates: [AssetCullingState] = []
        var beforeStates: [AssetCullingState] = []
        var expectedRevisions: [String: Int] = [:]
        var metadataPatch: [String: JSONValue] = [:]
        if let rating = patch.rating { metadataPatch["rating"] = .number(rating) }
        if let colorLabel = patch.colorLabel {
            // TS: colorLabel === 'None' → ''（写盘标签语义）。
            metadataPatch["label"] = .string(colorLabel == .none ? "" : colorLabel.rawValue)
        }

        for photo in affected {
            let existing = snapshot.decisionRows[photo.id]
            let cache = snapshot.cacheRows[photo.id]
            let existingState = CullingAssembler.state(
                photoId: photo.id, decision: existing, cache: cache
            )
            beforeStates.append(existingState)
            let isPickTarget = pickTargets.contains(photo.id)
            let nextPickState = isPickTarget && patch.pickState != nil
                ? patch.pickState!
                : existingState.pickState
            let nextRating = patch.rating ?? existingState.rating
            let nextColorLabel = patch.colorLabel ?? existingState.colorLabel
            let nextRevision = existingState.revision + 1
            expectedRevisions[photo.id] = existingState.revision

            collectors.decisionWrites.append(CullingDecisionWrite(
                sessionId: sessionId,
                photoId: photo.id,
                groupId: snapshot.groupMap[photo.id] ?? "ungrouped",
                state: CullingDecisionState(
                    decision: CullingAssembler.legacyDecision(nextPickState).rawValue,
                    rating: Int64(nextRating),
                    colorLabel: nextColorLabel.rawValue,
                    revision: Int64(nextRevision)
                )
            ))
            if patch.rating != nil {
                collectors.cachePatches.append(
                    CullingCachePatch(photoId: photo.id, rating: Int64(nextRating)))
            }
            if patch.colorLabel != nil {
                collectors.cachePatches.append(
                    CullingCachePatch(photoId: photo.id, label: nextColorLabel.rawValue))
            }
            resultStates.append(AssetCullingState(
                photoId: photo.id,
                pickState: nextPickState,
                rating: nextRating,
                colorLabel: nextColorLabel,
                source: .manual,
                revision: nextRevision,
                updatedAt: nowISOString()
            ))
        }

        let fields = CullingAssembler.fields(patch)
        let historyEntries: [CullingHistoryEntry] = resultStates.enumerated().map { index, after in
            let before = beforeStates[index]
            return CullingHistoryEntry(
                photoId: after.photoId,
                before: CullingStateSnapshot(
                    pickState: before.pickState, rating: before.rating, colorLabel: before.colorLabel
                ),
                after: CullingStateSnapshot(
                    pickState: after.pickState, rating: after.rating, colorLabel: after.colorLabel
                ),
                expectedRevision: after.revision,
                fields: fields
            )
        }
        if !metadataPatch.isEmpty {
            collectors.outboxWrites.append(CullingOutboxWrite(
                sessionId: sessionId,
                photoId: photoId,
                values: metadataPatch,
                source: .culling,
                schedule: false
            ))
        }
        if !historyEntries.isEmpty {
            collectors.historyEntries.append(contentsOf: historyEntries)
        }

        // outbox 行由 queuePhotoValues 在提交阶段写入；行状态由异步入口在提交后经
        // Store 刷新（此处只给保守默认值）。
        let syncStatus: MetadataSyncStatus = changesSharedMetadata ? .pending : .clean
        return CullingUpdateOutcome(
            result: CullingUpdateResult(
                states: resultStates,
                xmpPath: targetXmpPath,
                syncStatus: syncStatus
            ),
            expectedRevisions: expectedRevisions,
            scheduleXmpPaths: metadataPatch.isEmpty ? [] : [targetXmpPath]
        )
    }

    // MARK: - 提交（await）

    /// 单事务 CAS 决策写入。返回冲突（nil 即全部成功）。
    /// Store API 只接受单一 expectedRevision：按每照片基线分组，组内一次事务；
    /// 混合基线是正常形态（同一资产的变体 revision 各自演化），按基线升序提交，
    /// 任一组冲突立即停止并返回该组（已提交组不回滚——已知偏差，见文件头）。
    private func commitDecisionWritesCAS(
        sessionId: String,
        writes: [CullingDecisionWrite],
        expectedRevisions: [String: Int]
    ) async throws -> CullingDecisionCASConflict? {
        guard !writes.isEmpty else { return nil }
        guard let cullingStore = deps.cullingStore else { return nil }
        var groups: [Int: [CullingDecisionWrite]] = [:]
        for write in writes {
            let baseline = expectedRevisions[write.photoId] ?? Int(write.state.revision) - 1
            groups[baseline, default: []].append(write)
        }
        for baseline in groups.keys.sorted() {
            guard let group = groups[baseline] else { continue }
            let succeeded = try await cullingStore.applyDecisionStates(
                sessionId: sessionId, writes: group, expectedRevision: baseline
            )
            if !succeeded {
                return CullingDecisionCASConflict(expected: baseline, photoId: group[0].photoId)
            }
        }
        return nil
    }

    /// CAS 冲突 → 按真实 current revision 抛 CULLING_REVISION_CONFLICT（错误码逐字不变）。
    private func revisionConflictError(
        _ conflict: CullingDecisionCASConflict,
        sessionId: String
    ) async throws -> CullingServiceError {
        let current = try await deps.cullingStore?
            .decision(sessionId: sessionId, photoId: conflict.photoId)?.revision
        return CullingServiceError.revisionConflict(
            expected: conflict.expected,
            current: Int(current ?? Int64(conflict.expected))
        )
    }

    /// 事务外批量读 outbox 行（返回状态必须反映写后行）。
    private func refreshOutboxStatus(of result: inout CullingUpdateResult) async {
        do {
            if let row = try await deps.writebackStore.outboxEntry(xmpPath: result.xmpPath) {
                result.syncStatus = MetadataSyncStatus(rawValue: row.status) ?? result.syncStatus
            }
        } catch {
            // 决策与 outbox 已提交：行状态只是返回载荷的展示刷新，读失败保留保守默认值
            // （原实现的 try? 语义，此处显式忽略，不让成功写入对外报错）。
        }
    }

    private func commitOutboxWrites(_ writes: [CullingOutboxWrite]) async throws {
        for write in writes {
            _ = try await deps.metadataMutations.queuePhotoValues(
                sessionId: write.sessionId,
                photoId: write.photoId,
                values: write.values,
                source: write.source,
                schedule: write.schedule
            )
        }
    }

    private func commitCachePatches(_ patches: [CullingCachePatch]) async throws {
        for patch in patches {
            if let rating = patch.rating {
                try await deps.metadataStore.updateRating(photoId: patch.photoId, rating: rating)
            }
            if let label = patch.label {
                try await deps.metadataStore.updateLabel(photoId: patch.photoId, label: label)
            }
        }
    }

    private func appendHistory(_ entries: [CullingHistoryEntry], sessionId: String) async throws -> Int? {
        guard let cullingStore = deps.cullingStore, !entries.isEmpty else { return nil }
        return try await cullingStore.appendHistory(sessionId: sessionId, entries: entries).id
    }

    /// TS: historyOperation —— 损坏的历史载荷（historyCorrupt）在 Runtime 边界映射为
    /// historyNotFound（设计 §3.5）。
    private func loadHistoryOperation(
        sessionId: String,
        operationId: Int
    ) async throws -> CullingHistoryOperation? {
        guard let cullingStore = deps.cullingStore else { return nil }
        do {
            return try await cullingStore.historyOperation(sessionId: sessionId, operationId: operationId)
        } catch CullingStoreError.historyCorrupt {
            throw CullingServiceError.historyNotFound
        }
    }

    /// TS: setHistoryUndone —— Store 并发边界错误的 Runtime 映射（设计 §3.5）。
    private func setHistoryUndone(
        sessionId: String,
        operationId: Int,
        undone: Bool
    ) async throws {
        guard let cullingStore = deps.cullingStore else { return }
        do {
            try await cullingStore.setHistoryUndone(
                sessionId: sessionId, operationId: operationId, undone: undone
            )
        } catch CullingStoreError.undoNotLatest {
            throw CullingServiceError.historyAlreadyUndone
        } catch CullingStoreError.redoOutOfOrder {
            throw CullingServiceError.historyNotUndone
        } catch CullingStoreError.historyStale {
            throw CullingServiceError.historyDiverged
        }
    }

    // MARK: - 纯计算辅助（no await）

    /// 受影响照片超集（保序去重）：pick → 资产变体；rating/label → 共享侧车。
    /// 仅用于提交前预读（决策行 revision 基线 + 缓存行），顺序与 performUpdate 一致。
    private static func affectedPhotoIds(
        targets: [CullingPhotoRow],
        patch: CullingUpdatePatch,
        photosByAssetId: [String: [CullingPhotoRow]],
        linkedByXmp: [String: [CullingPhotoRow]]
    ) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        func add(_ photo: CullingPhotoRow) {
            if seen.insert(photo.id).inserted { ids.append(photo.id) }
        }
        for target in targets {
            if patch.pickState != nil, let assetId = target.assetId {
                for photo in photosByAssetId[assetId] ?? [] { add(photo) }
            } else {
                add(target)
            }
            if patch.rating != nil || patch.colorLabel != nil {
                for photo in linkedByXmp[TSPath.xmpSidecarPath(target.filepath)] ?? [] {
                    add(photo)
                }
            }
        }
        return ids
    }

    /// TS: batchUpdate 的操作 id 合并 —— pick 按逻辑资产、shared metadata 按共享侧车。
    private static func operationIds(
        uniqueIds: [String],
        patch: CullingUpdatePatch,
        photoById: [String: CullingPhotoRow]
    ) -> [String] {
        var operationIds: [String] = []
        var operationKeys: Set<String> = []
        for photoId in uniqueIds {
            guard let photo = photoById[photoId] else { continue }
            let key = patch.pickState == nil
                ? TSPath.xmpSidecarPath(photo.filepath)
                : (photo.assetId ?? "photo:\(photo.id)")
            if operationKeys.insert(key).inserted {
                operationIds.append(photoId)
            }
        }
        return operationIds
    }

    private static func makeSnapshot(
        entry: CullingSessionCache.Update,
        rows: (decisionRows: [String: CullingDecisionRecord], cacheRows: [String: MetadataCacheRecord])
    ) -> CullingUpdateSnapshot {
        CullingUpdateSnapshot(
            photos: entry.photos,
            photoById: entry.photoById,
            photosByAssetId: entry.photosByAssetId,
            groupMap: entry.groupMap ?? [:],
            linkedByXmp: entry.linkedByXmp ?? [:],
            cacheRows: rows.cacheRows,
            decisionRows: rows.decisionRows
        )
    }

    /// 按 scope 计数（total 与页面同源）。不可解析的相似度组 id 回退 JS 相似度映射
    /// 计数（旧 countForScope 的 JS 分支，与页面 JS 过滤同源）。
    private func countForRequest(
        request: CullingPageRequest,
        similarityMap: [String: String]
    ) async throws -> Int {
        if request.postFilter.scope == .similarityGroup,
           let requestedGroupId = request.postFilter.requestedGroupId,
           CullingQueryBuilder.parseSimilarityGroupId(requestedGroupId) == nil {
            return similarityMap.values.filter { $0 == requestedGroupId }.count
        }
        return try await deps.queryStore.countAssetGroups(CullingQueryBuilder.countQuery(request))
    }

    /// 受影响超集的决策行 + 元数据缓存行（一次批量读；Store 内部分块）。
    private func loadUpdateRows(
        sessionId: String,
        photoIds: [String]
    ) async throws -> (decisionRows: [String: CullingDecisionRecord], cacheRows: [String: MetadataCacheRecord]) {
        let decisionRows: [String: CullingDecisionRecord]
        if let cullingStore = deps.cullingStore {
            decisionRows = Dictionary(
                uniqueKeysWithValues: try await cullingStore.decisions(
                    sessionId: sessionId, photoIds: photoIds
                ).map { ($0.photoId, $0) }
            )
        } else {
            decisionRows = [:]
        }
        let cacheRows = try await loader.loadMetadata(photoIds: photoIds)
        return (decisionRows, cacheRows)
    }
}
