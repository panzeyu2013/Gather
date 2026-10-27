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
