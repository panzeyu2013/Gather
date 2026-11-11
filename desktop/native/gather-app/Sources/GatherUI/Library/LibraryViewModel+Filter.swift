// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel+Filter.swift
// Cut 4 / 4c-2j：从 LibraryViewModel.swift 移出筛选提交（原 588-658 行）。
// 纯搬移：四字段 300ms 防抖、criteriaKey 比较（会话筛选并入键）、页码归零、
// 在途响应作废与两个可见计数逐字未动。
import Foundation
import GatherProtocol

extension LibraryViewModel {

    // MARK: 筛选提交（TS useDebouncedValue + criteriaKey 联动）

    /// 任一筛选字段变更后调用：四个自由文本字段 300ms 防抖，其余立即提交。
    /// 提交后 criteriaKey 变化 → 页码归零并重新取数（TS useEffect setPage(0)）。
    public func onFilterChanged() {
        // 规则编辑器也是自由输入：逐键提交会在单连接上堆积 page+facet+count。
        let debouncedTouched = LibraryFilterState.debouncedFields.contains {
            filter[keyPath: $0] != committed[keyPath: $0]
        } || filter.rules != committed.rules
        if debouncedTouched {
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: self?.debounceDelay ?? .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.commitFilter()
            }
        } else {
            debounceTask?.cancel()
            commitFilter()
        }
    }

    /// 会话筛选变更（TS select onChange → 立即生效 + 页码归零）。
    public func onSessionFilterChanged() {
        commitFilter()
    }

    public func clearFilters() {
        filter = LibraryFilterState()
        sessionFilter = ""
        debounceTask?.cancel()
        commitFilter()
    }

    // MARK: - 物理文件夹树（Wave5 batch4 / task-18，F1）

    /// 当前 directory 筛选对应的目录（去掉末尾 "/"；nil = 未按目录筛选）。
    public var selectedDirectoryPath: String? {
        DirectoryFilterRule.normalizedFilterPath(filter.directory)
    }

    /// 点击目录树：选中 → 应用 directory 前缀；再次点击同一目录 → 取消筛选。
    ///
    /// 目录点击是明确动作，**立即提交**（directory 属防抖字段，不能等 300ms）；
    /// 前缀由 DirectoryFilterRule 生成（末尾 "/"，避免兄弟目录前缀误命中）。
    public func toggleDirectoryFilter(_ path: String) {
        let normalized = DirectoryFilterRule.normalizedPath(path)
        guard !normalized.isEmpty else { return }
        // 智能相册会绕过 filters（fetchPage 走 albumPhotos）：目录导航必须退出
        // 相册视图，否则点击目录后网格"看起来没反应"。
        selectedAlbumId = nil
        if DirectoryFilterRule.isSelected(path: normalized, filterPrefix: filter.directory) {
            filter.directory = ""
        } else {
            filter.directory = DirectoryFilterRule.prefix(for: normalized)
        }
        debounceTask?.cancel()
        commitFilter()
    }

    /// 清除目录筛选（面包屑的 xmark / 状态条出口）。
    public func clearDirectoryFilter() {
        guard !filter.directory.isEmpty else { return }
        filter.directory = ""
        debounceTask?.cancel()
        commitFilter()
    }

    /// 会话筛选变更（复用目录树时）：切到别的工作区后，旧工作区根的目录前缀
    /// 会让结果为 0 张——先清掉不属于新根的前缀，再提交一次查询。
    public func onSessionFilterChanged(folderRoot: String?) {
        if let folderRoot {
            let rootPrefix = DirectoryFilterRule.prefix(for: folderRoot)
            let current = filter.directory.trimmingCharacters(in: .whitespaces)
            if !current.isEmpty, !current.hasPrefix(rootPrefix) {
                filter.directory = ""
            }
        }
        commitFilter()
    }

    /// TS: activeFilterCount / advancedFilterCount（trim 后非空的字段数）。
    /// P1 / C：facet 五维与规则编辑器也是"筛选生效"，漏计会让工具栏的
    /// 「清除筛选」在只有 facet 时被 .disabled（LibraryView+Filters），空态也会误判成空库。
    public var activeFilterCount: Int {
        let values: [String] = [
            filter.search, filter.rating, filter.label, filter.status,
            filter.keyword, filter.directory, filter.volume, filter.person,
            filter.duplicates, filter.recentDays,
            filter.camera, filter.lens, filter.iso, filter.year,
        ]
        return values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            + (filter.rules.conditions.isEmpty ? 0 : 1)
    }

    public var advancedFilterCount: Int {
        let values: [String] = [
            filter.keyword, filter.directory, filter.volume, filter.person,
            filter.duplicates, filter.recentDays,
            filter.camera, filter.lens, filter.iso, filter.year,
        ]
        return values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            + (filter.rules.conditions.isEmpty ? 0 : 1)
    }

    private func commitFilter() {
        let newKey = Self.criteriaKey(filter: filter, sessionFilter: sessionFilter)
        committed = filter
        guard newKey != criteriaKey else { return }
        criteriaKey = newKey
        page = 0
        // D06：查询条件变化 → 在途响应作废（相册切换/事件刷新同理）。
        fetchGeneration += 1
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(0, isFirst: true)
        }
    }

    /// TS: criteriaKey = JSON.stringify(criteria)（会话筛选并入键，保证页码归零）。
    static func criteriaKey(filter: LibraryFilterState, sessionFilter: String) -> String {
        let criteria = buildLibraryCriteria(filter)
        let encoded = (try? JSONEncoder().encode(criteria)) ?? Data()
        return "\(sessionFilter)|\(String(data: encoded, encoding: .utf8) ?? "")"
    }
}
