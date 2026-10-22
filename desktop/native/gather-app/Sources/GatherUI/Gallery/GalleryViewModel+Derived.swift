// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Derived.swift
// Cut 4 / 4c-2d：派生数据——searchActive / loadedPhotos / filteredPhotos 记忆化、
// 布局代数与轻量指纹（原 GalleryViewModel.swift 351-356、368-419 行）。
// 纯搬移：过滤语义（all/hasFace/noFace/offline）与缓存键逐字不变；存储属性
// pagesGeneration/flatCache/filteredCache 留在 GalleryViewModel.swift 的类体内。
import Foundation

extension GalleryViewModel {

    // MARK: 派生（TS loadedPhotos / searchActive / filtered）

    /// TS: searchActive —— 搜索或筛选激活时链式拉满整个会话。
    public var searchActive: Bool {
        !committedSearch.trimmingCharacters(in: .whitespaces).isEmpty || committedFilter != .all
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
    public var filteredPhotos: [GalleryPhotoData] {
        let key = "\(pagesGeneration)|\(committedSearch)|\(committedFilter)"
        if let filteredCache, filteredCache.key == key {
            return filteredCache.photos
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
        filteredCache = (key, photos)
        return photos
    }

    /// 布局缓存键用的数据代数（替代旧实现每次 body 的 O(n) id 哈希）。
    public var layoutGeneration: Int { pagesGeneration }

    /// 派生数组的轻量指纹（D-3：.onChange 改看它，避免每次 body 深比较整数组）。
    public var filteredFingerprint: String {
        "\(pagesGeneration)|\(committedSearch)|\(committedFilter.rawValue)|\(filteredPhotos.count)"
    }

    public var hasNextPage: Bool {
        pageCursors.last ?? nil != nil
    }
}
