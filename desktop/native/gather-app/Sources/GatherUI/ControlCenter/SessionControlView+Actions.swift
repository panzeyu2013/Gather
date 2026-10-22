// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Actions.swift
// Cut 4 / 4c-2e：待办/推荐动作执行（perform），原 1040-1076 行。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 动作执行

    func perform(_ action: InboxAction) {
        switch action {
        case .none:
            break
        case .showStages:
            scrollToStagesRequested = true
        case .reviewXmpConflicts:
            // D10：待办指向「某类问题」——进入挑片时必须同时带上「只看冲突」，
            // 否则用户到达的只是一个普通挑片页，还得自己再找一遍。
            onReviewXmpConflicts(viewModel.sessionId)
        case .reviewOfflinePhotos:
            onReviewOfflinePhotos(viewModel.sessionId)
        case .reviewStaleAnalysis:
            onReviewStaleAnalysis(viewModel.sessionId)
        case .navigateTab(let tab):
            if tab == .export {
                // N05：控制中心的导出引导语义是「导出挑片成果」——默认范围必须
                // 是保留片，而不是退回「工作区全部照片」。
                onOpenExportTab(viewModel.sessionId, .picks)
            } else {
                onOpenTab(viewModel.sessionId, tab)
            }
        case .navigateSimilarity:
            onOpenSimilarity(viewModel.sessionId)
        case .navigateGallery:
            // 对齐 OLD workspace-view.ts:135：offline_photos “查看”进入画廊
            // （/sessions/:id/gallery），而非 onBack 返回上一页。onOpenGallery
            // 在 RootView 已接线 navigation.openGallery；默认闭包保证独立编译。
            onOpenGallery(viewModel.sessionId)
        case .retryJob(let jobId):
            viewModel.retry(jobId: jobId)
        case .retryFailedJobs:
            viewModel.retryFailedJobs()
        }
    }
}
