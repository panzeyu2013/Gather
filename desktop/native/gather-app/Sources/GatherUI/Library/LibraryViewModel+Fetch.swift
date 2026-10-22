// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel+Fetch.swift
// Cut 4 / 4c-2j：从 LibraryViewModel.swift 移出取数（原 695-746 行）。
// 纯搬移：D06 数据代次守卫、P2-7 请求序号（最新请求胜出）、isFetching 只由
// 最新请求收尾、首屏失败与有旧数据时刷新失败的相位/错误落地逐字未动。
import Foundation
import GatherProtocol

extension LibraryViewModel {

    // MARK: 取数

    func fetchPage(_ target: Int, isFirst: Bool) async {
        // D06：请求绑定数据代数。旧实现只 `fetchTask?.cancel()`——旧字符串命令
        // 的 continuation 请求不会被真正取消，旧筛选（星级 1）的响应会在新筛选
        // （星级 5）之后返回并**无条件**覆盖 photos/total/page，界面筛选值是 5、
        // 计数却是 1 的结果。
        let generation = fetchGeneration
        // P2-7（审计 2）：同代内也要防乱序——goToPage 与事件刷新/load 并发时，
        // 旧请求返回会把用户刚翻到的页**静默回退**。用请求序号做「最新请求胜出」，
        // isFetching 也只由最新请求负责收尾（旧请求完成不得提前关掉新请求的指示器）。
        requestSequence += 1
        let requestID = requestSequence
        latestRequestID = requestID
        isFetching = true
        defer { if requestID == latestRequestID { isFetching = false } }
        do {
            let result: (photos: [GlobalPhotoResult], total: Int)
            if let selectedAlbumId {
                result = try await provider.albumPhotos(
                    albumId: selectedAlbumId,
                    limit: Self.pageSize,
                    offset: target * Self.pageSize
                )
            } else {
                result = try await provider.globalPhotos(
                    criteria: buildLibraryCriteria(committed),
                    sessionId: sessionFilter.isEmpty ? nil : sessionFilter,
                    limit: Self.pageSize,
                    offset: target * Self.pageSize
                )
            }
            guard generation == fetchGeneration, requestID == latestRequestID else { return }
            photos = result.photos
            total = result.total
            page = target
            if phase == .loading { phase = .loaded }
            actionError = nil
        } catch {
            guard generation == fetchGeneration, requestID == latestRequestID else { return }
            if photos.isEmpty && phase == .loading {
                // 4a-3b-2a：首屏失败只存错误载体，文案在渲染期解析。
                phase = .failed(CommandError(error))
            } else {
                // P2-7：有旧数据时刷新失败必须回到 loaded——旧实现把 phase 留在
                // .loading，页面永久大 spinner，工具栏刷新按钮又因 phase == .loading
                // 被禁用，用户只能靠改筛选/等事件自愈。
                if phase == .loading { phase = .loaded }
                actionError = CommandError(error)
            }
        }
    }
}
