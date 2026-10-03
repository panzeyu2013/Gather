// desktop/native/gather-app/Sources/GatherApp/Gallery/GalleryView.swift
// Phase 3.2 Gallery（工作区浏览）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/SessionDetail/Gallery.tsx（工具栏/选择栏/
//       justified 网格/哨兵分页/变体徽标）+ pages/SessionDetail/index.tsx（页签）
//
// 原生化（B1/B3/B4/B5/B6）：
// - 页面头部交给窗口 chrome：.navigationTitle（会话名）+ .navigationSubtitle +
//   工具栏分段页签（sessionPageChrome）、返回按钮（.navigation）、
//   C1 状态胶囊/刷新/设置（.primaryAction）；
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
import GatherCore

/// 工作区页签（对齐 SessionDetail/index.tsx 的 NavLink；全部由 SwiftUI 承载）。
/// 页签文案统一由 SessionTabBar.tabTitle 提供（中英双语），此处不再持有。
enum SessionTab: String, CaseIterable, Identifiable {
    case control = "control"
    case faceKw = "face-kw"
    case duplicates
    case culling
    case export

    var id: String { rawValue }
}

/// 网格行布局缓存（引用语义盒子）。
///
/// justified 布局在 body 求值期间计算；把结果写回 @State 会触发 SwiftUI 的
/// 「Modifying state during view update」。写入引用盒子不经过 SwiftUI 状态机，
/// 缓存语义（key 命中即复用）与旧实现完全一致。
private final class GalleryLayoutCache {
    var key = ""
    var rows: [JustifiedLayoutRow] = []

    func reset() {
        key = ""
        rows = []
    }
}

struct GalleryView: View {
    @Bindable var viewModel: GalleryViewModel
    let router: SessionCommandRouter
    let onBack: () -> Void
    let onOpenSimilarity: (String) -> Void
    let onOpenTab: (String, SessionTab) -> Void
    let onOpenSettings: () -> Void
    /// 轮询门控：外壳已改为按目的地条件构建页面，本页不再用可见性隐藏自己，
    /// 该参数只用于门控 C1 胶囊订阅与索引状态轮询。
    var isActive: Bool = true

    /// N07：从全局图库点进来时要打开的那张照片（一次性消费）。
    ///
    /// 旧实现把「点击全局图库卡片」当成「打开该工作区的控制中心」，用户跨工作区
    /// 找到的具体照片被丢掉；这里把它落到图库查看器上。
    @State private var pendingInitialPhotoId: String?
    /// 只有路径的调用方（相似度成员行）用：id 匹配不到时按 filepath 匹配。
    @State private var pendingInitialPhotoPath: String?
    /// D10：入口筛选意图（控制中心「N 张照片离线 → 查看」）。
    private let filterIntent: GalleryFilter?
    private let onConsumeFilterIntent: () -> Void

    init(
        viewModel: GalleryViewModel,
        router: SessionCommandRouter,
        initialPhotoId: String? = nil,
        initialPhotoPath: String? = nil,
        filterIntent: GalleryFilter? = nil,
        onConsumeFilterIntent: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenSettings: @escaping () -> Void = {},
        isActive: Bool = true
    ) {
        self.viewModel = viewModel
        self.router = router
        self.filterIntent = filterIntent
        self.onConsumeFilterIntent = onConsumeFilterIntent
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenSettings = onOpenSettings
        self.isActive = isActive
        _pendingInitialPhotoId = State(initialValue: initialPhotoId)
        _pendingInitialPhotoPath = State(initialValue: initialPhotoPath)
    }

    /// TS: DENSITY_OPTIONS（行高密度）。计算属性：static let 只求值一次，
    /// 语言切换后会残留旧语言文案。
    private var densityOptions: [(value: Double, label: String)] {
        [
            (160, GatherLocalization.l("小图")),
            (220, GatherLocalization.l("中图")),
            (300, GatherLocalization.l("大图")),
        ]
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var density = 220.0
    @State private var lightboxIndex: Int?
    /// 网格行布局缓存（避免 ScrollView 滚动时反复重算 justified 布局）。
    @State private var layoutCache = GalleryLayoutCache()
    /// Lightbox 打开期间错过的终态事件：关闭后补一次刷新。
    @State private var refreshDeferredWhileLightbox = false
    /// 隐藏期间错过的事件刷新：重新可见时补一次（隐藏页不发命令）。
    @State private var refreshDeferredWhileHidden = false
    /// 右侧检查器（筛选 / 显示）：浏览选项不属于工具栏——参考 Bridge 右栏
    /// （Filter / Collections）与 Capture One 工具页：内容永远留在中央，
    /// 浏览选项进侧面板，工具栏只承担模式与瞬时动作。
    /// macOS 14 起 `.inspector` 是系统 API，工具栏的显示/隐藏按钮（系统提供）
    /// 与列宽记忆都不需要自己维护；可见性用 @SceneStorage 按页记忆——跨导航
    /// 重建 / 新窗口都保持（参考 darktable 各视图独立存储面板可见性）。
    @SceneStorage("gallery.inspectorVisible") private var showInspector = true

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GatherTheme.windowBackground)
            // 会话名走窗口标题；页面身份走副标题（不再在内容区画 26pt 大标题、
            // 也不再显示任何会话 UUID）。
            .navigationTitle(viewModel.session?.name ?? GatherLocalization.l("图库"))
            .sessionPageChrome(
                subtitle: GatherLocalization.l("图库"),
                selection: .browse,
                onBrowse: {},
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
            .toolbar { toolbarItems }
            // 右侧检查器：筛选 / 显示选项（系统在工具栏提供显示/隐藏按钮）。
            .inspector(isPresented: $showInspector) {
                inspector
            }
            .searchable(
                text: $viewModel.search,
                placement: .toolbar,
                prompt: Text(GatherLocalization.l("搜索文件名…"))
            )
            .onChange(of: viewModel.search) { _, _ in viewModel.searchChanged() }
            .task(id: viewModel.sessionId) {
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
                // 意图在后，两者同时存在时以照片目标为准（不能把目标又筛掉）。
                if let filterIntent, pendingInitialPhotoId == nil, pendingInitialPhotoPath == nil {
                    viewModel.filter = filterIntent
                    viewModel.filterOrVariantChanged()
                    onConsumeFilterIntent()
                }
                // 会话切换时外壳重建 VM 但视图身份不变：id 变化会重启本任务，
                // 保证新 VM 立即加载而非永远 loading。
                await viewModel.loadIfNeeded()
                await locatePendingPhotoIfNeeded()
                if isActive { viewModel.startIndexStatusPolling() }
            }
            .onChange(of: viewModel.sessionId) { _, _ in
                // 双保险：.task(id:) 重启之外的路径（如会话切换发生在视图重排窗口）。
                Task { await viewModel.loadIfNeeded() }
            }
            // B2（9-30 审查）：条件构建下页面销毁**不会**触发 isActive 变化，
            // 因此必须显式在 onDisappear 停轮询；否则用户离开图库后
            // workspace.status 的 3s/15s 轮询仍在后台跑（VM 由外壳持有）。
            .onDisappear {
                viewModel.stopIndexStatusPolling()
            }
            .onChange(of: isActive) { _, active in
                // 索引头轮询门控（兜底路径：外壳若改为常驻页面，靠这里切换）。
                if active {
                    viewModel.startIndexStatusPolling()
                    // 隐藏期间错过的事件刷新：重新可见时补一次（不发命令则只登记）。
                    if refreshDeferredWhileHidden {
                        refreshDeferredWhileHidden = false
                        viewModel.scheduleEventRefresh()
                    }
                } else {
                    viewModel.stopIndexStatusPolling()
                }
            }
            // D-3：改看轻量指纹（代数+参数+条数），避免每次 body 对整数组深比较。
            .onChange(of: viewModel.filteredFingerprint) { _, _ in
                // 过滤/事件刷新后行项 index 指向旧数组 —— 布局缓存立即失效，
                // 避免 count/width/density 未变时复用错位行。
                layoutCache.reset()
                // N07：分页/筛选刷新后目标照片才就位时，在这里补一次打开。
                openPendingPhotoIfAvailable(viewModel.filteredPhotos)
            }
            .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { notification in
                // 仅本工作区的终态事件触发重载（其他会话的索引结束不打扰浏览）。
                guard let event = notification.object as? GatherJobEvent,
                      event.job.scopeId == viewModel.sessionId else { return }
                scheduleRefreshFromEvent()
            }
            // 写路径广播（挑片决策/库变更/写回/人脸绑定）：命中本会话才刷新。
            // photo.list_page 行不含评分/色标字段，重取后随行更新的是离线态、
            // 变体徽标、人脸计数与行集合本身（照片被移除/恢复）。
            .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
                guard let change = notification.object as? GatherDomainChange,
                      change.matches(sessionId: viewModel.sessionId),
                      [.culling, .library, .metadata, .faceKeywording].contains(change.domain) else { return }
                scheduleRefreshFromEvent()
            }
            .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
                // 隐藏页不发命令：进度帧本身只更新缓存，但 VM 内去抖后会执行
                // workspace.status；不可见时直接丢弃，重新可见由轮询补齐。
                guard isActive else { return }
                // 索引活跃期间 jobs:progress 帧 → 索引头实时刷新（VM 内 1s 去抖）。
                guard let event = notification.object as? GatherJobEvent else { return }
                viewModel.handleIndexJobProgress(event)
            }
            .sheet(isPresented: lightboxPresented) {
                lightboxSheet
            }
    }

    // MARK: - 页面结构（头部已移入窗口 chrome）

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                // 旧版裸红字 → 原生提示条（图标 + 语义色底）。
                NativeBanner(
                    text: String(format: GatherLocalization.l("操作失败：%@"), error),
                    color: GatherTheme.error
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            indexHeaderRow
            if !viewModel.selectedIds.isEmpty {
                selectionBar
            }
            content
        }
    }

    // MARK: - 工具栏（返回 / C1 / 刷新 / 设置：只留模式与瞬时动作）

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // 内容区返回按钮 → 工具栏导航位（命中区由系统控件保证 ≥24pt）。
        ToolbarItem(placement: .navigation) {
            Button(action: onBack) {
                Label(GatherLocalization.l("返回"), systemImage: "chevron.backward")
            }
            .help(GatherLocalization.l("返回到上一页"))
        }
        // 按功能分组（HIG Toolbars：「Group toolbar items logically by function
        // and frequency of use… aim for a maximum of three」）。macOS 26 起
        // ToolbarSpacer 会让每组玻璃各自成为独立的胶囊；更早版本它不存在，
        // 于是退化成今天的一整条。
        // 浏览/筛选选项（筛选 / 密度 / 变体）已移入右侧检查器：
        // 工具栏只剩模式与瞬时动作——C1 状态胶囊 + 刷新，以及设置。
        ToolbarItemGroup(placement: .primaryAction) {
            // C1 状态胶囊（旧版画在页头行里）。
            C1StatusCapsuleHost(
                sessionId: viewModel.sessionId,
                router: router,
                onOpenSettings: onOpenSettings,
                isActive: isActive
            )
            refreshButton
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            settingsButton
        }
    }

    /// TS: FILTER_OPTIONS —— 原生下拉（可访问名是真标签，不再是当前值）。
    /// 检查器分区「筛选」的行：走出工具栏后标签恢复可见（移除 .labelsHidden），
    /// 可访问名与提示原样保留。
    private var filterPicker: some View {
        Picker(GatherLocalization.l("筛选"), selection: $viewModel.filter) {
            Text(GatherLocalization.l("全部")).tag(GalleryFilter.all)
            Text(GatherLocalization.l("有人脸")).tag(GalleryFilter.hasFace)
            Text(GatherLocalization.l("无人脸")).tag(GalleryFilter.noFace)
            // D10：离线照片的可见筛选（控制中心「N 张照片离线」直达这里）。
            Text(GatherLocalization.l("离线")).tag(GalleryFilter.offline)
        }
        .pickerStyle(.menu)
        .help(GatherLocalization.l("筛选"))
        .accessibilityLabel(GatherLocalization.l("筛选"))
        .onChange(of: viewModel.filter) { _, _ in viewModel.filterOrVariantChanged() }
    }

    /// TS: DENSITY_OPTIONS —— 原生下拉（检查器分区「显示」的行）。
    private var densityPicker: some View {
        Picker(GatherLocalization.l("网格尺寸"), selection: $density) {
            ForEach(densityOptions, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .help(GatherLocalization.l("网格尺寸"))
        .accessibilityLabel(GatherLocalization.l("网格尺寸"))
    }

    /// TS Gallery.tsx:274-280 —— 变体展开开关。
    /// 旧版手绘「primarySoft 底 + 主色描边 + aria-pressed」→ 原生 Toggle；
    /// 检查器行用系统勾选样式（.button 图标胶囊只适合工具栏，标签不可读）。
    private var variantsToggle: some View {
        Toggle(isOn: $viewModel.expandVariants) {
            Label(GatherLocalization.l("展开所有变体"), systemImage: "rectangle.stack")
        }
        .help(
            viewModel.expandVariants
                ? GatherLocalization.l("折叠 RAW/JPEG")
                : GatherLocalization.l("展开所有变体")
        )
        .accessibilityLabel(GatherLocalization.l("展开所有变体"))
        .accessibilityValue(
            viewModel.expandVariants ? GatherLocalization.l("已展开") : GatherLocalization.l("已折叠")
        )
        .onChange(of: viewModel.expandVariants) { _, _ in viewModel.filterOrVariantChanged() }
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.load() }
        } label: {
            Label(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise")
        }
        .help(GatherLocalization.l("刷新"))
        .keyboardShortcut("r", modifiers: .command)
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label(GatherLocalization.l("设置"), systemImage: "gearshape")
        }
        .help(GatherLocalization.l("设置"))
    }

    // MARK: - 右侧检查器（浏览/筛选选项：筛选 / 显示）

    /// Bridge 右栏 / Capture One 工具页范式：内容区只留网格，浏览与筛选选项
    /// 进检查器。macOS 14 起 .inspector 是系统 API——工具栏右侧的显示/隐藏
    /// 按钮与列宽记忆都由系统提供，本页不自绘开关。
    ///
    /// 仅收拢页面已有状态的两组选项：
    /// - 筛选：viewModel.filter（全部 / 有人脸 / 无人脸）；
    /// - 显示：网格尺寸 density + 展开所有变体 viewModel.expandVariants。
    ///
    /// 评分与色标：GalleryViewModel 未暴露 rating/colorLabel 过滤状态
    ///（photo.list_page 行本身不含评分/色标字段，见本文件「写路径广播」注），
    /// 无可绑定模型 → 不设该分区（约束：不新增 ViewModel API）。
    private var inspector: some View {
        // 约束循环修复（F01）：grouped Form 挂在 .inspector 上会在 AppKit 的
        // 约束更新阶段抛 NSGenericException（"more Update Constraints in Window
        // passes than there are views"）——LibraryView.libraryInspector 已记录
        // 同一崩溃栈并改为此形态，本页原先漏改。检查器只放「选项/管理」，
        // ScrollView + 卡片分组同样贴切。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(GatherLocalization.l("筛选")) {
                    filterPicker
                }
                inspectorSection(GatherLocalization.l("显示")) {
                    VStack(alignment: .leading, spacing: 10) {
                        densityPicker
                        variantsToggle
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        // 同 CullingView：理想列宽会计入最小宽度，收窄以避免窄窗口下的约束循环。
        .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
    }

    /// 检查器里的一组选项：标题 + 内容，套系统分组容器（与 LibraryView.supportCard 同形）。
    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.panel)
    }

    // MARK: - Lightbox 呈现

    /// N07：异步分页/筛选刷新后照片才到位，这里补一次消费。
    private var pendingPhotoIds: [String] { viewModel.filteredPhotos.map(\.id) }

    private var lightboxPresented: Binding<Bool> {
        Binding(
            get: { lightboxIndex != nil },
            // SwiftUI 只在系统侧 dismiss 时回调 setter；LightboxView 的 onClose
            // 不经过这里，因此关闭逻辑统一收敛到 closeLightbox()，防止事件期间
            // 打开 Lightbox 后补刷丢失、refreshDeferredWhileLightbox 泄漏。
            set: { if !$0 { closeLightbox() } }
        )
    }

    @ViewBuilder
    private var lightboxSheet: some View {
        if let index = lightboxIndex {
            LightboxView(
                photos: viewModel.filteredPhotos,
                initialIndex: index,
                onClose: closeLightbox
            )
        }
    }

    /// N07 / D08：把目标照片定位并打开查看器（一次性）。
    ///
    /// 旧实现只在下标已经在 `filteredPhotos` 里时才打开：目标排在第 200 张之后
    /// （初始页大小 200）时，页面只会停在图库首页，用户看不到"查看照片"的结果——
    /// 除非自己恰好滚到目标附近。现在改为**主动向后取页直到找到**（有上限 + 结束后
    /// 未找到也会给出明确反馈），再由 index 打开查看器。
    ///
    /// 匹配顺序：photoId 优先（精确），其次 filepath（相似度成员行只带路径）。
    private func locatePendingPhotoIfNeeded() async {
        guard pendingInitialPhotoId != nil || pendingInitialPhotoPath != nil else { return }
        // 审计 2 P2-4：三态分别处理——「不存在」「超出扫描范围」「取页失败」
        // 旧实现只返回 Bool，三种情况都报「可能已被移除」（瞬时失败会让用户以为照片没了）。
        switch await viewModel.locatePendingPhoto(
            photoId: pendingInitialPhotoId,
            photoPath: pendingInitialPhotoPath
        ) {
        case .found:
            openPendingPhotoIfAvailable(viewModel.filteredPhotos)
        case .notFound:
            // 被删除/不属于本工作区：清掉待定并给出明确反馈，不再静默等待。
            viewModel.reportPhotoTargetMissing()
            pendingInitialPhotoId = nil
            pendingInitialPhotoPath = nil
        case .outOfRange:
            // 目标在工作区里但在扫描上限之外：给可执行建议，同样清掉待定。
            viewModel.reportPhotoTargetOutOfRange()
            pendingInitialPhotoId = nil
            pendingInitialPhotoPath = nil
        case .failed:
            // 取页失败/被新的导航取代：保留待定与原始错误，用户可以重试。
            viewModel.reportPhotoLocateFailed()
        }
    }

    /// 照片就位后打开查看器（一次性）。匹配顺序：photoId 优先，其次 filepath。
    private func openPendingPhotoIfAvailable(_ photos: [GalleryPhotoData]) {
        var index: Int?
        if let photoId = pendingInitialPhotoId {
            index = photos.firstIndex { $0.id == photoId }
        }
        if index == nil, let path = pendingInitialPhotoPath {
            index = photos.firstIndex { $0.filepath == path }
        }
        guard let index else { return }
        pendingInitialPhotoId = nil
        pendingInitialPhotoPath = nil
        lightboxIndex = index
    }

    /// Lightbox 关闭的统一出口：onClose 与 sheet binding setter 共用。
    /// 消费事件期间标记的补刷并复位标志，避免标志泄漏。
    private func closeLightbox() {
        lightboxIndex = nil
        if refreshDeferredWhileLightbox {
            refreshDeferredWhileLightbox = false
            scheduleRefreshFromEvent()
        }
    }

    /// 事件 → 刷新统一入口：可见才发命令；隐藏/Lightbox 期间只登记，
    /// 回到可见（或关闭 Lightbox）时补一次（隐藏页不发命令）。
    private func scheduleRefreshFromEvent() {
        guard isActive else {
            refreshDeferredWhileHidden = true
            return
        }
        if lightboxIndex != nil {
            // 全量重排会打断预览：登记到关闭后补刷。
            refreshDeferredWhileLightbox = true
        } else {
            viewModel.scheduleEventRefresh()
        }
    }

    /// 右键「在 Finder 中显示」的 URL：路径为空/不可用时返回 nil（跳过该项）。
    private static func finderURL(for photo: GalleryPhotoData) -> URL? {
        finderURLForPath(photo.filepath)
    }

    // MARK: - 索引头（TS index.tsx:158-188 —— 照片计数/索引进度行）

    /// deriveIndexHeaderCopy（indexProgress.ts:32-63）等价行：
    /// 扫描中「正在索引 N / M（x%）」+ 原生进度条；失败「索引失败」+ 重试；
    /// 成功/无任务「已索引 N 张照片」；photoCount==0 且无任务时不渲染。
    @ViewBuilder
    private var indexHeaderRow: some View {
        if let copy = GalleryViewModel.indexHeaderCopy(
            status: viewModel.workspaceStatus,
            photoCount: viewModel.session?.photoCount ?? 0,
            truncatedImport: viewModel.session?.truncatedImport ?? false
        ) {
            // D-1（审计 3/5）：索引头是最后一个不可滚动的固定横排（文案 + 140pt 进度条
            // + 百分比），窄窗口下会把内容最小宽度顶上去。改为横向可滚动 + 固定分隔线，
            // 与挑片 infoBar 同一处理方式（不再用 Spacer 抢宽度）。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    indexHeaderContent(copy)
                    if viewModel.isFetchingNextPage {
                        Divider().frame(height: 14)
                        ProgressView()
                            .controlSize(.small)
                            .help(GatherLocalization.l("加载照片中…"))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(minHeight: 26)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: copy.kind)
        }
    }

    @ViewBuilder
    private func indexHeaderContent(_ copy: GalleryIndexHeaderCopy) -> some View {
        switch copy.kind {
        case .scanning:
            Text(copy.text)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let percent = copy.percent {
                // TS ProgressBar 语义 → 原生线性进度条 + 百分比（计数：.callout）。
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                    .accessibilityLabel(GatherLocalization.l("索引进度"))
                    .accessibilityValue("\(percent)%")
                Text("\(percent)%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        case .error:
            // 状态色不做正文前景：图标承担颜色语义，正文保持 .primary。
            Label {
                Text(copy.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GatherTheme.error)
            }
            .font(.callout)
            // TS index.tsx:179-183 —— 旧版一体「索引失败，点击重试」
            // 拆为「索引失败」+ 独立「重试」按钮。
            Button(GatherLocalization.l("重试")) {
                Task { await viewModel.retryIndex() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .count:
            Text(copy.text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 选择栏（旧版：主色实底 + 白字白胶囊 → 系统选中色）

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Label(
                String(format: GatherLocalization.l("选中 %lld 张照片"), viewModel.selectedIds.count),
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout.weight(.medium))
            Spacer(minLength: 0)
            Button(GatherLocalization.l("全选")) {
                toggleSelectAllVisible()
            }
            .buttonStyle(.borderless)
            .help(GatherLocalization.l("选择当前筛选下的全部照片"))
            Button(GatherLocalization.l("取消选择")) {
                viewModel.clearSelection()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(nsColor: .selectedContentBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    /// 全选/取消全选当前筛选结果（VM 只暴露 toggle，逐个切换保持单一事实源）。
    private func toggleSelectAllVisible() {
        let visible = viewModel.filteredPhotos.map(\.id)
        guard !visible.isEmpty else { return }
        let selected = viewModel.selectedIds
        if visible.allSatisfy({ selected.contains($0) }) {
            visible.forEach { viewModel.toggleSelection($0) }
        } else {
            visible.filter { !selected.contains($0) }.forEach { viewModel.toggleSelection($0) }
        }
    }

    // MARK: - 内容（TS justified 网格 + 哨兵分页）

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(GatherLocalization.l("加载照片中…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            loadFailureView(message)
        case .loaded:
            loadedContent
        }
    }

    /// 加载失败：系统空态视图 + 明确出口（重试），不再是裸红字。
    private func loadFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                String(format: GatherLocalization.l("加载照片失败：%@"), message),
                systemImage: "exclamationmark.triangle"
            )
        } actions: {
            Button(GatherLocalization.l("重试")) {
                Task { await viewModel.load() }
            }
            .gatherPrimaryActionButton()
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadedContent: some View {
        let filtered = viewModel.filteredPhotos
        if filtered.isEmpty {
            if viewModel.loadedPhotos.isEmpty {
                emptyLibraryView
            } else {
                noMatchView
            }
        } else {
            gridView(filtered)
        }
    }

    /// 真空库：给「导入文件夹 / 前往控制中心 / 刷新」三条出口，而不是错误文案。
    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("暂无照片"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(GatherLocalization.l("索引完成后照片将显示在这里"))
        } actions: {
            Button(GatherLocalization.l("导入文件夹")) {
                // F02：走统一入口（宿主打开目录选择器）。不再 post 带 nil 载荷的
                // menuImportFolder——那条通知的语义是「已选好目录」，接收方要求 URL，
                // nil 会被静默丢弃，按钮点了没反应。
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            }
            .gatherPrimaryActionButton()
            Button(GatherLocalization.l("前往控制中心")) {
                onOpenTab(viewModel.sessionId, .control)
            }
            Button(GatherLocalization.l("刷新")) {
                Task { await viewModel.load() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }

    /// 搜索/筛选无结果：清除筛选永远可点。
    private var noMatchView: some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("没有符合条件的照片"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(GatherLocalization.l("调整或清除筛选条件以查看全部照片"))
        } actions: {
            Button(GatherLocalization.l("清除筛选")) {
                viewModel.search = ""
                viewModel.filter = .all
                viewModel.filterOrVariantChanged()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }

    private func gridView(_ filtered: [GalleryPhotoData]) -> some View {
        GeometryReader { geometry in
            // 行区域实际内容宽度 = 全宽 − LazyVStack 水平 padding 24×2。
            let rows = layoutRows(filtered: filtered, width: max(1, geometry.size.width - 48))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        rowView(row, filtered: filtered)
                            .frame(height: row.height)
                    }
                    // TS 哨兵：滚近末尾触发下一页（键集游标）。
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded() }
                        }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
    }

    /// TS: layoutJustifiedRows 的结果缓存（key 覆盖 filtered 身份 + 宽度 + 密度）。
    /// filtered 数据变化时由 .onChange(of: filteredPhotos) 整体失效；key 内
    /// 再叠首尾 id 折叠哈希，双保险防止同 count 复用错位行。
    private func layoutRows(filtered: [GalleryPhotoData], width: Double) -> [JustifiedLayoutRow] {
        // D-3：用数据代数替代每次 body 对全部 id 的 O(n) 哈希；**但必须带上
        // filtered 指纹**（第二轮验证）：仅用 代数|条数|宽|密度 时，「搜索词变化但
        // 命中数相同」会复用上一组照片的行高（照片集合正确、几何错位）。
        let key = "\(viewModel.layoutGeneration)|\(viewModel.filteredFingerprint)|\(filtered.count)|\(width)|\(density)"
        if layoutCache.key == key {
            return layoutCache.rows
        }
        let source = filtered.map { GalleryAspectItem(width: Double(max(1, $0.width)), height: Double(max(1, $0.height))) }
        let rows = layoutJustifiedRows(source: source, containerWidth: width, targetRowHeight: density, gap: 8)
        layoutCache.key = key
        layoutCache.rows = rows
        return rows
    }

    /// 距行末的预取窗口（项数）：旧版 IntersectionObserver rootMargin
    /// 1600px ≈ 数屏；LazyVStack 行进入视口即触发，此窗口约 1-2 屏。
    private static let prefetchRemaining = 20

    private func rowView(_ row: JustifiedLayoutRow, filtered: [GalleryPhotoData]) -> some View {
        HStack(spacing: 8) {
            ForEach(row.items, id: \.index) { item in
                // 越界保护：布局缓存/数据刷新后 index 可能指向旧数组。
                if let photo = filtered[safe: item.index] {
                    photoButton(photo, item: item, rowHeight: row.height)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // P11：滚近末尾（距末行 20 项内）即预取下一页（loadMoreIfNeeded 内部
        // hasNextPage/isFetchingNextPage 去重），快滚到底不白屏。
        .onAppear {
            let lastIndex = row.items.last?.index ?? 0
            if lastIndex >= max(0, filtered.count - Self.prefetchRemaining) {
                Task { await viewModel.loadMoreIfNeeded() }
            }
        }
    }

    private func photoButton(_ photo: GalleryPhotoData, item: JustifiedLayoutItem, rowHeight: Double) -> some View {
        Button {
            // TS：Ctrl/⌘ 多选；普通点击打开 Lightbox。
            if NSEvent.modifierFlags.contains(.control) || NSEvent.modifierFlags.contains(.command) {
                viewModel.toggleSelection(photo.id)
            } else {
                lightboxIndex = item.index
            }
        } label: {
            GalleryCellView(
                photo: photo,
                isSelected: viewModel.selectedIds.contains(photo.id),
                thumbnailSize: viewModel.thumbnailSize
            )
            .frame(width: item.width, height: rowHeight)
        }
        .buttonStyle(.plain)
        // HIG：上下文菜单描述指针下的对象（旧版在选中集非空时变成空菜单）。
        .contextMenu {
            if let url = GalleryView.finderURL(for: photo) {
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button(viewModel.selectedIds.contains(photo.id) ? GatherLocalization.l("取消选择") : GatherLocalization.l("选择")) {
                viewModel.toggleSelection(photo.id)
            }
            if !viewModel.selectedIds.isEmpty {
                Button(GatherLocalization.l("取消选择")) {
                    viewModel.clearSelection()
                }
            }
        }
        .help(photo.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(photo.filename)
        .accessibilityValue(cellAccessibilityValue(photo))
        .accessibilityAddTraits(viewModel.selectedIds.contains(photo.id) ? [.isSelected] : [])
    }

    private func cellAccessibilityValue(_ photo: GalleryPhotoData) -> String {
        var parts = ["\(photo.width) × \(photo.height)"]
        if photo.faceCount > 0 {
            parts.append("\(GatherLocalization.l("人脸")) \(photo.faceCount)")
        }
        if photo.status == "missing" {
            parts.append(GatherLocalization.l("离线"))
        }
        return parts.joined(separator: "，")
    }

    // MARK: Lightbox（TS components/Lightbox：预览 + 基础元数据）
}

// MARK: - 网格单元（TS GalleryThumbnail：缩略图 + 文件名 + 变体徽标 + 选中勾）

private struct GalleryCellView: View {
    let photo: GalleryPhotoData
    let isSelected: Bool
    var thumbnailSize: Int

    /// TS: .cell:hover —— 悬停投影 + 提亮；选中态由系统选中色承担。
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoThumbnailView(path: photo.filepath, size: thumbnailSize)
                // 占位尺寸固定（防解码完成前后跳动）：始终撑满单元格。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .brightness(isHovered ? 0.03 : 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if photo.status == "missing" {
                        chip(
                            text: GatherLocalization.l("离线"),
                            icon: "exclamationmark.triangle.fill",
                            iconColor: GatherTheme.error
                        )
                    }
                    if photo.variantCount > 1 {
                        chip(text: String(format: GatherLocalization.l("RAW+JPEG · %lld"), photo.variantCount))
                    }
                }
                Text(photo.filename)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        // 照片底部渐变遮罩（照片查看器的标准做法）。
                        // 旧版渐变只覆盖文字自身的 ~28pt 高度，文字实际落在
                        // 约 35% 黑上，遇到亮照片读不出来；这里加高遮罩并提高
                        // 底部不透明度，保证任何底图上的可读性。
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.55), location: 0.45),
                                .init(color: .black.opacity(0.82), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                selectionCheck
            }
        }
        // TS: 单元格圆角 10（--radius-sm）；选中态 = 系统选中色描边
        //（旧版 .cellSelected outline 2px inset，无填充底色）。
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(nsColor: .selectedContentBackgroundColor)
                        : (isHovered ? GatherTheme.accent.opacity(0.55) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        // TS: .cell:hover —— box-shadow 0 3px 14px rgba(0,0,0,.45) + brightness(1.05)
        // 的原生等价：shadowMd（radius 9 / y 3）+ 缩略图亮度 0.03。
        .shadow(color: isHovered ? GatherTheme.shadowMd : Color.clear, radius: 9, y: 3)
        .onHover { isHovered = $0 }
    }

    /// 照片上的信息芯片：自带深色底 + 白字（不依赖照片亮度，也不会白压亮色）。
    private func chip(text: String, icon: String? = nil, iconColor: Color = .white) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.66)))
    }

    /// 选中勾：系统选中色 + 选中文字色（旧版为主色圆 + 白勾，深色下 ≈2.7:1）。
    private var selectionCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                Color(nsColor: .alternateSelectedControlTextColor),
                Color(nsColor: .selectedContentBackgroundColor)
            )
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityHidden(true)
    }
}

// MARK: - Lightbox（TS components/Lightbox/Lightbox.tsx 的简化版：预览 + 元数据）

/// 越界安全的数组取值（网格行/预览共用）。
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct LightboxView: View {
    let photos: [GalleryPhotoData]
    let initialIndex: Int
    let onClose: () -> Void

    /// 当前照片 id（photos 变化时按 id 重新定位；TS Lightbox.tsx:122
    /// if (!photo) return null 语义，避免事件刷新缩水后下标崩溃）。
    @State private var currentID: String?
    /// 可见区域细节层（去抖 150ms 后更新）。
    @State private var detailTileState: PhotoViewerGeometry.DetailTile?
    @State private var detailTileTask: Task<Void, Never>?
    @State private var scale = 1.0
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    /// 本次拖拽起点基线（审计 B-C2）：translation 相对手势起点，不叠加基线
    /// 会让松手后的下一次拖拽弹回原点。
    @State private var dragStartOffset = CGSize.zero
    /// ←/→ 键：.onKeyPress 需要焦点，灯箱出现时把焦点交给查看器容器
    /// （旧版用 NSEvent.addLocalMonitorForEvents 全局监听，已删除）。
    @FocusState private var keysFocused: Bool

    init(photos: [GalleryPhotoData], initialIndex: Int, onClose: @escaping () -> Void) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.onClose = onClose
        // 越界保护：initialIndex 越界时回退到第一张（photos 为空则 nil → 占位）。
        _currentID = State(initialValue: photos.indices.contains(initialIndex) ? photos[initialIndex].id : photos.first?.id)
    }

    /// TS Lightbox.tsx:122 if (!photo) return null —— 按 id 定位，取不到渲染占位。
    private var currentPhoto: GalleryPhotoData? {
        guard let currentID else { return nil }
        return photos.first { $0.id == currentID }
    }

    private var currentIndex: Int {
        guard let currentID else { return 0 }
        return photos.firstIndex { $0.id == currentID } ?? 0
    }

    var body: some View {
        ZStack {
            // 恒深色查看器背景（与挑片页查看器 GatherTheme.viewerBackground 统一）。
            GatherTheme.viewerBackground
            if let photo = currentPhoto {
                photoViewer(photo)
            } else {
                unavailableView
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        .onKeyPress(.leftArrow) {
            goPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            goNext()
            return .handled
        }
        .onAppear { keysFocused = true }
        .onChange(of: photos) { oldPhotos, newPhotos in
            // 事件刷新后 photos 变化：当前照片 id 消失时不关闭（旧版「数组变化
            // 不重置」语义）——新数组非空则就近定位（沿用旧下标，钳制到边界）
            // 继续浏览，全空则停留占位态。
            guard let currentID, !newPhotos.contains(where: { $0.id == currentID }) else { return }
            if !newPhotos.isEmpty {
                let previousIndex = oldPhotos.firstIndex { $0.id == currentID } ?? 0
                let fallback = min(max(0, previousIndex), newPhotos.count - 1)
                self.currentID = newPhotos[fallback].id
                resetTransform()
            }
        }
        .task(id: currentID) {
            // TS Lightbox.tsx:143-146 —— 相邻照片 preview 预加载（best-effort）。
            await Self.prefetchAdjacent(photos: photos, currentID: currentID)
        }
    }

    // MARK: 主体（照片 + 顶部文件名行 + 底部元数据行）

    private func photoViewer(_ photo: GalleryPhotoData) -> some View {
        VStack(spacing: 12) {
            headerRow(photo)
            zoomableImage(photo)
            footerRow(photo)
        }
    }

    private func headerRow(_ photo: GalleryPhotoData) -> some View {
        HStack(spacing: 12) {
            Text(photo.filename)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
            Spacer(minLength: 0)
            Text("\(currentIndex + 1) / \(photos.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.75))
            Button(GatherLocalization.l("关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .help(GatherLocalization.l("关闭"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func zoomableImage(_ photo: GalleryPhotoData) -> some View {
        GeometryReader { geometry in
            ZStack {
                // allowsHitTesting(false)：scaleEffect 放大后命中区域外溢
                //（.clipped() 不裁剪命中），会吞掉灯箱顶部/底部按钮的点击；
                // 手势统一挂在容器上。
                // 底层：整图基准档位图（构图 + 手势 + 立即显示）。
                PhotoThumbnailView(
                    path: photo.filepath,
                    size: PhotoDetailTier.baseDimension,
                    preview: true,
                    contentMode: .fit
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .allowsHitTesting(false)
                // 可见区域细节层（同审片台）：只解当前看得到的那一块。
                if let tile = detailTileState {
                    PhotoDetailTileView(
                        path: photo.filepath,
                        normalizedRect: tile.normalizedRect,
                        targetPixel: PhotoViewerGeometry.tilePixelSize(
                            viewRect: tile.viewRect,
                            budgetDimension: PhotoDetailTier.maxDimension
                        )
                    )
                    .frame(width: max(0, tile.viewRect.width), height: max(0, tile.viewRect.height))
                    .position(x: tile.viewRect.midX, y: tile.viewRect.midY)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                // macOS 14：MagnificationGesture 已废弃，改 MagnifyGesture。
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(5, max(0.5, gestureScale * value.magnification))
                    }
                    .onEnded { _ in
                        gestureScale = scale
                        if scale <= 1 {
                            offset = .zero
                            dragStartOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // TS: 缩放 ≤1 不可拖拽，>1 可平移。
                        guard scale > 1 else { return }
                        offset = PanOffset.apply(start: dragStartOffset, translation: value.translation)
                    }
                    .onEnded { _ in
                        dragStartOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                // 双击复位（原生侧增强，对齐「重置」按钮语义）。
                resetTransform()
            }
            // TS: wheel 事件 ±0.2/档、钳制 [0.5, 5]（passive:false +
            // preventDefault 语义：消费事件防止触发滚动）。
            .overlay {
                ScrollWheelCatcher { deltaY in
                    guard deltaY != 0 else { return }
                    let next = min(5, max(0.5, scale + (deltaY > 0 ? -0.2 : 0.2)))
                    scale = next
                    gestureScale = next
                    if next <= 1 { offset = .zero }
                }
            }
            // 可见区域细节层：缩放或平移停止 150ms 后重算可见矩形（只重解那一块）。
            .onChange(of: scale) { _, _ in scheduleDetailTileUpdate(photo: photo, containerSize: geometry.size) }
            .onChange(of: offset) { _, _ in scheduleDetailTileUpdate(photo: photo, containerSize: geometry.size) }
            .onAppear { scheduleDetailTileUpdate(photo: photo, containerSize: geometry.size) }
        }
        .background(Color.black.opacity(0.9))
        .clipped()
    }

    private func footerRow(_ photo: GalleryPhotoData) -> some View {
        HStack(spacing: 20) {
            metadataItem(GatherLocalization.l("尺寸"), "\(photo.width) × \(photo.height)")
            metadataItem(
                GatherLocalization.l("状态"),
                photo.status == "missing" ? GatherLocalization.l("离线") : GatherLocalization.l("在线")
            )
            metadataItem(GatherLocalization.l("人脸"), "\(photo.faceCount)")
            if photo.variantCount > 1 {
                metadataItem(GatherLocalization.l("变体"), "\(photo.variantCount)")
            }
            Spacer(minLength: 0)
            Button {
                zoom(by: -0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help(GatherLocalization.l("缩小"))
            .accessibilityLabel(GatherLocalization.l("缩小"))
            Text("\(Int(scale * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.8))
                .frame(width: 52)
            Button {
                zoom(by: 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help(GatherLocalization.l("放大"))
            .accessibilityLabel(GatherLocalization.l("放大"))
            Button(GatherLocalization.l("重置")) {
                resetTransform()
            }
            .help(GatherLocalization.l("重置"))
            Button {
                goPrevious()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help(GatherLocalization.l("上一张"))
            .accessibilityLabel(GatherLocalization.l("上一张"))
            .disabled(currentIndex == 0)
            Button {
                goNext()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(GatherLocalization.l("下一张"))
            .accessibilityLabel(GatherLocalization.l("下一张"))
            .disabled(currentIndex == photos.count - 1)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    /// TS if (!photo) return null —— 照片已随刷新消失：占位 + 关闭。
    /// 查看器是恒深色表面，这里保留查看器文字色（系统 ContentUnavailableView
    /// 在浅色外观下会给出深色文字，压在深色查看器上不可读）。
    private var unavailableView: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .imageScale(.large)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.75))
                .accessibilityHidden(true)
            Text(GatherLocalization.l("照片已不可用"))
                .font(.headline)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
            Button(GatherLocalization.l("关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }

    // MARK: 翻页（TS goNext/goPrev —— 切换照片重置缩放/位移）

    private func goNext() {
        guard currentIndex < photos.count - 1, let next = photos[safe: currentIndex + 1] else { return }
        currentID = next.id
        resetTransform()
    }

    private func goPrevious() {
        guard currentIndex > 0, let previous = photos[safe: currentIndex - 1] else { return }
        currentID = previous.id
        resetTransform()
    }

    private func zoom(by delta: Double) {
        let next = min(5, max(0.5, scale + delta))
        scale = next
        gestureScale = next
        if next <= 1 { offset = .zero }
    }

    // MARK: 相邻预加载

    /// TS Lightbox.tsx:143-146 —— 预取 index±1、±2 的 preview（best-effort，
    /// 失败静默）；解码结果落入 PhotoThumbnailCache，翻页即命中。
    private static func prefetchAdjacent(photos: [GalleryPhotoData], currentID: String?) async {
        guard let currentID, let index = photos.firstIndex(where: { $0.id == currentID }) else { return }
        // 只预取紧邻的两张（-2/+2 的收益远低于它占用的解码名额）。
        let paths = [-1, 1].compactMap { offset -> String? in
            let target = index + offset
            guard photos.indices.contains(target) else { return nil }
            return photos[target].filepath
        }
        // A-1（性能审计）：旧实现解 2048 且**从不写缓存**（decode 只返回 Data），
        // 而灯箱显示用 baseDimension(2560) —— 缓存键不匹配 ⇒ 100% 无效解码，
        // 还占掉 4 个解码名额。现在：只预取相邻 2 张、键与显示完全一致、命中即跳过、
        // 串行且每张前检查取消。
        for path in paths {
            guard !Task.isCancelled else { return }
            let key = PhotoThumbnailCache.key(path: path, size: PhotoDetailTier.baseDimension, preview: true)
            if PhotoThumbnailCache.image(for: key) != nil { continue }
            // 走统一异步入口：受解码闸门（并发 4）、同键去重与磁盘缓存管；
            // 裸 Task.detached 会绕开闸门导致并发无界（第一轮自查发现的副作用）。
            guard let data = try? await PhotoThumbnailDecoder.decodeAsync(
                path: path,
                size: PhotoDetailTier.baseDimension,
                preview: true
            ) else { continue }
            guard !Task.isCancelled, let image = NSImage(data: data) else { continue }
            PhotoThumbnailCache.setImage(image, for: key)
        }
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
        dragStartOffset = .zero
        detailTileTask?.cancel()
        detailTileState = nil
    }

    /// 可见区域细节层：缩放/平移停止 150ms 后重算可见矩形（只重解那一块）。
    private func scheduleDetailTileUpdate(photo: GalleryPhotoData, containerSize: CGSize) {
        let imageSize = CGSize(width: Double(photo.width), height: Double(photo.height))
        let zoom = Double(scale)
        let pan = offset
        detailTileTask?.cancel()
        detailTileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            detailTileState = PhotoViewerGeometry.detailTile(
                imageSize: imageSize,
                viewSize: containerSize,
                zoom: zoom,
                panOffset: pan,
                backingPixelBudget: PhotoDetailTier.baseDimension
            )
        }
    }

    /// 适配显示尺寸的最长边（pt）：与 contentMode .fit 的几何一致（灯箱档位用）。
    static func fitPoints(imageSize: CGSize, containerSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else { return 0 }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return Double(max(imageSize.width, imageSize.height) * scale)
    }

    private func metadataItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.7))
            Text(value)
                .font(.callout)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 滚轮缩放捕获器（SwiftUI 无 onScrollWheel，NSView 包装接收 wheel 事件）

/// TS Lightbox.tsx wheel 监听（passive:false + preventDefault）的等价实现：
/// 消费滚轮事件并回调缩放步进，阻止事件传播。鼠标事件转发给 nextResponder
/// （宿主 NSHostingView），保证下方 SwiftUI 手势（拖拽平移/捏合/双击）不受拦截。
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onWheel: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelCatcherNSView {
        let view = WheelCatcherNSView()
        view.onWheel = onWheel
        return view
    }

    func updateNSView(_ nsView: WheelCatcherNSView, context: Context) {
        nsView.onWheel = onWheel
    }

    final class WheelCatcherNSView: NSView {
        var onWheel: ((CGFloat) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 始终命中本视图以捕获滚动事件；鼠标事件经转发保持下方手势可用。
            self
        }

        override func scrollWheel(with event: NSEvent) {
            onWheel?(event.deltaY)
        }

        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
        override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
        override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
        override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
        override func rightMouseDragged(with event: NSEvent) { nextResponder?.rightMouseDragged(with: event) }
        override func rightMouseUp(with event: NSEvent) { nextResponder?.rightMouseUp(with: event) }
        override func otherMouseDown(with event: NSEvent) { nextResponder?.otherMouseDown(with: event) }
        override func otherMouseDragged(with event: NSEvent) { nextResponder?.otherMouseDragged(with: event) }
        override func otherMouseUp(with event: NSEvent) { nextResponder?.otherMouseUp(with: event) }
        override func magnify(with event: NSEvent) { nextResponder?.magnify(with: event) }
        override func rotate(with event: NSEvent) { nextResponder?.rotate(with: event) }
    }
}
