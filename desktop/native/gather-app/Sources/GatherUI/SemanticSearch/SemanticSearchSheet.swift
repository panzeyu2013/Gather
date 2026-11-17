// desktop/native/gather-app/Sources/GatherUI/SemanticSearch/SemanticSearchSheet.swift
// Wave2 / task-14：场景标签检索/写回面板。
//
// 入口：挑片检查器「场景标签…」（CullingTriageCard）——用当前多选照片做种子，
// 支持 ① 找相似（多选平均向量）② 按 Vision 标签检索（支持中文输入，见
// SemanticLabelCatalog）③ 把场景标签写回关键词（预览显示中文名；路径仍英文；整批撤销）。
import Foundation
import SwiftUI
import GatherProtocol

struct SemanticSearchSheet: View {
    @State private var model: SemanticSearchSheetModel
    @State private var pendingWriteback: SemanticSearchSheetModel.WritebackAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// 命中照片的可读名（E5）：调用方注入（挑片页用 page.assets 的 filename）。
    private let nameFor: (String) -> String
    /// 命中照片的跳转（E5）：点击即选中并定位到该照片，回得到网格。
    private let onSelect: (String) -> Void

    init(
        api: any PhotoAPI,
        sessionId: String,
        seedPhotoIds: [String],
        nameFor: @escaping (String) -> String = { $0 },
        onSelect: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: SemanticSearchSheetModel(
            api: api, sessionId: sessionId, seedPhotoIds: seedPhotoIds))
        self.nameFor = nameFor
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            header
            modePicker
            if model.mode == .labels {
                labelField
            }
            noticeLine
            results
            Divider()
            writebackCard
            footer
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 560, minHeight: 520)
        .task {
            if model.mode == .similar {
                await model.loadSimilar(l10n: l10n)
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingWriteback,
            title: l10n("确认写回场景关键词？"),
            confirmLabel: { action in
                action == .undo ? l10n("确认撤销") : l10n("确认写回")
            },
            confirmRole: { action in action == .undo ? .destructive : nil },
            message: { action in
                if action == .undo {
                    let scope = l10n.format(
                        "本次撤销范围：上一次写回实际改动的 %lld 张照片。",
                        Int64(model.lastWriteScopePhotoIds.count))
                    return l10n("只移除 AI 场景标签这一棵子树下的关键词，不动人工/人脸/相似度来源的关键词。")
                        + "\n" + scope
                }
                return l10n("会把场景标签写成层级关键词并进入交付链（XMP）。可整批撤销。")
            },
            onConfirm: { action in
                pendingWriteback = nil
                Task { await model.applyWriteback(action, l10n: l10n) }
            },
            onCancel: { _ in
                pendingWriteback = nil
            }
        )
    }

    // MARK: - 头部 / 模式

    private var header: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Text(l10n("场景标签"))
                .font(GatherFont.cardTitle)
            if model.hasMultipleSeeds {
                Text(l10n.format("已选 %lld 张作为种子", Int64(model.seedPhotoIds.count)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var modePicker: some View {
        Picker(l10n("检索方式"), selection: Binding(
            get: { model.mode },
            set: { newValue in
                model.mode = newValue
                Task {
                    if newValue == .similar {
                        await model.loadSimilar(l10n: l10n)
                    } else if !model.labelKeywords.isEmpty {
                        await model.searchLabels(l10n: l10n)
                    }
                }
            }
        )) {
            Text(l10n("找相似（用选中照片）")).tag(SemanticSearchSheetModel.Mode.similar)
            Text(l10n("按标签检索")).tag(SemanticSearchSheetModel.Mode.labels)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            HStack(spacing: GatherMetrics.Space.s) {
                TextField(l10n("标签（中文或英文，逗号分隔，如 海滩, wedding）"), text: Binding(
                    get: { model.labelQuery },
                    set: { model.labelQuery = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.searchLabels(l10n: l10n) } }
                Button(l10n("检索")) {
                    Task { await model.searchLabels(l10n: l10n) }
                }
                .gatherButton(.secondary)
                .disabled(model.isBusy)
            }
            // 中文→英文映射可见（避免用户以为检索参数变了却说不清为什么命中）。
            if !model.labelMappings.isEmpty {
                Text(l10n.format(
                    "中文映射：%@",
                    model.labelMappings
                        .map { "\($0.input) → \($0.english)" }
                        .joined(separator: "、")))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var noticeLine: some View {
        if let error = model.error {
            Text(APIErrorPresentation.message(for: error, with: l10n))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.errorText)
                .fixedSize(horizontal: false, vertical: true)
        } else if let notice = model.notice {
            Text(notice)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var results: some View {
        if model.hits.isEmpty {
            Text(model.isBusy ? l10n("检索中…") : l10n("没有结果"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                    ForEach(model.hits, id: \.photoId) { hit in
                        Button {
                            // E5：点结果 = 选中并定位这张照片，然后关闭面板回网格。
                            onSelect(hit.photoId)
                            dismiss()
                        } label: {
                            HStack(spacing: GatherMetrics.Space.s) {
                                VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                                    Text(nameFor(hit.photoId))
                                        .font(GatherFont.labelRegular)
                                        .lineLimit(1)
                                    if !hit.matchedLabels.isEmpty {
                                        // 主行中文显示名；英文原标签作为小字副行（可逆证据）。
                                        Text(model.displayText(hit.matchedLabels))
                                            .font(GatherFont.secondary)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .accessibilityLabel(Text(l10n.format(
                                                "命中标签：%@",
                                                model.displayText(hit.matchedLabels))))
                                        let englishText = hit.matchedLabels.joined(separator: " · ")
                                        if model.displayText(hit.matchedLabels) != englishText {
                                            Text(englishText)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                Spacer()
                                if let similarity = hit.similarity {
                                    Text(String(format: "%.0f%%", similarity * 100))
                                        .font(GatherFont.secondary.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, GatherMetrics.Space.xxs)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)
        }
    }

    // MARK: - 写回

    private var writebackCard: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n("标签 → 关键词"))
                .font(GatherFont.labelRegular)
            Text(planSummary)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            plannedKeywordsPreview
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("预览")) {
                    Task { await model.previewWriteback(l10n: l10n) }
                }
                .gatherButton(.secondary, size: .small)
                .disabled(model.isBusy)

                Button(l10n("写回关键词…")) {
                    pendingWriteback = .write
                }
                .gatherButton(.secondary, size: .small)
                .disabled(model.isBusy || (model.plan?.totalAdditions ?? 0) == 0)

                Button(l10n("撤销上一次写回…")) {
                    pendingWriteback = .undo
                }
                .gatherButton(.secondary, size: .small)
                .disabled(model.isBusy || !model.canUndoWriteback)
            }
            Text(l10n("界面显示中文名；写回 XMP 的关键词仍用英文标签（如 AI|场景|beach），可在图库按关键词检索/交付。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n("写回是幂等的：同一张照片重复写不会重复加词；撤销只移除 AI 场景子树。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n("上一次写回可撤销：关闭面板或重启 App 后仍可撤销。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .gatherCard()
    }

    /// 写回预览：中文显示名 + 英文原标签（路径本身不翻译，保持 AI|场景|<英文>）。
    @ViewBuilder
    private var plannedKeywordsPreview: some View {
        if let plan = model.plan, !model.plannedKeywords.isEmpty {
            Text(l10n("将写入的关键词"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
            Text(model.plannedKeywords.prefix(10)
                .map { l10n.format("%@（%@）", $0.displayName, $0.englishLabel) }
                .joined(separator: " · "))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.plannedKeywords.count > 10 {
                Text(l10n.format(
                    "…等 %lld 个",
                    Int64(model.plannedKeywords.count)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            Text(l10n.format(
                "写回路径：%@|英文标签（可逆；中文只影响显示）",
                plan.root))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planSummary: String {
        guard let plan = model.plan else {
            return l10n("先点「预览」看会新增多少关键词。")
        }
        if let unavailable = plan.unavailableReason {
            return unavailable
        }
        let summary = l10n.format(
            "可写回 %lld 个关键词 / %lld 张照片（已存在的不重复写）",
            Int64(plan.totalAdditions), Int64(plan.photosWithLabels))
        guard plan.itemsTruncated else { return summary }
        // Wave4b：明细被上限截断时明确说明（计数是准确的，别让用户以为明细少了词）。
        return summary + "\n" + l10n.format(
            "（照片明细仅返回前 %lld 张，计数为全量）",
            Int64(SemanticKeywordPath.maxDisplayedPlanItems))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(l10n("完成")) { dismiss() }
                .gatherButton(.secondary)
                .keyboardShortcut(.cancelAction)
        }
    }
}
