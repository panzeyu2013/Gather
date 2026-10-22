// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Filter.swift
// Cut 4 / 4c-2d：搜索防抖提交与过滤/变体切换（原 GalleryViewModel.swift 548-603 行）。
// 纯搬移：有效查询没变即 no-op、退出搜索保留首页、选择集随查询收敛均逐字保留。
import Foundation

extension GalleryViewModel {

    // MARK: 变更提交

    /// 搜索输入变更：300ms 防抖后提交（TS useDeferredValue 近似）。
    public func searchChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceDelay ?? .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.commitSearch()
        }
    }

    /// 过滤/展开切换：立即提交（TS queryKey 外字段，同样触发链式拉取）。
    public func filterOrVariantChanged() {
        debounceTask?.cancel()
        commitSearch()
    }

    private func commitSearch() {
        let nextSearch = search.trimmingCharacters(in: .whitespaces)
        let nextActive = !nextSearch.isEmpty || filter != .all
        // 审计 2 P1-3/P2-6：**有效查询没变就什么都不做**。
        // 旧实现无条件递增代数 + 清选择：进入页面时程序化把筛选改回默认值，会被
        // 绑定/onChange 再提交一次，这次提交把正在进行的定位判成过期 → 误报「未找到」；
        // 同理「输入一个字符再删掉」也会清空选择并作废在途响应。
        guard nextSearch != committedSearch
            || filter != committedFilter
            || expandVariants != committedExpandVariants else { return }
        // D04/D06：查询条件变化即失效在途响应——旧请求返回的行属于上一个查询，
        // 不得 append 进新数据集（cancel 不保证 continuation 请求真的被取消）。
        fetchGeneration += 1
        // D07：选择集跟着查询走（旧实现只在 reload 里清，普通搜索不经过 reload）。
        clearSelectionForNewQuery()
        committedSearch = nextSearch
        committedFilter = filter

        // 退出搜索/筛选：丢弃链式拉取的额外页，保留首页（TS setQueryData
        // pages.slice(0,1)），哨兵恢复自然分页。
        if searchActiveWas && !nextActive {
            pages = Array(pages.prefix(1))
            pagesGeneration += 1
            flatCache = nil
            filteredCache = nil
            pageCursors = Array(pageCursors.prefix(1))
        }
        searchActiveWas = nextActive

        if expandVariants != committedExpandVariants {
            Task { await reload() }
            return
        }
        // 激活搜索/筛选时立即链式拉满（TS chain-fetch effect）。
        if nextActive {
            Task { await chainFetchIfActive() }
        }
    }
}
