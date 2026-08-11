// Phase 3.6：任务中心 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/Jobs/index.tsx。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class JobsViewModel {
    private let jobService: JobService
    private(set) public var jobs: [AnalysisJobData] = []
    private(set) public var isLoading = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?

    public init(jobService: JobService) {
        self.jobService = jobService
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try jobService.list()
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func cancel(_ job: AnalysisJobData) async {
        do {
            _ = try jobService.cancel(job.id)
            notice = "已请求取消 \(job.id.prefix(8))"
            await load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func retry(_ job: AnalysisJobData) async {
        do {
            _ = try jobService.retry(job.id)
            notice = "已重新排队 \(job.id.prefix(8))"
            await load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func clearCompleted() async {
        do {
            let count = try jobService.clearCompleted()
            notice = "已清理 \(count) 个任务"
            await load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public var attentionJobs: [AnalysisJobData] {
        jobs.filter { $0.status != .succeeded }
    }

    public var historyJobs: [AnalysisJobData] {
        jobs.filter { $0.status == .succeeded }
    }
}

public struct JobsView: View {
    @State private var viewModel: JobsViewModel

    public init(jobService: JobService) {
        _viewModel = State(initialValue: JobsViewModel(jobService: jobService))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            if let error = viewModel.errorMessage {
                NativeBanner(text: error, color: .red)
            }
            if let notice = viewModel.notice {
                NativeBanner(text: notice, color: .green)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    jobSection(title: "需要处理", jobs: viewModel.attentionJobs)
                    jobSection(title: "历史记录", jobs: viewModel.historyJobs)
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.load() }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("任务中心").font(.system(size: 24, weight: .bold))
                Text("查看、取消、重试和清理后台任务").foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await viewModel.load() }
            }
            Button("清理已完成", systemImage: "trash") {
                Task { await viewModel.clearCompleted() }
            }
            .disabled(viewModel.historyJobs.isEmpty)
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func jobSection(title: String, jobs: [AnalysisJobData]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            if jobs.isEmpty {
                Text("暂无任务").foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ForEach(jobs, id: \.id) { job in
                    JobRow(job: job,
                           onCancel: { Task { await viewModel.cancel(job) } },
                           onRetry: { Task { await viewModel.retry(job) } })
                }
            }
        }
    }
}

private struct JobRow: View {
    let job: AnalysisJobData
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var progress: Double {
        guard job.progressTotal > 0 else { return 0 }
        return min(1, max(0, Double(job.progressCurrent) / Double(job.progressTotal)))
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.type.rawValue).font(.headline)
                    Text(job.status.rawValue).font(.caption).foregroundStyle(statusColor)
                    Spacer()
                    Text(job.scopeId.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if job.progressTotal > 0 {
                    ProgressView(value: progress)
                    Text("\(job.progressCurrent)/\(job.progressTotal)  (job.progressMessage)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !job.progressMessage.isEmpty {
                    Text(job.progressMessage).font(.caption).foregroundStyle(.secondary)
                }
                if !job.errorMessage.isEmpty {
                    Text(job.errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            if [.queued, .running].contains(job.status) {
                Button("取消", action: onCancel)
            } else if [.failed, .cancelled, .interrupted].contains(job.status) {
                Button("重试", action: onRetry)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var icon: String {
        switch job.status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled, .cancelling, .interrupted: return "stop.circle.fill"
        case .queued, .running: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled, .cancelling, .interrupted: return .orange
        case .queued, .running: return .accentColor
        }
    }
}

public struct NativeBanner: View {
    let text: String
    let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .background(color.opacity(0.1))
    }
}
