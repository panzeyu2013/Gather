// desktop/native/gather-app/Sources/GatherUI/Culling/IngestSheet.swift
// P1 / D：摄取向导（复制/重命名/校验 → 登记进当前会话）。
//
// 只做"把卡里的照片搬进工作目录并登记"这一件事：不选片、不改元数据。
// 目标默认 <sessionSourcePath>/_ingest，源用系统面板选（支持多选目录）。
import SwiftUI
import AppKit
import GatherProtocol

struct IngestSheet: View {
    let viewModel: CullingViewModel
    let sessionSourcePath: String

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("摄取到当前会话"))
                .font(.headline)

            LabeledContent(l10n("来源")) {
                HStack {
                    Text(sources.isEmpty ? l10n("未选择") : sources.joined(separator: "、"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(sources.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(l10n("选择…")) { chooseSources() }
                }
            }

            LabeledContent(l10n("目标文件夹")) {
                HStack {
                    TextField(l10n("目标文件夹"), text: $destinationRoot)
                        .labelsHidden()
                    Button(l10n("选择…")) { chooseDestination() }
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
                }
            }

            Toggle(l10n("复制后校验校验和"), isOn: $verifyChecksum)

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
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                Button(l10n("开始摄取")) { Task { await run() } }
                    .disabled(isRunning || sources.isEmpty || destinationRoot.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            if destinationRoot.isEmpty, !sessionSourcePath.isEmpty {
                destinationRoot = (sessionSourcePath as NSString).appendingPathComponent("_ingest")
            }
        }
        .task {
            // 调用点没传会话目录时从会话记录补：目标必须在会话源目录内（API 会校验）。
            guard destinationRoot.isEmpty else { return }
            guard let api = viewModel.sessionAPI else {
                errorText = l10n("摄取未接线（缺少 session API）")
                return
            }
            do {
                let session = try await api.get(viewModel.sessionId)
                if !session.sourcePath.isEmpty {
                    destinationRoot = (session.sourcePath as NSString)
                        .appendingPathComponent("_ingest")
                } else {
                    errorText = l10n("无法确定会话目录，请手动选择目标文件夹")
                }
            } catch {
                errorText = String(describing: error)
            }
        }
    }

    private func run() async {
        isRunning = true
        errorText = nil
        result = nil
        defer { isRunning = false }
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
            await viewModel.loadPage(reset: true)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            sources = panel.urls.map(\.path)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            destinationRoot = url.path
        }
    }

    private func chooseSecondDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            secondRoot = url.path
        }
    }
}
