// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Actions.swift
// Cut 4 / 4c-2a：挑片决策 / 选择 / 翻页 / 历史撤销重做（原 CullingView.swift 690-1284 行）。
// 历史窗口常量 historyWindow（原 744-746）随加载路径移到 +Load。
import Foundation
import GatherProtocol

extension CullingViewModel {
    private func applyDecisionStates(_ states: [AssetCullingState]) {
        guard let page else { return }
        // 共享 sidecar 的跨 chunk 更新可能重复返回同一照片；用覆盖合并而不是
        // Dictionary(uniqueKeysWithValues:)（后者遇到重复键会直接 trap）。
        var byId: [String: AssetCullingState] = [:]
        for state in states { byId[state.photoId] = state }
        var assets = page.assets
        for index in assets.indices where byId[assets[index].photo.id] != nil {
            assets[index].state = byId[assets[index].photo.id]!
        }
        pageVersion += 1
        self.page = CullingPage(
            assets: assets,
            total: page.total,
            nextCursor: page.nextCursor
        )
    }


    private func markHistoryOperation(_ id: Int, undone: Bool) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let operation = history[index]
        history[index] = CullingHistoryOperation(
            id: operation.id,
            sessionId: operation.sessionId,
            entries: operation.entries,
            undone: undone,
            createdAt: operation.createdAt
        )
    }

    private func prependHistoryOperation(
        id: Int,
        photoIds: [String],
        beforeByPhoto: [String: CullingStateSnapshot],
        afterByPhoto: [String: CullingStateSnapshot],
        revisionsByPhoto: [String: Int],
        fields: [CullingUpdatePatchField]
    ) {
        let entries: [CullingHistoryEntry] = photoIds.compactMap { photoId in
            guard let before = beforeByPhoto[photoId], let after = afterByPhoto[photoId] else { return nil }
            return CullingHistoryEntry(
                photoId: photoId,
                before: before,
                after: after,
                expectedRevision: revisionsByPhoto[photoId] ?? 0,
                fields: fields
            )
        }
        guard !entries.isEmpty else { return }
        // 与 cullingHistoryRepo.append 同语义：新操作落地即删除已撤销分支
        //（redo 栈作废）。内存列表不同步会让重做指向已被删除的操作。
        history.removeAll { $0.undone }
        history.insert(CullingHistoryOperation(
            id: id,
            sessionId: sessionId,
            entries: entries,
            undone: false,
            createdAt: Date().ISO8601Format()
        ), at: 0)
    }

    /// 撤销栈顶 = MAX(id) 未撤销（唯一规则，见 CullingHistoryRepo 文件头注）。
    public var undoOperation: CullingHistoryOperation? {
        history.filter { !$0.undone }.max { $0.id < $1.id }
    }

    /// 重做栈顶 = MIN(id) 已撤销（不是列表里第一个 undone —— 列表是 id DESC）。
    public var redoOperation: CullingHistoryOperation? {
        history.filter { $0.undone }.min { $0.id < $1.id }
    }

    private func snapshot(of state: AssetCullingState) -> CullingStateSnapshot {
        CullingStateSnapshot(pickState: state.pickState, rating: state.rating, colorLabel: state.colorLabel)
    }

    public func decideSimilarityGroup(_ group: CullingGroup, keepPhotoIds: [String], shouldAdvance: Bool = true) async {
        let validIds = Set(group.images.map(\.photoId))
        // 对齐 TS keepInGroupRejectRest：保留 1..组员数-1 张、且都在组内。
        guard !keepPhotoIds.isEmpty,
              keepPhotoIds.count < group.images.count,
              Set(keepPhotoIds).isSubset(of: validIds) else {
            errorMessage = CommandError.localized(
                "请选择当前相似度组中 1 至 %lld 张照片",
                params: ["\(max(1, group.images.count - 1))"]
            )
            return
        }
        do {
            let input = try CullingDecideGroupInput(
                sessionId: sessionId,
                groupId: group.groupId,
                keepPhotoIds: keepPhotoIds
            )
            _ = try await cullingAPI.decideGroup(input)
            notice = CullingNotice("已更新相似度组挑片决策")
            postCullingChange()
            await loadPage(reset: true)
            if shouldAdvance && autoAdvance {
                await jumpToNextGroup(after: group)
            }
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 对齐 TS keepInGroupRejectRest 的组前进：相似度组范围内直接切下一组；
    /// 其他范围对齐 TS（Culling.tsx:1063-1073）从当前照片之后查找第一个
    /// 不同相似度组的资产，避免跳到当前照片之前。
    private func jumpToNextGroup(after group: CullingGroup) async {
        if scopeMode == .similarityGroup {
            await loadSimilarityGroupsIfNeeded()
            let groups = similarityGroups
            guard let index = groups.firstIndex(where: { $0.groupId == group.groupId }),
                  let next = groups.dropFirst(index + 1).first else { return }
            await selectSimilarityGroup(next.groupId)
            return
        }
        guard let assets = page?.assets, let current = currentPhotoId,
              let currentIndex = assets.firstIndex(where: { $0.photo.id == current }) else { return }
        let currentGroupId = assets[currentIndex].similarityGroupId
        guard let next = assets.dropFirst(currentIndex + 1)
            .first(where: { $0.similarityGroupId != currentGroupId }) else { return }
        currentPhotoId = next.photo.id
        // 自动前进后选择集必须一起收敛；否则下一次 P/X 仍写上一组。
        selectedPhotoIds = [next.photo.id]
        selectionAnchorId = next.photo.id
        invalidateSelectionSnapshot()
    }
    // MARK: - P1 / D：淘汰移出（移到 _rejects，不删除）

    /// 把已淘汰的照片移出工作目录；确认由调用点构造 Confirmed。
    /// 范围：显式传入 > 选中项 > 当前照片。
    ///
    /// P0 / A1：不再在客户端按当前页/当前判定过滤——
    /// - 跨页选择必须整份交给服务端（否则第 2 页的选择被静默丢掉）；
    /// - 混进保留件/已移出件时服务端按张返回 skipped，而不是整批失败；
    /// - 服务端还会把选择展开成逻辑资产的全部变体（RAW+JPEG 不会只搬一半）。
    public func moveRejectedOut(photoIds explicitIds: [String]? = nil) async {
        let targets: [String]
        if let explicitIds {
            targets = Array(Set(explicitIds)).sorted()
        } else if !selectedPhotoIds.isEmpty {
            targets = selectedPhotoIds.sorted()
        } else if let current = currentAsset, current.state.pickState == .rejected {
            targets = [current.photo.id]
        } else {
            targets = []
        }
        guard !targets.isEmpty else {
            errorMessage = CommandError.localized("没有已淘汰的照片可移出")
            return
        }
        do {
            let input = try CullingMoveRejectedInput(sessionId: sessionId, photoIds: targets)
            let result = try await cullingAPI.moveRejected(Confirmed(input, source: .userDialog))
            selectedPhotoIds.subtract(result.moved)
            if let first = result.failed.first {
                errorMessage = CommandError(APIError.failed(first.message))
            }
            let skipped = result.skipped
            if !skipped.isEmpty {
                let notRejected = skipped.filter { $0.reason == "not_rejected" }.count
                let archived = skipped.filter { $0.reason == "already_archived" }.count
                let unknown = skipped.count - notRejected - archived
                notice = CullingNotice(
                    "已移出 %lld 张；跳过 %lld 张（非淘汰 %lld / 已移出 %lld / 不在会话 %lld）",
                    params: [
                        "\(result.moved.count)", "\(skipped.count)",
                        "\(notRejected)", "\(archived)", "\(unknown)",
                    ])
            } else if result.moved.isEmpty {
                errorMessage = CommandError.localized("没有可移出的淘汰照片")
            } else {
                notice = CullingNotice("已移出 %lld 张", params: ["\(result.moved.count)"])
            }
            // 路径已变：重新拉页，避免网格继续用旧路径取缩略图。
            await loadPage(reset: true)
            // 归档改变了工作区可见集合（sessions.photo_count 已回落）：广播出去，
            // 侧栏/图库/控制中心才会跟着刷新。
            if !result.moved.isEmpty { postCullingChange() }
        } catch {
            errorMessage = CommandError(error)
        }
    }

    public func toggleSelection(_ photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
        } else {
            selectedPhotoIds.insert(photoId)
        }
        selectionAnchorId = photoId
        invalidateSelectionSnapshot()
    }

    public func clearSelection() {
        selectedPhotoIds = []
        selectionAnchorId = nil
        invalidateSelectionSnapshot()
    }

    /// 单张更新；nextPhotoId 非空时在刷新前预置当前照片（自动前进目标）。
    public func update(_ asset: CullingAsset, patch: CullingUpdatePatch, nextPhotoId: String? = nil) async {
        do {
            let input = try CullingUpdateInput(
                sessionId: sessionId,
                photoId: asset.photo.id,
                expectedRevision: asset.state.revision,
                patch: patch
            )
            // 先快照 before，再 await：等待期间后台刷新可能已经改了 page。
            let before = page?.assets
                .first(where: { $0.photo.id == asset.photo.id })
                .map { snapshot(of: $0.state) }
            let result = try await cullingAPI.update(input)
            applyDecisionStates(result.states)
            if let id = result.historyOperationId, let before {
                let afterByPhoto = Dictionary(
                    uniqueKeysWithValues: result.states.map { ($0.photoId, snapshot(of: $0)) }
                )
                let revisionsByPhoto = Dictionary(
                    uniqueKeysWithValues: result.states.map { ($0.photoId, $0.revision) }
                )
                prependHistoryOperation(
                    id: id,
                    photoIds: [asset.photo.id],
                    beforeByPhoto: [asset.photo.id: before],
                    afterByPhoto: afterByPhoto,
                    revisionsByPhoto: revisionsByPhoto,
                    fields: patch.fields
                )
            }
            if let nextPhotoId {
                currentPhotoId = nextPhotoId
                // P1：自动前进必须同步选择集。否则连续按 P/X 时 targets 仍是上一张，
                // 会在视图已前进的情况下反复重写同一张照片。
                selectedPhotoIds = [nextPhotoId]
                invalidateSelectionSnapshot()
            }
            postCullingChange()
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = CommandError(error)
        }
    }

    public func batchUpdate(
        patch: CullingUpdatePatch,
        targets: Set<String>? = nil
    ) async {
        // P1-7：批量目标 = 完整选择集，不再与当前已加载页求交。
        // 协议单次上限 10k：超过就按 10k 分块串行提交，跨页大选择不再被“请分批”挡住。
        let requested = Array(targets ?? selectedPhotoIds).sorted()
        guard !requested.isEmpty else {
            errorMessage = CommandError.localized("请选择至少一张照片")
            return
        }
        // 可见项才有 before 快照；屏幕外的项由服务端返回 states，本地只刷新页。
        let requestedSet = Set(requested)
        let beforeByPhoto = Dictionary(
            uniqueKeysWithValues: (page?.assets ?? []).compactMap { asset in
                requestedSet.contains(asset.photo.id)
                    ? (asset.photo.id, snapshot(of: asset.state))
                    : nil
            }
        )
        let chunkSize = 10_000
        var applied = 0
        var firstOperation: (id: Int, states: [AssetCullingState])?
        do {
            var index = 0
            while index < requested.count {
                let end = min(index + chunkSize, requested.count)
                let chunk = Array(requested[index..<end])
                let input = try CullingBatchUpdateInput(
                    sessionId: sessionId,
                    photoIds: chunk,
                    patch: patch
                )
                let results = try await cullingAPI.batchUpdate(input)
                let states = results.flatMap { $0.states }
                applyDecisionStates(states)
                // 按请求的代表照片计数：pick 会展开资产变体、rating/label 会联动
                // 共享 sidecar，states 行数可能大于 chunk 行数。
                let written = Set(states.map(\.photoId))
                applied += chunk.filter { written.contains($0) }.count
                if firstOperation == nil, let id = results.first?.historyOperationId {
                    firstOperation = (id, states)
                }
                index = end
            }
            // 只有单块才能用本地预读快照拼完整 operation；多块时整条服务端
            // operation 可能包含屏幕外照片，本地只记第一块会在刷新前撤销不全。
            if requested.count <= chunkSize, let firstOperation, !beforeByPhoto.isEmpty {
                var afterByPhoto: [String: CullingStateSnapshot] = [:]
                var revisionsByPhoto: [String: Int] = [:]
                for state in firstOperation.states {
                    afterByPhoto[state.photoId] = snapshot(of: state)
                    revisionsByPhoto[state.photoId] = state.revision
                }
                prependHistoryOperation(
                    id: firstOperation.id,
                    photoIds: Array(beforeByPhoto.keys),
                    beforeByPhoto: beforeByPhoto,
                    afterByPhoto: afterByPhoto,
                    revisionsByPhoto: revisionsByPhoto,
                    fields: patch.fields
                )
            }
            // 文案用真实写入数：服务端会跳过“合并变体/决策未变化”，请求数会虚高。
            notice = applied == requested.count
                ? CullingNotice("已更新 %lld 张照片", params: ["\(applied)"])
                : CullingNotice(
                    "已更新 %lld 张照片；%lld 张无变化",
                    params: ["\(applied)", "\(requested.count - applied)"])
            postCullingChange()
            refreshSilently()
        } catch {
            pageVersion += 1
            if applied == 0 {
                // 首块即失败：保留真实错误码/诊断，不能改写成“部分完成 0 张”。
                errorMessage = CommandError(error)
            } else {
                errorMessage = CommandError.localized(
                    "批量更新部分完成：已应用 %lld 张，其余块未执行；请重新全选后再试。",
                    params: ["\(applied)"])
            }
        }
    }

    /// TS commitTargets（Culling.tsx:828-906）：快捷键/工具栏决策作用于选中集，
    /// 无选中时作用于当前照片；U 待定不前进，其余决策按自动前进开关前进。
    public func commit(patch: CullingUpdatePatch, shouldAdvance: Bool = true) async {
        guard !isLoading else { return }
        guard !selectedPhotoIds.isEmpty else {
            guard let asset = currentAsset else { return }
            let nextId = shouldAdvance && autoAdvance ? nextPhotoId(after: asset.photo.id) : nil
            await update(asset, patch: patch, nextPhotoId: nextId)
            return
        }
        let targets = Array(selectedPhotoIds)
        // 服务端范围快照只在“选择集与快照一一对应”时可用；任何手动微调都会作废它。
        let snapshot = selectionSnapshot.flatMap { snap in
            snap.count == selectedPhotoIds.count && !snap.idsHash.isEmpty ? snap : nil
        }
        let loaded = Set(page?.assets.map { $0.photo.id } ?? [])
        let visible = targets.filter { loaded.contains($0) }
        if visible.count < targets.count {
            // 有屏幕外照片：先让用户看到影响面。范围快照由服务端重算 + hash 绑定；
            // 显式选择按 id 分块提交——两条路都必须先确认再执行。
            pendingCrossPageBatch = CullingCrossPageBatchPlan(
                patch: patch,
                snapshot: snapshot,
                photoIds: targets,
                visiblePhotoIds: visible)
            return
        }
        if let snapshot {
            await performSelectionUpdate(patch: patch, snapshot: snapshot)
            return
        }
        if targets.count == 1,
           let asset = page?.assets.first(where: { $0.photo.id == targets[0] }) {
            let nextId = shouldAdvance && autoAdvance ? nextPhotoId(after: targets[0]) : nil
            await update(asset, patch: patch, nextPhotoId: nextId)
        } else {
            await batchUpdate(patch: patch, targets: Set(targets))
        }
    }

    /// 服务端快照批量：hash 不符时零写入，并清空失效选择。
    func performSelectionUpdate(
        patch: CullingUpdatePatch,
        snapshot: CullingSelectionSnapshot
    ) async {
        do {
            let input = try CullingSelectionUpdateInput(
                sessionId: sessionId,
                scope: snapshot.scope,
                filters: snapshot.filters,
                groupId: snapshot.groupId,
                expectedIdsHash: snapshot.idsHash,
                expectedCount: snapshot.count,
                patch: patch)
            let result = try await cullingAPI.updateSelection(input)
            let skipped = result.skipped.count
            let steps = result.historyOperationIds.count
            if !result.failed.isEmpty {
                if result.applied == 0, let failure = result.failed.first {
                    // 首块即失败：保留服务端 detail/code，不要改写成“0 张部分完成”。
                    errorMessage = CommandError.localized(
                        "批量更新失败：%@", params: [failure.detail])
                } else {
                    errorMessage = CommandError.localized(
                        "批量更新部分完成：已应用 %lld 张，其余块未执行；请重新全选后再试。",
                        params: ["\(result.applied)"])
                }
            } else if skipped > 0 {
                // 全被“无变化/合并变体”跳过时也必须给反馈，否则界面毫无变化。
                notice = CullingNotice(
                    steps > 1
                        ? "已应用 %lld 张，%lld 张无变化（选择共 %lld 张）；分 %lld 步撤销"
                        : "已应用 %lld 张，%lld 张无变化（选择共 %lld 张）",
                    params: steps > 1
                        ? ["\(result.applied)", "\(skipped)", "\(result.requested)", "\(steps)"]
                        : ["\(result.applied)", "\(skipped)", "\(result.requested)"])
            } else {
                notice = CullingNotice(
                    steps > 1
                        ? "已应用 %lld 张（选择共 %lld 张）；分 %lld 步撤销"
                        : "已应用 %lld 张（选择共 %lld 张）",
                    params: steps > 1
                        ? ["\(result.applied)", "\(result.requested)", "\(steps)"]
                        : ["\(result.applied)", "\(result.requested)"])
            }
            if result.truncated {
                notice = CullingNotice(
                    "选择超过单次上限（%lld 张），超出部分不会被处理；请缩小筛选范围。",
                    params: ["\(CullingSelectionQuery.maxIds)"])
            }
            postCullingChange()
            // 结果带逐张 states：先就地回显，再只刷摘要/同步态。已加载 >2000 张时
            // forcePage 会被 silentRefreshPageLimit 拒绝，不能依赖整页重取。
            applyDecisionStates(result.states)
            refreshSilently()
        } catch {
            let commandError = CommandError(error)
            if commandError.code == GatherErrorCode.CULLING_SELECTION_CHANGED.rawValue {
                selectedPhotoIds.removeAll()
                invalidateSelectionSnapshot()
            }
            errorMessage = commandError
        }
    }

    /// 确认弹窗动作：应用到全部，或只应用当前已加载的可见项。
    func performCrossPageBatch(
        _ plan: CullingCrossPageBatchPlan,
        onlyVisible: Bool
    ) async {
        pendingCrossPageBatch = nil
        if onlyVisible {
            invalidateSelectionSnapshot()
            selectedPhotoIds = Set(plan.visiblePhotoIds)
            await batchUpdate(patch: plan.patch, targets: Set(plan.visiblePhotoIds))
        } else if let snapshot = plan.snapshot {
            await performSelectionUpdate(patch: plan.patch, snapshot: snapshot)
        } else {
            await batchUpdate(patch: plan.patch, targets: Set(plan.photoIds))
        }
    }

    /// P2-3：多选时的混合态摘要。只统计已加载且选中的照片；跨页未加载时
    /// 视为不完整（hasMixed* 为 true），避免把当前页的单一值冒充整个选择集。
    public struct SelectionSummary: Equatable {
        public let selectedCount: Int
        public let loadedCount: Int
        public let ratings: Set<Int>
        public let colorLabels: Set<CaptureOneColorLabel>

        public var rating: Int? {
            ratings.count == 1 && selectedCount == loadedCount ? ratings.first : nil
        }

        public var colorLabel: CaptureOneColorLabel? {
            colorLabels.count == 1 && selectedCount == loadedCount ? colorLabels.first : nil
        }

        // rating/colorLabel 为 nil 当且仅当“混合或跨页”（见上方两个计算属性）。
        public var hasMixedRating: Bool { rating == nil }
        public var hasMixedColorLabel: Bool { colorLabel == nil }
    }

    public var selectionSummary: SelectionSummary? {
        guard !selectedPhotoIds.isEmpty, let assets = page?.assets else { return nil }
        let selected = assets.filter { selectedPhotoIds.contains($0.photo.id) }
        guard !selected.isEmpty else { return nil }
        return SelectionSummary(
            selectedCount: selectedPhotoIds.count,
            loadedCount: selected.count,
            ratings: Set(selected.map { Int($0.state.rating) }),
            colorLabels: Set(selected.map(\.state.colorLabel))
        )
    }

    public func nextPhotoId(after photoId: String) -> String? {
        guard let assets = page?.assets,
              let index = assets.firstIndex(where: { $0.photo.id == photoId }) else { return nil }
        return assets.indices.contains(index + 1) ? assets[index + 1].photo.id : nil
    }

    /// 选中当前照片并把多选收敛为这一张。
    ///
    /// P1-6：旧实现只改 currentPhotoId，胶片条普通点击后旧多选仍在；
    /// 随后 P/X 会按 selectedPhotoIds 批量写入，导致“点在 A、改的是 B/C”。
    /// 普通点击 = 单选，必须同时清空多选（与网格 gridClick 的普通点击语义一致）。
    public func selectCurrent(_ photoId: String) {
        guard page?.assets.contains(where: { $0.photo.id == photoId }) == true else { return }
        currentPhotoId = photoId
        selectedPhotoIds = [photoId]
        selectionAnchorId = photoId
        invalidateSelectionSnapshot()
    }

    /// TS advance：←/→ 翻页；到达已加载窗口末尾且还有下一页时后台加载。
    public func advanceCurrent() {
        guard let assets = page?.assets, !assets.isEmpty else { return }
        if let current = currentPhotoId, let index = assets.firstIndex(where: { $0.photo.id == current }) {
            if index < assets.count - 1 {
                let next = assets[index + 1].photo.id
                currentPhotoId = next
                selectedPhotoIds = [next]
                selectionAnchorId = next
                invalidateSelectionSnapshot()
            } else if hasMore {
                // 末张：加载下一页后真正前进到新页首张（否则停在末张，看起来像卡住）。
                Task {
                    await loadMore()
                    guard let assets = page?.assets,
                          let current = currentPhotoId,
                          let index = assets.firstIndex(where: { $0.photo.id == current }),
                          index + 1 < assets.count
                    else { return }
                    currentPhotoId = assets[index + 1].photo.id
                    selectedPhotoIds = [assets[index + 1].photo.id]
                    selectionAnchorId = assets[index + 1].photo.id
                    invalidateSelectionSnapshot()
                }
            }
        } else {
            currentPhotoId = assets.first?.photo.id
        }
    }

    public func retreatCurrent() {
        guard let assets = page?.assets, !assets.isEmpty else { return }
        if let current = currentPhotoId, let index = assets.firstIndex(where: { $0.photo.id == current }) {
            let previous = assets[max(0, index - 1)].photo.id
            currentPhotoId = previous
            selectedPhotoIds = [previous]
            selectionAnchorId = previous
            invalidateSelectionSnapshot()
        } else {
            currentPhotoId = assets.first?.photo.id
        }
    }

    public func undo() async {
        triageApplied = false
        // 唯一规则：撤销栈顶 = MAX(id) 未撤销（见 undoOperation）。
        guard let operation = undoOperation else {
            notice = CullingNotice("没有可撤销的挑片操作")
            return
        }
        await applyHistory(operation, direction: .undo)
    }

    public func redo() async {
        triageApplied = false
        // 唯一规则：重做栈顶 = MIN(id) 已撤销（见 redoOperation）。
        guard let operation = redoOperation else {
            notice = CullingNotice("没有可重做的挑片操作")
            return
        }
        await applyHistory(operation, direction: .redo)
    }

    private func applyHistory(_ operation: CullingHistoryOperation, direction: CullingHistoryDirection) async {
        do {
            let entries = operation.entries.map { entry -> CullingHistoryApplyEntry in
                let snapshot = direction == .undo ? entry.before : entry.after
                let patch = CullingUpdatePatch(
                    rating: entry.fields.contains(.rating) ? snapshot.rating : nil,
                    pickState: entry.fields.contains(.pickState) ? snapshot.pickState : nil,
                    colorLabel: entry.fields.contains(.colorLabel) ? snapshot.colorLabel : nil
                )
                return CullingHistoryApplyEntry(
                    photoId: entry.photoId,
                    expectedRevision: entry.expectedRevision,
                    patch: patch
                )
            }
            let input = try CullingApplyHistoryInput(
                sessionId: sessionId,
                entries: entries,
                historyOperationId: operation.id,
                direction: direction,
                source: operation.id == triageHistoryOperationId ? .ai : .manual
            )
            let results = try await cullingAPI.applyHistory(input)
            applyDecisionStates(results.flatMap { $0.states })
            markHistoryOperation(operation.id, undone: direction == .undo)
            notice = CullingNotice(direction == .undo ? "已撤销上一次挑片操作" : "已重做挑片操作")
            postCullingChange()
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = CommandError(error)
        }
    }
}
