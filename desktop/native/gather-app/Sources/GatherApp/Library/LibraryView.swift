// desktop/native/gather-app/Sources/GatherApp/Library/LibraryView.swift
// Phase 3.2 Library（全局图库）：SwiftUI 页面（宿主内直连 GatherCore）。
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
import SwiftUI
import AppKit
import GatherCore

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    /// 页面是否可见（RootView 传 navigation.isLibrary）。隐藏页不发命令、
    /// 不响应领域事件刷新（防抖任务与弹窗按钮由修饰符显式启用）。
    var isActive: Bool = true
    let onOpenSession: (String) -> Void
    /// 打开具体照片（N07）：点击卡片必须打开**那张照片**，而不是只打开它所属
    /// 工作区的控制中心——跨工作区搜索命中一张照片后，目标本身才是用户要的。
    let onOpenPhoto: (String, String) -> Void

    init(
        viewModel: LibraryViewModel,
        isActive: Bool = true,
        onOpenSession: @escaping (String) -> Void = { _ in },
        onOpenPhoto: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.viewModel = viewModel
        self.isActive = isActive
        self.onOpenSession = onOpenSession
        self.onOpenPhoto = onOpenPhoto
    }

    /// 需要刷新本页支持数据（相册/关联候选/孤立 XMP/离线卷）的域。
    private static let refreshDomains: Set<GatherDomain> = [
        .duplicates, .metadata, .culling, .library,
    ]

    @State private var showAdvancedFilters = false
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
    @State private var albumName = ""
    /// 破坏性动作的待确认项（非空即弹确认；取消不发命令）。
    @State private var pendingDeleteAlbum: SmartAlbumData?
    @State private var pendingAcceptCandidate: AssetLinkCandidateData?
    @State private var pendingRejectCandidate: AssetLinkCandidateData?
    @State private var pendingRelink: PendingRelink?
    /// 「恢复原片」确认的目标（不可逆覆盖操作）。
    @State private var pendingRestoreOrphan: MetadataOrphan?

    /// 待确认的重新关联：oldRoot → newRoot 由用户选目录后填充。
    struct PendingRelink: Equatable {
        let oldRoot: String
        let newRoot: String
    }
    @State private var jobProgressDebounceTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.actionError {
                NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            filterBar
            Divider()
            statusBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GatherTheme.windowBackground)
        .disabled(!isActive)
        // 页面 chrome：标题 / 副标题交给系统窗口，内容区不再自绘 eyebrow + 大标题。
        .navigationTitle(GatherLocalization.l("全局图库"))
        .navigationSubtitle(GatherLocalization.l("以同一逻辑照片为单位，跨工作区浏览、筛选和管理。"))
        // 文件名搜索：系统搜索框（取代 .roundedBorder TextField + 手搓宽度）。
        .searchable(
            text: $viewModel.filter.search,
            placement: .toolbar,
            prompt: Text(GatherLocalization.l("搜索文件名"))
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
            guard let change = notification.object as? GatherDomainChange,
                  Self.refreshDomains.contains(change.domain),
                  change.origin != LibraryViewModel.changeOrigin,
                  isActive else { return }
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

    // MARK: 工具栏（工作区筛选 / 清除筛选 / 刷新）

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // N09 同类（E 报告）：Picker 的标签与「全部」选项同文案会在同一行
            // 出现两次「全部工作区」；改为固定短标签 + 精简的选项文案。
            HStack(spacing: 6) {
                Text(GatherLocalization.l("工作区"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker(GatherLocalization.l("工作区"), selection: $viewModel.sessionFilter) {
                    Text(GatherLocalization.l("全部")).tag("")
                    ForEach(viewModel.sessions, id: \.id) { session in
                        Text("\(session.name)（\(session.photoCount)）").tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(GatherLocalization.l("工作区"))
            }
            .help(GatherLocalization.l("按工作区筛选"))

            Button {
                viewModel.clearFilters()
            } label: {
                Label(GatherLocalization.l("清除筛选"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .help(GatherLocalization.l("清除筛选"))
            .disabled(viewModel.activeFilterCount == 0)

            Button {
                Task { await viewModel.load() }
            } label: {
                Label(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise")
            }
            .help(GatherLocalization.l("刷新"))
            .disabled(viewModel.phase == .loading)
        }
    }

    // MARK: 筛选（TS filterPanel：主筛选 + 更多筛选 + 操作）

    /// 主筛选三件套（N09）：字段名与「全部」值分开显示，窄窗口自动换成两行。
    ///
    /// 旧实现用 Picker 的标签承载字段名、又用同文案的菜单项承载「全部」，
    /// 于是同一行出现两次「全部星级」，且选中值被压成「全…」。
    @ViewBuilder
    private var primaryFilterControls: some View {
        filterSelect(
            GatherLocalization.l("星级"),
            allLabel: GatherLocalization.l("全部"),
            selection: $viewModel.filter.rating,
            options: [1, 2, 3, 4, 5].map { (String(format: GatherLocalization.l("至少 %lld 星"), $0), "\($0)") }
        )
        filterSelect(
            GatherLocalization.l("颜色"),
            allLabel: GatherLocalization.l("全部"),
            selection: $viewModel.filter.label,
            options: LibraryColorOption.all.map { ($0.label, $0.value) }
        )
        filterSelect(
            GatherLocalization.l("在线状态"),
            allLabel: GatherLocalization.l("全部"),
            selection: $viewModel.filter.status,
            options: [(GatherLocalization.l("在线"), "online"), (GatherLocalization.l("离线"), "missing")]
        )
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 宽窗口一行三列；放不下时整组换成竖排（ViewThatFits 按理想宽度判断），
            // 字段名与当前值在两种排布下都完整可读。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    primaryFilterControls
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    primaryFilterControls
                }
            }
            // 手搓「更多筛选」展开按钮 → 系统 DisclosureGroup（chevron / 键盘 / 动画由系统负责）。
            DisclosureGroup(isExpanded: $showAdvancedFilters) {
                advancedFilters
            } label: {
                Text(moreFiltersLabel)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var advancedFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            advancedField(GatherLocalization.l("关键词"), text: $viewModel.filter.keyword)
            advancedField(GatherLocalization.l("人物"), text: $viewModel.filter.person)
            advancedField(GatherLocalization.l("目录路径前缀"), text: $viewModel.filter.directory)
            HStack(spacing: 12) {
                filterSelect(
                    GatherLocalization.l("存储卷"),
                    allLabel: GatherLocalization.l("全部"),
                    selection: $viewModel.filter.volume,
                    options: viewModel.assetVolumes.map {
                        ($0.roots.first ?? $0.volumeId, $0.volumeId)
                    }
                )
                filterSelect(
                    GatherLocalization.l("重复状态"),
                    allLabel: GatherLocalization.l("全部"),
                    selection: $viewModel.filter.duplicates,
                    options: [(GatherLocalization.l("有重复候选"), "yes"), (GatherLocalization.l("无重复候选"), "no")]
                )
                filterSelect(
                    GatherLocalization.l("导入时间"),
                    allLabel: GatherLocalization.l("全部"),
                    selection: $viewModel.filter.recentDays,
                    options: [(GatherLocalization.l("最近 24 小时"), "1"), (GatherLocalization.l("最近 7 天"), "7"), (GatherLocalization.l("最近 30 天"), "30")]
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }

    /// 表单行：LabeledContent 负责标签列，TextField 用系统字段样式（不再自定宽度/描边）。
    private func advancedField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .labelsHidden()
                // 自适应宽度（F01）：固定 220 在最小窗口 + 检查器打开时会让
                // 内容区索要比可用宽度更大的最小宽度，触发 AppKit 约束重排。
                .frame(minWidth: 120, maxWidth: 220)
                .onChange(of: text.wrappedValue) { _, _ in viewModel.onFilterChanged() }
        }
    }

    private var moreFiltersLabel: String {
        let count = viewModel.advancedFilterCount
        return count > 0 ? String(format: GatherLocalization.l("更多筛选（%lld）"), count) : GatherLocalization.l("更多筛选")
    }

    /// 一个筛选下拉：左侧字段名（短标签、不随值变化），右侧只显示当前值。
    /// 自适应宽度（F01）：固定 150 × 3 个下拉在最小窗口宽度下会超出可用宽度，
    /// 非滚动容器里的超宽固定子视图会把布局推入约束更新循环。
    private func filterSelect(
        _ title: String,
        allLabel: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker(title, selection: selection) {
                Text(allLabel).tag("")
                ForEach(options, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.menu)
            // 字段名由左侧 Text 承载，Picker 不再重复渲染标签（N09 的重复文案）。
            .labelsHidden()
            .frame(minWidth: 88, maxWidth: 150)
            .accessibilityLabel(title)
        }
        .onChange(of: selection.wrappedValue) { _, _ in viewModel.onFilterChanged() }
    }

    // MARK: 支持能力（TS Library sidebar：智能相册、RAW/JPEG 关联、孤立 XMP、离线卷）

    /// 支持能力卡片：自适应网格。
    ///
    /// 旧实现是**隐藏滚动条的固定宽度横条**（280+320+320+300 = 1244pt）：
    /// 在最小窗口（内容宽 ≈900pt）下「离线存储卷」整张卡落在屏幕外，
    /// 而 showsIndicators:false 又抹掉了唯一的提示——已实现的功能不可达。
    /// 改为自适应列数：窗口变窄时自动折行，任何宽度下四张卡都在视野内。
    private var libraryInspector: some View {
        // 用 ScrollView + 卡片，而不是 Form(.grouped)：
        // Form 装进 .inspector 会在 AppKit 的约束更新阶段抛异常
        // （崩溃栈：NSDisplayCycleObserverInvoke → objc_exception_rethrow），
        // 已实测复现。这里的四组内容是「管理面板」而不是表单行，
        // 用卡片分组本来也更贴切。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                smartAlbumsCard
                assetCandidatesCard
                metadataOrphansCard
                offlineVolumesCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .navigationTitle(GatherLocalization.l("资料库"))
    }

    private var smartAlbumsCard: some View {
        supportCard(title: GatherLocalization.l("智能相册"), systemImage: "rectangle.stack") {
            Picker(GatherLocalization.l("相册"), selection: Binding(
                get: { viewModel.selectedAlbumId ?? "" },
                set: { viewModel.selectAlbum($0.isEmpty ? nil : $0) }
            )) {
                Text(GatherLocalization.l("全部照片")).tag("")
                ForEach(viewModel.albums, id: \.id) { album in
                    Group {
                        if album.validationError == nil {
                            Text(album.name)
                        } else {
                            Label(album.name, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(GatherTheme.error)
                        }
                    }
                    .tag(album.id)
                    .help(album.validationError ?? "")
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                TextField(GatherLocalization.l("新相册名称"), text: $albumName)
                Button(GatherLocalization.l("创建")) {
                    let name = albumName
                    albumName = ""
                    Task { await viewModel.createAlbum(name: name) }
                }
                .disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSupportBusy)
            }
            if viewModel.selectedAlbumId != nil {
                HStack(spacing: 8) {
                    Button(GatherLocalization.l("用当前筛选更新")) {
                        Task { await viewModel.updateSelectedAlbum() }
                    }
                    .disabled(viewModel.isSupportBusy)
                    Button(GatherLocalization.l("删除"), role: .destructive) {
                        pendingDeleteAlbum = viewModel.albums.first {
                            $0.id == viewModel.selectedAlbumId
                        }
                    }
                    .disabled(viewModel.isSupportBusy)
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingDeleteAlbum,
            title: GatherLocalization.l("删除当前智能相册？"),
            confirmLabel: { _ in GatherLocalization.l("删除相册") },
            message: { album in
                String(
                    format: GatherLocalization.l("将删除智能相册「%@」及其筛选规则。只删除相册规则，不会删除任何照片文件。"),
                    album.name
                )
            },
            onConfirm: { album in
                // confirmed: true 只能从这个分支到达。
                Task { await viewModel.deleteAlbum(id: album.id, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var assetCandidatesCard: some View {
        supportCard(title: GatherLocalization.l("RAW/JPEG 资产关联"), systemImage: "link") {
            if viewModel.assetCandidates.isEmpty {
                Text(GatherLocalization.l("暂无待处理关联候选"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // TS Library/index.tsx:348 —— 候选直出（卡片内可滚动，无分页门控）。
                // C-6（性能审计）：旧实现在 ScrollView { VStack } 里**直出**全部候选
                // （无 LIMIT），每次重建实例化所有行。LazyVStack 是零行为变化的修法。
                LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.assetCandidates, id: \.id) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Self.basename(candidate.leftPath)) ↔ \(Self.basename(candidate.rightPath))")
                            .font(.callout)
                            .lineLimit(1)
                            .help("\(candidate.leftPath)\n\(candidate.rightPath)")
                            .textSelection(.enabled)
                        Text(String(format: GatherLocalization.l("%@ · 置信度 %lld%%"), Self.candidateStatusText(candidate.status), Int(candidate.confidence * 100)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if candidate.status != .accepted {
                                Button(GatherLocalization.l("接受")) {
                                    pendingAcceptCandidate = candidate
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                            if candidate.status != .rejected {
                                Button(candidate.status == .accepted ? GatherLocalization.l("拆分") : GatherLocalization.l("拒绝")) {
                                    pendingRejectCandidate = candidate
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                        }
                    }
                    if candidate.id != viewModel.assetCandidates.last?.id {
                        Divider()
                    }
                }
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingAcceptCandidate,
            title: GatherLocalization.l("接受资产关联？"),
            confirmLabel: { _ in GatherLocalization.l("接受并合并") },
            message: { candidate in
                String(
                    format: GatherLocalization.l("将把「%@」与「%@」合并为同一个资产（RAW + JPEG 变体）：图库与导出中只保留一个条目，另一个作为变体保留在磁盘上。"),
                    Self.basename(candidate.leftPath),
                    Self.basename(candidate.rightPath)
                )
            },
            onConfirm: { candidate in
                Task { await viewModel.updateCandidate(candidate, accept: true, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
        .gatherDestructiveConfirm(
            pending: $pendingRejectCandidate,
            title: GatherLocalization.l("拒绝资产关联？"),
            confirmLabel: { candidate in
                candidate.status == .accepted
                    ? GatherLocalization.l("拆分资产")
                    : GatherLocalization.l("拒绝关联")
            },
            message: { candidate in
                String(
                    format: candidate.status == .accepted
                        ? GatherLocalization.l("将拆分「%@」与「%@」：两张文件重新作为独立照片出现在图库中。")
                        : GatherLocalization.l("将拒绝「%@」与「%@」的关联：两张文件保持独立，自动关联不会再合并它们。"),
                    Self.basename(candidate.leftPath),
                    Self.basename(candidate.rightPath)
                )
            },
            onConfirm: { candidate in
                Task { await viewModel.updateCandidate(candidate, accept: false, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var metadataOrphansCard: some View {
        supportCard(title: GatherLocalization.l("孤立 XMP"), systemImage: "doc.badge.ellipsis") {
            if viewModel.metadataOrphans.isEmpty {
                Text(GatherLocalization.l("没有孤立 XMP"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // TS Library/index.tsx:377 —— 孤立 XMP 直出（卡片内可滚动，无分页门控）。
                LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.metadataOrphans, id: \.xmpPath) { orphan in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.basename(orphan.xmpPath))
                            .font(.callout)
                            .lineLimit(1)
                            .help(orphan.xmpPath)
                            .textSelection(.enabled)
                        // TS index.tsx:380 —— translateErrorCode 语义：状态与错误码
                        // 一律经本地化漏斗，原始诊断只进日志（不直显给用户）。
                        Text(orphan.errorMessage.isEmpty
                            ? Self.orphanStatusText(orphan.status)
                            : String(
                                format: GatherLocalization.l("%@ · %@"),
                                Self.orphanStatusText(orphan.status),
                                Self.orphanErrorText(orphan.errorMessage)
                            ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if orphan.status == "pending" || orphan.status == "failed" {
                                // 重试是「再试一次已授权的写回」，按钮本身即用户决定。
                                Button(GatherLocalization.l("重试")) {
                                    Task { await viewModel.resolveOrphan(orphan, action: .retry, confirmed: true) }
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                            // 保留 XMP 不改写任何照片文件，按钮本身即用户决定。
                            Button(GatherLocalization.l("保留 XMP")) {
                                Task { await viewModel.resolveOrphan(orphan, action: .keep, confirmed: true) }
                            }
                            .disabled(viewModel.isSupportBusy)
                            Button(GatherLocalization.l("恢复原片"), role: .destructive) {
                                pendingRestoreOrphan = orphan
                            }
                            .disabled(viewModel.isSupportBusy)
                        }
                    }
                    if orphan.xmpPath != viewModel.metadataOrphans.last?.xmpPath {
                        Divider()
                    }
                }
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingRestoreOrphan,
            title: GatherLocalization.l("恢复原片"),
            confirmLabel: { _ in GatherLocalization.l("恢复原片") },
            message: { orphan in
                String(
                    format: GatherLocalization.l("会用备份覆盖照片文件「%@」，当前内容将被替换，此操作不可撤销。"),
                    Self.basename(orphan.xmpPath)
                )
            },
            onConfirm: { orphan in
                Task { await viewModel.resolveOrphan(orphan, action: .restore, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var offlineVolumesCard: some View {
        supportCard(title: GatherLocalization.l("离线存储卷"), systemImage: "externaldrive.badge.exclamationmark") {
            let offlineVolumes = viewModel.assetVolumes.filter { $0.offlineFiles > 0 }
            if offlineVolumes.isEmpty {
                Text(GatherLocalization.l("没有需要重新关联的离线卷"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(offlineVolumes, id: \.volumeId) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.roots.joined(separator: "、").isEmpty ? volume.volumeId : volume.roots.joined(separator: "、"))
                            .font(.callout)
                            .lineLimit(2)
                            .help(volume.roots.joined(separator: "\n"))
                        Text(String(format: GatherLocalization.l("离线文件：%lld"), volume.offlineFiles))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(volume.roots, id: \.self) { root in
                            Button(GatherLocalization.l("重新关联此目录")) {
                                Task {
                                    // 先只选目录（不发命令），拿到新旧根后再弹确认。
                                    if let newRoot = await viewModel.chooseRelinkRoot() {
                                        pendingRelink = PendingRelink(oldRoot: root, newRoot: newRoot)
                                    }
                                }
                            }
                            .disabled(viewModel.isSupportBusy)
                        }
                    }
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingRelink,
            title: GatherLocalization.l("重新关联离线存储卷？"),
            confirmLabel: { _ in GatherLocalization.l("重新关联") },
            message: { relink in
                String(
                    format: GatherLocalization.l("会把「%@」下已登记的文件路径改写为「%@」（该卷共 %lld 个离线文件），并重新索引这些文件。原目录不会被修改或删除。"),
                    relink.oldRoot,
                    relink.newRoot,
                    viewModel.assetVolumes.reduce(0) { $0 + $1.offlineFiles }
                )
            },
            onConfirm: { relink in
                Task {
                    await viewModel.relinkVolume(
                        root: relink.oldRoot,
                        newRoot: relink.newRoot,
                        confirmed: true
                    )
                }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    /// 检查器里的一组管理功能：标题 + 内容，套系统分组容器。
    private func supportCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.panel)
    }

    /// 对齐 TS Library/index.tsx:353-355：已关联/已拒绝/待确认·N%。
    /// 孤立 XMP 状态 → 可本地化文案；未知状态记日志并回退通用文案，
    /// 绝不把原始状态码/诊断字符串直显给用户（审查 P3）。
    private static func orphanStatusText(_ status: String) -> String {
        switch status {
        case "pending": return GatherLocalization.l("待处理")
        case "failed": return GatherLocalization.l("上次处理失败")
        case "resolved", "kept", "restored": return GatherLocalization.l("已处理")
        default:
            GatherLogger.log("library orphan status unmapped: \(status)", level: .debug)
            return GatherLocalization.l("状态未知")
        }
    }

    /// 孤立 XMP 错误码 → 本地化文案；非错误码诊断只进日志 + 通用文案。
    private static func orphanErrorText(_ raw: String) -> String {
        LibraryViewModel.userFacingText(for: raw)
    }

    private static func candidateStatusText(_ status: AssetLinkCandidateStatus) -> String {
        switch status {
        case .accepted: return GatherLocalization.l("已关联")
        case .rejected: return GatherLocalization.l("已拒绝")
        case .pending: return GatherLocalization.l("待确认")
        }
    }

    private static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: 状态行（TS toolbar：loading/totalCount + range）

    private var statusBar: some View {
        HStack(spacing: 12) {
            if viewModel.phase == .loading {
                Text(GatherLocalization.l("加载中…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: GatherLocalization.l("共 %lld 张逻辑照片"), viewModel.total))
                    .font(.callout)
                Text(viewModel.rangeText)
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

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(GatherLocalization.l("加载照片中…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            loadFailureState(message)
        case .loaded:
            if viewModel.photos.isEmpty {
                emptyState
            } else {
                photoGrid
            }
        }
    }

    /// 失败出口：系统空态 + 重试（不再只渲染一行红字）。
    private func loadFailureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("全局图库"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(String(format: GatherLocalization.l("加载照片失败：%@"), message))
        } actions: {
            Button(GatherLocalization.l("重试")) {
                Task { await viewModel.load() }
            }
            .gatherPrimaryActionButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 无结果态：系统 ContentUnavailableView + 「清除筛选」出口。
    private var emptyState: some View {
        // E 报告：空库（没有任何筛选条件）时旧实现只给一个**被禁用**的
        //「清除筛选」——用户面对死路。这里分两种语义：
        //   · 有筛选 → 清除筛选（可用）；
        //   · 无筛选 → 图库确实为空，给「导入文件夹」出口。
        ContentUnavailableView {
            Label(
                viewModel.activeFilterCount == 0
                    ? GatherLocalization.l("图库还没有照片")
                    : GatherLocalization.l("没有符合条件的照片"),
                systemImage: viewModel.activeFilterCount == 0
                    ? "photo.on.rectangle.angled"
                    : "magnifyingglass"
            )
        } description: {
            Text(viewModel.activeFilterCount == 0
                ? GatherLocalization.l("导入一个文件夹后，这里会汇总所有工作区的照片。")
                : GatherLocalization.l("调整或清除筛选条件以查看全部照片"))
        } actions: {
            if viewModel.activeFilterCount == 0 {
                Button(GatherLocalization.l("导入文件夹")) {
                    NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
                }
                .gatherPrimaryActionButton()
            } else {
                Button(GatherLocalization.l("清除筛选")) {
                    viewModel.clearFilters()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button(GatherLocalization.l("上一页")) {
                viewModel.prevPage()
            }
            .disabled(viewModel.page == 0)
            Text("\(viewModel.page + 1) / \(max(1, Int(ceil(Double(viewModel.total) / Double(LibraryViewModel.pageSize)))))")
                .font(.callout)
                .monospacedDigit()
            Button(GatherLocalization.l("下一页")) {
                viewModel.nextPage()
            }
            .disabled(!viewModel.hasNextPage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}

// MARK: - 照片条目（TS Library card：缩略图 + 文件名 + 星级 + 色标 + 会话）

private struct LibraryCardView: View {
    let photo: GlobalPhotoResult
    let onOpen: () -> Void
    /// 「打开所在工作区」：与「打开照片」并列的显式动作（N07）。
    var onOpenSession: () -> Void = {}

    /// TS 卡片本体：整项即按钮；不再自绘卡底/描边/悬停阴影，
    /// 缩略图 + 说明文字直接排在窗口底色上（与「照片」App 网格一致）。
    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                thumbnail
                Text(photo.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                ratingRow
                Text(metadataText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !photo.keywords.isEmpty {
                    Text(photo.keywords.prefix(4).joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(GatherLocalization.l("打开照片"), action: onOpen)
            Button(GatherLocalization.l("打开所在工作区"), action: onOpenSession)
            if let url = finderURLForPath(photo.filepath) {
                Divider()
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        // 按钮自带 .isButton 语义（不再叠加 children: .combine，避免盖掉按钮动作）；
        // 标签取文件名，星级/色标/会话/关键词作为 value 一并读出。
        .accessibilityLabel(photo.filename)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [Self.starText(photo.rating), metadataText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var metadataText: String {
        String(
            format: GatherLocalization.l("%@ · %@"),
            photo.label.isEmpty ? GatherLocalization.l("无色标") : photo.label,
            photo.sessionNames.joined(separator: "、")
        )
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            PhotoThumbnailView(path: photo.filepath, size: 512)
                // 占位/加载中/失败三态同尺寸（防跳动）：固定高 110 并撑满卡宽。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 110)
                .background(GatherTheme.contentBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if photo.status == "missing" {
                // 角标压在缩略图上：材质底 + 主文字色（不再用红底白字，深色模式对比不足）。
                Label(GatherLocalization.l("离线"), systemImage: "externaldrive.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .padding(6)
                    .help(GatherLocalization.l("离线"))
            }
        }
    }

    /// 星级：品牌 accent 只做强调（自造 hex 星级色已删除）。
    private var ratingRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .imageScale(.small)
                .foregroundStyle(GatherTheme.accent)
                .accessibilityHidden(true)
            Text(Self.starText(photo.rating))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// TS: rating 星级（★ 重复 + ☆ 补齐）。
    static func starText(_ rating: Double) -> String {
        let count = Int(rating)
        guard count > 0 else { return GatherLocalization.l("未评级") }
        return String(repeating: "★", count: count) + String(repeating: "☆", count: max(0, 5 - count))
    }
}

/// TS: COLOR_LABELS（culling.color.* 中文键值）。
private enum LibraryColorOption: CaseIterable {
    case red, orange, yellow, green, blue, pink, purple

    static let all: [LibraryColorOption] = [.red, .orange, .yellow, .green, .blue, .pink, .purple]

    var value: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }

    var label: String {
        switch self {
        case .red: return GatherLocalization.l("红")
        case .orange: return GatherLocalization.l("橙")
        case .yellow: return GatherLocalization.l("黄")
        case .green: return GatherLocalization.l("绿")
        case .blue: return GatherLocalization.l("蓝")
        case .pink: return GatherLocalization.l("粉")
        case .purple: return GatherLocalization.l("紫")
        }
    }
}
