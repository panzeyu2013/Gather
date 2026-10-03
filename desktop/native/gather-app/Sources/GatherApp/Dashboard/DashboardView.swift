// desktop/native/gather-app/Sources/GatherApp/Dashboard/DashboardView.swift
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
import SwiftUI
import AppKit
import GatherCore

/// 「新建工作区 / 导入文件夹」请求。
///
/// 由外壳（RootView）持有并投递，而不是工作台自己订阅通知：页面是按目的地
/// 条件构建的，离开工作台时 @State 随之销毁——在别的页面按 ⌘N 或点导入时，
/// 直接投给工作台的通知会静默丢失（F02 的入口失效即此类）。
struct NewWorkspaceRequest: Equatable {
    /// 预填目录（导入入口已选好的目录；⌘N 为空串 = 手动选择）。
    var folderPath: String = ""
    /// 请求身份：同一路径的重复请求也必须重新打开表单。
    var id = UUID()
}

struct DashboardView: View {
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
    /// 原生多选：直接绑定 List(selection:)，取代旧版 selectMode + selectedIds 双状态。
    @State private var selectedIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    /// jobs:progress 进度帧节流窗口（事件风暴只按窗口合并一次 UI 更新）。
    private static let jobProgressThrottleInterval: TimeInterval = 1
    @State private var lastJobProgressAppliedAt = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.actionError {
                NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            phaseContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 页面 chrome：标题 / 副标题交给系统窗口，内容区不再自绘大标题。
        .navigationTitle("Gather")
        .navigationSubtitle(GatherLocalization.l("整理、挑选并同步你的摄影工作区"))
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
                GatherLocalization.setAppLanguage(language)
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewSessionSheet(viewModel: viewModel, initialFolderPath: pendingFolderPath) { sessionId in
                onOpenSession(sessionId)
            }
            .onDisappear { pendingFolderPath = "" }
        }
        .alert(
            GatherLocalization.l("删除工作区"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(GatherLocalization.l("删除"), role: .destructive) {
                if let target = deleteTarget {
                    // confirmed: true 只能从这个确认分支到达。
                    Task { await viewModel.deleteSession(target.id, confirmed: true) }
                }
                deleteTarget = nil
            }
            Button(GatherLocalization.l("取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            // TS dashboard.deleteWorkspaceMessage 逐字对齐。
            Text(String(format: GatherLocalization.l("确定要删除 \"%@\" 吗？这将移除该工作区中的所有照片和结果。"), deleteTarget?.name ?? ""))
        }
        .alert(
            GatherLocalization.l("批量删除工作区"),
            isPresented: $showBatchDeleteConfirm
        ) {
            Button(GatherLocalization.l("删除全部"), role: .destructive) {
                let ids = Array(selectedIds)
                Task {
                    // confirmed: true 只能从这个确认分支到达。
                    if await viewModel.deleteSessions(ids, confirmed: true) {
                        selectedIds = []
                    }
                }
            }
            Button(GatherLocalization.l("取消"), role: .cancel) { showBatchDeleteConfirm = false }
        } message: {
            Text(String(format: GatherLocalization.l("确定要删除选中的 %lld 个工作区吗？这将移除这些工作区中的所有照片和结果，不可恢复。"), selectedIds.count))
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
                Label(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise")
            }
            .help(GatherLocalization.l("刷新"))
            .disabled(viewModel.phase == .loading)

            if !viewModel.sessions.isEmpty {
                Button(GatherLocalization.l("全选")) {
                    selectedIds = Set(viewModel.sessions.map(\.id))
                }
                .disabled(selectedIds.count == viewModel.sessions.count)

                if !selectedIds.isEmpty {
                    Button(String(format: GatherLocalization.l("删除 %lld 个"), selectedIds.count), role: .destructive) {
                        showBatchDeleteConfirm = true
                    }
                    Button(GatherLocalization.l("取消")) { selectedIds = [] }
                }
            }

            Button {
                showNewSheet = true
            } label: {
                Label(GatherLocalization.l("新建工作区"), systemImage: "plus")
            }
            .help(GatherLocalization.l("新建工作区"))
        }
    }

    // MARK: 相位（加载 / 失败 / 已加载）

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(GatherLocalization.l("加载工作区中…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            loadFailureState(message)
        case .loaded:
            workspaceList
        }
    }

    /// 失败出口：系统空态 + 重试（不再只渲染一行红字）。
    private func loadFailureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("工作区"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(String(format: GatherLocalization.l("加载工作区失败：%@"), message))
        } actions: {
            Button(GatherLocalization.l("重试")) {
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
            statItem(GatherLocalization.l("工作区"), summary.sessionCount)
            summarySeparator
            statItem(GatherLocalization.l("照片"), summary.photoCount)
            summarySeparator
            statItem(GatherLocalization.l("待同步写回"), summary.pendingXmp)
            summarySeparator
            statItem(GatherLocalization.l("冲突"), summary.conflictXmp)
            summarySeparator
            statItem(GatherLocalization.l("离线照片"), summary.offlinePhotos)
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
            Text(GatherLocalization.l("工作区"))
                .font(.headline)
        }
    }

    private var emptySessionsState: some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("暂无工作区"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(GatherLocalization.l("创建新的工作区以开始整理照片"))
        } actions: {
            Button(GatherLocalization.l("新建工作区")) { showNewSheet = true }
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
                Text(GatherLocalization.l("任务中心"))
                    .font(.headline)
                Text(GatherLocalization.l("后台任务 · 持久化分析任务、进度和失败恢复"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(GatherLocalization.l("清理已完成")) {
                Task { await viewModel.clearCompletedJobs() }
            }
            .disabled(!viewModel.hasClearableJobs)
            .help(GatherLocalization.l("清理已完成"))
        }
    }

    @ViewBuilder
    private var jobsBody: some View {
        if let error = viewModel.jobsError {
            jobsFailureState(error)
        } else if viewModel.jobs.isEmpty {
            ContentUnavailableView {
                Label(GatherLocalization.l("暂无后台任务"), systemImage: "clock")
            }
        } else {
            if viewModel.attentionJobs.isEmpty {
                // quietState：成功语义用系统提示条（图标 + 低透明度底色），不是绿色正文。
                NativeBanner(
                    text: GatherLocalization.l("当前没有运行中或失败的任务"),
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
    private func jobsFailureState(_ error: String) -> some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("任务中心"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(String(format: GatherLocalization.l("任务加载失败：%@"), error))
        } actions: {
            Button(GatherLocalization.l("重试")) {
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
                Text(GatherLocalization.l("已完成历史"))
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

// MARK: - 工作区行（原生 List 行）

private struct SessionRowView: View {
    let session: SessionData
    let photoCountLabel: String
    let status: WorkspaceStatus?
    let scanJob: DashboardScanJob?
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRetryScan: () -> Void

    /// TS 卡片布局：.cardOpen 是整卡按钮（flex:1 内容区），.cardActions 是
    /// 右侧独立按钮组（stopPropagation）——SwiftUI 用 List(selection:) 承载
    /// 选中（⌘/⇧ 原生多选），「进入」按钮与菜单承载动作，不再自绘复选框。
    var body: some View {
        HStack(spacing: 12) {
            identity
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(GatherLocalization.l("打开"), action: onOpen)
            Button(GatherLocalization.l("删除"), role: .destructive, action: onDelete)
        }
    }

    /// 名称 + 状态徽标 + 计数/冲突/离线 + 创建时间。
    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                statusBadge
            }
            metadataRow
            Text(Self.dateText(session.createdAt))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.name)
        .accessibilityValue(accessibilityValue)
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            Text(photoCountLabel)
                .font(.callout)
            if let status {
                if status.xmp.pending > 0 {
                    statusPill(
                        String(format: GatherLocalization.l("待同步写回 %lld"), status.xmp.pending),
                        systemImage: "arrow.up.doc",
                        color: GatherTheme.warning
                    )
                }
                if status.xmp.conflict > 0 {
                    statusPill(
                        String(format: GatherLocalization.l("冲突 %lld"), status.xmp.conflict),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.error
                    )
                }
                if !status.failedJobs.isEmpty {
                    statusPill(
                        String(format: GatherLocalization.l("失败任务 %lld"), status.failedJobs.count),
                        systemImage: "xmark.octagon.fill",
                        color: GatherTheme.error
                    )
                }
                if status.offlinePhotos > 0 {
                    Text(String(format: GatherLocalization.l("离线 %lld"), status.offlinePhotos))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }

    /// 状态信号 = 语义色图标 + 低透明度底色；正文保持系统主文字色
    /// （GatherTheme.warning 对比度不足，绝不作为正文前景色）。
    private func statusPill(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    private var accessibilityValue: String {
        var parts = [photoCountLabel]
        if let status {
            if status.xmp.pending > 0 {
                parts.append(String(format: GatherLocalization.l("待同步写回 %lld"), status.xmp.pending))
            }
            if status.xmp.conflict > 0 {
                parts.append(String(format: GatherLocalization.l("冲突 %lld"), status.xmp.conflict))
            }
            if !status.failedJobs.isEmpty {
                parts.append(String(format: GatherLocalization.l("失败任务 %lld"), status.failedJobs.count))
            }
            if status.offlinePhotos > 0 {
                parts.append(String(format: GatherLocalization.l("离线 %lld"), status.offlinePhotos))
            }
        }
        parts.append(Self.dateText(session.createdAt))
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            // TS retryScan：索引失败行显示「重试」，重新入队 metadata.scan。
            if deriveCardIndexKind(scanJob) == .failed {
                Button(GatherLocalization.l("重试"), action: onRetryScan)
                    .buttonStyle(.bordered)
                    .help(String(format: GatherLocalization.l("重试 %@"), session.name))
            }
            Button(GatherLocalization.l("进入"), action: onOpen)
                .buttonStyle(.bordered)
                .help(String(format: GatherLocalization.l("打开 %@"), session.name))
            Menu {
                Button(GatherLocalization.l("删除"), role: .destructive, action: onDelete)
            } label: {
                Label(GatherLocalization.l("操作"), systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help(GatherLocalization.l("操作"))
        }
    }

    /// TS Badge 状态色（取值已换成系统语义色）。
    private var statusBadge: GatherBadge {
        switch session.status {
        case .draft:
            return .draft()
        case .photosLoaded:
            return .photosLoaded()
        case .analyzing:
            return .running(GatherLocalization.l("分析中"))
        case .review:
            return .review()
        case .completed:
            return .done(GatherLocalization.l("已完成"))
        }
    }

    /// TS Dashboard formatDate（toLocaleDateString：跟随应用语言；
    /// zh 环境输出 2026年8月12日 14:30）。
    private static func dateText(_ iso: String) -> String {
        // C-8（性能审计）：不再每次新建 DateFormatter（每行 2 次 ⇒ 6 个/行/次重绘），
        // 改为进程内缓存实例；**输出与旧实现逐字节一致**（FormatStyle 在 zh 下
        // 会把 09:46 写成 9:46，属展示回归，已放弃该方案）。
        guard let date = parseISO8601Date(iso) else { return iso }
        return DisplayDateFormatters.shared.mediumShort(date, locale: GatherLocalization.appLocale)
    }
}

// MARK: - 任务行（TS Jobs 页统一行格式：身份列 + 状态徽标 + 进度条 + 操作）

private struct JobRowView: View {
    let job: AnalysisJobData
    var compact = false
    /// 工作区显示名（空串 = 未知；旧实现显示 scopeId 前 8 位 UUID，已删除）。
    var scopeName: String = ""
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .padding(.vertical, 2)
    }

    /// 非 compact 行：TS Jobs.module.css .row 四列（身份 flexible≥180 /
    /// 状态 90 / 进度 flexible / 操作 80）。身份列改弹性下限：窄窗口收缩、
    /// 宽窗口舒展，英文类型文案不截断。
    private var fullBody: some View {
        HStack(spacing: 16) {
            identityColumn
                .frame(minWidth: 180, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
            statusBadge
                .frame(width: 90, alignment: .leading)
            progressBar
                .frame(maxWidth: .infinity)
            actions
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// compact 行：TS .rowCompact 两列（身份 flexible + 状态 100），无进度无操作。
    private var compactBody: some View {
        HStack(spacing: 16) {
            identityColumn
            Spacer(minLength: 0)
            statusBadge
                .frame(width: 100, alignment: .trailing)
        }
    }

    /// TS .identity 列：类型 strong +「工作区 · 名称」+「尝试 N 次」+ 错误。
    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.typeLabel(job.type))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(scopeText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !compact {
                Text(String(format: GatherLocalization.l("尝试 %lld 次"), job.attemptCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !job.errorMessage.isEmpty {
                // 错误码经漏斗翻译；tooltip 同样不直显原始诊断（细节只进日志）。
                Text(GatherLocalization.jobErrorMessage(job.errorMessage))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(1)
                    .help(GatherLocalization.jobErrorMessage(job.errorMessage))
            }
        }
    }

    private var scopeText: String {
        scopeName.isEmpty
            ? GatherLocalization.l("工作区")
            : String(format: GatherLocalization.l("工作区 · %@"), scopeName)
    }

    /// 状态：GatherBadge 主题语义色编码（成功/失败/警告/信息/主色）。
    private var statusBadge: some View {
        GatherBadge(status: job.status)
    }

    /// 进度：原生 ProgressView（GatherProgressBar 内部已换系统控件），
    /// 标签文案仍在条上方显示 百分比 + 相位（pct = round(current/total)）。
    private var progressBar: some View {
        GatherProgressBar(
            fraction: Double(DashboardViewModel.progressPercent(of: job)) / 100,
            fill: GatherTheme.accent,
            label: "\(DashboardViewModel.progressPercent(of: job))% \(GatherLocalization.progressPhaseText(job.progressMessage))",
            accessibilityText: Self.typeLabel(job.type)
        )
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if job.status == .queued || job.status == .running {
                Button(GatherLocalization.l("取消"), action: onCancel)
            }
            if job.status == .failed || job.status == .interrupted || job.status == .cancelled {
                Button(GatherLocalization.l("重试"), action: onRetry)
            }
        }
    }

    /// TS JOB_TYPE_KEYS（jobs.type.* 中文键值）。
    static func typeLabel(_ type: AnalysisJobType) -> String {
        switch type {
        case .metadataScan: return GatherLocalization.l("照片索引与元数据")
        case .checksumBackfill: return GatherLocalization.l("文件校验和补全")
        case .similarityAnalyze: return GatherLocalization.l("相似照片分析")
        case .faceAnalyze: return GatherLocalization.l("人脸分析")
        case .duplicateScan: return GatherLocalization.l("重复照片扫描")
        case .qualityScore: return GatherLocalization.l("技术质量分析")
        case .exportExecute: return GatherLocalization.l("照片导出")
        case .thumbnailBuild: return GatherLocalization.l("缩略图生成")
        }
    }
}

// MARK: - 新建工作区（来源选择 + C1 四层预检 + metadata.scan 一跳入队）

private struct NewSessionSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    /// 创建成功回调（TS createMutation onSuccess → navigate /sessions/:id）。
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var nameEdited = false
    @State private var folderPath = ""
    @State private var source = DashboardViewModel.SessionSource.local

    init(
        viewModel: DashboardViewModel,
        initialFolderPath: String = "",
        onCreated: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onCreated = onCreated
        _folderPath = State(initialValue: initialFolderPath)
        _name = State(initialValue: initialFolderPath.isEmpty ? "" : URL(fileURLWithPath: initialFolderPath).lastPathComponent)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 表单行交给 Form + .formStyle(.grouped) + LabeledContent：
            // 标签列、控件列、行内边距与选中高亮由系统负责。
            Form {
                nameSection
                sourceSection
                if let error = viewModel.createError {
                    // createError 只可能是 GatherLocalization.l(...) 引导文案或
                    // errorText(code) 输出（DashboardViewModel.message/c1Message 漏斗），
                    // 原始诊断只进日志，不经 UI 直显。
                    NativeBanner(text: error)
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 520)
        // N10：sheet 高度贴合内容。旧的固定 440pt 在 3 行表单下留出 200pt 以上
        // 空白；Capture One 来源会多出「连接预检」区块，因此按来源给两档高度。
        .frame(height: source == .captureOne ? 430 : 330)
        .task {
            // TS：对话框打开且来源为 Capture One 时自动预检。
            if source == .captureOne {
                await viewModel.runC1Preflight()
            }
        }
        .onChange(of: source) { _, newSource in
            // TS：切换来源且名称未编辑时清空名称。
            if !nameEdited { name = "" }
            if newSource == .captureOne {
                Task { await viewModel.runC1Preflight() }
            }
        }
    }

    private var nameSection: some View {
        Section {
            LabeledContent(GatherLocalization.l("名称")) {
                TextField(
                    GatherLocalization.l("名称"),
                    text: $name,
                    prompt: Text(source == .local
                        ? GatherLocalization.l("自动生成")
                        : GatherLocalization.l("默认用文件夹名"))
                )
                .labelsHidden()
                .onChange(of: name) { _, _ in nameEdited = true }
            }
        } footer: {
            // N10：长提示从输入框 placeholder 移到分组脚注——placeholder 在标签列
            // 挤压下会被截断成「选择文件…」，而脚注有整行宽度。
            Text(source == .local
                ? GatherLocalization.l("选择文件夹后名称会自动生成，也可以先手动输入。")
                : GatherLocalization.l("留空则使用选中照片所在的文件夹名称。"))
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            Picker(GatherLocalization.l("导入来源"), selection: $source) {
                ForEach(DashboardViewModel.SessionSource.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        if source == .local {
            Section {
                folderRow
            }
        } else {
            Section {
                c1PreflightRows
            } header: {
                Text(GatherLocalization.l("Capture One 连接预检"))
            }
        }
    }

    private var canCreate: Bool {
        switch source {
        case .local:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty && !folderPath.isEmpty
        case .captureOne:
            // 名称可留空（回退文件夹名），但预检/创建进行中禁用。
            return !viewModel.isC1PreflightChecking
        }
    }

    /// TS handleSelectFolder（selectDirectory + 未编辑时用目录名填充名称）。
    ///
    /// 第三轮审计 F：改用非阻塞 `begin()`。旧实现的 `runModal()` 在 sheet 内
    /// 再开嵌套 runloop，会卡住主线程并让工具栏/菜单在新工作区表单打开期间失去响应。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = GatherLocalization.l("请选择包含照片的文件夹")
        Task { @MainActor in
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { return }
            folderPath = url.path
            if !nameEdited {
                name = url.lastPathComponent
            }
        }
    }

    private var folderRow: some View {
        LabeledContent(GatherLocalization.l("文件夹位置")) {
            HStack(spacing: 8) {
                TextField(
                    GatherLocalization.l("文件夹位置"),
                    text: $folderPath,
                    prompt: Text(GatherLocalization.l("选择文件夹"))
                )
                .labelsHidden()
                .disabled(true)
                Button(GatherLocalization.l("选择文件夹"), action: chooseFolder)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { isDirectoryURL($0) }) else { return false }
            folderPath = url.path
            if !nameEdited {
                name = url.lastPathComponent
            }
            return true
        }
    }

    /// TS Dialog c1Preflight 区块：检查清单 + 通过/引导文案。
    /// 状态行 = Label + SF Symbol + 语义色（不再用裸 ✓/✗ 字形与纯颜色信号）。
    @ViewBuilder
    private var c1PreflightRows: some View {
        switch viewModel.c1Preflight {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(GatherLocalization.l("正在检查 Capture One 连接…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .finished(let result):
            ForEach(result.checks) { check in
                Label(
                    check.label,
                    systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(check.passed ? GatherTheme.success : GatherTheme.error)
            }
            if result.passed {
                Text(GatherLocalization.l("预检通过：导入时读取 Capture One 当前选中的照片。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let guidance = result.guidance {
                // 旧版 c1-preflight.ts：预检失败引导为 error 语义提示条。
                NativeBanner(text: guidance)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("创建后会立即启动照片索引；索引进度和失败重试可在任务中心查看。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(GatherLocalization.l("取消")) { dismiss() }
                Button(GatherLocalization.l("创建"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || viewModel.isCreating)
            }
        }
        .padding(16)
    }

    /// TS handleCreate：本地 → createFromDirectory；Capture One → 预检门控后
    /// 读选中照片建库（未选中报“请先在 Capture One 中选择照片”）。
    private func create() {
        Task {
            let session: SessionData?
            switch source {
            case .local:
                session = await viewModel.createSession(
                    name: name.trimmingCharacters(in: .whitespaces),
                    sourcePath: folderPath
                )
            case .captureOne:
                session = await viewModel.createSessionFromCaptureOne(
                    name: name.trimmingCharacters(in: .whitespaces)
                )
            }
            if let session {
                dismiss()
                // TS createMutation onSuccess L220：创建成功后立即跳转
                // /sessions/:id（控制中心）；toast 已由 ViewModel 展示。
                onCreated(session.id)
            }
        }
    }
}
