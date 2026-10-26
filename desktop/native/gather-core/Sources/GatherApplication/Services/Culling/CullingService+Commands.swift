// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Commands.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// 写命令：update/batch/history/decide/reset 与补丁校验。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    /// TS: updateState —— 单张照片状态更新（pick/rating/colorLabel），受影响
    /// 照片为 asset 变体（pick）或共享侧车（shared metadata）。
    @discardableResult
    public func updateState(
        sessionId: String,
        photoId: String,
        expectedRevision: Int,
        patch: CullingUpdatePatch,
        context: CullingUpdateContext? = nil
    ) throws -> CullingUpdateResult {
        try validatePatch(patch)
        let entry = try getSessionUpdateContext(sessionId: sessionId)
        var photos = context?.photos ?? entry.photos
        var photoById = context?.photoById ?? entry.photoById
        var contextGroupMap = context?.groupMap
        var contextLinkedByXmp = context?.linkedByXmp
        var contextPhotosByAssetId = context?.photosByAssetId
        let target: CullingPhotoRow
        if let initial = photoById[photoId] ?? photos.first(where: { $0.id == photoId }) {
            target = initial
        } else {
            // TTL 缓存的照片集合可能缺索引器刚加的照片，每次窗口先试一次新鲜读
            //（见 refreshSessionUpdateContext）。陈旧的调用方上下文被丢弃。
            try refreshSessionUpdateContext(sessionId: sessionId, entry: entry)
            photos = entry.photos
            photoById = entry.photoById
            contextGroupMap = nil
            contextLinkedByXmp = nil
            contextPhotosByAssetId = nil
            guard let refreshed = photoById[photoId] ?? photos.first(where: { $0.id == photoId }) else {
                throw CullingServiceError.photoNotInSession
            }
            target = refreshed
        }

        let currentRow = try cullingDecisionRepo.getDecision(sessionId: sessionId, photoId: photoId)
        let currentRevision = currentRow?.revision ?? 0
        if currentRevision != Int64(expectedRevision) {
            throw CullingServiceError.revisionConflict(
                expected: expectedRevision, current: Int(currentRevision)
            )
        }

        let targetXmpPath = DeliveryPath.sidecar(target.filepath)
        let changesSharedMetadata = patch.rating != nil || patch.colorLabel != nil
        // 完整的调用方上下文（IPC/batch）已过 ensureUpdateExtras；只有直连路径与
        // 新鲜读回退（丢弃了上下文映射）之后才需要按点击做版本检查。
        if contextGroupMap == nil {
            try ensureUpdateExtras(entry: entry, sessionId: sessionId)
        }
        let photosByAssetId = contextPhotosByAssetId ?? entry.photosByAssetId
        // 保序受影响集合：TS Map.set 保留首见位置（先资产变体，后共享侧车），
        // 结果状态数组的顺序依赖它。
        var affectedById: [(id: String, photo: CullingPhotoRow)] = []
        var affectedSeen = Set<String>()
        func addAffected(_ photo: CullingPhotoRow) {
            if affectedSeen.insert(photo.id).inserted {
                affectedById.append((photo.id, photo))
            }
        }
        if patch.pickState != nil, let assetId = target.assetId {
            for photo in photosByAssetId[assetId] ?? [] {
                addAffected(photo)
            }
        } else {
            addAffected(target)
        }
        if changesSharedMetadata {
            let linkedByXmp = contextLinkedByXmp ?? entry.linkedByXmp ?? [:]
            for photo in linkedByXmp[targetXmpPath] ?? [] {
                addAffected(photo)
            }
        }
        let affectedPhotos = affectedById.map(\.photo)
        let pickTargets: Set<String> = patch.pickState != nil && target.assetId != nil
            ? Set((photosByAssetId[target.assetId!] ?? []).map(\.id))
            : [target.id]
        let groupMap = contextGroupMap ?? entry.groupMap!
        var resultStates: [AssetCullingState] = []
        var beforeStates: [AssetCullingState] = []
        var historyOperationId: Int?
        var metadataPatch: [String: JSONValue] = [:]
        if let rating = patch.rating { metadataPatch["rating"] = .number(rating) }
        if let colorLabel = patch.colorLabel {
            // TS: colorLabel === 'None' → ''（写盘标签语义）。
            metadataPatch["label"] = .string(colorLabel == .none ? "" : colorLabel.rawValue)
        }

        try transactions.transaction {
            let existingRows = Dictionary(
                uniqueKeysWithValues: try cullingDecisionRepo
                    .getByPhotoIds(sessionId: sessionId, photoIds: affectedPhotos.map(\.id))
                    .map { ($0.photoId, $0) }
            )
            let cacheRows = Dictionary(
                uniqueKeysWithValues: try metadataCacheRepo
                    .getBatch(affectedPhotos.map(\.id))
                    .map { ($0.photoId, $0) }
            )

            for photo in affectedPhotos {
                let existing = existingRows[photo.id]
                let cache = cacheRows[photo.id]
                let existingState = rowToState(
                    photoId: photo.id, decisionRow: existing,
                    cachedRating: cache?.rating ?? 0, cachedLabel: cache?.label
                )
                beforeStates.append(existingState)
                let isPickTarget = pickTargets.contains(photo.id)
                let nextPickState = isPickTarget && patch.pickState != nil
                    ? patch.pickState!
                    : existingState.pickState
                let nextRating = patch.rating ?? existingState.rating
                let nextColorLabel = patch.colorLabel ?? existingState.colorLabel
                let nextRevision = existingState.revision + 1

                // 决策行的 rating/color_label 只是镜像列：真相源是同一事务里紧接着
                // 写入的 photo_metadata_cache（读取路径从不读这两列）。
                try cullingDecisionRepo.upsertState(
                    sessionId: sessionId,
                    photoId: photo.id,
                    groupId: groupMap[photo.id] ?? "ungrouped",
                    state: CullingDecisionStateInput(
                        decision: pickStateToDecision(nextPickState).rawValue,
                        rating: Int64(nextRating),
                        colorLabel: nextColorLabel.rawValue,
                        revision: Int64(nextRevision)
                    )
                )
                if patch.rating != nil {
                    try metadataCacheRepo.updateRating(photoId: photo.id, rating: Int64(nextRating))
                }
                if patch.colorLabel != nil {
                    try metadataCacheRepo.updateLabel(photoId: photo.id, label: nextColorLabel.rawValue)
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

            let fields = patch.fields
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
                // 不再由 CullingService 直连 sync 端口排程：排程随变更入队
                // （MetadataMutationService 的 schedule=true）走同一条写回链。
                _ = try metadataMutations.queuePhotoValues(
                    sessionId: sessionId,
                    photoId: photoId,
                    values: metadataPatch,
                    source: .culling,
                    schedule: true
                )
            }
            if !historyEntries.isEmpty {
                if let sink = context?.historySink {
                    sink.append(historyEntries)
                } else if let cullingHistoryRepo {
                    historyOperationId = try cullingHistoryRepo.append(
                        sessionId: sessionId, entries: historyEntries
                    ).id
                }
            }
        }

        // S5c-2b-3b-2a：交付行是同步态的优先读模型（写回执行器直接维护它）；
        // 手动 rating/label 仍走旧 mutation 队列，交付行出现前用旧行兜底，
        // 2b 手动队列迁入交付后删除兜底（不让徽标在写入前谎报 clean）。
        let syncStatus = try currentSyncStatus(
            xmpPath: targetXmpPath,
            fallback: changesSharedMetadata ? .pending : .clean
        )
        return CullingUpdateResult(
            states: resultStates,
            xmpPath: targetXmpPath,
            syncStatus: syncStatus,
            historyOperationId: historyOperationId
        )
    }
    /// TS: batchUpdate —— 批量更新；pick 按逻辑资产合并、shared metadata 按
    /// 共享侧车合并，整批单事务。
    public func batchUpdate(
        sessionId: String,
        photoIds: [String],
        patch: CullingUpdatePatch
    ) throws -> [CullingUpdateResult] {
        try validatePatch(patch)
        var uniqueIds: [String] = []
        for photoId in photoIds where !uniqueIds.contains(photoId) {
            uniqueIds.append(photoId)
        }
        if uniqueIds.isEmpty { throw CullingServiceError.emptySelection }
        if uniqueIds.count > Self.batchMax { throw CullingServiceError.tooManyPhotoIds }
        let entry = try getSessionUpdateContext(sessionId: sessionId)
        // 先在缓存索引里校验照片 id（任何相似度读之前，见 ensureUpdateExtras）。
        // 缺失可能是索引器刚加的照片（TTL 缓存不可见），先试一次新鲜读再拒绝。
        if uniqueIds.contains(where: { entry.photoById[$0] == nil }) {
            try refreshSessionUpdateContext(sessionId: sessionId, entry: entry)
            if uniqueIds.contains(where: { entry.photoById[$0] == nil }) {
                throw CullingServiceError.photosNotInSession
            }
        }
        try ensureUpdateExtras(entry: entry, sessionId: sessionId)
        let photos = entry.photos
        let photoById = entry.photoById
        let groupMap = entry.groupMap ?? [:]
        let linkedByXmp = entry.linkedByXmp ?? [:]
        // pick 更新按逻辑资产合并（同一资产的变体只更新一次），否则按共享侧车
        // 合并（RAW+JPEG 对的 rating/label 一次入队）。
        var operationIds: [String] = []
        var operationKeys: Set<String> = []
        for photoId in uniqueIds {
            // 上面已校验并刷新过上下文；这里仍显式处理，禁止对外部数据强解包。
            guard let photo = photoById[photoId] else {
                throw CullingServiceError.photosNotInSession
            }
            let key = patch.pickState == nil
                ? DeliveryPath.sidecar(photo.filepath)
                : (photo.assetId ?? "photo:\(photo.id)")
            if operationKeys.insert(key).inserted {
                operationIds.append(photoId)
            }
        }
        var results: [CullingUpdateResult] = []
        let historySink = CullingHistorySink()
        // 一次 IN 查询预读全部操作目标的决策行，替代事务内逐项 getDecision
        //（N+1 单行查询）。预读与事务在同一同步 tick 内，且每个照片每批最多写
        // 一次（操作 id 按逻辑资产/侧车唯一），故预读的 revision 不会过期。
        let currentRows = Dictionary(
            uniqueKeysWithValues: try cullingDecisionRepo
                .getByPhotoIds(sessionId: sessionId, photoIds: operationIds)
                .map { ($0.photoId, $0) }
        )
        try transactions.transaction {
            for photoId in operationIds {
                let current = currentRows[photoId]
                results.append(try updateState(
                    sessionId: sessionId,
                    photoId: photoId,
                    expectedRevision: Int(current?.revision ?? 0),
                    patch: patch,
                    context: CullingUpdateContext(
                        photos: photos,
                        photoById: photoById,
                        photosByAssetId: entry.photosByAssetId,
                        groupMap: groupMap,
                        linkedByXmp: linkedByXmp,
                        historySink: historySink
                    )
                ))
            }
            if !historySink.entries.isEmpty {
                if let operationId = try cullingHistoryRepo?.append(
                    sessionId: sessionId, entries: historySink.entries
                ).id {
                    for index in results.indices {
                        results[index].historyOperationId = operationId
                    }
                }
            }
        }
        return results
    }
    /// P1-9：把本次 update/batchUpdate/applyHistory 入队的 metadata 意图立即写盘。
    /// service 方法保持同步（与旧契约一致），由 async 的 API 层在返回前调用。
    public func flushQueuedMetadata(sessionId: String) async throws {
        try await flushMetadata?(sessionId)
    }

    /// TS: applyHistory —— 应用显式条目（renderer 重建的补丁）或历史栈操作
    /// （undo/redo，按操作 id 解析 entries）；带操作 id 时校验并发边界。
    /// 注：TS 参数 `historyOperationId` 在函数内被重新赋值（append 结果），
    /// 故 Swift 侧为 var。
    @discardableResult
    public func applyHistory(
        sessionId: String,
        requestedEntries: [CullingHistoryApplyEntry],
        historyOperationId: Int? = nil,
        direction: CullingHistoryDirection? = nil,
        source: CullingDecisionSource = .manual
    ) throws -> [CullingUpdateResult] {
        var historyOperationId = historyOperationId
        var entries = requestedEntries
        var historicalFields: [String: [CullingUpdatePatchField]] = [:]
        if let historyOperationId, let direction {
            guard let operation = try cullingHistoryRepo?.get(sessionId: sessionId, operationId: historyOperationId) else {
                throw CullingServiceError.historyNotFound
            }
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
                    patch: patchFromSnapshot(
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
        for entry in entries { try validatePatch(entry.patch) }
        let updateEntry = try getSessionUpdateContext(sessionId: sessionId)
        // 与 updateState/batchUpdate 相同的 fresh-read 兜底：索引器刚加的照片
        // 可能缺席 TTL 缓存。
        if entries.contains(where: { updateEntry.photoById[$0.photoId] == nil }) {
            try refreshSessionUpdateContext(sessionId: sessionId, entry: updateEntry)
        }
        let photoById = updateEntry.photoById
        // 历史载荷是**外部数据**（库行里的 operation_json，可能残留已删除照片的 id：
        // 迁移去重、用户删片）。禁止强解包，也禁止静默整条丢弃：
        // - 历史重放（undo/redo）→ 跳过缺失照片的条目，其余条目照常应用并记 warn；
        // - 直接调用（renderer 重建补丁）→ 契约错误 CULLING_PHOTO_NOT_IN_SESSION。
        // 存在性以**库**为准（photos.session_id），不依赖可能过期的 TTL 上下文：
        // 被删照片仍留在缓存里会让分歧判定误报，整条 undo 无谓失败。
        let existingPhotoIds = try existingSessionPhotoIds(
            sessionId: sessionId, photoIds: entries.map(\.photoId)
        )
        var applicableEntries: [CullingHistoryApplyEntry] = []
        var skippedHistoryPhotoIds: [String] = []
        for entry in entries {
            guard existingPhotoIds.contains(entry.photoId) else {
                if historyOperationId != nil {
                    skippedHistoryPhotoIds.append(entry.photoId)
                    continue
                }
                throw CullingServiceError.photoNotInSession
            }
            applicableEntries.append(entry)
        }
        if !skippedHistoryPhotoIds.isEmpty {
            GatherLogger.log(
                "culling.apply_history 跳过 \(skippedHistoryPhotoIds.count) 条照片已不存在的历史条目："
                    + skippedHistoryPhotoIds.joined(separator: ","),
                level: .warn
            )
        }
        if applicableEntries.isEmpty {
            // 全部条目都已失效：给出可读的分歧错误（「重置挑片」是清栈出口），
            // 绝不静默成功把栈推到无法解释的状态。
            throw CullingServiceError.historyDiverged
        }
        let currentRows = Dictionary(
            uniqueKeysWithValues: try cullingDecisionRepo
                .getByPhotoIds(sessionId: sessionId, photoIds: applicableEntries.map(\.photoId))
                .map { ($0.photoId, $0) }
        )
        let cacheRows = Dictionary(
            uniqueKeysWithValues: try metadataCacheRepo
                .getBatch(applicableEntries.map(\.photoId))
                .map { ($0.photoId, $0) }
        )
        for entry in applicableEntries {
            let currentRevision = currentRows[entry.photoId]?.revision ?? 0
            if historyOperationId == nil && currentRevision != Int64(entry.expectedRevision) {
                throw CullingServiceError.revisionConflict(
                    expected: entry.expectedRevision, current: Int(currentRevision)
                )
            }
        }
        if let historyOperationId, let direction {
            let operation = try cullingHistoryRepo?.get(sessionId: sessionId, operationId: historyOperationId)
            for historical in operation?.entries ?? [] {
                // 与上面的跳过规则一致：照片已不存在的历史条目不参与分歧判定
                //（否则会误报 CULLING_HISTORY_DIVERGED，让可应用的其余条目一起失败）。
                guard existingPhotoIds.contains(historical.photoId) else { continue }
                let row = currentRows[historical.photoId]
                let cache = cacheRows[historical.photoId]
                let current = rowToState(
                    photoId: historical.photoId, decisionRow: row,
                    cachedRating: cache?.rating ?? 0, cachedLabel: cache?.label
                )
                let expected = direction == .undo ? historical.after : historical.before
                for field in historical.fields {
                    if !matchesSnapshot(state: current, snapshot: expected, field: field) {
                        throw CullingServiceError.historyDiverged
                    }
                }
            }
        }
        try ensureUpdateExtras(entry: updateEntry, sessionId: sessionId)
        let groupMap = updateEntry.groupMap ?? [:]

        // 每会话批量读一次而非每条目两次（1 万次 undo 就是 2 万次单行查询）：
        // 同步态只读交付行；无交付（手动队列尚未落交付）时按 .clean 呈现，
        // 2b-2 手动队列迁入交付后该默认值即唯一语义。
        let deliveryByPath = try deliveryItems.getMany(
            xmpPaths: photoById.values.map { DeliveryPath.sidecar($0.filepath) }
        )
        func deliveryStatus(_ xmpPath: String) -> MetadataSyncStatus {
            if let status = deliveryByPath[xmpPath]?.typedStatus {
                return Self.syncStatus(from: status)
            }
            return .clean
        }

        var results: [CullingUpdateResult] = []
        var historyEntries: [CullingHistoryEntry] = []
        var xmpPatches: [String: (photoId: String, values: [String: JSONValue])] = [:]
        try transactions.transaction {
            for entry in applicableEntries {
                // applicableEntries 已保证照片存在；仍显式处理（外部数据不强解包）。
                guard let photo = photoById[entry.photoId] else { continue }
                let existing = currentRows[entry.photoId]
                let cache = cacheRows[entry.photoId]
                let before = rowToState(
                    photoId: entry.photoId, decisionRow: existing,
                    cachedRating: cache?.rating ?? 0, cachedLabel: cache?.label
                )
                let after = AssetCullingState(
                    photoId: entry.photoId,
                    pickState: entry.patch.pickState ?? before.pickState,
                    rating: entry.patch.rating ?? before.rating,
                    colorLabel: entry.patch.colorLabel ?? before.colorLabel,
                    source: source,
                    revision: before.revision + 1,
                    updatedAt: nowISOString()
                )
                // rating/color_label 是镜像列（真相源为紧随其后的 cache 写入）。
                try cullingDecisionRepo.upsertState(
                    sessionId: sessionId,
                    photoId: entry.photoId,
                    groupId: groupMap[entry.photoId] ?? "ungrouped",
                    state: CullingDecisionStateInput(
                        decision: pickStateToDecision(after.pickState).rawValue,
                        rating: Int64(after.rating),
                        colorLabel: after.colorLabel.rawValue,
                        revision: Int64(after.revision),
                        source: source.rawValue
                    )
                )
                if entry.patch.rating != nil {
                    try metadataCacheRepo.updateRating(photoId: entry.photoId, rating: Int64(after.rating))
                }
                if entry.patch.colorLabel != nil {
                    try metadataCacheRepo.updateLabel(photoId: entry.photoId, label: after.colorLabel.rawValue)
                }
                let xmpPath = DeliveryPath.sidecar(photo.filepath)
                var values = xmpPatches[xmpPath]?.values ?? [:]
                if entry.patch.rating != nil { values["rating"] = .number(after.rating) }
                if entry.patch.colorLabel != nil {
                    values["label"] = .string(after.colorLabel == .none ? "" : after.colorLabel.rawValue)
                }
                if !values.isEmpty {
                    xmpPatches[xmpPath] = (photoId: entry.photoId, values: values)
                }
                historyEntries.append(CullingHistoryEntry(
                    photoId: entry.photoId,
                    before: CullingStateSnapshot(
                        pickState: before.pickState, rating: before.rating, colorLabel: before.colorLabel
                    ),
                    after: CullingStateSnapshot(
                        pickState: after.pickState, rating: after.rating, colorLabel: after.colorLabel
                    ),
                    expectedRevision: after.revision,
                    fields: historicalFields[entry.photoId] ?? entry.patch.fields
                ))
                results.append(CullingUpdateResult(
                    states: [after],
                    xmpPath: xmpPath,
                    syncStatus: deliveryStatus(xmpPath)
                ))
            }
            for (photoId, values) in xmpPatches.values {
                // 排程随入队（不再由 CullingService 直连 sync 端口）。
                _ = try metadataMutations.queuePhotoValues(
                    sessionId: sessionId,
                    photoId: photoId,
                    values: values,
                    source: .culling,
                    schedule: true
                )
            }
            if let historyOperationId, let direction {
                try cullingHistoryRepo?.setUndone(
                    sessionId: sessionId,
                    operationId: historyOperationId,
                    undone: direction == .undo
                )
            } else if let cullingHistoryRepo, !historyEntries.isEmpty {
                historyOperationId = try cullingHistoryRepo.append(
                    sessionId: sessionId, entries: historyEntries
                ).id
            }
        }
        // 交付行不随手动队列变化（queuePhotoValues 仍写旧 outbox，2b-2 迁移），
        // 因此预读的交付快照就是本次返回的同步态；不再回读 outbox。
        for index in results.indices {
            results[index].historyOperationId = historyOperationId
        }
        return results
    }
    /// TS: decideSimilarityGroup —— 整组批量 keep/reject（K 保留 + 其余拒绝）。
    public func decideSimilarityGroup(
        sessionId: String,
        groupId: String,
        keepPhotoIds: [String]
    ) throws -> [CullingUpdateResult] {
        guard keepPhotoIds.count <= Self.batchMax else { throw CullingServiceError.tooManyKeepPhotoIds }
        guard let resultRow = try similarityResultRepo.getLatest(sessionId: sessionId) else {
            throw CullingServiceError.noSimilarity
        }
        // TS: `[...membership.entries()].filter(...)` —— Map 插入序即成员表行序；
        // Swift 侧经 getGroupMembers（ORDER BY m.rowid）保持同一顺序；组 id 与
        // 最新结果派生的完整 "resultId:index" 精确相等（旧结果的组 id 匹配不到）。
        let groupPhotoIds: [String]
        if let members = try similarityResultRepo.getGroupMembers(sessionId: sessionId, resultId: resultRow.id) {
            groupPhotoIds = members
                .filter { "\(resultRow.id):\($0.groupIndex)" == groupId }
                .map(\.photoId)
        } else {
            groupPhotoIds = []
        }
        if groupPhotoIds.count < 2 { throw CullingServiceError.groupTooSmall }

        var keepIds: [String] = []
        for photoId in keepPhotoIds where !keepIds.contains(photoId) {
            keepIds.append(photoId)
        }
        let groupIdSet = Set(groupPhotoIds)
        if keepIds.isEmpty || keepIds.count >= groupPhotoIds.count
            || keepIds.contains(where: { !groupIdSet.contains($0) }) {
            throw CullingServiceError.keepNotInGroup
        }
        let keepIdSet = Set(keepIds)
        let currentRows = Dictionary(
            uniqueKeysWithValues: try cullingDecisionRepo
                .getByPhotoIds(sessionId: sessionId, photoIds: groupPhotoIds)
                .map { ($0.photoId, $0) }
        )
        return try applyHistory(
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
    /// TS: decide —— 旧版 renderer 的单张决策命令。
    public func decide(sessionId: String, photoId: String, decision: CullingDecisionValue) throws {
        let current = try cullingDecisionRepo.getDecision(sessionId: sessionId, photoId: photoId)
        try updateState(
            sessionId: sessionId,
            photoId: photoId,
            expectedRevision: Int(current?.revision ?? 0),
            patch: CullingUpdatePatch(pickState: decisionToPickState(decision))
        )
    }

    /// TS: batchDecide —— 旧版 renderer 的批量决策命令。
    public func batchDecide(sessionId: String, photoIds: [String], decision: CullingDecisionValue) throws {
        _ = try batchUpdate(
            sessionId: sessionId,
            photoIds: photoIds,
            patch: CullingUpdatePatch(pickState: decisionToPickState(decision))
        )
    }
    /// TS: reset —— 清空会话决策（可选按组）。
    ///
    /// 「挑片状态」= 取舍决策行 + 唯一真相源里的星级/色标投影 + 触及这些照片的
    /// 历史操作，三者必须一起清（旧实现只删决策行 → 页面仍显示旧星级、summary
    /// 仍报 rated/labeled）。单事务；只改 Gather 数据库，不写 XMP、不删文件：
    /// 磁盘上的外部值不变，后续导入扫描按 XMP 重建投影属预期。
    public func reset(sessionId: String, groupId: String? = nil) throws {
        try transactions.transaction {
            let photoIds: [String]
            if let groupId {
                photoIds = try cullingDecisionRepo.deleteBySessionAndGroup(
                    sessionId: sessionId, groupId: groupId)
            } else {
                photoIds = try cullingDecisionRepo.deleteBySession(sessionId)
            }
            guard !photoIds.isEmpty else { return }
            try clearCullingProjection(photoIds: photoIds)
            try cullingHistoryRepo?.deleteOperationsTouching(
                sessionId: sessionId, photoIds: Set(photoIds)
            )
        }
        // 决策行/历史变了：照片级更新上下文整体失效一次（下次访问重建）。
        sessionUpdateCache.removeValue(forKey: sessionId)
    }

    /// 撤回挑片对唯一真相源（photo_metadata_cache 的 rating/label）的投影。
    /// 只清这两个字段，不触碰 cached_at（缓存新鲜度标记留给导入扫描判断）。
    private func clearCullingProjection(photoIds: [String]) throws {
        try richQuery.clearCullingProjection(photoIds: photoIds)
    }
    /// TS: culling.reset（confirmed 必须为 true，否则
    /// CULLING_RESET_CONFIRM_REQUIRED）。
    public func resetCommand(sessionId: String, groupId: String? = nil, confirmed: Bool) throws {
        guard confirmed else { throw CullingServiceError.resetConfirmRequired }
        try reset(sessionId: sessionId, groupId: groupId)
    }
    /// TS: validatePatch —— 补丁校验；rating/pickState/colorLabel 的非法值是
    /// bug 守卫（renderer 只用共享常量构造补丁，ADR-017）。
    private func validatePatch(_ patch: CullingUpdatePatch) throws {
        if patch.rating == nil && patch.pickState == nil && patch.colorLabel == nil {
            throw CullingServiceError.patchInvalid
        }
        if let rating = patch.rating,
           !(rating.rounded() == rating && (0...5).contains(rating)) {
            throw CullingServiceError.ratingOutOfRange
        }
        if let pickState = patch.pickState,
           ![PickState.unreviewed, .picked, .rejected].contains(pickState) {
            throw CullingServiceError.invalidPickState
        }
        if let colorLabel = patch.colorLabel, !Self.colorLabels.contains(colorLabel) {
            throw CullingServiceError.invalidColorLabel
        }
    }
    /// TS: decisionToPickState（CullingDecisionValue 入参版，decide/batchDecide）。
    private func decisionToPickState(_ decision: CullingDecisionValue) -> PickState {
        switch decision {
        case .keep: .picked
        case .reject: .rejected
        case .pending: .unreviewed
        }
    }

    /// TS: pickStateToDecision。
    private func pickStateToDecision(_ pickState: PickState) -> CullingDecisionValue {
        switch pickState {
        case .picked: .keep
        case .rejected: .reject
        case .unreviewed: .pending
        }
    }
    /// TS: `Object.fromEntries(fields.map(field => [field, snapshot[field]]))`。
    private func patchFromSnapshot(
        fields: [CullingUpdatePatchField],
        snapshot: CullingStateSnapshot
    ) -> CullingUpdatePatch {
        var patch = CullingUpdatePatch()
        for field in fields {
            switch field {
            case .rating: patch.rating = snapshot.rating
            case .pickState: patch.pickState = snapshot.pickState
            case .colorLabel: patch.colorLabel = snapshot.colorLabel
            }
        }
        return patch
    }

    /// TS: applyHistory 的 `current[field] !== expected[field]` 分歧比较。
    private func matchesSnapshot(
        state: AssetCullingState,
        snapshot: CullingStateSnapshot,
        field: CullingUpdatePatchField
    ) -> Bool {
        switch field {
        case .rating: state.rating == snapshot.rating
        case .pickState: state.pickState == snapshot.pickState
        case .colorLabel: state.colorLabel == snapshot.colorLabel
        }
    }
}
