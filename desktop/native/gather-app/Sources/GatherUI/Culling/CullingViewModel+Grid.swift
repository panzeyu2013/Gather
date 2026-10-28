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
        // 不再无条件清空：跨页选择保留在 selectedPhotoIds（提交时再按可见性收窄），
        // 避免“切布局/翻页即丢选择”。
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

    /// P0 / A1：⌘A 选中**当前 scope/filters 的全部照片**（不只已加载页）。
    ///
    /// 失败时退回"已加载页"并提示：宁可少选，也不能假装全选。
    public func selectAllInScope() async {
        // 进入时快照 scope 与加载代数：await 期间切筛选/scope 会清空选择并重新加载，
        // 旧 scope 的结果绝不能回填（P1：否则随后的移出会把当前视图看不到的
        // 旧选择整份提交给服务端，单向不可撤销）。
        let generation = loadGeneration
        let scope = currentAPIScope
        do {
            let query = try CullingSelectionQuery(
                sessionId: sessionId,
                scope: currentAPIScope,
                filters: currentAPIScope == .filtered ? filtersForCurrentState() : nil,
                // 相似度模式未选组时与 loadPage 同语义：nil = latest，不是空字符串。
                groupId: currentAPIScope == .similarityGroup && !selectedSimilarityGroupId.isEmpty
                    ? selectedSimilarityGroupId : nil
            )
            let result = try await cullingAPI.selection(query)
            guard generation == loadGeneration, scope == currentAPIScope else { return }
            selectedPhotoIds = Set(result.ids)
            if result.truncated {
                notice = CullingNotice(
                    "已选中前 %lld 张（超出单次上限，其余请先缩小筛选范围）",
                    params: ["\(result.ids.count)"])
            }
        } catch {
            // 旧 scope 的失败也不能回退成"已加载页"选择（那会把旧视图的
            // 选择集写进新 scope）。
            guard generation == loadGeneration, scope == currentAPIScope else { return }
            selectAllLoaded()
            errorMessage = CommandError(error)
        }
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
