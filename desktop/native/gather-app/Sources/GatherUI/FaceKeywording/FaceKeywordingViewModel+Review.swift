// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingViewModel+Review.swift
// Cut 4 / 4c-2b：绑定/解绑/移除成员/合并、内联错误与变更广播
// （原 FaceKeywordingView.swift 442-536、672-684、810-814 行，逐字搬移）。
import Foundation
import GatherProtocol

extension FaceKeywordingViewModel {
    public func bind(_ cluster: FaceClusterData) async {
        let role = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = parseKeywords()
        guard !role.isEmpty else {
            // TS handleBind：空角色名 → 详情栏内联错误（StepReview.tsx:95-97）。
            let failure = CommandError(code: "FKW_ROLE_NAME_EMPTY")
            errorMessage = failure
            reviewActionError = failure
            return
        }
        do {
            try await face.bind(FaceBindInput(
                sessionId: sessionId,
                clusterId: cluster.id,
                roleName: role,
                keywords: words
            ))
            publishChange(.faceKeywording, .persons)
            notice = FaceNotice("已绑定簇 #%lld", params: ["\(cluster.id)"])
            reviewActionError = nil
            await reload()
        } catch {
            errorMessage = CommandError(error)
            reviewActionError = errorMessage
        }
    }

    /// 解除绑定：命令层 FKW_UNBIND_CONFIRM_REQUIRED 门控，`confirmed` 只能由
    /// 确认弹窗传入 true（旧实现恒 true 已删除）。
    public func unbind(_ cluster: FaceClusterData, confirmed: Bool) async {
        guard confirmed else {
            notice = FaceNotice("未确认，已取消解除绑定")
            return
        }
        do {
            _ = try await face.unbind(Confirmed(
                try FaceUnbindInput(sessionId: sessionId, clusterId: cluster.id),
                source: .userDialog
            ))
            publishChange(.faceKeywording, .persons)
            notice = FaceNotice("已解除簇 #%lld 的绑定", params: ["\(cluster.id)"])
            reviewActionError = nil
            await reload()
        } catch {
            errorMessage = CommandError(error)
            reviewActionError = errorMessage
        }
    }

    /// TS handleMerge：合并到下拉目标（过滤当前簇），成功后选中目标簇。
    public func merge(_ cluster: FaceClusterData) async {
        guard let target = mergeTargetId,
              target != cluster.id,
              clusters.contains(where: { $0.id == target }) else {
            let failure = CommandError.localized("请选择有效的目标簇")
            errorMessage = failure
            reviewActionError = failure
            return
        }
        do {
            try await face.merge(FaceMergeInput(
                sessionId: sessionId,
                source: cluster.id,
                target: target
            ))
            publishChange(.faceKeywording)
            notice = FaceNotice("已将簇 #%lld 合并到簇 #%lld", params: ["\(cluster.id)", "\(target)"])
            mergeTargetId = nil
            reviewActionError = nil
            await reload()
            if let targetCluster = clusters.first(where: { $0.id == target }) {
                select(targetCluster)
            }
        } catch {
            errorMessage = CommandError(error)
            reviewActionError = errorMessage
        }
    }

    /// 合并目标无效时的内联错误（UI 侧不再用 merge() 做校验，避免静默执行）。
    public func reportInvalidMergeTarget() {
        let failure = CommandError.localized("请选择有效的目标簇")
        errorMessage = failure
        reviewActionError = failure
    }

    /// 写路径统一广播：人脸域；绑定/解绑同时命中人物域（person_photos 变化）。
    func publishChange(_ domains: GatherChangeDomain...) {
        for domain in domains {
            GatherEventCenter.postDomainChange(domain, sessionId: sessionId)
        }
    }

    private func parseKeywords() -> [String] {
        keywords.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}
