// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView.swift
// Phase 3.2 Library（全局图库）：SwiftUI 页面（宿主内经 GatherProtocol 端口访问）。
// TS 源: desktop/src/renderer/pages/Library/index.tsx（筛选面板/工具栏/卡片网格/分页）
//
// 原生化改造（仅视图层）：
// - 删除内容区自绘头部（eyebrow + 26pt 大标题 + 副标题）：标题/副标题交给窗口 chrome，
//   工作区筛选与页面级动作进系统工具栏；
// - 文件名搜索框（.roundedBorder TextField）→ .searchable(placement: .toolbar)；
// - 「更多筛选」手搓展开 → 系统 DisclosureGroup；筛选字段走 LabeledContent 标签列；
// - 自绘卡片底 / 描边 / 悬停态 → .gatherCard() 分组容器；
// - 空态 / 无结果 / 加载失败 → ContentUnavailableView（macOS 14+）+ 重试/清除筛选出口；
// - 排版走系统文本样式（计数、文件名、状态不再是 10pt footnote），
//   颜色一律语义色（去掉自造 hex 星级色与红底白字离线角标）。
//
// Cut 4 / 4c-2j：940 行 -> 6 文件（行为不变）。本文件只保留页面壳：8 个 @State
// （高级筛选展开、相册名、4 个破坏性确认目标、重新关联、jobProgress 去抖 Task）
// + @SceneStorage（检查器可见性）+ 嵌套 PendingRelink + 页面装配/接线 + #Preview。
// 工具栏在 +Toolbar，筛选面板在 +Filters，右侧支持能力检查器在 +Support，
// 状态行/内容/网格/分页在 +Content，照片卡在 LibraryCardView。接线顺序
// （searchable -> onChange search -> onChange sessionFilter -> toolbar -> inspector
// -> task -> onReceive domainChanged/jobTerminal/jobProgress）逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

package struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    /// Cut 4 / 4a-2c：删除 isActive——页面按目的地条件构建，存在即可见；
    /// 隐藏页不再存在，事件刷新无需二次门控。
    let onOpenSession: (String) -> Void
    /// 打开具体照片（N07）：点击卡片必须打开**那张照片**，而不是只打开它所属
    /// 工作区的控制中心——跨工作区搜索命中一张照片后，目标本身才是用户要的。
    let onOpenPhoto: (String, String) -> Void

    package init(
        viewModel: LibraryViewModel,
        onOpenSession: @escaping (String) -> Void = { _ in },
        onOpenPhoto: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.viewModel = viewModel
        self.onOpenSession = onOpenSession
        self.onOpenPhoto = onOpenPhoto
    }

    /// Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView）。
    @Environment(\.languageStore) private var languageStore
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 需要刷新本页支持数据（相册/关联候选/孤立 XMP/离线卷）的域。
    private static let refreshDomains: Set<GatherChangeDomain> = [
        .duplicates, .metadata, .culling, .library,
    ]

    @State var showAdvancedFilters = false
    /// 右侧「资料库」检查器（相册 / 资产关联 / 孤立 XMP / 离线卷）。
    ///
    /// 这四块是**目录级管理功能**，和「浏览照片」不是同一件事。参考 Bridge 的
    /// 右栏（Collections / Metadata）与 Capture One 的 Library 工具页：
    /// 内容永远留在中央，管理选项进侧面板。旧版把它们做成四张横向卡片压在
    /// 网格上方，既占掉三分之一屏高，又和照片浏览混在一条视线上。
    ///
    /// macOS 14 起 `.inspector` 是系统 API，工具栏的显示/隐藏按钮由系统提供，
    /// 宽度由系统记忆；可见性用 @SceneStorage 按页记忆——跨导航重建 / 新窗口
    /// 都保持（参考 darktable 各视图独立存储面板可见性）。
    @SceneStorage("library.inspectorVisible") private var showInspector = true
    @State var albumName = ""
    /// 破坏性动作的待确认项（非空即弹确认；取消不发命令）。
    @State var pendingDeleteAlbum: SmartAlbumData?
    @State var pendingAcceptCandidate: AssetLinkCandidateData?
    @State var pendingRejectCandidate: AssetLinkCandidateData?
    @State var pendingRelink: PendingRelink?
    /// 「恢复原片」确认的目标（不可逆覆盖操作）。
    @State var pendingRestoreOrphan: MetadataOrphan?

    /// 待确认的重新关联：oldRoot → newRoot 由用户选目录后填充。
    struct PendingRelink: Equatable {
        let oldRoot: String
        let newRoot: String
    }
    /// jobProgress 去抖 Task 保留在 View（Cut 4 / 4c-2j 显式决策）：它只服务
    /// 本页这一处事件接线，生命周期与页面一致；VM 的 scheduleEventRefresh 已有
    /// 500ms 合并窗口，搬进 VM 会叠成两层去抖，且 viewModel 替换/页面销毁时的
    /// 取消语义需要重建。保持 @State 所有权 = 现有隔离与取消语义不变。
    @State private var jobProgressDebounceTask: Task<Void, Never>?

    let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    /// 空库且没有筛选条件时，不显示筛选 / 状态条，让空态成为首屏唯一焦点。
    private var showsBrowseChrome: Bool {
        !(viewModel.phase == .loaded
          && viewModel.photos.isEmpty
          && viewModel.activeFilterCount == 0)
    }

    /// 窗口副标题：加载完成后显示库存摘要，避免固定营销句占满标题栏。
    private var browseSubtitle: String {
        guard viewModel.phase == .loaded else {
            return l10n("以同一逻辑照片为单位，跨工作区浏览、筛选和管理。")
        }
        return l10n.format(
            "%lld 张逻辑照片 · %lld 个工作区",
            viewModel.total,
            viewModel.sessions.count
        )
    }

    package var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.actionError {
                NativeBanner(text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                    .padding(.top, 12)
            }
            // 空库且无筛选时，筛选条 / 状态条不占首屏：只留一个整页空态。
            if showsBrowseChrome {
                filterBar
                Divider()
                statusBar
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GatherTheme.windowBackground)
        // 页面 chrome：标题 / 副标题交给系统窗口，内容区不再自绘 eyebrow + 大标题。
        .navigationTitle(l10n("全局图库"))
        .navigationSubtitle(browseSubtitle)
        // 文件名搜索：系统搜索框（取代 .roundedBorder TextField + 手搓宽度）。
        .searchable(
            text: $viewModel.filter.search,
            placement: .toolbar,
            prompt: Text(l10n("搜索文件名"))
        )
        .onChange(of: viewModel.filter.search) { _, _ in viewModel.onFilterChanged() }
        .onChange(of: viewModel.sessionFilter) { _, _ in viewModel.onSessionFilterChanged() }
        .toolbar { toolbarItems }
        // 右侧检查器：目录级管理功能。内容区回到「筛选 + 网格」两件事。
        .inspector(isPresented: $showInspector) {
            libraryInspector
                // 与 Culling/Gallery 对齐（A3）：理想列宽会计入承载视图最小宽度，
                // 320 会在最小窗口下挤压主内容区。
                .inspectorColumnWidth(min: 220, ideal: 260, max: 400)
        }
        .task {
            if viewModel.phase == .loading {
                await viewModel.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherApplicationChange,
                  Self.refreshDomains.contains(change.domain),
                  change.origin != LibraryViewModel.changeOrigin else { return }
            // 只刷新本次变更可能影响的支持子域 + 当前页（不重置筛选/页码）。
            viewModel.scheduleEventRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { _ in
            // 任意终态事件都重载支持数据/照片列表（索引/分析结束即反映）。
            viewModel.scheduleEventRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.type == .metadataScan else { return }
            let viewModel = viewModel
            jobProgressDebounceTask?.cancel()
            jobProgressDebounceTask = Task { [weak viewModel] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                viewModel?.scheduleEventRefresh()
            }
        }
    }
}

#if DEBUG
#Preview("Library · 全局图库") {
    PreviewFactory.libraryPage()
}
#endif
