// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingViewModel+SplitReview.swift
// P0 / F0：人脸簇成员级复核（cohesion / flags / 分页）与拆分（仅未绑定簇）。
//
// 语义：
//   - 复核列表只承载“成员”，不替代簇列表；切换簇时按 clusterId 重新拉取；
//   - 拆分成功后 select(newCluster) + 重新拉复核；失败保留当前选择，便于修正；
//   - 已绑定簇/分析中/全选（会清空原簇）在 VM 侧先拦，服务层仍做最终校验。
import Foundation
import GatherProtocol

extension FaceKeywordingViewModel {
    // MARK: - 派生

    public var selectedReviewItems: [FaceReviewItem] {
        guard let selectedClusterId else { return [] }
        return reviewItems.filter { $0.clusterId == selectedClusterId }
    }

    public func reviewSummary(for clusterId: Int) -> FaceReviewClusterSummary? {
        reviewSummaries.first { $0.clusterId == clusterId }
    }

    public var canSplit: Bool {
        guard let cluster = selectedCluster else { return false }
        return cluster.binding == nil
            && analysisPhase != .running
            && !isSplitting
            && !selectedMemberIds.isEmpty
            && selectedMemberIds.count < cluster.size
    }

    // MARK: - 复核加载

    /// 拉取复核成员。reset=false 时从 reviewNextCursor 继续；切换簇必须 reset=true。
    public func loadReview(clusterId: Int? = nil, reset: Bool = true) async {
        guard let target = clusterId ?? selectedClusterId else { return }
        reviewGeneration += 1
        let generation = reviewGeneration
        if reset {
            reviewItems = []
            reviewNextCursor = nil
            reviewTotal = 0
            reviewSuspectTotal = 0
            selectedMemberIds.removeAll()
        }
        isLoadingReview = true
        defer {
            if generation == reviewGeneration { isLoadingReview = false }
        }
        do {
            let page = try await face.review(FaceReviewInput(
                sessionId: sessionId,
                clusterId: target,
                cursor: reset ? nil : reviewNextCursor,
                limit: 50,
                includeResolved: !includeOnlyReviewMembers
            ))
            guard generation == reviewGeneration else { return }
            if reset {
                reviewItems = page.items
            } else {
                let existing = Set(reviewItems.map(\.memberId))
                reviewItems.append(contentsOf: page.items.filter { !existing.contains($0.memberId) })
            }
            reviewNextCursor = page.nextCursor
            reviewTotal = page.total
            reviewSuspectTotal = page.suspectTotal
            if !page.clusters.isEmpty {
                if clusterId == nil {
                    reviewSummaries = page.clusters
                } else {
                    // 单簇复核只更新该簇的 Badge，不能覆盖其他簇的摘要。
                    for summary in page.clusters {
                        if let index = reviewSummaries.firstIndex(
                            where: { $0.clusterId == summary.clusterId }) {
                            reviewSummaries[index] = summary
                        } else {
                            reviewSummaries.append(summary)
                        }
                    }
                }
            }
            reviewActionError = nil
        } catch {
            guard generation == reviewGeneration else { return }
            let failure = CommandError(error)
            errorMessage = failure
            reviewActionError = failure
        }
    }

    /// 只拉全部簇的复核概要（卡片角标）；不动当前成员列表。
    public func loadReviewSummaries() async {
        do {
            let page = try await face.review(FaceReviewInput(
                sessionId: sessionId,
                clusterId: nil,
                cursor: nil,
                limit: 1,
                includeResolved: false
            ))
            reviewSummaries = page.clusters
        } catch {
            // 角标失败不打扰主流程；成员列表仍可单独加载。
        }
    }

    public func loadMoreReview() async {
        guard reviewNextCursor != nil, !isLoadingReview else { return }
        await loadReview(clusterId: selectedClusterId, reset: false)
    }

    /// 切换“仅看待复核成员”后重载当前簇。
    public func setIncludeOnlyReviewMembers(_ value: Bool) async {
        guard includeOnlyReviewMembers != value else { return }
        includeOnlyReviewMembers = value
        await loadReview(clusterId: selectedClusterId, reset: true)
    }

    // MARK: - 选择

    public func toggleMemberSelection(_ memberId: Int) {
        if selectedMemberIds.contains(memberId) {
            selectedMemberIds.remove(memberId)
        } else {
            selectedMemberIds.insert(memberId)
        }
    }

    public func clearMemberSelection() {
        selectedMemberIds.removeAll()
    }

    /// ⌘A 全选当前复核列表；若会清空原簇，仍允许选择，由拆分按钮/服务层提示 KEEP_ONE。
    public func selectAllReviewMembers() {
        selectedMemberIds = Set(selectedReviewItems.map(\.memberId))
    }

    // MARK: - 拆分 / 移除

    public func splitSelectedMembers(from cluster: FaceClusterData, confirmed: Bool) async {
        guard confirmed else {
            notice = FaceNotice("未确认，已取消拆分")
            return
        }
        guard cluster.binding == nil else {
            setReviewError(code: "FACE_CLUSTER_BOUND")
            return
        }
        guard analysisPhase != .running else {
            setReviewError(CommandError.localized("分析进行中，暂不能拆分"))
            return
        }
        guard !selectedMemberIds.isEmpty else {
            setReviewError(CommandError.localized("请选择至少一个成员"))
            return
        }
        guard selectedMemberIds.count < cluster.size else {
            setReviewError(code: "FACE_SPLIT_KEEP_ONE")
            return
        }
        isSplitting = true
        defer { isSplitting = false }
        do {
            let result = try await face.split(Confirmed(
                try FaceSplitInput(
                    sessionId: sessionId,
                    clusterId: cluster.id,
                    memberIds: Array(selectedMemberIds).sorted()
                ),
                source: .userDialog
            ))
            publishChange(.faceKeywording)
            notice = FaceNotice(
                "已拆分出簇 #%lld（%lld 个成员），可立即绑定。",
                params: ["\(result.newClusterId)", "\(result.movedCount)"]
            )
            reviewActionError = nil
            await reload()
            if let newCluster = clusters.first(where: { $0.id == result.newClusterId }) {
                select(newCluster)
                await loadReview(clusterId: newCluster.id, reset: true)
            }
            await loadReviewSummaries()
        } catch {
            let failure = CommandError(error)
            errorMessage = failure
            reviewActionError = failure
        }
    }

    public func removeReviewMember(_ item: FaceReviewItem, from cluster: FaceClusterData) async {
        do {
            try await face.removeMember(FaceRemoveMemberInput(
                sessionId: sessionId,
                clusterId: cluster.id,
                memberId: item.memberId
            ))
            publishChange(.faceKeywording)
            notice = FaceNotice("已从簇 #%lld 移除成员", params: ["\(cluster.id)"])
            reviewActionError = nil
            await reload()
            if clusters.contains(where: { $0.id == cluster.id }) {
                await loadReview(clusterId: cluster.id, reset: true)
            }
            await loadReviewSummaries()
        } catch {
            let failure = CommandError(error)
            errorMessage = failure
            reviewActionError = failure
        }
    }

    private func setReviewError(code: String) {
        let failure = CommandError(code: code)
        errorMessage = failure
        reviewActionError = failure
    }

    private func setReviewError(_ failure: CommandError) {
        errorMessage = failure
        reviewActionError = failure
    }
}
