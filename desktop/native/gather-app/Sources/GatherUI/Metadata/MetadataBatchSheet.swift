// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataBatchSheet.swift
// P1 / B3：持久化批次的撤销入口（关闭模板面板/重启后仍可回滚）。
import SwiftUI
import GatherProtocol

struct MetadataBatchSheet: View {
    let viewModel: CullingViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var batches: [MetadataBatchSummary] = []
    @State private var errorText: String?
    @State private var isBusy = false
    /// 待确认撤销的批次：Confirmed 只能在真实确认弹窗的分支里构造（D-011）。
    @State private var pendingUndo: MetadataBatchSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("最近套用与写回"))
                .font(GatherFont.cardTitle)

            if batches.isEmpty {
                Text(l10n("没有可撤销的批次"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                        ForEach(batches, id: \.batchId) { batch in
                            HStack(spacing: GatherMetrics.Space.m) {
                                VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                                    Text(batch.kind == "triage"
                                         ? l10n("技术建议写回") : batch.name)
                                        .font(GatherFont.body)
                                    Text(l10n.format("%@ · %lld 张 · %@",
                                                     batch.kind == "triage"
                                                        ? l10n("技术建议写回") : batch.name,
                                                     batch.photoCount,
                                                     displayDate(batch.appliedAt)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if batch.undone {
                                    Text(l10n("已撤销"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button(l10n("撤销")) { pendingUndo = batch }
                                        .disabled(isBusy)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(l10n("关闭")) { dismiss() }
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 560)
        .task { await reload() }
        .confirmationDialog(
            l10n("撤销这次写回？"),
            isPresented: Binding(
                get: { pendingUndo != nil },
                set: { if !$0 { pendingUndo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(l10n("撤销"), role: .destructive) {
                if let batch = pendingUndo { Task { await undo(batch) } }
                pendingUndo = nil
            }
            Button(l10n("取消"), role: .cancel) { pendingUndo = nil }
        } message: {
            Text(pendingUndo?.kind == "triage"
                 ? l10n("还原 rating/关键词，并清除私有命名空间信号。")
                 : l10n("还原这批照片的描述性字段。"))
        }
    }

    private func reload() async {
        do {
            batches = try await viewModel.metadataAPI.recentBatches(limit: 20)
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    private func displayDate(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func undo(_ batch: MetadataBatchSummary) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let input = try MetadataTemplateUndoInput(batchId: batch.batchId)
            let confirmed = Confirmed(input, source: .userDialog)
            let failedCount: Int
            if batch.kind == "triage" {
                failedCount = try await viewModel.metadataAPI
                    .undoTriageWriteback(confirmed).failed.count
            } else {
                failedCount = try await viewModel.metadataAPI
                    .undoTemplate(confirmed).failed.count
            }
            // reload() 成功会把 errorText 清空：失败提示必须在它之后写，
            // 否则"部分撤销失败"的唯一反馈会在一个 await 内被抹掉。
            await reload()
            if failedCount > 0 {
                errorText = l10n.format("撤销有 %lld 张失败，可重试", failedCount)
            }
            await viewModel.loadPage(reset: true)
            viewModel.loadMetadataDetail()
        } catch {
            errorText = String(describing: error)
        }
    }
}
