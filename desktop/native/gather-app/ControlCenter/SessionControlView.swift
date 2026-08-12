// Phase 3.1/3.6：工作区控制中心（对齐 Electron ControlCenter）。
// 派生逻辑对齐 renderer/pages/SessionDetail/ControlCenter/workspace-view.ts：
// - Action Inbox 7 类固定优先级聚合（L70-169）
// - 三硬阶段进度条（L187-199，未完成阶段实线描边）
// - 推荐下一步 6 种 action 中文映射（L210-276）
// - 头部索引进度/失败重试（indexProgress.ts / deriveWorkspaceHeaderCopy 语义，
//   截断导入在精确总数落定前保留 "≥" 前缀）
// 数据源：workspace.status / jobs.list / culling.sync_status；
// 事件：GatherEventCenter.jobTerminal + c1SyncStatus，另设兜底轮询
// （索引活跃期 3s，其余 15s，对齐 useWorkspaceStatus.ts 3s/30s 双档）。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class SessionControlViewModel {
    private let client: NativeCommandClient
    public let sessionId: String
    private(set) public var session: SessionData?
    private(set) public var workspaceStatus: WorkspaceStatus?
    private(set) public var jobs: [AnalysisJobData] = []
    private(set) public var syncStatus: MetadataSyncSummary?
    private(set) public var isWorking = false
    /// 初始为 true：首帧即渲染加载态，避免 load() 完成前卡片空白。
    private(set) public var isLoading = true
    private(set) public var errorMessage: String?
    private(set) public var notice: String?

    /// 索引进度活跃判定（对齐 OLD useWorkspaceStatus.ts:26-42 的 indexActive）：
    /// stage == created（一跳化导入窗口）或 indexing == active（含 queued/running
    /// 语义）时为 true；终态（idle/failed）回落常规轮询间隔。
    public var isIndexingActive: Bool {
        guard let status = workspaceStatus else { return false }
        return status.stage == .created || status.indexing.status == .active
    }

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    public func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            session = try client.execute("session.get", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: SessionData.self)
            workspaceStatus = try client.execute("workspace.status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: WorkspaceStatus.self)
            jobs = try client.execute("jobs.list").decoded(as: [AnalysisJobData].self)
                .filter { $0.scopeId == sessionId }
            syncStatus = try? client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: MetadataSyncSummary.self)
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func scanIndex() async {
        await enqueue("index.scan", message: "索引扫描已入队")
    }

    public func analyzeQuality() async {
        await enqueue("quality.analyze", message: "技术质量分析已入队")
    }

    /// 索引失败重试：重新入队 metadata.scan（对齐 TS retryIndex → indexerApi.scan）。
    public func retryIndex() async {
        await enqueue("index.scan", message: "索引扫描已入队")
    }

    public func retry(jobId: String) {
        do {
            _ = try client.execute("jobs.retry", params: ["jobId": .string(jobId)])
            notice = "已重试任务"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func retry(_ job: AnalysisJobData) {
        guard [.failed, .interrupted, .cancelled].contains(job.status) else { return }
        retry(jobId: job.id)
    }

    /// recommendedNext.retry_jobs 动作：重试全部失败任务（TS 跳转 /jobs；
    /// 原生无任务中心页，等价改为逐个 jobs.retry）。
    public func retryFailedJobs() {
        let failed = workspaceStatus?.failedJobs ?? []
        guard !failed.isEmpty else { return }
        var retried = 0
        var firstFailure: String?
        for job in failed {
            do {
                _ = try client.execute("jobs.retry", params: ["jobId": .string(job.id)])
                retried += 1
            } catch {
                if firstFailure == nil {
                    firstFailure = NativeCommandClient.message(for: error)
                }
            }
        }
        if retried > 0 {
            notice = "已重试 \(retried) 个失败任务"
            load()
        }
        if retried == 0 {
            errorMessage = firstFailure ?? "重试任务失败"
        }
    }

    private func enqueue(_ command: String, message: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await client.executeAsync(command, params: ["sessionId": .string(sessionId)])
            notice = message
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }
}

// MARK: - Action Inbox 模型（对齐 workspace-view.ts InboxItem / InboxKind）
// internal（非 private）：InboxItemsTests 直测 deriveInboxItems 优先级。

enum InboxKind: Equatable {
    case scanIncomplete
    case xmpConflict
    case analysisStale
    case xmpPending
    case offlinePhotos
    case jobFailed
    case exportPending
}

enum InboxAction: Equatable {
    case none
    case showStages
    case navigateTab(SessionTab)
    case navigateSimilarity
    case navigateGallery
    case retryJob(String)
    case retryFailedJobs
}

struct InboxItem: Identifiable, Equatable {
    let id: String
    let kind: InboxKind
    let label: String
    let detail: String?
    let actionLabel: String
    let action: InboxAction
}

// MARK: - 推荐下一步模型（对齐 workspace-view.ts RecommendedNextView）

private struct RecommendedNextView {
    let title: String
    let detail: String
    let actionLabel: String
    let action: InboxAction?
}

// MARK: - 头部索引文案模型（对齐 indexProgress.ts IndexHeaderCopy）

/// 索引进度头文案模式（internal：IndexProgressTests 直测纯推导）。
enum IndexHeaderMode: Equatable {
    case scanning
    case error
    case count
}

struct IndexHeaderCopy: Equatable {
    let mode: IndexHeaderMode
    let text: String
    let percent: Double?
    let done: Int
    let total: Int
}

public struct SessionControlView: View {
    @State private var viewModel: SessionControlViewModel
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void
    @State private var scrollToStagesRequested = false

    /// TS: MAX_FAILED_JOB_ROWS —— 失败任务最多显示 3 行。
    private static let maxFailedJobRows = 3
    /// 兜底轮询常规间隔（10-30s 区间内；事件驱动为主，轮询仅兜底）。
    private static let pollInterval: Duration = .seconds(15)
    /// 索引活跃期快速轮询间隔（对齐 TS POLL_INTERVAL_ACTIVE_MS=3s：
    /// 索引进度条及时推进；useWorkspaceStatus.ts:10-11 3s/30s 双档）。
    private static let pollIntervalActive: Duration = .seconds(3)

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: SessionControlViewModel(sessionId: sessionId, router: router))
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                header
                if let error = viewModel.errorMessage { NativeBanner(text: "操作失败：\(error)", color: GatherTheme.error) }
                if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
                ScrollView {
                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("加载中…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    } else if viewModel.workspaceStatus == nil && viewModel.errorMessage == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("暂无工作区状态").foregroundStyle(.secondary)
                            Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            stagesCard.id("stages")
                            inboxCard
                            recommendationCard
                            actionCard
                            syncCard
                            jobsCard
                        }
                        .padding(24)
                    }
                }
            }
            .background(Color.gatherBackground)
            .onChange(of: scrollToStagesRequested) { _, requested in
                guard requested else { return }
                withAnimation { proxy.scrollTo("stages", anchor: .top) }
                scrollToStagesRequested = false
            }
        }
        .task {
            viewModel.load()
            // 兜底轮询：jobTerminal / c1SyncStatus 事件驱动为主，无事件时按状态
            // 动态调整间隔——索引进度活跃期（isIndexingActive）每 3s 刷新一次，
            // 其余情况 15s（对齐 OLD useWorkspaceStatus.ts 的 3s/30s 双档）。
            // 每次 sleep 前读取最新 status，因此索引开始/结束会自动切换档位。
            while !Task.isCancelled {
                let interval = viewModel.isIndexingActive ? Self.pollIntervalActive : Self.pollInterval
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                viewModel.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.scopeType == "session",
                  event.job.scopeId == viewModel.sessionId else { return }
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            viewModel.load()
        }
    }

    // MARK: 头部（含索引进度：对齐 index.tsx header + deriveWorkspaceHeaderCopy）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.session?.name ?? "工作区控制中心").font(.system(size: 24, weight: .bold))
                    Text("工作区 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
                }
                Spacer()
                C1StatusCapsuleHost(
                    sessionId: viewModel.sessionId,
                    router: router,
                    onOpenSettings: onOpenSettings
                )
                Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
            }
            SessionTabBar(
                selection: .tab(.control),
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
            indexRow
        }
        .padding(24)
        .background(Color.gatherSurface)
    }

    @ViewBuilder
    private var indexRow: some View {
        if let status = viewModel.workspaceStatus {
            let copy = indexHeaderCopy(status, session: viewModel.session)
            HStack(spacing: 10) {
                switch copy.mode {
                case .scanning:
                    Text(copy.text).font(.callout)
                    if let percent = copy.percent, copy.total > 0 {
                        Text("已索引 \(Int(percent.rounded()))%").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(copy.done), total: Double(copy.total))
                            .frame(maxWidth: 220)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .error:
                    Text(copy.text).font(.callout).foregroundStyle(.red)
                    Button("重试") { Task { await viewModel.retryIndex() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                case .count:
                    Text(copy.text).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    /// deriveWorkspaceHeaderCopy（workspace-view.ts L289-322）：索引活跃/失败期间
    /// 绝不把阶段计数当权威数据展示；截断导入在索引成功（精确总数落定）前保留 "≥"。
    /// internal（非 private）：IndexProgressTests 直接测纯推导（对齐 index-progress.test.ts）。
    func indexHeaderCopy(_ status: WorkspaceStatus, session: SessionData?) -> IndexHeaderCopy {
        if status.stage == .created || status.indexing.status == .active {
            if status.indexing.total > 0 {
                return IndexHeaderCopy(
                    mode: .scanning,
                    text: "正在索引 \(status.indexing.done) / \(status.indexing.total)",
                    // 对齐 index-progress.test.ts：percent 钳制 0...100（防御服务端越界）。
                    percent: min(max(status.indexing.percent, 0), 100),
                    done: status.indexing.done,
                    total: status.indexing.total
                )
            }
            return IndexHeaderCopy(mode: .scanning, text: "扫描中…", percent: nil, done: 0, total: 0)
        }
        if status.indexing.status == .failed {
            return IndexHeaderCopy(mode: .error, text: "索引失败", percent: nil, done: 0, total: 0)
        }
        let photoCount = session?.photoCount ?? 0
        if photoCount == 0 {
            return IndexHeaderCopy(mode: .count, text: "暂无照片", percent: nil, done: 0, total: 0)
        }
        if (session?.truncatedImport ?? false) && status.stage != .indexed {
            return IndexHeaderCopy(mode: .count, text: "已索引 ≥\(photoCount) 张照片", percent: nil, done: 0, total: 0)
        }
        return IndexHeaderCopy(mode: .count, text: "已索引 \(photoCount) 张照片", percent: nil, done: 0, total: 0)
    }

    // MARK: 三硬阶段进度条（对齐 deriveStageMarks + index.tsx stageBar）

    private var stagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("阶段进度").font(.title3.weight(.semibold))
            if let status = viewModel.workspaceStatus {
                HStack(spacing: 10) {
                    ForEach(Array(stageMarks(status.stage).enumerated()), id: \.element.id) { index, mark in
                        if index > 0 { stageConnector(reached: mark.reached) }
                        stageMark(mark)
                    }
                    Spacer()
                }
                if status.softFlags.culled || status.softFlags.exported {
                    HStack(spacing: 8) {
                        if status.softFlags.culled { softFlagBadge("已挑片") }
                        if status.softFlags.exported { softFlagBadge("已导出") }
                    }
                }
            }
        }
        .nativeCard()
    }

    /// 阶段标记（internal：WorkspaceStageMarksTests 直测 deriveStageMarks）。
    struct StageMark: Identifiable, Equatable {
        let id: String
        let label: String
        let reached: Bool
        let current: Bool
    }

    /// deriveStageMarks（workspace-view.ts L187-199）：created 窗口（一跳化导入后
    /// 0 张照片）时高亮第一个硬阶段；未达阶段以实线描边标记呈现。
    func stageMarks(_ stage: WorkspaceStage) -> [StageMark] {
        let order = ["imported", "indexed", "analyzed"]
        let labels: [String: String] = [
            "imported": "已导入",
            "indexed": "已索引",
            "analyzed": "已分析",
        ]
        let reachedIndex = stage == .created ? -1 : (order.firstIndex(of: stage.rawValue) ?? -1)
        return order.enumerated().map { index, id in
            StageMark(
                id: id,
                label: labels[id] ?? id,
                reached: index <= reachedIndex,
                current: stage == .created ? index == 0 : index == reachedIndex
            )
        }
    }

    private func stageMark(_ mark: StageMark) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if mark.reached {
                    Circle()
                        .fill(GatherTheme.primary)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.gatherSurface, lineWidth: 2))
                } else {
                    // 未完成阶段：实线描边（对齐 OLD ControlCenter.module.css:87-101
                    // .stageDot 2px solid border，非虚线软标记）。
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(GatherTheme.primary.opacity(mark.current ? 0.15 : 0)))
            .overlay(Circle().stroke(GatherTheme.primary.opacity(mark.current ? 0.65 : 0), lineWidth: 1.5))
            Text(mark.label)
                .font(.caption)
                .fontWeight(mark.current ? .semibold : .regular)
                .foregroundStyle(mark.current ? Color.gatherPrimary : (mark.reached ? .primary : .secondary))
        }
    }

    private func stageConnector(reached: Bool) -> some View {
        Rectangle()
            .fill(reached ? Color.gatherPrimary : Color.secondary.opacity(0.35))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    private func softFlagBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(GatherTheme.primary.opacity(0.1)))
            .foregroundStyle(.secondary)
    }

    // MARK: Action Inbox（对齐 deriveInboxItems：固定优先级序列表）

    private var inboxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("待处理事项").font(.title3.weight(.semibold))
                Text("按优先级排序").font(.caption).foregroundStyle(.secondary)
            }
            if let status = viewModel.workspaceStatus {
                let items = inboxItems(status, truncatedImport: viewModel.session?.truncatedImport ?? false)
                if items.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("全部正常").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        inboxRow(item)
                    }
                }
            }
        }
        .nativeCard()
    }

    private func inboxRow(_ item: InboxItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            let icon = inboxIcon(item.kind)
            Image(systemName: icon.name).foregroundStyle(icon.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(item.actionLabel) { perform(item.action) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// deriveInboxItems（workspace-view.ts L70-169）：7 类固定优先级聚合，
    /// 失败任务最多 3 行；错误码仅展示可翻译文案，原始诊断不落 UI。
    func inboxItems(_ status: WorkspaceStatus, truncatedImport: Bool) -> [InboxItem] {
        var items: [InboxItem] = []
        let truncatedImport = truncatedImport

        let indexingActive = status.stage == .created || status.indexing.status == .active
        let scanIncomplete = indexingActive
            || status.indexing.status == .failed
            || (truncatedImport && status.stage == .imported)
        if scanIncomplete {
            items.append(InboxItem(
                id: "scan_incomplete", kind: .scanIncomplete,
                label: "索引未完成，照片数量暂不精确", detail: nil,
                actionLabel: "查看进度", action: .showStages
            ))
        }

        if status.xmp.conflict > 0 {
            items.append(InboxItem(
                id: "xmp_conflict", kind: .xmpConflict,
                label: "\(status.xmp.conflict) 个 XMP 冲突待裁决", detail: nil,
                actionLabel: "逐条裁决", action: .navigateTab(.culling)
            ))
        }

        if !status.staleAnalyses.isEmpty {
            let faceOnly = status.staleAnalyses.allSatisfy { $0.kind == .face }
            let names = status.staleAnalyses
                .map { $0.kind == .similarity ? "相似度" : "人脸" }
                .joined(separator: "、")
            items.append(InboxItem(
                id: "analysis_stale", kind: .analysisStale,
                label: "\(names)分析已过期，新增照片未参与分析", detail: nil,
                actionLabel: "重新分析",
                action: faceOnly ? .navigateTab(.faceKw) : .navigateSimilarity
            ))
        }

        if status.xmp.pending > 0 {
            items.append(InboxItem(
                id: "xmp_pending", kind: .xmpPending,
                label: "\(status.xmp.pending) 个 XMP 待写入", detail: nil,
                actionLabel: "检查", action: .navigateTab(.culling)
            ))
        }

        if status.offlinePhotos > 0 {
            items.append(InboxItem(
                id: "offline_photos", kind: .offlinePhotos,
                label: "\(status.offlinePhotos) 张照片离线（源文件不可读）", detail: nil,
                actionLabel: "查看", action: .navigateGallery
            ))
        }

        for (index, job) in status.failedJobs.prefix(Self.maxFailedJobRows).enumerated() {
            // 错误码不在翻译表时 detail 置 nil 不渲染（对齐 TS L148-150：
            // 原始诊断不落 UI 文案）。
            let detail = GatherLocalization.errorMessages[job.code]
            items.append(InboxItem(
                id: "job_failed-\(index)", kind: .jobFailed,
                label: "\(Self.jobTypeLabel(job.type))任务失败", detail: detail,
                actionLabel: "重试", action: .retryJob(job.id)
            ))
        }

        if status.softFlags.culled && !status.softFlags.exported {
            items.append(InboxItem(
                id: "export_pending", kind: .exportPending,
                label: "已挑片但尚未导出", detail: nil,
                actionLabel: "去导出", action: .navigateTab(.export)
            ))
        }

        return items
    }

    /// JOB_TYPE_KEYS（workspace-view.ts L43-53）：未知类型回退原始字符串。
    private static func jobTypeLabel(_ type: String) -> String {
        switch type {
        case "metadata.scan": "索引"
        case "similarity.analyze": "相似度分析"
        case "fkw.analyze", "face.analyze": "人脸分析"
        case "dup.scan", "duplicate.scan": "重复扫描"
        case "export.execute": "导出"
        case "quality.analyze", "quality.score": "技术分析"
        case "navigation.analyze": "导航分析"
        case "culling.writeback": "挑片写回"
        case "sim.writeback": "相似组写回"
        default: type
        }
    }

    private func inboxIcon(_ kind: InboxKind) -> (name: String, color: Color) {
        switch kind {
        case .scanIncomplete: return ("magnifyingglass", GatherTheme.primary)
        case .xmpConflict: return ("exclamationmark.triangle.fill", .red)
        case .analysisStale: return ("clock.arrow.circlepath", .orange)
        case .xmpPending: return ("arrow.up.doc", GatherTheme.primary)
        case .offlinePhotos: return ("photo", .secondary)
        case .jobFailed: return ("xmark.circle.fill", .red)
        case .exportPending: return ("square.and.arrow.up", GatherTheme.primary)
        }
    }

    // MARK: 推荐下一步（对齐 deriveRecommendedNextView）

    private var recommendationCard: some View {
        Group {
            if let status = viewModel.workspaceStatus {
                let view = recommendedNextView(status)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb").foregroundStyle(.orange)
                        Text("推荐下一步").font(.headline)
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(view.title).font(.callout.weight(.semibold))
                            Text(view.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let action = view.action {
                            Button(view.actionLabel) { perform(action) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .nativeCard()
    }

    /// deriveRecommendedNextView（workspace-view.ts L210-276）：6 种 action 映射为
    /// 中文标题/详情/按钮文案；未知 action 兜底为 done（一切正常）而非裸枚举字符串
    /// （对齐 TS L273-274 return done）。
    private func recommendedNextView(_ status: WorkspaceStatus) -> RecommendedNextView {
        guard let next = status.recommendedNext else {
            return RecommendedNextView(
                title: "一切正常", detail: "工作区状态良好，无待办事项",
                actionLabel: "", action: nil
            )
        }
        switch next.action {
        case "scan_incomplete":
            return RecommendedNextView(
                title: "等待索引完成", detail: "后台索引正在进行，完成后照片数量将精确显示",
                actionLabel: "查看进度", action: .showStages
            )
        case "resolve_conflicts":
            return RecommendedNextView(
                title: "裁决 XMP 冲突", detail: "冲突会阻塞写回同步，先逐条裁决再继续",
                actionLabel: "逐条裁决", action: .navigateTab(.culling)
            )
        case "re_analyze":
            let faceOnly = status.staleAnalyses.allSatisfy { $0.kind == .face }
            return RecommendedNextView(
                title: "重新分析相似度", detail: "新增照片未参与分组，重新分析可合并剩余重复项",
                actionLabel: "重新分析",
                action: faceOnly ? .navigateTab(.faceKw) : .navigateSimilarity
            )
        case "retry_jobs":
            return RecommendedNextView(
                title: "重试失败任务", detail: "存在失败的后台任务，先重试再继续",
                actionLabel: "重试失败任务", action: .retryFailedJobs
            )
        case "start_culling":
            return RecommendedNextView(
                title: "开始挑片", detail: "工作区已就绪，从挑片开始整理",
                actionLabel: "去挑片", action: .navigateTab(.culling)
            )
        case "export":
            return RecommendedNextView(
                title: "导出成品", detail: "挑片已完成，导出最终成品",
                actionLabel: "去导出", action: .navigateTab(.export)
            )
        default:
            return RecommendedNextView(
                title: "一切正常", detail: "工作区状态良好，无待办事项",
                actionLabel: "", action: nil
            )
        }
    }

    // MARK: 动作执行

    private func perform(_ action: InboxAction) {
        switch action {
        case .none:
            break
        case .showStages:
            scrollToStagesRequested = true
        case .navigateTab(let tab):
            onOpenTab(viewModel.sessionId, tab)
        case .navigateSimilarity:
            onOpenSimilarity(viewModel.sessionId)
        case .navigateGallery:
            // 对齐 OLD workspace-view.ts:135：offline_photos “查看”进入画廊
            // （/sessions/:id/gallery），而非 onBack 返回上一页。onOpenGallery
            // 在 RootView 已接线 navigation.openGallery；默认闭包保证独立编译。
            onOpenGallery(viewModel.sessionId)
        case .retryJob(let jobId):
            viewModel.retry(jobId: jobId)
        case .retryFailedJobs:
            viewModel.retryFailedJobs()
        }
    }

    // MARK: 工具箱（原生保留入口）

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分析与索引").font(.title3.weight(.semibold))
            Text("后台任务可在任务中心查看、取消或重试。").foregroundStyle(.secondary)
            HStack {
                Button("扫描索引", systemImage: "magnifyingglass") { Task { await viewModel.scanIndex() } }
                Button("分析质量", systemImage: "wand.and.stars") { Task { await viewModel.analyzeQuality() } }
                Button("打开挑片") { onOpenTab(viewModel.sessionId, .culling) }
                Button("打开人脸") { onOpenTab(viewModel.sessionId, .faceKw) }
            }
        }
        .nativeCard()
    }

    // MARK: 元数据同步（保留计数 + 中文状态说明）

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("元数据同步").font(.title3.weight(.semibold))
            if let sync = viewModel.syncStatus {
                HStack(spacing: 16) {
                    syncCount("待处理", sync.pending)
                    syncCount("写入中", sync.writing)
                    syncCount("已写入", sync.written)
                    syncCount("失败", sync.failed, emphasized: sync.failed > 0)
                    syncCount("冲突", sync.conflict, emphasized: sync.conflict > 0)
                    Spacer()
                }
                Text(syncStatusText(sync))
                    .font(.caption)
                    .foregroundStyle(sync.failed + sync.conflict > 0 ? .red : .secondary)
            } else {
                Text("暂无同步状态").foregroundStyle(.secondary)
            }
        }
        .nativeCard()
    }

    private func syncCount(_ title: String, _ value: Int, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)")
                .font(.callout.weight(.semibold).monospaced())
                .foregroundStyle(emphasized ? .red : .primary)
        }
    }

    private func syncStatusText(_ sync: MetadataSyncSummary) -> String {
        if sync.failed + sync.conflict > 0 { return "存在失败或冲突的写入项，请先处理后再继续" }
        if sync.pending + sync.writing > 0 { return "正在等待 Capture One 确认写入…" }
        return "元数据已全部同步"
    }

    // MARK: 当前任务（本地化状态/类型/进度文案）

    private var jobsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前任务").font(.title3.weight(.semibold))
            if viewModel.jobs.isEmpty {
                Text("暂无工作区任务").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.jobs, id: \.id) { job in
                    HStack(spacing: 8) {
                        Image(systemName: job.status == .succeeded ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(job.status == .failed ? .red : GatherTheme.primary)
                        Text(GatherLocalization.jobTypeText(job.type.rawValue))
                        Text(GatherLocalization.jobStatusText(job.status.rawValue))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if job.progressTotal > 0 {
                            Text(GatherLocalization.progressPhaseText(job.progressMessage))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(job.progressCurrent)/\(job.progressTotal)").font(.caption.monospaced())
                        }
                        if [.failed, .interrupted, .cancelled].contains(job.status) {
                            Button("重试") { viewModel.retry(job) }
                        }
                    }
                }
            }
        }
        .nativeCard()
    }
}
