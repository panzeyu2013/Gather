// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel.swift
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
import GatherProtocol

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
/// GatherHost 的 async 数据适配器（临时 SQLite + typed API）。
/// Swift 6 迁移：协议继承 Sendable（Live 实现只持有不可变的各域 API），使
/// @MainActor ViewModel 可在 async 调用中安全地把 provider existential 送出。
public protocol GalleryDataProvider: Sendable {
    /// Cut 1 / B8.2a：会话读取改 async（SessionAPI.get；缺失会话返回 nil，与旧
    /// sessionService.getSession 语义一致）。
    func getSession(_ sessionId: String) async throws -> SessionData?
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
    /// 网格缩略图目标解码尺寸（settings thumbnail_size 分桶）。**必须作为 requirement
    /// 声明**：ViewModel 持有 existential，只在 extension 给默认实现会让 Live 实现
    /// 永远不被调用（用户设置失效）。
    /// B8.2a：SettingsAPI.get 只有 async 形态，故 requirement 也是 async。
    func thumbnailSize() async -> Int
}

public extension GalleryDataProvider {
    /// 网格缩略图目标解码尺寸（TS Gallery.tsx:50-55：settings thumbnail_size
    /// 分桶 → ≤320→256、≤1280→1024、>1280→2048）。测试 stub 未实现时取默认。
    func thumbnailSize() async -> Int { 1024 }

    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? { nil }
}

/// 真实实现已移到 GatherHost：UI 只保留 async 数据端口。
///
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
public final class GalleryViewModel: PageVisibility {
    /// TS: PAGE_SIZE = 200（非搜索态）；搜索/筛选态链式拉满用 1000。
    public static let pageSize = 200
    public static let chainFetchLimit = 1_000

    /// 索引状态轮询间隔：扫描活跃 3s（进度跟手），空闲 15s 兜底
    /// （对齐 SessionControlView.pollInterval 模式）。
    /// 默认值可经 init 注入（生命周期单测用 10ms，生产保持默认）。
    static let defaultActiveStatusPollInterval: Duration = .seconds(3)
    static let defaultIdleStatusPollInterval: Duration = .seconds(15)
    let activeStatusPollInterval: Duration
    let idleStatusPollInterval: Duration
    /// jobs:progress 帧去抖窗口（事件风暴只刷新一次状态）。
    static let progressFrameDebounceSeconds: TimeInterval = 1

    public let sessionId: String
    let provider: GalleryDataProvider
    /// B8.2b：索引重试的建任务通道（JobAPI.start；不再经 provider/字符串命令）。
    let jobAPI: any JobAPI
    let debounceDelay: Duration
    var debounceTask: Task<Void, Never>?
    var fetchTask: Task<Void, Never>?
    /// 数据代数（D04/D06）：任何改变数据集的操作（reload / 变体提交 / 搜索筛选提交 /
    /// 事件重载）都递增。在途请求返回后代数不符即整份作废。
    ///
    /// 旧实现只 `fetchTask?.cancel()`：取消的是链式循环 Task，而旧字符串命令
    /// 的 continuation 请求不会被真正取消，响应回来后仍无条件 append/覆盖，
    /// 于是「切变体后旧页从 p200 开始」「旧筛选计数覆盖新筛选」都能发生。
    var fetchGeneration = 0
    /// 索引头请求序号（P2-9）：只接受最新一次 workspace.status 的结果。
    var statusRequestID = 0
    /// 显式 load 的串行化任务（见 load()）。
    var loadTask: Task<Void, Never>?
    var eventRefreshTask: Task<Void, Never>?
    /// 索引状态轮询任务（可见性由 setVisible 统一启停，Cut 4 / 4a-2b）。
    var statusPollTask: Task<Void, Never>?
    /// 首载激活任务（R4 P1-4）：构造时不再起 Task；只由首次页面激活
    /// （setVisible(true)，经 GatherSessionPage.onAppear → setPageVisible 路由）启动，
    /// shutdown 时一并取消，避免关闭后继续取页。
    var activateTask: Task<Void, Never>?
    /// 首载是否已激活（只发生一次：再次 onAppear / 隐藏再显示都不重复取页）。
    var hasActivated = false
    /// 可见性真相（WP4d：默认不可见；首次 onAppear 经 setPageVisible 置 true，
    /// 避免构造后未挂载页就在后台轮询。不再兼容旧"默认可见"路径）。
    /// 跨文件 extension（+Core/+Load/+Index）读写，故保持 internal var。
    var isVisible = false
    /// 隐藏期间错过的事件刷新：setVisible(true) 时补一次（隐藏页不发命令）。
    var deferredRefreshWhileHidden = false
    /// 关闭终态：shutdown() 之后 setVisible(true) 明确 no-op。
    /// 4a-2c：对外只读，供 SessionWorkspace.close 的扇出测试断言。
    public internal(set) var isShutdown = false
    /// 距上次 workspace.status 刷新时刻（progress 帧去抖）。
    var lastStatusRefreshAt = Date.distantPast
    var pages: [[GalleryPhotoData]] = []
    var pageCursors: [Int64?] = []
    /// 提交后的搜索词（TS useDeferredValue 语义）。
    var committedSearch = ""
    var committedFilter: GalleryFilter = .all
    var committedExpandVariants = false
    var searchActiveWas = false

    public internal(set) var phase: LoadPhase = .loading
    public internal(set) var session: SessionData?
    /// 在途取页所属的数据代数（D04）；nil = 空闲。
    ///
    /// 旧实现是一个全局 Bool：reload（切变体/换筛选）时旧请求仍在途，新首页请求
    /// 被这个 Bool 直接拒绝 → 清空后的首页永远补不回来（实测数组从 p200 开始）。
    /// 改为按代数记账：同一代数内仍只允许一个在途请求，跨代数不互相阻塞，
    /// 旧请求返回时也不会误清新代数的在途标记。
    var fetchingGeneration: Int?

    public var isFetchingNextPage: Bool { fetchingGeneration != nil }
    public internal(set) var actionError: CommandError?
    public internal(set) var selectedIds: Set<String> = []
    /// 网格缩略图解码尺寸（load() 时经 provider 读取 settings thumbnail_size 分桶）。
    public internal(set) var thumbnailSize = 1024
    /// 工作区索引状态（workspace.status；索引头数据源，轮询 + 事件驱动）。
    public internal(set) var workspaceStatus: WorkspaceStatus?
    /// 搜索输入框实时值（视图绑定；经 searchChanged 提交）。
    public var search = ""
    /// 客户端过滤（对齐 TS FILTER_OPTIONS）。
    public var filter: GalleryFilter = .all
    /// RAW/JPEG 变体展开（对齐 TS expandVariants toggle）。
    public var expandVariants = false
    /// pages 变更代数（D-3 性能审计：派生数组记忆化的失效依据）。
    ///
    /// 旧实现 loadedPhotos/filteredPhotos 是纯计算属性：GalleryView 有 9 处读取，
    /// 其中 2 处在 body 求值路径、1 处在 .onChange(of:) 的深比较里 ⇒ 每次 body
    /// 要 flatMap+filter 各若干遍（1 万行含 lowercased 实测 3.6-3.9ms/遍）。
    /// 现在按代数 + 过滤参数缓存，只在真的变化时重算（派生计算在 +Derived）。
    var pagesGeneration = 0
    var flatCache: (generation: Int, photos: [GalleryPhotoData])?
    var filteredCache: (key: String, photos: [GalleryPhotoData])?

    public init(
        sessionId: String,
        provider: GalleryDataProvider,
        job: any JobAPI,
        debounceDelay: Duration = .milliseconds(300),
        // 默认值与 defaultActive/IdleStatusPollInterval 一致；public init 的默认
        // 参数不能引用 internal static，故此处写字面量（常量仅供测试引用）。
        activeStatusPollInterval: Duration = .seconds(3),
        idleStatusPollInterval: Duration = .seconds(15)
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.jobAPI = job
        self.debounceDelay = debounceDelay
        self.activeStatusPollInterval = activeStatusPollInterval
        self.idleStatusPollInterval = idleStatusPollInterval
        // R4 P1-4：构造只做对象图装配，不查库、不取页。
        // 旧实现在 init 里起 initTask → loadIfNeeded()，于是只要 workspace 被构造
        // （进入 control/face/export，甚至仅 enqueue 意图）就会打一次
        // photo.list_page，与"打开哪一页"无关；LRU 重建还会再来一次。
        // 首载改为显式激活：GatherSessionPage.onAppear → workspace.setPageVisible(.gallery)
        // → setVisible(true) → activateIfNeeded()（见 +Load/+Core）。
    }
}
