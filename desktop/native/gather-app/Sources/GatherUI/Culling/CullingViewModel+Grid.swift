// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Grid.swift
// P0 / G0：网格布局的排序、分页大小与选择语义。
// 只扩充 VM 的 UI 状态；不改 core 契约/服务逻辑。
import AppKit
import Foundation
import GatherProtocol

extension CullingViewModel {
    /// 恢复上次排序：只改 UI 状态，由页面首次 load 使用；不额外发请求。
    public func applySort(_ sort: CullingSort) {
        isSortUserSet = true
        sortMode = sort
    }

    /// 切换排序：重置分页与游标，保留当前照片（若仍在新页）。
    public func setSort(_ sort: CullingSort) async {
        guard sortMode != sort else { return }
        isSortUserSet = true
        sortMode = sort
        // P0：排序变化后旧选择可能不可见；提交前必须清空。
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    /// 切换布局导致的页大小变化：重置分页。
    public func setPageLimit(_ limit: Int) async {
        let clamped = min(1_000, max(50, limit))
        guard pageLimit != clamped else { return }
        pageLimit = clamped
        // 不再无条件清空：宽化保留选择；缩页由 loadPage 的 formIntersection(newIds)
        // 自动丢掉已不在页内的项，避免“切布局即丢选择”。
        await loadPage(reset: true)
    }

    /// 首屏加载前静默设置页大小（不触发第二次请求）。
    public func applyPageLimit(_ limit: Int) {
        pageLimit = min(1_000, max(50, limit))
    }

    /// T0：按建议 verdict 过滤；空数组表示取消。
    public func setTriageVerdicts(_ verdicts: [TriageVerdict]?) async {
        await setFilterState { state in
            state.triageVerdicts = (verdicts?.isEmpty == false) ? verdicts : nil
        }
    }

    public func selectAllLoaded() {
        guard !loadedPhotoIds.isEmpty else { return }
        selectedPhotoIds = loadedPhotoIds
    }

    /// ⇧ 范围选择：当前照片到目标照片（按当前页顺序）。
    public func selectRange(from anchor: String, to target: String) {
        guard let assets = page?.assets,
              let start = assets.firstIndex(where: { $0.photo.id == anchor }),
              let end = assets.firstIndex(where: { $0.photo.id == target }) else { return }
        let range = start <= end ? start...end : end...start
        selectedPhotoIds.formUnion(range.map { assets[$0].photo.id })
    }

    /// 网格点击：⌘ 切换，⇧ 范围，否则单选并清空多选。
    public func gridClick(_ photoId: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = currentPhotoId, anchor != photoId {
            selectRange(from: anchor, to: photoId)
            currentPhotoId = photoId
            return
        }
        if modifiers.contains(.command) {
            toggleSelection(photoId)
            currentPhotoId = photoId
            return
        }
        selectedPhotoIds = [photoId]
        currentPhotoId = photoId
    }
}
