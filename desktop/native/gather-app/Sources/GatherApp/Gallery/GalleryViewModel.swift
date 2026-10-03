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
/// Swift 6 迁移：协议继承 Sendable（实现类构造后不再变更存储状态——
/// Live 实现仅持有不可变 router），使 @MainActor ViewModel 可在 async 调用中
/// 安全地把 provider existential 送出当前隔离域。
public protocol GalleryDataProvider: Sendable {
    func getSession(_ sessionId: String) throws -> SessionData?
    /// TS: sessionApi.getPhotosPage → { rows, cursor }。
    /// async：分页投影经 executeAsync 后台执行（避免 @MainActor 主线程阻塞）。
    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?)
    /// 工作区索引状态（workspace.status；indexing 字段由主进程按
    /// metadata.scan job 派生，供索引头推导）。测试 stub 未实现时返回 nil。
    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus?
    /// 重新入队索引扫描（TS indexerApi.scan / SessionDetail handleRetryIndex）。
    func retryIndex(sessionId: String) async throws
    /// 网格缩略图目标解码尺寸（settings thumbnail_size 分桶）。**必须作为 requirement
    /// 声明**：ViewModel 持有 existential，只在 extension 给默认实现会让 Live 实现
    /// 永远不被调用（用户设置失效）。
    func thumbnailSize() -> Int
}

public extension GalleryDataProvider {
    /// 网格缩略图目标解码尺寸（TS Gallery.tsx:50-55：settings thumbnail_size
    /// 分桶 → ≤320→256、≤1280→1024、>1280→2048）。测试 stub 未实现时取默认。
    func thumbnailSize() -> Int { 1024 }

    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? { nil }

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
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        let response = try await NativeCommandClient(router: router).executeAsync("photo.list_page", params: [
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
    public func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? {
        try await NativeCommandClient(router: router).executeAsync("workspace.status", params: [
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
    /// D10：控制中心「N 张照片离线」的落点——离线照片此前只能"进入浏览"，
    /// 没有任何筛选语义能直接看到它们。
    case offline
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
    /// 数据代数（D04/D06）：任何改变数据集的操作（reload / 变体提交 / 搜索筛选提交 /
    /// 事件重载）都递增。在途请求返回后代数不符即整份作废。
    ///
    /// 旧实现只 `fetchTask?.cancel()`：取消的是链式循环 Task，而 NativeCommandClient
    /// 的 continuation 请求不会被真正取消，响应回来后仍无条件 append/覆盖，
    /// 于是「切变体后旧页从 p200 开始」「旧筛选计数覆盖新筛选」都能发生。
    private var fetchGeneration = 0
    /// 索引头请求序号（P2-9）：只接受最新一次 workspace.status 的结果。
    private var statusRequestID = 0
    /// 显式 load 的串行化任务（见 load()）。
    private var loadTask: Task<Void, Never>?
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
    /// 在途取页所属的数据代数（D04）；nil = 空闲。
    ///
    /// 旧实现是一个全局 Bool：reload（切变体/换筛选）时旧请求仍在途，新首页请求
    /// 被这个 Bool 直接拒绝 → 清空后的首页永远补不回来（实测数组从 p200 开始）。
    /// 改为按代数记账：同一代数内仍只允许一个在途请求，跨代数不互相阻塞，
    /// 旧请求返回时也不会误清新代数的在途标记。
    private var fetchingGeneration: Int?

    public var isFetchingNextPage: Bool { fetchingGeneration != nil }
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

    /// pages 变更代数（D-3 性能审计：派生数组记忆化的失效依据）。
    ///
    /// 旧实现 loadedPhotos/filteredPhotos 是纯计算属性：GalleryView 有 9 处读取，
    /// 其中 2 处在 body 求值路径、1 处在 .onChange(of:) 的深比较里 ⇒ 每次 body
    /// 要 flatMap+filter 各若干遍（1 万行含 lowercased 实测 3.6-3.9ms/遍）。
    /// 现在按代数 + 过滤参数缓存，只在真的变化时重算。
    private var pagesGeneration = 0
    private var flatCache: (generation: Int, photos: [GalleryPhotoData])?
    private var filteredCache: (key: String, photos: [GalleryPhotoData])?

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
                    text: String(format: GatherLocalization.l("正在索引 %lld / %lld（%lld%%）"), status.indexing.done, status.indexing.total, percent),
                    percent: percent
                )
            }
            return GalleryIndexHeaderCopy(kind: .scanning, text: GatherLocalization.l("扫描中…"), percent: nil)
        }
        if let status, status.indexing.status == .failed {
            return GalleryIndexHeaderCopy(kind: .error, text: GatherLocalization.l("索引失败"), percent: nil)
        }
        // 无 job / 已成功（stage == .indexed）：photoCount==0 → 不渲染。
        if photoCount == 0 { return nil }
        if truncatedImport, status?.stage != .indexed {
            return GalleryIndexHeaderCopy(kind: .count, text: String(format: GatherLocalization.l("已索引 ≥%lld 张照片"), photoCount), percent: nil)
        }
        return GalleryIndexHeaderCopy(kind: .count, text: String(format: GatherLocalization.l("已索引 %lld 张照片"), photoCount), percent: nil)
    }

    // MARK: 索引状态数据源（workspace.status 轮询 + jobs:progress 事件）

    // MARK: 加载

    func load() async {
        // 单飞加载：init 自动补载与显式 load（重试/深链）并发时合并为同一轮，
        // 后者直接等待前者结果，避免两轮加载互相覆盖（fetchNextPage 的
        // isFetchingNextPage 早退会把 phase 兜底成 loaded）。
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
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
        // P1-1（审计 2）：reload 必须**自己**递增代数。旧实现只清理数组：
        // 此时若仍有同代取页在途（滚动预取/哨兵/定位都不受 fetchTask 管理），
        // 新首页会被 fetchNextPage 的「同代拒绝」挡掉 → phase 兜成 loaded →
        // 界面显示「暂无照片」，随后旧响应（代数没变，校验通过）把旧游标之后的
        // 行 append 进空数组 → 网格从 p200 开始（D04 症状从 ⌘R/刷新路径复现）。
        fetchGeneration += 1
        pages = []
        pagesGeneration += 1
        flatCache = nil
        filteredCache = nil
        pageCursors = []
        committedSearch = search.trimmingCharacters(in: .whitespaces)
        committedFilter = filter
        committedExpandVariants = expandVariants
        searchActiveWas = false
        phase = .loading
        // 第三轮审计 C-#3 + 深度审查 D07：换筛选/搜索后，选择集必须收敛到
        //「还会出现」的照片。清空必须发生在**所有**改查询的入口（不只 reload）：
        // 普通搜索走 commitSearch，不经过 reload，旧选择会留在隐藏项上。
        clearSelectionForNewQuery()
        await fetchNextPage()
        // A1（审计 4）：筛选/搜索态的**首页只有一页 limit**，客户端过滤要看到全局结果
        // 必须链式拉满。旧实现把链式拉满只放在 commitSearch 里，而「进入页面时带着
        // 筛选意图」（控制中心『N 张离线 → 查看』）路径上 commitSearch 早于首页加载，
        // hasNextPage 还是 false → 空转 → 用户停在「没有符合条件的照片」的死态。
        if searchActive {
            await chainFetchIfActive()
        }
        // 兜底：仅在本轮没有在途请求时收尾（有在途请求时由它自己写 phase）。
        // 旧实现无条件兜底：首页被拒时会把「空数据集」标成 loaded，用户看到假空态。
        if phase == .loading, fetchingGeneration == nil { phase = .loaded }
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
        // P2-9（审计 2）：索引头有四个并发调用方（load / 轮询 / 进度帧去抖 / 重试），
        // 旧响应后到会让进度百分比与阶段回退。只接受最新一次请求的结果。
        statusRequestID += 1
        let requestID = statusRequestID
        do {
            let status = try await provider.workspaceStatus(sessionId)
            guard requestID == statusRequestID else { return }
            workspaceStatus = status
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
            _ = await fetchNextPage()
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
                let before = self.pages.count
                let hadMore = await self.fetchNextPage()
                // D05：任一失败（或无进展）立即终止链式取数。旧实现忽略返回值——
                // 下一页持续失败时游标仍在，循环条件恒成立，用户没点重试就自动
                // 发出 21+ 次请求。保留已加载结果，把重试留给用户（滚动/重试）。
                // pages 无增长同时挡住「并发取页早退返回 hasNextPage=true」的自旋。
                guard hadMore, self.pages.count > before else { return }
            }
        }
        fetchTask = task
        // Task 的失败类型为 Never（内部 do/catch 已吞掉取消），无需 try?
        await task.value
    }

    /// D08：把目标照片定位到已加载数据集里。
    ///
    /// 旧实现只在 filteredPhotos 里查找：初始页大小 200，目标排在其后时页面只会停在
    /// 首页（用户以为「查看照片」没生效），要靠自己滚到目标附近才触发分页。
    /// 这里主动向后取页直到找到目标；仍找不到返回 false，由调用方给出明确反馈。
    ///
    /// 定位结果（审计 2 P2-4）：把「找不到」「超出扫描范围」「取页失败」分开。
    /// 旧实现只返回 Bool，三种情况都报「可能已被移除」——取页瞬时失败会让用户
    /// 以为照片没了，目标在上万张之后也被说成已删除。
    public enum PhotoLocateOutcome: Equatable, Sendable {
        case found
        case notFound
        case outOfRange
        case failed
    }

    public func locatePendingPhoto(photoId: String?, photoPath: String?) async -> PhotoLocateOutcome {
        guard photoId != nil || photoPath != nil else { return .notFound }
        func isFound() -> Bool {
            loadedPhotos.contains { row in
                if let photoId, row.id == photoId { return true }
                if let photoPath, row.filepath == photoPath { return true }
                return false
            }
        }
        /// 目标可能是被折叠的兄弟变体（RAW/JPEG 对里非首选那张）：这时它在
        /// loadedPhotos 里根本不存在（list_page 默认每资产只回首选行），
        /// 旧实现会扫完上限后误报「已被移除」（审计 2 P2-3）。
        func isFoldedVariant() -> Bool {
            loadedPhotos.contains { row in
                row.variants.contains { variant in
                    if let photoId, variant.photoId == photoId { return true }
                    if let photoPath, variant.filepath == photoPath { return true }
                    return false
                }
            }
        }
        if isFound() { return .found }
        if isFoldedVariant(), !expandVariants {
            // 展开变体后目标会作为独立行出现；只展开一次（expandVariants 已置位）。
            expandVariants = true
            await reload()
            return await locatePendingPhoto(photoId: photoId, photoPath: photoPath)
        }
        var pagesFetched = 0
        while hasNextPage, pagesFetched < Self.locatePageLimit {
            // P2-5：离开页面（.task 取消）后不再继续扫。
            if Task.isCancelled { return .failed }
            pagesFetched += 1
            let before = loadedPhotos.count
            let hadMore = await fetchNextPage()
            if isFound() { return .found }
            if isFoldedVariant(), !expandVariants {
                expandVariants = true
                await reload()
                return await locatePendingPhoto(photoId: photoId, photoPath: photoPath)
            }
            guard hadMore, loadedPhotos.count > before else {
                // 无进展：区分「取页失败」（有错误）与「真的没有了」。
                return actionError == nil ? .notFound : .failed
            }
        }
        if isFound() { return .found }
        return hasNextPage ? .outOfRange : (actionError == nil ? .notFound : .failed)
    }

    /// 目标在扫描上限之外（审计 2 P2-4）：不是「不存在」，要给出可执行的建议。
    public func reportPhotoTargetOutOfRange() {
        actionError = GatherLocalization.l("目标照片在已加载范围之外，请用搜索缩小范围后再试。")
    }

    /// 定位被中断（取页失败/页面离开）（审计 2 P2-4）：保留原始错误，不谎称「已被移除」。
    public func reportPhotoLocateFailed() {
        if actionError == nil {
            actionError = GatherLocalization.l("定位照片时中断，请重试。")
        }
    }

    /// 定位失败的明确反馈（D08）：目标被删除/不属于本工作区时不静默等待。
    public func reportPhotoTargetMissing() {
        actionError = GatherLocalization.l("未在当前工作区找到这张照片（可能已被移除或不在本工作区）。")
    }

    /// 目标定位的最大取页数（每页 200 张 → 上限 10000 张）。更靠后时不继续扫，
    /// 避免为一次跳转把整个大图库全部拉进内存。
    private static let locatePageLimit = 50

    /// 取下一页（键集游标）；返回是否还有更多页。
    ///
    /// 审计 2 P2-10：原 isFirst 参数在函数体内从未使用（首页/续页同一条键集语义），
    /// 已删除——死参数会让调用方误以为两条路径有区别。
    @discardableResult
    private func fetchNextPage() async -> Bool {
        // D04/D06：请求绑定数据代数。await 之后若代数已变（切变体/换筛选/事件重载），
        // 这份响应属于上一个数据集，必须整份丢弃——不 append 行、不改 phase。
        let generation = fetchGeneration
        // 同一代数内只允许一个在途取页；跨代数不阻塞（新首页必须能立刻取）。
        guard fetchingGeneration != generation else { return hasNextPage }
        fetchingGeneration = generation
        defer {
            // 只清自己的标记：旧代数的请求返回时不能误清新代数的在途状态。
            if fetchingGeneration == generation { fetchingGeneration = nil }
        }
        do {
            let cursor = pageCursors.last ?? nil
            // TS Gallery.tsx:69-71 —— limit 由 searchActive 决定（搜索态 1000
            // 减短链式拉取的往返次数，非搜索态 200）。
            let limit = searchActive ? Self.chainFetchLimit : Self.pageSize
                let result = try await provider.photoPage(
                sessionId: sessionId,
                afterFirstRowid: cursor,
                limit: limit,
                expandVariants: committedExpandVariants
            )
            guard generation == fetchGeneration else { return false }
            pages.append(result.rows)
            pagesGeneration += 1
            pageCursors.append(result.cursor)
            if phase == .loading { phase = .loaded }
            // P2-2（审计 2）：成功取页清掉上一次的瞬时错误。旧实现只有写没有清：
            // 一次分页失败的红条会永久挂在页顶（VM 按 session 缓存，离开再回来还在）。
            actionError = nil
            return result.cursor != nil
        } catch {
            guard generation == fetchGeneration else { return false }
            if pages.isEmpty && phase == .loading {
                phase = .failed(Self.message(for: error))
            } else {
                actionError = Self.message(for: error)
            }
            return false
        }
    }

    // MARK: 选择（TS toggleSelect / clearSelection）

    /// D07：查询条件（搜索/筛选/变体）变化时清空选择集。
    ///
    /// 清空的语义是「筛选条件下的旧选择没有稳定含义」——否则选择栏会显示屏幕上
    /// 不存在的照片数量，「全选/取消全选当前结果」也无法取消这些隐藏项。
    private func clearSelectionForNewQuery() {
        guard !selectedIds.isEmpty else { return }
        selectedIds = []
    }

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

    /// 与 Dashboard/Similarity 同一漏斗：码 → 本地化文案，未知回退通用文案。
    /// 旧实现走 NSError.localizedDescription，会丢 NativeCommandError/BridgeError
    /// 的码值（非 LocalizedError 枚举桥接后退化成 "The operation couldn't be
    /// completed…"），已知码也被显示成通用文案。
    static func message(for error: Error) -> String {
        NativeCommandClient.userFacingMessage(for: error)
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
        // 审计 2 P1-2：事件刷新此前完全在代数协议之外——它整份替换 pages/pageCursors，
        // 与 reload / 切变体 / 在途取页并发时互相覆盖（旧快照覆盖新数据集、游标链跳跃），
        // 也让 locatePendingPhoto 的「行数增长」判据失效 → 误报「未找到」。
        // 现在绑定代数并在写入前校验；循环内改用可取消的让出，使旧刷新真的能被打断。
        let generation = fetchGeneration
        fetchTask?.cancel()
        var nextPages: [[GalleryPhotoData]] = []
        var nextCursors: [Int64?] = []
        do {
            var cursor: Int64?
            repeat {
                let result = try await provider.photoPage(
                    sessionId: sessionId,
                    afterFirstRowid: cursor,
                    limit: searchActive ? Self.chainFetchLimit : Self.pageSize,
                    expandVariants: committedExpandVariants
                )
                guard generation == fetchGeneration else {
                    actionError = nil
                    return
                }
                nextPages.append(result.rows)
                nextCursors.append(result.cursor)
                cursor = result.cursor
                // 逐页让出主线程（可取消），避免大深度重取一帧卡死。
                try Task.checkCancellation()
            } while cursor != nil && nextPages.reduce(0, { $0 + $1.count }) < targetCount
            guard generation == fetchGeneration else {
                actionError = nil
                return
            }
            pages = nextPages
            pagesGeneration += 1
            flatCache = nil
            filteredCache = nil
            pageCursors = nextCursors
            // P2-1（审计 2）：事件刷新会丢弃已删除行，选择集必须随之收敛，
            // 否则选择栏会显示屏幕上不存在的照片数量（全选也清不掉这些隐藏 id）。
            selectedIds.formIntersection(loadedPhotos.map(\.id))
            actionError = nil
        } catch is CancellationError {
            // 被新一轮刷新/导航取代：旧快照整份丢弃，不动任何状态。
            return
        } catch {
            // 重取失败：保留旧网格（就地语义），仅提示错误。
            guard generation == fetchGeneration else { return }
            actionError = Self.message(for: error)
        }
        // 搜索/筛选态链式拉满保证过滤结果的全局完整性（对齐 commitSearch）。
        if searchActive {
            await chainFetchIfActive()
        }
        if phase == .loading { phase = .loaded }
    }
}
