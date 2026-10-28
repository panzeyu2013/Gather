// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Actions.swift
// Cut 4 / 4c-2a：挑片决策 / 选择 / 翻页 / 历史撤销重做（原 CullingView.swift 690-1284 行）。
// 历史窗口常量 historyWindow（原 744-746）随加载路径移到 +Load。
import Foundation
import GatherProtocol

extension CullingViewModel {
    private func applyDecisionStates(_ states: [AssetCullingState]) {
        guard let page else { return }
        let byId = Dictionary(uniqueKeysWithValues: states.map { ($0.photoId, $0) })
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
    }

    public func clearSelection() {
        selectedPhotoIds = []
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
            if let nextPhotoId { currentPhotoId = nextPhotoId }
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
        // commit 传 visibleSelection；直接调用时再与当前已加载页求交，
        // 防止分页/筛选后隐藏的选择被批量写入。
        let loaded = Set(page?.assets.map { $0.photo.id } ?? [])
        let requested = targets ?? selectedPhotoIds
        let photoIds = requested.intersection(loaded).sorted()
        guard !photoIds.isEmpty else {
            errorMessage = CommandError.localized("请选择至少一张照片")
            return
        }
        do {
            // 选择集与 before 都在 await 前快照：等待期间用户仍可能改选择/触发刷新。
            let beforeByPhoto = Dictionary(
                uniqueKeysWithValues: (page?.assets ?? []).compactMap { asset in
                    photoIds.contains(asset.photo.id)
                        ? (asset.photo.id, snapshot(of: asset.state))
                        : nil
                }
            )
            let input = try CullingBatchUpdateInput(
                sessionId: sessionId,
                photoIds: photoIds,
                patch: patch
            )
            let results = try await cullingAPI.batchUpdate(input)
            applyDecisionStates(results.flatMap { $0.states })
            let afterByPhoto = Dictionary(
                uniqueKeysWithValues: results.flatMap(\.states).map { ($0.photoId, snapshot(of: $0)) }
            )
            let revisionsByPhoto = Dictionary(
                uniqueKeysWithValues: results.flatMap(\.states).map { ($0.photoId, $0.revision) }
            )
            if let id = results.first?.historyOperationId {
                prependHistoryOperation(
                    id: id,
                    photoIds: Array(beforeByPhoto.keys),
                    beforeByPhoto: beforeByPhoto,
                    afterByPhoto: afterByPhoto,
                    revisionsByPhoto: revisionsByPhoto,
                    fields: patch.fields
                )
            }
            notice = CullingNotice("已更新 %lld 张照片", params: ["\(photoIds.count)"])
            postCullingChange()
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = CommandError(error)
        }
    }

    /// TS commitTargets（Culling.tsx:828-906）：快捷键/工具栏决策作用于选中集，
    /// 无选中时作用于当前照片；U 待定不前进，其余决策按自动前进开关前进。
    public func commit(patch: CullingUpdatePatch, shouldAdvance: Bool = true) async {
        guard !isLoading else { return }
        // P0：只提交当前已加载页里仍可见的选择；筛选/排序后隐藏的旧选择
        // 不能因为快捷键命中而写到不可见照片。
        let loaded = Set(page?.assets.map { $0.photo.id } ?? [])
        let visibleSelection = selectedPhotoIds.intersection(loaded)
        if !selectedPhotoIds.isEmpty, visibleSelection.isEmpty {
            // 选择仍在但已不可见（筛选/刷新/翻页后）：绝不回退到当前照片，
            // 否则会把 P/X 写进用户根本没选中的照片（宁可漏杀不可错杀）。
            errorMessage = CommandError.localized("所选照片不在当前视图内，请重新选择")
            return
        }
        let targets = visibleSelection.isEmpty
            ? (currentAsset.map { [$0.photo.id] } ?? [])
            : Array(visibleSelection)
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            guard let asset = page?.assets.first(where: { $0.photo.id == targets[0] }) else { return }
            let nextId = shouldAdvance && autoAdvance ? nextPhotoId(after: targets[0]) : nil
            await update(asset, patch: patch, nextPhotoId: nextId)
        } else {
            await batchUpdate(patch: patch, targets: visibleSelection)
        }
    }
    public func nextPhotoId(after photoId: String) -> String? {
        guard let assets = page?.assets,
              let index = assets.firstIndex(where: { $0.photo.id == photoId }) else { return nil }
        return assets.indices.contains(index + 1) ? assets[index + 1].photo.id : nil
    }

    public func selectCurrent(_ photoId: String) {
        guard page?.assets.contains(where: { $0.photo.id == photoId }) == true else { return }
        currentPhotoId = photoId
    }

    /// TS advance：←/→ 翻页；到达已加载窗口末尾且还有下一页时后台加载。
    public func advanceCurrent() {
        guard let assets = page?.assets, !assets.isEmpty else { return }
        if let current = currentPhotoId, let index = assets.firstIndex(where: { $0.photo.id == current }) {
            if index < assets.count - 1 {
                let next = assets[index + 1].photo.id
                currentPhotoId = next
                selectedPhotoIds = [next]
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
