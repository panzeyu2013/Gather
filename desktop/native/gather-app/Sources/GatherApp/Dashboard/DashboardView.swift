// desktop/native/gather-app/Sources/GatherApp/Dashboard/DashboardView.swift
// Phase 3.1 Dashboard：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Dashboard/index.tsx + pages/Jobs/index.tsx
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    let onOpenSession: (SessionData) -> Void

    @State private var showNewSheet = false
    @State private var deleteTarget: SessionData?
    @State private var showHistory = false
    @State private var pendingFolderPath = ""

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
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.loadAll()
            viewModel.startAutoRefresh()
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
        .sheet(isPresented: $showNewSheet) {
            NewSessionSheet(viewModel: viewModel, initialFolderPath: pendingFolderPath)
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
            Text("删除「\(deleteTarget?.name ?? "")」？这将移除该工作区的所有照片与分析结果。")
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
            Button {
                showNewSheet = true
            } label: {
                Label("新建工作区", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
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
                            onOpen: { onOpenSession(session) },
                            onDelete: { deleteTarget = session }
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
            if viewModel.jobs.isEmpty {
                Text("暂无后台任务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text("进行中与需要处理")
                    .font(.subheadline.weight(.semibold))
                if viewModel.attentionJobs.isEmpty {
                    Text("当前没有运行中或失败的任务")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
}

// MARK: - 工作区卡片

private struct SessionCardView: View {
    let session: SessionData
    let photoCountLabel: String
    let status: WorkspaceStatus?
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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
            Spacer()
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
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// TS Badge 文案（badge.* 中文键值）。
    private var statusBadge: some View {
        let label: String
        switch session.status {
        case .draft: label = "草稿"
        case .photosLoaded: label = "已导入"
        case .analyzing: label = "分析中"
        case .review: label = "待审核"
        case .completed: label = "已完成"
        }
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }

    /// TS Dashboard formatDate（toLocaleDateString 的近似：zh_CN + 精确时间）。
    private static func dateText(_ iso: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
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

// MARK: - 任务行

private struct JobRowView: View {
    let job: AnalysisJobData
    var compact = false
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Self.typeLabel(job.type))
                        .font(.subheadline.weight(.semibold))
                    Text("工作区 · \(job.scopeId.prefix(8))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !compact {
                        Text("尝试 \(job.attemptCount) 次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !job.errorMessage.isEmpty {
                    Text(job.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if !compact && job.progressTotal > 0 {
                    ProgressView(
                        value: Double(job.progressCurrent),
                        total: Double(job.progressTotal)
                    )
                    Text("\(DashboardViewModel.progressPercent(of: job))% \(job.progressMessage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Self.statusLabel(job.status))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            if !compact {
                if job.status == .queued || job.status == .running {
                    Button("取消", action: onCancel)
                        .buttonStyle(.bordered)
                }
                if job.status == .failed || job.status == .interrupted || job.status == .cancelled {
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// TS STATUS_LABEL_KEYS（jobs.status.* 中文键值）。
    static func statusLabel(_ status: AnalysisJobStatus) -> String {
        switch status {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .cancelling: return "取消中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
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

// MARK: - 新建工作区（目录校验 + metadata.scan 一跳入队）

private struct NewSessionSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nameEdited = false
    @State private var folderPath = ""

    init(viewModel: DashboardViewModel, initialFolderPath: String = "") {
        self.viewModel = viewModel
        _folderPath = State(initialValue: initialFolderPath)
        _name = State(initialValue: initialFolderPath.isEmpty ? "" : URL(fileURLWithPath: initialFolderPath).lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建工作区")
                .font(.title3.bold())
            TextField("工作区名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, _ in nameEdited = true }
            HStack(spacing: 8) {
                TextField("文件夹位置", text: $folderPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("选择文件夹", action: chooseFolder)
            }
            if let error = viewModel.createError {
                Text("创建失败：\(error)")
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
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !folderPath.isEmpty
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

    private func create() {
        Task {
            let session = await viewModel.createSession(
                name: name.trimmingCharacters(in: .whitespaces),
                sourcePath: folderPath
            )
            if session != nil { dismiss() }
        }
    }
}
