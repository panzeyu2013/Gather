// Phase 3.1/3.6：工作区控制中心，承接 workspace.status、indexProgress、
// 质量分析、失败任务恢复和同步入口。
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
    private(set) public var errorMessage: String?
    private(set) public var notice: String?

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    public func load() {
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
        await enqueue("quality.analyze", message: "质量分析已入队")
    }

    public func retry(_ job: AnalysisJobData) {
        guard [.failed, .interrupted, .cancelled].contains(job.status) else { return }
        do {
            _ = try client.execute("jobs.retry", params: ["jobId": .string(job.id)])
            notice = "已重试任务"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
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

public struct SessionControlView: View {
    @State private var viewModel: SessionControlViewModel
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in }
    ) {
        _viewModel = State(initialValue: SessionControlViewModel(sessionId: sessionId, router: router))
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: error, color: .red) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: .green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    recommendationCard
                    actionCard
                    syncCard
                    jobsCard
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { viewModel.load() }
    }

    private var header: some View {
        HStack {
            Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.session?.name ?? "工作区控制中心").font(.system(size: 24, weight: .bold))
                Text("会话 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var statusCard: some View {
        if let status = viewModel.workspaceStatus {
            VStack(alignment: .leading, spacing: 12) {
                Text("工作区状态").font(.title3.weight(.semibold))
                HStack(spacing: 18) {
                    statusValue("阶段", stageLabel(status.stage))
                    statusValue("索引", "\(status.indexing.done)/\(status.indexing.total)")
                    statusValue("离线", "\(status.offlinePhotos)")
                    statusValue("待同步", "\(status.xmp.pending)")
                    statusValue("冲突", "\(status.xmp.conflict)")
                    Spacer()
                }
                if status.indexing.total > 0 {
                    ProgressView(value: Double(status.indexing.done), total: Double(status.indexing.total))
                    Text("索引 \(Int(status.indexing.percent.rounded()))% · \(status.indexing.status.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !status.failedJobs.isEmpty {
                    Text("失败任务 \(status.failedJobs.count) 个").foregroundStyle(.red)
                }
            }
            .nativeCard()
        }
    }

    @ViewBuilder
    private var recommendationCard: some View {
        if let next = viewModel.workspaceStatus?.recommendedNext {
            HStack {
                Image(systemName: "lightbulb").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("建议下一步").font(.headline)
                    Text(next.action).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if next.target.lowercased().contains("similar") {
                    Button("打开") { onOpenSimilarity(viewModel.sessionId) }
                } else if let tab = Self.tab(for: next.target) {
                    Button("打开") { onOpenTab(viewModel.sessionId, tab) }
                }
            }
            .nativeCard()
        }
    }

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

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("元数据同步").font(.title3.weight(.semibold))
            if let sync = viewModel.syncStatus {
                Text("待处理 \(sync.pending) · 写入中 \(sync.writing) · 已写入 \(sync.written) · 失败 \(sync.failed) · 冲突 \(sync.conflict)")
                    .foregroundStyle(sync.failed + sync.conflict > 0 ? .red : .secondary)
            } else {
                Text("暂无同步状态").foregroundStyle(.secondary)
            }
        }
        .nativeCard()
    }

    private var jobsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前任务").font(.title3.weight(.semibold))
            if viewModel.jobs.isEmpty {
                Text("暂无工作区任务").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.jobs, id: \.id) { job in
                    HStack {
                        Image(systemName: job.status == .succeeded ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(job.status == .failed ? .red : .accentColor)
                        Text(job.type.rawValue)
                        Spacer()
                        Text(job.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        if job.progressTotal > 0 {
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

    private func statusValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold))
        }
    }

    private func stageLabel(_ stage: WorkspaceStage) -> String {
        switch stage {
        case .created: return "已创建"
        case .imported: return "已导入"
        case .indexed: return "已索引"
        case .analyzed: return "已分析"
        }
    }

    private static func tab(for target: String) -> SessionTab? {
        let normalized = target.lowercased()
        if normalized.contains("face") { return .faceKw }
        if normalized.contains("cull") || normalized.contains("pick") { return .culling }
        if normalized.contains("export") { return .export }
        if normalized.contains("duplicate") { return .duplicates }
        if normalized.contains("similar") { return nil }
        return .control
    }
}
