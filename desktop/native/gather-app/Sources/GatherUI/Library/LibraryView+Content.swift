// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Content.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出状态行与内容区（原 655-786 行）。纯搬移：
// 加载/失败/空态/网格/分页与各出口逐字未动。
import SwiftUI
import GatherProtocol

extension LibraryView {

    // MARK: 状态行（TS toolbar：loading/totalCount + range）

    var statusBar: some View {
        HStack(spacing: 12) {
            if viewModel.phase == .loading {
                Text(l10n("加载中…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(l10n.format("共 %lld 张逻辑照片", viewModel.total))
                    .font(.callout)
                Text(l10n.resolve(viewModel.rangeText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if viewModel.isFetching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
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
            sessionId: viewModel.sessionFilter.isEmpty ? nil : viewModel.sessionFilter
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
            .gatherPrimaryActionButton()
        }
    }

    /// 无结果态：系统 ContentUnavailableView + 「清除筛选」出口。
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
                .gatherPrimaryActionButton()
            } else {
                Button(l10n("清除筛选")) {
                    viewModel.clearFilters()
                }
            }
        }
    }

    private var photoGrid: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.photos, id: \.assetId) { photo in
                        LibraryCardView(
                            photo: photo,
                            onOpen: { onOpenPhoto(photo.sessionId, photo.photoId) },
                            onOpenSession: { onOpenSession(photo.sessionId) }
                        )
                    }
                }
                .padding(24)
            }
            Divider()
            pagination
        }
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            Button(l10n("上一页")) {
                viewModel.prevPage()
            }
            .disabled(viewModel.page == 0)
            Text("\(viewModel.page + 1) / \(max(1, Int(ceil(Double(viewModel.total) / Double(LibraryViewModel.pageSize)))))")
                .font(.callout)
                .monospacedDigit()
            Button(l10n("下一页")) {
                viewModel.nextPage()
            }
            .disabled(!viewModel.hasNextPage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}
// MARK: - 策展侧栏入口（§3.8）

/// 图库内容区外壳：折叠式策展侧栏 + 原内容 / 集合 / 跨工作区重复。
///
/// 折叠态只留一条 28pt 的窄轨（一个图标按钮）：默认不改变图库布局，
/// 展开后才让出 216pt 给侧栏。选中集合或"跨工作区重复"后内容区整体切换，
/// 关闭（xmark）回到图库。
///
/// 依赖经环境注入（CurationServices），未注入时侧栏仍可展开并显示"未接线"，
/// 不会静默丢功能。
struct LibraryCurationHost<Browse: View>: View {
    @Environment(\.languageStore) private var languageStore
    @Environment(\.curationServices) private var services
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private let sessionId: String?
    private let browse: Browse

    @State private var showsSidebar = false
    @State private var selection: CurationSidebarSelection?

    init(sessionId: String?, @ViewBuilder browse: () -> Browse) {
        self.sessionId = sessionId
        self.browse = browse()
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                CollectionSidebar(sessionId: sessionId, selection: $selection)
                Divider()
            } else {
                collapsedRail
                Divider()
            }
            content
        }
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
            .help(l10n("集合与跨工作区重复"))
            .accessibilityLabel(l10n("打开策展侧栏"))
            Spacer(minLength: 0)
        }
        .padding(.vertical, GatherMetrics.Space.s)
        .frame(width: 28)
        .background(GatherTheme.surfaceMuted)
    }
}
