// desktop/native/gather-app/Sources/GatherUI/Culling/IngestSheet.swift
// P1 / D：摄取向导（复制/重命名/校验 → 登记进当前会话）。
//
// 只做"把卡里的照片搬进工作目录并登记"这一件事：不选片、不改元数据。
// 目标默认 <会话源目录>/_ingest（打开时由 session.get 补齐），源用系统面板选（支持多选目录）。
import SwiftUI
import AppKit
import GatherProtocol

struct IngestSheet: View {
    let viewModel: CullingViewModel


    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var sources: [String] = []
    @State private var destinationRoot = ""
    @State private var renameTemplate = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}"
    @State private var secondRoot = ""
    @State private var verifyChecksum = true
    @State private var isRunning = false
    @State private var result: SessionIngestResult?
    @State private var errorText: String?
    /// P1-3：会话没有 sourcePath 时先修根，不引导用户手选一个必败的目标目录。
    @State private var rootMissing = false
    @State private var progress: (current: Int, total: Int)?
    @State private var progressTask: Task<Void, Never>?
    @State private var cancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("摄取到当前会话"))
                .font(.headline)

            if rootMissing {
                HStack(spacing: GatherMetrics.Space.s) {
                    Text(l10n("当前工作区没有根目录，无法确定摄取目标。"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(l10n("设置根目录…")) { chooseSessionRoot() }
                        .gatherButton(.secondary, size: .small)
                }
            }

            LabeledContent(l10n("来源")) {
                HStack {
                    Text(sources.isEmpty ? l10n("未选择") : sources.joined(separator: "、"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(sources.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(l10n("选择…")) { chooseSources() }
                        .gatherButton(.secondary, size: .small)
                        .accessibilityLabel(l10n("来源"))
                }
            }

            LabeledContent(l10n("目标文件夹")) {
                HStack {
                    TextField(l10n("目标文件夹"), text: $destinationRoot)
                        .labelsHidden()
                    Button(l10n("选择…")) { chooseDestination() }
                        .gatherButton(.secondary, size: .small)
                        .accessibilityLabel(l10n("目标文件夹"))
                }
            }

            LabeledContent(l10n("重命名模板")) {
                TextField("{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}", text: $renameTemplate)
                    .labelsHidden()
                    .font(.body.monospaced())
            }
            Text(l10n("占位符：{yyyy} {MM} {dd} {HH} {mm} {ss} {orig} {ext} {seq:4} {camera}"))
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent(l10n("第二目的地")) {
                HStack {
                    TextField(l10n("可选"), text: $secondRoot)
                        .labelsHidden()
                    Button(l10n("选择…")) { chooseSecondDestination() }
                        .gatherButton(.secondary, size: .small)
                        .accessibilityLabel(l10n("第二目的地"))
                }
            }

            Toggle(l10n("复制后校验校验和"), isOn: $verifyChecksum)

            if isRunning {
                HStack(spacing: GatherMetrics.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(progress.map { l10n.format("已复制 %lld/%lld", $0.current, $0.total) }
                         ?? l10n("正在摄取…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button(cancelling ? l10n("正在取消…") : l10n("取消摄取")) {
                        Task { await cancelIngest() }
                    }
                    .gatherButton(.secondary, size: .small)
                    .disabled(cancelling)
                }
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            if let result {
                Text(l10n.format("已登记 %lld 张，跳过 %lld 张，失败 %lld 张",
                                 result.registered, result.skipped.count, result.failed.count))
                    .font(.caption)
                if !result.unreadable.isEmpty {
                    Text(l10n.format("无法读取/越界被拒绝：%lld 个", result.unreadable.count))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !result.copiedButUnregistered.isEmpty {
                    Text(l10n.format("已复制但未登记：%lld 张", result.copiedButUnregistered.count))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let failure = result.failed.first {
                    let failureError = CommandError(
                        apiText: failure.code ?? "", diagnostic: failure.message)
                    Text(CommandErrorText.resolve(failureError, with: l10n))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                    .gatherButton(.secondary)
                    .disabled(isRunning)
                Button(l10n("开始摄取")) { Task { await run() } }
                    .gatherButton(.primary)
                    .disabled(isRunning || sources.isEmpty || destinationRoot.isEmpty || rootMissing)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 520)
        // 运行中禁止 Esc/点外部关闭：任务在后台继续但用户看不到进度会以为已取消。
        .interactiveDismissDisabled(isRunning)
        .task {
            // 调用点没传会话目录时从会话记录补：目标必须在会话源目录内（API 会校验）。
            guard destinationRoot.isEmpty else { return }
            guard let api = viewModel.sessionAPI else {
                errorText = l10n("摄取未接线（缺少 session API）")
                return
            }
            do {
                let session = try await api.get(viewModel.sessionId)
                // await 期间用户可能已经手选目录：不得用回填值覆盖。
                guard destinationRoot.isEmpty else { return }
                if !session.sourcePath.isEmpty {
                    destinationRoot = (session.sourcePath as NSString)
                        .appendingPathComponent("_ingest")
                    rootMissing = false
                } else {
                    rootMissing = true
                    errorText = l10n("当前工作区没有根目录，无法确定摄取目标。")
                }
            } catch {
                errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            }
        }
    }

    private func run() async {
        isRunning = true
        errorText = nil
        result = nil
        progress = nil
        startProgressPolling()
        defer {
            progressTask?.cancel()
            progressTask = nil
            isRunning = false
            cancelling = false
        }
        do {
            let input = try SessionIngestInput(
                sessionId: viewModel.sessionId,
                sourcePaths: sources,
                destinationRoot: destinationRoot,
                renameTemplate: renameTemplate,
                secondDestinationRoot: secondRoot.isEmpty ? nil : secondRoot,
                verifyChecksum: verifyChecksum
            )
            guard let sessionAPI = viewModel.sessionAPI else {
                errorText = l10n("摄取未接线（缺少 session API）")
                return
            }
            let outcome = try await sessionAPI.ingest(Confirmed(input, source: .userDialog))
            result = outcome
            // #11：导入改变会话的照片集合与计数（侧栏/图库都读它），发 .library。
            // 本页动作：带 culling origin，避免挑片页把它当外部变更再整页刷一次（本页随后 loadPage）。
            GatherEventCenter.postDomainChange(
                .library, sessionId: nil, origin: CullingViewModel.changeOrigin)
            await viewModel.loadPage(reset: true)
        } catch {
            if error is any JobCancellationMarker {
                // 取消可能已登记部分照片：不报“未知错误”，并刷新列表让用户看到实况。
                errorText = l10n("已取消摄取；取消前已登记的照片会保留")
                await viewModel.loadPage(reset: true)
            } else {
                errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            }
        }
    }

    /// P1-3：摄取已 Job 化；取消按 session 找活跃 ingest.run 任务，不依赖局部 Task 句柄。
    private func cancelIngest() async {
        cancelling = true
        defer { cancelling = false }
        do {
            guard let job = await activeIngestJob() else {
                // 任务刚好结束/尚未入队：给可见反馈，不能“点了没反应”。
                errorText = l10n("没有进行中的摄取任务")
                return
            }
            _ = try await viewModel.jobAPI.cancel(job.id)
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    /// 当前会话活跃的 ingest 任务（摄取复用 checksum.backfill 载体，按 checkpoint 判定）。
    private func activeIngestJob() async -> AnalysisJobData? {
        let jobs: [AnalysisJobData]
        do {
            // isIngestRun 只读 dedupeKey；不需要 checkpoint（导出 job 可达 MB）。
            jobs = try await viewModel.jobAPI.list(JobListFilter(includeCheckpoint: false))
        } catch {
            return nil
        }
        return jobs.first {
            $0.isIngestRun
                && $0.scopeId == viewModel.sessionId
                && [.queued, .running, .cancelling].contains($0.status)
        }
    }

    /// 复制阶段的服务端进度（1000 张以上必须能看到 N/M）。
    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                if let job = await activeIngestJob(), job.progressTotal > 0 {
                    let next = (current: job.progressCurrent, total: job.progressTotal)
                    if progress?.current != next.current || progress?.total != next.total {
                        progress = next
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// 没有根的会话：先修根（与「设置根目录…」同一 API），再回填目标目录。
    private func chooseSessionRoot() {
        guard let api = viewModel.sessionAPI else {
            errorText = l10n("摄取未接线（缺少 session API）")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let session = try await api.setSourceRoot(
                        Confirmed(try SessionSetSourceRootInput(
                            sessionId: viewModel.sessionId, sourceRoot: url.path)))
                    destinationRoot = (session.sourcePath as NSString)
                        .appendingPathComponent("_ingest")
                    rootMissing = false
                    errorText = nil
                } catch {
                    errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
                }
            }
        }
    }

    private func chooseSources() {
        pickPaths(canChooseFiles: true, allowsMultiple: true) { sources = $0 }
    }

    private func chooseDestination() {
        pickPaths(canChooseFiles: false) { if let path = $0.first { destinationRoot = path } }
    }

    private func chooseSecondDestination() {
        pickPaths(canChooseFiles: false) { if let path = $0.first { secondRoot = path } }
    }

    /// 三个选择面板共用：目录必选、文件可选；回调只在用户确认后执行。
    private func pickPaths(
        canChooseFiles: Bool,
        allowsMultiple: Bool = false,
        apply: @escaping ([String]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = allowsMultiple
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in apply(paths) }
        }
    }
}
