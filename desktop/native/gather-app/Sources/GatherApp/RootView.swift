// Gather 原生导航壳。
//
// 原生化要点（取代旧版自绘外壳）：
// - 侧栏改用 NavigationSplitView + List(selection:).listStyle(.sidebar)，
//   由系统负责玻璃材质、选中高亮、⌘⌥S 显隐与列宽拖拽；
// - 删除手搓的侧栏、6pt 拖拽手柄、NSCursor.push/pop 与不透明色块背景；
// - 页面改为**按目的地条件构建**（不再用 .opacity(0) 常驻），
//   消除隐藏页的状态泄漏与跨页快捷键污染；
// - 窗口标题 / 副标题交给 .navigationTitle / .navigationSubtitle。
import SwiftUI
import AppKit
import GatherCore

@MainActor
@Observable
final class RootNavigation {
    enum WebPage: String, CaseIterable, Identifiable {
        case persons
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .persons: return GatherLocalization.l("人脸库")
            case .settings: return GatherLocalization.l("设置")
            }
        }

        var systemImage: String {
            switch self {
            case .persons: return "person.2"
            case .settings: return "gearshape"
            }
        }
    }

    /// 单一表示：WebPage 即页面身份，网页类页面统一走 .page(WebPage)。
    /// （旧实现同时存在 .persons 与 .page(.persons) 两套表示，令 .page(.persons)
    /// 永远构造不出来——已收敛，人脸库经侧栏 selectWeb(.persons) 真实可达。）
    enum Destination: Equatable {
        case dashboard
        case page(WebPage)
        case library
        case gallery(String)
        case similarity(String)
        case sessionTab(String, SessionTab)
    }

    private(set) var destination: Destination = .dashboard

    var selectedWebPage: WebPage? {
        if case .page(let page) = destination { return page }
        return nil
    }

    var isDashboard: Bool { if case .dashboard = destination { return true }; return false }
    var isLibrary: Bool { if case .library = destination { return true }; return false }
    var isPersons: Bool { if case .page(.persons) = destination { return true }; return false }
    var isSettings: Bool { if case .page(.settings) = destination { return true }; return false }

    /// 测试用判定（B1 返回语义）。
    func isGallery(sessionId: String) -> Bool {
        if case .gallery(let id) = destination { return id == sessionId }
        return false
    }

    func isSessionTab(sessionId: String, tab: SessionTab) -> Bool {
        if case .sessionTab(let id, let current) = destination { return id == sessionId && current == tab }
        return false
    }

    var gallerySessionId: String? {
        if case .gallery(let id) = destination { return id }
        return nil
    }

    var similaritySessionId: String? {
        if case .similarity(let id) = destination { return id }
        return nil
    }

    var sessionTabDestination: (sessionId: String, tab: SessionTab)? {
        if case .sessionTab(let id, let tab) = destination { return (id, tab) }
        return nil
    }

    /// 当前打开的会话 id（对齐旧版 sessionStore.currentSessionId 驱动的
    /// 侧栏"当前会话"项）：gallery / similarity / 任一工作区页签均算。
    var currentSessionId: String? {
        if let id = gallerySessionId { return id }
        if let id = similaritySessionId { return id }
        if let tab = sessionTabDestination { return tab.sessionId }
        return nil
    }

    func selectDashboard() { destination = .dashboard }
    func selectLibrary() { destination = .library }

    func selectWeb(_ page: WebPage) {
        destination = .page(page)
    }

    /// 最近一次打开的工作区（N07）：离开工作区页面后侧栏仍保留「当前会话」入口，
    /// 用户不必回到工作台再找一遍。与 currentSessionId 的区别：后者是「当前目的地
    /// 属于哪个工作区」，前者是「最近用过哪个工作区」。
    private(set) var lastSessionId: String?

    /// 从全局图库点开的具体照片（N07）：进入图库页后一次性打开查看器。
    /// 旧实现只把点击当成「打开该工作区」，用户跨工作区找到的那张照片被丢掉。
    ///
    /// 第三轮审计 E：重复检测 / 相似度 / 人物库的成员行也要能直达照片，而
    /// SimilarityImage 只有 filepath、没有 photoId，因此这里同时支持路径匹配。
    private(set) var pendingGalleryPhotoId: String?
    private(set) var pendingGalleryPhotoPath: String?

    /// 侧栏「当前会话」条目使用的工作区 id（当前优先，其次最近一次）。
    var sidebarSessionId: String? { currentSessionId ?? lastSessionId }

    /// 进入工作区之前的来源页（第三轮审计 E-P0）。
    ///
    /// 会话页的返回按钮原先**写死**去图库：从工作台点「进入」、从人脸库深链、
    /// 或从全局图库点照片进来，返回都落图库，用户被丢到没去过的页面。
    /// 这里记录真实的来源，返回时回到那里。
    enum SessionOrigin: Equatable {
        case dashboard
        case library
        case persons
        case gallery
        case similarity
    }

    private(set) var sessionOrigin: SessionOrigin = .gallery

    /// 上一个真实页面（含工作区 id 与页签）。B1（9-30 审查）：粗粒度的
    /// SessionOrigin 只能表达「哪一类页面」，无法表达「控制中心 / 浏览 / 相似度」
    /// 这类同层页签切换——「工作台 → 控制中心 → 浏览 → 相似度 → 返回」于是回到
    /// 工作台而不是浏览页。返回语义改用完整目的地。
    private(set) var previousDestination: Destination?

    /// 记录来源（仅在进入会话/图库/相似度时调用）。
    private func recordOrigin() {
        previousDestination = destination
        switch destination {
        case .dashboard: sessionOrigin = .dashboard
        case .library: sessionOrigin = .library
        case .page(.persons): sessionOrigin = .persons
        // A6（审计 4）：.gallery 与 .similarity 以前落 default 被吞掉 →
        // 「工作台 → 会话 → 图库页签 → 返回」会回到工作台（更早的页面），
        // 而不是用户实际所在的图库。
        case .gallery: sessionOrigin = .gallery
        case .similarity: sessionOrigin = .similarity
        default: break
        }
    }

    /// 通用返回（B1 9-30 审查）：优先回到**上一个真实页面**（可精确到
    /// 工作区 + 页签 / 图库 / 相似度 / 页面型目的地）；没有记录时退回粗粒度来源。
    ///
    /// 返回后清空 previousDestination（单步返回，不做前进栈），避免来回弹跳。
    @discardableResult
    func goBack(sessionId: String) -> Bool {
        if let previous = previousDestination, previous != destination {
            previousDestination = nil
            clearPendingGalleryPhoto()
            destination = previous
            if case .sessionTab(let id, _) = previous { lastSessionId = id }
            return true
        }
        // 兜底：按粗粒度来源回到对应页面（含图库——B1 的复现路径）。
        switch sessionOrigin {
        case .dashboard: selectDashboard()
        case .library: selectLibrary()
        case .persons: selectWeb(.persons)
        case .gallery: openGallery(sessionId, photoId: nil)
        case .similarity: openSimilarity(sessionId)
        }
        return false
    }

    /// 从工作区页面返回：回到真实来源页。
    func backFromSession(sessionId: String) {
        goBack(sessionId: sessionId)
    }

    /// 相似度页返回：回到进入相似度之前的页面（A6/G-3 审计 4/5 + B1）。
    func backFromSimilarity(sessionId: String) {
        goBack(sessionId: sessionId)
    }

    /// 工作区入口与 TS /sessions/:id 一致：先进入控制中心。
    func openSession(_ sessionId: String) {
        recordOrigin()
        lastSessionId = sessionId
        // G-2（审计 5）：照片待定必须**成对**清理——旧实现只清 id，相似度成员行
        // 留下的 path 会跨导航存活，下次进图库又自动弹出旧照片。
        clearPendingGalleryPhoto()
        destination = .sessionTab(sessionId, .control)
    }

    func openGallery(_ sessionId: String) { openGallery(sessionId, photoId: nil, photoPath: nil) }

    /// 打开图库并可指定要打开的照片（全局图库卡片 → 直接看那张照片）。
    /// photoPath 供只有路径的调用方（相似度成员行）使用；与 photoId 二选一。
    func openGallery(_ sessionId: String, photoId: String?, photoPath: String? = nil) {
        // 记录来源：图库的返回按钮也要回到真实的来源页（工作台 / 全局图库 / 人脸库）。
        if case .gallery = destination {} else { recordOrigin() }
        lastSessionId = sessionId
        pendingGalleryPhotoId = photoId
        pendingGalleryPhotoPath = photoPath
        destination = .gallery(sessionId)
    }

    func openSimilarity(_ sessionId: String) {
        // G-3（审计 5）：相似度页的返回也要回到真实来源（此前写死去图库）。
        recordOrigin()
        lastSessionId = sessionId
        clearPendingGalleryPhoto()
        destination = .similarity(sessionId)
    }

    func openSessionTab(_ sessionId: String, _ tab: SessionTab) {
        // 会话**内部**的页签切换不改变来源（否则来回切页签会把来源覆盖掉），
        // 但**会话之间**的跳转必须记录来源（A6：图库 → 会话页签的返回落点）。
        if case .sessionTab(let current, _) = destination, current == sessionId {} else { recordOrigin() }
        lastSessionId = sessionId
        clearPendingGalleryPhoto()
        destination = .sessionTab(sessionId, tab)
    }

    /// 图库页返回：回到进入图库之前的页面（默认工作台）。
    func backFromGallery() {
        // 问题 8（第三轮审查）：旧实现把 gallery/similarity/dashboard 合并成
        // 「回工作台」，而新的 previousDestination/goBack 只被会话与相似度入口使用
        // ⇒「工作台 → 控制中心 → 图库 → 返回」落到工作台而不是控制中心。
        // 图库同样走统一返回（精确恢复到上一个完整页面）。
        let sessionId = gallerySessionId ?? lastSessionId ?? ""
        goBack(sessionId: sessionId)
    }

    /// A9（审计 4）：未消费的入口意图必须**离开即失效**。
    ///
    /// 旧实现只在页面 .task 里消费，用户没等页面渲染就切走时意图会残留：下次以
    /// 普通路径进同一页时旧意图静默生效一次（导出页表现为范围自己变成保留片）。
    /// 意图只有在其目标页上才有意义，因此目的地一离开就整批清掉。
    fileprivate func pruneIntents(for destination: Destination, draftCache: SessionDraftCache) {
        switch destination {
        case .gallery: break
        default:
            clearPendingGalleryPhoto()
            draftCache.pendingGalleryFilter.removeAll()
        }
        if case .sessionTab(_, .culling) = destination {} else {
            draftCache.pendingCullingConflicts.removeAll()
        }
        if case .sessionTab(_, .faceKw) = destination {} else {
            draftCache.pendingFaceAnalyze.removeAll()
        }
        if case .sessionTab(_, .export) = destination {} else {
            draftCache.pendingExportIntent.removeAll()
        }
    }

    /// 离开图库页时清掉待打开照片，避免下次进入图库又自动弹出同一张（N07）。
    func clearPendingGalleryPhoto() {
        pendingGalleryPhotoId = nil
        pendingGalleryPhotoPath = nil
    }
}

// MARK: - 侧栏条目

private enum SidebarItem: Hashable {
    case dashboard
    case currentSession(String)
    case library
    case web(RootNavigation.WebPage)
}

/// 会话级草稿缓存（N04 / N05）。
///
/// 为什么需要它：工作区页面是按目的地条件构建的，切换页签会销毁页面（连同页面
/// 里的 @State 视图模型）。导出目录/格式/命名、人脸页的步骤与选中簇都属于
/// 「用户已经投入过输入」的状态，必须按工作区缓存下来。
///
/// 用普通引用类型而不是 @State 字典：在 body 求值期间写入缓存不应触发 SwiftUI
/// 的更新循环（缓存不是渲染输入）；被缓存的 VM 自身是 @Observable，
/// 页面内部的绑定照常刷新。
private final class SessionDraftCache {
    /// 最近使用的工作区顺序（C-2 审计 5）：草稿缓存是普通类，旧实现只增不减，
    /// 每个工作区留 4 个 VM（挑片/重复/导出/人脸，内含 Task 与轮询字段）。
    /// 这里按 LRU 保留最近 maxSessions 个工作区，超出的整批淘汰。
    private var recentSessionIds: [String] = []
    /// 正在浏览的工作区（B7）：淘汰时永远跳过它，避免刚用过的草稿被清掉。
    var activeSessionId: String?
    /// 上限 8 个工作区（每区最多 4 个 VM）。
    private static let maxSessions = 8

    func noteAccess(_ sessionId: String) {
        recentSessionIds.removeAll { $0 == sessionId }
        recentSessionIds.append(sessionId)
        guard recentSessionIds.count > Self.maxSessions else { return }
        // 淘汰最久未访问的那个，但永远不淘汰正在浏览的工作区（B7）。
        let victimIndex = recentSessionIds.firstIndex { $0 != activeSessionId } ?? 0
        let evicted = recentSessionIds.remove(at: victimIndex)
        evict(evicted)
    }

    /// 淘汰某工作区的全部草稿（离开很久的工作区不需要再占内存）。
    private func evict(_ sessionId: String) {
        exportViewModels[sessionId] = nil
        faceViewModels[sessionId] = nil
        cullingViewModels[sessionId] = nil
        duplicatesViewModels[sessionId] = nil
        pendingExportIntent[sessionId] = nil
        pendingGalleryFilter[sessionId] = nil
        pendingCullingConflicts.remove(sessionId)
        pendingFaceAnalyze.remove(sessionId)
    }

    var exportViewModels: [String: ExportViewModel] = [:]
    var faceViewModels: [String: FaceKeywordingViewModel] = [:]
    /// 第三轮审计 D-P0：挑片与重复页的 VM 同样要跨页签保留——
    /// 挑片：范围 / 筛选 / 当前照片 / 多选 / 逐字段裁决草稿；
    /// 重复：扫描结果 / 阈值 / 分组展开 / 分页。
    var cullingViewModels: [String: CullingViewModel] = [:]
    var duplicatesViewModels: [String: DuplicatesViewModel] = [:]
    /// 待消费的导出入口意图（控制中心「去导出」= 挑片成果）。
    var pendingExportIntent: [String: ExportRangeIntent] = [:]
    /// 待消费的挑片入口意图（D10：控制中心「逐条裁决」→ 筛选收敛到 XMP 冲突）。
    var pendingCullingConflicts: Set<String> = []
    /// 待消费的图库筛选意图（D10：控制中心「N 张照片离线 → 查看」）。
    var pendingGalleryFilter: [String: GalleryFilter] = [:]
    /// 待消费的人脸页分析意图（D10：控制中心「分析已过期 → 重新分析」）。
    var pendingFaceAnalyze: Set<String> = []
}

// MARK: - 外壳

/// 主窗口外壳的尺寸约束（D-2 审计 5）：内容区可用最小宽度 = 窗口最小宽度 − 侧栏最小宽度。
/// 布局预算测试此前把 680 写死在测试里，两处常量漂移时测试不会失败——改由这里单点定义。
enum RootShellMetrics {
    static let windowMinWidth: CGFloat = 860
    static let sidebarMinWidth: CGFloat = 180
    /// 内容区（会话页 + 页签行）必须放得下的最小宽度。
    static var contentMinWidthBudget: CGFloat { windowMinWidth - sidebarMinWidth }
}

struct RootView: View {
    let router: SessionCommandRouter
    let provider: DashboardDataProvider
    let libraryProvider: LibraryDataProvider
    let galleryProvider: GalleryDataProvider
    let similarityProvider: SimilarityDataProvider
    let personsProvider: PersonsDataProvider?

    @State private var navigation: RootNavigation
    @State private var viewModel: DashboardViewModel
    @State private var libraryViewModel: LibraryViewModel
    @State private var galleryViewModel: GalleryViewModel?
    @State private var similarityViewModel: SimilarityViewModel?
    @State private var personsViewModel: PersonsViewModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 人脸审核深链的角色预筛选（Persons 详情「复核人脸」注入；切换目的地后清空）。
    @State private var faceKwInitialRole: String?
    /// 界面语言版本号：languageChanged 通知递增，驱动外壳层双语文案重渲染。
    @State private var languageVersion = 0
    /// 窗口标题：有会话时取会话名，否则保持「Gather」。
    @State private var windowTitle = "Gather"
    /// 工作台新建/导入请求（非空 = 工作台应立即打开新建表单）。
    /// 由外壳暂存而不是 DashboardView 自己订阅通知：条件构建下页面的 @State
    /// 随目的地切换销毁，跨页触发的请求必须由外壳代收（F02 / ⌘N 竞态）。
    @State private var newWorkspaceRequest: NewWorkspaceRequest?
    /// 会话级草稿缓存（N04 / N05）：导出配置与人脸页进度跨页签保留。
    @State private var draftCache = SessionDraftCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 打开原生设置窗口（macOS 14+ 的公开 API；`showSettingsWindow:` 是
    /// SwiftUI 私有 selector，不在 AppKit SDK 里，不能依赖）。
    @Environment(\.openSettings) private var openSettings

    @MainActor
    init(
        router: SessionCommandRouter,
        provider: DashboardDataProvider,
        libraryProvider: LibraryDataProvider,
        galleryProvider: GalleryDataProvider,
        similarityProvider: SimilarityDataProvider,
        navigation: RootNavigation? = nil,
        personsProvider: PersonsDataProvider? = nil
    ) {
        self.router = router
        self.provider = provider
        self.libraryProvider = libraryProvider
        self.galleryProvider = galleryProvider
        self.similarityProvider = similarityProvider
        self.personsProvider = personsProvider
        let navigation = navigation ?? RootNavigation()
        _navigation = State(initialValue: navigation)
        _viewModel = State(initialValue: DashboardViewModel(provider: provider))
        _libraryViewModel = State(initialValue: LibraryViewModel(provider: libraryProvider))
        if case .gallery(let id) = navigation.destination {
            _galleryViewModel = State(initialValue: GalleryViewModel(sessionId: id, provider: galleryProvider))
        }
        if case .similarity(let id) = navigation.destination {
            _similarityViewModel = State(initialValue: SimilarityViewModel(
                sessionId: id,
                provider: similarityProvider,
                captureOne: CaptureOneBridge(router: router)
            ))
        }
        if let personsProvider {
            _personsViewModel = State(initialValue: PersonsViewModel(provider: personsProvider))
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: RootShellMetrics.sidebarMinWidth, ideal: 200, max: 300)
        } detail: {
            detail
                // 语言切换只重建外壳层文案；页面子树由各自目的地驱动。
                .id(languageVersion)
                // 窗口标题：会话页（控制中心/人脸/重复/挑片/导出）用会话名，
                // 页面型目的地（工作台/图库/人脸库/设置）由页面自己的
                // navigationTitle 覆盖（内层优先）。
                .navigationTitle(windowTitle)
        }
        .frame(minWidth: RootShellMetrics.windowMinWidth, minHeight: 560)
        .tint(GatherTheme.accent)
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.languageChanged)) { notification in
            if let language = notification.object as? String {
                GatherLocalization.setAppLanguage(language)
            }
            languageVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuToggleSidebar)) { _ in
            // 交给系统：⌘⌥S 语义由 NavigationSplitView 的列可见性承载。
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuNewWorkspace)) { _ in
            // ⌘N：请求先落到外壳再切工作台。DashboardView 是按目的地条件构建的，
            // 页面不在场时把通知直接投递给它必然丢失（与 F02 同类竞态）。
            navigation.selectDashboard()
            newWorkspaceRequest = NewWorkspaceRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuImportFolder)) { notification in
            navigation.selectDashboard()
            guard let directory = notification.object as? URL else {
                // 兼容旧语义（object: nil = 用户要导入但尚未选目录）：
                // 退回统一入口打开目录选择器，绝不静默无响应。
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
                return
            }
            newWorkspaceRequest = NewWorkspaceRequest(folderPath: directory.path)
        }
        // ⌘, 与各页面的「打开设置」入口统一打开原生设置窗口。
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuOpenSettings)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.importCompleted)) { notification in
            guard let userInfo = notification.userInfo,
                  let sessionId = userInfo[GatherAppImportUserInfoKey.sessionId] as? String,
                  !sessionId.isEmpty else { return }
            let failedCount = (userInfo[GatherAppImportUserInfoKey.failedCount] as? Int) ?? 0
            if failedCount > 0 {
                // 对齐旧版 importFailureMessage（session-paths.ts:26-45）：
                // 「N 张照片已导入；来源读取失败：示例文件、… 等 N 个」。
                let addedCount = (userInfo[GatherAppImportUserInfoKey.addedCount] as? Int) ?? 0
                let sourceLabel = (userInfo[GatherAppImportUserInfoKey.sourceLabel] as? String)
                    ?? GatherLocalization.l("文件")
                let examples = (userInfo[GatherAppImportUserInfoKey.examples] as? String) ?? ""
                let remaining = failedCount > 3
                    ? String(format: GatherLocalization.l(" 等 %d 个"), failedCount)
                    : ""
                GatherToastCenter.shared.show(
                    type: .warning,
                    message: String(format: GatherLocalization.l("%lld 张照片已导入；%@读取失败：%@%@"), addedCount, sourceLabel, examples, remaining)
                )
            }
            // 深链/导入完成语义对齐旧版 App.tsx:34-64：落点浏览页（图库）。
            navigation.openGallery(sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.captureOneError)) { notification in
            guard let code = notification.object as? String else { return }
            GatherToastCenter.shared.show(type: .error, message: GatherLocalization.errorText(code))
        }
        .overlay(alignment: .topTrailing) {
            ToastView()
        }
        .onAppear { refreshWindowTitle() }
        .onChange(of: navigation.destination) { previous, destination in
            refreshWindowTitle()
            // A9（审计 4）：未消费的入口意图离开即失效（只有对应目标页才有意义）。
            navigation.pruneIntents(for: destination, draftCache: draftCache)
            // 人脸审核深链角色预筛选为一次性播种：离开人脸页即清空。
            if case .sessionTab(_, .faceKw) = destination {} else {
                faceKwInitialRole = nil
            }
            // N07：离开图库页即清掉「待打开照片」，避免下次进入图库重复弹出。
            if case .gallery = previous, !Self.isGalleryDestination(destination) {
                navigation.clearPendingGalleryPhoto()
            }
            // B2（9-30 审查）：离开图库必须**显式**停轮询。页面是条件构建（销毁），
            // 而 VM 由外壳持有——销毁不会触发 onDisappear 里的 isActive=false 分支，
            // 于是 workspace.status 的 3s/15s 轮询在用户离开后继续跑。
            if case .gallery = previous, !Self.isGalleryDestination(destination) {
                galleryViewModel?.stopIndexStatusPolling()
            }
            // 轮询门控：离开工作台显式停止自动刷新，回到时恢复。
            if case .dashboard = previous {
                viewModel.isVisible = false
                viewModel.stopAutoRefresh()
            }
            if case .similarity = previous {
                similarityViewModel?.stopProgressPolling()
                similarityViewModel?.stopResultPolling()
            }
            if case .dashboard = destination {
                viewModel.isVisible = true
                viewModel.startAutoRefresh()
            }
        }
        // 目的地驱动的视图模型生命周期：条件构建下页面每次进入都重建，
        // 但其 @State 模型由外壳持有，跨导航保留。
        .task(id: navigation.destination) {
            syncViewModels(for: navigation.destination)
        }
    }

    // MARK: - 侧栏（原生）

    private var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            Section {
                Label(GatherLocalization.l("工作台"), systemImage: "house")
                    .tag(SidebarItem.dashboard)
                if let sessionId = navigation.sidebarSessionId {
                    Label(GatherLocalization.l("当前会话"), systemImage: "rectangle.stack")
                        .tag(SidebarItem.currentSession(sessionId))
                }
                Label(GatherLocalization.l("全局图库"), systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarItem.library)
                // F03：人物库是**全局一级目的地**（跨工作区人物管理），
                // 与工作区内的人脸审核对象范围不同，不能互相替代。
                Label(RootNavigation.WebPage.persons.title, systemImage: RootNavigation.WebPage.persons.systemImage)
                    .tag(SidebarItem.web(.persons))
            }
            // 设置不占侧栏条目：macOS 惯例是应用菜单里的「设置…」（⌘,）
            // 打开独立的设置窗口，与 Xcode / Safari / 访达一致。
        }
        .listStyle(.sidebar)
        .navigationTitle("Gather")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // F02：不再直接 post menuImportFolder——该通知的载荷语义是
                    // 「已经选好的目录」，object: nil 会被接收方（要求 URL）静默丢弃，
                    // 表现就是按钮点了没反应。统一走 importFolderRequest：
                    // AppDelegate 打开目录选择器，落点由面板回调决定
                    //（目录里可导入 → 直接建库；没有可导入文件 → menuImportFolder
                    // 带目录 URL 回落到新建表单）。
                    NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
                } label: {
                    Label(GatherLocalization.l("导入文件夹"), systemImage: "square.and.arrow.down")
                }
                .help(GatherLocalization.l("导入文件夹"))
            }
        }
    }

    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { currentSidebarItem },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
                case .dashboard: navigation.selectDashboard()
                case .currentSession(let id): navigation.openSession(id)
                case .library: navigation.selectLibrary()
                case .web(let page): navigation.selectWeb(page)
                }
            }
        )
    }

    private var currentSidebarItem: SidebarItem? {
        switch navigation.destination {
        case .dashboard: return .dashboard
        case .library: return .library
        case .page(let page): return .web(page)
        case .gallery, .similarity:
            // 图库/相似度页在侧栏不单列条目，落回「当前会话」。
            if let id = navigation.currentSessionId { return .currentSession(id) }
            return nil
        case .sessionTab:
            // F09：任一工作区子页（控制中心/人脸/重复/挑片/导出）都必须保持
            // 「当前会话」选中态——否则用户进入子页后侧栏无高亮，失去
            // 「我在哪个工作区」的稳定提示。
            if let id = navigation.currentSessionId { return .currentSession(id) }
            return nil
        }
    }

    // MARK: - 详情区（按目的地条件构建）

    @ViewBuilder
    private var detail: some View {
        switch navigation.destination {
        case .dashboard:
            DashboardView(viewModel: viewModel, newWorkspaceRequest: $newWorkspaceRequest) { sessionId in
                navigation.openSession(sessionId)
            }
        case .library:
            LibraryView(
                viewModel: libraryViewModel,
                isActive: true,
                onOpenSession: { sessionId in navigation.openSession(sessionId) },
                // N07：点击卡片打开那张照片（而不是丢掉目标只打开工作区）。
                onOpenPhoto: { sessionId, photoId in
                    navigation.openGallery(sessionId, photoId: photoId)
                }
            )
        case .page(.persons):
            if let personsViewModel {
                PersonsView(
                    viewModel: personsViewModel,
                    onReview: { sessionId in navigation.openSessionTab(sessionId, .faceKw) },
                    onReviewFaceRole: { role, sessionId in
                        faceKwInitialRole = role
                        navigation.openSessionTab(sessionId, .faceKw)
                    },
                    // E：人物关联照片可直接打开（走到那张照片的查看器）。
                    onOpenPhoto: { sessionId, photoId in
                        navigation.openGallery(sessionId, photoId: photoId)
                    },
                    // D12：复核按钮优先落在当前工作区（人物可能横跨多个工作区）。
                    currentSessionId: navigation.sidebarSessionId,
                    isActive: true
                )
            } else {
                unavailable(GatherLocalization.l("人脸库不可用"))
            }
        case .page(.settings):
            SettingsView(router: router)
        case .gallery(let sessionId):
            if let galleryViewModel, galleryViewModel.sessionId == sessionId {
                GalleryView(
                    viewModel: galleryViewModel,
                    router: router,
                    // N07 / E：从其它页面点进来的照片，加载完成后一次性打开查看器
                    //（id 优先，路径兜底——相似度成员行只有路径）。
                    initialPhotoId: navigation.pendingGalleryPhotoId,
                    initialPhotoPath: navigation.pendingGalleryPhotoPath,
                    // D10：控制中心「N 张照片离线 → 查看」意图（只看离线照片）。
                    filterIntent: draftCache.pendingGalleryFilter[sessionId],
                    onConsumeFilterIntent: {
                        draftCache.pendingGalleryFilter[sessionId] = nil
                    },
                    // 图库返回同样回到真实来源（默认工作台）。
                    onBack: { navigation.backFromGallery() },
                    onOpenSimilarity: { navigation.openSimilarity($0) },
                    onOpenTab: { navigation.openSessionTab($0, $1) },
                    onOpenSettings: { openSettings() },
                    isActive: true
                )
            } else {
                loadingPlaceholder
            }
        case .similarity(let sessionId):
            if let similarityViewModel, similarityViewModel.sessionId == sessionId {
                SimilarityView(
                    viewModel: similarityViewModel,
                    router: router,
                    // G-3（审计 5）：返回真实来源页（此前写死去图库）。
                    onBack: { navigation.backFromSimilarity(sessionId: sessionId) },
                    onOpenGallery: { navigation.openGallery($0) },
                    onOpenTab: { navigation.openSessionTab($0, $1) },
                    onOpenSettings: { openSettings() },
                    // E：成员行「查看照片」→ 该照片的图库查看器（按路径匹配）。
                    onOpenPhoto: { path in
                        navigation.openGallery(sessionId, photoId: nil, photoPath: path)
                    },
                    isActive: true
                )
            } else {
                loadingPlaceholder
            }
        case .sessionTab(let sessionId, let tab):
            sessionTabView(sessionId: sessionId, tab: tab)
                // 会话切换守卫：页面 @State VM 以 init 时的 sessionId 初始化，
                // 直接 control(A)→control(B) 跳转也必须强制重建。
                .id("session-tab-\(sessionId)-\(tab)")
        }
    }

    private static func isGalleryDestination(_ destination: RootNavigation.Destination) -> Bool {
        if case .gallery = destination { return true }
        return false
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ title: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "questionmark.folder",
            description: Text(GatherLocalization.l("请确认应用的数据目录可访问。"))
        )
    }

    /// 取（或建立）某工作区的导出草稿 VM（N04：跨页签保留）。
    private func exportViewModel(for sessionId: String) -> ExportViewModel {
        // B7（9-30 审查）：命中也要记访问，否则「重访已有工作区」不刷新 LRU 顺序，
        // 新建第 9 个工作区时可能淘汰刚用过的草稿。
        if let existing = draftCache.exportViewModels[sessionId] {
            draftCache.noteAccess(sessionId)
            return existing
        }
        let created = ExportViewModel(sessionId: sessionId, router: router)
        draftCache.exportViewModels[sessionId] = created
        draftCache.noteAccess(sessionId)
        return created
    }

    /// 取（或建立）某工作区的人脸页 VM（N04：步骤 / 选中簇 / 编辑中字段不丢）。
    private func faceViewModel(for sessionId: String) -> FaceKeywordingViewModel {
        if let existing = draftCache.faceViewModels[sessionId] {
            draftCache.noteAccess(sessionId)
            return existing
        }
        let created = FaceKeywordingViewModel(
            sessionId: sessionId,
            router: router,
            initialRoleFilter: faceKwInitialRole
        )
        draftCache.faceViewModels[sessionId] = created
        draftCache.noteAccess(sessionId)
        return created
    }

    /// 取（或建立）某工作区的挑片 VM（D-P0：范围/筛选/当前张/裁决草稿跨页签保留）。
    private func cullingViewModel(for sessionId: String) -> CullingViewModel {
        if let existing = draftCache.cullingViewModels[sessionId] {
            draftCache.noteAccess(sessionId)
            return existing
        }
        let created = CullingViewModel(sessionId: sessionId, router: router)
        draftCache.cullingViewModels[sessionId] = created
        draftCache.noteAccess(sessionId)
        return created
    }

    /// 取（或建立）某工作区的重复检测 VM（D-P0：扫描结果/阈值/分页跨页签保留）。
    private func duplicatesViewModel(for sessionId: String) -> DuplicatesViewModel {
        if let existing = draftCache.duplicatesViewModels[sessionId] {
            draftCache.noteAccess(sessionId)
            return existing
        }
        let created = DuplicatesViewModel(sessionId: sessionId, router: router)
        draftCache.duplicatesViewModels[sessionId] = created
        draftCache.noteAccess(sessionId)
        return created
    }

    /// 控制中心「N 张照片离线 → 查看」（D10）：进入图库并只看离线照片。
    private func openGalleryOffline(sessionId: String) {
        draftCache.pendingGalleryFilter[sessionId] = .offline
        navigation.openGallery(sessionId)
    }

    /// 控制中心「分析已过期 → 重新分析」（D10）：进入人脸页并直达分析步骤。
    private func openFaceAnalyze(sessionId: String) {
        draftCache.pendingFaceAnalyze.insert(sessionId)
        navigation.openSessionTab(sessionId, .faceKw)
    }

    /// 控制中心「逐条裁决」（D10）：记录「只看 XMP 冲突」意图后切到挑片页。
    /// 事件语义：页面消费后清空，避免后续普通进入也套用旧意图。
    private func openCullingConflicts(sessionId: String) {
        draftCache.pendingCullingConflicts.insert(sessionId)
        navigation.openSessionTab(sessionId, .culling)
    }

    /// 控制中心「去导出」：记录入口意图（挑片成果 → 默认保留片）后切到导出页（N05）。
    private func openExport(sessionId: String, intent: ExportRangeIntent) {
        draftCache.pendingExportIntent[sessionId] = intent
        navigation.openSessionTab(sessionId, .export)
    }

    /// 导出页消费完入口意图后清空（V2 审计 P1）：意图是「每次入口点击」的事件，
    /// 不是一次性播种。否则用户先经过页签进过导出页之后，「去导出」的意图会被
    /// 静默丢弃；反过来，不消费又会让后续页签进入重复套用旧意图。
    private func consumeExportIntent(sessionId: String) {
        draftCache.pendingExportIntent[sessionId] = nil
    }

    @ViewBuilder
    private func sessionTabView(sessionId: String, tab: SessionTab) -> some View {
        let onOpenSettings = { openSettings() }
        // E-P0：返回真实的来源页（工作台 / 全局图库 / 人脸库 / 图库），
        // 而不是一律回图库。
        let onBack = { navigation.backFromSession(sessionId: sessionId) }
        let onOpenSimilarity: (String) -> Void = { navigation.openSimilarity($0) }
        let onOpenTab: (String, SessionTab) -> Void = { navigation.openSessionTab($0, $1) }
        let onOpenGallery: (String) -> Void = { navigation.openGallery($0) }
        let onOpenExportTab: (String, ExportRangeIntent) -> Void = { id, intent in
            openExport(sessionId: id, intent: intent)
        }

        switch tab {
        case .control:
            SessionControlView(
                sessionId: sessionId,
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings,
                onOpenExportTab: onOpenExportTab,
                // D10：冲突待办带上「只看冲突」意图（未接线时退回普通挑片页）。
                onReviewXmpConflicts: { sessionId in
                    openCullingConflicts(sessionId: sessionId)
                },
                // D10：离线照片 → 图库只看离线；分析过期 → 人脸页直达分析步骤。
                onReviewOfflinePhotos: { sessionId in
                    openGalleryOffline(sessionId: sessionId)
                },
                onReviewStaleAnalysis: { sessionId in
                    openFaceAnalyze(sessionId: sessionId)
                }
            )
        case .faceKw:
            // 深链（人物库「前往人脸审核」）：VM 可能是之前缓存的，角色过滤由
            // 页面在 .task 里消费（不能在 body 求值期改 @Observable 状态）。
            FaceKeywordingView(
                viewModel: faceViewModel(for: sessionId),
                router: router,
                pendingRoleFilter: faceKwInitialRole,
                // D10：控制中心「重新分析」意图（直达分析步骤）。
                analyzeIntent: draftCache.pendingFaceAnalyze.contains(sessionId),
                onConsumeAnalyzeIntent: {
                    draftCache.pendingFaceAnalyze.remove(sessionId)
                },
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        case .duplicates:
            DuplicatesView(
                viewModel: duplicatesViewModel(for: sessionId),
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings,
                // E：成员行「查看照片」→ 该照片的图库查看器（按 photoId 匹配）。
                onOpenPhoto: { photoId in
                    navigation.openGallery(sessionId, photoId: photoId)
                }
            )
        case .culling:
            CullingView(
                viewModel: cullingViewModel(for: sessionId),
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings,
                // D10：控制中心「逐条裁决」意图（只看 XMP 冲突）。
                conflictsIntent: draftCache.pendingCullingConflicts.contains(sessionId),
                onConsumeConflictsIntent: {
                    draftCache.pendingCullingConflicts.remove(sessionId)
                }
            )
        case .export:
            ExportView(
                viewModel: exportViewModel(for: sessionId),
                router: router,
                rangeIntent: draftCache.pendingExportIntent[sessionId],
                onConsumeRangeIntent: { consumeExportIntent(sessionId: sessionId) },
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        }
    }

    // MARK: - 视图模型生命周期

    private func syncViewModels(for destination: RootNavigation.Destination) {
        switch destination {
        case .gallery(let id):
            if galleryViewModel?.sessionId != id {
                galleryViewModel = GalleryViewModel(sessionId: id, provider: galleryProvider)
            }
        case .similarity(let id):
            if similarityViewModel?.sessionId != id {
                similarityViewModel?.stopProgressPolling()
                similarityViewModel?.stopResultPolling()
                similarityViewModel = SimilarityViewModel(
                    sessionId: id,
                    provider: similarityProvider,
                    captureOne: CaptureOneBridge(router: router)
                )
            } else {
                // 回到同一 similarity：恢复因隐藏而停止的轮询（按当前状态裁剪）。
                if similarityViewModel?.isAnalyzing == true {
                    similarityViewModel?.startProgressPolling()
                }
                if similarityViewModel?.result == nil {
                    similarityViewModel?.startResultPolling()
                }
            }
        default:
            break
        }
    }

    /// 窗口标题跟随当前会话：有会话时用会话名，无会话（或无名称）保持「Gather」。
    private func refreshWindowTitle() {
        guard let sessionId = navigation.currentSessionId else {
            windowTitle = "Gather"
            return
        }
        let sessions = (try? provider.listSessions()) ?? []
        windowTitle = sessions.first(where: { $0.id == sessionId })?.name ?? "Gather"
    }
}

// MARK: - 页面内联提示条（原生）

/// 页面级内联提示：SF Symbol + 文字 + 语义色底，取代旧版裸色块横幅。
public struct NativeBanner: View {
    public let text: String
    public var color: Color = GatherTheme.error
    public var systemImage: String?
    public var onDismiss: (() -> Void)?

    public init(text: String, color: Color = GatherTheme.error, onDismiss: (() -> Void)? = nil) {
        self.text = text
        self.color = color
        self.systemImage = nil
        self.onDismiss = onDismiss
    }

    public init(text: String, systemImage: String, color: Color = GatherTheme.error, onDismiss: (() -> Void)? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
        self.onDismiss = onDismiss
    }

    private var resolvedImage: String {
        if let systemImage { return systemImage }
        return color == GatherTheme.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: resolvedImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(GatherLocalization.l("关闭"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
