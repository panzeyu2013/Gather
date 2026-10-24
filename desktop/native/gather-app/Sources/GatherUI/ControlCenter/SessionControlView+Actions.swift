// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Actions.swift
// Cut 4 / 4c-2e：待办/推荐动作执行（perform），原 1040-1076 行。
// appearance 迁移：导航闭包换成 environment 的 navigator 具名入口。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 动作执行

    /// 动作 → 路由：控制中心只表达「去哪」，意图（只看冲突/离线/分析步骤/
    /// 导出范围）由 navigator 写入 SessionWorkspace，页面不再各自拼装闭包。
    func perform(_ action: InboxAction) {
        switch action {
        case .none:
            break
        case .showStages:
            scrollToStagesRequested = true
        case .reviewXmpConflicts:
            // D10：待办指向「某类问题」——进入挑片时必须同时带上「只看冲突」，
            // 否则用户到达的只是一个普通挑片页，还得自己再找一遍。
            navigator?.openCullingConflicts(viewModel.sessionId)
        case .reviewOfflinePhotos:
            navigator?.openGalleryOffline(viewModel.sessionId)
        case .reviewStaleAnalysis:
            // D10：人脸过期直达分析步骤（intent 由 navigator 入队）。
            navigator?.openFaceAnalyze(viewModel.sessionId)
        case .navigateTab(let tab):
            if tab == .export {
                // N05：控制中心的导出引导语义是「导出挑片成果」——默认范围必须
                // 是保留片，而不是退回「工作区全部照片」。
                navigator?.openExport(viewModel.sessionId, intent: .picks)
            } else {
                // 模型已直接携带唯一页面身份 SessionPage，导航只留 open(_:in:)。
                navigator?.open(tab, in: viewModel.sessionId)
            }
        case .navigateSimilarity:
            navigator?.openSimilarity(viewModel.sessionId)
        case .navigateGallery:
            // 对齐 OLD workspace-view.ts:135：offline_photos “查看”进入画廊
            // （/sessions/:id/gallery），而不是返回上一页。
            navigator?.openGallery(viewModel.sessionId)
        case .retryJob(let jobId):
            viewModel.retry(jobId: jobId)
        case .retryFailedJobs:
            viewModel.retryFailedJobs()
        }
    }
}
