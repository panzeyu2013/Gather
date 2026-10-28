// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryView.swift
// Phase 3.2 Gallery（工作区浏览）：SwiftUI 页面（宿主内经 GatherProtocol 端口访问）。
// TS 源: desktop/src/renderer/pages/SessionDetail/Gallery.tsx（工具栏/选择栏/
//       justified 网格/哨兵分页/变体徽标）+ pages/SessionDetail/index.tsx（页签）
//
// Cut 4 / 4c-2c：1,368 行单文件拆为壳 + 内容/工具栏/检查器/网格/Cell/Lightbox
// （纯搬移，行为不变）。本文件只留壳：@State/@SceneStorage 身份、init、body 与
// .task(id: sessionId)/.onReceive/.onChange/.sheet 的挂载层级和顺序。
// - 页面结构 / 索引头 / 选择栏 / 空态 / 灯箱呈现与入口意图：GalleryView+Content；
// - 工具栏：GalleryToolbar；筛选 / 显示检查器：GalleryInspector；
// - 网格（含行内 .onAppear 预取）：GalleryGrid；单元：GalleryCellView；
// - 灯箱与滚轮捕获：LightboxView；页签枚举已迁 Interaction/SessionPage.swift。
//
// 原生化（B1/B3/B4/B5/B6）：
// - 页面头部交给会话页骨架：GatherSessionPage 负责 7 段页签 / 返回按钮 /
//   画布背景 / navigationSubtitle / 页面级可见性（workspace.setPageVisible）；
//   本页只留 C1 状态胶囊/刷新/设置（.primaryAction）；
// - 浏览选项（筛选 / 显示）移出工具栏 → 右侧 .inspector（Bridge 右栏 /
//   Capture One 工具页范式：工具栏只留模式与瞬时动作，浏览/筛选选项进检查器；
//   显示/隐藏按钮由系统提供，不自绘）；
// - 搜索改 .searchable；空态 / 无结果 / 加载失败改 ContentUnavailableView；
// - 选中栏改用系统选中色（selectedContentBackgroundColor / …TextColor），
//   不再用「白字压品牌色」；
// - 灯箱 ←/→ 改 .onKeyPress + .focusable，删除 NSEvent 本地监听；
// - 页面不再自我隐藏（disabled / allowsHitTesting / accessibilityHidden 三件套
//   已随外壳条件构建删除）。
import SwiftUI
import AppKit
import GatherProtocol

package struct GalleryView: View {
    @Bindable var viewModel: GalleryViewModel
    let culling: any CullingAPI
    /// 所属会话工作区（Cut 4 / 4a-2c）：入口意图（照片 / 筛选）在 .task 里 take；
    /// 会话页骨架也用它做页面级可见性路由（setPageVisible(.gallery,…)）。
    private let workspace: SessionWorkspace

    /// N07：从全局图库点进来时要打开的那张照片（一次性消费）。
    ///
    /// 旧实现把「点击全局图库卡片」当成「打开该工作区的控制中心」，用户跨工作区
    /// 找到的具体照片被丢掉；这里把它落到图库查看器上。
    @State var pendingInitialPhotoId: String?
    /// 只有路径的调用方（相似度成员行）用：id 匹配不到时按 filepath 匹配。
    @State var pendingInitialPhotoPath: String?
    /// P0 / B2：单张元数据编辑 sheet（检查器扩展不能自带存储属性）。
    @State var showMetadataEditor = false
    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（workspace.gallery），
    /// 外壳不再维护 gallery 单槽，也不再在导航时替换 VM。
    ///
    /// Cut 4 / 4a-2c：照片 / 筛选入口意图改由 `.task` 从 workspace take；
    /// 页面不再接收 initialPhoto* / filterIntent / isActive，也删除兼容 init。
    /// 会话页迁移：导航闭包（onBack/onOpenSimilarity/onOpenTab/onOpenSettings）
    /// 全部删除——返回与 7 段页签由 `GatherSessionPage` 承担，设置走
    /// `\.openSettings`，其余跳转走 `\.navigator`。
    package init(workspace: SessionWorkspace, culling: any CullingAPI) {
        self.workspace = workspace
        self.viewModel = workspace.gallery
        self.culling = culling
    }

    /// Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView / SessionPageHost）。
    /// Cut 4 / 4b-2i：本页全部文案（75 处）改在渲染期解析——查表时点不再
    /// 捕获进程语言，切语言后已渲染的视图下次 body 求值即换文案。
    @Environment(\.languageStore) private var languageStore
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 会话页骨架统一提供返回与 7 段页签；页面自己只从环境取路由能力。
    /// 新代码优先 `open(_ page:in:)`（此处「前往控制中心」即走它）。
    @Environment(\.navigator) var navigator: RootNavigation?
    /// 设置入口（工具栏齿轮 / C1 胶囊）：直接打开系统设置窗，不再收导航闭包。
    @Environment(\.openSettings) var openSettings

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var density = 220.0
    @State var lightboxIndex: Int?
    /// 网格行布局缓存（避免 ScrollView 滚动时反复重算 justified 布局）。
    @State var layoutCache = GalleryLayoutCache()
    /// Lightbox 打开期间错过的终态事件：关闭后补一次刷新。
    @State var refreshDeferredWhileLightbox = false
    /// 右侧检查器（筛选 / 显示）：浏览选项不属于工具栏——参考 Bridge 右栏
    /// （Filter / Collections）与 Capture One 工具页：内容永远留在中央，
    /// 浏览选项进侧面板，工具栏只承担模式与瞬时动作。
    /// macOS 14 起 `.inspector` 是系统 API，工具栏的显示/隐藏按钮（系统提供）
    /// 与列宽记忆都不需要自己维护；可见性用 @SceneStorage 按页记忆——跨导航
    /// 重建 / 新窗口都保持（参考 darktable 各视图独立存储面板可见性）。
    @SceneStorage("gallery.inspectorVisible") private var showInspector = true

    package var body: some View {
        // 会话页骨架：7 段页签 / 返回 / 画布背景 / 副标题 / 页面级可见性都在里面。
        // 会话名由外壳的窗口标题承载（RootView.windowTitle）；页面只给副标题，
        // 避免 macOS 26/27 在标题栏与工具栏导航位重复显示同一个会话名。
        GatherSessionPage(page: .gallery, workspace: workspace, subtitle: l10n("图库")) {
            page
        }
        .toolbar { toolbarItems }
        // 右侧检查器：筛选 / 显示选项（系统在工具栏提供显示/隐藏按钮）。
        .inspector(isPresented: $showInspector) {
            inspector
        }
        // 搜索留在内容列：工具栏 search 在 inspector 打开时会横跨两栏。
        .onChange(of: viewModel.search) { _, _ in viewModel.searchChanged() }
        .task(id: viewModel.sessionId) {
            // Cut 4 / 4a-2c：入口意图取出即清（一次性事件，不跨进入重复套用）。
            if case let .galleryPhoto(id, path)? = workspace.take(.galleryPhoto) {
                pendingInitialPhotoId = id
                pendingInitialPhotoPath = path
            }
            // N07 / D08：目标照片不能被本地筛选藏起来——先把搜索与筛选清回默认。
            // 旧判断只看 pendingInitialPhotoId，**只带路径**的入口（相似度成员行）
            // 不会走这条分支，目标会被既有筛选藏住。
            if pendingInitialPhotoId != nil || pendingInitialPhotoPath != nil {
                let needsReset = !viewModel.search.isEmpty || viewModel.filter != .all
                viewModel.search = ""
                viewModel.filter = .all
                if needsReset { viewModel.filterOrVariantChanged() }
            }
            // D10：入口筛选意图（只看离线等）。目标照片的「清筛选」在前，
            // 意图在后；take 恒清，但两者同时存在时以照片目标为准
            //（不能把目标又筛掉）。
            if case let .galleryFilter(filter)? = workspace.take(.galleryFilter),
               pendingInitialPhotoId == nil, pendingInitialPhotoPath == nil {
                viewModel.filter = filter
                viewModel.filterOrVariantChanged()
            }
            // 会话切换时外壳重建 VM 但视图身份不变：id 变化会重启本任务，
            // 保证新 VM 立即加载而非永远 loading。
            await viewModel.loadIfNeeded()
            await locatePendingPhotoIfNeeded()
            // 页面级可见性（含轮询启停）由 GatherSessionPage 的
            // onAppear/onDisappear 经 workspace.setPageVisible 统一接管：
            // 本任务只负责取数，不再在加载结束后补置可见（那会与离场竞态）。
        }
        .onChange(of: viewModel.sessionId) { _, _ in
            // 双保险：.task(id:) 重启之外的路径（如会话切换发生在视图重排窗口）。
            Task { await viewModel.loadIfNeeded() }
        }
        // D-3：改看轻量指纹（代数+参数+条数），避免每次 body 对整数组深比较。
        .onChange(of: viewModel.filteredFingerprint) { _, _ in
            // 过滤/事件刷新后行项 index 指向旧数组 —— 布局缓存立即失效，
            // 避免 count/width/density 未变时复用错位行。
            layoutCache.reset()
            // N07：分页/筛选刷新后目标照片才就位时，在这里补一次打开。
            openPendingPhotoIfAvailable(viewModel.filteredPhotos)
        }
        .refreshOnJobTerminal(sessionId: viewModel.sessionId, debounce: .zero) {
            // 仅本工作区的终态事件触发重载（其他会话的索引结束不打扰浏览）。
            scheduleRefreshFromEvent()
        }
        // 写路径广播（挑片决策/库变更/写回/人脸绑定）：命中本会话才刷新。
        // photo.list_page 行不含评分/色标字段，重取后随行更新的是离线态、
        // 变体徽标、人脸计数与行集合本身（照片被移除/恢复）。
        .refreshOnDomainEvents(
            [.culling, .library, .metadata, .faceKeywording],
            sessionId: viewModel.sessionId,
            debounce: .zero
        ) {
            scheduleRefreshFromEvent()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            // 条件构建：页面存在即可见；进度帧只更新缓存，按 scopeId 过滤。
            // 索引活跃期间 jobs:progress 帧 → 索引头实时刷新（VM 内 1s 去抖）。
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.handleIndexJobProgress(event)
        }
        .sheet(isPresented: lightboxPresented) {
            lightboxSheet
        }
    }
}

#if DEBUG
#Preview("Gallery · 图库网格") {
    PreviewFactory.galleryPage()
}
#endif
