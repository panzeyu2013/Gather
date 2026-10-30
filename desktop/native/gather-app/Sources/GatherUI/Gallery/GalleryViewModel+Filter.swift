// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Filter.swift
// Cut 4 / 4c-2d：搜索防抖提交与过滤/变体切换（原 GalleryViewModel.swift 548-603 行）。
// 纯搬移：有效查询没变即 no-op、退出搜索保留首页、选择集随查询收敛均逐字保留。
import Foundation
import GatherProtocol

extension GalleryViewModel {
    /// P2-2：⌘A 走服务端全选；无 PhotoAPI（预览/旧测试）时退回已加载页。
    public func selectAllInScope() async {
        guard let photoAPI else {
            selectAll(filteredPhotos.map(\.id))
            return
        }
        // P1 下一波：服务端 criteria（facet / 规则）无法经 PhotoSelectionQuery 表达
        // （那套只有 4 档 + 搜索串），改用 filter.photos 的 criteria 查询取 id 集，
        // 保证"全选筛选结果"与网格是同一批照片。
        if let criteria = activeCriteria {
            let generation = fetchGeneration
            do {
                let result = try await photoAPI.search(try PhotoQuery(
                    criteria: criteria, sessionId: sessionId, limit: 20_000))
                guard generation == fetchGeneration else { return }
                selectedIds = Set(result.photos.map(\.photoId))
                isScopeSelection = true
                if result.total > result.photos.count {
                    GatherToastCenter.shared.show(
                        type: .info,
                        message: String(
                            format: GatherLocalization.l(
                                "已选中前 %lld 张（超出单次上限，请缩小筛选范围）"),
                            result.photos.count))
                }
            } catch {
                guard generation == fetchGeneration else { return }
                actionError = CommandError(error)
            }
            return
        }
        // 与网格一致：读已提交查询（不是 300ms 防抖中的草稿），并用代数
        // 防止 await 期间换筛选/搜索后把旧 20k 回填到新视图。
        let generation = fetchGeneration
        let committedSearch = committedSearch.trimmingCharacters(in: .whitespaces)
        let filter: PhotoSelectionFilter
        switch committedFilter {
        case .all: filter = .all
        case .hasFace: filter = .hasFace
        case .noFace: filter = .noFace
        case .offline: filter = .offline
        }
        do {
            let result = try await photoAPI.select(
                PhotoSelectionQuery(
                    sessionId: sessionId,
                    search: committedSearch.isEmpty ? nil : committedSearch,
                    filter: filter,
                    limit: 20_000))
            guard generation == fetchGeneration else { return }
            selectedIds = Set(result.ids)
            isScopeSelection = true
            if result.truncated {
                GatherToastCenter.shared.show(
                    type: .info,
                    message: String(
                        format: GatherLocalization.l("已选中前 %lld 张（超出单次上限，请缩小筛选范围）"),
                        result.ids.count))
            }
        } catch {
            guard generation == fetchGeneration else { return }
            actionError = CommandError(error)
        }
    }


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
        // load()/reload() 会把 searchActiveWas 复位；退出搜索时不能只看它，
        // 还要看"提交态"是否曾经激活（否则 450 行的链式结果会被留在网格里）。
        let wasActive = searchActiveWas
            || !committedSearch.trimmingCharacters(in: .whitespaces).isEmpty
            || committedFilter != .all
        // D04/D06：查询条件变化即失效在途响应——旧请求返回的行属于上一个查询，
        // 不得 append 进新数据集（cancel 不保证 continuation 请求真的被取消）。
        fetchGeneration += 1
        // D07：选择集跟着查询走（旧实现只在 reload 里清，普通搜索不经过 reload）。
        clearSelectionForNewQuery()
        committedSearch = nextSearch
        committedFilter = filter

        // 退出搜索/筛选：丢弃链式拉取的额外页，保留首页（TS setQueryData
        // pages.slice(0,1)），哨兵恢复自然分页。
        if wasActive && !nextActive {
            pages = Array(pages.prefix(1))
            pagesGeneration += 1
            flatCache = nil
            filteredCache = nil
            pageCursors = Array(pageCursors.prefix(1))
            searchActiveWas = nextActive
            // 退出搜索/筛选：从首页重取，保证 limit 回到 pageSize（而不是
            // 沿用搜索态的 chainFetchLimit），并把哨兵恢复成自然分页。
            Task { await reload() }
            return
        }
        searchActiveWas = nextActive

        if expandVariants != committedExpandVariants {
            Task { await reload() }
            return
        }
        // P1 下一波 §3.7.1：服务端 criteria 下，搜索串变化必须从首页重取。
        // 旧页属于旧 WHERE，链式补页只会把"新的筛选结果"接在"旧的未筛选行"后面。
        if activeCriteria != nil {
            Task { await reload() }
            return
        }
        // 激活搜索/筛选时立即链式拉满（TS chain-fetch effect）。
        if nextActive {
            Task { await chainFetchIfActive() }
        }
    }
}
