// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Derived.swift
// Cut 4 / 4c-2d：派生数据——searchActive / loadedPhotos / filteredPhotos 记忆化、
// 布局代数与轻量指纹（原 GalleryViewModel.swift 351-356、368-419 行）。
// 纯搬移：过滤语义（all/hasFace/noFace/offline）与缓存键逐字不变；存储属性
// pagesGeneration/flatCache/filteredCache 留在 GalleryViewModel.swift 的类体内。
import Foundation

/// 已加载范围的客户端排序（服务端游标只支持导入序；这里不改变数据集）。
public enum GallerySortMode: String, CaseIterable, Sendable {
    case importOrder
    case filename
    case createdAt
}

extension GalleryViewModel {

    // MARK: 派生（TS loadedPhotos / searchActive / filtered）

    /// TS: searchActive —— **客户端过滤路径**激活时链式拉满整个会话。
    ///
    /// 语义收窄（D5）：criteria 由服务端过滤时（`usesServerCriteria`）不算激活。
    /// 旧实现把 facet / 规则也算进来，于是点一次 facet 就触发
    /// `chainFetchIfActive()`（limit 1000/页）把**整个命中集**拉进内存：
    /// 数据本来就只会有命中行（WHERE 在 SQL 里跑），链式拉满纯属把
    /// 首屏代价绑定到命中集大小上；网格只需要可见的那几页。
    /// 因此服务端 criteria 生效时退回自然分页（limit = pageSize，哨兵滚到哪取到哪），
    /// `searchActive` 只留给"没有 PhotoAPI、必须在内存里筛选"的客户端路径。
    ///
    /// 注意这里取的是**提交态**（committedSearch/committedFilter）与
    /// committedFacetSelection/committedRules——与 `activeCriteria` 同一份输入，
    /// 保证"是否链式拉满"和"是否走服务端 WHERE"不会各自漂移。
    public var searchActive: Bool {
        guard !usesServerCriteria else { return false }
        return !committedSearch.trimmingCharacters(in: .whitespaces).isEmpty
            || committedFilter != .all
            || !committedFacetSelection.values.allSatisfy { $0.isEmpty }
            || !committedRules.conditions.isEmpty
    }
    /// TS: loadedPhotos（全部已加载页拍平 + 同代数缓存的 id 集合）。
    ///
    /// perf-ui task-10：id 集合与照片数组用**同一份**缓存构建，供 body 做 O(1)
    /// 命中判断（GalleryInspector 原先每帧 2 次 `loadedPhotos.contains(where:)`）。
    private func loadedPhotosAndIDs() -> (photos: [GalleryPhotoData], ids: Set<String>) {
        if let flatCache, flatCache.generation == pagesGeneration {
            return (flatCache.photos, flatCache.ids)
        }
        let photos = pages.flatMap { $0 }
        var ids = Set<String>()
        ids.reserveCapacity(photos.count)
        for photo in photos { ids.insert(photo.id) }
        flatCache = (pagesGeneration, photos, ids)
        return (photos, ids)
    }

    /// TS: loadedPhotos（全部已加载页拍平）。
    public var loadedPhotos: [GalleryPhotoData] { loadedPhotosAndIDs().photos }

    /// 已加载照片 id 集合（与 loadedPhotos 同代数、同缓存；O(1) 命中判断用）。
    var loadedPhotoIdSet: Set<String> { loadedPhotosAndIDs().ids }

    /// 已加载照片的 O(1) 查询表（id / 路径 / 变体 / 文件名）。
    ///
    /// perf-ui task-17：定位流程在取页循环里反复 `loadedPhotos.contains`，场景标签
    /// 面板的 `nameFor` 也逐行 `first(where:)`；这里一次构表后全部 O(1)。
    /// 与 `flatCache` 用**同一个** pagesGeneration 失效，重复 id 的语义按"首个"保留。
    struct GalleryLoadedPhotoLookup {
        let ids: Set<String>
        let filepaths: Set<String>
        let variantIDs: Set<String>
        let variantFilepaths: Set<String>
        let filenamesByID: [String: String]
    }

    var loadedPhotoLookup: GalleryLoadedPhotoLookup {
        if let cached = loadedPhotoLookupCache, cached.generation == pagesGeneration {
            return cached.lookup
        }
        let photos = loadedPhotos
        var ids = Set<String>()
        var filepaths = Set<String>()
        var variantIDs = Set<String>()
        var variantFilepaths = Set<String>()
        var filenamesByID: [String: String] = [:]
        ids.reserveCapacity(photos.count)
        filepaths.reserveCapacity(photos.count)
        filenamesByID.reserveCapacity(photos.count)
        for photo in photos {
            ids.insert(photo.id)
            filepaths.insert(photo.filepath)
            // 与旧 `first(where:)` 同义：重复 id 取首个文件名。
            if filenamesByID[photo.id] == nil { filenamesByID[photo.id] = photo.filename }
            for variant in photo.variants {
                variantIDs.insert(variant.photoId)
                variantFilepaths.insert(variant.filepath)
            }
        }
        let lookup = GalleryLoadedPhotoLookup(
            ids: ids,
            filepaths: filepaths,
            variantIDs: variantIDs,
            variantFilepaths: variantFilepaths,
            filenamesByID: filenamesByID)
        loadedPhotoLookupCache = (pagesGeneration, lookup)
        return lookup
    }

    /// TS: filtered —— 客户端过滤（文件名 contains + faceCount 判定）。
    ///
    /// P1 下一波：criteria 走服务端时**不再客户端再筛一遍**——服务端已经按同一套
    /// 语义（4 档 / facet / 规则 / 搜索串）过滤过，再筛一次只会让"只有 3 张命中"
    /// 的查询在网格里变成 0 张（例如 keyword_path 规则命中但文件名不含搜索词）。
    public var filteredPhotos: [GalleryPhotoData] {
        let key = "\(pagesGeneration)|\(committedSearch)|\(committedFilter)|\(usesServerCriteria)|\(sortMode.rawValue)|\(stackFoldVersion)"
        if let filteredCache, filteredCache.key == key {
            return filteredCache.photos
        }
        if usesServerCriteria {
            let photos = Self.folded(
                Self.sorted(loadedPhotos, by: sortMode), index: stackFolds)
            return storeFilteredPhotos(photos, key: key)
        }
        // 过滤词只小写一次（旧实现写在闭包里 = 每行一次分配）。
        let needle = committedSearch.lowercased()
        let filter = committedFilter
        let photos = needle.isEmpty
            ? loadedPhotos.filter { photo in
                switch filter {
                case .all: return true
                case .hasFace: return photo.faceCount > 0
                case .noFace: return photo.faceCount == 0
                case .offline: return photo.status == "missing"
                }
            }
            : loadedPhotos.filter { photo in
                guard photo.filename.lowercased().contains(needle) else { return false }
                switch filter {
                case .all: return true
                case .hasFace: return photo.faceCount > 0
                case .noFace: return photo.faceCount == 0
                case .offline: return photo.status == "missing"
                }
            }
        let sorted = Self.sorted(photos, by: sortMode)
        let folded = Self.folded(sorted, index: stackFolds)
        return storeFilteredPhotos(folded, key: key)
    }

    /// 写入 filtered 缓存，同时构建 id 集合与 id→**首个**下标（供键盘游标/选中定位）。
    private func storeFilteredPhotos(_ photos: [GalleryPhotoData], key: String) -> [GalleryPhotoData] {
        var indexByID: [String: Int] = [:]
        var ids = Set<String>()
        indexByID.reserveCapacity(photos.count)
        ids.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() {
            ids.insert(photo.id)
            if indexByID[photo.id] == nil { indexByID[photo.id] = index }
        }
        filteredCache = (key, photos, ids, indexByID)
        return photos
    }

    /// 选择集的稳定排序快照（按 id 升序、去重、去空串；场景标签种子等 body 派生用）。
    ///
    /// task-22：旧实现每帧 `selectedIds.sorted()` + policy 内再 Set+sort；
    /// 现在按 selectionVersion（O(1) 键）缓存。Observation 依赖：命中缓存也先读
    /// `selectedIds.count`，保证只改选择集时 body 会重算。
    var sortedSelectedIds: [String] {
        let selectionCount = selectedIds.count
        if let cached = sortedSelectionCache, cached.version == selectionVersion {
            return cached.ids
        }
        // 与旧 SceneTagsEntryPolicy.seedPhotoIds 的"去空串后排序"同口径，缓存后每帧 O(1)。
        let ids = selectionCount == 0 ? [] : selectedIds.filter { !$0.isEmpty }.sorted()
        sortedSelectionCache = (selectionVersion, ids)
        return ids
    }

    /// filtered 行的 id 集合（与 filteredPhotos 同一缓存 key；O(1) 命中判断）。
    var filteredPhotoIdSet: Set<String> {
        _ = filteredPhotos
        return filteredCache?.ids ?? []
    }

    /// filtered 行 id→首下标（与 filteredPhotos 同一缓存 key；键盘游标定位 O(1)）。
    var filteredPhotoIndexByID: [String: Int] {
        _ = filteredPhotos
        return filteredCache?.indexByID ?? [:]
    }

    /// 堆栈折叠：每个堆栈只显示代表张（封面优先），徽标由格子读取 badgeCount。
    ///
    /// `compactMap` 是 P1-7 的破口所在：它按 id 回填行，**回填不到就静默丢行**。
    /// 因此 StackFoldIndex 保证 emit 的每个 id 都属于本次输入（封面不在输入里时
    /// 回退该堆首个成员）；这里不需要也不应该再做"补行"——补行会把不在当前
    /// 筛选里的成员塞回网格，等于用折叠绕过筛选。
    private static func folded(
        _ photos: [GalleryPhotoData], index: StackFoldIndex
    ) -> [GalleryPhotoData] {
        guard !index.isEmpty else { return photos }
        let visible = index.visiblePhotoIds(photos.map(\.id))
        guard visible.count != photos.count else { return photos }
        let byId = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return visible.compactMap { byId[$0] }
    }

    /// 已加载范围的稳定排序（同值时按 id 兜底，避免每次重排抖动）。
    private static func sorted(
        _ photos: [GalleryPhotoData], by mode: GallerySortMode
    ) -> [GalleryPhotoData] {
        switch mode {
        case .importOrder:
            return photos
        case .filename:
            return photos.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
                    || ($0.filename == $1.filename && $0.id < $1.id)
            }
        case .createdAt:
            return photos.sorted {
                $0.createdAt > $1.createdAt
                    || ($0.createdAt == $1.createdAt && $0.id < $1.id)
            }
        }
    }

    /// 布局缓存键用的数据代数（替代旧实现每次 body 的 O(n) id 哈希）。
    public var layoutGeneration: Int { pagesGeneration }

    /// 派生数组的轻量指纹（D-3：.onChange 改看它，避免每次 body 深比较整数组）。
    public var filteredFingerprint: String {
        "\(pagesGeneration)|\(committedSearch)|\(committedFilter.rawValue)|\(sortMode.rawValue)|\(filteredPhotos.count)"
    }

    public var hasNextPage: Bool {
        pageCursors.last ?? nil != nil
    }
}
