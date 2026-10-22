// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel+EventRefresh.swift
// Cut 4 / 4c-2j：从 LibraryViewModel.swift 移出终态事件刷新（原 748-769 行）。
// 纯搬移：500ms 合并连续终态帧、就地刷新（不跳页、不闪 loading）逐字未动。
import Foundation
import GatherProtocol

extension LibraryViewModel {

    // MARK: 终态事件刷新（对齐 TS 事件失效语义）

    /// 终态事件驱动的按需刷新：任意终态事件重载支持数据（相册/关联候选/
    /// 孤立 XMP/离线卷）与当前页照片列表；500ms 合并连续终态帧，避免风暴。
    public func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshOnEvent()
        }
    }

    /// 就地刷新当前页（react-query invalidate 语义：不跳页、不闪 loading）。
    func refreshOnEvent() async {
        await reloadSupport()
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchPage(self.page, isFirst: false)
        }
    }
}
