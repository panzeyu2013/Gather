// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardView.swift
// Phase 3.1 Dashboard：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Dashboard/index.tsx + pages/Jobs/index.tsx
//
// 原生化改造（仅视图层）：
// - 删除内容区自绘头部（26pt 大标题 / 副标题 / 手搓刷新与多选按钮）：标题与副标题
//   交给窗口 chrome（.navigationTitle / .navigationSubtitle），页面级动作进系统工具栏；
// - 手搓多选（selectMode + 自绘 checkbox 图标）→ List(selection:) 原生多选：
//   ⌘ 点选、⇧ 连选、行内选中高亮与 Delete 键命令全部由系统负责；
// - 自绘卡片底 / 描边 / 悬停态 → .gatherCard() 分组容器 + 系统 Divider；
// - 空态 / 错误态 → ContentUnavailableView（macOS 14+），失败一定带重试出口；
// - 计数与状态改走系统文本样式；warning 不再做正文前景色（图标 + 低透明度底色）。
//
// Cut 4 / 4c-2i：Dashboard 拆分（行为不变）。本文件只保留页面壳（状态/接线/
// 工具栏/列表骨架/#Preview）；行与表单拆到 SessionRowView / JobRowView /
// NewSessionSheet。修饰符顺序（onChange sessions ids → task → onReceive
// jobProgress → onAppear → onChange newWorkspaceRequest → onReceive
// languageChanged → sheet → onDisappear → alert → alert）逐字未动。
import SwiftUI
import GatherProtocol

/// 「新建工作区 / 导入文件夹」请求。
///
/// 由外壳（RootView）持有并投递，而不是工作台自己订阅通知：页面是按目的地
/// 条件构建的，离开工作台时 @State 随之销毁——在别的页面按 ⌘N 或点导入时，
/// 直接投给工作台的通知会静默丢失（F02 的入口失效即此类）。
package struct NewWorkspaceRequest: Equatable {
    /// 预填目录（导入入口已选好的目录；⌘N 为空串 = 手动选择）。
    var folderPath: String = ""
    /// 请求身份：同一路径的重复请求也必须重新打开表单。
    var id = UUID()

    package init(folderPath: String = "") {
        self.folderPath = folderPath
    }
}

package struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    /// 外壳暂存的新建/导入请求（非空 = 打开新建表单）。
    @Binding var newWorkspaceRequest: NewWorkspaceRequest?
    /// 打开工作区回调（RootView 注入；默认 no-op 便于独立预览/测试）。
    /// 创建成功导航（TS navigate /sessions/:id）与行内「进入」共用。
    var onOpenSession: (String) -> Void = { _ in }

    @State private var showNewSheet = false
    @State private var deleteTarget: SessionData?
    @State private var showHistory = false
    /// 新建表单的预填目录（消费请求时写入，取消后不保留）。
    @State private var pendingFolderPath = ""

    package init(
        viewModel: DashboardViewModel,
        newWorkspaceRequest: Binding<NewWorkspaceRequest?>,
        onOpenSession: @escaping (String) -> Void = { _ in }
    ) {
        self._viewModel = Bindable(viewModel)
        self._newWorkspaceRequest = newWorkspaceRequest
        self.onOpenSession = onOpenSession
    }

    /// Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 原生多选：直接绑定 List(selection:)，取代旧版 selectMode + selectedIds 双状态。
    @State private var selectedIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    /// jobs:progress 进度帧节流窗口（事件风暴只按窗口合并一次 UI 更新）。
    private static let jobProgressThrottleInterval: TimeInterval = 1
    @State private var lastJobProgressAppliedAt = Date.distantPast

    package var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.actionError {
                NativeBanner(text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            phaseContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 页面 chrome：标题 / 副标题交给系统窗口，内容区不再自绘大标题。
        .navigationTitle("Gather")
        .navigationSubtitle(l10n("整理、挑选并同步你的摄影工作区"))
        .toolbar { toolbarItems }
        .onChange(of: viewModel.sessions.map(\.id)) { _, ids in
            // 行被别处删除时收敛选中集合，避免「删除 N 个」计数虚高。
            selectedIds.formIntersection(Set(ids))
        }
        .task {
            if viewModel.phase == .loading {
                await viewModel.loadAll()
            }
            viewModel.startAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            // 进度帧节流：1s 窗口内合并（对齐 GalleryViewModel 的
            // progressFrameDebounce 先例），避免高频帧反复重排整行 UI；
            // 终态帧始终透传（权威计数/整页刷新不受影响）。
            if !event.isTerminal {
                guard Date().timeIntervalSince(lastJobProgressAppliedAt) >= Self.jobProgressThrottleInterval else { return }
                lastJobProgressAppliedAt = Date()
            }
            viewModel.applyJobEvent(event)
        }
        // 新建/导入请求由外壳投递（onAppear 兜住切页竞态，onChange 覆盖已在工作台
        // 的情形）。两个入口共用同一表单：一次点击只出现一个 sheet。
        .onAppear { consumeNewWorkspaceRequest() }
        .onChange(of: newWorkspaceRequest) { _, _ in consumeNewWorkspaceRequest() }
        // 设置页切换语言（settings.set_language → languageChanged）：日期等
        // 格式化跟随 ui_language，不再硬编码 zh_CN。
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.languageChanged)) { notification in
            if let language = notification.object as? String {
                // Cut 4 / 4b-1：语言唯一写入口是 LanguageStore（它同步旧全局，
                // 供尚未 codemod 的 l() 跟随）；本页只把外部广播转成 store 写入。
                languageStore?.set(rawLanguage: language)
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewSessionSheet(viewModel: viewModel, initialFolderPath: pendingFolderPath) { sessionId in
                onOpenSession(sessionId)
            }
            .onDisappear { pendingFolderPath = "" }
        }
        .alert(
            l10n("删除工作区"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(l10n("删除"), role: .destructive) {
                if let target = deleteTarget {
                    // confirmed: true 只能从这个确认分支到达。
                    Task { await viewModel.deleteSession(target.id, confirmed: true) }
                }
                deleteTarget = nil
            }
            Button(l10n("取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            // TS dashboard.deleteWorkspaceMessage 逐字对齐。
            Text(l10n.format("确定要删除 \"%@\" 吗？这将移除该工作区中的所有照片和结果。", deleteTarget?.name ?? ""))
        }
        .alert(
            l10n("批量删除工作区"),
            isPresented: $showBatchDeleteConfirm
        ) {
            Button(l10n("删除全部"), role: .destructive) {
                let ids = Array(selectedIds)
                Task {
                    // confirmed: true 只能从这个确认分支到达。
                    if await viewModel.deleteSessions(ids, confirmed: true) {
                        selectedIds = []
                    }
                }
            }
            Button(l10n("取消"), role: .cancel) { showBatchDeleteConfirm = false }
        } message: {
            Text(l10n.format("确定要删除选中的 %lld 个工作区吗？这将移除这些工作区中的所有照片和结果，不可恢复。", selectedIds.count))
        }
    }

    /// 消费外壳投递的新建/导入请求：清空请求（防重复弹窗）后打开表单。
    private func consumeNewWorkspaceRequest() {
        guard let request = newWorkspaceRequest else { return }
        newWorkspaceRequest = nil
        pendingFolderPath = request.folderPath
        showNewSheet = true
    }

    // MARK: 工具栏（页面级动作：刷新 / 选择 / 新建）

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await viewModel.refreshAll() }
            } label: {
                Label(l10n("刷新"), systemImage: "arrow.clockwise")
            }
            .help(l10n("刷新"))
            .disabled(viewModel.phase == .loading)

            if !viewModel.sessions.isEmpty {
                Button(l10n("全选")) {
                    selectedIds = Set(viewModel.sessions.map(\.id))
                }
                .disabled(selectedIds.count == viewModel.sessions.count)

                if !selectedIds.isEmpty {
                    Button(l10n.format("删除 %lld 个", selectedIds.count), role: .destructive) {
                        showBatchDeleteConfirm = true
                    }
                    Button(l10n("取消")) { selectedIds = [] }
                }
            }

            Button {
                showNewSheet = true
            } label: {
                Label(l10n("新建工作区"), systemImage: "plus")
            }
            .help(l10n("新建工作区"))
        }
    }

    // MARK: 相位（加载 / 失败 / 已加载）

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(l10n("加载工作区中…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            loadFailureState(error)
        case .loaded:
            workspaceList
        }
    }

    /// 失败出口：系统空态 + 重试（不再只渲染一行红字）。
    /// 4a-3b-2a：错误以 `CommandError` 传入，文案在渲染期按当前语言解析。
    private func loadFailureState(_ error: CommandError) -> some View {
        ContentUnavailableView {
            Label(l10n("工作区"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(l10n.format("加载工作区失败：%@", CommandErrorText.resolve(error, with: l10n)))
        } actions: {
            Button(l10n("重试")) {
                Task { await viewModel.loadAll() }
            }
            .gatherPrimaryActionButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 内容（原生列表：概览 / 工作区 / 任务中心）

    private var workspaceList: some View {
        List(selection: $selectedIds) {
            summaryRow
            sessionsSection
            jobsSection
        }
        .listStyle(.inset)
        .onDeleteCommand {
            // 原生 Delete 键：只在有选中项时走同一确认门控（取消不发命令）。
            if !selectedIds.isEmpty {
                showBatchDeleteConfirm = true
            }
        }
    }

    // MARK: 工作区概览（SwiftUI 侧聚合，数据源 workspace.status）

    /// 概览条：原生分组容器 + 系统分隔线（取代自绘圆角底 + 1pt 描边 + 竖线方块）。
    private var summaryRow: some View {
        let summary = viewModel.summary()
        return HStack(alignment: .center, spacing: 0) {
            statItem(l10n("工作区"), summary.sessionCount)
            summarySeparator
            statItem(l10n("照片"), summary.photoCount)
            summarySeparator
            statItem(l10n("待同步写回"), summary.pendingXmp)
            summarySeparator
            statItem(l10n("冲突"), summary.conflictXmp)
            summarySeparator
            statItem(l10n("离线照片"), summary.offlinePhotos)
        }
        .gatherCard()
    }

    private var summarySeparator: some View {
        Divider()
            .frame(height: 28)
    }

    private func statItem(_ title: String, _ value: Int) -> some View {
        GatherStatCard(value: value, label: title, style: .plain)
    }

    // MARK: 工作区列表（原生 List(selection:) 多选）

    @ViewBuilder
    private var sessionsSection: some View {
        Section {
            if viewModel.sessions.isEmpty {
                emptySessionsState
            } else {
                ForEach(viewModel.sessions, id: \.id) { session in
                    SessionRowView(
                        session: session,
                        photoCountLabel: viewModel.photoCountLabel(for: session),
                        status: viewModel.statuses[session.id],
                        scanJob: viewModel.scanJobs[session.id],
                        onOpen: { onOpenSession(session.id) },
                        onDelete: { deleteTarget = session },
                        onRetryScan: { Task { await viewModel.retryScan(sessionId: session.id) } }
                    )
                    .tag(session.id)
                }
            }
        } header: {
            Text(l10n("工作区"))
                .font(.headline)
        }
    }

    private var emptySessionsState: some View {
        ContentUnavailableView {
            Label(l10n("暂无工作区"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(l10n("创建新的工作区以开始整理照片"))
        } actions: {
            Button(l10n("新建工作区")) { showNewSheet = true }
                .gatherPrimaryActionButton()
        }
    }

    // MARK: 任务中心（TS Jobs 页：attention + history + clear）

    @ViewBuilder
    private var jobsSection: some View {
        Section {
            jobsBody
        } header: {
            jobsSectionHeader
        }
    }

    private var jobsSectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n("任务中心"))
                    .font(.headline)
                Text(l10n("后台任务 · 持久化分析任务、进度和失败恢复"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(l10n("清理已完成")) {
                Task { await viewModel.clearCompletedJobs() }
            }
            .disabled(!viewModel.hasClearableJobs)
            .help(l10n("清理已完成"))
        }
    }

    @ViewBuilder
    private var jobsBody: some View {
        if let error = viewModel.jobsError {
            jobsFailureState(error)
        } else if viewModel.jobs.isEmpty {
            ContentUnavailableView {
                Label(l10n("暂无后台任务"), systemImage: "clock")
            }
        } else {
            if viewModel.attentionJobs.isEmpty {
                // quietState：成功语义用系统提示条（图标 + 低透明度底色），不是绿色正文。
                NativeBanner(
                    text: l10n("当前没有运行中或失败的任务"),
                    systemImage: "checkmark.circle",
                    color: GatherTheme.success
                )
            } else {
                ForEach(viewModel.attentionJobs, id: \.id) { job in
                    JobRowView(
                        job: job,
                        scopeName: scopeName(for: job),
                        onCancel: { Task { await viewModel.cancelJob(job.id) } },
                        onRetry: { Task { await viewModel.retryJob(job.id) } }
                    )
                }
            }
            if !viewModel.historyJobs.isEmpty {
                historyDisclosure
            }
        }
    }

    /// 任务中心错误态（jobs.list 失败；区别于「暂无后台任务」空态）。
    private func jobsFailureState(_ error: CommandError) -> some View {
        ContentUnavailableView {
            Label(l10n("任务中心"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(l10n.format("任务加载失败：%@", CommandErrorText.resolve(error, with: l10n)))
        } actions: {
            Button(l10n("重试")) {
                Task { await viewModel.refreshJobs() }
            }
            .gatherPrimaryActionButton()
        }
    }

    /// 已完成历史：系统 DisclosureGroup（取代手搓 chevron + 展开/收起按钮）。
    private var historyDisclosure: some View {
        DisclosureGroup(isExpanded: $showHistory) {
            ForEach(viewModel.historyJobs, id: \.id) { job in
                JobRowView(
                    job: job,
                    compact: true,
                    scopeName: scopeName(for: job),
                    onCancel: {},
                    onRetry: {}
                )
            }
        } label: {
            HStack(spacing: 6) {
                Text(l10n("已完成历史"))
                Text(verbatim: "\(viewModel.historyJobs.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    /// 任务行的工作区显示名（旧实现显示 scopeId 前 8 位 UUID，已删除）。
    private func scopeName(for job: AnalysisJobData) -> String {
        viewModel.sessions.first { $0.id == job.scopeId }?.name ?? ""
    }
}

#if DEBUG
#Preview("Dashboard · 工作台") {
    PreviewFactory.dashboardPage()
}
#endif
