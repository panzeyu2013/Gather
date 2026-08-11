// desktop/native/gather-app/Sources/GatherApp/Gallery/GalleryViewModel.swift
// Phase 3.2 Gallery（工作区浏览）：视图模型（服务可注入，同进程直连路由）。
// TS 源: desktop/src/renderer/pages/SessionDetail/Gallery.tsx（useInfiniteQuery
//       keyset 分页 / searchActive 链式拉满 / 退出搜索保留首页 / 客户端过滤）
//       + api/session.ts getPhotosPage（photo.list_page 形状）
//
// 差异说明（有意）：
// - TS 的 useInfiniteQuery 缓存层 → 显式 pages 数组 + keyset 游标；
// - useDeferredValue(search)（无超时的并发渲染延迟）→ 300ms 防抖提交
//   （测试可注入；语义等价：过滤结果滞后于输入）；
// - IntersectionObserver 哨兵 → 视图滚近末尾调用 loadMoreIfNeeded()。
import Foundation
import GatherCore

/// TS: photo.list_page 的 rows 元素（photo.ipc.ts assemblePhotos 输出形状）。
public struct GalleryPhotoData: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let hasExistingXmp: Bool
    public let faceCount: Int
    public let width: Int
    public let height: Int
    public let status: String
    public let variantCount: Int
    public let variants: [GalleryVariantData]
    public let createdAt: String
    public let updatedAt: String
    public let assetId: String?
    // metadata/result 在路由装配中恒为 {}，解码忽略。

    public init(
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        checksum: String,
        hasExistingXmp: Bool,
        faceCount: Int,
        width: Int,
        height: Int,
        status: String,
        variantCount: Int,
        variants: [GalleryVariantData],
        createdAt: String,
        updatedAt: String,
        assetId: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.hasExistingXmp = hasExistingXmp
        self.faceCount = faceCount
        self.width = width
        self.height = height
        self.status = status
        self.variantCount = variantCount
        self.variants = variants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assetId = assetId
    }
}

/// TS: PhotoVariantData（assemblePhotos 的 variants 元素）。
public struct GalleryVariantData: Codable, Equatable, Sendable {
    public let photoId: String
    public let filepath: String
    public let filename: String
    public let role: String

    public init(photoId: String, filepath: String, filename: String, role: String) {
        self.photoId = photoId
        self.filepath = filepath
        self.filename = filename
        self.role = role
    }
}

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态）或
/// 真实路由（LiveGalleryDataProvider + 临时 SQLite）。
public protocol GalleryDataProvider {
    func getSession(_ sessionId: String) throws -> SessionData?
    /// TS: sessionApi.getPhotosPage → { rows, cursor }。
    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) throws -> (rows: [GalleryPhotoData], cursor: Int64?)
}

/// 真实实现：同进程直连 SessionCommandRouter（photo.list_page 的资产分组/
/// 变体装配以路由为唯一事实源）。
public final class LiveGalleryDataProvider: GalleryDataProvider {
    private let router: SessionCommandRouter

    public init(router: SessionCommandRouter) {
        self.router = router
    }

    public func getSession(_ sessionId: String) throws -> SessionData? {
        try router.sessionService.getSession(sessionId)
    }

    public func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        let response = try router.execute("photo.list_page", params: [
            "sessionId": .string(sessionId),
            "afterFirstRowid": afterFirstRowid.map { .number(Double($0)) } ?? .null,
            "limit": .number(Double(limit)),
            "expandVariants": .bool(expandVariants),
        ])
        let object = response.objectValue ?? [:]
        let rows: [GalleryPhotoData] = try (object["rows"] ?? .array([])).decoded(as: [GalleryPhotoData].self)
        let cursor = object["cursor"]?.numberValue.map(Int64.init)
        return (rows, cursor)
    }
}

/// TS: Gallery.tsx FILTER_OPTIONS（hasFace/noFace 客户端过滤）。
public enum GalleryFilter: String, CaseIterable, Sendable {
    case all
    case hasFace
    case noFace
}

/// 工作区图库视图模型：photo.list_page 键集分页 + 客户端搜索/人脸过滤。
@MainActor
@Observable
public final class GalleryViewModel {
    public enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// TS: PAGE_SIZE = 200（非搜索态）；搜索/筛选态链式拉满用 1000。
    public static let pageSize = 200
    public static let chainFetchLimit = 1_000

    public let sessionId: String
    private let provider: GalleryDataProvider
    private let debounceDelay: Duration
    private var debounceTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var pages: [[GalleryPhotoData]] = []
    private var pageCursors: [Int64?] = []
    /// 提交后的搜索词（TS useDeferredValue 语义）。
    private var committedSearch = ""
    private var committedFilter: GalleryFilter = .all
    private var committedExpandVariants = false
    private var searchActiveWas = false

    private(set) public var phase: LoadPhase = .loading
    private(set) public var session: SessionData?
    private(set) public var isFetchingNextPage = false
    private(set) public var actionError: String?
    private(set) public var selectedIds: Set<String> = []
    /// 搜索输入框实时值（视图绑定；经 searchChanged 提交）。
    public var search = ""
    /// 客户端过滤（对齐 TS FILTER_OPTIONS）。
    public var filter: GalleryFilter = .all
    /// RAW/JPEG 变体展开（对齐 TS expandVariants toggle）。
    public var expandVariants = false

    public init(sessionId: String, provider: GalleryDataProvider, debounceDelay: Duration = .milliseconds(300)) {
        self.sessionId = sessionId
        self.provider = provider
        self.debounceDelay = debounceDelay
    }

    // MARK: 派生（TS loadedPhotos / searchActive / filtered）

    /// TS: searchActive —— 搜索或筛选激活时链式拉满整个会话。
    public var searchActive: Bool {
        !committedSearch.trimmingCharacters(in: .whitespaces).isEmpty || committedFilter != .all
    }

    /// TS: loadedPhotos（全部已加载页拍平）。
    public var loadedPhotos: [GalleryPhotoData] {
        pages.flatMap { $0 }
    }

    /// TS: filtered —— 客户端过滤（文件名 contains + faceCount 判定）。
    public var filteredPhotos: [GalleryPhotoData] {
        loadedPhotos.filter { photo in
            if !committedSearch.isEmpty {
                guard photo.filename.lowercased().contains(committedSearch.lowercased()) else { return false }
            }
            switch committedFilter {
            case .all: return true
            case .hasFace: return photo.faceCount > 0
            case .noFace: return photo.faceCount == 0
            }
        }
    }

    public var hasNextPage: Bool {
        pageCursors.last ?? nil != nil
    }

    // MARK: 加载

    func load() async {
        phase = .loading
        do {
            session = try provider.getSession(sessionId)
        } catch {
            actionError = Self.message(for: error)
        }
        await reload()
    }

    /// 重置并取第一页（TS queryKey ['photos', sessionId, expandVariants] 变更）。
    private func reload() async {
        fetchTask?.cancel()
        pages = []
        pageCursors = []
        committedSearch = search.trimmingCharacters(in: .whitespaces)
        committedFilter = filter
        committedExpandVariants = expandVariants
        searchActiveWas = false
        phase = .loading
        await fetchNextPage(isFirst: true)
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
        committedSearch = nextSearch
        committedFilter = filter

        // 退出搜索/筛选：丢弃链式拉取的额外页，保留首页（TS setQueryData
        // pages.slice(0,1)），哨兵恢复自然分页。
        if searchActiveWas && !nextActive {
            pages = Array(pages.prefix(1))
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

    // MARK: 滚动加载（TS sentinel + chain-fetch effect）

    /// 视图滚近末尾时调用：非搜索态取下一页；搜索/筛选态链式拉满。
    public func loadMoreIfNeeded() async {
        // TS Gallery.tsx:118 —— 无更多页时哨兵不触发取页（含空页确认后的
        // 终态；搜索态由 chainFetchIfActive 内部再判）。
        guard !pages.isEmpty, hasNextPage, !isFetchingNextPage else { return }
        if searchActive {
            await chainFetchIfActive()
        } else {
            _ = await fetchNextPage(isFirst: false)
        }
    }

    private func chainFetchIfActive() async {
        guard searchActive, hasNextPage, !isFetchingNextPage else { return }
        while searchActive && hasNextPage && !isFetchingNextPage {
            _ = await fetchNextPage(isFirst: false)
        }
    }

    /// 取下一页（键集游标）；返回是否还有更多页。
    @discardableResult
    private func fetchNextPage(isFirst: Bool) async -> Bool {
        guard !isFetchingNextPage else { return hasNextPage }
        isFetchingNextPage = true
        defer { isFetchingNextPage = false }
        do {
            let cursor = pageCursors.last ?? nil
            // TS Gallery.tsx:69-71 —— limit 由 searchActive 决定（搜索态 1000
            // 减短链式拉取的往返次数，非搜索态 200）。
            let limit = searchActive ? Self.chainFetchLimit : Self.pageSize
                let result = try provider.photoPage(
                sessionId: sessionId,
                afterFirstRowid: cursor,
                limit: limit,
                expandVariants: committedExpandVariants
            )
            pages.append(result.rows)
            pageCursors.append(result.cursor)
            if phase == .loading { phase = .loaded }
            return result.cursor != nil
        } catch {
            if pages.isEmpty && phase == .loading {
                phase = .failed(Self.message(for: error))
            } else {
                actionError = Self.message(for: error)
            }
            return false
        }
    }

    // MARK: 选择（TS toggleSelect / clearSelection）

    public func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    public func clearSelection() {
        selectedIds = []
    }

    // MARK: 错误 message（对齐 DashboardViewModel.message）

    static func message(for error: Error) -> String {
        if let sessionError = error as? SessionServiceError {
            return sessionError.gatherCode.rawValue
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }
}
