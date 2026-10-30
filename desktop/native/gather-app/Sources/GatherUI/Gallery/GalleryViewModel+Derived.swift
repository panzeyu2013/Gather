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

    /// TS: searchActive —— 搜索或筛选激活时链式拉满整个会话。
    ///
    /// P1 下一波：服务端 criteria（facet / 规则）也算激活——它们同样把数据集
    /// 从"整会话"缩成"命中集"，只是过滤发生在 SQL 里。
    public var searchActive: Bool {
        !committedSearch.trimmingCharacters(in: .whitespaces).isEmpty
            || committedFilter != .all
            || !committedFacetSelection.values.allSatisfy { $0.isEmpty }
            || !committedRules.conditions.isEmpty
    }
    /// TS: loadedPhotos（全部已加载页拍平）。
    public var loadedPhotos: [GalleryPhotoData] {
        if let flatCache, flatCache.generation == pagesGeneration {
            return flatCache.photos
        }
        let photos = pages.flatMap { $0 }
        flatCache = (pagesGeneration, photos)
        return photos
    }

    /// TS: filtered —— 客户端过滤（文件名 contains + faceCount 判定）。
    ///
    /// P1 下一波：criteria 走服务端时**不再客户端再筛一遍**——服务端已经按同一套
    /// 语义（4 档 / facet / 规则 / 搜索串）过滤过，再筛一次只会让"只有 3 张命中"
    /// 的查询在网格里变成 0 张（例如 keyword_path 规则命中但文件名不含搜索词）。
    public var filteredPhotos: [GalleryPhotoData] {
        let key = "\(pagesGeneration)|\(committedSearch)|\(committedFilter)|\(usesServerCriteria)|\(sortMode.rawValue)"
        if let filteredCache, filteredCache.key == key {
            return filteredCache.photos
        }
        if usesServerCriteria {
            let photos = Self.sorted(loadedPhotos, by: sortMode)
            filteredCache = (key, photos)
            return photos
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
        filteredCache = (key, sorted)
        return sorted
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
