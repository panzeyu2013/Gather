// desktop/native/gather-app/Sources/GatherApp/Dashboard/DashboardView.swift
// Phase 3.1 Dashboard：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Dashboard/index.tsx + pages/Jobs/index.tsx
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    /// 打开工作区回调（RootView 注入；默认 no-op 便于独立预览/测试）。
    /// 创建成功导航（TS navigate(`/sessions/${id})`）与卡片「进入」共用。
    var onOpenSession: (String) -> Void = { _ in }

    @State private var showNewSheet = false
    @State private var deleteTarget: SessionData?
    @State private var showHistory = false
    @State private var pendingFolderPath = ""
    @State private var selectMode = false
    @State private var selectedIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                Text("操作失败：\(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    switch viewModel.phase {
                    case .loading:
                        ProgressView("加载工作区中…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    case .failed(let message):
                        Text("加载工作区失败：\(message)")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    case .loaded:
                        summaryBar
                        sessionSection
                        jobsSection
                    }
                }
                // TS Dashboard.page：max-width 1040 居中 + padding 32/56。
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gatherBackground)
        .task {
            await viewModel.loadAll()
            viewModel.startAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuNewWorkspace)) { _ in
            pendingFolderPath = ""
            showNewSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuImportFolder)) { notification in
            guard let directory = notification.object as? URL else { return }
            pendingFolderPath = directory.path
            showNewSheet = true
        }
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
        }
        .confirmationDialog(
            "删除工作区",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    Task { await viewModel.deleteSession(target.id) }
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            // TS dashboard.deleteWorkspaceMessage 逐字对齐。
            Text("确定要删除 \"\(deleteTarget?.name ?? "")\" 吗？这将移除该工作区中的所有照片和结果。")
        }
        .confirmationDialog(
            "批量删除工作区",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除全部", role: .destructive) {
                let ids = Array(selectedIds)
                Task {
                    if await viewModel.deleteSessions(ids) {
                        exitSelectMode()
                    }
                }
            }
            Button("取消", role: .cancel) { showBatchDeleteConfirm = false }
        } message: {
            Text("确定要删除选中的 \(selectedIds.count) 个工作区吗？这将移除这些工作区中的所有照片和结果，不可恢复。")
        }
    }

    // MARK: 头部（TS Dashboard header：Gather + subtitle + 新建工作区）

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gather")
                    .font(.system(size: 24, weight: .bold))
                Text("整理、挑选并同步你的摄影工作区")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !viewModel.sessions.isEmpty {
                if selectMode {
                    // TS selectAll checkbox：支持半选（indeterminate）。
                    Button(action: toggleSelectAll) {
                        Label("全选", systemImage: selectAllIcon)
                    }
                    if !selectedIds.isEmpty {
                        Button("删除 \(selectedIds.count) 个", role: .destructive) {
                            showBatchDeleteConfirm = true
                        }
                    }
                    Button("取消", action: exitSelectMode)
                } else {
                    Button("多选") { selectMode = true }
                }
            }
            Button {
                showNewSheet = true
            } label: {
                Label("新建工作区", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: 多选（TS selectedIds/toggleSelect/toggleSelectAll/exitSelectMode）

    private var selectAllIcon: String {
        if selectedIds.isEmpty { return "square" }
        if selectedIds.count == viewModel.sessions.count { return "checkmark.square.fill" }
        return "minus.square"
    }

    private func toggleSelect(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func toggleSelectAll() {
        if selectedIds.count == viewModel.sessions.count {
            selectedIds = []
        } else {
            selectedIds = Set(viewModel.sessions.map(\.id))
        }
    }

    private func exitSelectMode() {
        selectMode = false
        selectedIds = []
    }

    // MARK: 工作区概览（SwiftUI 侧聚合，数据源 workspace.status）

    private var summaryBar: some View {
        let summary = viewModel.summary()
        return HStack(spacing: 0) {
            statItem("工作区", summary.sessionCount)
            statItem("照片", summary.photoCount)
            statItem("待同步写回", summary.pendingXmp)
            statItem("冲突", summary.conflictXmp)
            statItem("离线照片", summary.offlinePhotos)
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func statItem(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 工作区卡片列表（TS Dashboard 卡片区）

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工作区")
                .font(.title3.bold())
            if viewModel.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("暂无工作区")
                        .font(.headline)
                    Text("创建新的工作区以开始整理照片")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.sessions, id: \.id) { session in
                        SessionCardView(
                            session: session,
                            photoCountLabel: viewModel.photoCountLabel(for: session),
                            status: viewModel.statuses[session.id],
                            scanJob: viewModel.scanJobs[session.id],
                            selectMode: selectMode,
                            isSelected: selectedIds.contains(session.id),
                            onToggleSelect: { toggleSelect(session.id) },
                            onOpen: { onOpenSession(session.id) },
                            onDelete: { deleteTarget = session },
                            onRetryScan: { Task { await viewModel.retryScan(sessionId: session.id) } }
                        )
                    }
                }
            }
        }
    }

    // MARK: 任务中心（TS Jobs 页：attention + history + clear）

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("任务中心")
                        .font(.title3.bold())
                    Text("后台任务 · 持久化分析任务、进度和失败恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清理已完成") {
                    Task { await viewModel.clearCompletedJobs() }
                }
                .disabled(!viewModel.hasClearableJobs)
            }
            if let error = viewModel.jobsError {
                jobsErrorState(error)
            } else if viewModel.jobs.isEmpty {
                jobsEmptyState
            } else {
                Text("进行中与需要处理")
                    .font(.subheadline.weight(.semibold))
                if viewModel.attentionJobs.isEmpty {
                    quietState
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.attentionJobs, id: \.id) { job in
                            JobRowView(
                                job: job,
                                onCancel: { Task { await viewModel.cancelJob(job.id) } },
                                onRetry: { Task { await viewModel.retryJob(job.id) } }
                            )
                        }
                    }
                }
                if !viewModel.historyJobs.isEmpty {
                    Button {
                        showHistory.toggle()
                    } label: {
                        HStack {
                            Text("已完成历史")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(showHistory ? "收起历史" : "展开 \(viewModel.historyJobs.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showHistory {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.historyJobs, id: \.id) { job in
                                JobRowView(job: job, compact: true, onCancel: {}, onRetry: {})
                            }
                        }
                    }
                }
            }
        }
    }

    /// TS Jobs 页整页空态（jobs.empty）：dashed 大块 + 插画 +「暂无后台任务」。
    private var jobsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 28))
                .foregroundStyle(GatherTheme.primary)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 20).fill(GatherTheme.primarySoft))
            Text("暂无后台任务")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    GatherTheme.border,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        )
    }

    /// 任务中心错误态（jobs.list 失败；区别于「暂无后台任务」空态，
    /// 只在获取成功后无任务时才展示空态）：错误文案 + 重试。
    private func jobsErrorState(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(GatherTheme.error)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 20).fill(GatherTheme.error.opacity(0.1)))
            Text("任务加载失败：\(error)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await viewModel.refreshJobs() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    GatherTheme.border,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        )
    }

    /// TS Jobs 页 quietState（jobs.noAttention）：success 色 dashed 块。
    private var quietState: some View {
        Text("当前没有运行中或失败的任务")
            .font(.callout)
            .foregroundStyle(GatherTheme.success)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(GatherTheme.success.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                GatherTheme.success.opacity(0.6),
                                style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                            )
                    )
            )
    }
}

// MARK: - 工作区卡片

private struct SessionCardView: View {
    let session: SessionData
    let photoCountLabel: String
    let status: WorkspaceStatus?
    let scanJob: DashboardScanJob?
    let selectMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRetryScan: () -> Void

    /// TS card hover（Dashboard.module.css .card:hover）：border→primary +
    /// shadow-md + translateY(-1px)，0.15s。
    @State private var hovered = false

    /// TS 卡片布局：.cardOpen 是整卡按钮（flex:1 内容区），.cardActions 是
    /// 右侧独立按钮组（stopPropagation）——SwiftUI 用外层 Button（可键盘
    /// 聚焦、Enter/Space 激活）承载内容区，操作按钮为兄弟节点不嵌套。
    var body: some View {
        HStack(spacing: 12) {
            Button(action: selectMode ? onToggleSelect : onOpen) {
                HStack(spacing: 12) {
                    if selectMode {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(session.name)
                                .font(.headline)
                                .lineLimit(1)
                            statusBadge
                        }
                        HStack(spacing: 12) {
                            Text(photoCountLabel)
                                .font(.callout)
                            if let status {
                                if status.xmp.pending > 0 {
                                    Text("待同步写回 \(status.xmp.pending)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if status.xmp.conflict > 0 {
                                    Text("冲突 \(status.xmp.conflict)")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                if !status.failedJobs.isEmpty {
                                    Text("失败任务 \(status.failedJobs.count)")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                if status.offlinePhotos > 0 {
                                    Text("离线 \(status.offlinePhotos)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(Self.dateText(session.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectMode ? session.name : "打开 \(session.name)")
            if !selectMode {
                HStack(spacing: 8) {
                    // TS retryScan：索引失败卡片显示“重试”，重新入队 metadata.scan。
                    if deriveCardIndexKind(scanJob) == .failed {
                        Button("重试", action: onRetryScan)
                            .buttonStyle(.bordered)
                    }
                    Button("进入", action: onOpen)
                        .buttonStyle(.bordered)
                    Menu {
                        Button("删除", role: .destructive, action: onDelete)
                    } label: {
                        Label("操作", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .gatherCard()
        .shadow(
            color: hovered ? GatherTheme.shadowMd : Color.clear,
            radius: hovered ? 16 : 0,
            y: hovered ? 6 : 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    selectMode
                        ? (isSelected ? Color.accentColor : Color.clear)
                        : (hovered ? GatherTheme.primary : Color.clear),
                    lineWidth: 1.5
                )
        )
        .offset(y: hovered ? -1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovering in
            hovered = hovering
        }
    }

    /// TS Badge 状态色（Badge.tsx STATUS_COLORS 逐字对齐：photosLoaded 青 /
    /// review 靛蓝 / analyzing 蓝 / completed 绿 / draft 灰，pastel 底 +
    /// 深色文字 + uppercase 600 样式）。
    private var statusBadge: GatherBadge {
        switch session.status {
        case .draft:
            return .draft()
        case .photosLoaded:
            return .photosLoaded()
        case .analyzing:
            return .running("分析中")
        case .review:
            return .review()
        case .completed:
            return .done("已完成")
        }
    }

    /// TS Dashboard formatDate（toLocaleDateString：跟随应用语言；
    /// zh 环境输出 2026年8月12日 14:30）。
    private static func dateText(_ iso: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = GatherLocalization.appLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let date = Self.parseISO8601(iso) {
            return formatter.string(from: date)
        }
        return iso
    }

    private static func parseISO8601(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

// MARK: - 任务行（TS Jobs 页统一行格式：身份列 + 状态徽标 + 进度条 + 操作）

private struct JobRowView: View {
    let job: AnalysisJobData
    var compact = false
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gatherSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1)
        )
    }

    /// 非 compact 行：TS Jobs.module.css .row 四列（身份 220 / 状态 90 /
    /// 进度 flexible / 操作 80）。
    private var fullBody: some View {
        HStack(spacing: 16) {
            identityColumn
                .frame(width: 220, alignment: .leading)
            statusBadge
                .frame(width: 90, alignment: .leading)
            progressBar
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if job.status == .queued || job.status == .running {
                    Button("取消", action: onCancel)
                }
                if job.status == .failed || job.status == .interrupted || job.status == .cancelled {
                    Button("重试", action: onRetry)
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(14)
    }

    /// compact 行：TS .rowCompact 两列（身份 flexible + 状态 100），
    /// 无进度无操作，min-height 58。
    private var compactBody: some View {
        HStack(spacing: 16) {
            identityColumn
            Spacer(minLength: 0)
            statusBadge
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
    }

    /// TS .identity 列：类型 strong +「工作区 · id 前 8 位」（title 完整 id）+
    /// 「尝试 N 次」+ 错误（title 完整错误）。
    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.typeLabel(job.type))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("工作区 · \(job.scopeId.prefix(8))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(job.scopeId)
            if !compact {
                Text("尝试 \(job.attemptCount) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !job.errorMessage.isEmpty {
                Text(GatherLocalization.jobErrorMessage(job.errorMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(job.errorMessage)
            }
        }
    }

    /// 状态：GatherBadge 主题语义色编码（成功/失败/警告/信息/主色）。
    private var statusBadge: some View {
        GatherBadge(status: job.status)
    }

    /// TS Jobs.module.css .progress：高 28、圆角 10、带边框、主色填充、
    /// 文字内嵌 `{pct}% {phase}`（pct = Math.round(current/total*100)）。
    private var progressBar: some View {
        let pct = Double(DashboardViewModel.progressPercent(of: job)) / 100
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(GatherTheme.backgroundSecondary)
                RoundedRectangle(cornerRadius: 10)
                    .fill(GatherTheme.primary.opacity(0.18))
                    .frame(width: max(0, geo.size.width * pct))
                Text("\(DashboardViewModel.progressPercent(of: job))% \(GatherLocalization.progressPhaseText(job.progressMessage))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.gatherTextPrimary)
                    .lineLimit(1)
                    .padding(.leading, 9)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(GatherTheme.primary.opacity(0.35), lineWidth: 1)
            )
        }
        .frame(height: 28)
    }

    /// TS JOB_TYPE_KEYS（jobs.type.* 中文键值）。
    static func typeLabel(_ type: AnalysisJobType) -> String {
        switch type {
        case .metadataScan: return "照片索引与元数据"
        case .checksumBackfill: return "文件校验和补全"
        case .similarityAnalyze: return "相似照片分析"
        case .faceAnalyze: return "人脸分析"
        case .duplicateScan: return "重复照片扫描"
        case .qualityScore: return "技术质量分析"
        case .exportExecute: return "照片导出"
        case .thumbnailBuild: return "缩略图生成"
        }
    }
}

// MARK: - 新建工作区（来源选择 + C1 四层预检 + metadata.scan 一跳入队）

private struct NewSessionSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    /// 创建成功回调（TS createMutation onSuccess → navigate(`/sessions/${id})`，
    /// DashboardView 注入 onOpenSession）。
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
        VStack(alignment: .leading, spacing: 16) {
            Text("新建工作区")
                .font(.title3.bold())
            TextField(
                source == .local ? "选择文件夹后自动生成" : "留空则使用照片所在文件夹名称",
                text: $name
            )
            .textFieldStyle(.roundedBorder)
            .onChange(of: name) { _, _ in nameEdited = true }
            Picker("导入来源", selection: $source) {
                ForEach(DashboardViewModel.SessionSource.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if source == .local {
                folderRow
            } else {
                c1PreflightSection
            }
            if let error = viewModel.createError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Text("创建后会立即启动照片索引；索引进度和失败重试可在任务中心查看。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || viewModel.isCreating)
            }
        }
        .padding(20)
        .frame(width: 480)
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
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择包含照片的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
        if !nameEdited {
            name = url.lastPathComponent
        }
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            TextField("文件夹位置", text: $folderPath)
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            Button("选择文件夹", action: chooseFolder)
        }
    }

    /// TS Dialog c1Preflight 区块：检查清单（✓/✗）+ 通过/引导文案。
    @ViewBuilder
    private var c1PreflightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capture One 连接预检")
                .font(.subheadline.weight(.semibold))
            switch viewModel.c1Preflight {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查 Capture One 连接…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .finished(let result):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.checks) { check in
                        HStack(spacing: 6) {
                            Image(systemName: check.passed ? "checkmark" : "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(check.passed ? Color.green : Color.red)
                            Text(check.label)
                                .font(.callout)
                        }
                    }
                    if result.passed {
                        Text("预检通过：导入时读取 Capture One 当前选中的照片。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let guidance = result.guidance {
                        // 旧版 c1-preflight.ts：预检失败引导为红色（error 语义）。
                        Text(guidance)
                            .font(.caption)
                            .foregroundStyle(GatherTheme.error)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
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
