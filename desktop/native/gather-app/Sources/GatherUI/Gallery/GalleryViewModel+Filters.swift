// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Filters.swift
// P1 下一波 §3.7：Gallery 的服务端筛选面（4 档 + facet + 规则 + 搜索串 → 一个 FilterGroup）。
//
// 为什么合成一个 FilterGroup：
// - facet 计数（PhotoAPI.facets）与网格分页（PhotoAPI.page(criteria:)）必须吃**同一条**
//   WHERE，否则面板数字与列出的行对不上（§3.6 的同口径红线）；
// - 保存查询存的就是这一整份 criteria，恢复 = 整份回填（不再依赖 UI 侧第二份状态）。
//
// 4 档（all/hasFace/noFace/offline）没有内部字段，映射为可公开表达的条件：
// has_face eq bool 与 status eq 'missing'（与 PhotoAPI.select 的口径一致，
// 因此"全选筛选结果"与网格永远同集合）。
import Foundation
import GatherProtocol

extension GalleryViewModel {

    // MARK: - criteria 合成

    /// 已提交的筛选（服务端 criteria）。nil = 无筛选（走旧的客户端过滤路径）。
    ///
    /// 顺序必须稳定（facet 维按名字排序）：保存查询/比较 criteria 时依赖它。
    var activeCriteria: FilterGroup? {
        var conditions: [FilterCondition] = []
        switch committedFilter {
        case .all:
            break
        case .hasFace:
            conditions.append(.rule(FilterRule(field: "has_face", operator: .eq, value: .bool(true))))
        case .noFace:
            conditions.append(.rule(FilterRule(field: "has_face", operator: .eq, value: .bool(false))))
        case .offline:
            conditions.append(.rule(FilterRule(field: "status", operator: .eq, value: .string("missing"))))
        }
        for dimension in committedFacetSelection.keys.sorted() {
            let value = (committedFacetSelection[dimension] ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch dimension {
            case "camera":
                conditions.append(.rule(FilterRule(
                    field: FilterFields.cameraModel, operator: .eq, value: .string(value))))
            case "lens":
                conditions.append(.rule(FilterRule(
                    field: FilterFields.lensModel, operator: .eq, value: .string(value))))
            case "iso":
                if let iso = Int(value) {
                    conditions.append(.rule(FilterRule(
                        field: FilterFields.iso, operator: .eq, value: .number(Double(iso)))))
                }
            case "year":
                conditions.append(.rule(FilterRule(
                    field: FilterFields.dateTaken, operator: .startsWith, value: .string(value))))
            case "label":
                conditions.append(.rule(FilterRule(
                    field: FilterFields.label, operator: .eq, value: .string(value))))
            case "keyword":
                // 层级下钻：命中该节点自身 + 全部子孙（点 A 也看到 A|B）。
                conditions.append(.rule(.keywordPath(value)))
            default:
                break
            }
        }
        if !committedRules.conditions.isEmpty {
            conditions.append(.group(committedRules))
        }
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            conditions.append(.group(Self.searchCriteria(search)))
        }
        guard !conditions.isEmpty else { return nil }
        return FilterGroup(logic: .and, conditions: conditions)
    }

    /// 搜索串的多字段 OR 组。
    ///
    /// Wave2 task-13：字段扩到"文件 + 常用 IPTC 描述性字段 + 关键词"，与
    /// PhotoFilterQuery.jsonFields 的字段 id 逐字一致（服务端 json_extract 投影，
    /// 列表字段走 json_each 的 contains 语义）。数组字段（creator/person_in_image）
    /// 同样用 contains，对元素判定，不会拿整段 JSON 比较。
    static func searchCriteria(_ search: String) -> FilterGroup {
        let fields = [
            "filename", "title", "description", "headline", "creator",
            "copyright", "credit", "source", "usage_terms",
            "city", "state", "country", "event", "sublocation", "person_in_image",
            FilterFields.keywords, "keyword_path",
        ]
        return FilterGroup(logic: .or, conditions: fields.map { field -> FilterCondition in
            .rule(FilterRule(field: field, operator: .contains, value: .string(search)))
        })
    }

    /// 是否走服务端筛选分页（需要 PhotoAPI；预览/旧测试桩为 nil）。
    var usesServerCriteria: Bool { photoAPI != nil && activeCriteria != nil }

    /// facet 查询用的 criteria：与网格同源，只是 keyword 维由 facet 自己剔除。
    var facetCriteria: FilterGroup { activeCriteria ?? FilterGroup(logic: .and, conditions: []) }

    // MARK: - facet

    /// 重新计算 facet（维度顺序固定，便于 UI 稳定布局）。
    func refreshFacets() async {
        guard let photoAPI, !isShutdown else { return }
        let generation = fetchGeneration
        do {
            let input = try PhotoFacetInput(
                sessionId: sessionId,
                criteria: facetCriteria,
                dimensions: Self.facetDimensions,
                limit: 60,
                keywordPrefix: keywordFacetNode)
            let groups = try await photoAPI.facets(input)
            guard generation == fetchGeneration else { return }
            facetGroups = groups
        } catch {
            guard generation == fetchGeneration else { return }
            // facet 失败不清空网格：面板退化为空（不把用户赶出图库）。
            facetGroups = []
            actionError = CommandError(error)
        }
    }

    static var facetDimensions: [String] {
        ["camera", "lens", "iso", "year", "label", "keyword"]
    }

    /// 点 facet：同维单选（再点取消）；keyword 维同时下钻/回退。
    public func selectFacet(dimension: String, value: String) {
        if dimension == "keyword" {
            let current = facetSelection["keyword"] ?? ""
            if value.isEmpty || current == value {
                facetSelection["keyword"] = ""
                keywordFacetNode = nil
            } else {
                facetSelection["keyword"] = value
                keywordFacetNode = value
            }
        } else {
            facetSelection[dimension] = value
        }
        criteriaChanged()
    }

    /// 清除全部 facet（"清除筛选"按钮）。
    public func clearFacetSelection() {
        facetSelection = [:]
        keywordFacetNode = nil
        criteriaChanged()
    }

    // MARK: - 规则编辑器

    /// 规则变化：立即提交（与 facet 一致，不参与搜索防抖）。
    public func applyRules(_ group: FilterGroup) {
        rules = group
        criteriaChanged()
    }

    // MARK: - 提交

    /// 筛选条件变化：失效在途响应 → 清选择 → 重取首页（+ facet）。
    func criteriaChanged() {
        debounceTask?.cancel()
        fetchGeneration += 1
        clearSelectionForNewQuery()
        committedFacetSelection = facetSelection
        committedRules = rules
        committedSearch = search.trimmingCharacters(in: .whitespaces)
        committedFilter = filter
        searchActiveWas = activeCriteria != nil
        // 手动改任一条件后不再代表某条保存查询；applySavedSearch 会在 restore 后回填。
        appliedSearchName = nil
        Task { await reload() }
    }

    // MARK: - 保存查询

    /// 拉取保存查询（全局 + 本会话）。未接线 PhotoAPI 时为空。
    public func refreshSavedSearches() async {
        guard let photoAPI else {
            savedSearches = []
            return
        }
        do {
            savedSearches = try await photoAPI.savedSearches(
                SavedSearchesQuery(sessionId: sessionId))
        } catch {
            savedSearches = []
            actionError = CommandError(error)
        }
    }

    /// 保存当前筛选（同名 = 覆盖）。无筛选时不保存（空查询没有恢复价值）。
    public func saveCurrentSearch(name: String) async {
        guard let photoAPI else { return }
        guard let criteria = activeCriteria else {
            GatherToastCenter.shared.show(type: .info, message: GatherLocalization.l("当前没有筛选条件"))
            return
        }
        do {
            _ = try await photoAPI.saveSearch(SaveSearchInput(
                name: name, sessionId: sessionId, criteria: criteria))
            await refreshSavedSearches()
            GatherToastCenter.shared.show(
                type: .success,
                message: String(
                    format: GatherLocalization.l("已保存查询“%@”"), name))
        } catch {
            actionError = CommandError(error)
        }
    }

    public func deleteSavedSearch(_ id: String) async {
        guard let photoAPI else { return }
        do {
            try await photoAPI.deleteSavedSearch(DeleteSavedSearchInput(id: id))
            await refreshSavedSearches()
        } catch {
            actionError = CommandError(error)
        }
    }

    /// 应用保存的查询：把 criteria 拆回 4 档 / facet / 规则 / 搜索串（整份恢复）。
    ///
    /// 拆不出来的条件一律落进 rules（不丢语义）：宁可规则编辑器里多一行，
    /// 也不能让"恢复查询"少筛一批照片。顶层是 OR 组时不做拆分，整份进 rules。
    public func applySavedSearch(_ search: SavedSearchData) {
        restore(criteria: search.criteria)
        appliedSearchName = search.name
    }

    /// criteria → UI 状态（拆解规则见 applySavedSearch）。
    func restore(criteria: FilterGroup) {
        guard criteria.logic == .and else {
            filter = .all
            self.search = ""
            facetSelection = [:]
            keywordFacetNode = nil
            rules = criteria
            criteriaChanged()
            return
        }
        var nextFilter: GalleryFilter = .all
        var nextSearch = ""
        var nextFacets: [String: String] = [:]
        var leftover: [FilterCondition] = []
        for condition in criteria.conditions {
            switch condition {
            case .rule(let rule):
                switch rule.field {
                case "has_face" where rule.operator == .eq:
                    nextFilter = rule.value.boolValue == true ? .hasFace : .noFace
                case "status" where rule.operator == .eq && rule.value.stringValue == "missing":
                    nextFilter = .offline
                case FilterFields.cameraModel where rule.operator == .eq:
                    nextFacets["camera"] = rule.value.stringValue ?? ""
                case FilterFields.lensModel where rule.operator == .eq:
                    nextFacets["lens"] = rule.value.stringValue ?? ""
                case FilterFields.iso where rule.operator == .eq:
                    if let iso = rule.value.numberValue { nextFacets["iso"] = String(Int(iso)) }
                case FilterFields.label where rule.operator == .eq:
                    nextFacets["label"] = rule.value.stringValue ?? ""
                case FilterFields.dateTaken where rule.operator == .startsWith:
                    nextFacets["year"] = rule.value.stringValue ?? ""
                case FilterFields.keywordPath where rule.operator == .startsWith:
                    nextFacets["keyword"] = rule.value.stringValue ?? ""
                default:
                    leftover.append(.rule(rule))
                }
            case .group(let group):
                if let needle = Self.searchString(in: group), nextSearch.isEmpty {
                    nextSearch = needle
                } else {
                    leftover.append(.group(group))
                }
            }
        }
        filter = nextFilter
        search = nextSearch
        facetSelection = nextFacets
        keywordFacetNode = nextFacets["keyword"]
        rules = FilterGroup(logic: .and, conditions: leftover)
        criteriaChanged()
    }

    /// searchCriteria 用到的字段集合（识别保存查询里的搜索词时按它取反）。
    ///
    /// 与 searchCriteria 生成的条件一一对应。分两处维护是已知风险：新增搜索
    /// 字段却忘了同步这里，搜索词又会还原不出——改动这两处时必须成对检查
    /// （Wave2 task-13 起两处都按同一份字段清单扩展）。
    private static let searchCriteriaFields: Set<String> = [
        "filename",
        "title",
        "description",
        "headline",
        "creator",
        "copyright",
        "credit",
        "source",
        "usage_terms",
        "city",
        "state",
        "country",
        "event",
        "sublocation",
        "person_in_image",
        FilterFields.keywords,
        "keyword_path",
    ]

    /// 识别"搜索串多字段 OR 组"并取出原搜索词（识别不到返回 nil）。
    ///
    /// D4：旧实现要求"组内每条规则都是 filename contains"，而 searchCriteria
    /// 产出的是 filename / title / description / keywords / keyword_path 五字段
    /// OR —— 条件恒不成立，本函数是死分支：恢复保存查询后搜索框永远是空的
    ///（此时再点"保存"，新查询就把原来的搜索词丢掉了）。
    ///
    /// 现在的判定与 searchCriteria 严格互逆：顶层是 OR 且至少一条条件；每条都是
    /// .contains、字段属于上面这五个、取值为同一个非空串。少一条（例如用户手写的
    /// "filename 含 A OR filename 含 B"）就返回 nil，整组落回 rules——宁可规则
    /// 编辑器里多一行，也不能让恢复查询丢语义。
    static func searchString(in group: FilterGroup) -> String? {
        guard group.logic == .or, !group.conditions.isEmpty else { return nil }
        var needle: String?
        for condition in group.conditions {
            guard case .rule(let rule) = condition, rule.operator == .contains,
                  searchCriteriaFields.contains(rule.field),
                  let value = rule.value.stringValue,
                  !value.isEmpty else { return nil }
            if let needle, needle != value { return nil }
            needle = value
        }
        return needle
    }
}
