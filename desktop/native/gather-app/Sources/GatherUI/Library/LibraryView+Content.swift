// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Content.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出状态行与内容区（原 655-786 行）。纯搬移：
// 加载/失败/空态/网格/分页与各出口逐字未动。
import SwiftUI
import GatherProtocol

extension LibraryView {

    // MARK: 状态行（TS toolbar：loading/totalCount + range）

    var statusBar: some View {
        HStack(spacing: GatherMetrics.Space.m) {
            if viewModel.phase == .loading {
                Text(l10n("加载中…"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                Text(l10n.format("共 %lld 张逻辑照片", viewModel.total))
                    .font(GatherFont.secondary)
                Text(l10n.resolve(viewModel.rangeText))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            // Wave5 batch4：目录筛选生效时给面包屑 + 清除出口（左栏折叠时也能看见/清除）。
            if let selected = viewModel.selectedDirectoryPath,
               let breadcrumb = DirectoryFilterRule.breadcrumb(
                   root: folderTreeRootPath, filterPrefix: viewModel.filter.directory) {
                HStack(spacing: GatherMetrics.Space.xs) {
                    Image(systemName: "folder")
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.accent)
                    Text(breadcrumb)
                        .font(GatherFont.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(selected)
                    Button { viewModel.clearDirectoryFilter() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(GatherFont.labelRegular)
                            .foregroundStyle(GatherTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(l10n("清除目录筛选"))
                    .accessibilityLabel(l10n("清除目录筛选"))
                }
            }
            Spacer(minLength: 0)
            if viewModel.isFetching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, GatherMetrics.Space.xl)
        .padding(.vertical, 10)
    }

    // MARK: 内容（TS 卡片网格 + 分页）

    /// 内容区入口：左侧策略栏（集合 / 跨工作区重复）+ 原图库内容。
    ///
    /// P1 下一波 §3.8：只做**最小接入**——侧栏折叠时内容区与旧版逐像素一致，
    /// 展开后才出现集合列表；集合/重复内容替换内容区，页面的筛选条与状态行不动。
    /// 侧栏状态（是否展开、选中项）全部在被包裹的自有视图里，不污染 LibraryView
    /// 的既有 8 个 @State。
    @ViewBuilder
    var content: some View {
        // 集合是会话级容器：把图库当前的工作区筛选当作"所属工作区"，
        // 未筛选（全部工作区）时侧栏提示"先选一个工作区"。
        LibraryCurationHost(
            sessionId: viewModel.sessionFilter.isEmpty ? nil : viewModel.sessionFilter,
            folderTreeRootPath: folderTreeRootPath,
            folderTreeSessionName: folderTreeSessionName,
            folderTreeSelectedPrefix: viewModel.filter.directory,
            onSelectDirectory: { viewModel.toggleDirectoryFilter($0) },
            onClearDirectory: { viewModel.clearDirectoryFilter() },
            onCreateWorkspace: onCreateWorkspace,
            onIngestFolder: { requestIngestFolder($0) }
        ) {
            browseContent
        }
    }

    /// 原内容区（加载/失败/空态/网格/分页），行为不变。
    @ViewBuilder
    private var browseContent: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(l10n("加载照片中…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            loadFailureState(error)
        case .loaded:
            if viewModel.photos.isEmpty {
                emptyState
            } else {
                photoGrid
            }
        }
    }

    /// 失败出口：系统空态 + 重试（不再只渲染一行红字）。
    /// 4a-3b-2a：错误以 `CommandError` 传入，文案在渲染期按当前语言解析。
    private func loadFailureState(_ error: CommandError) -> some View {
        GatherEmptyState(
            icon: "exclamationmark.triangle",
            title: l10n("全局图库"),
            message: l10n.format("加载照片失败：%@", CommandErrorText.resolve(error, with: l10n))
        ) {
            Button(l10n("重试")) {
                Task { await viewModel.load() }
            }
            .gatherButton(.primary)
        }
    }

    /// 无结果态：GatherEmptyState + 「清除筛选」出口。
    private var emptyState: some View {
        // E 报告：空库（没有任何筛选条件）时旧实现只给一个**被禁用**的
        //「清除筛选」——用户面对死路。这里分两种语义：
        //   · 有筛选 → 清除筛选（可用）；
        //   · 无筛选 → 图库确实为空，给「导入文件夹」出口。
        GatherEmptyState(
            icon: viewModel.activeFilterCount == 0
                ? "photo.on.rectangle.angled"
                : "magnifyingglass",
            title: viewModel.activeFilterCount == 0
                ? l10n("图库还没有照片")
                : l10n("没有符合条件的照片"),
            message: viewModel.activeFilterCount == 0
                ? l10n("导入一个文件夹后，这里会汇总所有工作区的照片。")
                : l10n("调整或清除筛选条件以查看全部照片")
        ) {
            if viewModel.activeFilterCount == 0 {
                Button(l10n("导入文件夹")) {
                    NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
                }
                .gatherButton(.primary)
            } else {
                Button(l10n("清除筛选")) {
                    viewModel.clearFilters()
                }
                .gatherButton(.secondary)
            }
        }
    }

    private var photoGrid: some View {
        VStack(spacing: .zero) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: GatherMetrics.Space.m) {
                    ForEach(viewModel.photos, id: \.assetId) { photo in
                        LibraryCardView(
                            photo: photo,
                            onOpen: { onOpenPhoto(photo.sessionId, photo.photoId) },
                            onOpenSession: { onOpenSession(photo.sessionId) }
                        )
                    }
                }
                .padding(GatherMetrics.Space.xl)
            }
            Divider()
            pagination
        }
    }

    private var pagination: some View {
        HStack(spacing: GatherMetrics.Space.m) {
            Button(l10n("上一页")) {
                viewModel.prevPage()
            }
            .gatherButton(.secondary, size: .small)
            .disabled(viewModel.page == 0)
            Text("\(viewModel.page + 1) / \(max(1, Int(ceil(Double(viewModel.total) / Double(LibraryViewModel.pageSize)))))")
                .font(GatherFont.secondary)
                .monospacedDigit()
            Button(l10n("下一页")) {
                viewModel.nextPage()
            }
            .gatherButton(.secondary, size: .small)
            .disabled(!viewModel.hasNextPage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GatherMetrics.Space.xl)
        .padding(.vertical, GatherMetrics.Space.s)
    }
}
// MARK: - 左侧浏览栏（文件夹 + 策展；Wave5 batch4 / F1）

/// 左侧浏览栏的两个页签。
enum LibrarySidebarTab: Hashable {
    case folders
    case collections
}

/// 图库内容区外壳：左侧浏览栏（物理文件夹树 / 集合）+ 原内容 / 集合 / 跨工作区重复。
///
/// Wave5 batch4（task-18 / F1）：默认展开左栏（否则物理文件夹树只存在于代码里，
/// 用户仍需先猜入口）。左栏顶部两个页签：
/// - 文件夹：FolderTreePanel（根 = 当前工作区 sourcePath，点击目录 = directory 筛选）；
/// - 集合：原 CollectionSidebar（会话级手动集合 + 跨工作区重复）。
/// 折叠态只留一条 28pt 窄轨（一个图标按钮），与旧行为一致。
///
/// 依赖经环境注入（CurationServices），未注入时集合页签仍可展开并显示"未接线"，
/// 不会静默丢功能。
struct LibraryCurationHost<Browse: View>: View {
    @Environment(\.languageStore) private var languageStore
    @Environment(\.curationServices) private var services
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private let sessionId: String?
    private let folderTreeRootPath: String?
    private let folderTreeSessionName: String?
    private let folderTreeSelectedPrefix: String
    private let onSelectDirectory: (String) -> Void
    private let onClearDirectory: () -> Void
    private let onCreateWorkspace: @MainActor (String) -> Void
    private let onIngestFolder: @MainActor (String) -> Void
    private let browse: Browse

    @State private var showsSidebar = true
    @State private var sidebarTab: LibrarySidebarTab = .folders
    @State private var selection: CurationSidebarSelection?

    init(
        sessionId: String?,
        folderTreeRootPath: String? = nil,
        folderTreeSessionName: String? = nil,
        folderTreeSelectedPrefix: String = "",
        onSelectDirectory: @escaping (String) -> Void = { _ in },
        onClearDirectory: @escaping () -> Void = {},
        onCreateWorkspace: @escaping @MainActor (String) -> Void = { _ in },
        onIngestFolder: @escaping @MainActor (String) -> Void = { _ in },
        @ViewBuilder browse: () -> Browse
    ) {
        self.sessionId = sessionId
        self.folderTreeRootPath = folderTreeRootPath
        self.folderTreeSessionName = folderTreeSessionName
        self.folderTreeSelectedPrefix = folderTreeSelectedPrefix
        self.onSelectDirectory = onSelectDirectory
        self.onClearDirectory = onClearDirectory
        self.onCreateWorkspace = onCreateWorkspace
        self.onIngestFolder = onIngestFolder
        self.browse = browse()
    }

    var body: some View {
        HStack(spacing: .zero) {
            if showsSidebar {
                sidebar
                Divider()
            } else {
                collapsedRail
                Divider()
            }
            content
        }
        // 从集合切回文件夹页签 = 结束集合浏览，回到图库网格（否则页签与内容不一致）。
        .onChange(of: sidebarTab) { _, tab in
            if tab == .folders { selection = nil }
        }
    }

    private var sidebar: some View {
        VStack(spacing: .zero) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Picker("", selection: $sidebarTab) {
                    Text(l10n("文件夹")).tag(LibrarySidebarTab.folders)
                    Text(l10n("集合")).tag(LibrarySidebarTab.collections)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button { showsSidebar = false } label: {
                    Image(systemName: "sidebar.left")
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(l10n("隐藏文件夹与集合侧栏"))
                .accessibilityLabel(l10n("隐藏文件夹与集合侧栏"))
            }
            .padding(GatherMetrics.Space.s)
            Divider()
            switch sidebarTab {
            case .folders:
                FolderTreePanel(
                    rootPath: folderTreeRootPath,
                    rootTitle: folderTreeSessionName,
                    selectedDirectoryPrefix: folderTreeSelectedPrefix,
                    onSelectDirectory: { path in
                        // 目录导航是「浏览图库」的动作：结束当前集合视图再应用筛选。
                        selection = nil
                        onSelectDirectory(path)
                    },
                    onClearDirectory: onClearDirectory,
                    onCreateWorkspace: { path in
                        // 先结束集合浏览再交给外壳（与目录筛选同一入口语义）。
                        selection = nil
                        onCreateWorkspace(path)
                    },
                    onIngestFolder: onIngestFolder
                )
            case .collections:
                CollectionSidebar(sessionId: sessionId, selection: $selection)
            }
        }
        .frame(minWidth: 208, idealWidth: 228, maxWidth: 300)
        .background(GatherTheme.surfaceMuted)
    }

    @ViewBuilder
    private var content: some View {
        if let selection {
            switch selection {
            case .collection(let summary):
                CollectionView(collection: summary) { self.selection = nil }
            case .crossWorkspaceDuplicates:
                CrossWorkspaceDuplicatesView { self.selection = nil }
            }
        } else {
            browse
        }
    }

    /// 折叠轨：只放侧栏开关，宽度 28pt（不抢内容区）。
    private var collapsedRail: some View {
        VStack(spacing: GatherMetrics.Space.xs) {
            Button {
                showsSidebar = true
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help(l10n("文件夹与集合"))
            .accessibilityLabel(l10n("打开文件夹与集合侧栏"))
            Spacer(minLength: 0)
        }
        .padding(.vertical, GatherMetrics.Space.s)
        .frame(width: 28)
        .background(GatherTheme.surfaceMuted)
    }
}
