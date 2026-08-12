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
    /// 工作区索引状态（workspace.status；indexing 字段由主进程按
    /// metadata.scan job 派生，供索引头推导）。测试 stub 未实现时返回 nil。
    func workspaceStatus(_ sessionId: String) throws -> WorkspaceStatus?
    /// 重新入队索引扫描（TS indexerApi.scan / SessionDetail handleRetryIndex）。
    func retryIndex(sessionId: String) async throws
}

public extension GalleryDataProvider {
    /// 网格缩略图目标解码尺寸（TS Gallery.tsx:50-55：settings thumbnail_size
    /// 分桶 → ≤320→256、≤1280→1024、>1280→2048）。测试 stub 未实现时取默认。
    func thumbnailSize() -> Int { 1024 }

    func workspaceStatus(_ sessionId: String) throws -> WorkspaceStatus? { nil }

    func retryIndex(sessionId: String) async throws {
        throw NativeCommandError.failed("INDEX_SCAN_NOT_SUPPORTED")
    }
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

    /// TS: Gallery.tsx:50-55 —— settings thumbnail_size（默认 1024）分桶映射。
    public func thumbnailSize() -> Int {
        let raw = (try? router.execute("settings.get", params: ["key": .string("thumbnail_size")]))?.stringValue ?? ""
        return Self.thumbnailBucket(Int(raw) ?? 1024)
    }

    /// TS: thumbnail_size → 解码尺寸：≤320→256、≤1280→1024、>1280→2048。
    public static func thumbnailBucket(_ value: Int) -> Int {
        switch value {
        case ...320: return 256
        case 321...1280: return 1024
        default: return 2048
        }
    }

    /// TS: workspace.status —— indexing job 派生（quque/running/cancelling →
    /// active；succeeded → stage indexed；failed → failed）。
    public func workspaceStatus(_ sessionId: String) throws -> WorkspaceStatus? {
        try router.execute("workspace.status", params: [
            "sessionId": .string(sessionId),
        ]).decoded(as: WorkspaceStatus.self)
    }

    /// TS: indexerApi.scan —— 建 metadata.scan job 即返回（走 async 通道）。
    public func retryIndex(sessionId: String) async throws {
        _ = try await NativeCommandClient(router: router).executeAsync(
            "index.scan",
            params: ["sessionId": .string(sessionId)]
        )
    }
}

/// TS: Gallery.tsx FILTER_OPTIONS（hasFace/noFace 客户端过滤）。
public enum GalleryFilter: String, CaseIterable, Sendable {
    case all
    case hasFace
    case noFace
}

/// TS: indexProgress.ts IndexHeaderCopy（kind/text/percent 三元组）。
public struct GalleryIndexHeaderCopy: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case scanning
        case error
        case count
    }

    public let kind: Kind
    public let text: String
    /// 确定性进度 0-100（文案内联「（x%）」）；扫描中无数值时为 nil。
    public let percent: Int?

    public init(kind: Kind, text: String, percent: Int?) {
        self.kind = kind
        self.text = text
        self.percent = percent
    }
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

    /// 索引状态轮询间隔：扫描活跃 3s（进度跟手），空闲 15s 兜底
    /// （对齐 SessionControlView.pollInterval 模式）。
    static let activeStatusPollInterval: Duration = .seconds(3)
    static let idleStatusPollInterval: Duration = .seconds(15)
    /// jobs:progress 帧去抖窗口（事件风暴只刷新一次状态）。
    static let progressFrameDebounceSeconds: TimeInterval = 1

    public let sessionId: String
    private let provider: GalleryDataProvider
    private let debounceDelay: Duration
    private var debounceTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    /// 索引状态轮询任务（视图可见时启动；opacity 常驻架构下由视图门控）。
    private var statusPollTask: Task<Void, Never>?
    /// 距上次 workspace.status 刷新时刻（progress 帧去抖）。
    private var lastStatusRefreshAt = Date.distantPast
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
    /// 网格缩略图解码尺寸（load() 时经 provider 读取 settings thumbnail_size 分桶）。
    private(set) public var thumbnailSize = 1024
    /// 工作区索引状态（workspace.status；索引头数据源，轮询 + 事件驱动）。
    private(set) public var workspaceStatus: WorkspaceStatus?
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
        // RootView 用 opacity 常驻视图：切换 session 时 VM 被替换但视图身份不变，
        // .task(id:) 重启可能晚于本实例生效 —— init 立即补载，保证新 VM 不滞留 loading。
        Task { [weak self] in
            await self?.loadIfNeeded()
        }
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

    // MARK: 索引头推导（TS indexProgress.ts deriveIndexHeaderCopy:32-63 +
    //         workspace-view.ts deriveWorkspaceHeaderCopy:289-322）

    /// 索引头文案纯推导（可单测；nonisolated：不依赖任何实例状态）：
    /// 扫描活跃/失败期间绝不把阶段计数当权威数据展示；photoCount==0 且无
    /// 扫描任务时整行不渲染（返回 nil，对齐旧版 render null，而非「暂无照片」）。
    /// - 扫描中（active/created 窗口）且有数值：「正在索引 N / M（x%）」，
    ///   percent = min(100, round(N/M*100)) 自算并内联进文案；
    /// - 扫描中无数值：「扫描中…」（无进度条）；
    /// - 失败：「索引失败」（视图附「重试」按钮）；
    /// - 索引成功（stage == .indexed）或从未扫描：「已索引 N 张照片」；
    ///   截断导入在精确总数落定前保留「已索引 ≥N 张照片」。
    nonisolated public static func indexHeaderCopy(
        status: WorkspaceStatus?,
        photoCount: Int,
        truncatedImport: Bool
    ) -> GalleryIndexHeaderCopy? {
        if let status, status.stage == .created || status.indexing.status == .active {
            if status.indexing.total > 0, status.indexing.done > 0 {
                // TS: percent = Math.min(100, Math.round(current/total*100))。
                let percent = min(100, Int((Double(status.indexing.done) / Double(status.indexing.total) * 100).rounded()))
                return GalleryIndexHeaderCopy(
                    kind: .scanning,
                    text: "正在索引 \(status.indexing.done) / \(status.indexing.total)（\(percent)%）",
                    percent: percent
                )
            }
            return GalleryIndexHeaderCopy(kind: .scanning, text: "扫描中…", percent: nil)
        }
        if let status, status.indexing.status == .failed {
            return GalleryIndexHeaderCopy(kind: .error, text: "索引失败", percent: nil)
        }
        // 无 job / 已成功（stage == .indexed）：photoCount==0 → 不渲染。
        if photoCount == 0 { return nil }
        if truncatedImport, status?.stage != .indexed {
            return GalleryIndexHeaderCopy(kind: .count, text: "已索引 ≥\(photoCount) 张照片", percent: nil)
        }
        return GalleryIndexHeaderCopy(kind: .count, text: "已索引 \(photoCount) 张照片", percent: nil)
    }

    // MARK: 索引状态数据源（workspace.status 轮询 + jobs:progress 事件）

    // MARK: 加载

    func load() async {
        phase = .loading
        do {
            session = try provider.getSession(sessionId)
        } catch {
            actionError = Self.message(for: error)
        }
        thumbnailSize = provider.thumbnailSize()
        await refreshWorkspaceStatus()
        await reload()
    }

    /// 补载入口（.task(id:)/onChange/init 共用）：仅当从未成功加载时取首页，
    /// 避免同一次会话切换的多路触发重复取页；失败态不自动重试（由视图「重试」按钮 load()）。
    func loadIfNeeded() async {
        guard pages.isEmpty, phase == .loading else { return }
        await load()
    }

    /// 重置并取第一页（TS queryKey ['photos', sessionId, expandVariants] 变更）。
    private func reload() async {
        // 取消在途链式拉取（chain-fetch 循环每次迭代检查取消），防止与
        // 重置后的首页竞态（isFetchingNextPage 早退导致 phase 滞留 loading）。
        fetchTask?.cancel()
        fetchTask = nil
        pages = []
        pageCursors = []
        committedSearch = search.trimmingCharacters(in: .whitespaces)
        committedFilter = filter
        committedExpandVariants = expandVariants
        searchActiveWas = false
        phase = .loading
        await fetchNextPage(isFirst: true)
        // 兜底：即使在途取页早退（guard 拦截），reload 完成后也不滞留 loading。
        if phase == .loading { phase = .loaded }
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

    /// 视图可见时启动索引状态轮询（活跃 3s / 空闲 15s；任务随 VM 释放）。
    public func startIndexStatusPolling() {
        guard statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshWorkspaceStatus()
                let interval: Duration = self.workspaceStatus?.indexing.status == .active
                    ? Self.activeStatusPollInterval : Self.idleStatusPollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 视图隐藏时停止轮询（opacity 常驻架构：避免后台空转）。
    public func stopIndexStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = nil
    }

    /// jobs:progress 帧（metadata.scan）：1s 去抖后刷新索引状态，进度更跟手。
    public func handleIndexJobProgress(_ event: GatherJobEvent) {
        guard event.job.type == .metadataScan, event.job.scopeId == sessionId else { return }
        guard Date().timeIntervalSince(lastStatusRefreshAt) >= Self.progressFrameDebounceSeconds else { return }
        Task { await refreshWorkspaceStatus() }
    }

    /// 重取工作区索引状态（best-effort：失败保留旧值，不打断浏览）。
    func refreshWorkspaceStatus() async {
        lastStatusRefreshAt = Date()
        do {
            workspaceStatus = try provider.workspaceStatus(sessionId)
        } catch {
            // 索引头为辅助信息：瞬时失败静默保留旧状态，不整页报错。
        }
    }

    /// TS handleRetryIndex：重新入队 metadata.scan；入队后立即刷新状态
    ///（JobService 同步建行 → workspace.status 即报 active → 头显「扫描中…」）。
    public func retryIndex() async {
        do {
            try await provider.retryIndex(sessionId: sessionId)
        } catch {
            actionError = Self.message(for: error)
        }
        await refreshWorkspaceStatus()
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
        // 链式拉取挂到 fetchTask：reload/事件刷新可取消在途循环（弱引用防环）。
        fetchTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            while self.searchActive && self.hasNextPage && !self.isFetchingNextPage {
                do { try Task.checkCancellation() } catch { return }
                _ = await self.fetchNextPage(isFirst: false)
            }
        }
        fetchTask = task
        try? await task.value
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
            return GatherLocalization.errorText(sessionError.gatherCode.rawValue)
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }

    // MARK: 终态事件刷新（对齐 TS 事件失效语义）

    /// 终态事件驱动的按需刷新：500ms 合并连续终态帧（索引结束多帧风暴
    /// 只触发一次重载），替代“打开即快照”的过期展示。
    public func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshOnEvent()
        }
    }

    /// 重取会话与当前查询（react-query invalidate 语义：终态事件后页面
    /// 立即反映照片补齐/元数据变化）。
    /// P15：不重置页码——从首页重新拉取直至重新覆盖原已加载数量，网格与
    /// 滚动位置就地更新（页面保持 loaded，全程不闪 loading），不再回卷首页。
    func refreshOnEvent() async {
        do {
            session = try provider.getSession(sessionId)
        } catch {
            actionError = Self.message(for: error)
        }
        await refreshWorkspaceStatus()
        let targetCount = loadedPhotos.count
        fetchTask?.cancel()
        var nextPages: [[GalleryPhotoData]] = []
        var nextCursors: [Int64?] = []
        do {
            var cursor: Int64?
            repeat {
                let result = try provider.photoPage(
                    sessionId: sessionId,
                    afterFirstRowid: cursor,
                    limit: searchActive ? Self.chainFetchLimit : Self.pageSize,
                    expandVariants: committedExpandVariants
                )
                nextPages.append(result.rows)
                nextCursors.append(result.cursor)
                cursor = result.cursor
                // 逐页让出主线程，避免大深度重取一帧卡死。
                await Task.yield()
            } while cursor != nil && nextPages.reduce(0, { $0 + $1.count }) < targetCount
            pages = nextPages
            pageCursors = nextCursors
        } catch {
            // 重取失败：保留旧网格（就地语义），仅提示错误。
            actionError = Self.message(for: error)
        }
        // 搜索/筛选态链式拉满保证过滤结果的全局完整性（对齐 commitSearch）。
        if searchActive {
            await chainFetchIfActive()
        }
        if phase == .loading { phase = .loaded }
    }
}
